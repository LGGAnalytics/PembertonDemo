# Specs: spec-driven development with AI

Every change to the warehouse starts here. The AI agent reads `CLAUDE.md` and is not allowed to write code until a spec is **Approved**.

```
 spec.md (WHAT and WHY)  ──►  plan.md (HOW: files per layer)  ──►  tasks.md (checklist)  ──►  code + tests  ──►  make pipeline ✔
     human + AI                    AI, human reviews                   AI                         AI              evidence
```

| Spec | Title | Status |
|---|---|---|
| [001-net-leverage](001-net-leverage/spec.md) | Borrower net leverage (x EBITDA) | Draft, for approval during the demo |

How to start a new spec: copy `_template/spec.md` to `NNN-short-name/spec.md`.

Why work spec-first? The spec is the contract the business can read. The acceptance criteria become SQL tests, so "done" means the tests prove it.
