# Tasks 003: Position cost basis

Tick each task when done. AC = acceptance criterion in `spec.md` §5. Every AC maps to at least one task and one test.

Implementation decisions taken while executing (resolve ambiguities in plan 003, spec unchanged):
- **Equity unit price.** For `PER_UNIT` instruments one unit = 1.00 of currency invested, so prices sit around 1.0 (0.95–1.05 at acquisition, 0.4–1.4 marks). Amounts, commitment and outstanding stay monetary, so every EUR exposure chart keeps its meaning, and the spec formulas (`cost = (drawn − repaid) × wa`, `fair value = outstanding × price`) hold literally. The plan's "8–15 per unit" would have required amounts in units and broken every EUR total.
- **Initial drawdowns.** The generator now emits the first `Drawdown` for every facility, also those originated before the data window (dated at origination). Without it ~70% of facilities would have no acquisition cash flow. Pre-window drawdowns have no FX rate, so `bi.vw_cash_flow_monthly` (inner join to FX) still shows the window only.
- **`no acquisition cash flow` DQ row** is written only when `outstanding_local > 0`.
- **Yield / spread KPIs.** Equity has no base rate (`all_in_rate_pct` NULL, `spread_bps` 0), so `bi.vw_portfolio_monthly` gains `debt_outstanding_eur` and the two KPI cards divide by it (plan §8 risk).

## A. Source and staging
- [x] A1 Generator: `price` column on cash flows (dirty: blank 6%, `0` 2%, comma decimal 3%, one planted `250.00`), `PIK` rows for `Holdco PIK Note`, instrument `Equity co-invest` (~4%), initial drawdown for every facility, one planted facility without its drawdown, delta gets a late `Drawdown` in the last month — AC4, AC7, AC8
- [x] A2 Regenerate `data/raw/*.csv` and `data/raw/delta/*.csv`
- [x] A3 `staging.cash_flows` + `price TEXT`; `\copy` lists in `10_load_staging.sql` and `11_load_delta.sql`

## B. dbo
- [x] B1 DDL: `ref_instrument.price_basis`; `cash_flow.price` + `PIK` in type check; `facility.base_rate_name`, `facility_month.base_rate_pct` / `all_in_rate_pct` nullable; `facility_month` + 8 cost columns with comments — AC1–AC5
- [x] B2 Seeds: `price_basis` per instrument, `Equity co-invest` row — AC2
- [x] B3 `dbo.fn_try_price` (single decimal comma) — AC4
- [x] B4 `usp_load_cash_flow`: parse `price`, conform `PIK`, reject `invalid price` — AC4
- [x] B5 `usp_build_facility_month`: `PER_UNIT` fair value without `/100`, LEFT join to reference rate for equity — AC2
- [x] B6 `22_usp_build_cost_basis.sql` (three temp stages, DQ rows, log) — AC1, AC3, AC5, AC8
- [x] B7 `usp_run_etl` calls `usp_build_cost_basis` after FX in each period — AC1, AC7

## C. bi
- [x] C1 `vw_facility_exposure` + `price_basis`, `wa_acquisition_price`, `cost_basis_eur`, `unrealised_gain_eur`, `realised_gain_local` — AC5
- [x] C2 `vw_portfolio_monthly` + `cost_basis_eur`, `unrealised_gain_eur`, `facilities_without_cost`, `debt_outstanding_eur` — AC6
- [x] C3 `vw_watchlist` + `wa_acquisition_price`, `unrealised_gain_eur`

## D. Tests
- [x] D1 `t20_cost_basis_debt.sql` — AC1
- [x] D2 `t21_cost_basis_equity.sql` — AC2
- [x] D3 `t22_wa_price_bounds.sql` — AC3
- [x] D4 `t23_price_normalisation.sql` — AC4
- [x] D5 `t24_unrealised_gain.sql` — AC5
- [x] D6 `t09_bi_totals_reconcile.sql` extended with `unrealised_gain_eur` — AC6
- [x] D7 `tests/incremental/t26_late_drawdown_propagates.sql` — AC7
- [x] D8 `t25_dq_no_acquisition.sql` — AC8
- [x] D9 t01–t16 still pass — AC9

## E. Metabase
- [x] E1 `cards/kpi_unrealised_gain.sql` (smart scalar, decrease = bad)
- [x] E2 `cards/cost_vs_fair_value_by_fund.sql` (bar, cost `#192C50`, fair value `#3D7CC9`)
- [x] E3 `cards/watchlist.sql` + two columns; `kpi_spread.sql` / `kpi_all_in_yield.sql` use `debt_outstanding_eur`
- [x] E4 `dashboard.json`: new tile and bar, `[[AND fund_code = {{fund}}]]`; `make dashboard`

## F. Docs and close
- [x] F1 `DATA_DICTIONARY.md`, `ARCHITECTURE.md`, `DEMO_RUNBOOK.md`
- [x] F2 `specs/README.md` status; spec `Status: Done`
