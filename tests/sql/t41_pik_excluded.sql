-- AC2 (spec 005): PIK is not part of the gross flows. For the latest period, every facility
-- with PIK rows has no PIK in dbo.fn_gross_flow, and its gross flows are exactly its non-PIK
-- cash flows up to that date (same transactions), with amount_eur = signed amount x the D1 FX rate:
-- the month-end rate of the flow's month, else the currency's first rate for flows before it.
-- At least one pre-window (pre first FX date) flow must exist and be converted.
WITH t AS (
    SELECT max(fm.as_of_date) AS d
    FROM dbo.facility_month AS fm
),

pik_fac AS (
    SELECT DISTINCT cf.facility_id
    FROM dbo.cash_flow AS cf
    WHERE cf.transaction_type = 'PIK'
),

g AS (
    SELECT gf.*
    FROM t
    CROSS JOIN LATERAL dbo.fn_gross_flow(t.d) AS gf
    INNER JOIN pik_fac AS p ON gf.facility_id = p.facility_id
),

expected AS (
    SELECT cf.transaction_id
    FROM dbo.cash_flow AS cf
    INNER JOIN pik_fac AS p ON cf.facility_id = p.facility_id
    CROSS JOIN t
    WHERE cf.transaction_date <= t.d AND cf.transaction_type <> 'PIK'
)

SELECT
    (CASE WHEN (SELECT count(*) FROM pik_fac) = 0 THEN 1 ELSE 0 END)     -- the data must contain PIK
    + (
        SELECT count(*)
        FROM g
        WHERE g.transaction_type = 'PIK'
    )
    + (
        SELECT count(*)
        FROM (
            SELECT e.transaction_id FROM expected AS e
            EXCEPT
            SELECT g.transaction_id FROM g
        ) AS m
    )
    + (
        SELECT count(*)
        FROM (
            SELECT g.transaction_id FROM g
            EXCEPT
            SELECT e.transaction_id FROM expected AS e
        ) AS x
    )
    -- amounts: every flow converted, at the D1 rate (checked on all facilities, not only PIK ones)
    + (
        SELECT count(*)
        FROM t
        CROSS JOIN LATERAL dbo.fn_gross_flow(t.d) AS a
        INNER JOIN dbo.cash_flow AS cf ON a.transaction_id = cf.transaction_id
        LEFT JOIN dbo.fx_rate AS fx ON cf.currency = fx.currency AND fx.rate_date = dbo.fn_month_end(cf.transaction_date)
        WHERE
            a.amount_eur IS NULL
            OR abs(a.amount_eur) <> cf.amount * coalesce(
                fx.eur_per_unit,
                (
                    SELECT r.eur_per_unit
                    FROM dbo.fx_rate AS r
                    WHERE r.currency = cf.currency
                    ORDER BY r.rate_date
                    LIMIT 1
                )
            )
    )
    + (
        CASE WHEN NOT EXISTS (
            SELECT 1
            FROM t
            CROSS JOIN LATERAL dbo.fn_gross_flow(t.d) AS a
            WHERE a.flow_date < (SELECT min(r.rate_date) FROM dbo.fx_rate AS r) AND a.amount_eur IS NOT NULL
        ) THEN 1 ELSE 0 END
    )
    -- sign convention: drawdowns negative, everything else positive
    + (
        SELECT count(*)
        FROM g
        WHERE
            (g.transaction_type = 'Drawdown' AND g.amount_eur > 0)
            OR (g.transaction_type <> 'Drawdown' AND g.amount_eur < 0)
    );
