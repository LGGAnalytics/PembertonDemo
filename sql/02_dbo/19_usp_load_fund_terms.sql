-- =============================================================================
-- dbo.usp_load_fund_terms : staging.fund_terms -> dbo.fund_terms   (spec 005)
--   Dimension: parse, reject (unknown fund, out-of-range %, unsupported basis,
--   frequency or catch-up), TRUNCATE + INSERT. Last staged row per fund wins.
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_load_fund_terms(p_run_id UUID)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT;
BEGIN
    SELECT count(*) INTO v_read FROM staging.fund_terms;

    DROP TABLE IF EXISTS tmp_fund_terms;
    CREATE TEMP TABLE tmp_fund_terms AS
    SELECT d.*,
           concat_ws('; ',
               CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.fund f WHERE f.fund_code = d.fund_code) THEN 'unknown fund' END,
               CASE WHEN d.mgmt_fee_pct IS NULL OR d.mgmt_fee_pct NOT BETWEEN 0 AND 3  THEN 'mgmt_fee_pct out of range' END,
               CASE WHEN d.expense_pct  IS NULL OR d.expense_pct  NOT BETWEEN 0 AND 1  THEN 'expense_pct out of range' END,
               CASE WHEN d.carry_pct    IS NULL OR d.carry_pct    NOT BETWEEN 0 AND 30 THEN 'carry_pct out of range' END,
               CASE WHEN d.hurdle_pct   IS NULL OR d.hurdle_pct   NOT BETWEEN 0 AND 15 THEN 'hurdle_pct out of range' END,
               CASE WHEN d.fee_basis IS NULL     THEN 'unknown fee basis' END,
               CASE WHEN d.fee_frequency IS NULL THEN 'unsupported fee frequency' END,
               CASE WHEN d.catch_up_pct IS DISTINCT FROM 100 THEN 'unsupported catch-up' END   -- decision D3
           ) AS reject_reason
    FROM (
        SELECT DISTINCT ON (upper(dbo.fn_clean_text(s.fund_code)))
               s._row_id,
               upper(dbo.fn_clean_text(s.fund_code))                    AS fund_code,
               dbo.fn_try_numeric(s.mgmt_fee_pct)                       AS mgmt_fee_pct,
               dbo.fn_conform(s.fee_basis, ARRAY['INVESTED','COMMITTED']) AS fee_basis,
               dbo.fn_conform(s.fee_frequency, ARRAY['Q'])              AS fee_frequency,
               dbo.fn_try_numeric(s.expense_pct)                        AS expense_pct,
               dbo.fn_try_numeric(s.carry_pct)                          AS carry_pct,
               dbo.fn_try_numeric(s.hurdle_pct)                         AS hurdle_pct,
               dbo.fn_try_numeric(s.catch_up_pct)                       AS catch_up_pct,
               to_jsonb(s) AS raw_record
        FROM staging.fund_terms s
        ORDER BY upper(dbo.fn_clean_text(s.fund_code)), s._row_id DESC
    ) d;

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
    SELECT p_run_id, 'staging.fund_terms', _row_id, fund_code, reject_reason, raw_record
    FROM tmp_fund_terms WHERE reject_reason <> '';
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    TRUNCATE dbo.fund_terms;
    INSERT INTO dbo.fund_terms (fund_code, mgmt_fee_pct, fee_basis, fee_frequency, expense_pct, carry_pct, hurdle_pct, catch_up_pct)
    SELECT fund_code, mgmt_fee_pct, fee_basis, fee_frequency, expense_pct, carry_pct, hurdle_pct, catch_up_pct
    FROM tmp_fund_terms WHERE reject_reason = '';
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_load_fund_terms', v_start, v_read, v_loaded, v_rej);
END $$;
