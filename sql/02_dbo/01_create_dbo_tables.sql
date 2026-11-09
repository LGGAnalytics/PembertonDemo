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
    seniority_rank   SMALLINT NOT NULL,
    price_basis      TEXT NOT NULL CHECK (price_basis IN ('PCT_OF_PAR','PER_UNIT'))
);
COMMENT ON COLUMN dbo.ref_instrument.price_basis IS 'PCT_OF_PAR: prices quoted per 100 of principal (debt). PER_UNIT: price per unit, 1 unit = 1.00 invested (equity).';

-- Spec 004: common 1 (best) .. 5 (worst) score per agency rating. A demo
-- convention, NOT an agency-published equivalence.
CREATE TABLE dbo.ref_rating_scale (
    agency   TEXT     NOT NULL,
    rating   TEXT     NOT NULL,
    score    SMALLINT NOT NULL CHECK (score BETWEEN 1 AND 5),
    rank     SMALLINT NOT NULL,
    PRIMARY KEY (agency, rating)
);
COMMENT ON TABLE  dbo.ref_rating_scale       IS 'Spec 004: maps S&P / Moody''s / Committee ratings to a common score 1 (strong) .. 5 (distressed). Demo convention.';
COMMENT ON COLUMN dbo.ref_rating_scale.rank  IS 'Notch order within the agency, 1 = best.';

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

-- spec 005: fee and carry terms per fund (dimension, TRUNCATE + INSERT)
CREATE TABLE dbo.fund_terms (
    fund_code       TEXT PRIMARY KEY REFERENCES dbo.fund DEFERRABLE INITIALLY DEFERRED,
    mgmt_fee_pct    NUMERIC(6,4) NOT NULL CHECK (mgmt_fee_pct BETWEEN 0 AND 3),
    fee_basis       TEXT         NOT NULL CHECK (fee_basis IN ('INVESTED','COMMITTED')),
    fee_frequency   CHAR(1)      NOT NULL CHECK (fee_frequency = 'Q'),
    expense_pct     NUMERIC(6,4) NOT NULL CHECK (expense_pct BETWEEN 0 AND 1),
    carry_pct       NUMERIC(6,4) NOT NULL CHECK (carry_pct BETWEEN 0 AND 30),
    hurdle_pct      NUMERIC(6,4) NOT NULL CHECK (hurdle_pct BETWEEN 0 AND 15),
    catch_up_pct    NUMERIC(7,4) NOT NULL CHECK (catch_up_pct = 100)
);
COMMENT ON COLUMN dbo.fund_terms.mgmt_fee_pct  IS 'Spec 005: management fee, % p.a. of fee_basis, charged quarterly in arrears.';
COMMENT ON COLUMN dbo.fund_terms.fee_basis     IS 'Spec 005: INVESTED (average invested cost) or COMMITTED capital.';
COMMENT ON COLUMN dbo.fund_terms.fee_frequency IS 'Spec 005: Q = quarterly in arrears (only value supported).';
COMMENT ON COLUMN dbo.fund_terms.expense_pct   IS 'Spec 005: fund expenses, % p.a., same basis and frequency as the fee.';
COMMENT ON COLUMN dbo.fund_terms.carry_pct     IS 'Spec 005: carried interest, % of LP profit (European waterfall).';
COMMENT ON COLUMN dbo.fund_terms.hurdle_pct    IS 'Spec 005: preferred return, % p.a.; carry accrues only when the LP pre-carry IRR reaches it.';
COMMENT ON COLUMN dbo.fund_terms.catch_up_pct  IS 'Spec 005: GP catch-up; only 100 (full catch-up) is modelled (decision D3).';

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
    base_rate_name     TEXT,
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
    transaction_type   TEXT          NOT NULL CHECK (transaction_type IN ('Drawdown','Repayment','Interest','Fee','PIK')),
    amount             NUMERIC(18,2) NOT NULL,
    currency           CHAR(3)       NOT NULL,
    price              NUMERIC(9,4)
);
-- spec 005: fund-level cash flows in EUR (dimension-like ledger, TRUNCATE + INSERT)
CREATE TABLE dbo.fund_cash_flow (
    flow_id     TEXT PRIMARY KEY,
    fund_code   TEXT          NOT NULL REFERENCES dbo.fund DEFERRABLE INITIALLY DEFERRED,
    flow_date   DATE          NOT NULL,
    flow_type   TEXT          NOT NULL CHECK (flow_type IN ('mgmt_fee','fund_expense','lp_call','lp_distribution')),
    amount      NUMERIC(18,2) NOT NULL CHECK (amount >= 0),
    currency    CHAR(3)       NOT NULL
);
COMMENT ON COLUMN dbo.fund_cash_flow.flow_type IS 'Spec 005: mgmt_fee / fund_expense (charged to LPs, included in lp_call), lp_call (LP pays in, negative for Net IRR), lp_distribution (LP receives, positive).';
COMMENT ON COLUMN dbo.fund_cash_flow.amount    IS 'Spec 005: always >= 0; the sign comes from flow_type.';
COMMENT ON COLUMN dbo.fund_cash_flow.currency  IS 'Spec 005: fund base currency (EUR).';
COMMENT ON COLUMN dbo.cash_flow.price IS 'Transaction price as sent (per 100 for debt, per unit for equity); NULL or 0 = not provided, normalised to par in usp_build_cost_basis.';
COMMENT ON COLUMN dbo.facility.base_rate_name IS 'Floating-rate benchmark; NULL for equity (PER_UNIT) instruments.';

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

-- Spec 004: external rating history, one row per borrower x agency x validity interval.
-- Dimension-like (not periodised): TRUNCATE + INSERT by usp_load_credit_rating.
CREATE TABLE dbo.credit_rating (
    borrower_id   TEXT        NOT NULL REFERENCES dbo.borrower DEFERRABLE INITIALLY DEFERRED,
    agency        TEXT        NOT NULL,
    rating        TEXT        NOT NULL,
    valid_from    DATE        NOT NULL,
    valid_to      DATE,
    updated_at    DATE        NOT NULL,
    etl_run_id    UUID        NOT NULL,
    loaded_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (borrower_id, agency, valid_from),
    FOREIGN KEY (agency, rating) REFERENCES dbo.ref_rating_scale (agency, rating),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);
COMMENT ON TABLE  dbo.credit_rating            IS 'Spec 004: effective-dated rating history. In force on d when valid_from <= d AND (valid_to IS NULL OR d < valid_to).';
COMMENT ON COLUMN dbo.credit_rating.valid_to   IS 'Exclusive end of validity; NULL = still in force. Overlaps are closed at load (the later-updated row wins).';
COMMENT ON COLUMN dbo.credit_rating.updated_at IS 'Date the source last updated the row; breaks ties when intervals overlap.';

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
    base_rate_pct          NUMERIC(8,4),
    all_in_rate_pct        NUMERIC(8,4),
    internal_rating        SMALLINT,
    days_past_due          INTEGER       NOT NULL,
    is_non_accrual         BOOLEAN       NOT NULL,
    risk_status            TEXT          NOT NULL
        CHECK (risk_status IN ('Performing','Watchlist','Impaired','Non-accrual')),
    -- spec 003: cost basis, set by usp_build_cost_basis
    drawn_to_date_local    NUMERIC(18,2),
    repaid_to_date_local   NUMERIC(18,2),
    pik_to_date_local      NUMERIC(18,2),
    wa_acquisition_price   NUMERIC(9,4),
    cost_basis_local       NUMERIC(18,2),
    cost_basis_eur         NUMERIC(18,2),
    unrealised_gain_eur    NUMERIC(18,2),
    realised_gain_local    NUMERIC(18,2),
    -- spec 004: ratings in force on as_of_date, set by usp_apply_ratings
    rating_sp              TEXT,
    rating_moodys          TEXT,
    rating_committee       TEXT,
    rating_score           SMALLINT,
    rating_changed_in_run  BOOLEAN       NOT NULL DEFAULT FALSE,
    etl_run_id             UUID          NOT NULL,
    loaded_at              TIMESTAMPTZ   NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (facility_id, as_of_date)
);
CREATE INDEX facility_month_period_idx ON dbo.facility_month (as_of_date);
CREATE INDEX credit_rating_lookup_idx ON dbo.credit_rating (borrower_id, agency, valid_from);
COMMENT ON COLUMN dbo.facility_month.commitment_local  IS 'Commitment in facility currency.';
COMMENT ON COLUMN dbo.facility_month.outstanding_local IS 'Outstanding principal in facility currency.';
COMMENT ON COLUMN dbo.facility_month.undrawn_local     IS 'max(commitment - outstanding, 0) in facility currency.';
COMMENT ON COLUMN dbo.facility_month.fair_value_local  IS 'outstanding x fair_value_price / 100 (PCT_OF_PAR) or outstanding x fair_value_price (PER_UNIT), facility currency.';
COMMENT ON COLUMN dbo.facility_month.base_rate_pct     IS 'Benchmark rate on as_of_date; NULL for equity (no coupon).';
COMMENT ON COLUMN dbo.facility_month.all_in_rate_pct   IS 'max(base rate, floor) + spread; NULL for equity (no coupon).';
COMMENT ON COLUMN dbo.facility_month.drawn_to_date_local  IS 'Spec 003: sum of Drawdown amounts with transaction_date <= as_of_date.';
COMMENT ON COLUMN dbo.facility_month.repaid_to_date_local IS 'Spec 003: sum of Repayment amounts <= as_of_date.';
COMMENT ON COLUMN dbo.facility_month.pik_to_date_local    IS 'Spec 003: sum of PIK (capitalised interest) amounts <= as_of_date.';
COMMENT ON COLUMN dbo.facility_month.wa_acquisition_price IS 'Spec 003: sum(drawdown x normalised price) / sum(drawdown) <= as_of_date; NULL when no drawdown.';
COMMENT ON COLUMN dbo.facility_month.cost_basis_local     IS 'Spec 003: debt (drawn - repaid) x wa / 100 + pik; equity (drawn - repaid) x wa; floored at 0; NULL without acquisition.';
COMMENT ON COLUMN dbo.facility_month.cost_basis_eur       IS 'Spec 003: cost_basis_local x fx_eur_per_unit.';
COMMENT ON COLUMN dbo.facility_month.unrealised_gain_eur  IS 'Spec 003: fair_value_eur - cost_basis_eur; NULL when cost is NULL.';
COMMENT ON COLUMN dbo.facility_month.rating_sp             IS 'Spec 004: S&P rating of the borrower in force on as_of_date.';
COMMENT ON COLUMN dbo.facility_month.rating_moodys         IS 'Spec 004: Moody''s rating in force on as_of_date.';
COMMENT ON COLUMN dbo.facility_month.rating_committee      IS 'Spec 004: internal committee grade (A-E) in force on as_of_date.';
COMMENT ON COLUMN dbo.facility_month.rating_score          IS 'Spec 004: worst (highest) score of the available agencies, 1 strong .. 5 distressed; NULL when unrated.';
COMMENT ON COLUMN dbo.facility_month.rating_changed_in_run IS 'Spec 004: TRUE when the latest run changed any of the four rating columns of this row.';
COMMENT ON COLUMN dbo.facility_month.realised_gain_local  IS 'Spec 003: sum over repayments of amount x (price - WA price before the repayment) / 100 (equity: without /100).';
COMMENT ON COLUMN dbo.facility_month.fx_eur_per_unit   IS 'Month-end EUR per unit of currency, set by usp_apply_fx_rates.';
COMMENT ON COLUMN dbo.facility_month.etl_run_id        IS 'Run that last (re)built this period (lineage).';
