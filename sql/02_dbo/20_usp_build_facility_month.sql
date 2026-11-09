-- =============================================================================
-- dbo.usp_build_facility_month : builds the monthly fact dbo.facility_month
--   grain   : one row per facility per month-end mark, ONE PERIOD per call
--   step 1  : this procedure writes LOCAL-currency measures (fx_eur_per_unit NULL)
--   step 2  : dbo.usp_apply_fx_rates converts to EUR (client: usp_UpdatePositionFxRates)
--   yield   : all-in rate = max(base rate, floor) + spread
--   status  : Non-accrual > Impaired (rating 5) > Watchlist (rating 4 or DPD >= 30) > Performing
--   hook    : dbo.etl_config.fail_on_period = this period -> RAISE (test only)
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_build_facility_month(p_run_id UUID, p_as_of_date DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_start   TIMESTAMPTZ := clock_timestamp();
    v_read    INT;
    v_loaded  INT;
    v_rej     INT;
BEGIN
    IF dbo.fn_config_date('fail_on_period') = p_as_of_date THEN
        RAISE EXCEPTION 'Injected failure for period % (dbo.etl_config.fail_on_period)', p_as_of_date;
    END IF;

    SELECT count(*) INTO v_read FROM dbo.loan_mark WHERE as_of_date = p_as_of_date;

    -- marks that cannot be priced (no reference rate) are rejected, not silently dropped
    INSERT INTO dbo.etl_reject (run_id, source_table, business_key, as_of_date, reason)
    SELECT p_run_id, 'dbo.loan_mark', m.facility_id || '@' || m.as_of_date, m.as_of_date,
           'no reference rate for ' || f.base_rate_name
    FROM dbo.loan_mark m
    JOIN dbo.facility f             ON f.facility_id = m.facility_id
    LEFT JOIN dbo.reference_rate rr ON rr.rate_date  = m.as_of_date AND rr.rate_name = f.base_rate_name
    WHERE m.as_of_date = p_as_of_date
      AND rr.rate_pct IS NULL;
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    DELETE FROM dbo.facility_month WHERE as_of_date = p_as_of_date;     -- client: DELETE ... WHERE AsOfDate = @currentDate

    INSERT INTO dbo.facility_month (
        facility_id, as_of_date, fund_code, borrower_id, currency,
        commitment_local, outstanding_local, undrawn_local, fair_value_local,
        fair_value_price, spread_bps, base_rate_pct, all_in_rate_pct,
        internal_rating, days_past_due, is_non_accrual, risk_status,
        etl_run_id, loaded_at)
    SELECT m.facility_id,
           m.as_of_date,
           f.fund_code,
           f.borrower_id,
           f.currency,
           f.commitment_amount                                              AS commitment_local,
           m.outstanding_principal                                          AS outstanding_local,
           greatest(f.commitment_amount - m.outstanding_principal, 0)       AS undrawn_local,
           round(m.outstanding_principal * m.fair_value_price / 100, 2)     AS fair_value_local,
           m.fair_value_price,
           f.spread_bps,
           rr.rate_pct                                                      AS base_rate_pct,
           greatest(rr.rate_pct, f.floor_bps / 100.0) + f.spread_bps / 100.0 AS all_in_rate_pct,   -- floor applies to the base rate only
           m.internal_rating,
           m.days_past_due,
           m.is_non_accrual,
           CASE WHEN m.is_non_accrual                                THEN 'Non-accrual'
                WHEN m.internal_rating = 5                           THEN 'Impaired'
                WHEN m.internal_rating = 4 OR m.days_past_due >= 30  THEN 'Watchlist'
                ELSE 'Performing' END                                       AS risk_status,
           p_run_id,
           clock_timestamp()
    FROM dbo.loan_mark m
    JOIN dbo.facility f        ON f.facility_id = m.facility_id
    JOIN dbo.reference_rate rr ON rr.rate_date  = m.as_of_date AND rr.rate_name = f.base_rate_name
    WHERE m.as_of_date = p_as_of_date;
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_build_facility_month', v_start, v_read, v_loaded, v_rej, p_as_of_date);
END $$;
