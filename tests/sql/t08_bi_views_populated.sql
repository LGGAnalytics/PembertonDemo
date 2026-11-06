-- Dashboard views return data for the latest month
SELECT count(*) FROM (VALUES
  ((SELECT count(*) FROM bi.vw_facility_exposure WHERE is_latest_month)),
  ((SELECT count(*) FROM bi.vw_portfolio_monthly)),
  ((SELECT count(*) FROM bi.vw_cash_flow_monthly)),
  ((SELECT count(*) FROM bi.vw_watchlist))) t(n)
WHERE n = 0;
