-- Every staging table received rows from its extract
SELECT count(*) FROM (VALUES
  ((SELECT count(*) FROM staging.funds)), ((SELECT count(*) FROM staging.borrowers)),
  ((SELECT count(*) FROM staging.facilities)), ((SELECT count(*) FROM staging.loan_marks)),
  ((SELECT count(*) FROM staging.cash_flows)), ((SELECT count(*) FROM staging.borrower_financials)),
  ((SELECT count(*) FROM staging.fx_rates)), ((SELECT count(*) FROM staging.reference_rates))) t(n)
WHERE n = 0;
