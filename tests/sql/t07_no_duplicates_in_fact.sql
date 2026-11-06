-- One row per facility per month in the fact (grain check)
SELECT count(*) FROM (
  SELECT facility_id, as_of_date FROM dbo.facility_month GROUP BY 1, 2 HAVING count(*) > 1) d;
