# Plan 003: Position cost basis

> Written before approval at the sponsor's request. Depends on plan 002 being implemented first (period loop, `*_local` columns, `p_as_of_date` signature).

## 1. Source and staging
| File | Change |
|---|---|
| `data/generator/generate_data.py` | `add_cf()` gains `price`: Drawdown → facility OID price ± 0.25 (blank 6% of the time, `0` 2%, comma-decimal 3%, one planted `250.0`); Repayment → `100` for amortisation, trade price 97–101 for prepayments; new `PIK` rows for `Holdco PIK Note` each month (today the interest is capitalised silently); new instrument `Equity co-invest` for ~4% of facilities (`PER_UNIT`, price per unit 8–15, no base rate, `fair_value_price` per unit); one planted facility whose first drawdown is removed (`no acquisition cash flow`) |
| `data/raw/cash_flows.csv`, `facilities.csv`, `loan_marks.csv` | regenerated |
| `sql/01_staging/01_create_staging_tables.sql` | `staging.cash_flows` + `price TEXT` |
| `sql/01_staging/10_load_staging.sql`, `11_load_delta.sql` | `\copy` column list + `price` |

## 2. dbo
| File | Change |
|---|---|
| `01_create_dbo_tables.sql` | `ref_instrument + price_basis`; `cash_flow + price NUMERIC(9,4)`, type check `+ 'PIK'`; `facility_month` + 8 columns (§2 of spec), all NULL, commented |
| `02_seed_reference_data.sql` | `price_basis` per instrument; new row `('Equity co-invest','Equity',5,'PER_UNIT')` |
| `03_functions.sql` | `dbo.fn_try_price(p TEXT)`: like `fn_try_numeric` but accepts a single decimal comma (`98,75`) when no dot present |
| `13_usp_load_facility.sql` | no change in logic; `v_instr` picks the new instrument automatically |
| `15_usp_load_cash_flow.sql` | parse `price`, conform `PIK`, reject `invalid price` (needs a join to `facility`→`ref_instrument` in the reject CASE) |
| `20_usp_build_facility_month.sql` | `fair_value_local = CASE price_basis WHEN 'PER_UNIT' THEN outstanding × price ELSE outstanding × price / 100 END`; base-rate join becomes LEFT for `PER_UNIT` (no coupon), `all_in_rate_pct` NULL for equity |
| `22_usp_build_cost_basis.sql` | **new**, spec §8.1–§8.3 (three temp stages, DQ rejects, log) |
| `10b_usp_discover_periods.sql` | cash-flow branch already expands to later months (plan 002) — verify |
| `99_usp_run_etl.sql` | add `CALL dbo.usp_build_cost_basis(v_run_id, v_period.as_of_date)` after FX |

## 3. bi
- `vw_facility_exposure`: + `wa_acquisition_price, cost_basis_eur, unrealised_gain_eur, realised_gain_local, price_basis`.
- `vw_portfolio_monthly`: + `sum(cost_basis_eur) AS cost_basis_eur`, `sum(unrealised_gain_eur) AS unrealised_gain_eur`, `count(*) FILTER (WHERE cost_basis_eur IS NULL) AS facilities_without_cost`.
- `vw_watchlist`: + `wa_acquisition_price, unrealised_gain_eur`.
- `vw_cash_flow_monthly`: no change (PIK flows through).

## 4. Tests
| Test | AC |
|---|---|
| `t20_cost_basis_debt.sql` | AC1 — recompute from `dbo.cash_flow` with window functions, compare with 0.01 tolerance |
| `t21_cost_basis_equity.sql` | AC2 |
| `t22_wa_price_bounds.sql` | AC3 |
| `t23_price_normalisation.sql` | AC4 — blank/0 loaded, `>200` rejected |
| `t24_unrealised_gain.sql` | AC5 |
| `t09_bi_totals_reconcile.sql` | AC6 — extend with `unrealised_gain_eur` |
| `tests/incremental/t26_late_drawdown_propagates.sql` | AC7 |
| `t25_dq_no_acquisition.sql` | AC8 |

## 5. Metabase
| File | Change |
|---|---|
| `cards/kpi_unrealised_gain.sql` | **new** smart scalar from `vw_portfolio_monthly` |
| `cards/cost_vs_fair_value_by_fund.sql` | **new** bar, two series |
| `cards/watchlist.sql` | + two columns |
| `dashboard.json` | KPI row gets the tile (shift `part2_placeholder`); new bar card; colours `#192C50` / `#3D7CC9`; `[[AND fund_code = {{fund}}]]` on both |

## 6. Docs
`DATA_DICTIONARY.md` (8 columns + `price`, `price_basis`), `ARCHITECTURE.md` (procedure 22 in the table, "Lineage example 2: cost of one position"), `DEMO_RUNBOOK.md` (talking point: three-stage temp tables like the client's).

## 7. Order
1. Generator + regenerate + staging column → `make pipeline` green (price ignored).
2. DDL/seeds/helper + `usp_load_cash_flow` → t23.
3. `usp_build_facility_month` equity branch → t02/t05/t06 still green.
4. `usp_build_cost_basis` + orchestration → t20–t25.
5. bi + t09 extension + incremental t26.
6. Metabase + docs.

## 8. Risks
- Regenerating data shifts every number in `docs/mockup` and screenshots; regenerate `dashboard_mockup.png` with `build_mock.py` at the end.
- Equity facilities have no base rate: every existing card that averages `all_in_rate_pct` must filter `price_basis = 'PCT_OF_PAR'` or use the weighted form that already ignores NULL × outstanding — check `kpi_all_in_yield.sql`, `kpi_spread.sql`, t06 bounds.
