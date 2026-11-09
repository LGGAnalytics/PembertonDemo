-- Cost vs fair value by fund, latest month (EUR m; spec 003)
SELECT fund_code                            AS "Fund",
       round(sum(cost_basis_eur) / 1e6, 1)  AS cost_eur_m,
       round(sum(fair_value_eur) / 1e6, 1)  AS fair_value_eur_m
FROM bi.vw_portfolio_monthly
WHERE as_of_date = (SELECT max(as_of_date) FROM bi.vw_portfolio_monthly)
  [[AND fund_code = {{fund}}]]
GROUP BY fund_code
ORDER BY fund_code
