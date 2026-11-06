-- Internal rating distribution, % of outstanding, latest month (1 strong -> 5 impaired)
SELECT internal_rating_label AS "Rating",
       round(100 * sum(outstanding_eur) / sum(sum(outstanding_eur)) OVER (), 1) AS pct_of_outstanding
FROM bi.vw_facility_exposure
WHERE is_latest_month
  [[AND fund_code = {{fund}}]]
GROUP BY internal_rating_label
ORDER BY internal_rating_label
