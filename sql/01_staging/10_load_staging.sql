-- =============================================================================
-- LAYER 1 - STAGING : load the original CSV extracts as-is.
-- Run with psql from the repository root (paths are relative to it).
-- Full refresh: staging is truncated before each load.
-- =============================================================================
TRUNCATE staging.funds, staging.borrowers, staging.facilities, staging.loan_marks,
         staging.cash_flows, staging.borrower_financials, staging.fx_rates,
         staging.reference_rates, staging.credit_ratings RESTART IDENTITY;

\copy staging.funds (fund_code, fund_name, vintage_year, strategy, fund_size_eur, base_currency) FROM 'data/raw/funds.csv' WITH (FORMAT csv, HEADER true)
\copy staging.borrowers (borrower_id, borrower_name, sector, country, pe_sponsor, founded_year) FROM 'data/raw/borrowers.csv' WITH (FORMAT csv, HEADER true)
\copy staging.facilities (facility_id, borrower_id, fund_code, instrument_type, currency, commitment_amount, base_rate, spread_bps, floor_bps, oid_price, origination_date, maturity_date) FROM 'data/raw/facilities.csv' WITH (FORMAT csv, HEADER true)
\copy staging.loan_marks (facility_id, as_of_date, outstanding_principal, fair_value_price, internal_rating, days_past_due, non_accrual_flag) FROM 'data/raw/loan_marks.csv' WITH (FORMAT csv, HEADER true)
\copy staging.cash_flows (transaction_id, facility_id, transaction_date, transaction_type, amount, currency, price) FROM 'data/raw/cash_flows.csv' WITH (FORMAT csv, HEADER true)
\copy staging.borrower_financials (borrower_id, period_end_date, revenue_ltm, ebitda_ltm, total_debt, cash_and_equivalents, interest_expense_ltm, reporting_currency) FROM 'data/raw/borrower_financials.csv' WITH (FORMAT csv, HEADER true)
\copy staging.fx_rates (rate_date, currency, eur_per_unit) FROM 'data/raw/fx_rates.csv' WITH (FORMAT csv, HEADER true)
\copy staging.reference_rates (rate_date, rate_name, rate_pct) FROM 'data/raw/reference_rates.csv' WITH (FORMAT csv, HEADER true)
\copy staging.credit_ratings (borrower_id, agency, rating, valid_from, valid_to, updated_at) FROM 'data/raw/credit_ratings.csv' WITH (FORMAT csv, HEADER true)

SELECT 'staging.' || t AS table_name, n AS rows_loaded FROM (
    SELECT 'funds' t, count(*) n FROM staging.funds UNION ALL
    SELECT 'borrowers', count(*) FROM staging.borrowers UNION ALL
    SELECT 'facilities', count(*) FROM staging.facilities UNION ALL
    SELECT 'loan_marks', count(*) FROM staging.loan_marks UNION ALL
    SELECT 'cash_flows', count(*) FROM staging.cash_flows UNION ALL
    SELECT 'borrower_financials', count(*) FROM staging.borrower_financials UNION ALL
    SELECT 'fx_rates', count(*) FROM staging.fx_rates UNION ALL
    SELECT 'reference_rates', count(*) FROM staging.reference_rates UNION ALL
    SELECT 'credit_ratings', count(*) FROM staging.credit_ratings) x;
