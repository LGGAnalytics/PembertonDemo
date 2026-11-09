# Tasks 004: Effective-dated ratings

Tick each task when done. AC = acceptance criterion in `spec.md` §5. Every AC maps to at least one task and one test.

Implementation decisions taken while executing (resolve ambiguities in plan 004, spec unchanged):
- **Change detection survives the period rebuild.** `usp_build_facility_month` deletes and re-inserts the period, so it now carries the previous rating stamp into the new rows (`tmp_prev_rating`). Without it every row would look "changed" against NULL on every run and AC5 could never hold.
- **`rating_changed_in_run` describes the latest run.** `usp_load_credit_rating` (dimension phase, before the loop) resets the flag to FALSE everywhere, so periods that a run does not rebuild do not keep a stale TRUE from an older run (needed for AC6).
- **Incremental window.** The rating branch of `usp_discover_periods` uses the same watermark − `overlap_hours` rule as the other sources. The client's 24-hour window maps to `overlap_hours` (the demo uses 0 because the full load and the delta are minutes apart; 24 h would re-read the whole base file).
- **Delta ratings** have `valid_from` inside the restated month, so spec 002 AC4 (exactly one period rebuilt) still holds.
- **Test order.** The AC5 test re-runs the ETL, so it is named `t35_change_only_zero.sql` and runs after the AC6 test `t34_delta_ratings.sql` (plan 004 had the two names the other way round).
- `updated_at` is a DATE (the source sends dates).

## A. Source and staging
- [x] A1 Generator: `credit_ratings.csv` (Committee for every borrower, S&P ~60%, Moody's ~45%, intervals follow leverage) with dirt: mixed dates, 10% lower-case ratings, open `valid_to`, overlaps (~1 per 20 borrowers), one `Fitch` row, one unknown borrower, one inverted interval, duplicates — AC2, AC3
- [x] A2 Generator: `delta/credit_ratings.csv`, 6 changes dated in the last month — AC6
- [x] A3 `staging.credit_ratings`; `10_load_staging.sql` (TRUNCATE + `\copy`), `11_load_delta.sql` (append)

## B. dbo
- [x] B1 DDL: `ref_rating_scale`, `credit_rating` (PK, interval CHECK, index), `facility_month` + five rating columns with comments — AC1, AC4
- [x] B2 Seeds: rating scale S&P / Moody's / Committee → score 1–5 — AC4
- [x] B3 `18_usp_load_credit_rating.sql`: parse, conform, rejects, overlap closing, TRUNCATE + INSERT, reset of `rating_changed_in_run` — AC2, AC3
- [x] B4 `23_usp_apply_ratings.sql`: point-in-time pivot, change-only UPDATE — AC1, AC4, AC5
- [x] B5 `usp_build_facility_month` carries the previous rating stamp across the rebuild — AC5, AC6
- [x] B6 `usp_discover_periods`: watermark + rating branch — AC6
- [x] B7 `usp_run_etl`: `usp_load_credit_rating` with the dimensions, `usp_apply_ratings` last in the loop — AC1

## C. bi
- [x] C1 `vw_facility_exposure`, `vw_watchlist` + ratings and `rating_band`
- [x] C2 `vw_rating_migration` (new) — AC7

## D. Tests
- [x] D1 `t30_rating_pit.sql` — AC1
- [x] D2 `t31_no_overlaps.sql` — AC2
- [x] D3 `t32_rating_rejects.sql` — AC3
- [x] D4 `t33_rating_score_worst.sql` — AC4
- [x] D5 `tests/incremental/t34_delta_ratings.sql` — AC6
- [x] D6 `tests/incremental/t35_change_only_zero.sql` — AC5
- [x] D7 `t36_migration_reconciles.sql` — AC7
- [x] D8 t01–t26 still pass (`make pipeline`, `make incremental`) — AC8

## E. Metabase
- [x] E1 `cards/exposure_by_rating_band.sql` (stacked by fund, fund colours)
- [x] E2 `cards/rating_migrations.sql` (table)
- [x] E3 `cards/watchlist.sql` + `rating_sp`, `rating_committee`, `rating_score`
- [x] E4 `dashboard.json` (new cards, `[[AND fund_code = {{fund}}]]`); `make dashboard`

## F. Docs and close
- [x] F1 `DATA_DICTIONARY.md`, `ARCHITECTURE.md`, `DEMO_RUNBOOK.md`
- [x] F2 `specs/README.md` status; spec `Status: Done`
