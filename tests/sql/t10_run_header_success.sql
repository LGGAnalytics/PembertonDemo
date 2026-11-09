-- AC1 (spec 002): the latest run header is closed as Success with every planned period done
SELECT 1 - count(*)
FROM dbo.etl_run
WHERE run_id = (SELECT run_id FROM dbo.etl_run ORDER BY started_at DESC LIMIT 1)
  AND status = 'Success'
  AND periods_done = periods_planned
  AND finished_at IS NOT NULL;
