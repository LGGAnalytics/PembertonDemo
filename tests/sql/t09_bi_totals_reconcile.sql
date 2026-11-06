-- BI aggregates reconcile to the dbo fact (no rows lost or duplicated by joins)
SELECT count(*) FROM (
  SELECT round((SELECT sum(outstanding_eur) FROM bi.vw_portfolio_monthly), 0)
       - round((SELECT sum(outstanding_eur) FROM dbo.facility_month), 0) AS d1,
         round((SELECT sum(outstanding_eur) FROM bi.vw_facility_exposure), 0)
       - round((SELECT sum(outstanding_eur) FROM dbo.facility_month), 0) AS d2) x
WHERE d1 <> 0 OR d2 <> 0;
