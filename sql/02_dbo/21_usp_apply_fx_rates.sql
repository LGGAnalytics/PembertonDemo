-- =============================================================================
-- dbo.usp_apply_fx_rates : converts one period of dbo.facility_month to EUR.
--   Mirrors the client's usp_UpdatePositionFxRates, called inside the period loop
--   right after the local-currency insert. Rows that still have no FX rate are
--   removed from the period and written to dbo.etl_reject, so after the period's
--   COMMIT every *_eur column is populated.
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_apply_fx_rates(p_run_id UUID, p_as_of_date DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_start   TIMESTAMPTZ := clock_timestamp();
    v_read    INT;
    v_loaded  INT;
    v_rej     INT;
BEGIN
    SELECT count(*) INTO v_read FROM dbo.facility_month WHERE as_of_date = p_as_of_date;

    UPDATE dbo.facility_month fm
       SET fx_eur_per_unit = fx.eur_per_unit,
           commitment_eur  = round(fm.commitment_local  * fx.eur_per_unit, 2),
           outstanding_eur = round(fm.outstanding_local * fx.eur_per_unit, 2),
           undrawn_eur     = round(fm.undrawn_local     * fx.eur_per_unit, 2),
           fair_value_eur  = round(fm.fair_value_local  * fx.eur_per_unit, 2)
      FROM dbo.fx_rate fx
     WHERE fm.as_of_date = p_as_of_date
       AND fx.rate_date  = fm.as_of_date                                  -- month-end rate
       AND fx.currency   = fm.currency;
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    -- unconverted rows cannot be shown in a EUR dashboard: remove and explain
    WITH gone AS (
        DELETE FROM dbo.facility_month fm
         WHERE fm.as_of_date = p_as_of_date
           AND fm.fx_eur_per_unit IS NULL
        RETURNING fm.facility_id, fm.as_of_date, fm.currency)
    INSERT INTO dbo.etl_reject (run_id, source_table, business_key, as_of_date, reason)
    SELECT p_run_id, 'dbo.facility_month', facility_id || '@' || as_of_date, as_of_date,
           'no FX rate for ' || currency
    FROM gone;
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_apply_fx_rates', v_start, v_read, v_loaded, v_rej, p_as_of_date);
END $$;
