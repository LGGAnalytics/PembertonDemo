-- AC2 (spec 004): no two dbo.credit_rating rows of one borrower x agency overlap, and every
-- overlap present in the (de-duplicated, valid) staged history produced an 'overlap closed' row.
WITH staged AS (
    SELECT DISTINCT ON (b, ag, vf) b, ag, vf, vt, up
    FROM (SELECT _row_id,
                 upper(dbo.fn_clean_text(borrower_id))                          AS b,
                 dbo.fn_conform(agency, ARRAY['S&P', 'Moody''s', 'Committee'])  AS ag,
                 dbo.fn_try_date(valid_from)                                    AS vf,
                 dbo.fn_try_date(valid_to)                                      AS vt,
                 dbo.fn_try_date(updated_at)                                    AS up
          FROM staging.credit_ratings) s
    WHERE ag IS NOT NULL AND vf IS NOT NULL AND (vt IS NULL OR vt > vf)
      AND EXISTS (SELECT 1 FROM dbo.borrower x WHERE x.borrower_id = s.b)
    ORDER BY b, ag, vf, _row_id DESC
), seeded AS (
    SELECT b, ag, vf FROM (
        SELECT b, ag, vf, vt, up, lead(vf) OVER w AS next_vf, lead(up) OVER w AS next_up
        FROM staged WINDOW w AS (PARTITION BY b, ag ORDER BY vf, up)) z
    WHERE next_vf IS NOT NULL AND (vt IS NULL OR vt > next_vf) AND next_up >= up
)
SELECT (SELECT count(*) FROM dbo.credit_rating a JOIN dbo.credit_rating c
          ON c.borrower_id = a.borrower_id AND c.agency = a.agency AND c.valid_from > a.valid_from
         WHERE a.valid_to IS NULL OR a.valid_to > c.valid_from)
     + (SELECT CASE WHEN count(*) = 0 THEN 1 ELSE 0 END FROM seeded)
     + (SELECT count(*) FROM seeded s
         WHERE NOT EXISTS (SELECT 1 FROM dbo.etl_reject r
                            WHERE r.source_table = 'staging.credit_ratings' AND r.reason = 'overlap closed'
                              AND r.business_key = s.b || '/' || s.ag || '@' || s.vf));
