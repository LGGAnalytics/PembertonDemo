-- AC3 (spec 003): wa_acquisition_price lies between the min and max normalised price of the
-- facility's drawdowns on or before the date, and is NULL exactly when there is none.
WITH d AS (
    SELECT fm.facility_id, fm.as_of_date,
           min(CASE WHEN coalesce(c.price, 0) = 0 THEN CASE ri.price_basis WHEN 'PER_UNIT' THEN 1 ELSE 100 END ELSE c.price END) AS lo,
           max(CASE WHEN coalesce(c.price, 0) = 0 THEN CASE ri.price_basis WHEN 'PER_UNIT' THEN 1 ELSE 100 END ELSE c.price END) AS hi
    FROM dbo.facility_month fm
    JOIN dbo.facility f        ON f.facility_id = fm.facility_id
    JOIN dbo.ref_instrument ri ON ri.instrument_type = f.instrument_type
    JOIN dbo.cash_flow c       ON c.facility_id = fm.facility_id AND c.transaction_date <= fm.as_of_date
                              AND c.transaction_type = 'Drawdown' AND c.amount > 0
    GROUP BY fm.facility_id, fm.as_of_date
)
SELECT count(*)
FROM dbo.facility_month fm
LEFT JOIN d USING (facility_id, as_of_date)
WHERE (d.facility_id IS NULL AND fm.wa_acquisition_price IS NOT NULL)
   OR (d.facility_id IS NOT NULL AND (fm.wa_acquisition_price IS NULL
                                      OR fm.wa_acquisition_price NOT BETWEEN round(d.lo, 4) - 0.0001 AND round(d.hi, 4) + 0.0001));
