# Spec 005: Gross IRR, Net IRR and MOIC per fund

| | |
|---|---|
| **Status** | Approved |
| **Owner** | Portfolio Management |
| **Requested by** | Demo sponsor — Azure DevOps Story AB#672 (Feature AB#644, Epic AB#619 Pemberton) |
| **Date** | 2026-11-09 |
| **Depends on** | Spec 002 (period loop, incremental window), spec 003 (pre-window drawdowns at origination) |
| **Amendments** | 2026-11-09, during implementation review (AB#672 Tasks 1/5–3/5), confirmed by the owner: AC7 reworded (F1); carry follows the full catch-up rule (F19); AC3b added and AC4 extended; reject reasons `xirr: out of range` / `invalid input`, `net …` / `pre-carry …`, `no fx rate for <ccy>` and the §4 rows added |

## 1. Business context
The dashboard shows yield, marks and exposure, but not the return LPs actually earn. A portfolio manager judges a
fund on its **IRR** (time-weighted return of the cash flows plus today's value) and its **MOIC** (money back per
euro invested), both **gross** (what the loans earned) and **net** (what LPs keep after management fees, fund
expenses and carried interest). This spec adds the two fund-level datasets needed for the net figures, a reusable
XIRR function, and a periodised performance table per facility, fund and vintage.

## 2. Definition
All amounts in EUR. T = `as_of_date` (a month-end of the period loop), t0 = the entity's first flow date.

| Measure | Business definition | Formula | Type |
|---|---|---|---|
| Gross flows | Cash between the fund and its borrowers | From `dbo.cash_flow`, `transaction_date ≤ T`: **out (−)** `Drawdown`; **in (+)** `Repayment`, `Interest`, `Fee`. **`PIK` excluded** (capitalised, already in fair value) | — |
| `fair_value_eur` (FV_T) | Value still held at T | `Σ dbo.facility_month.fair_value_eur` at T (0 for a facility with no row at T, e.g. repaid) | `NUMERIC(18,2)` |
| `gross_irr` | Annual return of the loans | XIRR, Act/365: r solving `Σ CF_i/(1+r)^((t_i−t0)/365) + FV_T/(1+r)^((T−t0)/365) = 0` | `NUMERIC(9,6)` (decimal, 0.05 = 5 %) |
| `moic` | Multiple on invested capital (gross) | `(Σ Repayment + Σ Interest + Σ Fee + FV_T) / Σ Drawdown` | `NUMERIC(9,4)` |
| LP flows | Cash between the fund and its LPs | From `dbo.fund_cash_flow`, `flow_date ≤ T`: **calls (−)** `lp_call`; **distributions (+)** `lp_distribution` | — |
| `accrued_carry_eur` | GP carry if the fund were sold at FV_T | **Only if** the LP pre-carry IRR (LP flows + FV_T) ≥ `hurdle_pct`, else 0: `min(carry_pct × max(0, Σ distributions + FV_T − Σ calls), max(0, FV_T − H))`, where `H = Σ −LP flow_i × (1 + hurdle_pct)^((T − t_i)/365)` is the end value that gives LPs exactly the hurdle. European waterfall, full (100 %) catch-up: LPs above the hurdle never end below it | `NUMERIC(18,2)` |
| `nav_eur` | LP net asset value | `FV_T − accrued_carry_eur` | `NUMERIC(18,2)` |
| `net_irr` | Annual return to LPs | XIRR over LP flows with end value `NAV_T` | `NUMERIC(9,6)` |

**Grain:** `dbo.fund_performance` — one row per `as_of_date × level × entity_key`, where `level` ∈
`FACILITY` (entity_key = facility_id), `FUND` (fund_code), `VINTAGE` (vintage_year from `dbo.fund`).
FUND and VINTAGE pool all flows and fair values of their facilities. FACILITY and VINTAGE rows carry gross figures
only; FUND rows also carry the LP / net figures.

**FX:** each gross flow is converted at the `dbo.fx_rate` of its own month-end (as `bi.vw_cash_flow_monthly`).
**Flows dated before the first available FX month-end (2024-11-30) use that first rate** — see §4 and decision D1.

## 3. Source data and lineage
| Layer | Object | Change |
|---|---|---|
| source | `data/raw/fund_terms.csv` (generator, new) | One row per fund: `fund_code, mgmt_fee_pct, fee_basis, fee_frequency, expense_pct, carry_pct, hurdle_pct, catch_up_pct`. Values (fee / expenses / carry / hurdle): EDL-III 1.00 / 0.15 / 10 / 6 · EDL-IV 0.90 / 0.12 / 10 / 6 · SCF-I 1.50 / 0.20 / 15 / 8; `fee_basis` INVESTED, `fee_frequency` Q, `catch_up_pct` 100. Plus 1 planted bad row (`XX-9`). No delta |
| source | `data/raw/fund_cash_flows.csv` (generator, new) | `flow_id, fund_code, flow_date, flow_type, amount, currency`. Dirty on purpose: mixed date formats, case/whitespace in `flow_type` and `currency`, ~1.5 % duplicates (`write_csv`), 2 planted bad rows (unknown fund, negative amount). Generation rule in §3.1 |
| source | `data/raw/delta/fund_cash_flows.csv` | 3 rows: one late `lp_distribution` per fund in the last month (Oct-2026), used by `make incremental` |
| staging | `staging.fund_terms`, `staging.fund_cash_flows` (new) | All TEXT + `_row_id, _source_file, _loaded_at`; added to `10_load_staging.sql` (TRUNCATE, `\copy`, counts) and `11_load_delta.sql` (fund_cash_flows) |
| dbo | `dbo.fund_terms` (new) | Typed, PK `fund_code` FK `dbo.fund`, CHECKs per §4, column comments |
| dbo | `dbo.fund_cash_flow` (new) | Typed, PK `flow_id`, FK `dbo.fund`, `flow_type` CHECK, `amount ≥ 0`, column comments |
| dbo | `dbo.fn_xirr(p_dates DATE[], p_amounts NUMERIC[]) RETURNS NUMERIC` (new, in `03_functions.sql`) | Newton-Raphson from 0.10 (stop when the step < 1e-10), bisection fallback on [−0.9999, 10] (stop when the bracket < 1e-12); NULL if an input is NULL, no sign change, no convergence in 100 iterations or overflow — never raises; `IMMUTABLE`. `dbo.fn_xirr_reason` gives the reject reason (`xirr: invalid input` / `no sign change` / `out of range`) |
| dbo | `dbo.usp_load_fund_terms`, `dbo.usp_load_fund_cash_flow` (new) | Pattern of `usp_load_cash_flow`: temp table, `reject_reason`, `etl_reject`, TRUNCATE + INSERT, `usp_log_step`. Dimension-like, called before the period loop |
| dbo | `dbo.fund_performance` (new) | Columns: `as_of_date, level, entity_key, fund_code, vintage_year, facility_id, drawn_eur, returned_eur, fair_value_eur, gross_irr, moic, lp_called_eur, lp_distributed_eur, accrued_carry_eur, nav_eur, net_irr, etl_run_id, loaded_at`; PK `(as_of_date, level, entity_key)` |
| dbo | `dbo.usp_build_fund_performance(p_run_id, p_as_of_date)` (new) | Per period: `DELETE WHERE as_of_date = p_as_of_date` + INSERT; stage temp tables for gross flows, LP flows and end values; unsolvable IRRs and no-drawdown entities → `etl_reject`; `usp_log_step` one row per period |
| dbo | `dbo.usp_run_etl` | Calls the two loaders with the dimensions; calls `usp_build_fund_performance` as the last step of each period (after `usp_apply_fx_rates` and `usp_apply_ratings`, so `fair_value_eur` is set) |
| dbo | `dbo.usp_discover_periods` | Watermark for `staging.fund_cash_flows`; in incremental mode a changed fund flow marks its month **and every later month** (IRR is cumulative) |
| bi | `bi.vw_fund_performance` (new) | `fund_code, fund_name, vintage_year, as_of_date, level, facility_id, gross_irr_pct, net_irr_pct, moic, drawn_eur, returned_eur, fair_value_eur, nav_eur` — IRRs ×100, rounded to 2 dp |
| Metabase | `metabase/cards/fund_performance.sql`, `dashboard.json` | See §6 |

### 3.1 Generation of `fund_cash_flows.csv`
LP flows must cover the **same horizon as the gross flows**, otherwise Net and Gross IRR are measured over different
periods (decision D2). For each fund, from the month-end of its first drawdown to Oct-2026:
- `mgmt_fee` at each quarter-end = `mgmt_fee_pct/100 × average invested cost EUR in the quarter × 90/365`.
- `fund_expense` at each quarter-end, same rule with `expense_pct`.
- `lp_call` at each month-end with drawdowns or fees = that month's drawdowns EUR + that month's `mgmt_fee` + `fund_expense`.
- `lp_distribution` at each month-end with gross inflows = that month's repayments + interest + facility fees EUR.

EUR conversion in the generator uses the same FX rule as §2 (first available rate for pre-window months), so LP calls
and gross drawdowns reconcile. Expected size: EDL-III ~23, EDL-IV ~9, SCF-I ~19 quarter-ends × 2 fee types ≈ 100 fee
rows; ~250 LP rows; ~25 KB.

## 4. Rules and edge cases
| Case | Expected result |
|---|---|
| `fund_terms.fund_code` / `fund_cash_flows.fund_code` not in `dbo.fund` | Rejected, reason `unknown fund` |
| `fund_terms` percentage outside range (fee 0–3, expense 0–1, carry 0–30, hurdle 0–15) | Rejected, reason `<column> out of range` |
| `catch_up_pct` ≠ 100 | Rejected, reason `unsupported catch-up` (only full catch-up is modelled; D3) |
| `fee_basis` not `INVESTED`/`COMMITTED`, `fee_frequency` not `Q` | Rejected with reason |
| `flow_type` dirty case/whitespace (`' LP_Call '`) | Conformed with `fn_conform`; unknown value → rejected |
| `flow_date` mixed formats | Parsed with `fn_try_date`; unparseable → rejected |
| Negative `amount` | Rejected, reason `negative amount` (sign comes from `flow_type`) |
| Missing `flow_id` | Rejected, reason `missing flow_id` |
| `amount` ≥ 1e16 (does not fit `NUMERIC(18,2)`) | Rejected, reason `amount out of range` |
| `currency` ≠ the fund's `base_currency` | Rejected, reason `currency is not the fund base currency` |
| Duplicate `flow_id` in staging | Last staged row wins (`DISTINCT ON … ORDER BY _row_id DESC`), as in `usp_load_cash_flow` |
| Gross flow dated before the first FX month-end | Converted at the first available rate for its currency (D1); not rejected |
| Gross flow with no FX rate for its month (no rate at all for the currency, or a gap month after the first rate) | Excluded from the flows, rejected with key `FLOW:<transaction_id>@<T>`, reason `no fx rate for <ccy>` |
| Facility / fund / vintage with no drawdown up to T | No row in `fund_performance`; one `etl_reject` row per period, reason `no drawdown`. A facility without drawdown is also left out of its fund's and vintage's pools (its income and fair value have no cost); a fund or vintage left with no facility gets its own `no drawdown` reject |
| Flows with no sign change (e.g. written off: −100 and FV 0) | `gross_irr` (or `net_irr`) NULL; row still written with MOIC; one `etl_reject` row, reason `xirr: no sign change`; run status Success |
| No root between −99.99 % and 1000 %, or no convergence in 100 iterations (typically a position held a few days, whose annualised return explodes) | IRR NULL; `etl_reject` reason `xirr: out of range`; run continues |
| NULL or mismatched XIRR inputs | IRR NULL; reason `xirr: invalid input` |
| LP pre-carry IRR unsolvable | Carry 0, NAV = FV; reject reason `pre-carry xirr: …` |
| Net IRR unsolvable | `net_irr` NULL; reject reason `net xirr: …` |
| Fund with no `fund_terms` row | Gross figures written; carry, NAV and net IRR NULL (LP totals still shown); reject reason `no fund terms` |
| Fund with terms but no LP flow up to T | `lp_called_eur` = `lp_distributed_eur` = 0, carry 0, NAV = FV; net IRR on the NAV alone → `net xirr: no sign change` (no separate pre-carry reject) |
| MOIC ≥ 100 000 (does not fit `NUMERIC(9,4)`, e.g. a mis-keyed tiny drawdown) or NAV < 0 | Not handled: would fail the period. Not reachable with the generated data; follow-up if real data is loaded (review F22) |
| Pre-carry LP IRR < hurdle | `accrued_carry_eur = 0`, `nav_eur = FV_T` |
| Facility not yet originated at T | No row (no flows ≤ T) — not a reject |
| Point-in-time | Only flows with date ≤ T and the fair value of T are used; each period is independent and rebuildable |
| `fund_terms` restated in incremental mode | Reloaded into dbo, but no period is rebuilt (spec has no `fund_terms` delta; a full run picks it up). Known limitation, review finding F5 |
| Rejects per period | `business_key` = `<level>:<entity_key>@<as_of_date>` (flows `FLOW:<transaction_id>@<as_of_date>`), so incremental re-runs stay traceable |

## 5. Acceptance criteria (each one becomes a test in `tests/sql/`)
- **AC1 (t40):** `dbo.fn_xirr` for −100 at t0 and +105 at t0 + 365 days returns 0.05 ± 0.0001; a fixture facility with −100 drawdown, +5 interest at t0+1y and fair value 100 at T = t0+1y gives `gross_irr` = 5.00 % ± 0.01 pp and `moic` = 1.05.
- **AC2 (t41):** For every facility with `PIK` rows, `drawn_eur` and `returned_eur` in `dbo.fund_performance` equal the recomputed sums of its non-PIK flows only.
- **AC3 (t42):** After load, every fund has `mgmt_fee` and `fund_expense` rows at every quarter-end from its first drawdown quarter to Sep-2026; and at the latest `as_of_date`, `net_irr < gross_irr` for every FUND row with `gross_irr > 0`.
- **AC4 (t43):** *(also covers the `no drawdown`, `no fx rate` and `no fund terms` rejects)* A fixture with no sign change makes `fn_xirr` return NULL; in the pipeline, every FACILITY row with NULL `gross_irr` has a matching `etl_reject` row with an `xirr:` reason, and the latest `dbo.etl_run` has status `Success`.
- **AC5 (t03):** The 3 planted bad rows (fund_terms `XX-9`, fund_cash_flows unknown fund, negative amount) are in `etl_reject` with their reasons and absent from dbo.
- **AC6 (t44):** `bi.vw_fund_performance` matches `dbo.fund_performance` row for row at the latest `as_of_date` (IRRs ×100, 2 dp); `dbo.fund_performance` has a FUND row for all 3 funds in every period, each stamped with an `etl_run_id` and one `usp_log_step` row per period.
- **AC7 (t46, incremental):** After `make incremental`, only the last period's `fund_performance` rows are rebuilt (stamped with the incremental run's `etl_run_id`, earlier periods untouched), and each FUND row's `lp_distributed_eur` equals the full-run value plus exactly that fund's delta `lp_distribution`. *Amended 2026-11-09 (review finding F1): the same delta also restates marks and adds late gross cash flows in that month, so gross figures legitimately change too.*
- **AC8 (dashboard):** After `make dashboard`, the "Fund performance" card shows Gross IRR, Net IRR and MOIC per fund matching `bi.vw_fund_performance`, and filtering by fund leaves only that fund's row (manual check, evidence on the Story).
- **AC3b (t45):** On rolled-back fixtures, a fund well above its hurdle accrues carry = carry_pct × (distributions + FV − calls); a fund in the catch-up zone accrues FV − H and its net IRR equals the hurdle; a fund below it accrues 0; NAV = FV − carry. On pipeline data every FUND row has NAV = FV − carry and no FUND row accrues carry with a net IRR below its hurdle.
- **AC9:** Existing tests t01–t09 and those of specs 002–004 still pass.

## 6. Dashboard impact
- New table card **"Fund performance"** (`fund_performance`), level FUND, latest `as_of_date`: Fund, Vintage, Gross IRR %, Net IRR %, MOIC x.
- Placed at row 48, col 0, size 24 × 6, under the part-2 placeholder.
- Fund filter mapped to `fund_code`; card SQL includes `[[AND fund_code = {{fund}}]]`.
- Brand palette: header navy `#192C50`; IRR columns conditional colour blue `#3D7CC9` (≥ 0) / no red, fund rows tagged with the fund series colours `#3D7CC9` / `#6BBD4A` / `#7D63BD`.

## 7. Out of scope
- American (deal-by-deal) waterfall, partial catch-up, clawback, GP commitment.
- Committed-capital fee basis in the generator (column accepted, only `INVESTED` generated).
- Fund-level leverage / subscription lines, recycling.
- DPI, RVPI, TVPI and PME — candidate follow-up spec.
- Restating pre-window interest and repayments: the generator has none before Nov-2024, so 2021/2022 vintages are
  dominated by drawdowns and the ending fair value (known caveat, shown in the card description).

## 8. Decisions to confirm at approval
| # | Decision | Recommendation | Why |
|---|---|---|---|
| D1 | FX for gross flows before 2024-11-30 | Use the first available rate for that currency | `bi.vw_cash_flow_monthly`'s inner join would silently drop every pre-window drawdown, making 2021/2022 IRRs meaningless |
| D2 | Horizon of LP flows | From each fund's first drawdown month (back to 2021), not only the 24-month window | Story's "8 quarter-ends / 144 LP rows" leaves EDL-III and SCF-I net flows on a shorter horizon than gross, so AC3 (Net < Gross) would not hold by construction. Changes Task AB#673's "Done when" from "8 mgmt_fee rows" to "a fee row every quarter-end from first drawdown" |
| D3 | `catch_up_pct` | Accept only 100, reject others | The formula models full catch-up only; accepting 0–100 would silently compute wrong carry |
| D4 | VINTAGE level | Keep, as the Story asks | Today each vintage maps to one fund, so VINTAGE = FUND; it becomes useful when a second fund of the same vintage is added |
