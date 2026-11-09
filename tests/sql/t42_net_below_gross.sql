-- AC3 (spec 005): with fund_terms and fund_cash_flows loaded,
--   * every fund has a mgmt_fee and a fund_expense row at every quarter-end from the quarter of its
--     first drawdown to Sep-2026 (decision D2)
--   * at the latest as_of_date, net_irr < gross_irr for every FUND row with gross_irr > 0
WITH first_dd AS (
    SELECT
        f.fund_code,
        min(cf.transaction_date) AS d
    FROM dbo.cash_flow AS cf
    INNER JOIN dbo.facility AS f ON cf.facility_id = f.facility_id
    WHERE cf.transaction_type = 'Drawdown'
    GROUP BY f.fund_code
),

quarter_ends AS (
    SELECT
        fd.fund_code,
        dbo.fn_month_end(g.q::DATE) AS q
    FROM first_dd AS fd
    CROSS JOIN LATERAL generate_series(
        date_trunc('quarter', fd.d) + INTERVAL '2 month', DATE '2026-09-01', INTERVAL '3 month'
    ) AS g (q)
),

fee_types AS (
    SELECT t.flow_type
    FROM (VALUES ('mgmt_fee'), ('fund_expense')) AS t (flow_type)
)

SELECT
    (
        SELECT count(*)
        FROM quarter_ends AS qe
        CROSS JOIN fee_types AS ft
        WHERE NOT EXISTS (
            SELECT 1
            FROM dbo.fund_cash_flow AS c
            WHERE c.fund_code = qe.fund_code AND c.flow_type = ft.flow_type AND c.flow_date = qe.q
        )
    )
    + (CASE WHEN (SELECT count(DISTINCT qe.fund_code) FROM quarter_ends AS qe) = 3 THEN 0 ELSE 1 END)
    + (
        SELECT count(*)
        FROM dbo.fund_performance AS fp
        WHERE
            fp.level = 'FUND'
            AND fp.as_of_date = (SELECT max(m.as_of_date) FROM dbo.fund_performance AS m)
            AND fp.gross_irr > 0
            AND (fp.net_irr IS NULL OR fp.net_irr >= fp.gross_irr)
    )
    + abs(3 - (
        SELECT count(*)
        FROM dbo.fund_performance AS fp
        WHERE
            fp.level = 'FUND'
            AND fp.as_of_date = (SELECT max(m.as_of_date) FROM dbo.fund_performance AS m)
            AND fp.gross_irr > 0
    ));
