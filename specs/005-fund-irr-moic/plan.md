# Plan 005: Gross IRR, Net IRR and MOIC per fund

Spec: [spec.md](spec.md) (Approved 2026-11-09, D1–D4 as recommended) · Story AB#672 · branch `feature/AB672-fund-irr-moic`

## Source (generator)
| File | Change |
|---|---|
| `data/generator/generate_data.py` | `FUND_TERMS` constant next to `FUNDS`. After the FX block: build an EUR flow ledger per fund from `cf_rows` (clean values, D1 FX rule: own month-end rate, else the first rate), then write `fund_terms.csv` (3 rows + `XX-9`) and `fund_cash_flows.csv` (§3.1 of the spec, from each fund's first drawdown month; dirty dates / case / whitespace; 2 planted bad rows). Delta block: `delta/fund_cash_flows.csv` (3 late `lp_distribution`, one per fund, dated in the last month). Regenerate `data/raw/` with seed 42 — existing extracts must not change (new RNG draws come after all existing ones; use a separate `random.Random(seed + 5)` for the new files) |

## Layer 1 — staging
| File | Change |
|---|---|
| `sql/01_staging/01_create_staging_tables.sql` | `staging.fund_terms`, `staging.fund_cash_flows` (all TEXT + `_row_id, _source_file, _loaded_at`) |
| `sql/01_staging/10_load_staging.sql` | TRUNCATE list, two `\copy`, two rows in the count query |
| `sql/01_staging/11_load_delta.sql` | `\copy` + `_source_file` UPDATE for `fund_cash_flows`; row in the summary |

## Layer 2 — dbo
| File | Change |
|---|---|
| `sql/02_dbo/01_create_dbo_tables.sql` | `dbo.fund_terms` (after `dbo.fund`), `dbo.fund_cash_flow` (after `dbo.cash_flow`), `dbo.fund_performance` (after `facility_month`, + index on `as_of_date`), column comments |
| `sql/02_dbo/03_functions.sql` | `dbo.fn_xirr(DATE[], NUMERIC[]) RETURNS NUMERIC` — Newton from 0.10, bisection fallback on [−0.9999, 10], 100 iterations, NULL on no sign change / no convergence. Plus `dbo.fn_xirr_reason(DATE[], NUMERIC[]) RETURNS TEXT` (`xirr: no sign change` / `xirr: no convergence` / NULL) so the proc can write the reject reason without duplicating the solver |
| `sql/02_dbo/19_usp_load_fund_terms.sql` (new) | Pattern of `15_usp_load_cash_flow.sql`; range / basis / frequency / catch-up checks (spec §4) |
| `sql/02_dbo/19a_usp_load_fund_cash_flow.sql` (new) | Same pattern; `DISTINCT ON flow_id … _row_id DESC`; unknown fund, invalid date, unknown type, negative / invalid amount |
| `sql/02_dbo/24_usp_build_fund_performance.sql` (new) | `dbo.fn_gross_flow(T)` (Task 2/5: non-PIK, ≤ T, EUR via D1) + `(p_run_id, p_as_of_date)` procedure: tmp_gross_flow from fn_gross_flow → tmp_end_value (facility_month FV at T) → tmp_lp_flow → FACILITY / FUND / VINTAGE aggregation with `fn_xirr`; carry & NAV for FUND; DELETE period + INSERT; rejects `no drawdown`, `xirr: …`, `no fund terms`, `no fx rate`; `usp_log_step` |
| `sql/02_dbo/99_usp_run_etl.sql` | CALL the two loaders after `usp_load_cash_flow`; CALL `usp_build_fund_performance` after `usp_apply_ratings` |
| `sql/02_dbo/10b_usp_discover_periods.sql` | Watermark rows for both staging tables; incremental UNION branch for `staging.fund_cash_flows` via `fn_month_ends_from` |

Deployment order is alphabetical in `run_pipeline.sh` (`19_`, `19a_` before `20_`; `24_` before `99_`), so no script change.

## Layer 3 — bi
| File | Change |
|---|---|
| `sql/03_bi/01_create_bi_views.sql` | `bi.vw_fund_performance` after `vw_cash_flow_monthly` (joins `dbo.fund` for name; IRR × 100 rounded 2 dp; `is_latest_month`). `99_grants.sql` already grants all bi tables |

## Tests
| File | AC |
|---|---|
| `tests/sql/t01_staging_loaded.sql` | new staging tables non-empty |
| `tests/sql/t03_expected_rejects.sql` | AC5 — combined into one final SELECT (runner reads only the last line) |
| `tests/sql/t08_bi_views_populated.sql` | new view |
| `tests/sql/t40_xirr_known_value.sql` (new) | AC1 |
| `tests/sql/t41_pik_excluded.sql` (new) | AC2 |
| `tests/sql/t42_net_below_gross.sql` (new) | AC3 |
| `tests/sql/t43_xirr_unsolvable_rejected.sql` (new) | AC4 |
| `tests/sql/t44_bi_fund_performance_reconciles.sql` (new) | AC6 |
| `tests/incremental/t46_delta_fund_flow.sql` (new) | AC7 (amended): latest run rebuilt only the last period's `fund_performance` rows (`etl_run_id`), earlier periods untouched; per FUND, `lp_distributed_eur` = recomputation from `dbo.fund_cash_flow` excluding `delta/fund_cash_flows.csv` rows + the delta amounts |

Fixtures for AC1 / AC4 run inside the test (`fn_xirr` on literal arrays; a fixture facility evaluated through the same SQL expressions in a CTE), never written to dbo.

## Metabase
| File | Change |
|---|---|
| `metabase/cards/fund_performance.sql` (new) | `bi.vw_fund_performance`, `level = 'FUND'`, latest month, `[[AND fund_code = {{fund}}]]` |
| `metabase/dashboard.json` | card `fund_performance`, table, row 48 col 0, 24 × 6, fund filter → `fund_code`, palette colours, description with the pre-window caveat |

## Docs
| File | Change |
|---|---|
| `docs/DATA_DICTIONARY.md` | 2 extracts, `dbo.fund_terms`, `dbo.fund_cash_flow`, `dbo.fund_performance`, `bi.vw_fund_performance` |
| `docs/ARCHITECTURE.md` | layer-2 procedure list, tests t40–t46, "Lineage example 3: one fund's Net IRR" |
| `specs/README.md` | row 005; spec Status → Done |

## Risks
- **Known LP/gross gap (review F6):** the generator's LP ledger includes the spec-003 planted repayment with price 250 that `usp_load_cash_flow` rejects, so one month's `lp_distribution` exceeds the gross inflows in dbo. Small; any LP-vs-gross reconciliation in Task 3/5 must tolerate it.
- **fund_terms not period-expanded (review F5):** see spec §4.
- **Size:** ~650 changed lines, over the 400-line Story limit (accepted on the Story). Each Task stays ≤ 150 lines of hand-written code; regenerated CSVs are data, not counted.
- **Generator determinism:** new files must not shift existing RNG draws, or every existing test baseline moves. Mitigation: separate RNG instance.
- **XIRR on 230 facilities × 24 periods** ≈ 5.5 k solves per full run in PL/pgSQL; expected < 10 s. If slower, cache flow arrays in the temp table once per period (already the design).
