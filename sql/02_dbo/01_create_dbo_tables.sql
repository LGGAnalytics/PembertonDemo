-- =============================================================================
-- LAYER 2 - DBO (treated data)
-- Typed, cleaned, de-duplicated and conformed tables. Populated ONLY by the
-- stored procedures in this schema (dbo.usp_*). Tables are created once and
-- reloaded with TRUNCATE + INSERT, so the BI views on top never break.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS dbo;
COMMENT ON SCHEMA dbo IS 'Layer 2: treated tables, loaded by the dbo.usp_* ETL procedures.';

-- ---------------------------------------------------------------- reference
CREATE TABLE dbo.ref_country (
    country_code   CHAR(2)  PRIMARY KEY,
    iso3_code      CHAR(3)  NOT NULL UNIQUE,
    country_name   TEXT     NOT NULL UNIQUE,
    region         TEXT     NOT NULL
);

CREATE TABLE dbo.ref_sector (
    sector_name    TEXT PRIMARY KEY,
    sector_group   TEXT NOT NULL
);

CREATE TABLE dbo.ref_instrument (
    instrument_type  TEXT PRIMARY KEY,
    seniority        TEXT NOT NULL,
    seniority_rank   SMALLINT NOT NULL
);

-- ---------------------------------------------------------------- audit
CREATE TABLE dbo.etl_run_log (
    log_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          UUID        NOT NULL,
    procedure_name  TEXT        NOT NULL,
    started_at      TIMESTAMPTZ NOT NULL,
    finished_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    rows_read       INTEGER,
    rows_loaded     INTEGER,
    rows_rejected   INTEGER,
    status          TEXT        NOT NULL DEFAULT 'SUCCESS'
);

CREATE TABLE dbo.etl_reject (
    reject_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          UUID        NOT NULL,
    source_table    TEXT        NOT NULL,
    source_row_id   BIGINT,
    business_key    TEXT,
    reason          TEXT        NOT NULL,
    raw_record      JSONB,
    rejected_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------- master data
CREATE TABLE dbo.fund (
    fund_code       TEXT PRIMARY KEY,
    fund_name       TEXT          NOT NULL,
    vintage_year    SMALLINT      NOT NULL,
    strategy        TEXT          NOT NULL,
    fund_size_eur   NUMERIC(18,2) NOT NULL,
    base_currency   CHAR(3)       NOT NULL
);

CREATE TABLE dbo.borrower (
    borrower_id     TEXT PRIMARY KEY,
    borrower_name   TEXT     NOT NULL,
    sector_name     TEXT     NOT NULL REFERENCES dbo.ref_sector,
    country_code    CHAR(2)  NOT NULL REFERENCES dbo.ref_country,
    pe_sponsor      TEXT,
    is_sponsored    BOOLEAN  NOT NULL,
    founded_year    SMALLINT
);

CREATE TABLE dbo.facility (
    facility_id        TEXT PRIMARY KEY,
    borrower_id        TEXT          NOT NULL REFERENCES dbo.borrower,
    fund_code          TEXT          NOT NULL REFERENCES dbo.fund,
    instrument_type    TEXT          NOT NULL REFERENCES dbo.ref_instrument,
    currency           CHAR(3)       NOT NULL,
    commitment_amount  NUMERIC(18,2) NOT NULL CHECK (commitment_amount > 0),
    base_rate_name     TEXT          NOT NULL,
    spread_bps         INTEGER       NOT NULL,
    floor_bps          INTEGER       NOT NULL DEFAULT 0,
    oid_price          NUMERIC(6,2),
    origination_date   DATE          NOT NULL,
    maturity_date      DATE          NOT NULL,
    tenor_years        NUMERIC(5,2)  NOT NULL
);

-- ---------------------------------------------------------------- transactional
CREATE TABLE dbo.loan_mark (
    facility_id            TEXT          NOT NULL REFERENCES dbo.facility,
    as_of_date             DATE          NOT NULL,
    outstanding_principal  NUMERIC(18,2) NOT NULL,
    fair_value_price       NUMERIC(9,3)  NOT NULL,
    internal_rating        SMALLINT      CHECK (internal_rating BETWEEN 1 AND 5),
    days_past_due          INTEGER       NOT NULL DEFAULT 0,
    is_non_accrual         BOOLEAN       NOT NULL,
    PRIMARY KEY (facility_id, as_of_date)
);

CREATE TABLE dbo.cash_flow (
    transaction_id     TEXT PRIMARY KEY,
    facility_id        TEXT          NOT NULL REFERENCES dbo.facility,
    transaction_date   DATE          NOT NULL,
    transaction_type   TEXT          NOT NULL CHECK (transaction_type IN ('Drawdown','Repayment','Interest','Fee')),
    amount             NUMERIC(18,2) NOT NULL,
    currency           CHAR(3)       NOT NULL
);

CREATE TABLE dbo.borrower_financials (
    borrower_id            TEXT          NOT NULL REFERENCES dbo.borrower,
    period_end_date        DATE          NOT NULL,
    revenue_ltm            NUMERIC(18,2),
    ebitda_ltm             NUMERIC(18,2),
    total_debt             NUMERIC(18,2),
    cash_and_equivalents   NUMERIC(18,2),
    interest_expense_ltm   NUMERIC(18,2),
    reporting_currency     CHAR(3)       NOT NULL,
    PRIMARY KEY (borrower_id, period_end_date)
);

CREATE TABLE dbo.fx_rate (
    rate_date      DATE          NOT NULL,
    currency       CHAR(3)       NOT NULL,
    eur_per_unit   NUMERIC(12,6) NOT NULL CHECK (eur_per_unit > 0),
    PRIMARY KEY (rate_date, currency)
);

CREATE TABLE dbo.reference_rate (
    rate_date   DATE         NOT NULL,
    rate_name   TEXT         NOT NULL,
    rate_pct    NUMERIC(8,4) NOT NULL,
    PRIMARY KEY (rate_date, rate_name)
);

-- ---------------------------------------------------------------- fact
-- One row per facility per month-end, everything converted to EUR.
CREATE TABLE dbo.facility_month (
    facility_id            TEXT          NOT NULL REFERENCES dbo.facility,
    as_of_date             DATE          NOT NULL,
    fund_code              TEXT          NOT NULL,
    borrower_id            TEXT          NOT NULL,
    currency               CHAR(3)       NOT NULL,
    fx_eur_per_unit        NUMERIC(12,6) NOT NULL,
    commitment_eur         NUMERIC(18,2) NOT NULL,
    outstanding_eur        NUMERIC(18,2) NOT NULL,
    undrawn_eur            NUMERIC(18,2) NOT NULL,
    fair_value_price       NUMERIC(9,3)  NOT NULL,
    fair_value_eur         NUMERIC(18,2) NOT NULL,
    spread_bps             INTEGER       NOT NULL,
    base_rate_pct          NUMERIC(8,4)  NOT NULL,
    all_in_rate_pct        NUMERIC(8,4)  NOT NULL,
    internal_rating        SMALLINT,
    days_past_due          INTEGER       NOT NULL,
    is_non_accrual         BOOLEAN       NOT NULL,
    risk_status            TEXT          NOT NULL
        CHECK (risk_status IN ('Performing','Watchlist','Impaired','Non-accrual')),
    PRIMARY KEY (facility_id, as_of_date)
);
