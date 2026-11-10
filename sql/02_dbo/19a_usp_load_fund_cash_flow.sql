-- =============================================================================
-- dbo.usp_load_fund_cash_flow : staging.fund_cash_flows -> dbo.fund_cash_flow   (spec 005)
--   Same pattern as usp_load_cash_flow: deduplicate on flow_id (last staged row
--   wins), parse dates, conform flow_type, reject unknown fund / bad date / bad
--   type / invalid, negative or overflowing amount / missing flow_id / currency other
--   than the fund's base currency (spec 005: fund flows are in base currency), TRUNCATE + INSERT.
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_load_fund_cash_flow(p_run_id UUID)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT;
BEGIN
    SELECT count(*) INTO v_read FROM staging.fund_cash_flows;

    DROP TABLE IF EXISTS tmp_fund_cash_flow;
    CREATE TEMP TABLE tmp_fund_cash_flow AS
    SELECT d.*,
           concat_ws('; ',
               CASE WHEN d.flow_id IS NULL THEN 'missing flow_id' END,
               CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.fund f WHERE f.fund_code = d.fund_code) THEN 'unknown fund' END,
               CASE WHEN d.flow_date IS NULL THEN 'invalid date' END,
               CASE WHEN d.flow_type IS NULL THEN 'unknown flow type' END,
               CASE WHEN d.amount IS NULL    THEN 'invalid amount' END,
               CASE WHEN d.amount < 0        THEN 'negative amount' END,
               CASE WHEN abs(d.amount) >= 1e16 THEN 'amount out of range' END,
               CASE WHEN d.currency IS DISTINCT FROM (SELECT f.base_currency FROM dbo.fund f WHERE f.fund_code = d.fund_code)
                     AND EXISTS (SELECT 1 FROM dbo.fund f WHERE f.fund_code = d.fund_code)
                    THEN 'currency is not the fund base currency' END
           ) AS reject_reason
    FROM (
        SELECT DISTINCT ON (upper(dbo.fn_clean_text(s.flow_id)))
               s._row_id,
               upper(dbo.fn_clean_text(s.flow_id))   AS flow_id,
               upper(dbo.fn_clean_text(s.fund_code)) AS fund_code,
               dbo.fn_try_date(s.flow_date)          AS flow_date,
               dbo.fn_conform(s.flow_type, ARRAY['mgmt_fee','fund_expense','lp_call','lp_distribution']) AS flow_type,
               dbo.fn_try_numeric(s.amount)          AS amount,
               upper(dbo.fn_clean_text(s.currency))  AS currency,
               to_jsonb(s) AS raw_record
        FROM staging.fund_cash_flows s
        ORDER BY upper(dbo.fn_clean_text(s.flow_id)), s._row_id DESC
    ) d;

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
    SELECT p_run_id, 'staging.fund_cash_flows', _row_id, flow_id, reject_reason, raw_record
    FROM tmp_fund_cash_flow WHERE reject_reason <> '';
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    TRUNCATE dbo.fund_cash_flow;
    INSERT INTO dbo.fund_cash_flow (flow_id, fund_code, flow_date, flow_type, amount, currency)
    SELECT flow_id, fund_code, flow_date, flow_type, amount, currency
    FROM tmp_fund_cash_flow WHERE reject_reason = '';
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_load_fund_cash_flow', v_start, v_read, v_loaded, v_rej);
END $$;
