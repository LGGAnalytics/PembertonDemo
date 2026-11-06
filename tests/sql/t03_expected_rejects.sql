-- The two deliberately bad source rows (F99901 invalid date/amount, F99902 orphan borrower) are rejected
SELECT 2 - count(DISTINCT business_key) FROM dbo.etl_reject
WHERE source_table = 'staging.facilities' AND business_key IN ('F99901','F99902');
