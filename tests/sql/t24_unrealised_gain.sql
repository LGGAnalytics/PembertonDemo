-- AC5 (spec 003): unrealised_gain_eur = fair_value_eur - cost_basis_eur where both are known, NULL otherwise
SELECT count(*) FROM dbo.facility_month
WHERE (cost_basis_eur IS NOT NULL AND fair_value_eur IS NOT NULL
       AND unrealised_gain_eur IS DISTINCT FROM fair_value_eur - cost_basis_eur)
   OR ((cost_basis_eur IS NULL OR fair_value_eur IS NULL) AND unrealised_gain_eur IS NOT NULL);
