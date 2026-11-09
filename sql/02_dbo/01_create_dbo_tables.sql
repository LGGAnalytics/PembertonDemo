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
-- One row per CALL dbo.usp_run_etl(): opened as 'Processing' before any load,
-- closed as 'Success' or 'Error' (mirrors the client's ETL audit header).
CREATE TABLE dbo.etl_run (
    run_id           UUID        PRIMARY KEY,
    source           TEXT        NOT NULL,
    triggered_by     TEXT        NOT NULL,
    mode             TEXT        NOT NULL CHECK (mode IN ('full','incremental')),
    status           TEXT        NOT NULL CHECK (status IN ('Processing','Success','Error')),
    message          TEXT,
    periods_planned  INTEGER,
    periods_done     INTEGER     NOT NULL DEFAULT 0,
    started_at       TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    finished_at      TIMESTAMPTZ
);
COMMENT ON TABLE  dbo.etl_run                 IS 'Run header: one row per ETL run, Processing -> Success | Error.';
COMMENT ON COLUMN dbo.etl_run.mode            IS 'full = every period in the data; incremental = periods changed since the watermark.';
COMMENT ON COLUMN dbo.etl_run.periods_planned IS 'Number of month-end periods discovered for this run.';
COMMENT ON COLUMN dbo.etl_run.periods_done    IS 'Periods committed so far; equals periods_planned on Success.';
COMMENT ON COLUMN dbo.etl_run.message         IS 'Error text (SQLERRM [SQLSTATE]) when status = Error.';

-- One log row per procedure PER PERIOD (as_of_date NULL for dimension loads).
CREATE TABLE dbo.etl_run_log (
    log_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          UUID        NOT NULL,
    procedure_name  TEXT        NOT NULL,
    as_of_date      DATE,
    started_at      TIMESTAMPTZ NOT NULL,
    finished_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    rows_read       INTEGER,
    rows_loaded     INTEGER,
    rows_rejected   INTEGER,
    status          TEXT        NOT NULL DEFAULT 'SUCCESS' CHECK (status IN ('SUCCESS','ERROR')),
    message         TEXT
);
CREATE INDEX etl_run_log_run_idx ON dbo.etl_run_log (run_id, as_of_date);
COMMENT ON COLUMN dbo.etl_run_log.as_of_date IS 'Period processed by this step; NULL for non-periodised (dimension) loads.';
COMMENT ON COLUMN dbo.etl_run_log.message    IS 'Error text when status = ERROR.';

CREATE TABLE dbo.etl_reject (
    reject_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          UUID        NOT NULL,
    source_table    TEXT        NOT NULL,
    source_row_id   BIGINT,
    business_key    TEXT,
    as_of_date      DATE,
    reason          TEXT        NOT NULL,
    raw_record      JSONB,
    rejected_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
COMMENT ON COLUMN dbo.etl_reject.as_of_date IS 'Period the rejected row belongs to, when known.';

-- High-water mark per staging table: max(_loaded_at) seen by the last SUCCESSFUL run.
-- Incremental runs rebuild only the periods whose source rows arrived after it (minus an overlap).
CREATE TABLE dbo.etl_watermark (
    source_table          TEXT        PRIMARY KEY,
    high_water_loaded_at  TIMESTAMPTZ NOT NULL,
    updated_by_run        UUID
);
COMMENT ON TABLE dbo.etl_watermark IS 'Incremental-load watermark per staging table; advanced only when a run ends in Success.';

-- Key/value runtime configuration for the ETL (lookback, overlap, test hooks).
CREATE TABLE dbo.etl_config (
    config_key    TEXT PRIMARY KEY,
    config_value  TEXT,
    description   TEXT NOT NULL
);
COMMENT ON TABLE dbo.etl_config IS 'ETL runtime parameters. fail_on_period is a TEST HOOK and must be NULL in normal operation.';

-- ---------------------------------------------------------------- master data
-- Dimensions are reloaded with DELETE + INSERT inside one transaction. Foreign keys
-- that point at them are DEFERRABLE so the reload is checked at COMMIT, not per
-- statement, and periodised facts survive an incremental run untouched.
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
    borrower_id        TEXT          NOT NULL REFERENCES dbo.borrower DEFERRABLE INITIALLY DEFERRED,
    fund_code          TEXT          NOT NULL REFERENCES dbo.fund     DEFERRABLE INITIALLY DEFERRED,
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
-- Periodised: rebuilt per as_of_date (DELETE + INSERT) inside the period loop.
CREATE TABLE dbo.loan_mark (
    facility_id            TEXT          NOT NULL REFERENCES dbo.facility DEFERRABLE INITIALLY DEFERRED,
    as_of_date             DATE          NOT NULL,
    outstanding_principal  NUMERIC(18,2) NOT NULL,
    fair_value_price       NUMERIC(9,3)  NOT NULL,
    internal_rating        SMALLINT      CHECK (internal_rating BETWEEN 1 AND 5),
    days_past_due          INTEGER       NOT NULL DEFAULT 0,
    is_non_accrual         BOOLEAN       NOT NULL,
    etl_run_id             UUID          NOT NULL,
    loaded_at              TIMESTAMPTZ   NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (facility_id, as_of_date)
);
CREATE INDEX loan_mark_period_idx ON dbo.loan_mark (as_of_date);
COMMENT ON COLUMN dbo.loan_mark.etl_run_id IS 'Run that last (re)built this period (lineage).';

CREATE TABLE dbo.cash_flow (
    transaction_id     TEXT PRIMARY KEY,
    facility_id        TEXT          NOT NULL REFERENCES dbo.facility DEFERRABLE INITIALLY DEFERRED,
    transaction_date   DATE          NOT NULL,
    transaction_type   TEXT          NOT NULL CHECK (transaction_type IN ('Drawdown','Repayment','Interest','Fee')),
    amount             NUMERIC(18,2) NOT NULL,
    currency           CHAR(3)       NOT NULL
);

CREATE TABLE dbo.borrower_financials (
    borrower_id            TEXT          NOT NULL REFERENCES dbo.borrower DEFERRABLE INITIALLY DEFERRED,
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
-- One row per facility per month-end. Periodised: rebuilt per as_of_date.
-- Written in two steps inside the period loop, like the client's Position table:
--   1. usp_build_facility_month inserts local-currency measures (fx NULL)
--   2. usp_apply_fx_rates converts to EUR; rows still without FX are removed and rejected
-- so after the period's COMMIT every *_eur column is populated.
CREATE TABLE dbo.facility_month (
    facility_id            TEXT          NOT NULL REFERENCES dbo.facility DEFERRABLE INITIALLY DEFERRED,
    as_of_date             DATE          NOT NULL,
    fund_code              TEXT          NOT NULL,
    borrower_id            TEXT          NOT NULL,
    currency               CHAR(3)       NOT NULL,
    commitment_local       NUMERIC(18,2) NOT NULL,
    outstanding_local      NUMERIC(18,2) NOT NULL,
    undrawn_local          NUMERIC(18,2) NOT NULL,
    fair_value_local       NUMERIC(18,2) NOT NULL,
    fx_eur_per_unit        NUMERIC(12,6),
    commitment_eur         NUMERIC(18,2),
    outstanding_eur        NUMERIC(18,2),
    undrawn_eur            NUMERIC(18,2),
    fair_value_price       NUMERIC(9,3)  NOT NULL,
    fair_value_eur         NUMERIC(18,2),
    spread_bps             INTEGER       NOT NULL,
    base_rate_pct          NUMERIC(8,4)  NOT NULL,
    all_in_rate_pct        NUMERIC(8,4)  NOT NULL,
    internal_rating        SMALLINT,
    days_past_due          INTEGER       NOT NULL,
    is_non_accrual         BOOLEAN       NOT NULL,
    risk_status            TEXT          NOT NULL
        CHECK (risk_status IN ('Performing','Watchlist','Impaired','Non-accrual')),
    etl_run_id             UUID          NOT NULL,
    loaded_at              TIMESTAMPTZ   NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (facility_id, as_of_date)
);
CREATE INDEX facility_month_period_idx ON dbo.facility_month (as_of_date);
COMMENT ON COLUMN dbo.facility_month.commitment_local  IS 'Commitment in facility currency.';
COMMENT ON COLUMN dbo.facility_month.outstanding_local IS 'Outstanding principal in facility currency.';
COMMENT ON COLUMN dbo.facility_month.undrawn_local     IS 'max(commitment - outstanding, 0) in facility currency.';
COMMENT ON COLUMN dbo.facility_month.fair_value_local  IS 'outstanding x fair_value_price / 100 in facility currency.';
COMMENT ON COLUMN dbo.facility_month.fx_eur_per_unit   IS 'Month-end EUR per unit of currency, set by usp_apply_fx_rates.';
COMMENT ON COLUMN dbo.facility_month.etl_run_id        IS 'Run that last (re)built this period (lineage).';
