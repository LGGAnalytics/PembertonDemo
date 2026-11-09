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
                                                                                          │   COMMIT            ← or: ROLLBACK, log ERROR, etl_run = Error, COMMIT, RAISE
                                                                                          └─► usp_audit_finish (Success) + watermark advance
```

- **`dbo.etl_run`** is the audit header, opened and committed before anything else, so a crashed run is visible as `Processing`.
- **`dbo.usp_discover_periods`** fills `tmp_periods` (`row_num`, `as_of_date`): every mark date in full mode; in incremental mode the union of mark dates, cash-flow months (expanded to every later month-end) and FX dates whose staging rows have `_loaded_at` after the watermark minus `overlap_hours`, within `lookback_months` of the latest month-end.
- **Per-period transaction.** Each period is `DELETE WHERE as_of_date` + `INSERT`, then committed. A failure rolls back only that period; earlier periods stay committed, the error is written to `dbo.etl_run_log` (`status = 'ERROR'`) and `dbo.etl_run` (`status = 'Error'`), both committed, and the exception is re-raised so the pipeline exits non-zero. The watermark does not move.
- **Dimensions** are reloaded with `DELETE` + `INSERT` (foreign keys that reference them are `DEFERRABLE INITIALLY DEFERRED`, so the reload is checked at `COMMIT`). Facilities that disappear from the source have their periodised rows removed and explained in `dbo.etl_reject` (`facility removed from source`).
- **Lineage.** Every periodised row carries `etl_run_id` and `loaded_at`.
- **Test hook.** `dbo.etl_config.fail_on_period` makes `usp_build_facility_month` raise for one period; test t15 uses it to prove the rollback path. It must be `NULL` in normal operation.

## Layer 1: staging

- One table per source extract: `staging.funds`, `borrowers`, `facilities`, `loan_marks`, `cash_flows`, `borrower_financials`, `fx_rates` and `reference_rates`.
- Every business column is `TEXT`, so nothing can fail at load time and the original values are kept for audit.
- Each table has lineage columns: `_row_id` (identity, in file order), `_source_file` and `_loaded_at`.
- There are no keys or constraints. Duplicates and bad rows are kept on purpose; the ETL decides what to do with them.

## Layer 2: dbo (stored procedures, then treated tables)

The master procedure `dbo.usp_run_etl(p_mode, p_lookback_months, p_periods)` opens the run header, reloads the dimensions, discovers the periods and then loops over them (see "The run contract" above). Steps in order:

| # | Procedure | Source → target | Rules |
|---|---|---|---|
| 1 | `dbo.usp_load_fund` | `staging.funds` → `dbo.fund` | Typed; rejects a fund with a missing key, name, vintage or size |
| 2 | `dbo.usp_load_borrower` | `staging.borrowers` → `dbo.borrower` | Sector conformed to `dbo.ref_sector`, ignoring case and whitespace. Country given as ISO-2, ISO-3 or full name becomes ISO-2 via `dbo.ref_country`. Sets `is_sponsored`. |
| 3 | `dbo.usp_load_facility` | `staging.facilities` → `dbo.facility` | Mixed date formats parsed. Thousands separators stripped. Instrument conformed. Currency upper-cased. `tenor_years` derived. Rejects impossible dates, non-numeric amounts, unknown borrowers or funds, and maturities before origination. |
| 4 | `dbo.usp_load_market_data` | `staging.fx_rates` and `reference_rates` → `dbo.fx_rate` and `dbo.reference_rate` | Typed; rejects non-positive FX rates |
| 5 | `dbo.usp_discover_periods` | staging `_loaded_at` + `dbo.etl_watermark` → `tmp_periods` | Decides which month-ends this run rebuilds (see "The run contract") |
| 6 | `dbo.usp_load_loan_mark` **(per period)** | `staging.loan_marks` → `dbo.loan_mark` | Y/N becomes `BOOLEAN`. A missing rating is kept as `NULL` and shown as "Not rated". Rejects marks for unknown facilities. `DELETE` the period + `INSERT`. |
| 7 | `dbo.usp_build_facility_month` **(per period)** | `dbo.loan_mark` + `facility` + `reference_rate` → `dbo.facility_month` | Local-currency measures. All-in rate = max(base rate, floor) + spread. Sets `risk_status`. Rejects marks without a reference rate. |
| 8 | `dbo.usp_apply_fx_rates` **(per period)** | `dbo.fx_rate` → `dbo.facility_month` | `UPDATE` to EUR at month-end FX (the client's `usp_UpdatePositionFxRates`). Rows still without FX are removed from the period and rejected. |
| – | `dbo.usp_load_cash_flow`, `dbo.usp_load_borrower_financials` | staging → dbo | Not periodised; run with the dimensions. Transaction type conformed; a missing EBITDA is kept as `NULL`. |
| – | `dbo.usp_audit_start` / `dbo.usp_audit_finish` | → `dbo.etl_run`, `dbo.etl_watermark` | Open / close the run header; advance the watermark on Success |

Every procedure follows the same pattern:

1. Count the staging rows read.
2. Parse into a temp table. Exact duplicates are removed with `DISTINCT ON (business key)`, and the latest staged row wins.
3. Write invalid rows, with their reasons and the raw record as JSON, to **`dbo.etl_reject`**.
4. Reload the target: dimensions with `DELETE` + `INSERT`; periodised tables with `DELETE WHERE as_of_date = p_as_of_date` + `INSERT`. Tables are never dropped, so the views on top stay valid.
5. Log the read, loaded and rejected counts to **`dbo.etl_run_log`** with `dbo.usp_log_step`, one row per procedure **per period**.

The parse helpers in `sql/02_dbo/03_functions.sql` are `fn_clean_text`, `fn_try_date`, `fn_try_numeric`, `fn_conform` and `fn_country_code`. Each returns `NULL` instead of raising an error, so a bad value becomes a reject rather than crashing the run.

**Risk status**, in priority order: `Non-accrual` (flag set), then `Impaired` (rating 5), then `Watchlist` (rating 4 or DPD ≥ 30), otherwise `Performing`.

## Layer 3: bi (views for the dashboard)

| View | Grain | Used by |
|---|---|---|
| `bi.vw_facility_exposure` | facility × month, fully described (fund, borrower, sector, country, instrument, EUR measures, risk); `is_latest_month` flag | sector, country, instrument and rating cards |
| `bi.vw_portfolio_monthly` | month × fund. Weighted averages are shipped as numerator and denominator (`spread_x_outstanding`, `all_in_rate_x_outstanding`) so they re-aggregate correctly | KPI tiles and the exposure trend |
| `bi.vw_cash_flow_monthly` | month × fund × transaction type, in EUR | interest received |
| `bi.vw_watchlist` | latest month, facilities not Performing, with `severity_rank` | watchlist table |
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

## Data-quality tests (`tests/sql`)

| Test | Checks |
|---|---|
| t01 | every staging table was loaded |
| t02 | every staged facility ends up in `dbo` or in `etl_reject` (reconciliation) |
| t03 | the two seeded bad rows (F99901 and F99902) are rejected |
| t04 | sectors and countries are conformed to the reference data |
| t05 | every mark reached the EUR fact (no FX or reference-rate gaps) |
| t06 | rates, prices and amounts are within plausible bounds |
| t07 | one fact row per facility per month (grain) |
| t08 | every dashboard view returns data |
| t09 | `bi` totals reconcile to `dbo` |
| t10 | the latest `dbo.etl_run` is `Success` with every planned period done |
| t11 | one log row per (procedure, period); FX-converted rows equal the fact rows |
| t12 | every periodised row points at a successful run (and at the latest one after a full run) |
| t13 | watermark = `max(_loaded_at)` per staging table |
| t14 | run views populated and readable by `bi_reader` |
| t15 | **error path**: injected failure in period P2 of [P1, P2, P3] → run `Error`, P1 committed, P2/P3 untouched, watermark unchanged; then restored |
| t16 (`tests/incremental`) | after `make incremental`: exactly one period rebuilt, restated prices applied, other months untouched |

## Design choices (and what production would do)

- **Full redeploy, then full or incremental ETL.** `make pipeline` drops and recreates every object (deterministic demo); `make incremental` shows the production shape: watermark, period discovery, per-period rebuild. Production would add versioned migrations (Flyway or Liquibase) and a scheduler (Airflow or Data Factory).
- **One transaction per period, audited.** A failed period is rolled back, earlier periods stay, and the failure is visible in `dbo.etl_run` and on the dashboard. This mirrors the client's production procedures (spec 002).
- **`overlap_hours = 0` in the demo.** The client re-reads 4 hours before the watermark; here the full load and the delta are minutes apart, so a 4-hour overlap would rebuild everything.
- **Dashboard as code.** The dashboard is rebuilt from git, so a change to it goes through the same review as a change to SQL.
