-- =============================================================================
-- LAYER 1 - STAGING
-- Landing zone for the original source extracts, loaded AS-IS.
--   * every business column is TEXT: nothing is parsed or rejected here
--   * _row_id / _source_file / _loaded_at give lineage back to the file
--   * no keys, no constraints: duplicates and bad rows are kept for the ETL
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS staging;
COMMENT ON SCHEMA staging IS 'Layer 1: raw source extracts loaded as-is (all TEXT).';

CREATE TABLE staging.funds (
    fund_code          TEXT,
    fund_name          TEXT,
    vintage_year       TEXT,
    strategy           TEXT,
    fund_size_eur      TEXT,
    base_currency      TEXT,
    _row_id            BIGINT GENERATED ALWAYS AS IDENTITY,
    _source_file       TEXT        NOT NULL DEFAULT 'funds.csv',
    _loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE staging.borrowers (
    borrower_id        TEXT,
    borrower_name      TEXT,
    sector             TEXT,
    country            TEXT,
    pe_sponsor         TEXT,
    founded_year       TEXT,
    _row_id            BIGINT GENERATED ALWAYS AS IDENTITY,
    _source_file       TEXT        NOT NULL DEFAULT 'borrowers.csv',
    _loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE staging.facilities (
    facility_id        TEXT,
    borrower_id        TEXT,
    fund_code          TEXT,
    instrument_type    TEXT,
    currency           TEXT,
    commitment_amount  TEXT,
    base_rate          TEXT,
    spread_bps         TEXT,
    floor_bps          TEXT,
    oid_price          TEXT,
    origination_date   TEXT,
    maturity_date      TEXT,
    _row_id            BIGINT GENERATED ALWAYS AS IDENTITY,
    _source_file       TEXT        NOT NULL DEFAULT 'facilities.csv',
    _loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE staging.loan_marks (
    facility_id            TEXT,
    as_of_date             TEXT,
    outstanding_principal  TEXT,
    fair_value_price       TEXT,
    internal_rating        TEXT,
    days_past_due          TEXT,
    non_accrual_flag       TEXT,
    _row_id                BIGINT GENERATED ALWAYS AS IDENTITY,
    _source_file           TEXT        NOT NULL DEFAULT 'loan_marks.csv',
    _loaded_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE staging.cash_flows (
    transaction_id     TEXT,
    facility_id        TEXT,
    transaction_date   TEXT,
    transaction_type   TEXT,
    amount             TEXT,
    currency           TEXT,
    price              TEXT,
    _row_id            BIGINT GENERATED ALWAYS AS IDENTITY,
    _source_file       TEXT        NOT NULL DEFAULT 'cash_flows.csv',
    _loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE staging.borrower_financials (
    borrower_id            TEXT,
    period_end_date        TEXT,
    revenue_ltm            TEXT,
    ebitda_ltm             TEXT,
    total_debt             TEXT,
    cash_and_equivalents   TEXT,
    interest_expense_ltm   TEXT,
    reporting_currency     TEXT,
    _row_id                BIGINT GENERATED ALWAYS AS IDENTITY,
    _source_file           TEXT        NOT NULL DEFAULT 'borrower_financials.csv',
    _loaded_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE staging.fx_rates (
    rate_date          TEXT,
    currency           TEXT,
    eur_per_unit       TEXT,
    _row_id            BIGINT GENERATED ALWAYS AS IDENTITY,
    _source_file       TEXT        NOT NULL DEFAULT 'fx_rates.csv',
    _loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE staging.reference_rates (
    rate_date          TEXT,
    rate_name          TEXT,
    rate_pct           TEXT,
    _row_id            BIGINT GENERATED ALWAYS AS IDENTITY,
    _source_file       TEXT        NOT NULL DEFAULT 'reference_rates.csv',
    _loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- spec 004: effective-dated external ratings (one row per borrower x agency x interval)
CREATE TABLE staging.credit_ratings (
    borrower_id        TEXT,
    agency             TEXT,
    rating             TEXT,
    valid_from         TEXT,
    valid_to           TEXT,
    updated_at         TEXT,
    _row_id            BIGINT GENERATED ALWAYS AS IDENTITY,
    _source_file       TEXT        NOT NULL DEFAULT 'credit_ratings.csv',
    _loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- spec 005: fund terms (one row per fund) and fund-level cash flows (fees, expenses, LP calls/distributions)
CREATE TABLE staging.fund_terms (
    fund_code          TEXT,
    mgmt_fee_pct       TEXT,
    fee_basis          TEXT,
    fee_frequency      TEXT,
    expense_pct        TEXT,
    carry_pct          TEXT,
    hurdle_pct         TEXT,
    catch_up_pct       TEXT,
    _row_id            BIGINT GENERATED ALWAYS AS IDENTITY,
    _source_file       TEXT        NOT NULL DEFAULT 'fund_terms.csv',
    _loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE staging.fund_cash_flows (
    flow_id            TEXT,
    fund_code          TEXT,
    flow_date          TEXT,
    flow_type          TEXT,
    amount             TEXT,
    currency           TEXT,
    _row_id            BIGINT GENERATED ALWAYS AS IDENTITY,
    _source_file       TEXT        NOT NULL DEFAULT 'fund_cash_flows.csv',
    _loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
