-- KPI: Non-accrual (% of outstanding) (smart scalar: latest month vs previous month)
SELECT as_of_date,
       round(100 * coalesce(sum(non_accrual_eur), 0) / nullif(sum(outstanding_eur), 0), 1) AS "Non-accrual (% of outstanding)"
FROM bi.vw_portfolio_monthly
WHERE 1 = 1
  [[AND fund_code = {{fund}}]]
GROUP BY as_of_date
ORDER BY as_of_date
