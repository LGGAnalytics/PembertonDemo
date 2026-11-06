-- =============================================================================
-- dbo.usp_build_facility_month : builds the monthly fact dbo.facility_month
--   grain   : one row per facility per month-end mark
--   EUR     : local amounts x month-end dbo.fx_rate
--   yield   : all-in rate = max(base rate, floor) + spread
--   status  : Non-accrual > Impaired (rating 5) > Watchlist (rating 4 or DPD >= 30) > Performing
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_build_facility_month(p_run_id UUID)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT;
BEGIN
    SELECT count(*) INTO v_read FROM dbo.loan_mark;

    -- marks that cannot be converted to EUR or priced are rejected, not silently dropped
    INSERT INTO dbo.etl_reject (run_id, source_table, business_key, reason)
    SELECT p_run_id, 'dbo.loan_mark', m.facility_id || '@' || m.as_of_date,
           concat_ws('; ', CASE WHEN fx.eur_per_unit IS NULL THEN 'no FX rate' END,
                           CASE WHEN rr.rate_pct IS NULL THEN 'no reference rate' END)
    FROM dbo.loan_mark m
    JOIN dbo.facility f ON f.facility_id = m.facility_id
    LEFT JOIN dbo.fx_rate fx        ON fx.rate_date = m.as_of_date AND fx.currency = f.currency
    LEFT JOIN dbo.reference_rate rr ON rr.rate_date = m.as_of_date AND rr.rate_name = f.base_rate_name
    WHERE fx.eur_per_unit IS NULL OR rr.rate_pct IS NULL;
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    TRUNCATE dbo.facility_month;
    INSERT INTO dbo.facility_month (
        facility_id, as_of_date, fund_code, borrower_id, currency, fx_eur_per_unit,
        commitment_eur, outstanding_eur, undrawn_eur, fair_value_price, fair_value_eur,
        spread_bps, base_rate_pct, all_in_rate_pct, internal_rating, days_past_due,
        is_non_accrual, risk_status)
    SELECT m.facility_id,
           m.as_of_date,
           f.fund_code,
           f.borrower_id,
           f.currency,
           fx.eur_per_unit,
           round(f.commitment_amount * fx.eur_per_unit, 2),
           round(m.outstanding_principal * fx.eur_per_unit, 2),
           round(greatest(f.commitment_amount - m.outstanding_principal, 0) * fx.eur_per_unit, 2),
           m.fair_value_price,
           round(m.outstanding_principal * fx.eur_per_unit * m.fair_value_price / 100, 2),
           f.spread_bps,
           rr.rate_pct,
           greatest(rr.rate_pct, f.floor_bps / 100.0) + f.spread_bps / 100.0,
           m.internal_rating,
           m.days_past_due,
           m.is_non_accrual,
           CASE WHEN m.is_non_accrual                              THEN 'Non-accrual'
                WHEN m.internal_rating = 5                         THEN 'Impaired'
                WHEN m.internal_rating = 4 OR m.days_past_due >= 30 THEN 'Watchlist'
                ELSE 'Performing' END
    FROM dbo.loan_mark m
    JOIN dbo.facility f       ON f.facility_id = m.facility_id
    JOIN dbo.fx_rate fx       ON fx.rate_date = m.as_of_date AND fx.currency = f.currency
    JOIN dbo.reference_rate rr ON rr.rate_date = m.as_of_date AND rr.rate_name = f.base_rate_name;
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_build_facility_month', v_start, v_read, v_loaded, v_rej);
END $$;
