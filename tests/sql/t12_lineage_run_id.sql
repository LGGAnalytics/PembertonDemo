-- AC3 (spec 002): every periodised row points at a Success run; after a FULL run all rows point at that run
WITH latest AS (SELECT run_id, mode FROM dbo.etl_run ORDER BY started_at DESC LIMIT 1)
SELECT (SELECT count(*) FROM dbo.facility_month fm LEFT JOIN dbo.etl_run r ON r.run_id = fm.etl_run_id WHERE r.status IS DISTINCT FROM 'Success')
     + (SELECT count(*) FROM dbo.loan_mark m      LEFT JOIN dbo.etl_run r ON r.run_id = m.etl_run_id  WHERE r.status IS DISTINCT FROM 'Success')
     + (SELECT count(*) FROM dbo.facility_month fm, latest WHERE latest.mode = 'full' AND fm.etl_run_id <> latest.run_id)
     + (SELECT count(*) FROM dbo.loan_mark m, latest      WHERE latest.mode = 'full' AND m.etl_run_id  <> latest.run_id);
