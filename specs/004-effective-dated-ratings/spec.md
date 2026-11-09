# Spec 004: Effective-dated external credit ratings applied point-in-time

| | |
|---|---|
| **Status** | Done |
| **Owner** | Credit Risk |
| **Requested by** | Demo sponsor (mirrors the client's `Asset_Rating_*` update from `view_CREDIT_Rating`) |
| **Date** | 2026-11-06 |
| **Depends on** | Spec 002 (runs inside the period loop, incremental window) |

## 1. Business context
Ratings change on their own calendar, not on month-ends. The client keeps a rating history with `ValidFromDate` /
`ValidToDate` and, after each position rebuild, stamps every position with the rating that was in force on that
as-of date, updating **only rows whose rating actually changed** and only for rating rows audited in the last 24 hours.
The demo currently has a single `internal_rating` that arrives already baked into the monthly mark file.
This spec adds an external rating history (S&P, Moody's and an internal committee grade) with validity intervals,
a mapping to a common 1–5 score, and the point-in-time stamp on the monthly fact.

Client pattern reproduced: SCD-2 join `AsOfDate BETWEEN ValidFrom AND COALESCE(ValidTo, today)`, change-only
`UPDATE … WHERE ISNULL(new,'1') <> ISNULL(old,'1')`, and the `AuditUpdated >= DATEADD(day,-1,MAX(AuditUpdated))` window.

## 2. Definition
- **Source grain:** one row per `borrower × agency × validity interval`.
- **Target grain:** `dbo.facility_month` (facility × month-end), new columns:

| Column | Definition | Type |
|---|---|---|
| `rating_sp` | S&P rating in force on `as_of_date` | `TEXT` |
| `rating_moodys` | Moody's rating in force on `as_of_date` | `TEXT` |
| `rating_committee` | Internal committee grade in force on `as_of_date` (`A`–`E`) | `TEXT` |
| `rating_score` | Worst (highest) of the three agencies' scores via `dbo.ref_rating_scale` (1 best … 5 worst) | `SMALLINT` |
| `rating_changed_in_run` | TRUE if this run changed any of the four columns for the row | `BOOLEAN` |

- **In force** = `valid_from ≤ as_of_date AND (valid_to IS NULL OR as_of_date < valid_to)`.
- `risk_status` (existing) is **not** changed by this spec; `rating_score` is informational and feeds a new band.

## 3. Source data and lineage
| Layer | Object | Change |
|---|---|---|
| source | `data/raw/credit_ratings.csv` (generator, new) | Columns `borrower_id, agency, rating, valid_from, valid_to, updated_at`. Dirty on purpose: mixed date formats, lower-case ratings, blank `valid_to`, one overlapping interval per ~20 borrowers, one unknown agency, one unknown borrower, duplicate rows |
| source | `data/raw/delta/credit_ratings.csv` | A handful of rating changes with `updated_at` = run day, used by `make incremental` |
| staging | `staging.credit_ratings` (new) | All TEXT + lineage columns; added to `10_load_staging.sql` and `11_load_delta.sql` |
| dbo | `dbo.ref_rating_scale` (new, seeded) | `agency, rating, score, rank` — S&P (AAA…D), Moody's (Aaa…C), Committee (A…E) → score 1–5 |
| dbo | `dbo.credit_rating` (new) | Typed history: `borrower_id, agency, rating, valid_from, valid_to, updated_at, etl_run_id, loaded_at`, PK `(borrower_id, agency, valid_from)` |
| dbo | `dbo.facility_month` | Add the five columns of §2 |
| dbo | `dbo.usp_load_credit_rating` (new) | Parse/conform, close overlaps, reject unknowns; TRUNCATE + INSERT (dimension-like, not periodised) |
| dbo | `dbo.usp_apply_ratings` (new) | Per period: pivot in-force ratings per borrower into a temp table, compute score, change-only UPDATE of `facility_month` for that period; logs `rows_loaded` = rows actually updated |
| dbo | `dbo.usp_run_etl` | Calls `usp_load_credit_rating` with the dimensions and `usp_apply_ratings` as the last step of each period |
| dbo | `dbo.usp_discover_periods` (spec 002) | In incremental mode, a rating row with `updated_at` in the window adds every period ≥ its `valid_from` (within lookback) |
| bi | `bi.vw_facility_exposure`, `bi.vw_watchlist` | Expose the four rating columns and `rating_band` (`1–2 Strong`, `3 Adequate`, `4 Weak`, `5 Distressed`, `n/a`) |
| bi | `bi.vw_rating_migration` (new) | Month × fund × previous `rating_score` × current `rating_score` × outstanding EUR, for a migration matrix |
| Metabase | cards | See §6 |

## 4. Rules and edge cases
| Case | Expected result |
|---|---|
| Rating text case / spaces (`bb+`, ` Baa2 `) | Conformed via `fn_conform` against `ref_rating_scale` for that agency |
| Unknown agency, unknown borrower, rating not in scale, invalid `valid_from` | Rejected to `etl_reject` with reason |
| `valid_to` blank | Open interval (NULL) |
| `valid_to ≤ valid_from` | Rejected, reason `invalid interval` |
| Two intervals of the same borrower × agency overlap | The one with the later `updated_at` wins for the overlapping days: the earlier row's `valid_to` is set to the later row's `valid_from`. A DQ row `overlap closed` is written to `etl_reject` with both keys; nothing is dropped |
| Gap in history (no interval covers `as_of_date`) | That agency's column is NULL |
| Exact duplicates in staging | Last staged row wins (`DISTINCT ON`), as in other loads |
| `rating_score` with some agencies missing | Worst of the available ones; NULL only if all three are NULL |
| Change-only update | `UPDATE … WHERE (new.rating_sp, new.rating_moodys, new.rating_committee, new.rating_score) IS DISTINCT FROM (old.…)`; `rating_changed_in_run` set TRUE on updated rows and reset to FALSE on the others of that period |
| Incremental window | Only rating rows with `updated_at ≥ watermark − 24 h` trigger period expansion; the stamp itself always uses the full history (so a period rebuilt for other reasons still gets correct ratings) |
| Facility's borrower has no ratings at all | All NULL, band `n/a`; not a reject |

## 5. Acceptance criteria (each one becomes a test in `tests/sql/`)
- **AC1:** For every `facility_month` row and each agency, the stamped rating equals the single `dbo.credit_rating` row in force on `as_of_date` for the borrower (recomputed in the test with the §2 interval rule), or NULL when none.
- **AC2:** No two `dbo.credit_rating` rows of the same borrower × agency overlap after load, and every seeded overlap produced an `overlap closed` row in `etl_reject`.
- **AC3:** The seeded unknown agency, unknown borrower and inverted interval are in `etl_reject` with their reasons and absent from `dbo.credit_rating`.
- **AC4:** `rating_score = greatest(score_sp, score_moodys, score_committee)` ignoring NULLs, NULL only when all three are NULL.
- **AC5:** On a second run with **no** rating changes, `etl_run_log.rows_loaded` for `usp_apply_ratings` is 0 for every period and no row has `rating_changed_in_run = TRUE`.
- **AC6:** After `make incremental` with the delta ratings, only the facility-months of the affected borrowers, from the new `valid_from` onwards, have `rating_changed_in_run = TRUE`, and their stamped rating equals the delta rating.
- **AC7:** `bi.vw_rating_migration` outstanding totals per month reconcile to `dbo.facility_month`.
- **AC8:** Tests t01–t09 and the tests of specs 002 and 003 still pass.

## 6. Dashboard impact
- New stacked bar **"Exposure by rating band (EUR m)"**, latest month by fund, bands in order Strong → Distressed, fund series colours `#3D7CC9` / `#6BBD4A` / `#7D63BD`.
- New table **"Rating migrations this month"**: borrower, agency, from → to, outstanding EUR, from `bi.vw_rating_migration` filtered to changed rows.
- Add `rating_sp`, `rating_committee`, `rating_score` to the watchlist table.
- All new cards include `[[AND fund_code = {{fund}}]]`.

## 7. Out of scope
- Replacing the mark file's `internal_rating` or changing the `risk_status` rule (candidate spec 005 once the committee grade is trusted).
- Rating outlooks / watch flags.
- Agency-specific notching for subordinated instruments.

## 8. Current queries vs target shape

### 8.1 The point-in-time stamp

**Client (screenshot 1, lines 398–415):**
```sql
Update P Set P.Asset_Rating_Pemberton = CR.PembertonRating,
             P.[Asset_Rating_Pemberton_Score] = CR.Pemberton_Score,
             P.[Asset_Rating_SnP]   = CR.SnPRating,
             P.[Asset_Rating_Moody] = CR.[MoodyRating]
FROM [dbo].[Position] P
Inner join ( SELECT DISTINCT BorrowerName, ProjectName, Asset_BackOfficeExternalID FROM [pbi].[view_LOANADMIN_DM_Asset] ) A
        ON P.Asset_BackOfficeExternalID = A.Asset_BackOfficeExternalID
INNER JOIN [pbi].[view_CREDIT_Rating] CR ON A.[ProjectName] = CR.ProjectName AND A.BorrowerName = CR.BorrowerName
       AND P.AsOfDate BETWEEN CR.ValidFromDate AND COALESCE(CR.ValidToDate, CONVERT(date, GETDATE()))
Where CR.AuditUpdated >= (SELECT DATEADD(Day,-1,MAX(AuditUpdated)) FROM [pbi].[view_CREDIT_Rating])   --up to 24 hours before latest audit update
  AND ISNULL(CR.PembertonRating,'1') <> ISNULL(P.Asset_Rating_Pemberton,'1');
```
Three things to copy: the validity-interval join, the "only rows that changed" predicate, and the audit window. One thing to improve: the client's view is already pivoted (one row per borrower with the three agencies as columns); the demo receives one row per agency and pivots in a temp table.

**Demo today:** `internal_rating` is a column of the monthly mark file, copied as-is into `dbo.loan_mark` and `dbo.facility_month`. No history, no agencies, no change detection.

**Target** (`dbo.usp_apply_ratings`)
```sql
CREATE OR REPLACE PROCEDURE dbo.usp_apply_ratings(p_run_id UUID, p_as_of_date DATE)
LANGUAGE plpgsql AS $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_read INT; v_loaded INT; v_rej INT := 0;
BEGIN
    SELECT count(*) INTO v_read FROM dbo.facility_month WHERE as_of_date = p_as_of_date;

    -- stage 1: ratings in force on the period date, pivoted to one row per borrower
    DROP TABLE IF EXISTS tmp_rating_pit;
    CREATE TEMP TABLE tmp_rating_pit AS
    SELECT  r.borrower_id,
            max(r.rating) FILTER (WHERE r.agency = 'S&P')       AS rating_sp,
            max(r.rating) FILTER (WHERE r.agency = 'Moody''s')  AS rating_moodys,
            max(r.rating) FILTER (WHERE r.agency = 'Committee') AS rating_committee,
            max(sc.score)                                       AS rating_score        -- worst of the available agencies
    FROM dbo.credit_rating r
    JOIN dbo.ref_rating_scale sc ON sc.agency = r.agency AND sc.rating = r.rating
    WHERE r.valid_from <= p_as_of_date                                               -- client: AsOfDate BETWEEN ValidFrom
      AND (r.valid_to IS NULL OR p_as_of_date < r.valid_to)                          --         AND COALESCE(ValidTo, today)
    GROUP BY r.borrower_id;

    -- stage 2: change-only update (client: ISNULL(new,'1') <> ISNULL(old,'1'))
    UPDATE dbo.facility_month fm
       SET rating_sp            = p.rating_sp,
           rating_moodys        = p.rating_moodys,
           rating_committee     = p.rating_committee,
           rating_score         = p.rating_score,
           rating_changed_in_run = TRUE
      FROM (SELECT fm2.facility_id, fm2.as_of_date, pit.*
              FROM dbo.facility_month fm2
              LEFT JOIN tmp_rating_pit pit ON pit.borrower_id = fm2.borrower_id
             WHERE fm2.as_of_date = p_as_of_date) p
     WHERE fm.facility_id = p.facility_id
       AND fm.as_of_date  = p.as_of_date
       AND (fm.rating_sp, fm.rating_moodys, fm.rating_committee, fm.rating_score)
           IS DISTINCT FROM (p.rating_sp, p.rating_moodys, p.rating_committee, p.rating_score);
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    UPDATE dbo.facility_month SET rating_changed_in_run = FALSE
     WHERE as_of_date = p_as_of_date AND rating_changed_in_run IS DISTINCT FROM TRUE AND etl_run_id <> p_run_id;

    DROP TABLE IF EXISTS tmp_rating_pit;
    CALL dbo.usp_log_step(p_run_id, 'dbo.usp_apply_ratings', v_start, v_read, v_loaded, v_rej, p_as_of_date);
END $$;
```
`IS DISTINCT FROM` on a row constructor replaces the client's `ISNULL(x,'1') <> ISNULL(y,'1')` idiom and is NULL-safe without a sentinel value.

The client's 24-hour **audit window** does not live in the UPDATE in the demo. It lives in `usp_discover_periods` (spec 002): a rating row with `updated_at >= watermark − 24 h` adds every period from its `valid_from` onwards to `tmp_periods`. The stamp itself always uses the full history, so a period rebuilt for another reason is still correct. This separates "what to rebuild" from "what is true", which the client's single predicate conflates.

### 8.2 History load with overlap closing

**Demo today:** no equivalent. Closest pattern is `usp_load_borrower_financials` (parse → reject → truncate/insert).

**Target** (`dbo.usp_load_credit_rating`, in addition to the standard parse/reject block)
```sql
-- close overlaps: the later-updated row wins the overlapping days (client's view does this upstream)
WITH ordered AS (
    SELECT c.*,
           lead(c.valid_from)  OVER w AS next_from,
           lead(c.updated_at)  OVER w AS next_updated
    FROM tmp_credit_rating c
    WHERE c.reject_reason = ''
    WINDOW w AS (PARTITION BY c.borrower_id, c.agency ORDER BY c.valid_from, c.updated_at)
)
UPDATE tmp_credit_rating t
   SET valid_to      = o.next_from,
       dq_note       = 'overlap closed'
  FROM ordered o
 WHERE t._row_id = o._row_id
   AND o.next_from IS NOT NULL
   AND (o.valid_to IS NULL OR o.valid_to > o.next_from)
   AND o.next_updated >= o.updated_at;                        -- the newer row wins

INSERT INTO dbo.etl_reject (run_id, source_table, source_row_id, business_key, reason, raw_record)
SELECT p_run_id, 'staging.credit_ratings', _row_id, borrower_id || '/' || agency || '@' || valid_from, dq_note, raw_record
FROM tmp_credit_rating WHERE dq_note IS NOT NULL;

TRUNCATE dbo.credit_rating;
INSERT INTO dbo.credit_rating (...) SELECT ... FROM tmp_credit_rating WHERE reject_reason = '';
```
Dimension-like history, so TRUNCATE + INSERT stays (it is not periodised).

### 8.3 Risk status unchanged
`usp_build_facility_month` keeps the existing `CASE WHEN is_non_accrual … END` for `risk_status`. The new `rating_score` is a parallel, external view of credit quality; merging the two is a future spec.
