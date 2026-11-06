-- KPI: Fair value (% of par) (smart scalar: latest month vs previous month)
SELECT as_of_date,
       round(100 * sum(fair_value_eur) / nullif(sum(outstanding_eur), 0), 1) AS "Fair value (% of par)"
FROM bi.vw_portfolio_monthly
WHERE 1 = 1
  [[AND fund_code = {{fund}}]]
GROUP BY as_of_date
ORDER BY as_of_date
