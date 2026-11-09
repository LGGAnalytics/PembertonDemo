-- AC6 (spec 004): after `make incremental` with data/raw/delta/credit_ratings.csv, the rows
-- flagged rating_changed_in_run are exactly the facility-months of the affected borrowers from
-- the new valid_from onwards, and they carry the delta rating.
WITH delta AS (
    SELECT upper(dbo.fn_clean_text(borrower_id))                          AS borrower_id,
           dbo.fn_conform(agency, ARRAY['S&P', 'Moody''s', 'Committee'])  AS agency,
           upper(dbo.fn_clean_text(rating))                               AS rating,
           dbo.fn_try_date(valid_from)                                    AS valid_from
    FROM staging.credit_ratings WHERE _source_file = 'delta/credit_ratings.csv'
), expected AS (
    SELECT fm.facility_id, fm.as_of_date, d.agency, d.rating,
           upper(CASE d.agency WHEN 'S&P' THEN fm.rating_sp WHEN 'Moody''s' THEN fm.rating_moodys ELSE fm.rating_committee END) AS stamped
    FROM dbo.facility_month fm JOIN delta d ON d.borrower_id = fm.borrower_id AND fm.as_of_date >= d.valid_from
)
SELECT (SELECT CASE WHEN count(*) = 0 THEN 1 ELSE 0 END FROM delta)
     + (SELECT CASE WHEN count(*) = 0 THEN 1 ELSE 0 END FROM expected)
     -- every affected row is flagged and carries the delta rating
     + (SELECT count(*) FROM expected e JOIN dbo.facility_month fm USING (facility_id, as_of_date)
         WHERE NOT fm.rating_changed_in_run OR e.stamped IS DISTINCT FROM e.rating)
     -- no other row is flagged
     + (SELECT count(*) FROM dbo.facility_month fm
         WHERE fm.rating_changed_in_run
           AND NOT EXISTS (SELECT 1 FROM expected e WHERE e.facility_id = fm.facility_id AND e.as_of_date = fm.as_of_date));
