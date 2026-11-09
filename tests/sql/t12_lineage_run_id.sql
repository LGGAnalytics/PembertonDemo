-- AC3 (spec 002): every periodised row points at a Success run; after a FULL run all rows point at that run.
-- Spec 005: dbo.fund_performance follows the same lineage rule.
WITH latest AS (
    SELECT
        r.run_id,
        r.mode
    FROM dbo.etl_run AS r
    ORDER BY r.started_at DESC
    LIMIT 1
),

stamped AS (
    SELECT fm.etl_run_id FROM dbo.facility_month AS fm
    UNION ALL
    SELECT m.etl_run_id FROM dbo.loan_mark AS m
    UNION ALL
    SELECT fp.etl_run_id FROM dbo.fund_performance AS fp
)

SELECT
    (
        SELECT count(*)
        FROM stamped AS s
        LEFT JOIN dbo.etl_run AS r ON s.etl_run_id = r.run_id
        WHERE r.status IS DISTINCT FROM 'Success'
    )
    + (
        SELECT count(*)
        FROM stamped AS s
        CROSS JOIN latest AS l
        WHERE l.mode = 'full' AND s.etl_run_id <> l.run_id
    );
