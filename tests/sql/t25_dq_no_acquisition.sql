-- AC8 (spec 003): the planted facility without an acquisition cash flow is explained in
-- etl_reject ('no acquisition cash flow') and its fact rows are kept with NULL cost.
WITH dq AS (
    SELECT DISTINCT split_part(business_key, '@', 1) AS facility_id
    FROM dbo.etl_reject
    WHERE source_table = 'dbo.facility_month' AND reason = 'no acquisition cash flow'
)
SELECT (SELECT CASE WHEN count(*) = 0 THEN 1 ELSE 0 END FROM dq)
     + (SELECT count(*) FROM dq WHERE NOT EXISTS (SELECT 1 FROM dbo.facility_month fm WHERE fm.facility_id = dq.facility_id))
     + (SELECT count(*) FROM dbo.facility_month fm JOIN dq USING (facility_id)
         WHERE fm.outstanding_local > 0 AND fm.cost_basis_local IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.cash_flow c WHERE c.facility_id = fm.facility_id
                                                           AND c.transaction_type = 'Drawdown'
                                                           AND c.transaction_date <= fm.as_of_date));
