-- =============================================================================
-- Run-level audit (mirrors the client's usp_ETL_AuditInsert / usp_ETL_AuditUpdate)
--
--   dbo.usp_audit_start  : opens dbo.etl_run as 'Processing' and returns the run_id.
--                          The caller COMMITs right after, so a crashed run stays
--                          visible as 'Processing'.
--   dbo.usp_audit_finish : closes the run as 'Success' or 'Error'. On Success it
--                          advances dbo.etl_watermark from tmp_watermark (captured
--                          by usp_discover_periods) and drops the run's temp tables.
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_audit_start(
    p_source        TEXT,
    p_triggered_by  TEXT,
    p_mode          TEXT,
    INOUT p_run_id  UUID DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_mode NOT IN ('full', 'incremental') THEN
        RAISE EXCEPTION 'usp_audit_start: unknown mode "%", expected full | incremental', p_mode;
    END IF;

    p_run_id := coalesce(p_run_id, gen_random_uuid());

    INSERT INTO dbo.etl_run (run_id, source, triggered_by, mode, status)
    VALUES (p_run_id, p_source, p_triggered_by, p_mode, 'Processing');

    RAISE INFO 'ETL run % started  mode=%  by=%', p_run_id, p_mode, p_triggered_by;
END $$;


CREATE OR REPLACE PROCEDURE dbo.usp_audit_finish(
    p_run_id   UUID,
    p_status   TEXT,
    p_message  TEXT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE v_done INT;
BEGIN
    IF p_status NOT IN ('Success', 'Error') THEN
        RAISE EXCEPTION 'usp_audit_finish: unknown status "%"', p_status;
    END IF;

    UPDATE dbo.etl_run
       SET status      = p_status,
           message     = p_message,
           finished_at = clock_timestamp()
     WHERE run_id = p_run_id
    RETURNING periods_done INTO v_done;

    -- watermark moves only on a clean run, and only from values captured at discovery time
    IF p_status = 'Success' AND to_regclass('pg_temp.tmp_watermark') IS NOT NULL THEN
        INSERT INTO dbo.etl_watermark (source_table, high_water_loaded_at, updated_by_run)
        SELECT source_table, high_water_loaded_at, p_run_id FROM tmp_watermark
        ON CONFLICT (source_table) DO UPDATE
           SET high_water_loaded_at = excluded.high_water_loaded_at,
               updated_by_run       = excluded.updated_by_run;
    END IF;

    IF p_status = 'Success' THEN
        DROP TABLE IF EXISTS tmp_periods;
        DROP TABLE IF EXISTS tmp_watermark;
        RAISE INFO 'ETL run % finished: Success (% periods)', p_run_id, v_done;
    ELSE
        RAISE WARNING 'ETL run % finished: Error - %', p_run_id, p_message;
    END IF;
END $$;
