-- KPI: Unrealised gain/loss (EUR m) (smart scalar: latest month vs previous month; spec 003)
SELECT as_of_date,
       round(sum(unrealised_gain_eur) / 1e6, 1) AS "Unrealised gain/loss (EUR m)"
FROM bi.vw_portfolio_monthly
WHERE 1 = 1
  [[AND fund_code = {{fund}}]]
GROUP BY as_of_date
ORDER BY as_of_date
