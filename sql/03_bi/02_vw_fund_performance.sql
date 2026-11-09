-- =============================================================================
-- LAYER 3 - BI : bi.vw_fund_performance (spec 005)
-- Gross IRR, Net IRR and MOIC per as_of_date x level (FACILITY, FUND, VINTAGE).
-- Reads dbo.fund_performance only; every figure is calculated in dbo
-- (usp_build_fund_performance). IRRs are shown in % (x 100, 2 dp).
-- Granted to bi_reader by 99_grants.sql (all tables in schema bi).
-- =============================================================================
CREATE OR REPLACE VIEW bi.vw_fund_performance AS
SELECT
    fp.as_of_date,
    fp.level,
    fp.entity_key,
    fp.fund_code,
    fd.fund_name,
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
    round(fp.net_irr * 100, 2) AS net_irr_pct,
    (fp.as_of_date = max(fp.as_of_date) OVER ()) AS is_latest_month
FROM dbo.fund_performance AS fp
LEFT JOIN dbo.fund AS fd ON fp.fund_code = fd.fund_code;

COMMENT ON VIEW bi.vw_fund_performance IS
'Spec 005: Gross IRR %, Net IRR % and MOIC per as_of_date x level (FACILITY / FUND / VINTAGE). Net figures on FUND rows only.';
