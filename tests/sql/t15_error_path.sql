-- AC5 + AC6 (spec 002): a failure inside period P2 of [P1, P2, P3]
--   * raises, closes the run as Error with P2 in the message, logs an ERROR row for P2
--   * P1 (committed before the failure) carries the failed run's id
--   * P2 and P3 keep their previous run id (rolled back / never reached)
--   * the watermark does not move
-- Then the hook is cleared and [P1, P2, P3] are rebuilt so every other test sees a clean state.
-- Uses the dbo.etl_config.fail_on_period TEST HOOK. Must be the last test in tests/sql.
\set ON_ERROR_STOP off
\set QUIET on
SET client_min_messages = error;
DROP TABLE IF EXISTS t15_periods, t15_before, t15_wm, t15_result;
CREATE TEMP TABLE t15_periods AS
SELECT as_of_date, row_number() OVER (ORDER BY as_of_date DESC) AS rn
FROM (SELECT DISTINCT as_of_date FROM dbo.facility_month) d;
CREATE TEMP TABLE t15_before AS
SELECT facility_id, as_of_date, etl_run_id FROM dbo.facility_month
WHERE as_of_date IN (SELECT as_of_date FROM t15_periods WHERE rn <= 3);
CREATE TEMP TABLE t15_wm AS SELECT * FROM dbo.etl_watermark;

SELECT (SELECT as_of_date::TEXT FROM t15_periods WHERE rn = 3) AS p1,
       (SELECT as_of_date::TEXT FROM t15_periods WHERE rn = 2) AS p2,
       (SELECT as_of_date::TEXT FROM t15_periods WHERE rn = 1) AS p3,
       (SELECT run_id::TEXT FROM dbo.etl_run ORDER BY started_at DESC LIMIT 1) AS prev_run
\gset

UPDATE dbo.etl_config SET config_value = :'p2' WHERE config_key = 'fail_on_period';
-- expected to FAIL with "Injected failure for period <p2>"
CALL dbo.usp_run_etl('incremental', NULL, ARRAY[:'p1'::DATE, :'p2'::DATE, :'p3'::DATE]);

CREATE TEMP TABLE t15_result AS
WITH failed AS (SELECT * FROM dbo.etl_run ORDER BY started_at DESC LIMIT 1)
SELECT (SELECT count(*) FROM failed WHERE run_id::TEXT = :'prev_run')                                         AS no_new_run,
       (SELECT count(*) FROM failed WHERE NOT (status = 'Error' AND message LIKE '%' || :'p2' || '%'))      AS header_not_error,
       (SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.etl_run_log l, failed
                                 WHERE l.run_id = failed.run_id AND l.status = 'ERROR' AND l.as_of_date = :'p2'::DATE)
                    THEN 0 ELSE 1 END)                                                                     AS no_error_log,
       (SELECT count(*) FROM dbo.facility_month fm, failed
         WHERE fm.as_of_date = :'p1'::DATE AND fm.etl_run_id <> failed.run_id)                             AS p1_not_committed,
       (SELECT count(*) FROM dbo.facility_month fm JOIN t15_before b USING (facility_id, as_of_date)
         WHERE fm.as_of_date IN (:'p2'::DATE, :'p3'::DATE) AND fm.etl_run_id <> b.etl_run_id)             AS p2_p3_touched,
       (SELECT count(*) FROM dbo.etl_watermark w JOIN t15_wm b USING (source_table)
         WHERE w.high_water_loaded_at <> b.high_water_loaded_at)                                           AS watermark_moved;

-- restore: clear the hook and rebuild the three periods cleanly
UPDATE dbo.etl_config SET config_value = NULL WHERE config_key = 'fail_on_period';
CALL dbo.usp_run_etl('incremental', NULL, ARRAY[:'p1'::DATE, :'p2'::DATE, :'p3'::DATE]);
\set ON_ERROR_STOP on
\set QUIET off
SELECT no_new_run + header_not_error + no_error_log + p1_not_committed + p2_p3_touched + watermark_moved
     + (SELECT 1 - count(*) FROM dbo.etl_run WHERE run_id = (SELECT run_id FROM dbo.etl_run ORDER BY started_at DESC LIMIT 1) AND status = 'Success')
FROM t15_result;
