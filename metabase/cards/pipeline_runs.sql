-- ETL run history: last 20 runs, newest first (audit header)
SELECT started_at     AS "Started",
       mode           AS "Mode",
       status         AS "Status",
       periods        AS "Periods",
       duration_s     AS "Seconds",
       rows_rejected  AS "Rejected",
       message        AS "Message"
FROM bi.vw_etl_run_history
ORDER BY started_at DESC
