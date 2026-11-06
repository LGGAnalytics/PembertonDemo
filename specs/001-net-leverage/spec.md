# Spec 001: Borrower net leverage (x EBITDA)

| | |
|---|---|
| **Status** | Draft |
| **Owner** | Portfolio Monitoring |
| **Requested by** | Investment Committee |
| **Date** | 2026-11-06 |

## 1. Business context
Net leverage is the main credit metric in direct lending. It drives internal ratings, covenant headroom and pricing.
The warehouse already holds borrowers' quarterly debt, cash and EBITDA in `dbo.borrower_financials`, but leverage is not calculated anywhere.
The Investment Committee wants to see the portfolio's weighted average leverage and which loans sit at high leverage, next to the existing risk view.

## 2. Definition
- **Name:** `net_leverage`
- **Business definition:** how many years of EBITDA the borrower needs to repay its debt net of cash.
- **Formula:** `net_leverage = (total_debt − cash_and_equivalents) / ebitda_ltm`, in multiples of EBITDA ("x").
- **Grain:** calculated per **borrower × quarter-end**, then carried to each **facility × month-end**.
- **Type:** `NUMERIC(8,2)`, rounded half-up to 2 decimals.

## 3. Source data and lineage
| Layer | Object | Change |
|---|---|---|
| staging | `staging.borrower_financials` | None: the inputs already exist |
| dbo | `dbo.borrower_financials` | New column `net_leverage`, calculated in `dbo.usp_load_borrower_financials` |
| dbo | `dbo.facility_month` | New column `net_leverage`, set in `dbo.usp_build_facility_month` (point-in-time rule below) |
| bi | `bi.vw_facility_exposure`, `bi.vw_watchlist` | Expose `net_leverage` and `leverage_band` |
| bi | `bi.vw_portfolio_monthly` | Add `net_leverage_x_outstanding` and `outstanding_with_leverage_eur` so the weighted average re-aggregates correctly |
| Metabase | new cards | See section 6 |

## 4. Rules and edge cases
| Case | Expected result |
|---|---|
| `ebitda_ltm` is NULL (late reporting) | `net_leverage` is NULL |
| `ebitda_ltm` ≤ 0 | `net_leverage` is NULL (leverage is meaningless when EBITDA is negative or zero) |
| `total_debt` or `cash_and_equivalents` is NULL | `net_leverage` is NULL |
| Cash exceeds debt (net cash) | Negative value is allowed |
| Point in time for a facility-month | Use the borrower's **latest quarter with `period_end_date` ≤ `as_of_date`**. If that quarter's leverage is NULL, the value is NULL; never fall back to an older quarter. |
| No quarter on or before `as_of_date` | NULL |
| Leverage band (`leverage_band`, in bi) | `< 4.0x`, `4.0–5.5x`, `5.5–7.0x`, `≥ 7.0x`, `n/a` (NULL) |
| Portfolio weighted average | Σ(net_leverage × outstanding_eur) / Σ(outstanding_eur), over facilities where net_leverage is not NULL |

## 5. Acceptance criteria (each one becomes a test in `tests/sql/`)
- **AC1:** For every row of `dbo.borrower_financials` with EBITDA > 0 and debt and cash present, `net_leverage = round((total_debt − cash_and_equivalents) / ebitda_ltm, 2)`.
- **AC2:** `net_leverage` is NULL whenever `ebitda_ltm` is NULL or ≤ 0.
- **AC3:** In `dbo.facility_month`, `net_leverage` equals the borrower's value for the latest quarter-end on or before `as_of_date`.
- **AC4:** `bi.vw_portfolio_monthly` totals still reconcile to `dbo.facility_month` (the existing test t09 must keep passing).
- **AC5:** At least 95% of the latest month's outstanding has a non-NULL `net_leverage` (data coverage).
- **AC6:** All existing tests t01–t09 still pass.

## 6. Dashboard impact
- New KPI tile **"Net leverage"**, a smart scalar showing the weighted average with the change against the previous month. An increase is shown as bad. It replaces the text card "Net leverage (x EBITDA)".
- New bar chart **"Exposure by leverage band (EUR m)"**, latest month, ordered from lowest to highest band, in brand blues.
- Add a **"Net leverage"** column to the watchlist table.
- All new cards respond to the **Fund** filter.

## 7. Out of scope
- Covenant definitions and headroom (covenant EBITDA adjustments differ by deal).
- Gross leverage, interest coverage ratio (could be spec 002).
- Changes to the internal rating model.
