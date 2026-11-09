-- AC6 (spec 002): after a successful run the watermark equals max(_loaded_at) of every staging table
SELECT count(*)
FROM (
    SELECT 'staging.loan_marks' AS t, max(_loaded_at) AS m FROM staging.loan_marks          UNION ALL
    SELECT 'staging.cash_flows',      max(_loaded_at)      FROM staging.cash_flows          UNION ALL
    SELECT 'staging.fx_rates',        max(_loaded_at)      FROM staging.fx_rates            UNION ALL
    SELECT 'staging.reference_rates', max(_loaded_at)      FROM staging.reference_rates     UNION ALL
    SELECT 'staging.facilities',      max(_loaded_at)      FROM staging.facilities          UNION ALL
    SELECT 'staging.borrowers',       max(_loaded_at)      FROM staging.borrowers           UNION ALL
    SELECT 'staging.funds',           max(_loaded_at)      FROM staging.funds               UNION ALL
    SELECT 'staging.borrower_financials', max(_loaded_at)  FROM staging.borrower_financials) x
LEFT JOIN dbo.etl_watermark w ON w.source_table = x.t
WHERE w.high_water_loaded_at IS DISTINCT FROM x.m;
