-- Sectors and countries only take conformed reference values
SELECT count(*) FROM dbo.borrower b
WHERE b.sector_name NOT IN (SELECT sector_name FROM dbo.ref_sector)
   OR b.country_code NOT IN (SELECT country_code FROM dbo.ref_country);
