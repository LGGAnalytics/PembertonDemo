-- =============================================================================
-- dbo.usp_run_etl : master procedure. Runs the full staging -> dbo ETL in
-- dependency order inside ONE transaction: if any step fails, nothing is
-- committed and the previous dbo data stays intact.
--
--   CALL dbo.usp_run_etl();
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_run_etl()
LANGUAGE plpgsql AS $$
DECLARE v_run_id UUID := gen_random_uuid(); v_start TIMESTAMPTZ := clock_timestamp();
        v_read INT; v_loaded INT; v_rej INT;
BEGIN
    RAISE INFO 'ETL run % started', v_run_id;

    -- master data first (FK order), then transactions, then the fact
    CALL dbo.usp_load_fund(v_run_id);
    CALL dbo.usp_load_borrower(v_run_id);
    CALL dbo.usp_load_facility(v_run_id);
    CALL dbo.usp_load_market_data(v_run_id);
    CALL dbo.usp_load_loan_mark(v_run_id);
    CALL dbo.usp_load_cash_flow(v_run_id);
    CALL dbo.usp_load_borrower_financials(v_run_id);
    CALL dbo.usp_build_facility_month(v_run_id);

    SELECT sum(rows_read), sum(rows_loaded), sum(rows_rejected)
      INTO v_read, v_loaded, v_rej
      FROM dbo.etl_run_log WHERE run_id = v_run_id;
    CALL dbo.usp_log_step(v_run_id, 'dbo.usp_run_etl (total)', v_start, v_read, v_loaded, v_rej);
END $$;
