-- Outstanding exposure by fund over time (EUR bn)
SELECT as_of_date,
       fund_code,
       round(sum(outstanding_eur) / 1e9, 2) AS outstanding_eur_bn
FROM bi.vw_portfolio_monthly
WHERE 1 = 1
  [[AND fund_code = {{fund}}]]
GROUP BY as_of_date, fund_code
ORDER BY as_of_date, fund_code
