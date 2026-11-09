-- =============================================================================
-- dbo.usp_load_cash_flow : staging.cash_flows -> dbo.cash_flow
--   spec 003: parses the transaction price ('98,75' -> 98.75, blank/0 kept as
--   NULL/0 and normalised later), conforms PIK, rejects impossible prices
--   (< 0, or > 200 on a PCT_OF_PAR instrument) with reason 'invalid price'.
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_load_cash_flow(p_run_id UUID)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT;
BEGIN
    SELECT count(*) INTO v_read FROM staging.cash_flows;

    DROP TABLE IF EXISTS tmp_cash_flow;
    CREATE TEMP TABLE tmp_cash_flow AS
    SELECT d.*,
           concat_ws('; ',
               CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.facility f WHERE f.facility_id = d.facility_id) THEN 'unknown facility' END,
               CASE WHEN d.transaction_date IS NULL THEN 'invalid date' END,
               CASE WHEN d.transaction_type IS NULL THEN 'unknown transaction type' END,
               CASE WHEN d.amount IS NULL THEN 'invalid amount' END,
               CASE WHEN d.amount < 0 THEN 'negative amount' END,          -- spec 005: sign comes from the type
               CASE WHEN d.price < 0
                      OR (d.price > 200 AND (SELECT ri.price_basis
                                               FROM dbo.facility f
                                               JOIN dbo.ref_instrument ri ON ri.instrument_type = f.instrument_type
                                              WHERE f.facility_id = d.facility_id) = 'PCT_OF_PAR')
                    THEN 'invalid price' END,
               CASE WHEN dbo.fn_clean_text(d.price_raw) IS NOT NULL AND d.price IS NULL THEN 'invalid price' END
           ) AS reject_reason
    FROM (
        SELECT DISTINCT ON (upper(dbo.fn_clean_text(s.transaction_id)))
               s._row_id,
               upper(dbo.fn_clean_text(s.transaction_id))   AS transaction_id,
               upper(dbo.fn_clean_text(s.facility_id))      AS facility_id,
               dbo.fn_try_date(s.transaction_date)          AS transaction_date,
               dbo.fn_conform(s.transaction_type, ARRAY['Drawdown','Repayment','Interest','Fee','PIK']) AS transaction_type,
               dbo.fn_try_numeric(s.amount)                 AS amount,
               dbo.fn_try_price(s.price)                    AS price,        -- '98,75' -> 98.75; '' -> NULL
               s.price                                      AS price_raw,
               upper(dbo.fn_clean_text(s.currency))         AS currency,
               to_jsonb(s) AS raw_record
        FROM staging.cash_flows s
        ORDER BY upper(dbo.fn_clean_text(s.transaction_id)), s._row_id DESC
    ) d;

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
    SELECT p_run_id, 'staging.cash_flows', _row_id, transaction_id, reject_reason, raw_record
    FROM tmp_cash_flow WHERE reject_reason <> '';
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    TRUNCATE dbo.cash_flow;
    INSERT INTO dbo.cash_flow (transaction_id, facility_id, transaction_date, transaction_type, amount, currency, price)
    SELECT transaction_id, facility_id, transaction_date, transaction_type, amount, currency, price
    FROM tmp_cash_flow WHERE reject_reason = '';
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_load_cash_flow', v_start, v_read, v_loaded, v_rej);
END $$;
