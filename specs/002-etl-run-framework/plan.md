# Plan 002: ETL run framework

> Written at the sponsor's request before approval. Implemented 2026-11-06. **Deviations found during implementation:** (1) dimensions are reloaded with `DELETE` + `INSERT`, not `TRUNCATE`, because FK-referenced tables cannot be truncated without `CASCADE`; all dimension FKs became `DEFERRABLE INITIALLY DEFERRED` (this also fixed a latent bug: `borrower_financials`/`cash_flow` FKs blocked any second run on a populated warehouse). (2) `overlap_hours` is seeded `0`. (3) Discovery uses strict `>` on `_loaded_at`. (4) `COMMIT` cannot sit inside a PL/pgSQL block with an `EXCEPTION` clause, so the loop uses a success flag and commits/rolls back after the block. (5) Incremental tests run before `tests/sql` because t15 rebuilds three periods.
> Order of work follows the layers in `CLAUDE.md`. Every file below is either **new**, **modified** or **unchanged but re-verified**.

## 0. Decisions carried into the plan
| Decision | Choice | Why |
|---|---|---|
| Transaction model | One `COMMIT` per period, dimensions committed before the loop | Mirrors the client; gives per-period rollback and visible audit rows |
| Where EUR conversion happens | `usp_apply_fx_rates` (UPDATE after INSERT) | Mirrors `usp_UpdatePositionFxRates`; fact gets `*_local` columns |
| `facility_month` NOT NULL on `*_eur` | Relaxed to NULL; rows still NULL after FX are deleted + rejected inside the same period transaction | Readers never see unconverted rows after COMMIT |
| Period discovery for cash flows | Expands to every later month-end within lookback | Cost basis is cumulative (spec 003) |
| Error-path test | `dbo.etl_config.fail_on_period` hook | Only deterministic way to prove rollback without destroying data |
| `00_reset.sql` | Unchanged: full redeploy drops everything, so `make pipeline` is still deterministic | Incremental mode is demonstrated by `make incremental` **after** a pipeline run, not by skipping the reset |

## 1. Staging layer
| File | Change |
|---|---|
| `sql/01_staging/01_create_staging_tables.sql` | unchanged (`_loaded_at` already exists and is the watermark source) |
| `sql/01_staging/10_load_staging.sql` | unchanged |
| `sql/01_staging/11_load_delta.sql` | **new**: no TRUNCATE; `\copy` of `data/raw/delta/loan_marks.csv` (one restated month) and `data/raw/delta/cash_flows.csv` (late transactions) with `_source_file = 'delta/…'` |
| `data/generator/generate_data.py` | **modified**: emit `data/raw/delta/` — restate month `MONTHS[-2]` marks for ~15 facilities with changed prices and add 5 late cash flows; deterministic with seed 42 |
| `data/raw/delta/*.csv` | **new** (generated) |

## 2. dbo layer
### 2.1 DDL — `sql/02_dbo/01_create_dbo_tables.sql` (modified)
```sql
CREATE TABLE dbo.etl_run (
    run_id           UUID PRIMARY KEY,
    source           TEXT        NOT NULL,
    triggered_by     TEXT        NOT NULL,
    mode             TEXT        NOT NULL CHECK (mode IN ('full','incremental')),
    status           TEXT        NOT NULL CHECK (status IN ('Processing','Success','Error')),
    message          TEXT,
    periods_planned  INT,
    periods_done     INT         NOT NULL DEFAULT 0,
    started_at       TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    finished_at      TIMESTAMPTZ
);
CREATE TABLE dbo.etl_watermark (source_table TEXT PRIMARY KEY, high_water_loaded_at TIMESTAMPTZ NOT NULL, updated_by_run UUID);
CREATE TABLE dbo.etl_config    (config_key TEXT PRIMARY KEY, config_value TEXT, description TEXT);
-- etl_run_log: + as_of_date DATE, + message TEXT, status CHECK IN ('SUCCESS','ERROR')
-- etl_reject : + as_of_date DATE
-- loan_mark, facility_month: + etl_run_id UUID NOT NULL, + loaded_at TIMESTAMPTZ NOT NULL
-- facility_month: + commitment_local, outstanding_local, undrawn_local, fair_value_local NUMERIC(18,2) NOT NULL;
--                 fx_eur_per_unit, commitment_eur, outstanding_eur, undrawn_eur, fair_value_eur -> NULL allowed
-- indexes: loan_mark(as_of_date), facility_month(as_of_date), etl_run_log(run_id, as_of_date)
```
Comments on every new column.

### 2.2 Seeds — `sql/02_dbo/02_seed_reference_data.sql` (modified)
`etl_config`: `lookback_months = 6`, `overlap_hours = 4`, `fail_on_period = NULL` (described as test hook).

### 2.3 Helpers — `sql/02_dbo/03_functions.sql` (modified)
- `dbo.fn_month_end(d DATE) RETURNS DATE`
- `dbo.fn_month_ends_from(d DATE, last DATE) RETURNS SETOF DATE` (period expansion for cash flows / ratings)
- `dbo.fn_config_int(key TEXT, dflt INT) RETURNS INT`

### 2.4 Procedures
| File | Status | Content |
|---|---|---|
| `10_usp_log_step.sql` | modified | New optional params `p_as_of_date`, `p_status`, `p_message`; `RAISE INFO` prefixed with the period |
| `10a_usp_audit.sql` | **new** | `usp_audit_start(p_source, p_triggered_by, p_mode, INOUT p_run_id)` and `usp_audit_finish(p_run_id, p_status, p_message)` (also sets `finished_at`, and on `Success` advances `etl_watermark` from values captured at discovery) |
| `10b_usp_discover_periods.sql` | **new** | Builds `tmp_periods` as in spec §8.2; records `periods_planned` on `etl_run`; stores candidate watermarks in `tmp_watermark` |
| `11`–`13`, `16`, `17` (fund, borrower, facility, financials, market data) | modified lightly | Signature unchanged. Only `TRUNCATE … CASCADE` on `facility` reviewed: it would cascade-truncate `facility_month`/`loan_mark` in incremental mode → replaced by `TRUNCATE dbo.facility` after a guard that deletes orphan periodised rows explicitly and rejects them |
| `14_usp_load_loan_mark.sql` | modified | Period-scoped as in spec §8.4 |
| `15_usp_load_cash_flow.sql` | unchanged here (spec 003 touches it) | |
| `20_usp_build_facility_month.sql` | modified | Period-scoped; inserts local-currency measures, `fx_eur_per_unit NULL`; base-rate join stays (rejects without reference rate are written per period); honours `fail_on_period` |
| `21_usp_apply_fx_rates.sql` | **new** | Spec §8.5 |
| `99_usp_run_etl.sql` | rewritten | Spec §8.1 + §8.3: audit start → dimensions → `COMMIT` → discover periods → loop → audit finish `Success` → watermark advance |

### 2.5 Behaviour of `TRUNCATE` on dimensions in incremental mode
Dimensions are still fully reloaded each run (source files are full extracts). Because `facility` is referenced by periodised tables, the FK makes `TRUNCATE dbo.facility` fail unless `CASCADE`. Plan: load into `tmp_facility`, compute the set of facility_ids that would disappear, delete their periodised rows (writing a reject `facility removed from source`), then `TRUNCATE dbo.facility` (no CASCADE) and insert. Same for `borrower` and `fund` through `facility`. This keeps rule "never drop, never silently lose data".

## 3. bi layer — `sql/03_bi/01_create_bi_views.sql` (modified), `99_grants.sql` (unchanged, schema grant covers new views)
- `bi.vw_etl_run_summary`: latest run, `etl_run` header joined to its log rows; columns `run_id, mode, run_status, procedure_name, as_of_date, status, rows_read, rows_loaded, rows_rejected, duration_s, message, finished_at`.
- `bi.vw_etl_run_history` (new): last 20 runs with `periods_done || '/' || periods_planned AS periods`, `duration_s`, `status`, `message`.
- `bi.vw_facility_exposure`, `bi.vw_portfolio_monthly`: unchanged column list (they read `*_eur`, now never NULL after COMMIT).

## 4. Tests — `tests/sql/` (new files; each returns one integer)
| Test | AC | Method |
|---|---|---|
| `t10_run_header_success.sql` | AC1 | latest `etl_run` is `Success`, `periods_done = periods_planned`, `finished_at` set |
| `t11_log_per_period.sql` | AC2 | one log row per (procedure, period); sum of loaded for build = count of fact |
| `t12_lineage_run_id.sql` | AC3 | all periodised rows carry latest successful `run_id` |
| `t13_watermark.sql` | AC6 | watermark = `max(_loaded_at)` per staging table |
| `t14_bi_run_views.sql` | AC7 | both views return rows; `SET ROLE bi_reader` select works |
| `t15_error_path.sql` | AC5 | `\set ON_ERROR_STOP off`; set hook = P2; `CALL dbo.usp_run_etl('incremental', NULL, ARRAY[P1,P2,P3])` (expected to fail); assert header/log/run_id state into a temp table; clear hook; re-run `[P2,P3]`; `\set ON_ERROR_STOP on`; emit the assertion count. Runs **last** alphabetically so other tests see a clean state; the run it leaves behind is `Success` |
| `t16_incremental_delta.sql` | AC4 | only executed by `make incremental` (script `scripts/run_incremental_tests.sh` runs `t0*`, `t1*` and `tests/incremental/*.sql`); compares `etl_run_id` per month against the previous run |
| `t01`–`t09` | AC8 | unchanged, re-run |

## 5. Metabase
| File | Change |
|---|---|
| `metabase/cards/pipeline_health.sql` | modified: add `as_of_date`, `status`, `message`; order by `as_of_date, finished_at` |
| `metabase/cards/pipeline_runs.sql` | **new**: from `bi.vw_etl_run_history` |
| `metabase/dashboard.json` | modified: `pipeline_health` height 8; new `pipeline_runs` table card beside it; conditional formatting `status = 'Error'` red, else `#3D7CC9` |

## 6. Scripts, Make, docs
| File | Change |
|---|---|
| `scripts/run_pipeline.sh` | step 3 unchanged (`CALL dbo.usp_run_etl();` = full) |
| `scripts/run_incremental.sh` | **new**: `11_load_delta.sql` → `CALL dbo.usp_run_etl('incremental');` → incremental tests |
| `Makefile` | **new target** `incremental` (compose `run --rm --entrypoint sh pipeline /workspace/scripts/run_incremental.sh`) |
| `docker-compose.yml` | unchanged |
| `CLAUDE.md` | rule 2 bullet 3 → "Dimension tables are reloaded with `TRUNCATE` + `INSERT`. Periodised tables (`loan_mark`, `facility_month`, …) are rebuilt per `as_of_date` with `DELETE` + `INSERT` inside the period loop of `dbo.usp_run_etl`. Never drop tables inside a procedure." New bullet: "Every procedure that runs inside the period loop takes `(p_run_id UUID, p_as_of_date DATE)` and logs one row per period." |
| `docs/ARCHITECTURE.md` | "Execution flow" gains the audit/discover/loop description and a sequence diagram in text; procedure table gains `usp_audit_*`, `usp_discover_periods`, `usp_apply_fx_rates`; new section "Incremental mode and `make incremental`" |
| `docs/DATA_DICTIONARY.md` | new tables `etl_run`, `etl_watermark`, `etl_config`; new columns on `etl_run_log`, `etl_reject`, `loan_mark`, `facility_month` |
| `docs/DEMO_RUNBOOK.md` | add the incremental demo step and the "break it" step (set `fail_on_period`, show the red row, clear, re-run) |
| `specs/README.md` | status column |

## 7. Order of implementation (becomes `tasks.md` on approval)
1. DDL + seeds + helpers → `make pipeline` still green with the old procedures (columns nullable/defaulted so nothing breaks).
2. `usp_log_step`, `usp_audit_*`, `usp_discover_periods` → unit-checked with `CALL` in psql.
3. Period-scope `usp_load_loan_mark`, `usp_build_facility_month`; add `usp_apply_fx_rates`.
4. Rewrite `usp_run_etl`; `make pipeline` green; t10–t14.
5. Delta generator + `11_load_delta.sql` + `run_incremental.sh` + `make incremental`; t16.
6. Error-path t15.
7. bi views, Metabase cards, `make dashboard`.
8. Docs, CLAUDE.md, spec `Status: Done`.

## 8. Risks
- `COMMIT` inside a procedure fails if `usp_run_etl` is ever called from within a transaction (e.g. a `DO` block or Metabase). Document: top-level `CALL` only.
- `TRUNCATE … CASCADE` currently on `facility`: must go (see 2.5) or incremental mode silently wipes the fact.
- Test t15 mutates `dbo.etl_config` and reruns two periods; it must restore state even if an assertion fails (use `\set ON_ERROR_STOP off` around the whole body and a final clean-up statement).
