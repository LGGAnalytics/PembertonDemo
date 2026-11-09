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

-- Prices (spec 003): like fn_try_numeric, but a single decimal comma with no dot
-- ('98,75') is read as a decimal point. Blank -> NULL.
CREATE OR REPLACE FUNCTION dbo.fn_try_price(p TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v TEXT := btrim(p);
BEGIN
    IF v ~ '^-?\d+,\d{1,4}$' THEN RETURN replace(v, ',', '.')::NUMERIC; END IF;
    RETURN dbo.fn_try_numeric(v);
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

-- Last day of the month containing d
CREATE OR REPLACE FUNCTION dbo.fn_month_end(d DATE)
RETURNS DATE LANGUAGE sql IMMUTABLE AS $$
    SELECT (date_trunc('month', d) + INTERVAL '1 month - 1 day')::DATE
$$;

-- Every month-end from the month of d up to and including p_last (period expansion:
-- a late transaction or rating change affects its month and every later month)
CREATE OR REPLACE FUNCTION dbo.fn_month_ends_from(d DATE, p_last DATE)
RETURNS SETOF DATE LANGUAGE sql IMMUTABLE AS $$
    SELECT dbo.fn_month_end(g::DATE)
    FROM generate_series(date_trunc('month', d), date_trunc('month', p_last), INTERVAL '1 month') g
    WHERE d IS NOT NULL AND p_last IS NOT NULL
$$;

-- Integer setting from dbo.etl_config, with a default when missing or NULL
CREATE OR REPLACE FUNCTION dbo.fn_config_int(p_key TEXT, p_default INT)
RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT config_value::INT FROM dbo.etl_config WHERE config_key = p_key), p_default)
$$;

-- Date setting from dbo.etl_config (NULL when missing or NULL)
CREATE OR REPLACE FUNCTION dbo.fn_config_date(p_key TEXT)
RETURNS DATE LANGUAGE sql STABLE AS $$
    SELECT dbo.fn_try_date(config_value) FROM dbo.etl_config WHERE config_key = p_key
$$;

-- Spec 005: annualised internal rate of return of dated cash flows (Excel XIRR, Act/365).
-- Solves sum(a_i / (1 + r) ^ ((d_i - d_0) / 365)) = 0, d_0 = earliest date.
-- Newton-Raphson from 10 % (stops when the step < 1e-10); if it leaves (-1, 10] or stalls,
-- bisection on [-0.9999, 10] (stops when the bracket < 1e-12).
-- NULL when an input is NULL or the arrays differ in length, when the flows never change sign,
-- when no root is found in 100 iterations, or on a floating-point overflow (never raises).
CREATE OR REPLACE FUNCTION dbo.fn_xirr(p_dates DATE [], p_amounts NUMERIC [])
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_n    INT := coalesce(array_length(p_amounts, 1), 0);
    v_t    DOUBLE PRECISION[];
    v_a    DOUBLE PRECISION[];
    v_d0   DATE;
    v_r    DOUBLE PRECISION := 0.10;
    v_lo   DOUBLE PRECISION := -0.9999;
    v_hi   DOUBLE PRECISION := 10.0;
    v_f    DOUBLE PRECISION;
    v_df   DOUBLE PRECISION;
    v_flo  DOUBLE PRECISION;
    v_step DOUBLE PRECISION;
    i      INT;
    k      INT;
BEGIN
    IF v_n < 2 OR v_n <> coalesce(array_length(p_dates, 1), 0)
       OR array_position(p_amounts, NULL) IS NOT NULL OR array_position(p_dates, NULL) IS NOT NULL THEN
        RETURN NULL;                                   -- invalid input
    END IF;
    IF NOT (0 < ANY (p_amounts) AND 0 > ANY (p_amounts)) THEN
        RETURN NULL;                                   -- no sign change: no IRR
    END IF;
    SELECT min(d) INTO v_d0 FROM unnest(p_dates) d;
    FOR i IN 1..v_n LOOP
        v_t[i] := (p_dates[i] - v_d0) / 365.0;
        v_a[i] := p_amounts[i];
    END LOOP;

    -- Newton-Raphson
    FOR k IN 1..100 LOOP
        v_f := 0; v_df := 0;
        FOR i IN 1..v_n LOOP
            v_f  := v_f  + v_a[i] * power(1 + v_r, -v_t[i]);
            v_df := v_df - v_t[i] * v_a[i] * power(1 + v_r, -v_t[i] - 1);
        END LOOP;
        EXIT WHEN v_df = 0;
        v_step := v_f / v_df;
        v_r := v_r - v_step;
        EXIT WHEN v_r <= -1 OR v_r > 10;
        IF abs(v_step) < 1e-10 THEN
            RETURN round(v_r::NUMERIC, 10);
        END IF;
    END LOOP;

    -- bisection fallback: needs a sign change of f between the bounds
    v_flo := 0; v_f := 0;
    FOR i IN 1..v_n LOOP
        v_flo := v_flo + v_a[i] * power(1 + v_lo, -v_t[i]);
        v_f   := v_f   + v_a[i] * power(1 + v_hi, -v_t[i]);
    END LOOP;
    IF sign(v_flo) = sign(v_f) THEN
        RETURN NULL;                                   -- no root in range: no convergence
    END IF;
    FOR k IN 1..100 LOOP
        v_r := (v_lo + v_hi) / 2;
        v_f := 0;
        FOR i IN 1..v_n LOOP
            v_f := v_f + v_a[i] * power(1 + v_r, -v_t[i]);
        END LOOP;
        IF sign(v_f) = sign(v_flo) THEN v_lo := v_r; v_flo := v_f; ELSE v_hi := v_r; END IF;
        IF v_hi - v_lo < 1e-12 THEN
            RETURN round(v_r::NUMERIC, 10);
        END IF;
    END LOOP;
    RETURN NULL;
EXCEPTION WHEN numeric_value_out_of_range OR floating_point_exception THEN
    RETURN NULL;                                       -- overflow near r = -1: treat as no convergence
END $$;

-- Spec 005: why dbo.fn_xirr returns NULL for these flows (reject reason), NULL when it solves.
-- Solves again: callers should ask for the reason only when dbo.fn_xirr is NULL.
CREATE OR REPLACE FUNCTION dbo.fn_xirr_reason(p_dates DATE [], p_amounts NUMERIC [])
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN coalesce(array_length(p_amounts, 1), 0) < 2
             OR coalesce(array_length(p_amounts, 1), 0) <> coalesce(array_length(p_dates, 1), 0)
             OR array_position(p_amounts, NULL) IS NOT NULL
             OR array_position(p_dates, NULL) IS NOT NULL THEN 'xirr: invalid input'
        WHEN NOT coalesce(0 < ANY (p_amounts) AND 0 > ANY (p_amounts), FALSE) THEN 'xirr: no sign change'
        WHEN dbo.fn_xirr(p_dates, p_amounts) IS NULL THEN 'xirr: no convergence'
    END
$$;
