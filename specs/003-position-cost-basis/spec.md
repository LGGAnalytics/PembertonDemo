# Spec 003: Position cost basis, weighted-average acquisition price and unrealised gain

| | |
|---|---|
| **Status** | Done |
| **Owner** | Fund Finance |
| **Requested by** | Demo sponsor (mirrors the client's `usp_CreatePositionEquityCost`) |
| **Date** | 2026-11-06 |
| **Depends on** | Spec 002 (period loop; this runs inside it) |

## 1. Business context
Fair value alone does not tell the Investment Committee whether a position is *making* money.
The client's position procedure rebuilds, for every as-of date, the **cost** of each position from the transaction
ledger: it aggregates buys/draws/sells/repayments, derives a weighted-average acquisition price, normalises prices
that are blank or zero, treats equity (price per unit) and debt (price per 100) differently, and stores
cost next to market value. The demo has the inputs (cash flows, marks, OID price) but no cost, no acquisition price
and no gain/loss.

Client pattern reproduced here: three-stage temp tables (`#tmp` transaction aggregates → `#tmp2` position join with
CASE on asset type → `UPDATE dbo.Position`), nested derived tables with price normalisation, and the equity/debt branch.

## 2. Definition
Grain: **facility × month-end** (`dbo.facility_month`), computed per period inside the spec 002 loop by a new
procedure `dbo.usp_build_cost_basis(p_run_id, p_as_of_date)`.

| Column | Definition | Type |
|---|---|---|
| `drawn_to_date_local` | Σ `Drawdown` amounts with `transaction_date ≤ as_of_date` | `NUMERIC(18,2)` |
| `repaid_to_date_local` | Σ `Repayment` amounts ≤ as_of_date | `NUMERIC(18,2)` |
| `pik_to_date_local` | Σ `PIK` (capitalised interest) amounts ≤ as_of_date | `NUMERIC(18,2)` |
| `wa_acquisition_price` | Σ(drawdown_amount × price_norm) / Σ(drawdown_amount) over drawdowns ≤ as_of_date | `NUMERIC(9,4)` |
| `cost_basis_local` | debt (`price_basis='PCT_OF_PAR'`): (drawn − repaid) × wa_acquisition_price / 100 + pik_to_date; equity (`'PER_UNIT'`): (drawn − repaid) × wa_acquisition_price | `NUMERIC(18,2)` |
| `cost_basis_eur` | `cost_basis_local × fx_eur_per_unit` | `NUMERIC(18,2)` |
| `unrealised_gain_eur` | `fair_value_eur − cost_basis_eur` | `NUMERIC(18,2)` |
| `realised_gain_local` | Σ over repayments ≤ as_of_date of `repayment_amount × (price_norm_repayment − wa_acquisition_price_at_that_date) / 100` (debt only; equity: × without /100) | `NUMERIC(18,2)` |

`price_norm` = the transaction's `price` after normalisation (see §4). Rounding: amounts half-up to 2 dp, prices to 4 dp.

## 3. Source data and lineage
| Layer | Object | Change |
|---|---|---|
| source | `data/raw/cash_flows.csv` (generator) | New columns `price` (clean price of the drawdown/repayment, dirty: blank, `0`, comma decimals, occasional `> 200`) and new `transaction_type` value `PIK`. New instrument `Equity co-invest` (~4% of facilities, `PER_UNIT`) so the equity branch is exercised |
| staging | `staging.cash_flows` | Add `price TEXT`; add to `\copy` list |
| dbo | `dbo.ref_instrument` | Add `price_basis TEXT NOT NULL CHECK (IN ('PCT_OF_PAR','PER_UNIT'))`, seeded |
| dbo | `dbo.cash_flow` | Add `price NUMERIC(9,4) NULL` (parsed, un-normalised); `transaction_type` check gains `'PIK'`. Normalised price is derived in `usp_build_cost_basis` because it depends on the instrument |
| dbo | `dbo.facility_month` | Add the eight columns of §2, nullable, with comments |
| dbo | `dbo.usp_load_cash_flow` | Parse `price`, conform `PIK`, apply normalisation, reject invalid prices |
| dbo | `dbo.usp_build_cost_basis` (new) | Stage 1 `tmp_txn`: per facility, cumulative sums and WA price as of the period, computed from a derived table that normalises price and applies the equity/debt scale. Stage 2 `tmp_position`: join `facility_month` for the period + `facility` + `ref_instrument` + `tmp_txn`, CASE on `price_basis`. Stage 3 `UPDATE dbo.facility_month SET … FROM tmp_position WHERE as_of_date = p_as_of_date` |
| dbo | `dbo.usp_run_etl` | Calls `usp_build_cost_basis` after `usp_apply_fx_rates` in each period |
| bi | `bi.vw_facility_exposure` | Expose `wa_acquisition_price`, `cost_basis_eur`, `unrealised_gain_eur`, `realised_gain_local` |
| bi | `bi.vw_portfolio_monthly` | Add `cost_basis_eur`, `unrealised_gain_eur` sums |
| bi | `bi.vw_cash_flow_monthly` | `PIK` appears as a type |
| Metabase | cards | See §6 |

## 4. Rules and edge cases
| Case | Expected result |
|---|---|
| `price` blank, NULL or `0` | `price_norm` = par: `100` for `PCT_OF_PAR`, `1` for `PER_UNIT` (client: `ISNULL(Price,0.01)=0 → 1`) |
| `price` comma decimal `98,75` | Parsed as `98.75` (extend `fn_try_numeric` only if a single comma followed by exactly 2 digits; thousands separators still stripped) |
| `price > 200` on a `PCT_OF_PAR` instrument, or `price < 0` | Transaction rejected to `etl_reject` with reason `invalid price`; it does not enter `dbo.cash_flow` |
| `Interest` / `Fee` rows | Loaded with whatever `price` they carry (usually blank); excluded from `usp_build_cost_basis` by the type filter |
| Facility with outstanding > 0 but **no drawdown** on or before `as_of_date` | `wa_acquisition_price`, `cost_basis_*`, `unrealised_gain_eur` are NULL; a DQ row is written to `etl_reject` with reason `no acquisition cash flow` and the fact row is **kept** |
| Σ drawdowns = 0 (division guard) | WA price NULL (client: `CASE WHEN SUM(...) = 0 THEN 1`; we prefer NULL over a fake price) |
| Repayments exceed drawdowns + PIK | `cost_basis_local` floored at 0; the excess is logged to `etl_reject` as `over-repaid` |
| `fx_eur_per_unit` NULL (spec 002 already removes those rows) | Not reachable; defensive `COALESCE` not added |
| Equity co-invest | `wa_acquisition_price` is a per-unit price; `fair_value_price` for equity is also per unit, so `fair_value_eur` in `usp_build_facility_month` uses `× price` not `× price / 100` for `PER_UNIT` (existing formula becomes a CASE) |
| Incremental run (spec 002) | A late cash flow dated in month M changes cost for M **and every later month**; `usp_discover_periods` must therefore expand a cash-flow change to all periods ≥ its month-end (within lookback) |

## 5. Acceptance criteria (each one becomes a test in `tests/sql/`)
- **AC1:** For every `facility_month` row of a `PCT_OF_PAR` facility with at least one prior drawdown, `cost_basis_local = round((drawn − repaid) × wa_acquisition_price / 100 + pik, 2)` recomputed independently in the test from `dbo.cash_flow`.
- **AC2:** For every `PER_UNIT` facility, `cost_basis_local = round((drawn − repaid) × wa_acquisition_price, 2)` and `fair_value_eur = outstanding × fx × fair_value_price`.
- **AC3:** `wa_acquisition_price` is between the min and max `price_norm` of the facility's drawdowns on or before the date, and is NULL exactly when there is no such drawdown.
- **AC4:** Every staged cash flow with `price` blank or `0` is loaded (not rejected) with `price` NULL or 0, and `usp_build_cost_basis` treats it as par (100 or 1 per `price_basis`, verified through `wa_acquisition_price` of facilities whose drawdowns all have blank price); every staged row with `price > 200` on a debt instrument is in `etl_reject` with reason `invalid price` and absent from `dbo.cash_flow`.
- **AC5:** `unrealised_gain_eur = fair_value_eur − cost_basis_eur` for every row where both are non-NULL, and is NULL otherwise.
- **AC6:** Portfolio `sum(unrealised_gain_eur)` in `bi.vw_portfolio_monthly` reconciles to `dbo.facility_month` for every month (extends t09).
- **AC7:** In the delta used by spec 002 AC4, a late `Drawdown` in month M changes `cost_basis_local` for M and all later months of that facility, and for no earlier month.
- **AC8:** `dbo.etl_reject` contains at least one `no acquisition cash flow` row from the seeded data (the generator plants one facility whose first drawdown is missing), and that facility's fact rows exist with NULL cost.
- **AC9:** Tests t01–t09 and spec 002 tests still pass.

## 6. Dashboard impact
- New KPI tile **"Unrealised gain/loss (EUR m)"**, smart scalar vs previous month, decrease shown as bad.
- New bar chart **"Cost vs fair value by fund (EUR m)"**, latest month, two series: cost `#192C50`, fair value `#3D7CC9`.
- Add `wa_acquisition_price` and `unrealised_gain_eur` columns to the watchlist table.
- All new cards include `[[AND fund_code = {{fund}}]]`.

## 7. Out of scope
- IRR / money multiple (needs full cash-flow timing; candidate spec 005, mirrors the client's `usp_CreateIRRCashflows`).
- Amortised cost under IFRS 9 effective interest (OID accretion); OID is reflected only through the drawdown price.
- Secondary trades at a different counterparty price (client's SCF overrides).

## 8. Current queries vs target shape

### 8.1 Transaction aggregation stage (`#tmp` in the client)

**Client (screenshots 3 and 4):** two nested derived tables. The inner one (`Y`) normalises `Price` per asset type (`EQUITY`: `ISNULL(Price,0.01)=0 → 1`; else `ISNULL(Price,1.0)=0 → 1`), tags `IsEquity`, and restricts to `TransactionCode IN ('BUY','SLL','DRAW','REPAY','LPAYD')` for the current date. The middle one (`X`) splits each row into `BUY_Quantity_F`, `SELL_Quantity_F`, … with `CASE WHEN TransactionCode = 'BUY' THEN AmountLocal / Price ELSE 0 END * (CASE WHEN IsEquity = 1 THEN 1.00 ELSE 100.00 END)`. The outer one `SUM`s them, computes `[WA ACQUISITION PRICE] = SUM(BUY×Price + DRAW×Price) / CASE WHEN SUM(BUY+DRAW) = 0 THEN 1 ELSE SUM(BUY+DRAW) END` and `[PRE_X]`, and lands in `#tmp`.

**Demo today:** nothing is derived from `dbo.cash_flow` except `bi.vw_cash_flow_monthly` (a sum per type per month, for one chart). `usp_load_cash_flow` has no price.

**Target** (`dbo.usp_build_cost_basis`, stage 1)
```sql
DROP TABLE IF EXISTS tmp_txn;
CREATE TEMP TABLE tmp_txn AS
SELECT  x.facility_id,
        x.currency,
        SUM(x.draw_amount) AS drawn_to_date_local,
        SUM(x.repay_amount) AS repaid_to_date_local,
        SUM(x.pik_amount) AS pik_to_date_local,
        SUM(x.draw_amount * x.price_norm)
            / NULLIF(SUM(x.draw_amount), 0)                                 AS wa_acquisition_price,   -- client: CASE WHEN SUM(...)=0 THEN 1; we return NULL instead
        SUM(x.repay_amount * (x.price_norm - x.wa_price_at_txn) / x.scale) AS realised_gain_local
FROM (
    SELECT  y.facility_id,
            y.currency,
            y.price_norm,
            y.scale,
            CASE WHEN y.transaction_type = 'Drawdown'  THEN y.amount ELSE 0 END AS draw_amount,
            CASE WHEN y.transaction_type = 'Repayment' THEN y.amount ELSE 0 END AS repay_amount,
            CASE WHEN y.transaction_type = 'PIK'       THEN y.amount ELSE 0 END AS pik_amount,
            -- running WA price *before* this transaction, for realised P&L on repayments
            SUM(CASE WHEN y.transaction_type = 'Drawdown' THEN y.amount * y.price_norm END)
                                  OVER (PARTITION BY y.facility_id ORDER BY y.transaction_date, y.transaction_id
                                        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
                            / NULLIF(SUM(CASE WHEN y.transaction_type = 'Drawdown' THEN y.amount END)
                                  OVER (PARTITION BY y.facility_id ORDER BY y.transaction_date, y.transaction_id
                                        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS wa_price_at_txn
    FROM (
        SELECT  t.facility_id,
                t.transaction_id,
                t.transaction_date,
                t.transaction_type,
                t.amount,
                t.currency,
                CASE WHEN ri.price_basis = 'PER_UNIT' THEN 1.00 ELSE 100.00 END AS scale,   -- client: IsEquity → 1.00 / 100.00
                CASE WHEN ri.price_basis = 'PER_UNIT'
                                  THEN CASE WHEN coalesce(t.price, 0) = 0 THEN 1   ELSE t.price END   -- client: ISNULL(Price,0.01)=0 → 1
                                  ELSE CASE WHEN coalesce(t.price, 0) = 0 THEN 100 ELSE t.price END   -- par when missing
                             END AS price_norm
        FROM dbo.cash_flow t
        JOIN dbo.facility       f  ON f.facility_id      = t.facility_id
        JOIN dbo.ref_instrument ri ON ri.instrument_type = f.instrument_type
        WHERE t.transaction_type IN ('Drawdown', 'Repayment', 'PIK')             -- client: IN ('BUY','SLL','DRAW','REPAY','LPAYD')
          AND t.transaction_date <= p_as_of_date                                 -- cumulative to the period
    ) y
) x
GROUP BY x.facility_id, x.currency;
```
(The client writes `alias = expression`; PostgreSQL requires `expression AS alias`. The one-column-per-line layout and the inline business comments are kept.)

### 8.2 Position stage (`#tmp2` in the client)

**Client (screenshot 2):** joins `#LotAllDates` (lots for the date) to the asset and portfolio dimensions and to `#tmp`, aggregates lots to asset level with `MIN`/`SUM`, and computes `X`, `Y` and `Cost` with `CASE WHEN AssetTypeCodeName = 'EQUITY' THEN … ELSE … / 100 END`, filtered on `Asset_BalancesheetType = 'ASSET'`.

**Target** (stage 2)
```sql
DROP TABLE IF EXISTS tmp_position;
CREATE TEMP TABLE tmp_position AS
SELECT  fm.facility_id,
        fm.as_of_date,
        t.drawn_to_date_local,
        t.repaid_to_date_local,
        t.pik_to_date_local,
        t.wa_acquisition_price,
        CASE WHEN ri.price_basis = 'PER_UNIT'
                                THEN  (t.drawn_to_date_local - t.repaid_to_date_local) * t.wa_acquisition_price
                                ELSE  (t.drawn_to_date_local - t.repaid_to_date_local) * t.wa_acquisition_price / 100
                                    + t.pik_to_date_local
                           END AS cost_basis_local,
        t.realised_gain_local,
        (t.wa_acquisition_price IS NOT NULL) AS has_acquisition
FROM dbo.facility_month fm
JOIN dbo.facility       f  ON f.facility_id      = fm.facility_id
JOIN dbo.ref_instrument ri ON ri.instrument_type = f.instrument_type
LEFT JOIN tmp_txn       t  ON t.facility_id      = fm.facility_id
WHERE fm.as_of_date = p_as_of_date;
```

### 8.3 Update stage (`UPDATE P SET … FROM dbo.Position P INNER JOIN #tmp2 T`)

**Client (screenshot 2 bottom / screenshot 1 top):** `UPDATE P SET P.Lot_AssetCost = T.Cost, P.Lot_Funded_Local = T.Cost, P.Lot_Unfunded_Local = 0 FROM dbo.Position P INNER JOIN … INNER JOIN #tmp2 T … WHERE P.AsOfDate = @currentDate AND A.AssetTypeCodeName = 'Equity'; DROP TABLE IF EXISTS #tmp; DROP TABLE IF EXISTS #tmp2;`

**Target** (stage 3)
```sql
UPDATE dbo.facility_month fm
   SET drawn_to_date_local  = t.drawn_to_date_local,
       repaid_to_date_local = t.repaid_to_date_local,
       pik_to_date_local    = t.pik_to_date_local,
       wa_acquisition_price = round(t.wa_acquisition_price, 4),
       cost_basis_local     = round(greatest(t.cost_basis_local, 0), 2),
       cost_basis_eur       = round(greatest(t.cost_basis_local, 0) * fm.fx_eur_per_unit, 2),
       unrealised_gain_eur  = round(fm.fair_value_eur - greatest(t.cost_basis_local, 0) * fm.fx_eur_per_unit, 2),
       realised_gain_local  = round(t.realised_gain_local, 2)
  FROM tmp_position t
 WHERE fm.facility_id = t.facility_id
   AND fm.as_of_date  = p_as_of_date;
GET DIAGNOSTICS v_loaded = ROW_COUNT;

-- data-quality rows (kept in the fact, explained in etl_reject)
INSERT INTO dbo.etl_reject (run_id, source_table, business_key, as_of_date, reason)
SELECT p_run_id, 'dbo.facility_month', t.facility_id || '@' || t.as_of_date, t.as_of_date,
       CASE WHEN NOT t.has_acquisition THEN 'no acquisition cash flow' ELSE 'over-repaid' END
FROM tmp_position t
WHERE NOT t.has_acquisition OR t.cost_basis_local < 0;
GET DIAGNOSTICS v_rej = ROW_COUNT;

DROP TABLE IF EXISTS tmp_txn;
DROP TABLE IF EXISTS tmp_position;
CALL dbo.usp_log_step(p_run_id, 'dbo.usp_build_cost_basis', v_start, v_read, v_loaded, v_rej, p_as_of_date);
```

### 8.4 Cash-flow load: price parsing added to the existing pattern

**Demo today** (`15_usp_load_cash_flow.sql`, parse block)
```sql
dbo.fn_conform(s.transaction_type, ARRAY['Drawdown','Repayment','Interest','Fee']) AS transaction_type,
dbo.fn_try_numeric(s.amount)                 AS amount,
```
**Target**
```sql
dbo.fn_conform(s.transaction_type, ARRAY['Drawdown','Repayment','Interest','Fee','PIK']) AS transaction_type,
dbo.fn_try_numeric(s.amount)                                                             AS amount,
dbo.fn_try_price(s.price)                                                                AS price,       -- '98,75' -> 98.75; '' -> NULL
...
-- reject reasons gain:
CASE WHEN d.price < 0 OR (d.price > 200 AND ri.price_basis = 'PCT_OF_PAR') THEN 'invalid price' END
```
`price_norm` is **not** stored in `dbo.cash_flow` after all (it depends on the instrument, which is a join away); it is derived in stage 1. §3 is amended accordingly: `dbo.cash_flow` gains only `price NUMERIC(9,4) NULL`.
