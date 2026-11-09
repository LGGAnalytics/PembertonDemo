-- =============================================================================
-- LAYER 1 - STAGING : append the DELTA extracts (incremental demo).
-- No TRUNCATE: the rows land next to the full extract with a later _loaded_at,
-- which is what dbo.usp_discover_periods compares against dbo.etl_watermark.
-- Run with psql from the repository root, after 10_load_staging.sql + a full ETL.
-- =============================================================================
\copy staging.loan_marks (facility_id, as_of_date, outstanding_principal, fair_value_price, internal_rating, days_past_due, non_accrual_flag) FROM 'data/raw/delta/loan_marks.csv' WITH (FORMAT csv, HEADER true)
UPDATE staging.loan_marks SET _source_file = 'delta/loan_marks.csv' WHERE _source_file = 'loan_marks.csv' AND _loaded_at = (SELECT max(_loaded_at) FROM staging.loan_marks);

\copy staging.cash_flows (transaction_id, facility_id, transaction_date, transaction_type, amount, currency, price) FROM 'data/raw/delta/cash_flows.csv' WITH (FORMAT csv, HEADER true)
UPDATE staging.cash_flows SET _source_file = 'delta/cash_flows.csv' WHERE _source_file = 'cash_flows.csv' AND _loaded_at = (SELECT max(_loaded_at) FROM staging.cash_flows);

\copy staging.credit_ratings (borrower_id, agency, rating, valid_from, valid_to, updated_at) FROM 'data/raw/delta/credit_ratings.csv' WITH (FORMAT csv, HEADER true)
UPDATE staging.credit_ratings SET _source_file = 'delta/credit_ratings.csv' WHERE _source_file = 'credit_ratings.csv' AND _loaded_at = (SELECT max(_loaded_at) FROM staging.credit_ratings);

SELECT _source_file, count(*) AS rows_loaded FROM staging.loan_marks GROUP BY 1
UNION ALL
SELECT _source_file, count(*) FROM staging.cash_flows GROUP BY 1
UNION ALL
SELECT _source_file, count(*) FROM staging.credit_ratings GROUP BY 1
ORDER BY 1;
