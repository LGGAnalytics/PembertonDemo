-- =============================================================================
-- dbo.usp_run_etl : master procedure (mirrors the client's position rebuild loop)
--
--   CALL dbo.usp_run_etl();                                   -- full
--   CALL dbo.usp_run_etl('incremental');                      -- periods changed since the watermark
--   CALL dbo.usp_run_etl('incremental', 6, ARRAY[DATE '2025-03-31']);   -- explicit periods
--
--   1. open the audit header (Processing) and COMMIT
--   2. reload dimensions and market data, discover periods, COMMIT
--   3. FOR each period: marks -> fact (local) -> FX -> cost basis -> ratings, COMMIT
--      on failure: ROLLBACK that period, log ERROR, close the run as Error, COMMIT, re-raise
--   4. close the run as Success and advance the watermark
--
--   Must be invoked with a top-level CALL (it uses COMMIT), never inside a
--   transaction block or a DO block.
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_run_etl(
    p_mode             TEXT   DEFAULT 'full',
    p_lookback_months  INT    DEFAULT NULL,
    p_periods          DATE[] DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_run_id       UUID;
    v_start        TIMESTAMPTZ := clock_timestamp();
    v_step_start   TIMESTAMPTZ;
    v_counter      INT := 1;                      -- client: @Counter
    v_max_counter  INT;                           -- client: @MaxCounter
    v_current_date DATE;                          -- client: @currentDate
    v_ok           BOOLEAN;
    v_msg          TEXT;
    v_read         INT; v_loaded INT; v_rej INT;
BEGIN
    -- 1. audit header, visible immediately
    CALL dbo.usp_audit_start('csv-extracts', current_user, p_mode, v_run_id);
    COMMIT;

    -- 2. dimensions and market data (not periodised), then period discovery
    v_ok := TRUE;
    BEGIN
        CALL dbo.usp_load_fund(v_run_id);
        CALL dbo.usp_load_borrower(v_run_id);
        CALL dbo.usp_load_credit_rating(v_run_id);                         -- spec 004
        CALL dbo.usp_load_facility(v_run_id);
        CALL dbo.usp_load_market_data(v_run_id);
        CALL dbo.usp_load_cash_flow(v_run_id);
        CALL dbo.usp_load_fund_terms(v_run_id);                            -- spec 005
        CALL dbo.usp_load_fund_cash_flow(v_run_id);                        -- spec 005
        CALL dbo.usp_load_borrower_financials(v_run_id);
        CALL dbo.usp_discover_periods(v_run_id, p_mode, p_lookback_months, p_periods);
    EXCEPTION WHEN OTHERS THEN
        v_ok  := FALSE;
        v_msg := format('dimensions: %s [%s]', SQLERRM, SQLSTATE);
    END;

    IF NOT v_ok THEN
        ROLLBACK;
        CALL dbo.usp_log_step(v_run_id, 'dbo.usp_run_etl', v_start, NULL, NULL, NULL, NULL, 'ERROR', v_msg);
        CALL dbo.usp_audit_finish(v_run_id, 'Error', v_msg);
        COMMIT;
        RAISE EXCEPTION '%', v_msg;
    END IF;
    COMMIT;

    SELECT count(*) INTO v_max_counter FROM tmp_periods;

    -- 3. period loop: one transaction per month-end
    WHILE v_counter <= v_max_counter LOOP
        SELECT as_of_date INTO v_current_date FROM tmp_periods WHERE row_num = v_counter;
        v_step_start := clock_timestamp();
        RAISE INFO '---- period % (%/%)', v_current_date, v_counter, v_max_counter;   -- client: PRINT CONVERT(VARCHAR(10), @currentDate, 120)

        v_ok := TRUE;
        BEGIN
            CALL dbo.usp_load_loan_mark      (v_run_id, v_current_date);
            CALL dbo.usp_build_facility_month(v_run_id, v_current_date);
            CALL dbo.usp_apply_fx_rates      (v_run_id, v_current_date);   -- client: EXEC usp_UpdatePositionFxRates
            CALL dbo.usp_build_cost_basis    (v_run_id, v_current_date);   -- spec 003, client: usp_CreatePositionEquityCost
            CALL dbo.usp_apply_ratings       (v_run_id, v_current_date);   -- spec 004, client: Asset_Rating_* update
        EXCEPTION WHEN OTHERS THEN
            v_ok  := FALSE;
            v_msg := format('period %s: %s [%s]', v_current_date, SQLERRM, SQLSTATE);
        END;

        IF v_ok THEN
            UPDATE dbo.etl_run SET periods_done = v_counter WHERE run_id = v_run_id;
            COMMIT;                                                        -- client: COMMIT per date
        ELSE
            ROLLBACK;                                                      -- client: IF @@TRANCOUNT > 0 ROLLBACK
            CALL dbo.usp_log_step(v_run_id, 'dbo.usp_run_etl', v_step_start, NULL, NULL, NULL, v_current_date, 'ERROR', v_msg);
            CALL dbo.usp_audit_finish(v_run_id, 'Error', v_msg);           -- client: usp_ETL_AuditUpdate @Status = 'ERROR'
            COMMIT;
            RAISE EXCEPTION '%', v_msg;                                    -- client: THROW
        END IF;

        v_counter := v_counter + 1;                                        -- client: SET @Counter += 1
    END LOOP;

    -- 4. totals and close
    SELECT sum(rows_read), sum(rows_loaded), sum(rows_rejected)
      INTO v_read, v_loaded, v_rej
      FROM dbo.etl_run_log WHERE run_id = v_run_id;
    CALL dbo.usp_log_step(v_run_id, 'dbo.usp_run_etl (total)', v_start, v_read, v_loaded, v_rej);
    CALL dbo.usp_audit_finish(v_run_id, 'Success');
    COMMIT;
END $$;
