# Plan 004: Effective-dated ratings

> Written before approval at the sponsor's request. Depends on plan 002 (period loop, watermark, `11_load_delta.sql`).

## 1. Source and staging
| File | Change |
|---|---|
| `data/generator/generate_data.py` | new `credit_ratings.csv`: per borrower, `Committee` grade history driven by `lev_at()` (grade changes when leverage crosses bands), `S&P` for ~60% of borrowers and `Moody's` for ~45%, 1–4 intervals each, `updated_at` a few days after `valid_from`. Dirt: date formats mixed, 10% lower-case ratings, blank open `valid_to`, one overlap per ~20 borrowers, one `Fitch` row, one unknown borrower, one `valid_to < valid_from`, duplicates via `write_csv` |
| `data/raw/delta/credit_ratings.csv` | 6 changes (downgrades/upgrades) with `updated_at = today` |
| `sql/01_staging/01_create_staging_tables.sql` | `staging.credit_ratings (borrower_id, agency, rating, valid_from, valid_to, updated_at, _row_id, _source_file, _loaded_at)` |
| `10_load_staging.sql`, `11_load_delta.sql` | TRUNCATE list + `\copy` |

## 2. dbo
| File | Change |
|---|---|
| `01_create_dbo_tables.sql` | `ref_rating_scale (agency, rating, score SMALLINT, rank SMALLINT, PRIMARY KEY (agency, rating))`; `credit_rating (borrower_id FK, agency, rating, valid_from, valid_to, updated_at, etl_run_id, loaded_at, PK (borrower_id, agency, valid_from), CHECK (valid_to IS NULL OR valid_to > valid_from))`; `facility_month` + `rating_sp, rating_moodys, rating_committee TEXT`, `rating_score SMALLINT`, `rating_changed_in_run BOOLEAN NOT NULL DEFAULT FALSE`; index `credit_rating (borrower_id, agency, valid_from)` |
| `02_seed_reference_data.sql` | scale: S&P `AAA…BBB- → 1`, `BB+…BB- → 2`, `B+…B → 3`, `B-…CCC+ → 4`, `CCC…D → 5`; Moody's equivalents; Committee `A→1 … E→5` |
| `18_usp_load_credit_rating.sql` | **new**: parse (`fn_try_date` ×3, `fn_conform` agency against `('S&P','Moody''s','Committee')`, rating against the scale of that agency), reject reasons (`unknown borrower`, `unknown agency`, `rating not in scale`, `invalid valid_from`, `invalid interval`), overlap closing (spec §8.2), TRUNCATE + INSERT, log |
| `23_usp_apply_ratings.sql` | **new**: spec §8.1 |
| `10b_usp_discover_periods.sql` | add the rating branch: `staging.credit_ratings._loaded_at ≥ watermark − 24h` **or** `fn_try_date(updated_at) ≥ watermark::date − 1` → `fn_month_ends_from(valid_from, last)` |
| `99_usp_run_etl.sql` | `CALL dbo.usp_load_credit_rating(v_run_id)` after `usp_load_borrower`; `CALL dbo.usp_apply_ratings(v_run_id, v_period.as_of_date)` last in the loop |
| `10a_usp_audit.sql` | watermark entry for `staging.credit_ratings` |

## 3. bi
- `vw_facility_exposure`, `vw_watchlist`: + four rating columns + `rating_band` CASE.
- `vw_rating_migration` (**new**): `facility_month` self-joined to the previous month-end (`lag` over facility), columns `as_of_date, fund_code, borrower_name, facility_id, agency_changed (text list), score_from, score_to, outstanding_eur, is_migration BOOLEAN`.

## 4. Tests
| Test | AC |
|---|---|
| `t30_rating_pit.sql` | AC1 — recompute in-force rating per (facility_month, agency) with a lateral join |
| `t31_no_overlaps.sql` | AC2 |
| `t32_rating_rejects.sql` | AC3 |
| `t33_rating_score_worst.sql` | AC4 |
| `tests/incremental/t34_change_only_zero.sql` | AC5 — run `make incremental` twice; second run has 0 updates |
| `tests/incremental/t35_delta_ratings.sql` | AC6 |
| `t36_migration_reconciles.sql` | AC7 |

## 5. Metabase
| File | Change |
|---|---|
| `cards/exposure_by_rating_band.sql` | **new** stacked bar by fund, series colours `#3D7CC9 / #6BBD4A / #7D63BD` |
| `cards/rating_migrations.sql` | **new** table from `vw_rating_migration WHERE is_migration` |
| `cards/watchlist.sql` | + `rating_sp, rating_committee, rating_score` |
| `dashboard.json` | two new cards in the risk row, both with `[[AND fund_code = {{fund}}]]` |

## 6. Docs
`DATA_DICTIONARY.md` (two tables, five columns), `ARCHITECTURE.md` (procedures 18 and 23, "point-in-time" paragraph), `DEMO_RUNBOOK.md` (show a downgrade arriving in the delta and only those rows flagged).

## 7. Order
1. Generator + staging + `ref_rating_scale` → `make pipeline` green.
2. `usp_load_credit_rating` → t31, t32.
3. `usp_apply_ratings` + orchestration → t30, t33.
4. Discovery branch + delta → t34, t35.
5. bi + t36, Metabase, docs.

## 8. Risks
- `max(rating) FILTER` in the pivot assumes one in-force row per agency; overlap closing guarantees it, t31 enforces it.
- Score mapping is a demo convention, not an agency-published equivalence; say so in the data dictionary.
