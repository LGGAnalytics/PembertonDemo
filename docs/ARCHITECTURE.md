# Pipeline architecture

## Execution flow (`scripts/run_pipeline.sh`)

| Step | What runs | Notes |
|---|---|---|
| 1. Deploy | `sql/00_reset.sql`, then `sql/01_staging/0*.sql`, `sql/02_dbo/*.sql` and `sql/03_bi/*.sql` in file order | Full rebuild. Every object is defined in versioned SQL files. |
| 2. Stage | `sql/01_staging/10_load_staging.sql` | `TRUNCATE` and `\copy` of each CSV, loaded as-is |
| 3. ETL | `CALL dbo.usp_run_etl();` | Full mode: audit header, dimensions, then one transaction **per month-end period** |
| 4. Test | `scripts/run_tests.sh tests/sql` | Any non-zero count fails the run |

`make dashboard` runs afterwards and builds the Metabase dashboard from `metabase/`.

### Incremental flow (`scripts/run_incremental.sh`, `make incremental`)

| Step | What runs | Notes |
|---|---|---|
| 1. Delta | `sql/01_staging/11_load_delta.sql` | Appends `data/raw/delta/*.csv` to staging (no truncate), with a later `_loaded_at` |
| 2. ETL | `CALL dbo.usp_run_etl('incremental');` | Only the periods whose source rows arrived after `dbo.etl_watermark` are rebuilt |
| 3. Test | `tests/incremental/*.sql` then `tests/sql/*.sql` | Incremental assertions first (t15 rebuilds periods and would mask them) |

### The run contract (`dbo.usp_run_etl`)

```
usp_audit_start  ──COMMIT──►  dimensions + market data + usp_discover_periods  ──COMMIT──►  FOR each period:
                                                                                          │   usp_load_loan_mark
   dbo.etl_run (Processing)                                                               │   usp_build_facility_month   (local currency)
                                                                                          │   usp_apply_fx_rates         (EUR)
                                                                                          │   usp_build_cost_basis       (spec 003: cost, WA price, gains)
                                                                                          │   usp_apply_ratings          (spec 004: point-in-time ratings, change-only)
                                                                                          │   usp_build_fund_performance (spec 005: Gross / Net IRR, MOIC, carry)
                                                                                          │   COMMIT            ← or: ROLLBACK, log ERROR, etl_run = Error, COMMIT, RAISE
                                                                                          └─► usp_audit_finish (Success) + watermark advance
```

- **`dbo.etl_run`** is the audit header, opened and committed before anything else, so a crashed run is visible as `Processing`.
- **`dbo.usp_discover_periods`** fills `tmp_periods` (`row_num`, `as_of_date`): every mark date in full mode; in incremental mode the union of mark dates, cash-flow months and rating `valid_from` months and fund cash-flow months (spec 005) (all expanded to every later month-end) and FX dates whose staging rows have `_loaded_at` after the watermark minus `overlap_hours`, within `lookback_months` of the latest month-end.
- **Per-period transaction.** Each period is `DELETE WHERE as_of_date` + `INSERT`, then committed. A failure rolls back only that period; earlier periods stay committed, the error is written to `dbo.etl_run_log` (`status = 'ERROR'`) and `dbo.etl_run` (`status = 'Error'`), both committed, and the exception is re-raised so the pipeline exits non-zero. The watermark does not move.
- **Dimensions** are reloaded with `DELETE` + `INSERT` (foreign keys that reference them are `DEFERRABLE INITIALLY DEFERRED`, so the reload is checked at `COMMIT`). Facilities that disappear from the source have their periodised rows removed and explained in `dbo.etl_reject` (`facility removed from source`).
- **Lineage.** Every periodised row carries `etl_run_id` and `loaded_at`.
- **Test hook.** `dbo.etl_config.fail_on_period` makes `usp_build_facility_month` raise for one period; test t15 uses it to prove the rollback path. It must be `NULL` in normal operation.

## Layer 1: staging

- One table per source extract: `staging.funds`, `borrowers`, `facilities`, `loan_marks`, `cash_flows`, `borrower_financials`, `fx_rates`, `reference_rates`, `credit_ratings` (spec 004), `fund_terms` and `fund_cash_flows` (spec 005).
- Every business column is `TEXT`, so nothing can fail at load time and the original values are kept for audit.
- Each table has lineage columns: `_row_id` (identity, in file order), `_source_file` and `_loaded_at`.
- There are no keys or constraints. Duplicates and bad rows are kept on purpose; the ETL decides what to do with them.

## Layer 2: dbo (stored procedures, then treated tables)

The master procedure `dbo.usp_run_etl(p_mode, p_lookback_months, p_periods)` opens the run header, reloads the dimensions, discovers the periods and then loops over them (see "The run contract" above). Steps in order:

| # | Procedure | Source → target | Rules |
|---|---|---|---|
| 1 | `dbo.usp_load_fund` | `staging.funds` → `dbo.fund` | Typed; rejects a fund with a missing key, name, vintage or size |
| 2b | `dbo.usp_load_credit_rating` | `staging.credit_ratings` → `dbo.credit_rating` | Spec 004. Agency and rating conformed to `dbo.ref_rating_scale`. Rejects unknown borrower / agency, rating not in scale, invalid dates, `valid_to ≤ valid_from`. Overlapping intervals are closed (later-updated row wins, DQ row `overlap closed`). TRUNCATE + INSERT. Resets `facility_month.rating_changed_in_run`. |
| 2 | `dbo.usp_load_borrower` | `staging.borrowers` → `dbo.borrower` | Sector conformed to `dbo.ref_sector`, ignoring case and whitespace. Country given as ISO-2, ISO-3 or full name becomes ISO-2 via `dbo.ref_country`. Sets `is_sponsored`. |
| 3 | `dbo.usp_load_facility` | `staging.facilities` → `dbo.facility` | Mixed date formats parsed. Thousands separators stripped. Instrument conformed. Currency upper-cased. `tenor_years` derived. Rejects impossible dates, non-numeric amounts, unknown borrowers or funds, and maturities before origination. |
| 4 | `dbo.usp_load_market_data` | `staging.fx_rates` and `reference_rates` → `dbo.fx_rate` and `dbo.reference_rate` | Typed; rejects non-positive FX rates |
| 5 | `dbo.usp_discover_periods` | staging `_loaded_at` + `dbo.etl_watermark` → `tmp_periods` | Decides which month-ends this run rebuilds (see "The run contract") |
| 6 | `dbo.usp_load_loan_mark` **(per period)** | `staging.loan_marks` → `dbo.loan_mark` | Y/N becomes `BOOLEAN`. A missing rating is kept as `NULL` and shown as "Not rated". Rejects marks for unknown facilities. `DELETE` the period + `INSERT`. |
| 7 | `dbo.usp_build_facility_month` **(per period)** | `dbo.loan_mark` + `facility` + `reference_rate` → `dbo.facility_month` | Local-currency measures. Fair value = outstanding × price / 100 (debt) or × price (equity, `PER_UNIT`). All-in rate = max(base rate, floor) + spread (NULL for equity). Sets `risk_status`. Rejects debt marks without a reference rate. |
| 8 | `dbo.usp_apply_fx_rates` **(per period)** | `dbo.fx_rate` → `dbo.facility_month` | `UPDATE` to EUR at month-end FX (the client's `usp_UpdatePositionFxRates`). Rows still without FX are removed from the period and rejected. |
| 9 | `dbo.usp_build_cost_basis` **(per period)** | `dbo.cash_flow` → `dbo.facility_month` | Spec 003, the client's `usp_CreatePositionEquityCost`: three temp stages (`tmp_txn` ledger aggregates with price normalisation → `tmp_position` CASE on `price_basis` → `UPDATE`). Blank/0 price = par. DQ rows `no acquisition cash flow` / `over-repaid`, fact rows kept. |
| 10 | `dbo.usp_apply_ratings` **(per period)** | `dbo.credit_rating` → `dbo.facility_month` | Spec 004, the client's `Asset_Rating_*` update: ratings in force on `as_of_date` pivoted per borrower, worst score; **change-only** `UPDATE … IS DISTINCT FROM`, `rows_loaded` = rows changed. `usp_build_facility_month` carries the previous stamp across the period rebuild so unchanged rows stay untouched. |
| 11 | `dbo.usp_build_fund_performance` **(per period)** | `dbo.fn_gross_flow(T)` + `facility_month` + `fund_cash_flow` + `fund_terms` → `dbo.fund_performance` | Spec 005. Gross flows (non-PIK, EUR) and fair value per FACILITY / FUND / VINTAGE → `dbo.fn_xirr` (Newton + bisection, never raises) and MOIC. FUND rows: LP calls / distributions, carry above the hurdle (European, full catch-up, capped at FV), NAV, net IRR. Rejects `no drawdown`, `no fx rate for <ccy>`, `xirr: …`, `no fund terms`. `DELETE` the period + `INSERT`. |
| – | `dbo.usp_load_cash_flow`, `dbo.usp_load_borrower_financials` | staging → dbo | Not periodised; run with the dimensions. Transaction type conformed; a missing EBITDA is kept as `NULL`. Spec 005: negative cash-flow amounts rejected. |
| – | `dbo.usp_load_fund_terms`, `dbo.usp_load_fund_cash_flow` | `staging.fund_terms` / `fund_cash_flows` → `dbo.fund_terms` / `fund_cash_flow` | Spec 005. Not periodised; run with the dimensions. Range, basis, frequency and catch-up checks; flow type conformed; unknown fund, negative amount, non-base currency rejected. TRUNCATE + INSERT. |
| – | `dbo.usp_audit_start` / `dbo.usp_audit_finish` | → `dbo.etl_run`, `dbo.etl_watermark` | Open / close the run header; advance the watermark on Success |

Every procedure follows the same pattern:

1. Count the staging rows read.
2. Parse into a temp table. Exact duplicates are removed with `DISTINCT ON (business key)`, and the latest staged row wins.
3. Write invalid rows, with their reasons and the raw record as JSON, to **`dbo.etl_reject`**.
4. Reload the target: dimensions with `DELETE` + `INSERT`; periodised tables with `DELETE WHERE as_of_date = p_as_of_date` + `INSERT`. Tables are never dropped, so the views on top stay valid.
5. Log the read, loaded and rejected counts to **`dbo.etl_run_log`** with `dbo.usp_log_step`, one row per procedure **per period**.

The parse helpers in `sql/02_dbo/03_functions.sql` are `fn_clean_text`, `fn_try_date`, `fn_try_numeric`, `fn_try_price` (spec 003: `98,75` → 98.75), `fn_conform` and `fn_country_code`. Each returns `NULL` instead of raising an error, so a bad value becomes a reject rather than crashing the run.

**Risk status**, in priority order: `Non-accrual` (flag set), then `Impaired` (rating 5), then `Watchlist` (rating 4 or DPD ≥ 30), otherwise `Performing`.

## Layer 3: bi (views for the dashboard)

| View | Grain | Used by |
|---|---|---|
| `bi.vw_facility_exposure` | facility × month, fully described (fund, borrower, sector, country, instrument, EUR measures, risk); `is_latest_month` flag | sector, country, instrument and rating cards |
| `bi.vw_portfolio_monthly` | month × fund. Weighted averages are shipped as numerator and denominator (`spread_x_outstanding`, `all_in_rate_x_outstanding`, `debt_outstanding_eur`) so they re-aggregate correctly; cost and unrealised gain sums (spec 003) | KPI tiles, exposure trend, cost vs fair value |
| `bi.vw_cash_flow_monthly` | month × fund × transaction type, in EUR | interest received |
| `bi.vw_watchlist` | latest month, facilities not Performing, with `severity_rank`, acquisition price, unrealised gain and ratings | watchlist table |
| `bi.vw_rating_migration` | facility × month vs the previous month-end, `is_migration` flag (spec 004) | rating migrations table |
| `bi.vw_fund_performance` | as_of_date × level (FACILITY / FUND / VINTAGE): Gross IRR %, Net IRR %, MOIC, NAV, carry (spec 005); `is_latest_month` | fund performance table |
| `bi.vw_etl_run_summary` | last ETL run, one row per procedure **per period**, with the run header (mode, status, periods done/planned) | pipeline health table |
| `bi.vw_etl_run_history` | last 20 runs, newest first (audit header) | ETL runs table |

**Security:** Metabase connects as `bi_reader`, which has `USAGE` and `SELECT` on schema `bi` only. Querying `staging` or `dbo` directly is denied, while the views still work because they run with the owner's rights.

**Dashboard filter:** every view carries `fund_code`, and each card's SQL has `[[AND fund_code = {{fund}}]]`, so the single "Fund" filter drives every card.

## Lineage example: one value end to end

`facilities.csv` contains `"138,500,000.00"` with currency `gbp` and date `11/11/2024`.
1. `staging.facilities` stores the same text, unchanged.
2. `dbo.usp_load_facility` turns it into `dbo.facility.commitment_amount = 138500000.00`, `currency = 'GBP'` and `origination_date = 2024-11-11`.
3. `dbo.usp_build_facility_month` turns it into `commitment_eur = 138500000 × fx(GBP, month-end)`.
4. `bi.vw_portfolio_monthly` adds it into `sum(commitment_eur)`, and Metabase shows it in the "Commitments" tile.

## Lineage example 2: the cost of one position (spec 003)

A drawdown of `78,000,000.00` GBP at price `98.75` on 2024-11-11 and quarterly amortisation repayments at `100`:
1. `staging.cash_flows` keeps the text (`price` may arrive blank, `0` or `98,75`).
2. `dbo.usp_load_cash_flow` parses it (`fn_try_price`) into `dbo.cash_flow.price`.
3. For each month-end, `dbo.usp_build_cost_basis` sums drawn / repaid / PIK up to the date, normalises missing prices to par, derives the WA acquisition price (98.75) and `cost = (drawn − repaid) × 98.75 / 100 + PIK`.
4. `cost_basis_eur` and `unrealised_gain_eur = fair_value_eur − cost_basis_eur` feed the "Unrealised P&L" tile and "Cost vs fair value by fund".

## Lineage example 3: one fund's Net IRR (spec 005)

EDL-IV at 2026-10-31:
1. `fund_cash_flows.csv` holds the fund's LP calls (drawdowns + quarterly fees and expenses) and distributions; `fund_terms.csv` its 0.90 % fee, 10 % carry and 6 % hurdle. Both land as text in `staging`, then typed in `dbo.fund_cash_flow` / `dbo.fund_terms`.
2. For the period, `dbo.usp_build_fund_performance` sums the fair value of the fund's facilities (`facility_month.fair_value_eur`) and solves the LP pre-carry IRR on calls, distributions and that fair value. It clears the 6 % hurdle, so carry accrues, capped by the catch-up: the LP keeps exactly the hurdle value H, the GP takes the excess up to 10 % of the profit.
3. NAV = fair value − carry; `net_irr` = XIRR of the LP flows ending in NAV (6.00 % after a full run: EDL-IV sits in the catch-up zone). Gross IRR (7.16 %) uses the facility cash flows instead.
4. `bi.vw_fund_performance` shows both × 100; the "Fund performance" card filters `level = 'FUND'` and the latest month.

## Data-quality tests (`tests/sql`)

| Test | Checks |
|---|---|
| t01 | every staging table was loaded |
| t02 | every staged facility ends up in `dbo` or in `etl_reject` (reconciliation) |
| t03 | the two seeded bad rows (F99901 and F99902) are rejected; spec 005 AC5: the 3 planted fund-term / fund-flow rows |
| t04 | sectors and countries are conformed to the reference data |
| t05 | every mark reached the EUR fact (no FX or reference-rate gaps) |
| t06 | rates, prices and amounts are within plausible bounds |
| t07 | one fact row per facility per month (grain) |
| t08 | every dashboard view returns data (incl. `bi.vw_fund_performance`) |
| t09 | `bi` totals reconcile to `dbo` |
| t10 | the latest `dbo.etl_run` is `Success` with every planned period done |
| t11 | one log row per (procedure, period); FX-converted rows equal the fact rows |
| t12 | every periodised row points at a successful run (and at the latest one after a full run) |
| t13 | watermark = `max(_loaded_at)` per staging table |
| t14 | run views populated and readable by `bi_reader` |
| t15 | **error path**: injected failure in period P2 of [P1, P2, P3] → run `Error`, P1 committed, P2/P3 untouched, watermark unchanged; then restored |
| t20 / t21 | spec 003 AC1/AC2: debt and equity cost basis recomputed independently from `dbo.cash_flow`; equity fair value per unit |
| t22 | spec 003 AC3: WA price within the drawdown price range, NULL exactly without a drawdown |
| t23 | spec 003 AC4: blank/0 prices loaded and treated as par; prices > 200 on debt rejected |
| t24 / t25 | spec 003 AC5/AC8: unrealised gain identity; planted facility without acquisition flagged and kept |
| t30 / t33 | spec 004 AC1/AC4: point-in-time rating per agency; score = worst available |
| t31 / t32 | spec 004 AC2/AC3: no overlapping intervals, every seeded overlap closed; seeded bad rows rejected |
| t36 | spec 004 AC7: migration view reconciles to the fact |
| t40 | spec 005 AC1: `fn_xirr` known values (incl. bisection, no root, NULL input) and the AC1 facility through the procedure (5.00 %, 1.05x) |
| t41 | spec 005 AC2: PIK not in the gross flows; D1 FX on every flow; `fund_performance` drawn / returned of PIK facilities |
| t42 | spec 005 AC3: quarterly fee and expense rows from each fund's first drawdown; Net IRR < Gross IRR |
| t43 | spec 005 AC4: no-sign-change IRR NULL + reject, run Success; `no drawdown` / `no fx rate` / `no fund terms` rejects |
| t44 | spec 005 AC6: view = dbo row for row; 3 FUND rows and one log row per period |
| t45 | spec 005 AC3b: carry above the hurdle, in the catch-up zone and below it; NAV = FV − carry; no carry below the hurdle |
| t16 (`tests/incremental`) | after `make incremental`: exactly one period rebuilt, restated prices applied, other months untouched |
| t26 (`tests/incremental`) | spec 003 AC7: the late delta drawdown is in the cost of its month; earlier months untouched |
| t17 (`tests/incremental`) | spec 005 AC7: only the last period's fund performance is rebuilt and LP distributions include the 3 delta flows (runs before t35) |
| t34 (`tests/incremental`) | spec 004 AC6: only the delta borrowers' rows from the new `valid_from` are flagged changed, with the new rating |
| t35 (`tests/incremental`) | spec 004 AC5: a full re-run with no rating news changes 0 rows in every period (runs the ETL, so it is last) |

## Design choices (and what production would do)

- **Full redeploy, then full or incremental ETL.** `make pipeline` drops and recreates every object (deterministic demo); `make incremental` shows the production shape: watermark, period discovery, per-period rebuild. Production would add versioned migrations (Flyway or Liquibase) and a scheduler (Airflow or Data Factory).
- **One transaction per period, audited.** A failed period is rolled back, earlier periods stay, and the failure is visible in `dbo.etl_run` and on the dashboard. This mirrors the client's production procedures (spec 002).
- **`overlap_hours = 0` in the demo.** The client re-reads 4 hours before the watermark; here the full load and the delta are minutes apart, so a 4-hour overlap would rebuild everything.
- **Dashboard as code.** The dashboard is rebuilt from git, so a change to it goes through the same review as a change to SQL.
