-- =============================================================================
-- LAYER 3 - BI (presentation views)
-- The ONLY objects Metabase can see. Each view reads from the treated dbo
-- tables and exposes business-friendly names. Every view keeps fund_code (and
-- as_of_date where relevant) so the dashboard "Fund" filter works everywhere.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS bi;
COMMENT ON SCHEMA bi IS 'Layer 3: views consumed by Metabase dashboards (read-only).';

-- -----------------------------------------------------------------------------
-- bi.vw_facility_exposure : facility x month, fully described (base view)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW bi.vw_facility_exposure AS
SELECT fm.as_of_date,
       fm.fund_code,
       fd.fund_name,
       fm.facility_id,
       fm.borrower_id,
       b.borrower_name,
       b.sector_name,
       s.sector_group,
       c.country_name,
       c.region,
       b.pe_sponsor,
       f.instrument_type,
       ri.seniority,
       ri.price_basis,
       fm.currency,
       f.origination_date,
       f.maturity_date,
       fm.commitment_eur,
       fm.outstanding_eur,
       fm.undrawn_eur,
       fm.fair_value_price,
       fm.fair_value_eur,
       fm.spread_bps,
       fm.base_rate_pct,
       fm.all_in_rate_pct,
       fm.internal_rating,
       coalesce(fm.internal_rating::TEXT, 'Not rated')       AS internal_rating_label,
       fm.days_past_due,
       fm.is_non_accrual,
       fm.risk_status,
       fm.wa_acquisition_price,
       fm.cost_basis_eur,
       fm.unrealised_gain_eur,
       fm.realised_gain_local,
       fm.rating_sp,
       fm.rating_moodys,
       fm.rating_committee,
       fm.rating_score,
       CASE WHEN fm.rating_score <= 2 THEN '1-2 Strong'
            WHEN fm.rating_score = 3  THEN '3 Adequate'
            WHEN fm.rating_score = 4  THEN '4 Weak'
            WHEN fm.rating_score = 5  THEN '5 Distressed'
            ELSE 'n/a' END                                   AS rating_band,
       fm.rating_changed_in_run,
       (fm.as_of_date = max(fm.as_of_date) OVER ())          AS is_latest_month
FROM dbo.facility_month fm
JOIN dbo.facility f        ON f.facility_id = fm.facility_id
JOIN dbo.fund fd           ON fd.fund_code = fm.fund_code
JOIN dbo.borrower b        ON b.borrower_id = fm.borrower_id
JOIN dbo.ref_sector s      ON s.sector_name = b.sector_name
JOIN dbo.ref_country c     ON c.country_code = b.country_code
JOIN dbo.ref_instrument ri ON ri.instrument_type = f.instrument_type;

-- -----------------------------------------------------------------------------
-- bi.vw_portfolio_monthly : month x fund aggregates for KPI tiles and trends.
-- Weighted averages are shipped as numerator + denominator so they can be
-- re-aggregated correctly across funds:  sum(spread_x_outstanding)/sum(outstanding_eur)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW bi.vw_portfolio_monthly AS
SELECT fm.as_of_date,
       fm.fund_code,
       count(*)                                                       AS facilities,
       count(DISTINCT fm.borrower_id)                                 AS borrowers,
       sum(fm.commitment_eur)                                         AS commitment_eur,
       sum(fm.outstanding_eur)                                        AS outstanding_eur,
       sum(fm.undrawn_eur)                                            AS undrawn_eur,
       sum(fm.fair_value_eur)                                         AS fair_value_eur,
       sum(fm.outstanding_eur) FILTER (WHERE fm.all_in_rate_pct IS NOT NULL) AS debt_outstanding_eur,   -- denominator for spread / yield (equity has no coupon)
       sum(fm.spread_bps * fm.outstanding_eur) FILTER (WHERE fm.all_in_rate_pct IS NOT NULL) AS spread_x_outstanding,
       sum(fm.all_in_rate_pct * fm.outstanding_eur)                   AS all_in_rate_x_outstanding,
       sum(fm.cost_basis_eur)                                         AS cost_basis_eur,
       sum(fm.unrealised_gain_eur)                                    AS unrealised_gain_eur,
       count(*) FILTER (WHERE fm.cost_basis_eur IS NULL)              AS facilities_without_cost,
       sum(fm.outstanding_eur) FILTER (WHERE fm.is_non_accrual)       AS non_accrual_eur,
       sum(fm.outstanding_eur) FILTER (WHERE fm.risk_status <> 'Performing') AS watchlist_eur,
       count(*) FILTER (WHERE fm.risk_status <> 'Performing')         AS watchlist_facilities
FROM dbo.facility_month fm
GROUP BY fm.as_of_date, fm.fund_code;

-- -----------------------------------------------------------------------------
-- bi.vw_cash_flow_monthly : month-end x fund x transaction type, in EUR
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW bi.vw_cash_flow_monthly AS
SELECT (date_trunc('month', cf.transaction_date) + INTERVAL '1 month - 1 day')::DATE AS month_end,
       f.fund_code,
       cf.transaction_type,
       count(*)                                    AS transactions,
       round(sum(cf.amount * fx.eur_per_unit), 2)  AS amount_eur
FROM dbo.cash_flow cf
JOIN dbo.facility f ON f.facility_id = cf.facility_id
JOIN dbo.fx_rate fx ON fx.currency = cf.currency
                   AND fx.rate_date = (date_trunc('month', cf.transaction_date) + INTERVAL '1 month - 1 day')::DATE
GROUP BY 1, 2, 3;

-- -----------------------------------------------------------------------------
-- bi.vw_watchlist : latest month, every facility not Performing
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW bi.vw_watchlist AS
SELECT e.as_of_date,
       e.fund_code,
       e.borrower_name,
       e.sector_name,
       e.country_name,
       e.instrument_type,
       e.outstanding_eur,
       e.fair_value_price,
       e.internal_rating,
       e.days_past_due,
       e.risk_status,
       e.wa_acquisition_price,
       e.unrealised_gain_eur,
       e.rating_sp,
       e.rating_moodys,
       e.rating_committee,
       e.rating_score,
       e.rating_band,
       CASE e.risk_status WHEN 'Non-accrual' THEN 1 WHEN 'Impaired' THEN 2 ELSE 3 END AS severity_rank
FROM bi.vw_facility_exposure e
WHERE e.is_latest_month AND e.risk_status <> 'Performing';

-- -----------------------------------------------------------------------------
-- bi.vw_rating_migration : facility x month against the previous month-end (spec 004).
-- One row per dbo.facility_month row, so outstanding totals reconcile to the fact;
-- is_migration flags rows whose rating changed since the previous month.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW bi.vw_rating_migration AS
SELECT fm.as_of_date,
       fm.fund_code,
       fm.facility_id,
       b.borrower_name,
       concat_ws(', ',
           CASE WHEN p.facility_id IS NOT NULL AND fm.rating_committee IS DISTINCT FROM p.rating_committee THEN 'Committee' END,
           CASE WHEN p.facility_id IS NOT NULL AND fm.rating_sp        IS DISTINCT FROM p.rating_sp        THEN 'S&P' END,
           CASE WHEN p.facility_id IS NOT NULL AND fm.rating_moodys    IS DISTINCT FROM p.rating_moodys    THEN 'Moody''s' END) AS agency_changed,
       p.rating_committee   AS committee_from,
       fm.rating_committee  AS committee_to,
       p.rating_sp          AS sp_from,
       fm.rating_sp         AS sp_to,
       p.rating_moodys      AS moodys_from,
       fm.rating_moodys     AS moodys_to,
       p.rating_score       AS score_from,
       fm.rating_score      AS score_to,
       fm.outstanding_eur,
       (p.facility_id IS NOT NULL
        AND (fm.rating_sp, fm.rating_moodys, fm.rating_committee)
            IS DISTINCT FROM (p.rating_sp, p.rating_moodys, p.rating_committee)) AS is_migration
FROM dbo.facility_month fm
JOIN dbo.borrower b ON b.borrower_id = fm.borrower_id
LEFT JOIN dbo.facility_month p ON p.facility_id = fm.facility_id
                              AND p.as_of_date  = dbo.fn_month_end((fm.as_of_date - INTERVAL '1 month')::DATE);

-- -----------------------------------------------------------------------------
-- bi.vw_etl_run_summary : pipeline observability, latest run.
-- One row per procedure PER PERIOD (as_of_date NULL for dimension loads), with
-- the run header (mode, run status, periods done/planned) repeated on each row.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW bi.vw_etl_run_summary AS
SELECT r.run_id,
       r.mode,
       r.status                                                          AS run_status,
       r.periods_done,
       r.periods_planned,
       l.procedure_name,
       l.as_of_date,
       l.status,
       l.started_at,
       l.finished_at,
       round(extract(epoch FROM l.finished_at - l.started_at)::NUMERIC, 3) AS duration_s,
       l.rows_read,
       l.rows_loaded,
       l.rows_rejected,
       l.message
FROM dbo.etl_run r
JOIN dbo.etl_run_log l ON l.run_id = r.run_id
WHERE r.run_id = (SELECT run_id FROM dbo.etl_run ORDER BY started_at DESC LIMIT 1);

-- -----------------------------------------------------------------------------
-- bi.vw_etl_run_history : the last 20 runs, newest first (run header only)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW bi.vw_etl_run_history AS
SELECT r.run_id,
       r.started_at,
       r.finished_at,
       r.mode,
       r.status,
       r.triggered_by,
       r.periods_done,
       r.periods_planned,
       coalesce(r.periods_done, 0) || '/' || coalesce(r.periods_planned::TEXT, '?') AS periods,
       round(extract(epoch FROM coalesce(r.finished_at, clock_timestamp()) - r.started_at)::NUMERIC, 1) AS duration_s,
       (SELECT sum(rows_rejected) FROM dbo.etl_run_log l WHERE l.run_id = r.run_id AND l.procedure_name <> 'dbo.usp_run_etl (total)') AS rows_rejected,
       r.message
FROM dbo.etl_run r
ORDER BY r.started_at DESC
LIMIT 20;
