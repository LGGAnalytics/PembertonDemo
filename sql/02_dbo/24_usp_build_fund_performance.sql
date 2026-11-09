-- =============================================================================
-- Spec 005: fund performance (Gross IRR, Net IRR, MOIC).
--
-- dbo.fn_gross_flow(T) : the gross cash flows of every facility up to T, in EUR,
--   signed from the fund's perspective (Drawdown < 0; Repayment, Interest, Fee > 0).
--   PIK is excluded: it is capitalised and already in the fair value.
--   FX: month-end dbo.fx_rate of the flow's month; a flow dated before the first
--   rate of its currency uses that first rate (decision D1); otherwise no rate
--   -> amount_eur NULL (the caller rejects it with 'no fx rate').
-- =============================================================================
CREATE OR REPLACE FUNCTION dbo.fn_gross_flow(p_as_of_date DATE)
RETURNS TABLE (
    transaction_id    TEXT,
    facility_id       TEXT,
    fund_code         TEXT,
    vintage_year      SMALLINT,
    flow_date         DATE,
    transaction_type  TEXT,
    currency          CHAR(3),
    amount_eur        NUMERIC
) LANGUAGE sql STABLE AS $$
    SELECT
        cf.transaction_id,
        cf.facility_id,
        f.fund_code,
        fd.vintage_year,
        cf.transaction_date,
        cf.transaction_type,
        cf.currency,
        CASE WHEN cf.transaction_type = 'Drawdown' THEN -1 ELSE 1 END
        * cf.amount
        * coalesce(
            fx.eur_per_unit,
            CASE WHEN dbo.fn_month_end(cf.transaction_date) < first_fx.rate_date THEN first_fx.eur_per_unit END
        )
    FROM dbo.cash_flow AS cf
    INNER JOIN dbo.facility AS f ON cf.facility_id = f.facility_id
    INNER JOIN dbo.fund AS fd ON f.fund_code = fd.fund_code
    LEFT JOIN dbo.fx_rate AS fx
        ON cf.currency = fx.currency AND fx.rate_date = dbo.fn_month_end(cf.transaction_date)
    LEFT JOIN LATERAL (
        SELECT
            r.rate_date,
            r.eur_per_unit
        FROM dbo.fx_rate AS r
        WHERE r.currency = cf.currency
        ORDER BY r.rate_date
        LIMIT 1
    ) AS first_fx ON TRUE
    WHERE
        cf.transaction_date <= p_as_of_date
        AND cf.transaction_type <> 'PIK'
$$;
