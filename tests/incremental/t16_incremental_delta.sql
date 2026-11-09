-- AC4 (spec 002): after `make incremental` with the delta (restated LAST month M):
--   * the latest run is an incremental Success that rebuilt exactly one period, M
--   * rows of M carry the new run id; rows of every other month do not
--   * the restated prices from data/raw/delta/loan_marks.csv are the ones in the fact
WITH latest AS (SELECT run_id, mode, status, periods_planned FROM dbo.etl_run ORDER BY started_at DESC LIMIT 1),
     m AS (SELECT max(as_of_date) AS d FROM dbo.facility_month),
     rebuilt AS (SELECT DISTINCT as_of_date FROM dbo.etl_run_log WHERE run_id = (SELECT run_id FROM latest) AND as_of_date IS NOT NULL)
SELECT (SELECT count(*) FROM latest WHERE NOT (mode = 'incremental' AND status = 'Success' AND periods_planned = 1))
     + (SELECT count(*) FROM rebuilt WHERE as_of_date <> (SELECT d FROM m))
     + (SELECT count(*) FROM dbo.facility_month fm, latest, m WHERE fm.as_of_date =  m.d AND fm.etl_run_id <> latest.run_id)
     + (SELECT count(*) FROM dbo.facility_month fm, latest, m WHERE fm.as_of_date <> m.d AND fm.etl_run_id =  latest.run_id)
     + (SELECT count(*) FROM dbo.loan_mark lm,      latest, m WHERE lm.as_of_date <> m.d AND lm.etl_run_id =  latest.run_id)
     + (SELECT count(*)
          FROM staging.loan_marks s
          JOIN dbo.facility_month fm ON fm.facility_id = upper(dbo.fn_clean_text(s.facility_id))
                                    AND fm.as_of_date  = dbo.fn_try_date(s.as_of_date)
         WHERE s._source_file = 'delta/loan_marks.csv'
           AND fm.fair_value_price <> dbo.fn_try_numeric(s.fair_value_price));
