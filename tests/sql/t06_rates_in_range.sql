-- All-in rates and prices are within plausible private-credit bounds
SELECT count(*) FROM dbo.facility_month
WHERE all_in_rate_pct NOT BETWEEN 3 AND 20
   OR fair_value_price NOT BETWEEN 0 AND 110
   OR outstanding_eur < 0;
