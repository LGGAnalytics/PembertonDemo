-- AC2 (spec 003): PER_UNIT facilities: cost = round((drawn - repaid) x wa, 2) and
-- fair_value_eur = outstanding x fx x fair_value_price. Also fails if no equity row exists.
WITH eq AS (
    SELECT fm.*
    FROM dbo.facility_month fm
    JOIN dbo.facility f        ON f.facility_id = fm.facility_id
    JOIN dbo.ref_instrument ri ON ri.instrument_type = f.instrument_type AND ri.price_basis = 'PER_UNIT'
), cf AS (
    SELECT eq.facility_id, eq.as_of_date,
           sum(c.amount) FILTER (WHERE c.transaction_type = 'Drawdown')  AS drawn,
           sum(c.amount) FILTER (WHERE c.transaction_type = 'Repayment') AS repaid,
           sum(c.amount * CASE WHEN coalesce(c.price, 0) = 0 THEN 1 ELSE c.price END)
               FILTER (WHERE c.transaction_type = 'Drawdown')
             / sum(c.amount) FILTER (WHERE c.transaction_type = 'Drawdown') AS wa
    FROM eq JOIN dbo.cash_flow c ON c.facility_id = eq.facility_id AND c.transaction_date <= eq.as_of_date
    GROUP BY eq.facility_id, eq.as_of_date
)
SELECT (SELECT CASE WHEN count(*) = 0 THEN 1 ELSE 0 END FROM eq)
     + (SELECT count(*) FROM eq JOIN cf USING (facility_id, as_of_date)
         WHERE cf.drawn > 0
           AND (eq.cost_basis_local IS NULL
                OR abs(eq.cost_basis_local - round(greatest((cf.drawn - coalesce(cf.repaid, 0)) * cf.wa, 0), 2)) > 0.01))
     + (SELECT count(*) FROM eq
         WHERE abs(eq.fair_value_eur - eq.outstanding_local * eq.fx_eur_per_unit * eq.fair_value_price) > 0.05
            OR eq.all_in_rate_pct IS NOT NULL);
