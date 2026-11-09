-- Spec 005 section 2 (AC3b): carry, hurdle and NAV on rolled-back fixtures at T = 2026-01-01.
-- All funds: carry 10 %, European waterfall with full catch-up; one facility drawn 100 on
-- 2025-01-01, LP call 100 the same day. Expected values computed independently (Python bisection).
--   TST-2 (hurdle 6 %):  LP distribution 10 on 2025-07-02, fair value 115 -> pre-carry IRR 26.24 %
--                        hurdle value H = 106 - 10 x 1.06^(183/365) = 95.70; FV - H = 19.30
--                        carry = min(10 % x (10 + 115 - 100), 19.30) = 2.50, NAV 112.50, net 23.6218 %
--   TST-3 (hurdle 15 %): fair value 110 -> pre-carry IRR 10 % < 15 %: carry 0, NAV 110, net 10 %
--   TST-4 (hurdle 6 %):  fair value 106.5 -> catch-up zone: H = 106, carry = min(0.65, 0.50) = 0.50,
--                        NAV 106, net IRR exactly the 6 % hurdle
-- Plus, on the pipeline data: nav_eur = fair_value_eur - accrued_carry_eur on every FUND row, and no
-- FUND row accrues carry while its net IRR is below the hurdle.
BEGIN;
INSERT INTO dbo.fund (fund_code, fund_name, vintage_year, strategy, fund_size_eur, base_currency)
VALUES
('TST-2', 'Test fund above hurdle', 2098, 'Test', 1000, 'EUR'),
('TST-3', 'Test fund below hurdle', 2097, 'Test', 1000, 'EUR'),
('TST-4', 'Test fund in catch-up', 2096, 'Test', 1000, 'EUR');
INSERT INTO dbo.fund_terms (
    fund_code, mgmt_fee_pct, fee_basis, fee_frequency, expense_pct, carry_pct, hurdle_pct, catch_up_pct
)
VALUES
('TST-2', 1, 'INVESTED', 'Q', 0.1, 10, 6, 100),
('TST-3', 1, 'INVESTED', 'Q', 0.1, 10, 15, 100),
('TST-4', 1, 'INVESTED', 'Q', 0.1, 10, 6, 100);
INSERT INTO dbo.facility (
    facility_id, borrower_id, fund_code, instrument_type, currency, commitment_amount,
    spread_bps, floor_bps, origination_date, maturity_date, tenor_years
)
VALUES
('FTST4', 'B0001', 'TST-2', 'Senior Secured Term Loan', 'EUR', 100, 0, 0, '2025-01-01', '2030-01-01', 5),
('FTST5', 'B0001', 'TST-3', 'Senior Secured Term Loan', 'EUR', 100, 0, 0, '2025-01-01', '2030-01-01', 5),
('FTST6', 'B0001', 'TST-4', 'Senior Secured Term Loan', 'EUR', 100, 0, 0, '2025-01-01', '2030-01-01', 5);
INSERT INTO dbo.cash_flow (transaction_id, facility_id, transaction_date, transaction_type, amount, currency)
VALUES
('TTST5', 'FTST4', '2025-01-01', 'Drawdown', 100, 'EUR'),
('TTST6', 'FTST5', '2025-01-01', 'Drawdown', 100, 'EUR'),
('TTST7', 'FTST6', '2025-01-01', 'Drawdown', 100, 'EUR');
INSERT INTO dbo.fund_cash_flow (flow_id, fund_code, flow_date, flow_type, amount, currency)
VALUES
('FFTST1', 'TST-2', '2025-01-01', 'lp_call', 100, 'EUR'),
('FFTST2', 'TST-3', '2025-01-01', 'lp_call', 100, 'EUR'),
('FFTST3', 'TST-2', '2025-07-02', 'lp_distribution', 10, 'EUR'),
('FFTST4', 'TST-4', '2025-01-01', 'lp_call', 100, 'EUR');
INSERT INTO dbo.facility_month (
    facility_id, as_of_date, fund_code, borrower_id, currency, commitment_local, outstanding_local,
    undrawn_local, fair_value_local, fair_value_price, fair_value_eur, spread_bps, days_past_due,
    is_non_accrual, risk_status, etl_run_id
)
VALUES
(
    'FTST4', '2026-01-01', 'TST-2', 'B0001', 'EUR', 100, 100, 0, 115, 115, 115, 0, 0, FALSE, 'Performing',
    gen_random_uuid()
),
(
    'FTST5', '2026-01-01', 'TST-3', 'B0001', 'EUR', 100, 100, 0, 110, 110, 110, 0, 0, FALSE, 'Performing',
    gen_random_uuid()
),
(
    'FTST6', '2026-01-01', 'TST-4', 'B0001', 'EUR', 100, 100, 0, 106.5, 106.5, 106.5, 0, 0, FALSE, 'Performing',
    gen_random_uuid()
);
CALL dbo.usp_build_fund_performance('00000000-0000-0000-0000-00000000a045', '2026-01-01');

WITH expected AS (
    SELECT
        e.fund_code,
        e.distributed,
        e.carry,
        e.nav,
        e.net_irr
    FROM (VALUES
        ('TST-2', 10.00, 2.50, 112.50, 0.236218),
        ('TST-3', 0.00, 0.00, 110.00, 0.10),
        ('TST-4', 0.00, 0.50, 106.00, 0.06)
    ) AS e (fund_code, distributed, carry, nav, net_irr)
)

SELECT
    (
        SELECT count(*)
        FROM expected AS x
        WHERE NOT EXISTS (
            SELECT 1
            FROM dbo.fund_performance AS fp
            WHERE
                fp.as_of_date = DATE '2026-01-01'
                AND fp.level = 'FUND'
                AND fp.entity_key = x.fund_code
                AND fp.lp_called_eur = 100
                AND fp.lp_distributed_eur = x.distributed
                AND fp.accrued_carry_eur = x.carry
                AND fp.nav_eur = x.nav
                AND abs(fp.net_irr - x.net_irr) <= 0.0001
        )
    )
    + (
        SELECT count(*)
        FROM dbo.fund_performance AS fp
        WHERE
            fp.level = 'FUND'
            AND fp.as_of_date <> DATE '2026-01-01'
            AND fp.nav_eur IS DISTINCT FROM fp.fair_value_eur - fp.accrued_carry_eur
    )
    + (
        SELECT count(*)
        FROM dbo.fund_performance AS fp
        INNER JOIN dbo.fund_terms AS ft ON fp.fund_code = ft.fund_code
        WHERE
            fp.level = 'FUND'
            AND fp.accrued_carry_eur > 0
            AND fp.net_irr < ft.hurdle_pct / 100 - 0.000001
    );
ROLLBACK;
