-- Cash interest received per month (EUR m); PIK and non-accrual pay no cash
SELECT to_char(month_end, 'YYYY-MM') AS month,
       round(sum(amount_eur) / 1e6, 1) AS interest_eur_m
FROM bi.vw_cash_flow_monthly
WHERE transaction_type = 'Interest'
  [[AND fund_code = {{fund}}]]
GROUP BY month_end
ORDER BY month_end
