-- KPI: Outstanding (EUR bn) (smart scalar: latest month vs previous month)
SELECT as_of_date,
       round(sum(outstanding_eur) / 1e9, 2) AS "Outstanding (EUR bn)"
FROM bi.vw_portfolio_monthly
WHERE 1 = 1
  [[AND fund_code = {{fund}}]]
GROUP BY as_of_date
ORDER BY as_of_date
