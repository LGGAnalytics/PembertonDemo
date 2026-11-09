-- AC7 (spec 004): bi.vw_rating_migration outstanding per month reconciles to dbo.facility_month
SELECT count(*)
FROM (SELECT as_of_date, sum(outstanding_eur) AS v FROM bi.vw_rating_migration GROUP BY 1) m
FULL JOIN (SELECT as_of_date, sum(outstanding_eur) AS v FROM dbo.facility_month GROUP BY 1) d USING (as_of_date)
WHERE round(m.v, 0) IS DISTINCT FROM round(d.v, 0);
