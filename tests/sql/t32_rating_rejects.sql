-- AC3 (spec 004): the seeded unknown agency (Fitch), unknown borrower (B9999) and inverted
-- interval (B0004 Committee from 2025-06-17) are rejected with their reasons and absent from dbo.
SELECT 3 - (SELECT count(*) FROM (VALUES
               ('B0003/?@2025-01-15',           'unknown agency'),
               ('B9999/Committee@2025-01-15',   'unknown borrower'),
               ('B0004/Committee@2025-06-17',   'invalid interval')) e(k, reason)
             WHERE EXISTS (SELECT 1 FROM dbo.etl_reject r
                            WHERE r.source_table = 'staging.credit_ratings'
                              AND r.business_key = e.k AND r.reason LIKE '%' || e.reason || '%'))
     + (SELECT count(*) FROM dbo.credit_rating
         WHERE borrower_id = 'B9999'
            OR (borrower_id = 'B0004' AND agency = 'Committee' AND valid_from = DATE '2025-06-17'));
