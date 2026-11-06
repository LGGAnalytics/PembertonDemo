# Demo Proposal — Finance Dashboard + Spec-Driven AI Column (DRAFT, pending approval)

No existing requirements were found (empty repo, no issues, nothing in Drive), so this is a proposal.

## 1. Dataset — synthetic European private-credit fund
Synthetic, deterministic (seeded), no real companies. Deliberately dirty raw extracts
(mixed date formats, thousands separators, casing, country variants, duplicates, rejectable rows).

| Extract | Content |
|---|---|
| funds | 3 funds (Direct Lending III, IV, Strategic Credit I) |
| borrowers | ~140 companies: sector, country, PE sponsor |
| facilities | ~230 loans: Unitranche / TL / RCF / 2nd Lien / PIK; EUR/GBP/USD; spread, floor, OID, maturity |
| loan_marks | monthly x 24: outstanding, price, internal rating, DPD, non-accrual |
| cash_flows | drawdowns, repayments, interest, fees |
| borrower_financials | quarterly LTM revenue, EBITDA, debt, cash, interest |
| fx_rates | month-end GBP/USD -> EUR |

## 2. Architecture
CSV -> BRONZE (raw text + load metadata) -> SILVER (typed, cleaned, deduped, rejects logged)
-> GOLD (facts, dims, marts) -> SQL data-quality tests -> Metabase dashboard.

- Docker Compose: Postgres 16 + Metabase v0.50.36
- All ETL in SQL, run by psql in a one-shot container (`make up / pipeline / dashboard / test`)
- Gold: fact_facility_month (EUR), portfolio KPIs, sector/country exposure, monthly trend, watchlist, cash flows
- Dashboard-as-code: JSON card definitions + Metabase API script, Fund filter across all cards

## 3. Spec-driven AI new column
- `CLAUDE.md` rules: no code without an approved spec; a column change touches silver, gold, tests, data dictionary, dashboard JSON
- `specs/` with template + ready spec for the demo column
- Proposed column: `net_leverage = (total_debt - cash) / LTM EBITDA` (alternatives: interest coverage, all-in yield, source-level esg_score)
- Live flow: spec -> plan -> tasks -> implement -> tests -> rebuild dashboard -> PR; rehearsed fallback branch

## 4. Open decisions
1. Dataset: synthetic private-credit (recommended) vs public market data
2. New column: net_leverage or alternative
3. AI tool used live (Claude Code assumed)
