-- =============================================================================
-- dbo.usp_build_cost_basis : cost basis, weighted-average acquisition price and
-- unrealised / realised gain for ONE period of dbo.facility_month (spec 003).
--
-- Mirrors the client's usp_CreatePositionEquityCost, three temp-table stages:
--   stage 1  tmp_txn      : transaction ledger aggregated per facility up to the
--                           period (client #tmp), price normalised and scaled by
--                           price basis in nested derived tables
--   stage 2  tmp_position : join to the period's fact rows, CASE on price basis
--                           (client #tmp2, CASE on AssetTypeCodeName = 'EQUITY')
--   stage 3  UPDATE dbo.facility_month ... FROM tmp_position (client UPDATE P)
-- Data-quality rows ('no acquisition cash flow', 'over-repaid') go to
-- dbo.etl_reject; the fact rows are KEPT.
-- Runs inside the period loop of dbo.usp_run_etl, after usp_apply_fx_rates.
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_build_cost_basis(p_run_id UUID, p_as_of_date DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_start   TIMESTAMPTZ := clock_timestamp();
    v_read    INT;
    v_loaded  INT;
    v_rej     INT;
BEGIN
    SELECT count(*) INTO v_read FROM dbo.facility_month WHERE as_of_date = p_as_of_date;

    -- stage 1: transaction aggregates per facility, cumulative to the period (client: #tmp)
    DROP TABLE IF EXISTS tmp_txn;
    CREATE TEMP TABLE tmp_txn AS
    SELECT  x.facility_id,
            sum(x.draw_amount)                                                   AS drawn_to_date_local,
            sum(x.repay_amount)                                                  AS repaid_to_date_local,
            sum(x.pik_amount)                                                    AS pik_to_date_local,
            sum(x.draw_amount * x.price_norm)
                / nullif(sum(x.draw_amount), 0)                                  AS wa_acquisition_price,   -- client: CASE WHEN SUM(...)=0 THEN 1; we return NULL instead
            sum(x.repay_amount * (x.price_norm - x.wa_price_at_txn) / x.scale)  AS realised_gain_local
    FROM (
        SELECT  y.facility_id,
                y.price_norm,
                y.scale,
                CASE WHEN y.transaction_type = 'Drawdown'  THEN y.amount ELSE 0 END AS draw_amount,
                CASE WHEN y.transaction_type = 'Repayment' THEN y.amount ELSE 0 END AS repay_amount,
                CASE WHEN y.transaction_type = 'PIK'       THEN y.amount ELSE 0 END AS pik_amount,
                -- running WA price BEFORE this transaction, for realised P&L on repayments
                sum(CASE WHEN y.transaction_type = 'Drawdown' THEN y.amount * y.price_norm END)
                                      OVER w
                    / nullif(sum(CASE WHEN y.transaction_type = 'Drawdown' THEN y.amount END)
                                      OVER w, 0)                              AS wa_price_at_txn
        FROM (
            SELECT  t.facility_id,
                    t.transaction_id,
                    t.transaction_date,
                    t.transaction_type,
                    t.amount,
                    CASE WHEN ri.price_basis = 'PER_UNIT' THEN 1.00 ELSE 100.00 END AS scale,      -- client: IsEquity -> 1.00 / 100.00
                    CASE WHEN ri.price_basis = 'PER_UNIT'
                         THEN CASE WHEN coalesce(t.price, 0) = 0 THEN 1   ELSE t.price END          -- client: ISNULL(Price,0.01)=0 -> 1
                         ELSE CASE WHEN coalesce(t.price, 0) = 0 THEN 100 ELSE t.price END          -- par when missing
                    END                                                                AS price_norm
            FROM dbo.cash_flow t
            JOIN dbo.facility       f  ON f.facility_id      = t.facility_id
            JOIN dbo.ref_instrument ri ON ri.instrument_type = f.instrument_type
            WHERE t.transaction_type IN ('Drawdown', 'Repayment', 'PIK')                  -- client: IN ('BUY','SLL','DRAW','REPAY','LPAYD')
              AND t.transaction_date <= p_as_of_date                                      -- cumulative to the period
        ) y
        WINDOW w AS (PARTITION BY y.facility_id ORDER BY y.transaction_date, y.transaction_id
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
    ) x
    GROUP BY x.facility_id;

    -- stage 2: position join, CASE on price basis (client: #tmp2)
    DROP TABLE IF EXISTS tmp_position;
    CREATE TEMP TABLE tmp_position AS
    SELECT  fm.facility_id,
            fm.as_of_date,
            fm.outstanding_local,
            t.drawn_to_date_local,
            t.repaid_to_date_local,
            t.pik_to_date_local,
            t.wa_acquisition_price,
            CASE WHEN ri.price_basis = 'PER_UNIT'
                 THEN  (t.drawn_to_date_local - t.repaid_to_date_local) * t.wa_acquisition_price
                 ELSE  (t.drawn_to_date_local - t.repaid_to_date_local) * t.wa_acquisition_price / 100
                     + t.pik_to_date_local
            END                                                   AS cost_basis_local,
            t.realised_gain_local,
            coalesce(t.wa_acquisition_price IS NOT NULL, FALSE) AS has_acquisition
    FROM dbo.facility_month fm
    JOIN dbo.facility       f  ON f.facility_id      = fm.facility_id
    JOIN dbo.ref_instrument ri ON ri.instrument_type = f.instrument_type
    LEFT JOIN tmp_txn       t  ON t.facility_id      = fm.facility_id
    WHERE fm.as_of_date = p_as_of_date;

    -- stage 3: update the period's fact rows (client: UPDATE P SET ... FROM dbo.Position P JOIN #tmp2 T)
    UPDATE dbo.facility_month fm
       SET drawn_to_date_local  = coalesce(t.drawn_to_date_local, 0),
           repaid_to_date_local = coalesce(t.repaid_to_date_local, 0),
           pik_to_date_local    = coalesce(t.pik_to_date_local, 0),
           wa_acquisition_price = round(t.wa_acquisition_price, 4),
           -- greatest() ignores NULL in PostgreSQL, so "no acquisition" must stay NULL explicitly
           cost_basis_local     = CASE WHEN t.has_acquisition THEN round(greatest(t.cost_basis_local, 0), 2) END,
           cost_basis_eur       = CASE WHEN t.has_acquisition THEN round(greatest(t.cost_basis_local, 0) * fm.fx_eur_per_unit, 2) END,
           unrealised_gain_eur  = CASE WHEN t.has_acquisition
                                       THEN fm.fair_value_eur - round(greatest(t.cost_basis_local, 0) * fm.fx_eur_per_unit, 2) END,
           realised_gain_local  = round(coalesce(t.realised_gain_local, 0), 2)
      FROM tmp_position t
     WHERE fm.facility_id = t.facility_id
       AND fm.as_of_date  = p_as_of_date;
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    -- data-quality rows: kept in the fact, explained in etl_reject
    INSERT INTO dbo.etl_reject (run_id, source_table, business_key, as_of_date, reason)
    SELECT p_run_id, 'dbo.facility_month', t.facility_id || '@' || t.as_of_date, t.as_of_date,
           CASE WHEN NOT t.has_acquisition THEN 'no acquisition cash flow' ELSE 'over-repaid' END
    FROM tmp_position t
    WHERE (NOT t.has_acquisition AND t.outstanding_local > 0)
       OR t.cost_basis_local < -1.00;                         -- tolerance: ledger amounts are rounded to cents
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    DROP TABLE IF EXISTS tmp_txn;
    DROP TABLE IF EXISTS tmp_position;
    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_build_cost_basis', v_start, v_read, v_loaded, v_rej, p_as_of_date);
END $$;
