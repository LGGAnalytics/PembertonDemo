-- =============================================================================
-- dbo.usp_load_fund : staging.funds -> dbo.fund
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_load_fund(p_run_id UUID)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT;
BEGIN
    SELECT count(*) INTO v_read FROM staging.funds;

    DROP TABLE IF EXISTS tmp_fund;
    CREATE TEMP TABLE tmp_fund AS
    SELECT DISTINCT ON (upper(dbo.fn_clean_text(s.fund_code)))
           s._row_id,
           upper(dbo.fn_clean_text(s.fund_code))      AS fund_code,
           dbo.fn_clean_text(s.fund_name)             AS fund_name,
           dbo.fn_try_numeric(s.vintage_year)::SMALLINT AS vintage_year,
           dbo.fn_clean_text(s.strategy)              AS strategy,
           dbo.fn_try_numeric(s.fund_size_eur)        AS fund_size_eur,
           upper(dbo.fn_clean_text(s.base_currency))  AS base_currency,
           to_jsonb(s) AS raw_record
    FROM staging.funds s
    ORDER BY upper(dbo.fn_clean_text(s.fund_code)), s._row_id DESC;

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
    SELECT p_run_id, 'staging.funds', _row_id, fund_code, 'missing key, name, vintage or size', raw_record
    FROM tmp_fund
    WHERE fund_code IS NULL OR fund_name IS NULL OR vintage_year IS NULL OR fund_size_eur IS NULL;
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    TRUNCATE dbo.fund CASCADE;
    INSERT INTO dbo.fund (fund_code, fund_name, vintage_year, strategy, fund_size_eur, base_currency)
    SELECT fund_code, fund_name, vintage_year, strategy, fund_size_eur, coalesce(base_currency, 'EUR')
    FROM tmp_fund
    WHERE fund_code IS NOT NULL AND fund_name IS NOT NULL AND vintage_year IS NOT NULL AND fund_size_eur IS NOT NULL;
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_load_fund', v_start, v_read, v_loaded, v_rej);
END $$;
