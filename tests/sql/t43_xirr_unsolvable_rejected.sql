-- AC4 (spec 005): flows with no sign change give a NULL IRR, one etl_reject row with a reason,
-- and the run still succeeds.
--   * fixture (rolled back): facility FTST2 with only a -100 drawdown -> FACILITY row written with
--     gross_irr NULL and moic 0, one reject 'xirr: no sign change', and the procedure does not raise
--   * fixture reject paths (review F15): FTST3 has a fair value but no drawdown -> 'no drawdown',
--     no row; its CHF interest has no FX rate -> 'no fx rate for CHF'; fund TST-1 has no fund
--     terms -> 'no fund terms'
--   * pipeline: every FACILITY / FUND / VINTAGE row with NULL gross_irr has a reject with an 'xirr:'
--     reason from the run that built it, and the latest run is a Success
-- Fixture (rolled back at the end): fund TST-1 with three facilities, evaluated by the real
-- procedure at T = 2026-01-01.
--   FTST1 : -100 drawdown at t0 = 2025-01-01, +5 interest at t0 + 1y, fair value 100 at T
--   FTST2 : -100 drawdown at t0, nothing back, no fair value  -> no sign change
BEGIN;
INSERT INTO dbo.fund (fund_code, fund_name, vintage_year, strategy, fund_size_eur, base_currency)
VALUES ('TST-1', 'Test fund', 2099, 'Test', 1000, 'EUR');
INSERT INTO dbo.facility (
    facility_id, borrower_id, fund_code, instrument_type, currency, commitment_amount,
    spread_bps, floor_bps, origination_date, maturity_date, tenor_years
)
VALUES
('FTST1', 'B0001', 'TST-1', 'Senior Secured Term Loan', 'EUR', 100, 0, 0, '2025-01-01', '2030-01-01', 5),
('FTST2', 'B0001', 'TST-1', 'Senior Secured Term Loan', 'EUR', 100, 0, 0, '2025-01-01', '2030-01-01', 5),
('FTST3', 'B0001', 'TST-1', 'Senior Secured Term Loan', 'CHF', 100, 0, 0, '2025-01-01', '2030-01-01', 5);
INSERT INTO dbo.cash_flow (transaction_id, facility_id, transaction_date, transaction_type, amount, currency)
VALUES
('TTST1', 'FTST1', '2025-01-01', 'Drawdown', 100, 'EUR'),
('TTST2', 'FTST1', '2026-01-01', 'Interest', 5, 'EUR'),
('TTST3', 'FTST2', '2025-01-01', 'Drawdown', 100, 'EUR'),
('TTST4', 'FTST3', '2025-06-30', 'Interest', 3, 'CHF');
INSERT INTO dbo.facility_month (
    facility_id, as_of_date, fund_code, borrower_id, currency, commitment_local, outstanding_local,
    undrawn_local, fair_value_local, fair_value_price, fair_value_eur, spread_bps, days_past_due,
    is_non_accrual, risk_status, etl_run_id
)
VALUES
(
    'FTST1', '2026-01-01', 'TST-1', 'B0001', 'EUR', 100, 100, 0, 100, 100, 100, 0, 0, FALSE, 'Performing',
    gen_random_uuid()
),
(
    'FTST3', '2026-01-01', 'TST-1', 'B0001', 'CHF', 100, 50, 50, 50, 100, 50, 0, 0, FALSE, 'Performing',
    gen_random_uuid()
);
CALL dbo.usp_build_fund_performance('00000000-0000-0000-0000-00000000a005', '2026-01-01');

SELECT
    abs(1 - (
        SELECT count(*)
        FROM dbo.fund_performance AS fp
        WHERE
            fp.as_of_date = DATE '2026-01-01' AND fp.level = 'FACILITY' AND fp.entity_key = 'FTST2'
            AND fp.gross_irr IS NULL AND fp.moic = 0
    ))
    + abs(1 - (
        SELECT count(*)
        FROM dbo.etl_reject AS j
        WHERE
            j.run_id = '00000000-0000-0000-0000-00000000a005'
            AND j.business_key = 'FACILITY:FTST2@2026-01-01'
            AND j.reason = 'xirr: no sign change'
    ))
    + (
        SELECT count(*)
        FROM (VALUES
            ('FACILITY:FTST3@2026-01-01', 'no drawdown'),
            ('FLOW:TTST4@2026-01-01', 'no fx rate for CHF'),
            ('FUND:TST-1@2026-01-01', 'no fund terms')
        ) AS e (business_key, reason)
        WHERE NOT EXISTS (
            SELECT 1
            FROM dbo.etl_reject AS j
            WHERE
                j.run_id = '00000000-0000-0000-0000-00000000a005'
                AND j.business_key = e.business_key
                AND j.reason = e.reason
        )
    )
    + (
        SELECT count(*)
        FROM dbo.fund_performance AS fp
        WHERE fp.as_of_date = DATE '2026-01-01' AND fp.entity_key = 'FTST3'
    )
    + (
        SELECT count(*)
        FROM dbo.fund_performance AS fp
        WHERE
            fp.gross_irr IS NULL
            AND fp.as_of_date <> DATE '2026-01-01'
            AND NOT EXISTS (
                SELECT 1
                FROM dbo.etl_reject AS j
                WHERE
                    j.run_id = fp.etl_run_id
                    AND j.business_key = fp.level || ':' || fp.entity_key || '@' || fp.as_of_date
                    AND j.reason LIKE 'xirr:%'
            )
    )
    + (
        SELECT count(*)
        FROM (
            SELECT r.status
            FROM dbo.etl_run AS r
            ORDER BY r.started_at DESC
            LIMIT 1
        ) AS latest
        WHERE latest.status <> 'Success'
    );
ROLLBACK;
