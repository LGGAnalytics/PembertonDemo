# Pipeline architecture

## Execution flow (`scripts/run_pipeline.sh`)

| Step | What runs | Notes |
|---|---|---|
| 1. Deploy | `sql/00_reset.sql`, then `sql/01_staging/0*.sql`, `sql/02_dbo/*.sql` and `sql/03_bi/*.sql` in file order | Full rebuild. Every object is defined in versioned SQL files. |
| 2. Stage | `sql/01_staging/10_load_staging.sql` | `TRUNCATE` and `\copy` of each CSV, loaded as-is |
| 3. ETL | `CALL dbo.usp_run_etl();` | Runs in one transaction, so it is all or nothing |
| 4. Test | `scripts/run_tests.sh` runs `tests/sql/t*.sql` | Any non-zero count fails the run |

`make dashboard` runs afterwards and builds the Metabase dashboard from `metabase/`.

## Layer 1: staging

- One table per source extract: `staging.funds`, `borrowers`, `facilities`, `loan_marks`, `cash_flows`, `borrower_financials`, `fx_rates` and `reference_rates`.
- Every business column is `TEXT`, so nothing can fail at load time and the original values are kept for audit.
- Each table has lineage columns: `_row_id` (identity, in file order), `_source_file` and `_loaded_at`.
- There are no keys or constraints. Duplicates and bad rows are kept on purpose; the ETL decides what to do with them.

## Layer 2: dbo (stored procedures, then treated tables)

The master procedure `dbo.usp_run_etl()` generates a `run_id` and calls the steps below in foreign-key order:

| # | Procedure | Source → target | Rules |
|---|---|---|---|
| 1 | `dbo.usp_load_fund` | `staging.funds` → `dbo.fund` | Typed; rejects a fund with a missing key, name, vintage or size |
| 2 | `dbo.usp_load_borrower` | `staging.borrowers` → `dbo.borrower` | Sector conformed to `dbo.ref_sector`, ignoring case and whitespace. Country given as ISO-2, ISO-3 or full name becomes ISO-2 via `dbo.ref_country`. Sets `is_sponsored`. |
| 3 | `dbo.usp_load_facility` | `staging.facilities` → `dbo.facility` | Mixed date formats parsed. Thousands separators stripped. Instrument conformed. Currency upper-cased. `tenor_years` derived. Rejects impossible dates, non-numeric amounts, unknown borrowers or funds, and maturities before origination. |
| 4 | `dbo.usp_load_market_data` | `staging.fx_rates` and `reference_rates` → `dbo.fx_rate` and `dbo.reference_rate` | Typed; rejects non-positive FX rates |
| 5 | `dbo.usp_load_loan_mark` | `staging.loan_marks` → `dbo.loan_mark` | Y/N becomes `BOOLEAN`. A missing rating is kept as `NULL` and shown as "Not rated". Rejects marks for unknown facilities. |
| 6 | `dbo.usp_load_cash_flow` | `staging.cash_flows` → `dbo.cash_flow` | Transaction type conformed to Drawdown, Repayment, Interest or Fee |
| 7 | `dbo.usp_load_borrower_financials` | `staging.borrower_financials` → `dbo.borrower_financials` | A missing EBITDA (late reporting) is kept as `NULL`, not rejected |
| 8 | `dbo.usp_build_facility_month` | `dbo.loan_mark` + `facility` + `fx_rate` + `reference_rate` → `dbo.facility_month` | Converts to EUR at month-end FX. All-in rate = max(base rate, floor) + spread. Sets `risk_status`. |

Every procedure follows the same pattern:

1. Count the staging rows read.
2. Parse into a temp table. Exact duplicates are removed with `DISTINCT ON (business key)`, and the latest staged row wins.
3. Write invalid rows, with their reasons and the raw record as JSON, to **`dbo.etl_reject`**.
4. `TRUNCATE` the target and `INSERT` the valid rows. The tables are never dropped, so the views on top stay valid.
5. Log the read, loaded and rejected counts to **`dbo.etl_run_log`** with `dbo.usp_log_step`.

The parse helpers in `sql/02_dbo/03_functions.sql` are `fn_clean_text`, `fn_try_date`, `fn_try_numeric`, `fn_conform` and `fn_country_code`. Each returns `NULL` instead of raising an error, so a bad value becomes a reject rather than crashing the run.

**Risk status**, in priority order: `Non-accrual` (flag set), then `Impaired` (rating 5), then `Watchlist` (rating 4 or DPD ≥ 30), otherwise `Performing`.

## Layer 3: bi (views for the dashboard)

| View | Grain | Used by |
|---|---|---|
| `bi.vw_facility_exposure` | facility × month, fully described (fund, borrower, sector, country, instrument, EUR measures, risk); `is_latest_month` flag | sector, country, instrument and rating cards |
| `bi.vw_portfolio_monthly` | month × fund. Weighted averages are shipped as numerator and denominator (`spread_x_outstanding`, `all_in_rate_x_outstanding`) so they re-aggregate correctly | KPI tiles and the exposure trend |
| `bi.vw_cash_flow_monthly` | month × fund × transaction type, in EUR | interest received |
| `bi.vw_watchlist` | latest month, facilities not Performing, with `severity_rank` | watchlist table |
| `bi.vw_etl_run_summary` | last ETL run, one row per procedure | pipeline health table |

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

## Design choices (and what production would do)

- **Full refresh, full rebuild.** This keeps the demo deterministic. Production would use incremental `MERGE`, versioned migrations (Flyway or Liquibase) and a scheduler (Airflow or cron).
- **Single-transaction ETL.** A failed run leaves the previous `dbo` data untouched.
- **Dashboard as code.** The dashboard is rebuilt from git, so a change to it goes through the same review as a change to SQL.
