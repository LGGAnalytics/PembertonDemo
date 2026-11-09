-- AC1 (spec 005): dbo.fn_xirr on known flows, and the AC1 facility through the procedure.
--   * -100 at t0, +105 one year (365 days) later            -> 5.00 % +/- 0.0001
--   * the AC1 facility: -100 drawdown, +5 interest and 100 fair value at t0 + 1y -> 5.00 %
--   * two-period case with a known root: -1000, +600 (1y), +600 (2y) -> 13.0662 %
--   * flows that never change sign -> NULL with reason 'xirr: no sign change' (AC4, function part)
--   * bisection path: -100 then +1 after 1y -> -99.00 % (Newton from 10 % jumps below -1)
--   * no root in [-0.9999, 10]: -1 then +1e6 after 1 day -> NULL, 'xirr: out of range'
--   * a NULL amount -> NULL, 'xirr: invalid input' (not a silent -99.99 %)
--   * AC1 through dbo.usp_build_fund_performance on a rolled-back fixture: facility FTST1
--     -> gross_irr 5.00 % +/- 0.01 pp, moic 1.05, drawn 100, returned 5, fair value 100

-- Fixture (rolled back at the end): fund TST-1 with one facility, evaluated by the real
-- procedure at T = 2026-01-01.
--   FTST1 : -100 drawdown at t0 = 2025-01-01, +5 interest at t0 + 1y, fair value 100 at T
BEGIN;
INSERT INTO dbo.fund (fund_code, fund_name, vintage_year, strategy, fund_size_eur, base_currency)
VALUES ('TST-1', 'Test fund', 2099, 'Test', 1000, 'EUR');
INSERT INTO dbo.facility (
    facility_id, borrower_id, fund_code, instrument_type, currency, commitment_amount,
    spread_bps, floor_bps, origination_date, maturity_date, tenor_years
)
VALUES
('FTST1', 'B0001', 'TST-1', 'Senior Secured Term Loan', 'EUR', 100, 0, 0, '2025-01-01', '2030-01-01', 5);
INSERT INTO dbo.cash_flow (transaction_id, facility_id, transaction_date, transaction_type, amount, currency)
VALUES
('TTST1', 'FTST1', '2025-01-01', 'Drawdown', 100, 'EUR'),
('TTST2', 'FTST1', '2026-01-01', 'Interest', 5, 'EUR');
INSERT INTO dbo.facility_month (
    facility_id, as_of_date, fund_code, borrower_id, currency, commitment_local, outstanding_local,
    undrawn_local, fair_value_local, fair_value_price, fair_value_eur, spread_bps, days_past_due,
    is_non_accrual, risk_status, etl_run_id
)
VALUES (
    'FTST1', '2026-01-01', 'TST-1', 'B0001', 'EUR', 100, 100, 0, 100, 100, 100, 0, 0, FALSE, 'Performing',
    gen_random_uuid()
);
CALL dbo.usp_build_fund_performance('00000000-0000-0000-0000-00000000a005', '2026-01-01');

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
        ('no_root', NULL, ARRAY[DATE '2025-01-01', DATE '2025-01-02'], ARRAY[-1, 1000000]::NUMERIC [], 'xirr: out of range'),
        (
            'null_amount', NULL,
            ARRAY[DATE '2025-01-01', DATE '2025-06-01', DATE '2026-01-01'], ARRAY[-100, NULL, 105]::NUMERIC [], 'xirr: invalid input'
        )
    ) AS c (label, expected, dates, amounts, reason_expected)
)

SELECT
    (
        SELECT count(*)
        FROM cases AS x
        WHERE
            (x.expected IS NOT NULL AND (x.irr IS NULL OR abs(x.irr - x.expected) > 0.0001 OR x.reason IS NOT NULL))
            OR (x.expected IS NULL AND (x.irr IS NOT NULL OR x.reason IS DISTINCT FROM x.reason_expected))
    )
    + abs(1 - (
        SELECT count(*)
        FROM dbo.fund_performance AS fp
        WHERE
            fp.as_of_date = DATE '2026-01-01' AND fp.level = 'FACILITY' AND fp.entity_key = 'FTST1'
            AND abs(fp.gross_irr - 0.05) <= 0.0001
            AND fp.moic = 1.05
            AND fp.drawn_eur = 100 AND fp.returned_eur = 5 AND fp.fair_value_eur = 100
    ));
ROLLBACK;
