-- AC7 (spec 003): the late Drawdown in data/raw/delta/cash_flows.csv (dated in the restated
-- month M) is in the cost of M for its facility, and no earlier month of that facility was
-- rebuilt by the incremental run (so no earlier cost moved).
WITH latest AS (SELECT run_id FROM dbo.etl_run ORDER BY started_at DESC LIMIT 1),
     late AS (
    SELECT upper(dbo.fn_clean_text(facility_id)) AS facility_id,
           dbo.fn_try_date(transaction_date)     AS d,
           dbo.fn_try_numeric(amount)            AS amount
    FROM staging.cash_flows
    WHERE _source_file = 'delta/cash_flows.csv' AND lower(btrim(transaction_type)) = 'drawdown'
), m AS (SELECT dbo.fn_month_end(d) AS me, facility_id, amount FROM late)
SELECT (SELECT CASE WHEN count(*) = 0 THEN 1 ELSE 0 END FROM late)
     -- M contains the late drawdown: drawn(M) = drawn(M-1) + every drawdown dated in M
     + (SELECT count(*) FROM m
          JOIN dbo.facility_month cur  ON cur.facility_id  = m.facility_id AND cur.as_of_date = m.me
          LEFT JOIN dbo.facility_month prev ON prev.facility_id = m.facility_id
                                         AND prev.as_of_date = dbo.fn_month_end((m.me - INTERVAL '1 month')::DATE)
         WHERE cur.drawn_to_date_local - coalesce(prev.drawn_to_date_local, 0)
               <> (SELECT sum(c.amount) FROM dbo.cash_flow c
                    WHERE c.facility_id = m.facility_id AND c.transaction_type = 'Drawdown'
                      AND dbo.fn_month_end(c.transaction_date) = m.me)
            OR cur.etl_run_id <> (SELECT run_id FROM latest))
     -- earlier months of that facility untouched by the incremental run
     + (SELECT count(*) FROM m JOIN dbo.facility_month fm ON fm.facility_id = m.facility_id AND fm.as_of_date < m.me
         WHERE fm.etl_run_id = (SELECT run_id FROM latest));
