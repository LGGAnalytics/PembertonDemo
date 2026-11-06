-- =============================================================================
-- LAYER 2 - DBO : parsing helpers used by the ETL procedures.
-- Each returns NULL instead of raising, so procedures can route bad values to
-- dbo.etl_reject rather than failing the whole run.
-- =============================================================================

-- Trim, collapse inner whitespace, empty string -> NULL
CREATE OR REPLACE FUNCTION dbo.fn_clean_text(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT NULLIF(regexp_replace(btrim(p), '\s+', ' ', 'g'), '')
$$;

-- Accepts YYYY-MM-DD, DD/MM/YYYY and YYYYMMDD; invalid dates (e.g. 30-Feb) -> NULL
CREATE OR REPLACE FUNCTION dbo.fn_try_date(p TEXT)
RETURNS DATE LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v TEXT := btrim(p);
BEGIN
    IF v ~ '^\d{4}-\d{2}-\d{2}$' THEN RETURN to_date(v, 'YYYY-MM-DD');
    ELSIF v ~ '^\d{2}/\d{2}/\d{4}$' THEN RETURN to_date(v, 'DD/MM/YYYY');
    ELSIF v ~ '^\d{8}$' THEN RETURN to_date(v, 'YYYYMMDD');
    END IF;
    RETURN NULL;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

-- Strips thousands separators; non-numeric -> NULL
CREATE OR REPLACE FUNCTION dbo.fn_try_numeric(p TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v TEXT := replace(btrim(p), ',', '');
BEGIN
    IF v ~ '^-?\d+(\.\d+)?$' THEN RETURN v::NUMERIC; END IF;
    RETURN NULL;
END $$;

-- Matches a free-text value case-insensitively against a canonical list
CREATE OR REPLACE FUNCTION dbo.fn_conform(p TEXT, canonical TEXT[])
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT c FROM unnest(canonical) c WHERE lower(c) = lower(dbo.fn_clean_text(p)) LIMIT 1
$$;

-- Country given as ISO-2, ISO-3 or full name -> ISO-2
CREATE OR REPLACE FUNCTION dbo.fn_country_code(p TEXT)
RETURNS CHAR(2) LANGUAGE sql STABLE AS $$
    SELECT country_code FROM dbo.ref_country
    WHERE upper(dbo.fn_clean_text(p)) IN (country_code, iso3_code, upper(country_name))
    LIMIT 1
$$;
