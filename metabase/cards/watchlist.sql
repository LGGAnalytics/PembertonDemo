-- Watchlist & non-accrual, latest month
SELECT borrower_name                  AS "Borrower",
       sector_name                    AS "Sector",
       country_name                   AS "Country",
       fund_code                      AS "Fund",
       instrument_type                AS "Instrument",
       round(outstanding_eur / 1e6, 1) AS "Outstanding (EUR m)",
       fair_value_price               AS "Price",
       internal_rating                AS "Rating",
       days_past_due                  AS "DPD",
       risk_status                    AS "Status"
FROM bi.vw_watchlist
WHERE 1 = 1
  [[AND fund_code = {{fund}}]]
ORDER BY severity_rank, outstanding_eur DESC
