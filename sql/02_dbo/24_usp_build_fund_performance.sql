-- =============================================================================
-- Spec 005: fund performance (Gross IRR, Net IRR, MOIC).
--
-- dbo.fn_gross_flow(T) : the gross cash flows of every facility up to T, in EUR,
--   signed from the fund's perspective (Drawdown < 0; Repayment, Interest, Fee > 0).
--   PIK is excluded: it is capitalised and already in the fair value.
--   FX: month-end dbo.fx_rate of the flow's month; a flow dated before the first
--   rate of its currency uses that first rate (decision D1); otherwise no rate
--   -> amount_eur NULL (the caller rejects it with 'no fx rate').
-- =============================================================================
CREATE OR REPLACE FUNCTION dbo.fn_gross_flow(p_as_of_date DATE)
RETURNS TABLE (
    transaction_id    TEXT,
    facility_id       TEXT,
    fund_code         TEXT,
    vintage_year      SMALLINT,
    flow_date         DATE,
    transaction_type  TEXT,
    currency          CHAR(3),
    amount_eur        NUMERIC
) LANGUAGE sql STABLE AS $$
    SELECT
        cf.transaction_id,
        cf.facility_id,
        f.fund_code,
        fd.vintage_year,
        cf.transaction_date,
        cf.transaction_type,
        cf.currency,
        CASE WHEN cf.transaction_type = 'Drawdown' THEN -1 ELSE 1 END
        * cf.amount
        * coalesce(
            fx.eur_per_unit,
            CASE WHEN dbo.fn_month_end(cf.transaction_date) < first_fx.rate_date THEN first_fx.eur_per_unit END
        )
    FROM dbo.cash_flow AS cf
    INNER JOIN dbo.facility AS f ON cf.facility_id = f.facility_id
    INNER JOIN dbo.fund AS fd ON f.fund_code = fd.fund_code
    LEFT JOIN dbo.fx_rate AS fx
        ON cf.currency = fx.currency AND fx.rate_date = dbo.fn_month_end(cf.transaction_date)
    LEFT JOIN LATERAL (
        SELECT
            r.rate_date,
            r.eur_per_unit
        FROM dbo.fx_rate AS r
        WHERE r.currency = cf.currency
        ORDER BY r.rate_date
        LIMIT 1
    ) AS first_fx ON TRUE
    WHERE
        cf.transaction_date <= p_as_of_date
        AND cf.transaction_type <> 'PIK'
$$;

-- =============================================================================
-- dbo.usp_build_fund_performance : rebuilds dbo.fund_performance for one period.
--   Last step of the period loop (after FX, so facility_month.fair_value_eur is set).
--   1. tmp_gross_flow   : dbo.fn_gross_flow(T); flows without a EUR rate -> reject 'no fx rate for <ccy>'
--   2. tmp_fp_facility  : drawn / returned / fair value per facility; no drawdown -> reject and
--                         excluded from every level (income without cost would inflate returns);
--                         a fund or vintage left with no facility -> reject 'no drawdown'
--   3. tmp_entity_flow  : the flows and the end value (dated T) of each FACILITY, FUND, VINTAGE
--   4. tmp_perf         : one row per entity with the XIRR arrays, gross IRR and MOIC
--   5. FUND rows        : LP flows, carry when the LP pre-carry IRR >= hurdle (European, full
--                         catch-up: min(carry_pct x profit, FV - hurdle value)), NAV = FV - carry, net IRR
--   6. unsolvable IRRs  -> reject with dbo.fn_xirr_reason; DELETE period + INSERT; log
--   Reject keys: '<level>:<entity_key>@<as_of_date>' (flows: 'FLOW:<transaction_id>@<date>');
--   net-side reasons are prefixed 'net ' / 'pre-carry '.
-- =============================================================================
CREATE OR REPLACE PROCEDURE dbo.usp_build_fund_performance(p_run_id UUID, p_as_of_date DATE)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT := 0; v_n INT;
BEGIN
    -- 1. gross flows up to T
    DROP TABLE IF EXISTS tmp_gross_flow;
    CREATE TEMP TABLE tmp_gross_flow AS SELECT * FROM dbo.fn_gross_flow(p_as_of_date);
    SELECT count(*) INTO v_read FROM tmp_gross_flow;

    INSERT INTO dbo.etl_reject (run_id, source_table, business_key, as_of_date, reason)
    SELECT p_run_id, 'dbo.cash_flow', 'FLOW:' || transaction_id || '@' || p_as_of_date, p_as_of_date,
           'no fx rate for ' || currency
    FROM tmp_gross_flow WHERE amount_eur IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_rej := v_rej + v_n;
    DELETE FROM tmp_gross_flow WHERE amount_eur IS NULL;

    -- 2. per facility: flows and/or a fair value at T
    DROP TABLE IF EXISTS tmp_fp_facility;
    CREATE TEMP TABLE tmp_fp_facility AS
    SELECT f.facility_id, f.fund_code, fd.vintage_year,
           coalesce(g.drawn, 0) AS drawn, coalesce(g.returned, 0) AS returned, coalesce(fm.fair_value_eur, 0) AS fv
    FROM dbo.facility f
    JOIN dbo.fund fd ON fd.fund_code = f.fund_code
    LEFT JOIN (SELECT facility_id,
                      -sum(amount_eur) FILTER (WHERE transaction_type = 'Drawdown') AS drawn,
                       sum(amount_eur) FILTER (WHERE transaction_type <> 'Drawdown') AS returned
               FROM tmp_gross_flow GROUP BY facility_id) g ON g.facility_id = f.facility_id
    LEFT JOIN dbo.facility_month fm ON fm.facility_id = f.facility_id AND fm.as_of_date = p_as_of_date
    WHERE g.facility_id IS NOT NULL OR fm.facility_id IS NOT NULL;

    -- facility, then any fund / vintage whose every facility has no drawdown
    INSERT INTO dbo.etl_reject (run_id, source_table, business_key, as_of_date, reason)
    SELECT p_run_id, 'dbo.fund_performance', k || '@' || p_as_of_date, p_as_of_date, 'no drawdown'
    FROM (
        SELECT 'FACILITY:' || facility_id AS k FROM tmp_fp_facility WHERE drawn <= 0
        UNION ALL
        SELECT 'FUND:' || fund_code FROM tmp_fp_facility GROUP BY fund_code HAVING max(drawn) <= 0
        UNION ALL
        SELECT 'VINTAGE:' || vintage_year FROM tmp_fp_facility GROUP BY vintage_year HAVING max(drawn) <= 0
    ) x;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_rej := v_rej + v_n;
    DELETE FROM tmp_fp_facility WHERE drawn <= 0;

    -- 3. flows + end value per entity, for the three levels
    DROP TABLE IF EXISTS tmp_entity_flow;
    CREATE TEMP TABLE tmp_entity_flow AS
    WITH flows AS (
        SELECT f.facility_id, f.fund_code, f.vintage_year, g.flow_date, g.amount_eur
        FROM tmp_fp_facility f JOIN tmp_gross_flow g ON g.facility_id = f.facility_id
        UNION ALL
        SELECT f.facility_id, f.fund_code, f.vintage_year, p_as_of_date, f.fv           -- end value at T
        FROM tmp_fp_facility f WHERE f.fv <> 0
    )
    SELECT 'FACILITY' AS level, facility_id AS entity_key, fund_code, vintage_year, facility_id, flow_date, amount_eur
    FROM flows
    UNION ALL
    SELECT 'FUND', fund_code, fund_code, vintage_year, NULL, flow_date, amount_eur FROM flows
    UNION ALL
    SELECT 'VINTAGE', vintage_year::TEXT, NULL, vintage_year, NULL, flow_date, amount_eur FROM flows;

    -- 4. gross IRR and MOIC per entity
    DROP TABLE IF EXISTS tmp_perf;
    CREATE TEMP TABLE tmp_perf AS
    WITH totals AS (
        SELECT 'FACILITY' AS level, facility_id AS entity_key, sum(drawn) AS drawn, sum(returned) AS returned, sum(fv) AS fv
        FROM tmp_fp_facility GROUP BY facility_id
        UNION ALL
        SELECT 'FUND', fund_code, sum(drawn), sum(returned), sum(fv) FROM tmp_fp_facility GROUP BY fund_code
        UNION ALL
        SELECT 'VINTAGE', vintage_year::TEXT, sum(drawn), sum(returned), sum(fv) FROM tmp_fp_facility GROUP BY vintage_year
    ), arrays AS (
        SELECT level, entity_key, max(fund_code) AS fund_code, max(vintage_year) AS vintage_year,
               max(facility_id) AS facility_id,
               array_agg(flow_date ORDER BY flow_date) AS dates, array_agg(amount_eur ORDER BY flow_date) AS amounts
        FROM tmp_entity_flow GROUP BY level, entity_key
    )
    SELECT a.*, t.drawn, t.returned, t.fv,
           dbo.fn_xirr(a.dates, a.amounts) AS gross_irr,
           (t.returned + t.fv) / t.drawn  AS moic,
           NULL::NUMERIC AS lp_called, NULL::NUMERIC AS lp_distributed, NULL::NUMERIC AS carry,
           NULL::NUMERIC AS nav, NULL::NUMERIC AS net_irr,
           NULL::DATE[] AS lp_dates, NULL::NUMERIC[] AS lp_amounts, NULL::NUMERIC AS pre_carry_irr,
           NULL::TEXT AS has_terms
    FROM arrays a JOIN totals t ON t.level = a.level AND t.entity_key = a.entity_key;

    -- 5. FUND rows: LP view (a fund with no LP flow yet gets 0 called / distributed)
    UPDATE tmp_perf p
       SET lp_called      = coalesce(lp.called, 0),
           lp_distributed = coalesce(lp.distributed, 0),
           lp_dates       = coalesce(lp.dates, '{}') || p_as_of_date,
           lp_amounts     = coalesce(lp.amounts, '{}') || p.fv,
           has_terms      = ft.fund_code
      FROM tmp_perf f
      LEFT JOIN (
          SELECT c.fund_code,
                 sum(c.amount) FILTER (WHERE c.flow_type = 'lp_call')         AS called,
                 sum(c.amount) FILTER (WHERE c.flow_type = 'lp_distribution') AS distributed,
                 array_agg(c.flow_date ORDER BY c.flow_date) AS dates,
                 array_agg(CASE WHEN c.flow_type = 'lp_call' THEN -c.amount ELSE c.amount END ORDER BY c.flow_date) AS amounts
          FROM dbo.fund_cash_flow c
          WHERE c.flow_date <= p_as_of_date AND c.flow_type IN ('lp_call', 'lp_distribution')
          GROUP BY c.fund_code
      ) lp ON lp.fund_code = f.entity_key
      LEFT JOIN dbo.fund_terms ft ON ft.fund_code = f.entity_key
     WHERE p.level = 'FUND' AND f.level = 'FUND' AND f.entity_key = p.entity_key;

    -- LP pre-carry IRR (end value = FV) decides whether carry accrues
    UPDATE tmp_perf SET pre_carry_irr = dbo.fn_xirr(lp_dates, lp_amounts)
     WHERE level = 'FUND' AND has_terms IS NOT NULL;

    -- unsolvable pre-carry IRR on a fund that has LP flows: carry 0 (a fund without LP flows
    -- only gets the net reject below)
    INSERT INTO dbo.etl_reject (run_id, source_table, business_key, as_of_date, reason)
    SELECT p_run_id, 'dbo.fund_performance', level || ':' || entity_key || '@' || p_as_of_date, p_as_of_date,
           'pre-carry ' || dbo.fn_xirr_reason(lp_dates, lp_amounts)
    FROM tmp_perf
    WHERE level = 'FUND' AND has_terms IS NOT NULL AND pre_carry_irr IS NULL
      AND (lp_called > 0 OR lp_distributed > 0);
    GET DIAGNOSTICS v_n = ROW_COUNT; v_rej := v_rej + v_n;

    -- European waterfall, full catch-up: LPs first get their hurdle, i.e. the end value
    -- H = sum(-lp_flow_i x (1 + hurdle) ^ ((T - t_i) / 365)); the GP then takes 100 % of the
    -- excess until it holds carry_pct of the total profit. So carry = min(carry_pct x profit,
    -- FV - H) and an LP above the hurdle never ends below it.
    UPDATE tmp_perf p
       SET carry = CASE WHEN p.pre_carry_irr >= ft.hurdle_pct / 100
                        THEN round(least(
                                 ft.carry_pct / 100 * greatest(0, p.lp_distributed + p.fv - p.lp_called),
                                 greatest(0, p.fv - (
                                     SELECT coalesce(sum(-x.amount * power(1 + ft.hurdle_pct / 100,
                                                                         (p_as_of_date - x.d) / 365.0)), 0)
                                     FROM unnest(p.lp_dates[1:array_length(p.lp_dates, 1) - 1],
                                                 p.lp_amounts[1:array_length(p.lp_amounts, 1) - 1]) AS x (d, amount)
                                 ))), 2)
                        ELSE 0 END
      FROM dbo.fund_terms ft
     WHERE p.level = 'FUND' AND ft.fund_code = p.entity_key;

    UPDATE tmp_perf
       SET nav        = fv - carry,
           lp_amounts = lp_amounts[1:array_length(lp_amounts, 1) - 1] || (fv - carry),     -- end value = NAV
           net_irr    = dbo.fn_xirr(lp_dates, lp_amounts[1:array_length(lp_amounts, 1) - 1] || (fv - carry))
     WHERE level = 'FUND' AND has_terms IS NOT NULL;

    -- 6. rejects for unsolvable IRRs (fn_xirr_reason solves again, so only for NULL results)
    INSERT INTO dbo.etl_reject (run_id, source_table, business_key, as_of_date, reason)
    SELECT p_run_id, 'dbo.fund_performance', level || ':' || entity_key || '@' || p_as_of_date, p_as_of_date, reason
    FROM (
        SELECT level, entity_key, dbo.fn_xirr_reason(dates, amounts) AS reason
        FROM tmp_perf WHERE gross_irr IS NULL
        UNION ALL
        SELECT level, entity_key, 'no fund terms'
        FROM tmp_perf WHERE level = 'FUND' AND has_terms IS NULL
        UNION ALL
        SELECT level, entity_key, 'net ' || dbo.fn_xirr_reason(lp_dates, lp_amounts)
        FROM tmp_perf WHERE level = 'FUND' AND has_terms IS NOT NULL AND net_irr IS NULL
    ) r;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_rej := v_rej + v_n;

    DELETE FROM dbo.fund_performance WHERE as_of_date = p_as_of_date;
    INSERT INTO dbo.fund_performance (
        as_of_date, level, entity_key, fund_code, vintage_year, facility_id,
        drawn_eur, returned_eur, fair_value_eur, gross_irr, moic,
        lp_called_eur, lp_distributed_eur, accrued_carry_eur, nav_eur, net_irr, etl_run_id)
    SELECT p_as_of_date, level, entity_key, fund_code, vintage_year, facility_id,
           round(drawn, 2), round(returned, 2), round(fv, 2), round(gross_irr, 6), round(moic, 4),
           round(lp_called, 2), round(lp_distributed, 2), carry, round(nav, 2), round(net_irr, 6), p_run_id
    FROM tmp_perf;
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    DROP TABLE IF EXISTS tmp_gross_flow, tmp_fp_facility, tmp_entity_flow, tmp_perf;
    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_build_fund_performance', v_start, v_read, v_loaded, v_rej, p_as_of_date);
END $$;
