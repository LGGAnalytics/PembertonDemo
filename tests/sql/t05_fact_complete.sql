-- Every monthly mark made it into the EUR fact (no FX / reference-rate gaps)
SELECT (SELECT count(*) FROM dbo.loan_mark) - (SELECT count(*) FROM dbo.facility_month);
