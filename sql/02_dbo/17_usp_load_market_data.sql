-- =============================================================================
-- dbo.usp_load_market_data : staging.fx_rates        -> dbo.fx_rate
--                            staging.reference_rates -> dbo.reference_rate
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_load_market_data(p_run_id UUID)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_loaded2 INT; v_rej INT; v_rej2 INT;
BEGIN
    SELECT (SELECT count(*) FROM staging.fx_rates) + (SELECT count(*) FROM staging.reference_rates) INTO v_read;

    -- FX
    DROP TABLE IF EXISTS tmp_fx;
    CREATE TEMP TABLE tmp_fx AS
    SELECT DISTINCT ON (dbo.fn_try_date(s.rate_date), upper(dbo.fn_clean_text(s.currency)))
           s._row_id, dbo.fn_try_date(s.rate_date) AS rate_date,
           upper(dbo.fn_clean_text(s.currency)) AS currency,
           dbo.fn_try_numeric(s.eur_per_unit) AS eur_per_unit, to_jsonb(s) AS raw_record
    FROM staging.fx_rates s
    ORDER BY dbo.fn_try_date(s.rate_date), upper(dbo.fn_clean_text(s.currency)), s._row_id DESC;

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
    SELECT p_run_id, 'staging.fx_rates', _row_id, currency, 'invalid date, currency or rate', raw_record
    FROM tmp_fx WHERE rate_date IS NULL OR currency IS NULL OR coalesce(eur_per_unit, 0) <= 0;
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    TRUNCATE dbo.fx_rate;
    INSERT INTO dbo.fx_rate (rate_date, currency, eur_per_unit)
    SELECT rate_date, currency, eur_per_unit FROM tmp_fx
    WHERE rate_date IS NOT NULL AND currency IS NOT NULL AND eur_per_unit > 0;
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    -- Reference (base) rates
    DROP TABLE IF EXISTS tmp_rr;
    CREATE TEMP TABLE tmp_rr AS
    SELECT DISTINCT ON (dbo.fn_try_date(s.rate_date), dbo.fn_clean_text(s.rate_name))
           s._row_id, dbo.fn_try_date(s.rate_date) AS rate_date,
           dbo.fn_clean_text(s.rate_name) AS rate_name,
           dbo.fn_try_numeric(s.rate_pct) AS rate_pct, to_jsonb(s) AS raw_record
    FROM staging.reference_rates s
    ORDER BY dbo.fn_try_date(s.rate_date), dbo.fn_clean_text(s.rate_name), s._row_id DESC;

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
    SELECT p_run_id, 'staging.reference_rates', _row_id, rate_name, 'invalid date, name or rate', raw_record
    FROM tmp_rr WHERE rate_date IS NULL OR rate_name IS NULL OR rate_pct IS NULL;
    GET DIAGNOSTICS v_rej2 = ROW_COUNT;

    TRUNCATE dbo.reference_rate;
    INSERT INTO dbo.reference_rate (rate_date, rate_name, rate_pct)
    SELECT rate_date, rate_name, rate_pct FROM tmp_rr
    WHERE rate_date IS NOT NULL AND rate_name IS NOT NULL AND rate_pct IS NOT NULL;
    GET DIAGNOSTICS v_loaded2 = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_load_market_data', v_start, v_read, v_loaded + v_loaded2, v_rej + v_rej2);
END $$;
