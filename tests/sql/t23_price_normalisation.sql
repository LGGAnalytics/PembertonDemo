-- AC4 (spec 003):
--   * every staged cash flow with price blank or '0' is loaded (not rejected) with price NULL / 0
--   * a facility whose drawdowns all lack a price gets wa = par (100 debt / 1 equity)
--   * every staged price > 200 on a debt instrument is rejected as 'invalid price' and absent
--     from dbo.cash_flow; at least one such planted row exists
WITH staged AS (
    SELECT DISTINCT ON (upper(dbo.fn_clean_text(transaction_id)))
           upper(dbo.fn_clean_text(transaction_id)) AS transaction_id,
           upper(dbo.fn_clean_text(facility_id))    AS facility_id,
           btrim(coalesce(price, ''))               AS price_raw
    FROM staging.cash_flows
    ORDER BY upper(dbo.fn_clean_text(transaction_id)), _row_id DESC
), blank AS (
    SELECT s.* FROM staged s WHERE s.price_raw IN ('', '0')
), high AS (
    SELECT s.* FROM staged s
    JOIN dbo.facility f        ON f.facility_id = s.facility_id
    JOIN dbo.ref_instrument ri ON ri.instrument_type = f.instrument_type AND ri.price_basis = 'PCT_OF_PAR'
    WHERE dbo.fn_try_price(s.price_raw) > 200
), unpriced AS (     -- facility-months whose drawdowns so far all carry no price
    SELECT fm.facility_id, fm.as_of_date, ri.price_basis, fm.wa_acquisition_price
    FROM dbo.facility_month fm
    JOIN dbo.facility f        ON f.facility_id = fm.facility_id
    JOIN dbo.ref_instrument ri ON ri.instrument_type = f.instrument_type
    JOIN dbo.cash_flow c       ON c.facility_id = fm.facility_id AND c.transaction_date <= fm.as_of_date
                              AND c.transaction_type = 'Drawdown'
    GROUP BY 1, 2, 3, 4
    HAVING bool_and(coalesce(c.price, 0) = 0)
)
SELECT (SELECT count(*) FROM blank b
         WHERE NOT EXISTS (SELECT 1 FROM dbo.cash_flow c WHERE c.transaction_id = b.transaction_id
                                                           AND coalesce(c.price, 0) = 0)
           AND NOT EXISTS (SELECT 1 FROM dbo.etl_reject r WHERE r.source_table = 'staging.cash_flows'
                                                            AND r.business_key = b.transaction_id
                                                            AND r.reason NOT LIKE '%invalid price%'))
     + (SELECT count(*) FROM unpriced
         WHERE wa_acquisition_price <> CASE price_basis WHEN 'PER_UNIT' THEN 1 ELSE 100 END)
     + (SELECT CASE WHEN count(*) = 0 THEN 1 ELSE 0 END FROM high)
     + (SELECT count(*) FROM high h
         WHERE EXISTS (SELECT 1 FROM dbo.cash_flow c WHERE c.transaction_id = h.transaction_id)
            OR NOT EXISTS (SELECT 1 FROM dbo.etl_reject r WHERE r.source_table = 'staging.cash_flows'
                                                            AND r.business_key = h.transaction_id
                                                            AND r.reason LIKE '%invalid price%'));
