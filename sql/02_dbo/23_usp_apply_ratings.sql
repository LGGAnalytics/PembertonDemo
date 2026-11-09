-- =============================================================================
-- dbo.usp_apply_ratings : stamps ONE period of dbo.facility_month with the
-- ratings in force on as_of_date (spec 004). Last step of the period loop.
--
-- Mirrors the client's Asset_Rating_* update from view_CREDIT_Rating:
--   * validity join   : valid_from <= as_of_date AND (valid_to IS NULL OR as_of_date < valid_to)
--                       (client: AsOfDate BETWEEN ValidFromDate AND COALESCE(ValidToDate, today))
--   * change-only     : rows are updated only when a rating actually changed
--                       (client: ISNULL(new,'1') <> ISNULL(old,'1'); here IS DISTINCT FROM)
--   * rows_loaded     : number of rows actually changed (0 on a re-run with no news)
-- The client's 24-hour audit window does not live here: usp_discover_periods
-- decides WHICH periods are rebuilt; the stamp always uses the full history.
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_apply_ratings(p_run_id UUID, p_as_of_date DATE)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT := 0;
BEGIN
    SELECT count(*) INTO v_read FROM dbo.facility_month WHERE as_of_date = p_as_of_date;

    -- stage 1: ratings in force on the period date, pivoted to one row per borrower
    DROP TABLE IF EXISTS tmp_rating_pit;
    CREATE TEMP TABLE tmp_rating_pit AS
    SELECT  r.borrower_id,
            max(r.rating) FILTER (WHERE r.agency = 'S&P')       AS rating_sp,
            max(r.rating) FILTER (WHERE r.agency = 'Moody''s')  AS rating_moodys,
            max(r.rating) FILTER (WHERE r.agency = 'Committee') AS rating_committee,
            max(sc.score)                                       AS rating_score        -- worst of the available agencies
    FROM dbo.credit_rating r
    JOIN dbo.ref_rating_scale sc ON sc.agency = r.agency AND sc.rating = r.rating
    WHERE r.valid_from <= p_as_of_date                                               -- client: AsOfDate BETWEEN ValidFrom
      AND (r.valid_to IS NULL OR p_as_of_date < r.valid_to)                          --         AND COALESCE(ValidTo, today)
    GROUP BY r.borrower_id;

    -- stage 2: change-only update
    UPDATE dbo.facility_month fm
       SET rating_sp             = p.rating_sp,
           rating_moodys         = p.rating_moodys,
           rating_committee      = p.rating_committee,
           rating_score          = p.rating_score,
           rating_changed_in_run = TRUE
      FROM (SELECT fm2.facility_id, pit.rating_sp, pit.rating_moodys, pit.rating_committee, pit.rating_score
              FROM dbo.facility_month fm2
              LEFT JOIN tmp_rating_pit pit ON pit.borrower_id = fm2.borrower_id
             WHERE fm2.as_of_date = p_as_of_date) p
     WHERE fm.facility_id = p.facility_id
       AND fm.as_of_date  = p_as_of_date
       AND (fm.rating_sp, fm.rating_moodys, fm.rating_committee, fm.rating_score)
           IS DISTINCT FROM (p.rating_sp, p.rating_moodys, p.rating_committee, p.rating_score);
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    DROP TABLE IF EXISTS tmp_rating_pit;
    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_apply_ratings', v_start, v_read, v_loaded, v_rej, p_as_of_date);
END $$;
