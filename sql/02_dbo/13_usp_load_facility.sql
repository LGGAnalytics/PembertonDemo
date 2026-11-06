-- =============================================================================
-- dbo.usp_load_facility : staging.facilities -> dbo.facility
--   * mixed date formats parsed; impossible dates rejected
--   * amounts with thousands separators parsed; non-numeric rejected
--   * instrument conformed to dbo.ref_instrument; currency upper-cased
--   * orphan borrower / fund rejected (referential integrity)
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_load_facility(p_run_id UUID)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT;
        v_instr TEXT[] := ARRAY(SELECT instrument_type FROM dbo.ref_instrument);
BEGIN
    SELECT count(*) INTO v_read FROM staging.facilities;

    DROP TABLE IF EXISTS tmp_facility;
    CREATE TEMP TABLE tmp_facility AS
    SELECT d.*,
           concat_ws('; ',
               CASE WHEN d.facility_id IS NULL THEN 'missing facility_id' END,
               CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.borrower b WHERE b.borrower_id = d.borrower_id) THEN 'unknown borrower' END,
               CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.fund f WHERE f.fund_code = d.fund_code) THEN 'unknown fund' END,
               CASE WHEN d.instrument_type   IS NULL THEN 'unknown instrument' END,
               CASE WHEN d.commitment_amount IS NULL OR d.commitment_amount <= 0 THEN 'invalid commitment' END,
               CASE WHEN d.spread_bps        IS NULL THEN 'invalid spread' END,
               CASE WHEN d.origination_date  IS NULL THEN 'invalid origination date' END,
               CASE WHEN d.maturity_date     IS NULL THEN 'invalid maturity date' END,
               CASE WHEN d.maturity_date <= d.origination_date THEN 'maturity before origination' END
           ) AS reject_reason
    FROM (
        SELECT DISTINCT ON (upper(dbo.fn_clean_text(s.facility_id)))
               s._row_id,
               upper(dbo.fn_clean_text(s.facility_id))        AS facility_id,
               upper(dbo.fn_clean_text(s.borrower_id))        AS borrower_id,
               upper(dbo.fn_clean_text(s.fund_code))          AS fund_code,
               dbo.fn_conform(s.instrument_type, v_instr)     AS instrument_type,
               upper(dbo.fn_clean_text(s.currency))           AS currency,
               dbo.fn_try_numeric(s.commitment_amount)        AS commitment_amount,
               dbo.fn_clean_text(s.base_rate)                 AS base_rate_name,
               dbo.fn_try_numeric(s.spread_bps)::INT          AS spread_bps,
               coalesce(dbo.fn_try_numeric(s.floor_bps), 0)::INT AS floor_bps,
               dbo.fn_try_numeric(s.oid_price)                AS oid_price,
               dbo.fn_try_date(s.origination_date)            AS origination_date,
               dbo.fn_try_date(s.maturity_date)               AS maturity_date,
               to_jsonb(s) AS raw_record
        FROM staging.facilities s
        ORDER BY upper(dbo.fn_clean_text(s.facility_id)), s._row_id DESC
    ) d;

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
    SELECT p_run_id, 'staging.facilities', _row_id, facility_id, reject_reason, raw_record
    FROM tmp_facility WHERE reject_reason <> '';
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    TRUNCATE dbo.facility CASCADE;
    INSERT INTO dbo.facility (facility_id, borrower_id, fund_code, instrument_type, currency,
        commitment_amount, base_rate_name, spread_bps, floor_bps, oid_price,
        origination_date, maturity_date, tenor_years)
    SELECT facility_id, borrower_id, fund_code, instrument_type, currency,
           commitment_amount, base_rate_name, spread_bps, floor_bps, oid_price,
           origination_date, maturity_date,
           round(((maturity_date - origination_date) / 365.25)::NUMERIC, 2)
    FROM tmp_facility WHERE reject_reason = '';
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_load_facility', v_start, v_read, v_loaded, v_rej);
END $$;
