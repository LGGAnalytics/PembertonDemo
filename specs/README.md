# Specs: spec-driven development with AI

Every change to the warehouse starts here. The AI agent reads `CLAUDE.md` and is not allowed to write code until a spec is **Approved**.

```
 spec.md (WHAT and WHY)  ──►  plan.md (HOW: files per layer)  ──►  tasks.md (checklist)  ──►  code + tests  ──►  make pipeline ✔
     human + AI                    AI, human reviews                   AI                         AI              evidence
```

| Spec | Title | Status |
|---|---|---|
| [001-net-leverage](001-net-leverage/spec.md) | Borrower net leverage (x EBITDA) | Draft, for approval during the demo |
| [002-etl-run-framework](002-etl-run-framework/spec.md) | ETL run framework: audited, incremental, period-by-period loop with per-period rollback | **Done** — [plan](002-etl-run-framework/plan.md) · [tasks](002-etl-run-framework/tasks.md) |
| [003-position-cost-basis](003-position-cost-basis/spec.md) | Position cost basis, WA acquisition price and unrealised gain (3-stage temp tables, equity/debt branch) | Draft, depends on 002 — [plan](003-position-cost-basis/plan.md) |
| [004-effective-dated-ratings](004-effective-dated-ratings/spec.md) | Effective-dated external ratings stamped point-in-time with change-only update | Draft, depends on 002 — [plan](004-effective-dated-ratings/plan.md) |

How to start a new spec: copy `_template/spec.md` to `NNN-short-name/spec.md`.

Why work spec-first? The spec is the contract the business can read. The acceptance criteria become SQL tests, so "done" means the tests prove it.
