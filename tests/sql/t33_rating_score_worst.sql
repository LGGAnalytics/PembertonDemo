-- AC4 (spec 004): rating_score = greatest of the available agency scores, NULL only when all three are NULL
SELECT count(*)
FROM dbo.facility_month fm
LEFT JOIN dbo.ref_rating_scale s1 ON s1.agency = 'S&P'       AND s1.rating = fm.rating_sp
LEFT JOIN dbo.ref_rating_scale s2 ON s2.agency = 'Moody''s'  AND s2.rating = fm.rating_moodys
LEFT JOIN dbo.ref_rating_scale s3 ON s3.agency = 'Committee' AND s3.rating = fm.rating_committee
WHERE fm.rating_score IS DISTINCT FROM greatest(s1.score, s2.score, s3.score);
