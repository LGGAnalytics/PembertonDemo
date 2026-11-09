-- Last ETL run: one row per procedure per period (status, counts, duration, error text)
SELECT as_of_date     AS "Period",
       procedure_name AS "Procedure",
       status         AS "Status",
       rows_read      AS "Read",
       rows_loaded    AS "Loaded",
       rows_rejected  AS "Rejected",
       duration_s     AS "Seconds",
       message        AS "Message"
FROM bi.vw_etl_run_summary
ORDER BY as_of_date DESC NULLS LAST, finished_at DESC
