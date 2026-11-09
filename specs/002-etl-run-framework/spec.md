# Spec 002: ETL run framework — audited, incremental, period-by-period

| | |
|---|---|
| **Status** | Done |
| **Owner** | Data Engineering |
| **Requested by** | Demo sponsor (to mirror the client's production ETL patterns) |
| **Date** | 2026-11-06 |

## 1. Business context
The client's warehouse procedures (e.g. `usp_CreatePositionEquityCost`) do not simply truncate and reload.
They (a) open an audit record before doing anything, (b) discover **which dates changed** since the last run,
(c) loop those dates one at a time inside a transaction with TRY/CATCH, (d) call other procedures per date
(FX rates, ratings), and (e) on failure roll back only the current date, write the error to the audit table and re-throw.

The demo's `dbo.usp_run_etl` today is one all-or-nothing transaction with a single log line per procedure.
This spec brings the demo procedures to the same operational shape so the audience sees a credible production pipeline,
not a toy load. Specs 003 and 004 then add the heavy per-period calculations on top of this frame.

### Pattern map (client → demo)
| Client (SQL Server) | Demo (PostgreSQL) |
|---|---|
| `usp_ETL_AuditInsert @Status='Processing'` / `usp_ETL_AuditUpdate @Status='ERROR'` | `dbo.usp_audit_start` / `dbo.usp_audit_finish` writing `dbo.etl_run` (run header) |
| `@Dates TABLE` built from `AuditUpdated >= DATEADD(HOUR,-4,MAX(AuditUpdated))`, UNION across Lot / Transaction / AssetMark, 6-month lookback | `dbo.usp_discover_periods` builds `tmp_periods` from `staging.*._loaded_at` vs `dbo.etl_watermark`, UNION across loan marks / cash flows / FX / ratings, with a 4-hour overlap and a lookback in months |
| `WHILE @Counter <= @MaxCounter ... BEGIN TRY BEGIN TRAN ... COMMIT END TRY BEGIN CATCH ROLLBACK; audit ERROR; THROW END CATCH` | `FOR r IN SELECT ... FROM tmp_periods ORDER BY row_num LOOP BEGIN ... COMMIT; EXCEPTION WHEN OTHERS THEN ROLLBACK; audit ERROR; COMMIT; RAISE; END; END LOOP` |
| `DELETE FROM dbo.Position WHERE AsOfDate = @currentDate` then `INSERT` | `DELETE FROM dbo.facility_month WHERE as_of_date = r.as_of_date` then `INSERT`, in both full and incremental mode |
| `EXEC dbo.usp_UpdatePositionFxRates @AsOfDate_From, @AsOfDate_To` inside the loop | `CALL dbo.usp_apply_fx_rates(p_run_id, r.as_of_date)` inside the loop (FX conversion moves out of the INSERT into its own procedure) |
| `PRINT CONVERT(VARCHAR(10), @currentDate, 120)` | `RAISE INFO` per period, plus one `dbo.etl_run_log` row per procedure **per period** |

## 2. Definition
This spec adds no business metric. It defines the **run contract**:

- **Run header** `dbo.etl_run`: one row per `CALL dbo.usp_run_etl(...)`, with `status` in `Processing → Success | Error`, `source`, `triggered_by`, `mode`, `message`, `periods_planned`, `periods_done`, `started_at`, `finished_at`.
- **Modes:** `full` (default: every period present in the data) and `incremental` (only periods changed since the watermark). Signature: `dbo.usp_run_etl(p_mode TEXT DEFAULT 'full', p_lookback_months INT DEFAULT 6, p_periods DATE[] DEFAULT NULL)`. `p_periods` forces an explicit list (used by operators and tests).
- **Period** = a month-end `as_of_date`. Dimension tables (`fund`, `borrower`, `facility`, reference data, `fx_rate`, `reference_rate`) are not periodised and keep TRUNCATE + INSERT, committed **before** the period loop. Periodised tables (`loan_mark`, `facility_month`, and the tables added by specs 003/004) are rebuilt **per period** with DELETE + INSERT.
- **Watermark** `dbo.etl_watermark(source_table, high_water_loaded_at)`: advanced only when a run ends in `Success`.
- **Lineage columns** on every periodised table: `etl_run_id UUID NOT NULL`, `loaded_at TIMESTAMPTZ NOT NULL`.

## 3. Source data and lineage
| Layer | Object | Change |
|---|---|---|
| staging | `sql/01_staging/10_load_staging.sql` | Unchanged for full loads. New `sql/01_staging/11_load_delta.sql` appends `data/raw/delta/*.csv` (a restated month of loan marks and a few late cash flows) without truncating, to demonstrate incremental mode |
| dbo | `dbo.etl_run` (new), `dbo.etl_watermark` (new), `dbo.etl_config` (new, key/value) | Run header, watermark, and config (`lookback_months`, `overlap_hours`, test hook `fail_on_period`) |
| dbo | `dbo.etl_run_log` | Add `as_of_date DATE NULL`, `message TEXT NULL`; `status` gains `'ERROR'` |
| dbo | `dbo.loan_mark`, `dbo.facility_month` | Add `etl_run_id`, `loaded_at` |
| dbo | `dbo.usp_audit_start`, `dbo.usp_audit_finish`, `dbo.usp_discover_periods`, `dbo.usp_apply_fx_rates` (new) | See §4 |
| dbo | `dbo.usp_load_loan_mark`, `dbo.usp_build_facility_month` | Become period-scoped: signature `(p_run_id UUID, p_as_of_date DATE)`; DELETE + INSERT for that period only |
| dbo | `dbo.usp_run_etl` | Rewritten as the orchestrator described in §4 |
| bi | `bi.vw_etl_run_summary` | Rebased on `dbo.etl_run` + `dbo.etl_run_log`; shows status, mode, periods done/planned, per-period rows and error message |
| bi | `bi.vw_etl_run_history` (new) | Last 20 runs, for the pipeline card |
| Metabase | `pipeline_health` card | Shows run status (colour: Success blue `#3D7CC9`, Error red), mode, periods, duration; new `pipeline_runs` table card |
| Make | `Makefile` | New target `make incremental` = load delta + `CALL dbo.usp_run_etl('incremental')` + tests |
| docs | `CLAUDE.md`, `docs/ARCHITECTURE.md` | Rule 2 amended: "periodised tables are rebuilt with DELETE by period + INSERT; dimensions with TRUNCATE + INSERT; never drop" |

## 4. Rules and edge cases
| Case | Expected result |
|---|---|
| Run start | `usp_audit_start` inserts `dbo.etl_run` with `status='Processing'` and **commits** before any load, so a crashed run is visible as `Processing` |
| Period discovery, `full` | All distinct month-ends in `staging.loan_marks` (parsed) |
| Period discovery, `incremental` | Distinct month-ends from rows whose `_loaded_at > watermark − overlap_hours` (strictly after: all rows of one `\copy` share the same `_loaded_at`) in loan marks ∪ month-end of such cash flows ∪ FX dates ∪ rating `valid_from` (spec 004), restricted to `as_of_date ≥ current month-end − lookback_months`. Empty set → run ends `Success` with `periods_planned = 0` |
| Period order | Ascending `as_of_date`; each period is its own transaction and is **committed** when its procedures finish |
| Failure inside a period | Current period rolled back, `etl_run_log` row with `status='ERROR'` and the SQLERRM for that procedure and period, `dbo.etl_run.status='Error'` with the same message, both committed, then the exception is re-raised (the pipeline exits non-zero). Periods already committed stay. Watermark is **not** advanced |
| Failure before the loop (dimension load) | Same audit behaviour; no period is touched |
| Rejects | Unchanged semantics: a reject is **not** a failure. Reject rows carry `as_of_date` so they can be filtered per period |
| Nested calls | `usp_build_facility_month` inserts local-currency rows with `fx_eur_per_unit = NULL`, then calls `usp_apply_fx_rates` (UPDATE … FROM `dbo.fx_rate` for that period), then the spec 003/004 procedures. Rows still without FX after the call are deleted from the period and written to `etl_reject` with reason `no FX rate` |
| Watermark advance | Only on `Success`; set to `max(_loaded_at)` of each staging table at the time of discovery (not at the end), so rows loaded during the run are picked up next time |
| Test hook | If `dbo.etl_config.fail_on_period` equals the current period, `usp_build_facility_month` raises `'Injected failure for period %'`. Documented as test-only; absent/NULL in normal runs |
| `overlap_hours` in the demo | Seeded `0` (the client uses 4): the full load and the delta happen minutes apart, so any positive overlap would re-read the whole load |
| Dimension reload | `DELETE` + `INSERT` (not `TRUNCATE`): a table referenced by a foreign key cannot be truncated without `CASCADE`, which would wipe the periodised facts in incremental mode. All FKs that point at dimensions are `DEFERRABLE INITIALLY DEFERRED` |
| Re-run after failure | `CALL dbo.usp_run_etl('incremental')` with the hook cleared rebuilds the failed and following periods; earlier periods are untouched (same `etl_run_id` as before) |

## 5. Acceptance criteria (each one becomes a test in `tests/sql/`)
- **AC1:** After `make pipeline`, exactly one `dbo.etl_run` row exists for the latest run with `status='Success'`, `periods_done = periods_planned`, `finished_at IS NOT NULL`.
- **AC2:** `dbo.etl_run_log` has one row per `(procedure, as_of_date)` for every period, and `sum(rows_loaded)` of `usp_build_facility_month` equals `count(*)` of `dbo.facility_month`.
- **AC3:** Every row of `dbo.facility_month` and `dbo.loan_mark` has `etl_run_id` equal to the latest successful run after a full load.
- **AC4:** After `make incremental` (delta touches exactly one restated month M), rows for month M carry the new `etl_run_id`; rows for every other month keep the previous one, and totals for the other months are unchanged.
- **AC5 (error path):** With `fail_on_period` set to period P2 of an explicit list `[P1, P2, P3]`, the call raises; afterwards `dbo.etl_run.status='Error'` and `message` contains P2; `etl_run_log` has an `ERROR` row for `(usp_build_facility_month, P2)`; P1 rows carry the failed run's `etl_run_id`; P2 and P3 rows keep their previous `etl_run_id`; watermark unchanged. The test clears the hook and re-runs `[P2, P3]` to restore the state, and all other tests still pass afterwards.
- **AC6:** `dbo.etl_watermark` equals `max(_loaded_at)` per staging table after a successful run, and is unchanged after the failed run in AC5.
- **AC7:** `bi.vw_etl_run_summary` returns one row per `(procedure, as_of_date)` of the latest run and `bi.vw_etl_run_history` returns the latest run first; `bi_reader` can select both.
- **AC8:** Existing tests t01–t09 still pass in full mode and after `make incremental`.

## 6. Dashboard impact
- `pipeline_health` card: add columns `status`, `mode`, `as_of_date`, `message`; conditional colour on status.
- New `pipeline_runs` card (table, last 20 runs): `started_at`, `mode`, `status`, `periods_done/planned`, `duration_s`, `message`.
- Neither card is fund-filterable (no `fund_code`), as today.

## 7. Out of scope
- Parallel period processing.
- Scheduling / orchestration outside Postgres (Data Factory equivalent).
- Retention of `etl_run_log` and `etl_reject` (grows unbounded in the demo).
- The per-period business calculations themselves (specs 003 and 004).

## 8. Current queries vs target shape (what "same quality as the client" means here)

Each block shows the demo code **as it is today** and the **target** written in the client's style, translated to PL/pgSQL.
The target blocks are the standard every `dbo.usp_*` must follow once this spec is approved.

### 8.1 Procedure header and audit record

**Client (screenshot 5, lines 10–15):** the first statement opens an audit row with `@Status = 'Processing'`, source and user, and gets the `@AuditID` back. Every later error updates that same row.

**Demo today** (`99_usp_run_etl.sql`): no header row. `gen_random_uuid()` is generated, used as a correlation id and logged only per step at the end of each procedure.
```sql
DECLARE v_run_id UUID := gen_random_uuid(); v_start TIMESTAMPTZ := clock_timestamp();
BEGIN
    RAISE INFO 'ETL run % started', v_run_id;
    CALL dbo.usp_load_fund(v_run_id);
    ...
```

**Target**
```sql
CREATE OR REPLACE PROCEDURE dbo.usp_run_etl(
    p_mode            TEXT   DEFAULT 'full',        -- 'full' | 'incremental'
    p_lookback_months INT    DEFAULT NULL,          -- NULL -> dbo.etl_config
    p_periods         DATE[] DEFAULT NULL)          -- explicit list overrides discovery
LANGUAGE plpgsql AS $$
DECLARE
    v_run_id   UUID;
    v_period   RECORD;
    v_done     INT := 0;
    v_msg      TEXT;
BEGIN
    -- 1. audit header, committed immediately (client: usp_ETL_AuditInsert @Status='Processing')
    CALL dbo.usp_audit_start(p_source => 'csv-extracts', p_triggered_by => current_user,
                             p_mode => p_mode, p_run_id => v_run_id);
    COMMIT;
    ...
EXCEPTION WHEN OTHERS THEN
    v_msg := format('%s [%s]', SQLERRM, SQLSTATE);
    ROLLBACK;
    CALL dbo.usp_audit_finish(v_run_id, 'Error', v_msg);
    COMMIT;
    RAISE;                                           -- client: THROW
END $$;
```

### 8.2 Date discovery

**Client (screenshot 5, lines 17–42):** a `@Dates` table variable filled from three sources (`Lot`, `Transaction`, `FINANCE_AssetMark_Vehicle`) with a 4-hour overlap on the audit timestamp and a 6-month lookback "for performance reasons", then `@MaxCounter = COUNT(*)`.

**Demo today:** none. Every procedure reloads everything.

**Target** (`dbo.usp_discover_periods`)
```sql
DROP TABLE IF EXISTS tmp_periods;
CREATE TEMP TABLE tmp_periods (row_num INT GENERATED ALWAYS AS IDENTITY, as_of_date DATE PRIMARY KEY);

INSERT INTO tmp_periods (as_of_date)
SELECT DISTINCT d FROM (
    -- marks that arrived since the watermark (minus overlap), like dbo.Lot
    SELECT dbo.fn_try_date(s.as_of_date) AS d
    FROM staging.loan_marks s
    WHERE p_mode = 'full'
       OR s._loaded_at >= (SELECT high_water_loaded_at - v_overlap FROM dbo.etl_watermark WHERE source_table = 'staging.loan_marks')
    UNION
    -- cash flows: a late transaction changes its month and every later month (spec 003)
    SELECT me.d
    FROM staging.cash_flows s
    CROSS JOIN LATERAL dbo.fn_month_ends_from(dbo.fn_try_date(s.transaction_date), v_last_month) me(d)
    WHERE p_mode = 'incremental'
      AND s._loaded_at >= (SELECT high_water_loaded_at - v_overlap FROM dbo.etl_watermark WHERE source_table = 'staging.cash_flows')
    UNION
    -- FX restatements, like FINANCE_AssetMark_Vehicle
    SELECT dbo.fn_try_date(s.rate_date)
    FROM staging.fx_rates s
    WHERE p_mode = 'incremental'
      AND s._loaded_at >= (SELECT high_water_loaded_at - v_overlap FROM dbo.etl_watermark WHERE source_table = 'staging.fx_rates')
) x
WHERE d IS NOT NULL
  AND d >= v_last_month - make_interval(months => v_lookback)      -- client: DATEADD(MONTH,-6,GETDATE())
ORDER BY d;

SELECT count(*) INTO v_max_counter FROM tmp_periods;                -- client: @MaxCounter
```

### 8.3 Period loop, per-period transaction and error handling

**Client (screenshot 5 lines 59–73 and screenshot 1 lines 150–185):** `WHILE @Counter <= @MaxCounter`, `BEGIN TRY BEGIN TRANSACTION`, `DELETE FROM dbo.Position WHERE AsOfDate = @currentDate`, `INSERT`, `EXEC usp_UpdatePositionFxRates`, `COMMIT`, `END TRY BEGIN CATCH ROLLBACK; EXEC usp_ETL_AuditUpdate 'ERROR'; THROW`.

**Demo today** (`20_usp_build_facility_month.sql`): one `TRUNCATE dbo.facility_month;` followed by one `INSERT … SELECT` over all months, no error handling, one transaction for the whole run.

**Target** (body of `dbo.usp_run_etl`, after the dimension loads)
```sql
FOR v_period IN SELECT row_num, as_of_date FROM tmp_periods ORDER BY row_num LOOP
    BEGIN
        RAISE INFO '[%/%] period %', v_period.row_num, v_max_counter, v_period.as_of_date;   -- client: PRINT CONVERT(...)

        CALL dbo.usp_load_loan_mark      (v_run_id, v_period.as_of_date);   -- DELETE period + INSERT
        CALL dbo.usp_build_facility_month(v_run_id, v_period.as_of_date);   -- DELETE period + INSERT (local ccy)
        CALL dbo.usp_apply_fx_rates      (v_run_id, v_period.as_of_date);   -- client: usp_UpdatePositionFxRates
        CALL dbo.usp_build_cost_basis    (v_run_id, v_period.as_of_date);   -- spec 003
        CALL dbo.usp_apply_ratings       (v_run_id, v_period.as_of_date);   -- spec 004

        v_done := v_done + 1;
        UPDATE dbo.etl_run SET periods_done = v_done WHERE run_id = v_run_id;
        COMMIT;                                                              -- client: COMMIT per date
    EXCEPTION WHEN OTHERS THEN
        v_msg := format('period %s: %s [%s]', v_period.as_of_date, SQLERRM, SQLSTATE);
        ROLLBACK;                                                            -- client: IF @@TRANCOUNT > 0 ROLLBACK
        CALL dbo.usp_log_step(v_run_id, 'dbo.usp_run_etl', clock_timestamp(), NULL, NULL, NULL,
                              p_as_of_date => v_period.as_of_date, p_status => 'ERROR', p_message => v_msg);
        CALL dbo.usp_audit_finish(v_run_id, 'Error', v_msg);                 -- client: usp_ETL_AuditUpdate @Status='ERROR'
        COMMIT;
        RAISE EXCEPTION '%', v_msg;                                          -- client: THROW
    END;
END LOOP;
```
Notes on the translation:
- SQL Server's `BEGIN TRY / BEGIN TRANSACTION` pair becomes a PL/pgSQL `BEGIN … EXCEPTION … END` block (an implicit savepoint) plus an explicit `COMMIT` at the end of each iteration. `COMMIT` inside a procedure is legal because `usp_run_etl` is invoked with a top-level `CALL` from `run_pipeline.sh`.
- `ROLLBACK` then `COMMIT` around the audit write is what makes the error visible after the exception propagates. Without it the audit row would be rolled back together with the failed period.
- `@Counter += 1` becomes the `FOR … LOOP` cursor; `row_num` is still stored so the log shows "[3/12]".

### 8.4 Period-scoped load instead of full truncate

**Client:** `DELETE FROM [dbo].[Position] WHERE [AsOfDate] IN (@currentDate); INSERT INTO [dbo].[Position] (…) SELECT … FROM #LotAllDates L WHERE L.Lot_AsOfDate IN (@currentDate)`.

**Demo today** (`14_usp_load_loan_mark.sql`)
```sql
TRUNCATE dbo.loan_mark;
INSERT INTO dbo.loan_mark (...)
SELECT ... FROM tmp_loan_mark WHERE reject_reason = '';
```

**Target**
```sql
CREATE OR REPLACE PROCEDURE dbo.usp_load_loan_mark(p_run_id UUID, p_as_of_date DATE)
...
    DROP TABLE IF EXISTS tmp_loan_mark;
    CREATE TEMP TABLE tmp_loan_mark AS
    SELECT d.*, concat_ws('; ', ...) AS reject_reason
    FROM ( SELECT DISTINCT ON (...) ... FROM staging.loan_marks s
           WHERE dbo.fn_try_date(s.as_of_date) = p_as_of_date          -- period filter pushed into the parse
           ORDER BY ... , s._row_id DESC ) d;

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, as_of_date, reason, raw_record) ...;

    DELETE FROM dbo.loan_mark WHERE as_of_date = p_as_of_date;             -- client: DELETE ... WHERE AsOfDate = @currentDate
    INSERT INTO dbo.loan_mark (..., etl_run_id, loaded_at)
    SELECT ..., p_run_id, clock_timestamp() FROM tmp_loan_mark WHERE reject_reason = '';

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_load_loan_mark', v_start, v_read, v_loaded, v_rej, p_as_of_date);
```
The three-step reject pattern (parse into temp → write rejects → load valid rows) is kept; it is already closer to the client's style than the client itself.

### 8.5 FX as a separate procedure called inside the loop

**Client (screenshot 4):** `EXEC dbo.usp_UpdatePositionFxRates @AsOfDate_From = @currentDate, @AsOfDate_To = @currentDate;` after the position insert, i.e. the fact is first written in local currency and converted by a second procedure.

**Demo today:** FX and base rate are inner-joined in the same `INSERT … SELECT`; a missing rate silently excludes the row from the fact (then a separate query logs it as a reject).

**Target** (`dbo.usp_apply_fx_rates`)
```sql
CREATE OR REPLACE PROCEDURE dbo.usp_apply_fx_rates(p_run_id UUID, p_as_of_date DATE)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT;
BEGIN
    SELECT count(*) INTO v_read FROM dbo.facility_month WHERE as_of_date = p_as_of_date;

    UPDATE dbo.facility_month fm
       SET fx_eur_per_unit = fx.eur_per_unit,
           commitment_eur  = round(fm.commitment_local  * fx.eur_per_unit, 2),
           outstanding_eur = round(fm.outstanding_local * fx.eur_per_unit, 2),
           undrawn_eur     = round(fm.undrawn_local     * fx.eur_per_unit, 2),
           fair_value_eur  = round(fm.fair_value_local  * fx.eur_per_unit, 2)
      FROM dbo.fx_rate fx
     WHERE fm.as_of_date = p_as_of_date
       AND fx.rate_date  = fm.as_of_date
       AND fx.currency   = fm.currency;
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    -- rows still unconverted are removed from the period and explained
    WITH gone AS (
        DELETE FROM dbo.facility_month fm
         WHERE fm.as_of_date = p_as_of_date AND fm.fx_eur_per_unit IS NULL
        RETURNING fm.facility_id, fm.as_of_date, fm.currency)
    INSERT INTO dbo.etl_reject (run_id, source_table, business_key, as_of_date, reason)
    SELECT p_run_id, 'dbo.facility_month', facility_id || '@' || as_of_date, as_of_date, 'no FX rate for ' || currency FROM gone;
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_apply_fx_rates', v_start, v_read, v_loaded, v_rej, p_as_of_date);
END $$;
```
This requires `*_local` columns on `dbo.facility_month` and the `*_eur` columns to become nullable until the FX step runs (they are `NOT NULL` today). The period's `COMMIT` only happens after the FX step, so a reader never sees unconverted rows.

### 8.6 Logging granularity

**Demo today:** `usp_log_step(run_id, procedure, started, read, loaded, rejected)`; one row per procedure per run; `status` always `'SUCCESS'`.

**Target:** `usp_log_step(run_id, procedure, started, read, loaded, rejected, p_as_of_date DATE DEFAULT NULL, p_status TEXT DEFAULT 'SUCCESS', p_message TEXT DEFAULT NULL)`; one row per procedure **per period**; the `RAISE INFO` line gains the period: `[2025-03-31] dbo.usp_apply_fx_rates   read=232 loaded=230 rejected=2`.

### 8.7 Coding conventions adopted from the screenshots
| Convention | Where it shows in the client code | Demo rule from now on |
|---|---|---|
| Header comment with `DROP PROCEDURE IF EXISTS` in a `/* */` block | screenshot 5 lines 1–4 | Keep the demo's `-- ===` banner, add the purpose, inputs, periodisation and the procedures it calls |
| Explicit `DECLARE` block for all loop/counter variables | screenshot 5 lines 44–47 | All variables declared in one `DECLARE`, prefixed `v_`; parameters prefixed `p_` |
| Temp tables dropped at the end of the procedure (`DROP TABLE IF EXISTS #tmp, #tmp2`) | screenshot 1 lines 111–112 | `DROP TABLE IF EXISTS tmp_*` both before creation and at the end |
| Intermediate results materialised in named temp tables, not CTE chains | `#LotAllDates`, `#tmp`, `#tmp2` | Multi-stage logic uses `CREATE TEMP TABLE tmp_<stage>`; one CTE at most per statement |
| Vertical alignment of `=` in SELECT lists and `ON` clauses | screenshots 2–4 | Align assignments and join predicates; one column per line |
| Business comments inline (`--up to 4 hours before latest audit update`) | screenshot 5 lines 25, 32 | Every non-obvious predicate carries the business reason as a trailing comment |
