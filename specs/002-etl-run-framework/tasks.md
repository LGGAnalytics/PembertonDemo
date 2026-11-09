# Tasks 002: ETL run framework

Tick each task when done. AC = acceptance criterion in `spec.md` §5. Every AC maps to at least one task and one test.

## A. Schema (dbo DDL, seeds, helpers)
- [x] A1 `dbo.etl_run`, `dbo.etl_watermark`, `dbo.etl_config` tables with comments (`01_create_dbo_tables.sql`) — AC1, AC6
- [x] A2 `dbo.etl_run_log` + `as_of_date`, `message`; status check `SUCCESS|ERROR` — AC2, AC5
- [x] A3 `dbo.etl_reject` + `as_of_date` — AC5
- [x] A4 `dbo.loan_mark`, `dbo.facility_month` + `etl_run_id`, `loaded_at`; `facility_month` + `*_local`, `*_eur` nullable; indexes on `as_of_date` — AC3, AC4
- [x] A5 Seed `etl_config` (`lookback_months`, `overlap_hours`, `fail_on_period`) (`02_seed_reference_data.sql`) — AC5
- [x] A6 Helpers `fn_month_end`, `fn_month_ends_from`, `fn_config_int` (`03_functions.sql`) — AC4

## B. Framework procedures
- [x] B1 `usp_log_step` gains `p_as_of_date`, `p_status`, `p_message` — AC2, AC5
- [x] B2 `usp_audit_start` / `usp_audit_finish` (`10a_usp_audit.sql`); finish on Success advances watermark from `tmp_watermark` — AC1, AC6
- [x] B3 `usp_discover_periods` builds `tmp_periods` + `tmp_watermark`, sets `periods_planned` (`10b_usp_discover_periods.sql`) — AC1, AC4

## C. Period-scoped loads
- [x] C1 `usp_load_loan_mark(p_run_id, p_as_of_date)`: period filter, DELETE+INSERT, lineage columns, rejects carry `as_of_date` — AC2, AC3
- [x] C2 `usp_build_facility_month(p_run_id, p_as_of_date)`: local measures, `fx_eur_per_unit` NULL, `fail_on_period` hook — AC2, AC5
- [x] C3 `usp_apply_fx_rates(p_run_id, p_as_of_date)` (`21_usp_apply_fx_rates.sql`): UPDATE from `fx_rate`, delete+reject unconverted — AC2
- [x] C4 `usp_load_facility`: remove `TRUNCATE … CASCADE`; delete+reject orphan periodised rows, then `DELETE` + `INSERT` (FKs deferrable) — AC4

## D. Orchestrator
- [x] D1 `usp_run_etl(p_mode, p_lookback_months, p_periods)`: audit start → dimensions → COMMIT → discover → loop with per-period COMMIT / ROLLBACK+audit+RAISE → audit finish — AC1, AC5
- [x] D2 `make pipeline` green with t01–t09 — AC8

## E. Incremental mode
- [x] E1 Generator emits `data/raw/delta/loan_marks.csv` (restated month) and `delta/cash_flows.csv` — AC4
- [x] E2 `sql/01_staging/11_load_delta.sql` (append, `_source_file = 'delta/…'`) — AC4
- [x] E3 `scripts/run_incremental.sh`, `scripts/run_tests.sh` accepts a directory, `Makefile` target `incremental` — AC4

## F. Tests (`tests/sql/` unless noted)
- [x] F1 `t10_run_header_success.sql` — AC1
- [x] F2 `t11_log_per_period.sql` — AC2
- [x] F3 `t12_lineage_run_id.sql` — AC3
- [x] F4 `t13_watermark.sql` — AC6
- [x] F5 `t14_bi_run_views.sql` — AC7
- [x] F6 `t15_error_path.sql` (hook on P2 of [P1,P2,P3]; restore afterwards) — AC5, AC6
- [x] F7 `tests/incremental/t16_incremental_delta.sql` — AC4
- [x] F8 t01–t09 pass in full mode and after `make incremental` — AC8

## G. BI and Metabase
- [x] G1 `bi.vw_etl_run_summary` rebased on `etl_run` + per-period log; `bi.vw_etl_run_history` — AC7
- [x] G2 `cards/pipeline_health.sql` updated; `cards/pipeline_runs.sql` new; `dashboard.json` — AC7
- [x] G3 `make dashboard` succeeds

## H. Docs and close
- [x] H1 `CLAUDE.md` rule 2 amended (periodised DELETE+INSERT; loop signature)
- [x] H2 `docs/ARCHITECTURE.md`, `docs/DATA_DICTIONARY.md`, `docs/DEMO_RUNBOOK.md`
- [x] H3 `specs/README.md` status; spec `Status: Done`
