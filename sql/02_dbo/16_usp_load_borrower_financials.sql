-- =============================================================================
-- dbo.usp_load_borrower_financials : staging.borrower_financials -> dbo.borrower_financials
--   Quarterly LTM financials. A missing EBITDA (late reporting) is kept as NULL,
--   not rejected: the quarter still carries debt and cash information.
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_load_borrower_financials(p_run_id UUID)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT;
BEGIN
    SELECT count(*) INTO v_read FROM staging.borrower_financials;

    DROP TABLE IF EXISTS tmp_fin;
    CREATE TEMP TABLE tmp_fin AS
    SELECT d.*,
           concat_ws('; ',
               CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.borrower b WHERE b.borrower_id = d.borrower_id) THEN 'unknown borrower' END,
               CASE WHEN d.period_end_date IS NULL THEN 'invalid period_end_date' END
           ) AS reject_reason
    FROM (
        SELECT DISTINCT ON (upper(dbo.fn_clean_text(s.borrower_id)), dbo.fn_try_date(s.period_end_date))
               s._row_id,
               upper(dbo.fn_clean_text(s.borrower_id))         AS borrower_id,
               dbo.fn_try_date(s.period_end_date)              AS period_end_date,
               dbo.fn_try_numeric(s.revenue_ltm)               AS revenue_ltm,
               dbo.fn_try_numeric(s.ebitda_ltm)                AS ebitda_ltm,
               dbo.fn_try_numeric(s.total_debt)                AS total_debt,
               dbo.fn_try_numeric(s.cash_and_equivalents)      AS cash_and_equivalents,
               dbo.fn_try_numeric(s.interest_expense_ltm)      AS interest_expense_ltm,
               coalesce(upper(dbo.fn_clean_text(s.reporting_currency)), 'EUR') AS reporting_currency,
               to_jsonb(s) AS raw_record
        FROM staging.borrower_financials s
        ORDER BY upper(dbo.fn_clean_text(s.borrower_id)), dbo.fn_try_date(s.period_end_date), s._row_id DESC
    ) d;

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
    SELECT p_run_id, 'staging.borrower_financials', _row_id, borrower_id, reject_reason, raw_record
    FROM tmp_fin WHERE reject_reason <> '';
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    TRUNCATE dbo.borrower_financials;
    INSERT INTO dbo.borrower_financials (borrower_id, period_end_date, revenue_ltm, ebitda_ltm, total_debt,
                                         cash_and_equivalents, interest_expense_ltm, reporting_currency)
    SELECT borrower_id, period_end_date, revenue_ltm, ebitda_ltm, total_debt,
           cash_and_equivalents, interest_expense_ltm, reporting_currency
    FROM tmp_fin WHERE reject_reason = '';
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_load_borrower_financials', v_start, v_read, v_loaded, v_rej);
END $$;
