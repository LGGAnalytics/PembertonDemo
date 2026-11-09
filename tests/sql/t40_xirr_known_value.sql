-- AC1 (spec 005), function part: dbo.fn_xirr on known flows.
--   * -100 at t0, +105 one year (365 days) later            -> 5.00 % +/- 0.0001
--   * the AC1 facility: -100 drawdown, +5 interest and 100 fair value at t0 + 1y -> 5.00 %
--   * two-period case with a known root: -1000, +600 (1y), +600 (2y) -> 13.0662 %
--   * flows that never change sign -> NULL with reason 'xirr: no sign change' (AC4, function part)
--   * bisection path: -100 then +1 after 1y -> -99.00 % (Newton from 10 % jumps below -1)
--   * no root in [-0.9999, 10]: -1 then +1e6 after 1 day -> NULL, 'xirr: no convergence'
--   * a NULL amount -> NULL, 'xirr: invalid input' (not a silent -99.99 %)
WITH cases AS (
    SELECT
        c.label,
        c.expected,
        c.reason_expected,
        dbo.fn_xirr(c.dates, c.amounts) AS irr,
        dbo.fn_xirr_reason(c.dates, c.amounts) AS reason
    FROM (VALUES
        ('simple', 0.05, ARRAY[DATE '2025-01-01', DATE '2026-01-01'], ARRAY[-100, 105]::NUMERIC [], NULL),
        (
            'ac1_facility', 0.05,
            ARRAY[DATE '2025-01-01', DATE '2026-01-01', DATE '2026-01-01'], ARRAY[-100, 5, 100]::NUMERIC [], NULL
        ),
        (
            'two_period', 0.130662,
            ARRAY[DATE '2025-01-01', DATE '2026-01-01', DATE '2027-01-01'], ARRAY[-1000, 600, 600]::NUMERIC [], NULL
        ),
        ('bisection', -0.99, ARRAY[DATE '2025-01-01', DATE '2026-01-01'], ARRAY[-100, 1]::NUMERIC [], NULL),
        ('no_sign_change', NULL, ARRAY[DATE '2025-01-01', DATE '2026-01-01'], ARRAY[-100, -5]::NUMERIC [], 'xirr: no sign change'),
        ('no_root', NULL, ARRAY[DATE '2025-01-01', DATE '2025-01-02'], ARRAY[-1, 1000000]::NUMERIC [], 'xirr: no convergence'),
        (
            'null_amount', NULL,
            ARRAY[DATE '2025-01-01', DATE '2025-06-01', DATE '2026-01-01'], ARRAY[-100, NULL, 105]::NUMERIC [], 'xirr: invalid input'
        )
    ) AS c (label, expected, dates, amounts, reason_expected)
)

SELECT count(*)
FROM cases AS x
WHERE
    (x.expected IS NOT NULL AND (x.irr IS NULL OR abs(x.irr - x.expected) > 0.0001 OR x.reason IS NOT NULL))
    OR (x.expected IS NULL AND (x.irr IS NOT NULL OR x.reason IS DISTINCT FROM x.reason_expected));
