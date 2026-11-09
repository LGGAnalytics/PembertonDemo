-- AC1 (spec 003): for PCT_OF_PAR facilities with a prior drawdown, cost_basis_local is
-- round((drawn - repaid) x wa / 100 + pik, 2), recomputed independently from dbo.cash_flow
-- (floored at 0, tolerance 0.01).
WITH cf AS (
    SELECT fm.facility_id, fm.as_of_date,
           sum(c.amount) FILTER (WHERE c.transaction_type = 'Drawdown')  AS drawn,
           sum(c.amount) FILTER (WHERE c.transaction_type = 'Repayment') AS repaid,
           sum(c.amount) FILTER (WHERE c.transaction_type = 'PIK')       AS pik,
           sum(c.amount * CASE WHEN coalesce(c.price, 0) = 0 THEN 100 ELSE c.price END)
               FILTER (WHERE c.transaction_type = 'Drawdown')
             / sum(c.amount) FILTER (WHERE c.transaction_type = 'Drawdown') AS wa
    FROM dbo.facility_month fm
    JOIN dbo.facility f        ON f.facility_id = fm.facility_id
    JOIN dbo.ref_instrument ri ON ri.instrument_type = f.instrument_type AND ri.price_basis = 'PCT_OF_PAR'
    JOIN dbo.cash_flow c       ON c.facility_id = fm.facility_id AND c.transaction_date <= fm.as_of_date
    GROUP BY fm.facility_id, fm.as_of_date
    HAVING sum(c.amount) FILTER (WHERE c.transaction_type = 'Drawdown') > 0
)
SELECT count(*)
FROM cf
JOIN dbo.facility_month fm USING (facility_id, as_of_date)
WHERE fm.cost_basis_local IS NULL
   OR abs(fm.cost_basis_local
          - round(greatest((cf.drawn - coalesce(cf.repaid, 0)) * cf.wa / 100 + coalesce(cf.pik, 0), 0), 2)) > 0.01;
