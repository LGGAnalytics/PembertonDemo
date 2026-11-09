-- =============================================================================
-- dbo.usp_discover_periods : decides WHICH month-end periods this run rebuilds.
-- Mirrors the client's @Dates table variable:
--   * full        : every as_of_date present in the mark file
--   * incremental : periods whose source rows arrived after the watermark
--                   (minus an overlap of N hours), UNION over marks, cash flows
--                   and FX, limited to a lookback window "for performance reasons"
--   * p_periods   : explicit list (operators and tests)
-- Output: temp tables tmp_periods (row_num, as_of_date) and tmp_watermark
--         (the staging high-water marks captured NOW, applied on Success).
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_discover_periods(
    p_run_id           UUID,
    p_mode             TEXT,
    p_lookback_months  INT    DEFAULT NULL,
    p_periods          DATE[] DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_start      TIMESTAMPTZ := clock_timestamp();
    v_lookback   INT         := coalesce(p_lookback_months, dbo.fn_config_int('lookback_months', 6));
    v_overlap    INTERVAL    := make_interval(hours => dbo.fn_config_int('overlap_hours', 4));
    v_last_month DATE;
    v_floor      DATE;
    v_planned    INT;
BEGIN
    -- latest month-end in the data; the lookback window counts back from here
    SELECT max(dbo.fn_try_date(as_of_date)) INTO v_last_month FROM staging.loan_marks;
    v_floor := CASE WHEN p_mode = 'incremental'
                    THEN (v_last_month - make_interval(months => v_lookback))::DATE   -- client: DATEADD(MONTH,-6,GETDATE())
                    ELSE DATE '0001-01-01' END;

    -- staging high-water marks, captured before reading so late arrivals are re-read next run
    DROP TABLE IF EXISTS tmp_watermark;
    CREATE TEMP TABLE tmp_watermark AS
    SELECT 'staging.loan_marks'          AS source_table, max(_loaded_at) AS high_water_loaded_at FROM staging.loan_marks          UNION ALL
    SELECT 'staging.cash_flows',                          max(_loaded_at)                         FROM staging.cash_flows          UNION ALL
    SELECT 'staging.fx_rates',                            max(_loaded_at)                         FROM staging.fx_rates            UNION ALL
    SELECT 'staging.reference_rates',                     max(_loaded_at)                         FROM staging.reference_rates     UNION ALL
    SELECT 'staging.facilities',                          max(_loaded_at)                         FROM staging.facilities          UNION ALL
    SELECT 'staging.borrowers',                           max(_loaded_at)                         FROM staging.borrowers           UNION ALL
    SELECT 'staging.funds',                               max(_loaded_at)                         FROM staging.funds               UNION ALL
    SELECT 'staging.borrower_financials',                 max(_loaded_at)                         FROM staging.borrower_financials;
    DELETE FROM tmp_watermark WHERE high_water_loaded_at IS NULL;   -- empty staging table: nothing to remember

    DROP TABLE IF EXISTS tmp_periods;
    CREATE TEMP TABLE tmp_periods (
        row_num     INT GENERATED ALWAYS AS IDENTITY,                -- client: RowID INT IDENTITY(1,1)
        as_of_date  DATE PRIMARY KEY
    );

    IF p_periods IS NOT NULL THEN
        INSERT INTO tmp_periods (as_of_date)
        SELECT DISTINCT d FROM unnest(p_periods) d WHERE d IS NOT NULL ORDER BY d;

    ELSIF p_mode = 'full' THEN
        INSERT INTO tmp_periods (as_of_date)
        SELECT DISTINCT dbo.fn_try_date(s.as_of_date)
        FROM staging.loan_marks s
        WHERE dbo.fn_try_date(s.as_of_date) IS NOT NULL
        ORDER BY 1;

    ELSE
        INSERT INTO tmp_periods (as_of_date)
        SELECT DISTINCT d FROM (
            -- marks that arrived since the watermark (like dbo.Lot)
            SELECT dbo.fn_try_date(s.as_of_date) AS d
            FROM staging.loan_marks s
            WHERE s._loaded_at >  coalesce((SELECT high_water_loaded_at FROM dbo.etl_watermark
                                             WHERE source_table = 'staging.loan_marks'), '-infinity') - v_overlap   -- up to N hours before the watermark
            UNION
            -- cash flows: a late transaction changes its month and every later month (like dbo.Transaction)
            SELECT me
            FROM staging.cash_flows s
            CROSS JOIN LATERAL dbo.fn_month_ends_from(dbo.fn_try_date(s.transaction_date), v_last_month) me
            WHERE s._loaded_at >  coalesce((SELECT high_water_loaded_at FROM dbo.etl_watermark
                                             WHERE source_table = 'staging.cash_flows'), '-infinity') - v_overlap
            UNION
            -- FX restatements (like FINANCE_AssetMark_Vehicle)
            SELECT dbo.fn_try_date(s.rate_date)
            FROM staging.fx_rates s
            WHERE s._loaded_at >  coalesce((SELECT high_water_loaded_at FROM dbo.etl_watermark
                                             WHERE source_table = 'staging.fx_rates'), '-infinity') - v_overlap
        ) x
        WHERE d IS NOT NULL
          AND d >= v_floor                                           -- lookback window
          AND d IN (SELECT DISTINCT dbo.fn_try_date(as_of_date) FROM staging.loan_marks)   -- only real mark dates
        ORDER BY d;
    END IF;

    SELECT count(*) INTO v_planned FROM tmp_periods;                 -- client: @MaxCounter = COUNT(*)
    UPDATE dbo.etl_run SET periods_planned = v_planned WHERE run_id = p_run_id;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_discover_periods', v_start, NULL, v_planned, 0);
END $$;
