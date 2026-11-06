-- Last ETL run: rows read / loaded / rejected per stored procedure
SELECT procedure_name AS "Procedure",
       rows_read      AS "Read",
       rows_loaded    AS "Loaded",
       rows_rejected  AS "Rejected",
       duration_s     AS "Seconds",
       finished_at    AS "Finished at"
FROM bi.vw_etl_run_summary
ORDER BY finished_at
