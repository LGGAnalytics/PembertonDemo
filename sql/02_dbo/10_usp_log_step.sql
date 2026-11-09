-- =============================================================================
-- dbo.usp_log_step : writes one audit row per ETL step into dbo.etl_run_log.
--   One row per procedure PER PERIOD (p_as_of_date NULL for dimension loads).
--   p_status 'ERROR' + p_message record a failed step (written after ROLLBACK).
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_log_step(
    p_run_id     UUID,
    p_procedure  TEXT,
    p_started    TIMESTAMPTZ,
    p_read       INTEGER,
    p_loaded     INTEGER,
    p_rejected   INTEGER,
    p_as_of_date DATE DEFAULT NULL,
    p_status     TEXT DEFAULT 'SUCCESS',
    p_message    TEXT DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dbo.etl_run_log (run_id, procedure_name, as_of_date, started_at,
                                 rows_read, rows_loaded, rows_rejected, status, message)
    VALUES (p_run_id, p_procedure, p_as_of_date, p_started,
            p_read, p_loaded, p_rejected, p_status, p_message);

    IF p_status = 'ERROR' THEN
        RAISE WARNING '[%] %  ERROR: %', coalesce(p_as_of_date::TEXT, '-'), rpad(p_procedure, 34), p_message;
    ELSE
        RAISE INFO '[%] %  read=%  loaded=%  rejected=%',
                   coalesce(p_as_of_date::TEXT, '    dims  '), rpad(p_procedure, 34), p_read, p_loaded, p_rejected;
    END IF;
END $$;
