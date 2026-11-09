-- AC1 (spec 004): for every facility_month row and each agency, the stamped rating equals the
-- single dbo.credit_rating row in force on as_of_date (recomputed here), or NULL when none.
-- Also fails when no row is rated at all.
WITH pit AS (
    SELECT fm.facility_id, fm.as_of_date, a.agency,
           CASE a.agency WHEN 'S&P' THEN fm.rating_sp WHEN 'Moody''s' THEN fm.rating_moodys ELSE fm.rating_committee END AS stamped,
           (SELECT r.rating FROM dbo.credit_rating r
             WHERE r.borrower_id = fm.borrower_id AND r.agency = a.agency
               AND r.valid_from <= fm.as_of_date AND (r.valid_to IS NULL OR fm.as_of_date < r.valid_to)) AS expected
    FROM dbo.facility_month fm
    CROSS JOIN (VALUES ('S&P'), ('Moody''s'), ('Committee')) a(agency)
)
SELECT (SELECT count(*) FROM pit WHERE stamped IS DISTINCT FROM expected)
     + (SELECT CASE WHEN count(*) = 0 THEN 1 ELSE 0 END FROM pit WHERE stamped IS NOT NULL);
