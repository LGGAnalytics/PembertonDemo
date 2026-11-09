-- Exposure by rating band, latest month, stacked by fund (EUR m; spec 004)
SELECT rating_band                          AS "Rating band",
       fund_code,
       round(sum(outstanding_eur) / 1e6, 1) AS outstanding_eur_m
FROM bi.vw_facility_exposure
WHERE is_latest_month
  [[AND fund_code = {{fund}}]]
GROUP BY rating_band, fund_code
ORDER BY rating_band, fund_code
