-- =============================================================================
-- dbo.usp_load_loan_mark : staging.loan_marks -> dbo.loan_mark, ONE PERIOD at a time
--   * runs inside the period loop of dbo.usp_run_etl
--   * DELETE the period + INSERT (client: DELETE FROM Position WHERE AsOfDate = @currentDate)
--   * missing internal rating kept as NULL (shown as "Not rated"); Y/N flag -> BOOLEAN
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_load_loan_mark(p_run_id UUID, p_as_of_date DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_start   TIMESTAMPTZ := clock_timestamp();
    v_read    INT;
    v_loaded  INT;
    v_rej     INT;
BEGIN
    SELECT count(*) INTO v_read
    FROM staging.loan_marks s
    WHERE dbo.fn_try_date(s.as_of_date) = p_as_of_date;

    DROP TABLE IF EXISTS tmp_loan_mark;
    CREATE TEMP TABLE tmp_loan_mark AS
    SELECT d.*,
           concat_ws('; ',
               CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.facility f WHERE f.facility_id = d.facility_id) THEN 'unknown facility' END,
               CASE WHEN d.outstanding_principal IS NULL THEN 'invalid outstanding' END,
               CASE WHEN d.fair_value_price      IS NULL THEN 'invalid price' END
           ) AS reject_reason
    FROM (
        SELECT DISTINCT ON (upper(dbo.fn_clean_text(s.facility_id)))
               s._row_id,
               upper(dbo.fn_clean_text(s.facility_id))                AS facility_id,
               p_as_of_date                                           AS as_of_date,
               dbo.fn_try_numeric(s.outstanding_principal)            AS outstanding_principal,
               dbo.fn_try_numeric(s.fair_value_price)                 AS fair_value_price,
               dbo.fn_try_numeric(s.internal_rating)::SMALLINT        AS internal_rating,
               coalesce(dbo.fn_try_numeric(s.days_past_due), 0)::INT  AS days_past_due,
               upper(dbo.fn_clean_text(s.non_accrual_flag)) IN ('Y','YES','TRUE','1') AS is_non_accrual,
               to_jsonb(s)                                            AS raw_record
        FROM staging.loan_marks s
        WHERE dbo.fn_try_date(s.as_of_date) = p_as_of_date             -- this period only
        ORDER BY upper(dbo.fn_clean_text(s.facility_id)), s._row_id DESC   -- latest staged row wins
    ) d;

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, as_of_date, reason, raw_record)
    SELECT p_run_id, 'staging.loan_marks', _row_id, facility_id || '@' || as_of_date, as_of_date, reject_reason, raw_record
    FROM tmp_loan_mark WHERE reject_reason <> '';
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    DELETE FROM dbo.loan_mark WHERE as_of_date = p_as_of_date;

    INSERT INTO dbo.loan_mark (facility_id, as_of_date, outstanding_principal, fair_value_price,
                               internal_rating, days_past_due, is_non_accrual, etl_run_id, loaded_at)
    SELECT facility_id, as_of_date, outstanding_principal, fair_value_price,
           internal_rating, days_past_due, is_non_accrual, p_run_id, clock_timestamp()
    FROM tmp_loan_mark WHERE reject_reason = '';
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    DROP TABLE IF EXISTS tmp_loan_mark;
    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_load_loan_mark', v_start, v_read, v_loaded, v_rej, p_as_of_date);
END $$;
