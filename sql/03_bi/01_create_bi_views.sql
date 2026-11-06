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
       sum(fm.spread_bps * fm.outstanding_eur)                        AS spread_x_outstanding,
       sum(fm.all_in_rate_pct * fm.outstanding_eur)                   AS all_in_rate_x_outstanding,
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
       CASE e.risk_status WHEN 'Non-accrual' THEN 1 WHEN 'Impaired' THEN 2 ELSE 3 END AS severity_rank
FROM bi.vw_facility_exposure e
WHERE e.is_latest_month AND e.risk_status <> 'Performing';

-- -----------------------------------------------------------------------------
-- bi.vw_etl_run_summary : pipeline observability (last run per procedure)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW bi.vw_etl_run_summary AS
SELECT l.run_id, l.procedure_name, l.started_at, l.finished_at,
       round(extract(epoch FROM l.finished_at - l.started_at)::NUMERIC, 3) AS duration_s,
       l.rows_read, l.rows_loaded, l.rows_rejected, l.status
FROM dbo.etl_run_log l
WHERE l.run_id = (SELECT run_id FROM dbo.etl_run_log ORDER BY finished_at DESC LIMIT 1);
