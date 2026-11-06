-- KPI: W.avg spread (bps) (smart scalar: latest month vs previous month)
SELECT as_of_date,
       round(sum(spread_x_outstanding) / nullif(sum(outstanding_eur), 0), 0) AS "W.avg spread (bps)"
FROM bi.vw_portfolio_monthly
WHERE 1 = 1
  [[AND fund_code = {{fund}}]]
GROUP BY as_of_date
ORDER BY as_of_date
