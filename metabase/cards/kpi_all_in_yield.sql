-- KPI: W.avg all-in yield (%) (smart scalar: latest month vs previous month)
SELECT as_of_date,
       round(sum(all_in_rate_x_outstanding) / nullif(sum(debt_outstanding_eur), 0), 2) AS "W.avg all-in yield (%)"
FROM bi.vw_portfolio_monthly
WHERE 1 = 1
  [[AND fund_code = {{fund}}]]
GROUP BY as_of_date
ORDER BY as_of_date
