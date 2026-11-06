-- =============================================================================
-- dbo.usp_log_step : writes one audit row per ETL step into dbo.etl_run_log.
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_log_step(
    p_run_id UUID, p_procedure TEXT, p_started TIMESTAMPTZ,
    p_read INTEGER, p_loaded INTEGER, p_rejected INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dbo.etl_run_log (run_id, procedure_name, started_at, rows_read, rows_loaded, rows_rejected)
    VALUES (p_run_id, p_procedure, p_started, p_read, p_loaded, p_rejected);
    RAISE INFO '%  read=%  loaded=%  rejected=%', rpad(p_procedure, 34), p_read, p_loaded, p_rejected;
END $$;
