-- AC6 (spec 005):
--   * bi.vw_fund_performance matches dbo.fund_performance row for row at the latest as_of_date
--     (IRRs x 100 rounded to 2 dp, every other figure unchanged)
--   * dbo.fund_performance has a FUND row for each of the 3 funds in every period of the fact
--   * the latest run logged exactly one dbo.usp_build_fund_performance row for every period it rebuilt
WITH latest_date AS (
    SELECT max(fp.as_of_date) AS d
    FROM dbo.fund_performance AS fp
    WHERE fp.as_of_date IN (SELECT fm.as_of_date FROM dbo.facility_month AS fm)
),

latest_run AS (
    SELECT r.run_id
    FROM dbo.etl_run AS r
    ORDER BY r.started_at DESC
    LIMIT 1
),

d AS (
    SELECT
        fp.level,
        fp.entity_key,
        fp.fund_code,
        fp.vintage_year,
        fp.facility_id,
        fp.moic,
        fp.drawn_eur,
        fp.returned_eur,
        fp.fair_value_eur,
        fp.lp_called_eur,
        fp.lp_distributed_eur,
        fp.accrued_carry_eur,
        fp.nav_eur,
        round(fp.gross_irr * 100, 2) AS gross_irr_pct,
        round(fp.net_irr * 100, 2) AS net_irr_pct
    FROM dbo.fund_performance AS fp
    INNER JOIN latest_date AS l ON fp.as_of_date = l.d
),

v AS (
    SELECT
        b.level,
        b.entity_key,
        b.fund_code,
        b.vintage_year,
        b.facility_id,
        b.moic,
        b.drawn_eur,
        b.returned_eur,
        b.fair_value_eur,
        b.lp_called_eur,
        b.lp_distributed_eur,
        b.accrued_carry_eur,
        b.nav_eur,
        b.gross_irr_pct,
        b.net_irr_pct
    FROM bi.vw_fund_performance AS b
    INNER JOIN latest_date AS l ON b.as_of_date = l.d
),

logged AS (
    SELECT
        g.as_of_date,
        count(*) FILTER (WHERE g.procedure_name = 'dbo.usp_build_fund_performance') AS n
    FROM dbo.etl_run_log AS g
    INNER JOIN latest_run AS r ON g.run_id = r.run_id
    WHERE g.as_of_date IS NOT NULL
    GROUP BY g.as_of_date
)

SELECT
    (SELECT count(*) FROM (SELECT * FROM d
    EXCEPT
    SELECT * FROM v) AS missing_in_view)
    + (SELECT count(*) FROM (SELECT * FROM v
    EXCEPT
    SELECT * FROM d) AS extra_in_view)
    + (CASE WHEN (SELECT count(*) FROM d) = 0 THEN 1 ELSE 0 END)
    + (
        SELECT count(*)
        FROM (SELECT DISTINCT fm.as_of_date FROM dbo.facility_month AS fm) AS p
        WHERE (
            SELECT count(*)
            FROM dbo.fund_performance AS fp
            WHERE fp.as_of_date = p.as_of_date AND fp.level = 'FUND'
        ) <> 3
    )
    + (SELECT count(*) FROM logged AS lg
WHERE lg.n <> 1)
    + (CASE WHEN (SELECT count(*) FROM logged) = 0 THEN 1 ELSE 0 END);
