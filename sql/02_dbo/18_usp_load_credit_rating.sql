-- =============================================================================
-- dbo.usp_load_credit_rating : staging.credit_ratings -> dbo.credit_rating (spec 004)
--   * dates in mixed formats parsed; agency conformed to S&P / Moody's / Committee;
--     rating conformed case-insensitively against that agency's scale
--   * rejects: unknown borrower, unknown agency, rating not in scale,
--     invalid valid_from, invalid interval (valid_to <= valid_from)
--   * exact duplicates: last staged row wins (DISTINCT ON), as in the other loads
--   * overlapping intervals of one borrower x agency are CLOSED, not dropped: the
--     later-updated row wins the overlapping days and a DQ row 'overlap closed'
--     is written (the client's view_CREDIT_Rating does this upstream)
--   * dimension-like history: TRUNCATE + INSERT, before the period loop
--   * resets facility_month.rating_changed_in_run so the flag describes THIS run
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_load_credit_rating(p_run_id UUID)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT; v_dq INT;
BEGIN
    SELECT count(*) INTO v_read FROM staging.credit_ratings;

    DROP TABLE IF EXISTS tmp_credit_rating;
    CREATE TEMP TABLE tmp_credit_rating AS
    SELECT d.*,
           (SELECT sc.rating FROM dbo.ref_rating_scale sc
             WHERE sc.agency = d.agency AND upper(sc.rating) = upper(d.rating_raw)) AS rating,
           NULL::TEXT AS dq_note
    FROM (
        SELECT DISTINCT ON (upper(dbo.fn_clean_text(s.borrower_id)),
                            dbo.fn_conform(s.agency, ARRAY['S&P', 'Moody''s', 'Committee']),
                            dbo.fn_try_date(s.valid_from))
               s._row_id,
               upper(dbo.fn_clean_text(s.borrower_id))                          AS borrower_id,
               dbo.fn_conform(s.agency, ARRAY['S&P', 'Moody''s', 'Committee'])  AS agency,
               dbo.fn_clean_text(s.rating)                                      AS rating_raw,
               dbo.fn_try_date(s.valid_from)                                    AS valid_from,
               dbo.fn_try_date(s.valid_to)                                      AS valid_to,
               dbo.fn_clean_text(s.valid_to)                                    AS valid_to_raw,
               coalesce(dbo.fn_try_date(s.updated_at), dbo.fn_try_date(s.valid_from)) AS updated_at,
               to_jsonb(s) AS raw_record
        FROM staging.credit_ratings s
        ORDER BY upper(dbo.fn_clean_text(s.borrower_id)),
                 dbo.fn_conform(s.agency, ARRAY['S&P', 'Moody''s', 'Committee']),
                 dbo.fn_try_date(s.valid_from), s._row_id DESC
    ) d;

    ALTER TABLE tmp_credit_rating ADD COLUMN reject_reason TEXT;
    UPDATE tmp_credit_rating d
       SET reject_reason = concat_ws('; ',
               CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.borrower b WHERE b.borrower_id = d.borrower_id) THEN 'unknown borrower' END,
               CASE WHEN d.agency IS NULL THEN 'unknown agency' END,
               CASE WHEN d.agency IS NOT NULL AND d.rating IS NULL THEN 'rating not in scale' END,
               CASE WHEN d.valid_from IS NULL THEN 'invalid valid_from' END,
               CASE WHEN d.valid_to_raw IS NOT NULL AND d.valid_to IS NULL THEN 'invalid valid_to' END,
               CASE WHEN d.valid_to <= d.valid_from THEN 'invalid interval' END);

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
    SELECT p_run_id, 'staging.credit_ratings', _row_id,
           borrower_id || '/' || coalesce(agency, '?') || '@' || coalesce(valid_from::TEXT, '?'), reject_reason, raw_record
    FROM tmp_credit_rating WHERE reject_reason <> '';
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    -- close overlaps: the later-updated row wins the overlapping days
    WITH ordered AS (
        SELECT c._row_id,
               c.valid_to,
               c.updated_at,
               lead(c.valid_from) OVER w AS next_from,
               lead(c.updated_at) OVER w AS next_updated
        FROM tmp_credit_rating c
        WHERE c.reject_reason = ''
        WINDOW w AS (PARTITION BY c.borrower_id, c.agency ORDER BY c.valid_from, c.updated_at)
    )
    UPDATE tmp_credit_rating t
       SET valid_to = o.next_from,
           dq_note  = 'overlap closed'
      FROM ordered o
     WHERE t._row_id = o._row_id
       AND o.next_from IS NOT NULL
       AND (o.valid_to IS NULL OR o.valid_to > o.next_from)
       AND o.next_updated >= o.updated_at;                       -- the newer row wins

    -- an overlap the rule cannot settle (the EARLIER row is the newer one) is rejected
    WITH ordered AS (
        SELECT c._row_id, c.valid_to, lead(c.valid_from) OVER w AS next_from
        FROM tmp_credit_rating c
        WHERE c.reject_reason = ''
        WINDOW w AS (PARTITION BY c.borrower_id, c.agency ORDER BY c.valid_from, c.updated_at)
    )
    UPDATE tmp_credit_rating t
       SET reject_reason = 'unresolved overlap'
      FROM ordered o
     WHERE t._row_id = o._row_id
       AND o.next_from IS NOT NULL
       AND (o.valid_to IS NULL OR o.valid_to > o.next_from);

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
    SELECT p_run_id, 'staging.credit_ratings', _row_id,
           borrower_id || '/' || agency || '@' || valid_from, coalesce(dq_note, reject_reason), raw_record
    FROM tmp_credit_rating
    WHERE dq_note IS NOT NULL OR reject_reason = 'unresolved overlap';
    GET DIAGNOSTICS v_dq = ROW_COUNT;

    TRUNCATE dbo.credit_rating;
    INSERT INTO dbo.credit_rating (borrower_id, agency, rating, valid_from, valid_to, updated_at, etl_run_id)
    SELECT borrower_id, agency, rating, valid_from, valid_to, updated_at, p_run_id
    FROM tmp_credit_rating WHERE reject_reason = '';
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    -- the change flag describes the latest run only (periods this run does not rebuild are not "changed")
    UPDATE dbo.facility_month SET rating_changed_in_run = FALSE WHERE rating_changed_in_run;

    DROP TABLE IF EXISTS tmp_credit_rating;
    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_load_credit_rating', v_start, v_read, v_loaded, v_rej + v_dq);
END $$;
