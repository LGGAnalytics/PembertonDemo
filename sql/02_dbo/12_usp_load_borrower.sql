-- =============================================================================
-- dbo.usp_load_borrower : staging.borrowers -> dbo.borrower
--   * sector conformed to dbo.ref_sector (case / whitespace insensitive)
--   * country given as ISO-2, ISO-3 or name -> ISO-2 via dbo.ref_country
--   * exact duplicates removed (latest staged row wins)
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_load_borrower(p_run_id UUID)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT;
        v_sectors TEXT[] := ARRAY(SELECT sector_name FROM dbo.ref_sector);
BEGIN
    SELECT count(*) INTO v_read FROM staging.borrowers;

    DROP TABLE IF EXISTS tmp_borrower;
    CREATE TEMP TABLE tmp_borrower AS
    SELECT DISTINCT ON (upper(dbo.fn_clean_text(s.borrower_id)))
           s._row_id,
           upper(dbo.fn_clean_text(s.borrower_id))     AS borrower_id,
           dbo.fn_clean_text(s.borrower_name)          AS borrower_name,
           dbo.fn_conform(s.sector, v_sectors)         AS sector_name,
           dbo.fn_country_code(s.country)              AS country_code,
           dbo.fn_clean_text(s.pe_sponsor)             AS pe_sponsor,
           dbo.fn_try_numeric(s.founded_year)::SMALLINT AS founded_year,
           to_jsonb(s) AS raw_record
    FROM staging.borrowers s
    ORDER BY upper(dbo.fn_clean_text(s.borrower_id)), s._row_id DESC;

    INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
    SELECT p_run_id, 'staging.borrowers', _row_id, borrower_id,
           concat_ws('; ',
               CASE WHEN borrower_id   IS NULL THEN 'missing borrower_id' END,
               CASE WHEN borrower_name IS NULL THEN 'missing name' END,
               CASE WHEN sector_name   IS NULL THEN 'unknown sector' END,
               CASE WHEN country_code  IS NULL THEN 'unknown country' END),
           raw_record
    FROM tmp_borrower
    WHERE borrower_id IS NULL OR borrower_name IS NULL OR sector_name IS NULL OR country_code IS NULL;
    GET DIAGNOSTICS v_rej = ROW_COUNT;

    TRUNCATE dbo.borrower CASCADE;
    INSERT INTO dbo.borrower (borrower_id, borrower_name, sector_name, country_code, pe_sponsor, is_sponsored, founded_year)
    SELECT borrower_id, borrower_name, sector_name, country_code, pe_sponsor, pe_sponsor IS NOT NULL, founded_year
    FROM tmp_borrower
    WHERE borrower_id IS NOT NULL AND borrower_name IS NOT NULL AND sector_name IS NOT NULL AND country_code IS NOT NULL;
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_load_borrower', v_start, v_read, v_loaded, v_rej);
END $$;
