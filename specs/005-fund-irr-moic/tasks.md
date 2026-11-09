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
- [ ] 2.1 `dbo.fn_xirr` + `dbo.fn_xirr_reason` in `03_functions.sql`
- [ ] 2.2 `24_usp_build_fund_performance.sql` part 1: `tmp_gross_flow` (non-PIK, ≤ T, EUR via D1)
- [ ] 2.3 Tests t40 (AC1, function part) and t41 (AC2)
- **Done when:** `fn_xirr` returns 5.00 % for the AC1 example and NULL when flows never change sign; the gross flow build excludes PIK.

## 3/5 Calculate Gross IRR, Net IRR and MOIC in dbo per as_of_date — AB#675
- [ ] 3.1 `dbo.fund_performance` DDL
- [ ] 3.2 Proc part 2: end values, FACILITY / FUND / VINTAGE rows, LP flows, carry, NAV, net IRR, rejects, DELETE + INSERT, log
- [ ] 3.3 CALL in the period loop after `usp_apply_ratings`
- [ ] 3.4 Tests t40 (AC1, fixture facility MOIC), t42 (AC3), t43 (AC4)
- **Done when:** after `make pipeline`, `dbo.fund_performance` has FUND rows for all 3 funds in every period, stamped with `etl_run_id`, one `usp_log_step` row per period.

## 4/5 Expose bi.vw_fund_performance and add SQL tests for every criterion — AB#676
- [ ] 4.1 `bi.vw_fund_performance`
- [ ] 4.2 t08 (new view), t44 (AC6), `tests/incremental/t46` (AC7)
- **Done when:** `make pipeline` and `make incremental` pass all tests, t40–t46 included (AC9).

## 5/5 Add the Metabase KPI card and update the docs — AB#677
- [ ] 5.1 `metabase/cards/fund_performance.sql` + `dashboard.json` card
- [ ] 5.2 `docs/DATA_DICTIONARY.md`, `docs/ARCHITECTURE.md`, `specs/README.md`, spec Status → Done
- [ ] 5.3 `make dashboard`; manual AC8 check (fund filter), evidence on the Story
- **Done when:** `make dashboard` succeeds, the card reacts to the fund filter, spec 005 is Done and the docs are updated.

## Acceptance criteria → task → test
| AC | Task | Test |
|---|---|---|
| AC1 | 2/5, 3/5 | t40 |
| AC2 | 2/5 | t41 |
| AC3 | 1/5, 3/5 | t42 |
| AC4 | 2/5, 3/5 | t43 |
| AC5 | 1/5 | t03 |
| AC6 | 3/5, 4/5 | t44 |
| AC7 | 1/5, 4/5 | t46 |
| AC8 | 5/5 | manual (Metabase), evidence on AB#672 |
| AC9 | all | full `make pipeline` + `make incremental` |
