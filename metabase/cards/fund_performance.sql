-- Fund performance: Gross IRR, Net IRR and MOIC per fund, latest month (spec 005)
-- All figures are calculated in dbo.usp_build_fund_performance; this card only selects them.
SELECT fund_code                          AS "Fund",
       fund_name                          AS "Fund name",
       vintage_year                       AS "Vintage",
       gross_irr_pct                      AS "Gross IRR %",
       net_irr_pct                        AS "Net IRR %",
       moic                               AS "MOIC x",
       round(nav_eur / 1e6, 1)            AS "NAV (EUR m)",
       round(accrued_carry_eur / 1e6, 1)  AS "Accrued carry (EUR m)"
FROM bi.vw_fund_performance
WHERE level = 'FUND'
  AND is_latest_month
  [[AND fund_code = {{fund}}]]
ORDER BY fund_code
