-- Dashboard views return data for the latest month (spec 005: bi.vw_fund_performance included)
WITH counts AS (
    SELECT count(*) AS n
    FROM bi.vw_facility_exposure AS e
    WHERE e.is_latest_month
    UNION ALL
    SELECT count(*) FROM bi.vw_portfolio_monthly
    UNION ALL
    SELECT count(*) FROM bi.vw_cash_flow_monthly
    UNION ALL
    SELECT count(*) FROM bi.vw_watchlist
    UNION ALL
    SELECT count(*)
    FROM bi.vw_fund_performance AS p
    WHERE p.is_latest_month AND p.level = 'FUND'
)

SELECT count(*)
FROM counts AS c
WHERE c.n = 0;
