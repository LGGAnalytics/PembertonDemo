-- AC7 (spec 005, amended 2026-11-09). Runs right after t16: t35 re-runs the full ETL.
-- after `make incremental` with data/raw/delta/fund_cash_flows.csv
-- (one late lp_distribution per fund, dated in the restated last month M):
--   * the latest run rebuilt dbo.fund_performance for M only: every row of M carries its run id,
--     no row of an earlier month does
--   * the 3 delta flows are in dbo.fund_cash_flow
--   * each FUND row of M has lp_distributed_eur = the distributions up to M without the delta
--     + exactly that fund's delta amount
WITH latest AS (
    SELECT r.run_id
    FROM dbo.etl_run AS r
    ORDER BY r.started_at DESC
    LIMIT 1
),

m AS (
    SELECT max(fm.as_of_date) AS d
    FROM dbo.facility_month AS fm
),

delta AS (
    SELECT
        upper(dbo.fn_clean_text(s.flow_id)) AS flow_id,
        upper(dbo.fn_clean_text(s.fund_code)) AS fund_code,
        dbo.fn_try_numeric(s.amount) AS amount
    FROM staging.fund_cash_flows AS s
    WHERE s._source_file = 'delta/fund_cash_flows.csv'
),

expected AS (
    SELECT
        c.fund_code,
        coalesce(sum(c.amount) FILTER (WHERE c.flow_id NOT IN (SELECT x.flow_id FROM delta AS x)), 0)
        + coalesce((SELECT sum(x.amount) FROM delta AS x
WHERE x.fund_code = c.fund_code), 0) AS distributed
    FROM dbo.fund_cash_flow AS c
    CROSS JOIN m
    WHERE c.flow_type = 'lp_distribution' AND c.flow_date <= m.d
    GROUP BY c.fund_code
)

SELECT
    abs(3 - (SELECT count(*) FROM delta))
    + abs(3 - (
        SELECT count(*)
        FROM dbo.fund_cash_flow AS c
        INNER JOIN delta AS x ON c.flow_id = x.flow_id AND c.amount = x.amount
    ))
    + (
        SELECT count(*)
        FROM dbo.fund_performance AS fp
        CROSS JOIN latest AS l
        CROSS JOIN m
        WHERE
            (fp.as_of_date = m.d AND fp.etl_run_id <> l.run_id)
            OR (fp.as_of_date < m.d AND fp.etl_run_id = l.run_id)
    )
    + abs(3 - (
        SELECT count(*)
        FROM dbo.fund_performance AS fp
        CROSS JOIN m
        INNER JOIN expected AS e ON fp.entity_key = e.fund_code
        WHERE fp.as_of_date = m.d AND fp.level = 'FUND' AND fp.lp_distributed_eur = e.distributed
    ));
