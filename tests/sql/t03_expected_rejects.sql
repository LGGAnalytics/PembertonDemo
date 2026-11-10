-- The deliberately bad source rows are rejected:
--   * facilities F99901 (invalid date/amount) and F99902 (orphan borrower)
--   * spec 005 AC5: fund_terms XX-9 (unknown fund), fund_cash_flows unknown fund and negative amount,
--     each with its reason and absent from dbo
WITH latest AS (
    SELECT r.run_id
    FROM dbo.etl_run AS r
    ORDER BY r.started_at DESC
    LIMIT 1
),

expected AS (
    SELECT
        e.src,
        e.fund,
        e.reason
    FROM (VALUES
        ('staging.fund_terms', 'XX-9', 'unknown fund'),
        ('staging.fund_cash_flows', 'XX-9', 'unknown fund'),
        ('staging.fund_cash_flows', 'EDL-IV', 'negative amount')
    ) AS e (src, fund, reason)
)

SELECT
    (2 - (
        SELECT count(DISTINCT j.business_key)
        FROM dbo.etl_reject AS j
        WHERE j.source_table = 'staging.facilities' AND j.business_key IN ('F99901', 'F99902')
    ))
    + (
        SELECT count(*)
        FROM expected AS x
        WHERE NOT EXISTS (
            SELECT 1
            FROM dbo.etl_reject AS j
            INNER JOIN latest AS l ON j.run_id = l.run_id
            WHERE
                j.source_table = x.src
                AND j.raw_record ->> 'fund_code' = x.fund
                AND j.reason LIKE '%' || x.reason || '%'
        )
    )
    + (
        SELECT count(*)
        FROM dbo.fund_terms AS t
        WHERE t.fund_code = 'XX-9'
    )
    + (
        SELECT count(*)
        FROM dbo.fund_cash_flow AS c
        WHERE c.fund_code = 'XX-9'
    )
    -- exactly the 3 planted rows, nothing else, rejected from the two spec 005 extracts
    + abs(3 - (
        SELECT count(*)
        FROM dbo.etl_reject AS j
        INNER JOIN latest AS l ON j.run_id = l.run_id
        WHERE j.source_table IN ('staging.fund_terms', 'staging.fund_cash_flows')
    ));
