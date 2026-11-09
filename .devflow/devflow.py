#!/usr/bin/env python3
"""devflow — shared helper for the devflow skills, hook and GitHub Actions.

One file, standard library only (Python 3.9+). The same file ships in the plugin
(scripts/devflow.py) and is copied into every repo as .devflow/devflow.py, so the
checks a developer runs locally are byte-for-byte the checks CI runs.

Subcommands
  version                         print version
  config [--get KEY]              print the repo config (or one dotted key)
  diff-stats --base REF           changed files / languages / line counts vs REF
  gate --base REF [--out F]       run the deterministic gate for the changed files
  review start ...                begin a review: run the gate, write diff + prompt + draft
  review finalize ...             merge AI findings into the draft, compute verdict, save report
  review render --report F        print the PR markdown block for a report
  review check --level L [--sha]  exit 0 if a PASS report exists for the commit
  review latest --level L         print the path of the newest report for HEAD
  pr-body ...                     compose a full PR body (summary + checklist + review block)
  verify-pr ...                   CI: validate the review block in a PR body
  story get|transition|comment    Azure DevOps state machine (REST, PAT auth)
  board-sync EVENT ...            CI: move Stories on merge / deploy events
  guard                           PreToolUse hook entry point (reads JSON on stdin)
  session-context                 SessionStart hook entry point
  install-repo --target DIR       copy the repo templates + this script into a repo
"""
from __future__ import annotations

import argparse
import base64
import datetime as _dt
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DEVFLOW_VERSION = "1.0.0"
REPORT_SCHEMA = "devflow.review/v1"
CONFIG_REL = ".devflow/config.json"
BLOCK_BEGIN = "<!-- devflow:review:begin -->"
BLOCK_END = "<!-- devflow:review:end -->"
DEVTEST_BEGIN = "<!-- devflow:devtest:begin -->"
DEVTEST_END = "<!-- devflow:devtest:end -->"
REPORT_RE = re.compile(r"<!-- devflow:report:([A-Za-z0-9+/=]+) -->")
LEVELS = ("task", "dev", "prod")
SEVERITIES = ("critical", "high", "medium", "low", "info")
CATEGORIES = ("security", "correctness", "scope", "acceptance", "tests", "data",
              "maintainability", "performance", "other")
# These can never be marked non-blocking by the reviewer.
FORCED_BLOCKING = {("critical", c) for c in CATEGORIES} | {
    ("high", "security"), ("high", "data"), ("high", "correctness"), ("high", "acceptance")}

LANG_EXT = {
    "python": (".py", ".pyi"),
    "js_ts": (".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"),
    "sql": (".sql",),
    "html": (".html", ".htm"),
    "css": (".css", ".scss", ".sass", ".less"),
}

DEFAULT_STATES = {
    "new": "New",
    "active": "Active",
    "code_review_dev": "Code Review - Dev",
    "dev_testing": "Dev Testing",
    "code_review_prod": "Code Review - Prod",
    "awaiting_deployment": "Awaiting Deployment",
    "closed": "Closed",
}
# Logical transitions for Stories and Bugs. Anything else is refused.
STORY_TRANSITIONS = {
    "new": {"active"},
    "active": {"code_review_dev"},
    "code_review_dev": {"dev_testing", "active"},
    "dev_testing": {"code_review_prod", "active"},
    "code_review_prod": {"awaiting_deployment", "active"},
    "awaiting_deployment": {"closed", "active"},
    "closed": set(),
}
TASK_TRANSITIONS = {"new": {"active", "closed"}, "active": {"closed"}, "closed": set()}


class DevflowError(Exception):
    pass


# ----------------------------------------------------------------------------- utils

def _run(cmd, cwd=None, check=True, timeout=None, shell=False):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, shell=shell)
    if check and p.returncode != 0:
        raise DevflowError(f"command failed ({p.returncode}): {cmd if shell else ' '.join(cmd)}\n{p.stderr.strip()}")
    return p


def git(args, cwd=None, check=True):
    return _run(["git"] + list(args), cwd=cwd, check=check).stdout.strip()


def repo_root(start=None) -> Path:
    p = _run(["git", "rev-parse", "--show-toplevel"], cwd=start, check=False)
    if p.returncode != 0:
        raise DevflowError("not inside a git repository")
    return Path(p.stdout.strip())


def git_dir(root: Path) -> Path:
    d = git(["rev-parse", "--git-common-dir"], cwd=root)
    p = Path(d)
    return p if p.is_absolute() else (root / p).resolve()


def reviews_dir(root: Path) -> Path:
    d = git_dir(root) / "devflow" / "reviews"
    d.mkdir(parents=True, exist_ok=True)
    return d


def now_iso():
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat()


def canonical(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest_of(report: dict) -> str:
    body = {k: v for k, v in report.items() if k != "digest"}
    return "sha256:" + hashlib.sha256(canonical(body).encode("utf-8")).hexdigest()


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_json(path, obj):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")


def get_dotted(obj, key):
    cur = obj
    for part in key.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            raise DevflowError(f"config key not found: {key}")
    return cur


# ----------------------------------------------------------------------------- config

def load_config(root: Path) -> dict:
    path = root / CONFIG_REL
    if not path.exists():
        raise DevflowError(f"{CONFIG_REL} not found in {root} — run the devflow:setup-repo skill")
    cfg = load_json(path)
    cfg.setdefault("branches", {})
    cfg["branches"].setdefault("dev", "develop")
    cfg["branches"].setdefault("prod", "main")
    cfg["branches"].setdefault("feature_prefix", "feature/AB")
    states = dict(DEFAULT_STATES)
    states.update(cfg.get("states", {}))
    cfg["states"] = states
    cfg.setdefault("review", {})
    cfg["review"].setdefault("max_rounds", 3)
    for lvl, eff in (("task", "medium"), ("dev", "medium"), ("prod", "high")):
        cfg["review"].setdefault(lvl, {})
        cfg["review"][lvl].setdefault("effort", eff)
    cfg.setdefault("gate", {"slots": []})
    cfg["gate"].setdefault("exclude", DEFAULT_EXCLUDE)
    cfg.setdefault("limits", {"max_tasks_per_story": 5, "max_changed_lines_per_story": 400,
                              "max_changed_lines_per_task": 150})
    return cfg


def level_for_base(cfg, base_branch: str):
    b = base_branch.replace("refs/heads/", "")
    if b.startswith("origin/"):
        b = b[len("origin/"):]
    if b == cfg["branches"]["dev"]:
        return "dev"
    if b == cfg["branches"]["prod"]:
        return "prod"
    return None


# ----------------------------------------------------------------------------- diff

def merge_base(root, base_ref):
    p = _run(["git", "merge-base", base_ref, "HEAD"], cwd=root, check=False)
    if p.returncode != 0:
        raise DevflowError(f"cannot find merge-base with {base_ref} (fetch it first: git fetch origin)")
    return p.stdout.strip()


def language_of(path: str):
    low = path.lower()
    for lang, exts in LANG_EXT.items():
        if low.endswith(exts):
            return lang
    return None


DEFAULT_EXCLUDE = [".devflow/*"]


def diff_stats(root, base_sha, head="HEAD", exclude=None):
    exclude = DEFAULT_EXCLUDE if exclude is None else exclude
    out = git(["diff", "--numstat", "--no-renames", f"{base_sha}..{head}"], cwd=root)
    status = git(["diff", "--name-status", "--no-renames", f"{base_sha}..{head}"], cwd=root)
    deleted = {ln.split("\t", 1)[1] for ln in status.splitlines() if ln.startswith("D\t")}
    files, ins, dels = [], 0, 0
    for ln in out.splitlines():
        parts = ln.split("\t")
        if len(parts) != 3:
            continue
        a, d, f = parts
        a = 0 if a == "-" else int(a)
        d = 0 if d == "-" else int(d)
        ins += a
        dels += d
        if any(fnmatch.fnmatch(f, g) for g in exclude):
            continue
        files.append({"path": f, "insertions": a, "deletions": d,
                      "language": language_of(f), "deleted": f in deleted})
    langs = sorted({f["language"] for f in files if f["language"] and not f["deleted"]})
    return {"base_sha": base_sha, "head_sha": git(["rev-parse", head], cwd=root),
            "files": files, "insertions": ins, "deletions": dels,
            "changed_lines": ins + dels, "languages": langs}


# ----------------------------------------------------------------------------- gate

def _slot_applies(slot, stats):
    when = slot.get("when", "always")
    if when == "always":
        return True, [f["path"] for f in stats["files"] if not f["deleted"]]
    langs = set(when.get("languages", []))
    globs = when.get("paths", [])
    hit = []
    for f in stats["files"]:
        if f["deleted"]:
            continue
        if f["language"] in langs or any(fnmatch.fnmatch(f["path"], g) or
                                          fnmatch.fnmatch(os.path.basename(f["path"]), g) for g in globs):
            hit.append(f["path"])
    return bool(hit), hit


def run_gate(root, cfg, base_sha, stats=None, only=None):
    stats = stats or diff_stats(root, base_sha, exclude=cfg["gate"]["exclude"])
    results = []
    for slot in cfg["gate"].get("slots", []):
        name = slot["name"]
        if only and name not in only:
            continue
        applies, files = _slot_applies(slot, stats)
        if not applies:
            results.append({"name": name, "status": "skipped", "reason": "no matching changes"})
            continue
        cmd = slot["run"].replace("{base}", base_sha).replace(
            "{files}", " ".join(shlex.quote(f) for f in files))
        tool = slot.get("tool") or shlex.split(slot["run"])[0]
        if shutil.which(tool) is None:
            status = "skipped" if slot.get("optional") else "fail"
            results.append({"name": name, "status": status, "command": cmd,
                            "reason": f"tool not installed: {tool}"})
            continue
        t0 = time.time()
        try:
            p = _run(cmd, cwd=root, check=False, shell=True, timeout=slot.get("timeout", 900))
            code, out = p.returncode, (p.stdout + "\n" + p.stderr).strip()
        except subprocess.TimeoutExpired:
            code, out = 124, "timed out"
        tail = "\n".join(out.splitlines()[-40:])
        results.append({"name": name, "status": "pass" if code == 0 else "fail", "command": cmd,
                        "exit_code": code, "duration_s": round(time.time() - t0, 1), "output_tail": tail})
    passed = all(r["status"] in ("pass", "skipped") for r in results)
    return {"passed": passed, "slots": results}


# ----------------------------------------------------------------------------- review

def _reports_for(rdir: Path, branch=None, level=None):
    out = []
    for p in rdir.glob("*.json"):
        if p.name.startswith("draft-"):
            continue
        try:
            r = load_json(p)
        except Exception:
            continue
        if r.get("schema") != REPORT_SCHEMA:
            continue
        if branch and r.get("branch") != branch:
            continue
        if level and r.get("level") != level:
            continue
        out.append((p, r))
    out.sort(key=lambda x: x[1].get("created_at", ""))
    return out


def _is_ancestor(root, a, b="HEAD"):
    return _run(["git", "merge-base", "--is-ancestor", a, b], cwd=root, check=False).returncode == 0


def review_start(root, cfg, level, base_ref, story=None, task=None, context_file=None, since=None,
                 skip_gate=False, escalation_ack=None):
    if level not in LEVELS:
        raise DevflowError(f"level must be one of {LEVELS}")
    dirty = git(["status", "--porcelain", "--untracked-files=no"], cwd=root)
    if dirty:
        raise DevflowError("working tree has uncommitted changes — commit them first; a review covers a commit")
    branch = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=root)
    head = git(["rev-parse", "HEAD"], cwd=root)
    base_sha = merge_base(root, base_ref) if level != "task" else git(["rev-parse", base_ref], cwd=root)
    rdir = reviews_dir(root)

    prior = _reports_for(rdir, branch=branch, level=level)
    # rounds since the last PASS on this branch+level
    fails = []
    for _, r in reversed(prior):
        if r.get("verdict") == "PASS":
            break
        fails.append(r)
        if r.get("escalation_ack"):
            break
    if level != "task" and len(fails) >= cfg["review"]["max_rounds"] and not escalation_ack:
        raise DevflowError(
            f"ESCALATE: {len(fails)} failed {level} review rounds on {branch}. "
            "Stop creating fix tasks — this Story needs a human conversation (author + Tech Lead). "
            "After that conversation, the next round can be started with --escalation-ack \"<who agreed what>\"; "
            "the acknowledgement is shown in the PR review table.")
    previous = fails[0] if fails else None
    if since is None and previous and _is_ancestor(root, previous["head_sha"]) and previous["head_sha"] != head:
        since = previous["head_sha"]

    ex = cfg["gate"]["exclude"]
    stats = diff_stats(root, base_sha, exclude=ex)
    review_base = since or base_sha
    review_stats = diff_stats(root, review_base, exclude=ex) if since else stats
    diff_text = git(["diff", "--no-renames", "-U5", f"{review_base}..HEAD", "--", "."]
                    + [f":(exclude){g}" for g in ex], cwd=root)
    log_text = git(["log", "--format=%h %s%n%b", f"{base_sha}..HEAD"], cwd=root)

    gate = {"passed": True, "slots": [], "skipped": True} if skip_gate else run_gate(root, cfg, base_sha, stats)
    rcfg = cfg["review"].get(level, {})
    draft = {
        "schema": REPORT_SCHEMA,
        "devflow_version": DEVFLOW_VERSION,
        "level": level,
        "repo": git(["config", "--get", "remote.origin.url"], cwd=root, check=False) or root.name,
        "branch": branch,
        "base_ref": base_ref,
        "base_sha": base_sha,
        "head_sha": head,
        "review_scope_base": review_base,
        "story_id": story,
        "task_id": task,
        "round": len(fails) + 1,
        "created_at": None,
        "reviewer": {"tool": rcfg.get("tool") or "current-ai", "model": rcfg.get("model") or "session-default",
                     "effort": rcfg.get("effort"), "mode": "cli" if rcfg.get("command") else "in-session"},
        "implementer": (cfg.get("implementer") or {}).get("tool") or "current-ai",
        "diff": {"files": len(stats["files"]), "insertions": stats["insertions"],
                 "deletions": stats["deletions"], "languages": stats["languages"],
                 "reviewed_files": [f["path"] for f in review_stats["files"]]},
        "gate": gate,
        "summary": "",
        "acceptance_criteria": [],
        "findings": [],
        "previous_findings": (previous or {}).get("findings", []),
        "escalation_ack": escalation_ack,
        "verdict": None,
        "blocking_open": None,
    }
    lim = cfg["limits"]
    warnings = []
    if level in ("dev", "prod") and stats["changed_lines"] > lim.get("max_changed_lines_per_story", 10**9):
        warnings.append(f"Story diff is {stats['changed_lines']} changed lines (limit "
                        f"{lim['max_changed_lines_per_story']}). Flag 'scope' finding: Story probably too large.")
    if level == "task" and stats["changed_lines"] > lim.get("max_changed_lines_per_task", 10**9):
        warnings.append(f"Task diff is {stats['changed_lines']} changed lines (limit "
                        f"{lim['max_changed_lines_per_task']}).")
    draft["warnings"] = warnings

    stem = f"draft-{level}"
    draft_path = rdir / f"{stem}.json"
    diff_path = rdir / f"{stem}.diff"
    prompt_path = rdir / f"{stem}.prompt.md"
    save_json(draft_path, draft)
    diff_path.write_text(diff_text, encoding="utf-8")

    rubric = ""
    rp = Path(__file__).resolve().parent.parent / "references" / "review-rubric.md"
    if rp.exists():
        rubric = rp.read_text(encoding="utf-8")
    ctx = Path(context_file).read_text(encoding="utf-8") if context_file else "(no work-item context supplied)"
    prev = json.dumps(draft["previous_findings"], indent=2) if draft["previous_findings"] else "none"
    gate_lines = "\n".join(f"- {s['name']}: {s['status']}" + (f" ({s.get('reason')})" if s.get("reason") else "")
                           for s in gate["slots"]) or "- (gate skipped)"
    prompt = f"""# devflow review — level: {level} (reasoning effort: {rcfg.get('effort')})

You are reviewing AI-assisted code before it moves on. Be specific and skeptical.
Return ONLY a JSON object matching the schema in the rubric (no prose around it).

## Work item context
{ctx}

## Scope
- Branch: {branch}
- Commits under review:
{log_text or '(none)'}
- Files in scope: {', '.join(draft['diff']['reviewed_files']) or '(none)'}
- Size warnings: {'; '.join(warnings) or 'none'}

## Deterministic gate results (already run — do not re-run)
{gate_lines}

## Findings from the previous round on this branch (mark each resolved or still open)
{prev}

## Diff
The full diff is in: {diff_path}

{rubric}
"""
    prompt_path.write_text(prompt, encoding="utf-8")
    return {"draft": str(draft_path), "diff": str(diff_path), "prompt": str(prompt_path),
            "gate_passed": gate["passed"], "round": draft["round"], "warnings": warnings,
            "review_scope_base": review_base, "head_sha": head}


def _normalize_findings(raw):
    if isinstance(raw, list):
        raw = {"findings": raw}
    out = []
    for i, f in enumerate(raw.get("findings", []), 1):
        sev = str(f.get("severity", "medium")).lower()
        if sev not in SEVERITIES:
            sev = "medium"
        cat = str(f.get("category", "other")).lower()
        if cat not in CATEGORIES:
            cat = "other"
        blocking = bool(f.get("blocking", False)) or (sev, cat) in FORCED_BLOCKING
        status = str(f.get("status", "open")).lower()
        if status not in ("open", "resolved", "dismissed"):
            status = "open"
        if blocking and status == "dismissed":
            # a reviewer cannot wave through its own blocking finding
            status = "open"
        out.append({"id": f.get("id") or f"F{i}", "severity": sev, "category": cat, "blocking": blocking,
                    "file": f.get("file", ""), "line": f.get("line"), "title": str(f.get("title", "")).strip(),
                    "detail": str(f.get("detail", "")).strip(), "status": status,
                    "resolution": str(f.get("resolution", "")).strip()})
    acs = []
    for a in raw.get("acceptance_criteria", []):
        acs.append({"criterion": str(a.get("criterion", "")).strip(), "met": bool(a.get("met", False)),
                    "evidence": str(a.get("evidence", "")).strip()})
    return str(raw.get("summary", "")).strip(), acs, out


def review_finalize(root, cfg, draft_path, findings_path, reviewer_override=None):
    draft = load_json(draft_path)
    head = git(["rev-parse", "HEAD"], cwd=root)
    if draft["head_sha"] != head:
        raise DevflowError("HEAD moved since `review start` — start the review again")
    summary, acs, findings = _normalize_findings(load_json(findings_path))
    # an acceptance criterion that is not met is a blocking finding (dev/prod only)
    if draft["level"] in ("dev", "prod"):
        for a in acs:
            if not a["met"]:
                findings.append({"id": f"AC{len(findings) + 1}", "severity": "high", "category": "acceptance",
                                 "blocking": True, "file": "", "line": None,
                                 "title": f"Acceptance criterion not met: {a['criterion'][:80]}",
                                 "detail": a["evidence"], "status": "open", "resolution": ""})
    report = dict(draft)
    report.pop("previous_findings", None)
    if reviewer_override:
        report["reviewer"].update(reviewer_override)
    report["summary"] = summary
    report["acceptance_criteria"] = acs
    report["findings"] = findings
    blocking_open = sum(1 for f in findings if f["blocking"] and f["status"] == "open")
    report["blocking_open"] = blocking_open
    report["verdict"] = "PASS" if (draft["gate"]["passed"] and blocking_open == 0) else "FAIL"
    report["created_at"] = now_iso()
    report["digest"] = digest_of(report)
    out = reviews_dir(root) / f"{head}-{draft['level']}.json"
    save_json(out, report)
    return out, report


ICON = {"pass": "✅", "fail": "❌", "skipped": "⏭️"}


def _cell(s):
    return str(s if s is not None else "").replace("|", "\\|").replace("\n", " ").strip()


def render_block(report: dict) -> str:
    lv = report["level"]
    rv = report["reviewer"]
    gate = report["gate"]
    gate_cells = " ".join(f"{ICON.get(s['status'], '?')} {s['name']}" for s in gate.get("slots", [])) or "—"
    lines = [
        BLOCK_BEGIN,
        f"### devflow review · {lv} · {'✅ PASS' if report['verdict'] == 'PASS' else '❌ FAIL'}",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Reviewed commit | `{report['head_sha']}` |",
        f"| Base | `{_cell(report['base_ref'])}` (`{report['base_sha'][:12]}`) |",
        f"| Story / Task | {('AB#' + str(report['story_id'])) if report.get('story_id') else '—'}"
        f" / {('AB#' + str(report['task_id'])) if report.get('task_id') else '—'} |",
        f"| Round | {report['round']} |",
        f"| Reviewer | {_cell(rv.get('tool'))} · {_cell(rv.get('model'))} · effort {_cell(rv.get('effort'))}"
        f" · {_cell(rv.get('mode'))} |",
        f"| Implementer | {_cell(report.get('implementer'))} |",
        f"| Diff | {report['diff']['files']} files, +{report['diff']['insertions']} / "
        f"-{report['diff']['deletions']} ({', '.join(report['diff']['languages']) or '—'}) |",
        f"| Deterministic gate | {gate_cells} |",
        f"| Blocking findings open | {report['blocking_open']} |",
    ]
    if report.get("escalation_ack"):
        lines.append(f"| Escalation acknowledged | {_cell(report['escalation_ack'])} |")
    lines += [
        f"| Reviewed at | {report['created_at']} |",
        "",
    ]
    if report.get("summary"):
        lines += [f"**Summary:** {_cell(report['summary'])}", ""]
    if report.get("acceptance_criteria"):
        lines += ["**Acceptance criteria**", "", "| Criterion | Met | Evidence |", "|---|---|---|"]
        for a in report["acceptance_criteria"]:
            lines.append(f"| {_cell(a['criterion'])} | {'✅' if a['met'] else '❌'} | {_cell(a['evidence'])} |")
        lines.append("")
    lines += ["**Findings**", ""]
    if report["findings"]:
        lines += ["| # | Severity | Blocking | Category | Location | Finding | Status |",
                  "|---|---|---|---|---|---|---|"]
        for f in report["findings"]:
            loc = f"{f['file']}:{f['line']}" if f.get("line") else (f["file"] or "—")
            text = f["title"] + (f" — {f['detail']}" if f["detail"] else "")
            if f.get("resolution"):
                text += f" _(resolution: {f['resolution']})_"
            lines.append(f"| {f['id']} | {f['severity']} | {'yes' if f['blocking'] else 'no'} | {f['category']}"
                         f" | `{_cell(loc)}` | {_cell(text)} | {f['status']} |")
    else:
        lines.append("_No findings._")
    if report.get("warnings"):
        lines += ["", "**Warnings:** " + "; ".join(_cell(w) for w in report["warnings"])]
    payload = base64.b64encode(canonical(report).encode("utf-8")).decode("ascii")
    lines += ["", f"<sub>devflow {report['devflow_version']} · digest `{report['digest']}`</sub>",
              f"<!-- devflow:report:{payload} -->", BLOCK_END]
    return "\n".join(lines)


def find_report(root, sha, level):
    p = reviews_dir(root) / f"{sha}-{level}.json"
    return (p, load_json(p)) if p.exists() else (None, None)


def report_ok(report, sha, level):
    return (report is not None and report.get("schema") == REPORT_SCHEMA and report.get("head_sha") == sha
            and report.get("level") == level and report.get("verdict") == "PASS"
            and report.get("digest") == digest_of(report))


# ----------------------------------------------------------------------------- PR body

def devtest_checklist(acs):
    lines = [DEVTEST_BEGIN, "### Dev testing (author confirms — every box must be ticked)", ""]
    for a in acs or []:
        lines.append(f"- [ ] Verified in dev: {a}")
    lines += ["- [ ] Tested on the dev environment (not only locally)",
              "- [ ] Evidence attached below (screenshots, request/response, logs)", "",
              "**Evidence:**", "", DEVTEST_END]
    return "\n".join(lines)


def compose_pr_body(report, story_id, summary, checklist=None):
    parts = [f"Story: AB#{story_id}", "", summary.strip(), ""]
    if checklist:
        parts += [checklist, ""]
    parts.append(render_block(report))
    return "\n".join(parts).strip() + "\n"


def _norm(s):
    return "\n".join(ln.rstrip() for ln in s.replace("\r\n", "\n").replace("\r", "\n").split("\n")).strip()


def verify_pr_body(body, head_sha, base_branch, cfg):
    errs = []
    body = body or ""
    level = level_for_base(cfg, base_branch)
    if level is None:
        return [], None  # not a protected base: nothing to enforce
    if not re.search(r"AB#\d+", body):
        errs.append("PR body must reference the Story as AB#<id>")
    b = body.replace("\r\n", "\n")
    if b.count(BLOCK_BEGIN) != 1 or b.count(BLOCK_END) != 1:
        errs.append("PR body must contain exactly one devflow review block — run the devflow:review-gate skill")
        return errs, level
    block = b[b.index(BLOCK_BEGIN): b.index(BLOCK_END) + len(BLOCK_END)]
    m = REPORT_RE.search(block)
    if not m:
        errs.append("review block has no embedded report")
        return errs, level
    try:
        report = json.loads(base64.b64decode(m.group(1)).decode("utf-8"))
    except Exception:
        errs.append("embedded report is not valid")
        return errs, level
    if report.get("digest") != digest_of(report):
        errs.append("embedded report digest does not match its contents (report was edited)")
    if _norm(render_block(report)) != _norm(block):
        errs.append("review table does not match the embedded report (table was edited by hand)")
    if report.get("head_sha") != head_sha:
        errs.append(f"review covers {str(report.get('head_sha'))[:12]} but the PR head is {head_sha[:12]} — "
                    "commits were pushed after the review; re-run the review")
    if report.get("level") != level:
        errs.append(f"PRs into {base_branch} need a '{level}' review; found '{report.get('level')}'")
    if report.get("verdict") != "PASS":
        errs.append("review verdict is FAIL")
    if report.get("blocking_open"):
        errs.append(f"{report.get('blocking_open')} blocking finding(s) still open")
    if level == "prod":
        if DEVTEST_BEGIN not in b or DEVTEST_END not in b:
            errs.append("prod PR must contain the dev-testing checklist (devflow:promote-to-prod)")
        else:
            sec = b[b.index(DEVTEST_BEGIN): b.index(DEVTEST_END)]
            boxes = re.findall(r"^\s*[-*] \[( |x|X)\]", sec, flags=re.M)
            if not boxes:
                errs.append("dev-testing checklist has no items")
            elif any(x == " " for x in boxes):
                errs.append("dev-testing checklist has unticked items — the author must confirm dev testing")
    return errs, level


# ----------------------------------------------------------------------------- Azure DevOps

def _ado_env(cfg):
    ado = cfg.get("ado", {})
    org = os.environ.get("ADO_ORG_URL") or ado.get("organization")
    proj = os.environ.get("ADO_PROJECT") or ado.get("project")
    pat = os.environ.get("ADO_PAT") or os.environ.get("AZURE_DEVOPS_EXT_PAT")
    if not (org and proj and pat):
        raise DevflowError("Azure DevOps not configured: need ado.organization, ado.project and a PAT "
                           "(AZURE_DEVOPS_EXT_PAT locally, ADO_PAT secret in CI)")
    return org.rstrip("/"), proj, pat


def _ado(cfg, method, path, body=None, content_type="application/json"):
    org, proj, pat = _ado_env(cfg)
    url = f"{org}/{urllib.request.quote(proj)}/_apis/{path}"
    url += ("&" if "?" in url else "?") + "api-version=7.1"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Basic " + base64.b64encode(f":{pat}".encode()).decode())
    req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raise DevflowError(f"Azure DevOps {method} {path}: HTTP {e.code} {e.read().decode()[:400]}")


def _logical(cfg, actual):
    for k, v in cfg["states"].items():
        if v.lower() == str(actual).lower():
            return k
    return None


def story_get(cfg, wid):
    w = _ado(cfg, "GET", f"wit/workitems/{int(wid)}")
    f = w.get("fields", {})
    return {"id": w.get("id"), "type": f.get("System.WorkItemType"), "state": f.get("System.State"),
            "title": f.get("System.Title"), "assigned_to": (f.get("System.AssignedTo") or {}).get("uniqueName")}


def story_transition(cfg, wid, to_logical, comment=None, allow_noop=True):
    if to_logical not in cfg["states"]:
        raise DevflowError(f"unknown state key '{to_logical}' (use one of {sorted(cfg['states'])})")
    item = story_get(cfg, wid)
    cur = _logical(cfg, item["state"])
    table = TASK_TRANSITIONS if item["type"] == "Task" else STORY_TRANSITIONS
    if cur == to_logical:
        if allow_noop:
            return {"id": item["id"], "from": item["state"], "to": item["state"], "changed": False}
    if cur is None or to_logical not in table.get(cur, set()):
        raise DevflowError(f"refused: AB#{wid} ({item['type']}) is '{item['state']}'; "
                           f"'{cfg['states'][to_logical]}' is not an allowed next state. "
                           "devflow never skips states.")
    ops = [{"op": "add", "path": "/fields/System.State", "value": cfg["states"][to_logical]}]
    if comment:
        ops.append({"op": "add", "path": "/fields/System.History", "value": comment})
    _ado(cfg, "PATCH", f"wit/workitems/{int(wid)}", ops, "application/json-patch+json")
    return {"id": item["id"], "from": item["state"], "to": cfg["states"][to_logical], "changed": True}


def story_comment(cfg, wid, text):
    _ado(cfg, "PATCH", f"wit/workitems/{int(wid)}",
         [{"op": "add", "path": "/fields/System.History", "value": text}], "application/json-patch+json")


STORY_RE = re.compile(r"(?:feature/AB|AB#)(\d+)")


def story_id_from(text):
    m = re.search(r"Story:\s*AB#(\d+)", text or "") or STORY_RE.search(text or "")
    return int(m.group(1)) if m else None


def board_sync(cfg, root, event, body="", branch="", pr_url=""):
    results = []
    if event == "deployed-prod":
        merges = git(["log", "--merges", "-n", "500", "--format=%s%n%b"], cwd=root)
        ids = sorted({int(x) for x in re.findall(r"feature/AB(\d+)", merges)})
        for wid in ids:
            try:
                item = story_get(cfg, wid)
                if _logical(cfg, item["state"]) == "awaiting_deployment":
                    results.append(story_transition(cfg, wid, "closed", "Deployed to production by the pipeline."))
            except DevflowError as e:
                results.append({"id": wid, "error": str(e)})
        return results
    wid = story_id_from(body) or story_id_from(branch)
    if not wid:
        return [{"error": "no Story id found in PR body or branch"}]
    target, note = {
        "pr-merged-dev": ("dev_testing", f"Merged into dev and deploying to the dev environment. {pr_url}"),
        "pr-opened-prod": ("code_review_prod", f"Production PR opened. {pr_url}"),
        "pr-merged-prod": ("awaiting_deployment", f"Merged into prod branch; awaiting deployment approval. {pr_url}"),
    }[event]
    try:
        results.append(story_transition(cfg, wid, target, note))
    except DevflowError as e:
        results.append({"id": wid, "error": str(e)})
    return results


# ----------------------------------------------------------------------------- hook: guard

SEP_RE = re.compile(r"\s*(?:&&|\|\||;|\||\n)\s*")


def _split_segments(cmd):
    # crude but safe: split on shell separators outside of quotes
    segs, buf, q = [], [], None
    i = 0
    while i < len(cmd):
        c = cmd[i]
        if q:
            buf.append(c)
            if c == q:
                q = None
        elif c in ("'", '"'):
            q = c
            buf.append(c)
        elif cmd.startswith("&&", i) or cmd.startswith("||", i):
            segs.append("".join(buf)); buf = []; i += 2; continue
        elif c in (";", "|", "\n"):
            segs.append("".join(buf)); buf = []
        else:
            buf.append(c)
        i += 1
    segs.append("".join(buf))
    return [s.strip() for s in segs if s.strip()]


def _tokens(seg):
    try:
        t = shlex.split(seg)
    except ValueError:
        t = seg.split()
    # drop env assignments and common wrappers
    while t and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t[0]) or t[0] in ("env", "command", "exec", "time", "sudo")):
        t = t[1:]
    return t


def _opt(tokens, *names):
    for i, t in enumerate(tokens):
        for n in names:
            if t == n and i + 1 < len(tokens):
                return tokens[i + 1]
            if n.startswith("--") and t.startswith(n + "="):
                return t.split("=", 1)[1]
    return None


def _deny(reason):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}))
    return 0


def guard_decide(command, cwd):
    """Return a deny reason, or None to allow."""
    cur = cwd
    for seg in _split_segments(command):
        t = _tokens(seg)
        if not t:
            continue
        if t[0] == "cd" and len(t) > 1:
            nxt = Path(os.path.expanduser(t[1]))
            cur = str(nxt if nxt.is_absolute() else Path(cur) / nxt)
            continue
        here = cur
        if t[0] == "git" and len(t) > 2 and t[1] == "-C":
            here = str(Path(cur) / t[2]); t = ["git"] + t[3:]
        try:
            root = repo_root(here)
        except DevflowError:
            continue
        if not (root / CONFIG_REL).exists():
            continue
        cfg = load_config(root)
        dev, prod = cfg["branches"]["dev"], cfg["branches"]["prod"]

        # --- gh pr create
        if t[:3] == ["gh", "pr", "create"]:
            base = _opt(t, "--base", "-B")
            if not base:
                return (f"devflow: `gh pr create` needs an explicit --base ({dev} for Code Review - Dev, "
                        f"{prod} for Code Review - Prod). Use the devflow:ship-to-dev or devflow:promote-to-prod skill.")
            level = level_for_base(cfg, base)
            if level is None:
                continue
            head_ref = _opt(t, "--head", "-H")
            sha = git(["rev-parse", head_ref or "HEAD"], cwd=root, check=False) or ""
            _, rep = find_report(root, sha, level)
            if not report_ok(rep, sha, level):
                return (f"devflow: no passing '{level}' review for commit {sha[:12]}. Run the devflow:review-gate "
                        f"skill (level {level}) first — the review is mandatory for every PR into {base}.")
            body_file = _opt(t, "--body-file", "-F")
            if not body_file:
                return ("devflow: create the PR with --body-file produced by `devflow.py pr-body` so the review "
                        "table is included.")
            bf = Path(body_file) if Path(body_file).is_absolute() else Path(here) / body_file
            try:
                body = bf.read_text(encoding="utf-8")
            except OSError:
                return f"devflow: cannot read PR body file {body_file}"
            errs, _ = verify_pr_body(body, sha, base, cfg)
            # the dev-testing boxes are ticked by the author on GitHub after the PR is open
            errs = [e for e in errs if "unticked" not in e]
            if errs:
                return "devflow: PR body is not valid — " + "; ".join(errs)
            continue

        # --- PRs created through the raw API
        if t[:2] == ["gh", "api"] and any("pulls" in x for x in t) and (
                any(x in ("-f", "-F", "--field", "--raw-field", "--input") for x in t)
                or (_opt(t, "-X", "--method") or "").upper() == "POST"):
            return "devflow: create pull requests with the devflow skills (gh pr create), not the raw API."

        # --- git push
        if t[0] == "git" and "push" in t[1:]:
            args = t[t.index("push") + 1:]
            if any(a in ("--all", "--mirror") for a in args):
                return "devflow: `git push --all/--mirror` is not allowed in a devflow repo."
            pos = [a for a in args if not a.startswith("-")]
            # drop values of options that take one
            refspecs = pos[1:] if pos else []
            targets = []
            if not refspecs:
                b = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=root, check=False)
                targets.append(b)
            for r in refspecs:
                r = r.lstrip("+")
                dst = r.split(":", 1)[1] if ":" in r else r
                if dst == "HEAD":
                    dst = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=root, check=False)
                targets.append(dst.replace("refs/heads/", ""))
            hit = [x for x in targets if x in (dev, prod)]
            if hit:
                return (f"devflow: direct pushes to {', '.join(hit)} are not allowed. Push your feature branch and "
                        "open a PR through devflow:ship-to-dev or devflow:promote-to-prod.")
    return None


def cmd_guard():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    if data.get("tool_name") != "Bash":
        return 0
    command = (data.get("tool_input") or {}).get("command", "")
    if not re.search(r"\b(gh|git)\b", command):
        return 0
    try:
        reason = guard_decide(command, data.get("cwd") or os.getcwd())
    except Exception as e:  # fail closed only for the commands we police
        if re.search(r"gh\s+pr\s+create|git\s+push|gh\s+api", command):
            reason = f"devflow guard could not verify this command ({e}). Fix the problem or ask your Tech Lead."
        else:
            return 0
    return _deny(reason) if reason else 0


def cmd_session_context():
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    try:
        root = repo_root(data.get("cwd") or os.getcwd())
    except DevflowError:
        return 0
    if not (root / CONFIG_REL).exists():
        return 0
    cfg = load_config(root)
    notes = [
        f"This repository uses the devflow workflow (config: {CONFIG_REL}).",
        f"Pull requests into {cfg['branches']['dev']} and {cfg['branches']['prod']} require a passing devflow "
        "review report for the head commit; the devflow hook blocks `gh pr create` and direct pushes to those "
        "branches without one.",
        "The devflow:review-gate skill produces that report; devflow:start-here lists the workflow entry points.",
    ]
    repo_copy = root / ".devflow" / "devflow.py"
    if repo_copy.exists():
        m = re.search(r'DEVFLOW_VERSION = "([^"]+)"', repo_copy.read_text(encoding="utf-8", errors="ignore"))
        if m and m.group(1) != DEVFLOW_VERSION:
            notes.append(f"The repo's .devflow/devflow.py is version {m.group(1)} but the plugin is "
                         f"{DEVFLOW_VERSION}; CI and local checks may differ until devflow:setup-repo updates it.")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                             "additionalContext": " ".join(notes)}}))
    return 0


# ----------------------------------------------------------------------------- install-repo

def install_repo(target: Path, force=False):
    plugin_root = Path(__file__).resolve().parent.parent
    tpl = plugin_root / "templates" / "repo"
    written, skipped = [], []
    for src in tpl.rglob("*"):
        if src.is_dir():
            continue
        rel = src.relative_to(tpl)
        dst = target / rel
        if dst.exists() and not force:
            skipped.append(str(rel)); continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst); written.append(str(rel))
    dst = target / ".devflow" / "devflow.py"
    if not dst.exists() or force or dst.read_bytes() != Path(__file__).read_bytes():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(Path(__file__), dst); written.append(".devflow/devflow.py")
    return {"written": written, "skipped_existing": skipped}


# ----------------------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(prog="devflow")
    ap.add_argument("--repo", default=None, help="path inside the repo (default: cwd)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("version")
    c = sub.add_parser("config"); c.add_argument("--get")
    d = sub.add_parser("diff-stats"); d.add_argument("--base", required=True)
    g = sub.add_parser("gate"); g.add_argument("--base", required=True); g.add_argument("--out")
    g.add_argument("--only", nargs="*")

    r = sub.add_parser("review"); rs = r.add_subparsers(dest="rcmd", required=True)
    s = rs.add_parser("start"); s.add_argument("--level", required=True, choices=LEVELS)
    s.add_argument("--base", required=True); s.add_argument("--story"); s.add_argument("--task")
    s.add_argument("--context-file"); s.add_argument("--since"); s.add_argument("--skip-gate", action="store_true")
    s.add_argument("--escalation-ack", help="who agreed what after an ESCALATE (shown in the PR table)")
    f = rs.add_parser("finalize"); f.add_argument("--level", required=True, choices=LEVELS)
    f.add_argument("--findings", required=True); f.add_argument("--reviewer-model"); f.add_argument("--reviewer-tool")
    rr = rs.add_parser("render"); rr.add_argument("--report", required=True)
    ck = rs.add_parser("check"); ck.add_argument("--level", required=True, choices=LEVELS); ck.add_argument("--sha")
    lt = rs.add_parser("latest"); lt.add_argument("--level", required=True, choices=LEVELS)

    pb = sub.add_parser("pr-body"); pb.add_argument("--level", required=True, choices=("dev", "prod"))
    pb.add_argument("--story", required=True); pb.add_argument("--summary-file", required=True)
    pb.add_argument("--acceptance-file", help="one acceptance criterion per line (prod checklist)")
    pb.add_argument("--out", required=True)

    vp = sub.add_parser("verify-pr"); vp.add_argument("--body-file", required=True)
    vp.add_argument("--head-sha", required=True); vp.add_argument("--base", required=True)

    st = sub.add_parser("story"); sts = st.add_subparsers(dest="scmd", required=True)
    sg = sts.add_parser("get"); sg.add_argument("--id", required=True)
    stt = sts.add_parser("transition"); stt.add_argument("--id", required=True); stt.add_argument("--to", required=True)
    stt.add_argument("--comment")
    sc = sts.add_parser("comment"); sc.add_argument("--id", required=True); sc.add_argument("--text", required=True)

    bs = sub.add_parser("board-sync")
    bs.add_argument("event", choices=("pr-merged-dev", "pr-opened-prod", "pr-merged-prod", "deployed-prod"))
    bs.add_argument("--body-file"); bs.add_argument("--branch", default=""); bs.add_argument("--pr-url", default="")

    sub.add_parser("guard"); sub.add_parser("session-context")
    ir = sub.add_parser("install-repo"); ir.add_argument("--target", required=True)
    ir.add_argument("--force", action="store_true")

    a = ap.parse_args(argv)
    try:
        if a.cmd == "version":
            print(DEVFLOW_VERSION); return 0
        if a.cmd == "guard":
            return cmd_guard()
        if a.cmd == "session-context":
            return cmd_session_context()
        if a.cmd == "install-repo":
            print(json.dumps(install_repo(Path(a.target).resolve(), a.force), indent=2)); return 0

        root = repo_root(a.repo)
        cfg = load_config(root)
        if a.cmd == "config":
            print(json.dumps(get_dotted(cfg, a.get) if a.get else cfg, indent=2)); return 0
        if a.cmd == "diff-stats":
            print(json.dumps(diff_stats(root, merge_base(root, a.base), exclude=cfg["gate"]["exclude"]),
                             indent=2)); return 0
        if a.cmd == "gate":
            res = run_gate(root, cfg, merge_base(root, a.base), only=a.only)
            if a.out:
                save_json(a.out, res)
            for sl in res["slots"]:
                print(f"{ICON.get(sl['status'], '?')} {sl['name']}: {sl['status']}"
                      + (f" — {sl.get('reason')}" if sl.get("reason") else ""))
                if sl["status"] == "fail" and sl.get("output_tail"):
                    print("    " + sl["output_tail"].replace("\n", "\n    "))
            print("GATE:", "PASS" if res["passed"] else "FAIL")
            return 0 if res["passed"] else 1
        if a.cmd == "review":
            if a.rcmd == "start":
                print(json.dumps(review_start(root, cfg, a.level, a.base, a.story, a.task, a.context_file,
                                              a.since, a.skip_gate, a.escalation_ack), indent=2)); return 0
            if a.rcmd == "finalize":
                ov = {k: v for k, v in (("model", a.reviewer_model), ("tool", a.reviewer_tool)) if v}
                path, rep = review_finalize(root, cfg, reviews_dir(root) / f"draft-{a.level}.json", a.findings, ov)
                print(json.dumps({"report": str(path), "verdict": rep["verdict"],
                                  "blocking_open": rep["blocking_open"], "gate_passed": rep["gate"]["passed"],
                                  "round": rep["round"]}, indent=2))
                return 0 if rep["verdict"] == "PASS" else 1
            if a.rcmd == "render":
                print(render_block(load_json(a.report))); return 0
            if a.rcmd == "check":
                sha = a.sha or git(["rev-parse", "HEAD"], cwd=root)
                _, rep = find_report(root, sha, a.level)
                ok = report_ok(rep, sha, a.level)
                print("PASS" if ok else ("FAIL" if rep else "MISSING")); return 0 if ok else 1
            if a.rcmd == "latest":
                sha = git(["rev-parse", "HEAD"], cwd=root)
                p, _ = find_report(root, sha, a.level)
                if not p:
                    print("MISSING"); return 1
                print(p); return 0
        if a.cmd == "pr-body":
            sha = git(["rev-parse", "HEAD"], cwd=root)
            _, rep = find_report(root, sha, a.level)
            if not report_ok(rep, sha, a.level):
                raise DevflowError(f"no passing {a.level} review for HEAD {sha[:12]}")
            checklist = None
            if a.level == "prod":
                acs = []
                if a.acceptance_file:
                    acs = [ln.strip("-* \t") for ln in Path(a.acceptance_file).read_text(encoding="utf-8").splitlines()
                           if ln.strip()]
                checklist = devtest_checklist(acs)
            body = compose_pr_body(rep, a.story, Path(a.summary_file).read_text(encoding="utf-8"), checklist)
            Path(a.out).write_text(body, encoding="utf-8")
            print(a.out); return 0
        if a.cmd == "verify-pr":
            body = Path(a.body_file).read_text(encoding="utf-8")
            errs, level = verify_pr_body(body, a.head_sha, a.base, cfg)
            if level is None:
                print(f"base {a.base} is not protected by devflow — nothing to verify"); return 0
            for e in errs:
                print(f"::error title=devflow review::{e}")
            print("devflow review check:", "PASS" if not errs else "FAIL", f"(level {level})")
            return 0 if not errs else 1
        if a.cmd == "story":
            if a.scmd == "get":
                print(json.dumps(story_get(cfg, a.id), indent=2)); return 0
            if a.scmd == "transition":
                print(json.dumps(story_transition(cfg, a.id, a.to, a.comment), indent=2)); return 0
            if a.scmd == "comment":
                story_comment(cfg, a.id, a.text); print("ok"); return 0
        if a.cmd == "board-sync":
            body = Path(a.body_file).read_text(encoding="utf-8") if a.body_file else ""
            res = board_sync(cfg, root, a.event, body, a.branch, a.pr_url)
            print(json.dumps(res, indent=2))
            return 0
    except (DevflowError, OSError, json.JSONDecodeError) as e:
        print(f"devflow: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
