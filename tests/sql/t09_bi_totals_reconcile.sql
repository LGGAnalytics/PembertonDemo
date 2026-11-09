-- BI aggregates reconcile to the dbo fact (no rows lost or duplicated by joins)
-- spec 003 AC6: portfolio unrealised gain reconciles per month as well
SELECT (SELECT count(*) FROM (
          SELECT round((SELECT sum(outstanding_eur) FROM bi.vw_portfolio_monthly), 0)
               - round((SELECT sum(outstanding_eur) FROM dbo.facility_month), 0) AS d1,
                 round((SELECT sum(outstanding_eur) FROM bi.vw_facility_exposure), 0)
               - round((SELECT sum(outstanding_eur) FROM dbo.facility_month), 0) AS d2) x
         WHERE d1 <> 0 OR d2 <> 0)
     + (SELECT count(*) FROM (
          SELECT as_of_date, sum(unrealised_gain_eur) AS bi_gain FROM bi.vw_portfolio_monthly GROUP BY as_of_date) b
          FULL JOIN (SELECT as_of_date, sum(unrealised_gain_eur) AS dbo_gain FROM dbo.facility_month GROUP BY as_of_date) d
          USING (as_of_date)
         WHERE round(b.bi_gain, 0) IS DISTINCT FROM round(d.dbo_gain, 0));
