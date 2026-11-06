-- Exposure by country, latest month (EUR m)
SELECT country_name AS "Country",
       round(sum(outstanding_eur) / 1e6) AS outstanding_eur_m
FROM bi.vw_facility_exposure
WHERE is_latest_month
  [[AND fund_code = {{fund}}]]
GROUP BY 1
ORDER BY 2 DESC
