# Tasks 005: Gross IRR, Net IRR and MOIC per fund

One commit per Task (`AB#<TaskID>`); each passes the devflow task review before it is closed.

## 1/5 Generate fund-level fee, expense and LP cash-flow datasets — AB#673
- [x] 1.1 Generator: `FUND_TERMS`, `fund_terms.csv`, `fund_cash_flows.csv` (horizon per D2, FX per D1), delta file; separate RNG; regenerate `data/raw/`
- [x] 1.2 Staging tables + `10_load_staging.sql` + `11_load_delta.sql`
- [x] 1.3 `dbo.fund_terms`, `dbo.fund_cash_flow` DDL with comments (`catch_up_pct` is `NUMERIC(7,4)`: 100.0000 overflows the Story's `NUMERIC(6,4)`)
- [x] 1.4 `usp_load_fund_terms`, `usp_load_fund_cash_flow`; wire into `usp_run_etl`; watermark + period expansion in `usp_discover_periods`
- [x] 1.5 Tests: t01 (new staging tables), t03 (AC5: 3 planted rejects)
- **Done when:** `make pipeline` loads both datasets with only the 3 planted rejects, and every fund has a `mgmt_fee` and `fund_expense` row at every quarter-end from its first drawdown quarter to Sep-2026.

## 2/5 Add dbo.fn_xirr and build gross cash flows per facility and fund — AB#674
- [x] 2.1 `dbo.fn_xirr` + `dbo.fn_xirr_reason` in `03_functions.sql`
- [x] 2.2 `24_usp_build_fund_performance.sql` part 1: `dbo.fn_gross_flow(T)` (non-PIK, ≤ T, EUR via D1) — a set-returning function instead of a temp table, so AC2 is testable before the procedure exists; Task 3/5 materialises it into `tmp_gross_flow`
- [x] 2.3 Tests t40 (AC1, function part) and t41 (AC2)
- **Done when:** `fn_xirr` returns 5.00 % for the AC1 example and NULL when flows never change sign; the gross flow build excludes PIK.

## 3/5 Calculate Gross IRR, Net IRR and MOIC in dbo per as_of_date — AB#675
- [x] 3.1 `dbo.fund_performance` DDL
- [x] 3.2 Proc part 2: end values, FACILITY / FUND / VINTAGE rows, LP flows, carry, NAV, net IRR, rejects, DELETE + INSERT, log
- [x] 3.3 CALL in the period loop after `usp_apply_ratings`
- [x] 3.4 Tests t40 (AC1, fixture facility MOIC), t42 (AC3), t43 (AC4); extend t41 so `fund_performance.drawn_eur` / `returned_eur` of PIK facilities equal their non-PIK flows (AC2 as worded)
- [x] 3.5 Call `fn_xirr_reason` only when `fn_xirr` is NULL (it solves again)
- [x] 3.8 Task 3/5 review round 2: full catch-up carry (F19, owner decision a); pre-carry reject before the NAV swap and only with LP flows (F21); t45 distribution and catch-up-zone fixtures (F23); spec amendment note (F24)
- [x] 3.7 Task 3/5 review: t45 carry / hurdle / NAV fixtures (F10); funds without LP flows (F11); spec reject keys and reasons, `xirr: out of range` (F12, F17); pre-carry reject (F13); reject-path fixtures in t43 (F15); fund / vintage `no drawdown` (F16); `tmp_fp_facility` (F18)
- [x] 3.6 Task 2/5 review: flows without a EUR rate (FX gap months) rejected `no fx rate` (F7); `usp_load_cash_flow` rejects negative amounts (F8); a single flow's reason is `no sign change`; t12 lineage covers `fund_performance`
- **Done when:** after `make pipeline`, `dbo.fund_performance` has FUND rows for all 3 funds in every period, stamped with `etl_run_id`, one `usp_log_step` row per period.

## 4/5 Expose bi.vw_fund_performance and add SQL tests for every criterion — AB#676
- [x] 4.1 `bi.vw_fund_performance` — in its own file `sql/03_bi/02_vw_fund_performance.sql` (sqlfluff's ST06 fix on `01_create_bi_views.sql` would reorder existing view columns)
- [x] 4.2 t08 (new view), t44 (AC6), `tests/incremental/t17` (AC7)
- [x] 4.3 Task 3/5 review leftovers: t44 counts 3 FUND rows and one log row per period (F20); accrued_carry_eur comment (F26); carry capped at FV (F27); carry truncated to cents and t45 invariant covers NULL net IRR (F28)
- **Done when:** `make pipeline` and `make incremental` pass all tests, t40–t45 and t17 included (AC9).

## 5/5 Add the Metabase KPI card and update the docs — AB#677
- [x] 5.1 `metabase/cards/fund_performance.sql` + `dashboard.json` card
- [x] 5.2 `docs/DATA_DICTIONARY.md`, `docs/ARCHITECTURE.md`, `specs/README.md`, spec Status → Done
- [x] 5.3 `make dashboard`; AC8 checked through the Metabase API (card = view, fund filter leaves one fund, palette applied), evidence on the Story
- [x] 5.4 Task 4/5 review leftovers: t44 log check on the latest run that rebuilt every period (F3) and row-count equality (F5); t17 delta filtered on `lp_distribution`, comment on the recomputed baseline (F4); `metabase/cards/` added to `.sqlfluffignore` (Metabase template syntax)
- **Done when:** `make dashboard` succeeds, the card reacts to the fund filter, spec 005 is Done and the docs are updated.

## Acceptance criteria → task → test
| AC | Task | Test |
|---|---|---|
| AC1 | 2/5, 3/5 | t40 |
| AC2 | 2/5, 3/5 | t41 |
| AC3 | 1/5, 3/5 | t42 |
| AC4 | 2/5, 3/5 | t43 |
| AC5 | 1/5 | t03 |
| AC6 | 3/5, 4/5 | t44 |
| AC7 | 1/5, 4/5 | t17 (incremental; must run before t35, which re-runs the full ETL) |
| AC8 | 5/5 | manual (Metabase), evidence on AB#672 |
| AC3b | 3/5 | t45 |
| AC9 | all | full `make pipeline` + `make incremental` |
