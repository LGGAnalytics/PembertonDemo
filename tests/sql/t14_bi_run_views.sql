-- AC7 (spec 002): the run views are populated and readable by bi_reader; history lists the latest run first
SET ROLE bi_reader;
SELECT (CASE WHEN (SELECT count(*) FROM bi.vw_etl_run_summary WHERE as_of_date IS NOT NULL) = 0 THEN 1 ELSE 0 END)
     + (CASE WHEN (SELECT run_id FROM bi.vw_etl_run_history LIMIT 1) IS DISTINCT FROM (SELECT run_id FROM bi.vw_etl_run_summary LIMIT 1) THEN 1 ELSE 0 END)
     + (CASE WHEN (SELECT count(DISTINCT as_of_date) FROM bi.vw_etl_run_summary WHERE as_of_date IS NOT NULL)
             <> (SELECT periods_planned FROM bi.vw_etl_run_summary LIMIT 1) THEN 1 ELSE 0 END);
RESET ROLE;
