-- Every distinct facility in staging is either loaded into dbo or logged as a reject
SELECT count(*) FROM (
  SELECT DISTINCT upper(btrim(facility_id)) AS facility_id FROM staging.facilities
  EXCEPT SELECT facility_id FROM dbo.facility
  EXCEPT SELECT business_key FROM dbo.etl_reject WHERE source_table = 'staging.facilities'
) missing;
