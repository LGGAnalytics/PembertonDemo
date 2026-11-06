# Data dictionary

All amounts in the `dbo` fact and the `bi` views are in **EUR**, converted at month-end FX. Source amounts are in the facility's local currency.
**This file must be updated in the same change as any column added, removed or redefined** (see `CLAUDE.md`).

## Source extracts and `staging.*` (all TEXT)

| Extract / table | Columns |
|---|---|
| funds | fund_code, fund_name, vintage_year, strategy, fund_size_eur, base_currency |
| borrowers | borrower_id, borrower_name, sector, country, pe_sponsor, founded_year |
| facilities | facility_id, borrower_id, fund_code, instrument_type, currency, commitment_amount, base_rate, spread_bps, floor_bps, oid_price, origination_date, maturity_date |
| loan_marks | facility_id, as_of_date, outstanding_principal, fair_value_price, internal_rating, days_past_due, non_accrual_flag |
| cash_flows | transaction_id, facility_id, transaction_date, transaction_type, amount, currency |
| borrower_financials | borrower_id, period_end_date, revenue_ltm, ebitda_ltm, total_debt, cash_and_equivalents, interest_expense_ltm, reporting_currency |
| fx_rates | rate_date, currency, eur_per_unit |
| reference_rates | rate_date, rate_name, rate_pct |

Every staging table also has `_row_id`, `_source_file` and `_loaded_at`.

## `dbo` (treated)

### dbo.fund
| Column | Type | Description |
|---|---|---|
| fund_code | text PK | Fund identifier (EDL-III, EDL-IV, SCF-I) |
| fund_name | text | Full fund name |
| vintage_year | smallint | Fund vintage |
| strategy | text | Senior Direct Lending / Opportunistic |
| fund_size_eur | numeric | Fund size (EUR) |
| base_currency | char(3) | Fund currency |

### dbo.borrower
| Column | Type | Description |
|---|---|---|
| borrower_id | text PK | Borrower identifier |
| borrower_name | text | Legal name (synthetic) |
| sector_name | text FK → ref_sector | Conformed sector |
| country_code | char(2) FK → ref_country | ISO-2 country |
| pe_sponsor | text | Private-equity sponsor (NULL if sponsorless) |
| is_sponsored | boolean | `pe_sponsor IS NOT NULL` |
| founded_year | smallint | Year founded |

### dbo.facility
| Column | Type | Description |
|---|---|---|
| facility_id | text PK | Loan facility identifier |
| borrower_id / fund_code | FK | Owner borrower / lending fund |
| instrument_type | text FK → ref_instrument | Unitranche, Senior Secured Term Loan, RCF, Second Lien, Holdco PIK Note |
| currency | char(3) | EUR / GBP / USD |
| commitment_amount | numeric | Committed amount, local currency |
| base_rate_name | text | EURIBOR 3M / SONIA / SOFR |
| spread_bps | int | Margin over the base rate |
| floor_bps | int | Base-rate floor |
| oid_price | numeric | Original issue discount price (% of par) |
| origination_date / maturity_date | date | Start and final maturity |
| tenor_years | numeric | (maturity − origination) / 365.25 |

### dbo.loan_mark (facility × month-end)
| Column | Type | Description |
|---|---|---|
| facility_id, as_of_date | PK | |
| outstanding_principal | numeric | Drawn principal, local currency (PIK accretes) |
| fair_value_price | numeric | Valuation mark, % of par |
| internal_rating | smallint 1–5 | 1 strong … 5 impaired; NULL means not rated |
| days_past_due | int | Days past due |
| is_non_accrual | boolean | Interest no longer accrued |

### dbo.cash_flow
transaction_id PK, facility_id FK, transaction_date, transaction_type (Drawdown, Repayment, Interest or Fee), amount, currency.

### dbo.borrower_financials (borrower × quarter-end, last twelve months)
| Column | Type | Description |
|---|---|---|
| borrower_id, period_end_date | PK | |
| revenue_ltm | numeric | Revenue, last twelve months |
| ebitda_ltm | numeric | EBITDA, last twelve months. **NULL when the borrower reported late** |
| total_debt | numeric | Total financial debt |
| cash_and_equivalents | numeric | Cash |
| interest_expense_ltm | numeric | Interest expense, last twelve months |
| reporting_currency | char(3) | Always EUR in this dataset |

### dbo.fx_rate / dbo.reference_rate
`fx_rate` (rate_date, currency) PK, `eur_per_unit`. `reference_rate` (rate_date, rate_name) PK, `rate_pct` (% p.a.).

### dbo.facility_month (fact: facility × month-end, EUR)
| Column | Description |
|---|---|
| facility_id, as_of_date | PK |
| fund_code, borrower_id, currency | Copied from the facility |
| fx_eur_per_unit | Month-end FX used |
| commitment_eur / outstanding_eur / undrawn_eur | Commitment, drawn and undrawn amounts in EUR |
| fair_value_price / fair_value_eur | Mark, and outstanding × price |
| spread_bps / base_rate_pct | Margin, and the reference rate that month |
| all_in_rate_pct | max(base rate, floor) + spread |
| internal_rating / days_past_due / is_non_accrual | From the mark |
| risk_status | Non-accrual > Impaired > Watchlist > Performing |

### Reference and audit
`ref_country` (code, iso3, name, region), `ref_sector` (name, group), `ref_instrument` (type, seniority, rank),
`etl_run_log` (run_id, procedure, timings, rows read, loaded and rejected),
`etl_reject` (run_id, source table and row, business key, reason, raw_record as JSONB).

## `bi` (views for Metabase)

See `docs/ARCHITECTURE.md` for each view's grain. Column names are those of `dbo.facility_month` plus the descriptive names (fund_name, borrower_name, sector_name, sector_group, country_name, region, pe_sponsor, instrument_type, seniority, internal_rating_label, is_latest_month).
`bi.vw_portfolio_monthly` adds: facilities, borrowers, spread_x_outstanding, all_in_rate_x_outstanding, non_accrual_eur, watchlist_eur and watchlist_facilities.
