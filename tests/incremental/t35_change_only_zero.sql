-- AC5 (spec 004): a second run with NO rating changes updates nothing: usp_apply_ratings logs
-- rows_loaded = 0 for every period and no row is flagged rating_changed_in_run.
-- Re-runs the full ETL on unchanged staging (so it runs after t34, which needs the flags).
CALL dbo.usp_run_etl();
WITH latest AS (SELECT run_id, periods_planned FROM dbo.etl_run ORDER BY started_at DESC LIMIT 1)
SELECT (SELECT count(*) FROM latest WHERE periods_planned < 1)
     + (SELECT abs((SELECT periods_planned FROM latest) - count(*)) FROM dbo.etl_run_log
         WHERE run_id = (SELECT run_id FROM latest) AND procedure_name = 'dbo.usp_apply_ratings')
     + (SELECT count(*) FROM dbo.etl_run_log
         WHERE run_id = (SELECT run_id FROM latest) AND procedure_name = 'dbo.usp_apply_ratings' AND rows_loaded <> 0)
     + (SELECT count(*) FROM dbo.facility_month WHERE rating_changed_in_run);
