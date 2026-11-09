-- AC2 (spec 002): one log row per (procedure, period) for the latest run; the number of
-- logged periods equals periods_planned; rows converted by usp_apply_fx_rates equal the fact rows of those periods
WITH r AS (SELECT run_id, periods_planned FROM dbo.etl_run ORDER BY started_at DESC LIMIT 1),
     l AS (SELECT * FROM dbo.etl_run_log WHERE run_id = (SELECT run_id FROM r) AND as_of_date IS NOT NULL)
SELECT (SELECT count(*) FROM (SELECT procedure_name, as_of_date FROM l GROUP BY 1, 2 HAVING count(*) > 1) d)
     + abs((SELECT count(DISTINCT as_of_date) FROM l) - (SELECT periods_planned FROM r))
     + abs((SELECT coalesce(sum(rows_loaded), 0) FROM l WHERE procedure_name = 'dbo.usp_apply_fx_rates')
           - (SELECT count(*) FROM dbo.facility_month WHERE as_of_date IN (SELECT DISTINCT as_of_date FROM l)));
