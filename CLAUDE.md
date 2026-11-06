# Instructions for AI agents working in this repository

This repository is a private-credit data warehouse. Data moves **staging → dbo → bi → Metabase**.
All changes are made with **spec-driven development (SDD)**: no code is written until a spec is approved.

## Architecture (do not break these rules)

1. **staging** (`sql/01_staging/`) holds raw extracts. Columns are `TEXT` only, with no parsing and no constraints. A new source column means adding it to the `CREATE TABLE` and to the `\copy` column list.
2. **dbo** (`sql/02_dbo/`) holds the treated data, written **only** by stored procedures `dbo.usp_*`.
   - Parse with the `dbo.fn_try_*` and `dbo.fn_conform` helpers. Bad values go to `dbo.etl_reject` with a reason and must never fail the run.
   - Every procedure logs to `dbo.etl_run_log` via `dbo.usp_log_step`.
   - Tables are reloaded with `TRUNCATE` + `INSERT`; never drop them inside a procedure.
   - Derived business metrics are calculated in `dbo` procedures, **not** in views or Metabase.
3. **bi** (`sql/03_bi/`) holds views only. They read `dbo` and keep `fund_code` (and `as_of_date` where relevant). Metabase's `bi_reader` role can see only this schema.
4. **Metabase** is defined as code in `metabase/dashboard.json` plus one `metabase/cards/<key>.sql` per card. Cards query `bi.*` only. Any card SQL that can be filtered by fund must include `[[AND fund_code = {{fund}}]]`. Never edit the dashboard by hand in the UI.
5. Keep the brand palette from `docs/mockup/BRAND.md`: navy `#192C50`, blue `#3D7CC9`, fund series `#3D7CC9` / `#6BBD4A` / `#7D63BD`.

## The SDD workflow (mandatory)

1. **Specify:** copy `specs/_template/spec.md` to `specs/NNN-<slug>/spec.md` and fill it in with the user. Set `Status: Draft`.
2. **Approve:** the human changes the status to `Approved`. **Do not implement while the status is Draft.**
3. **Plan:** write `specs/NNN-<slug>/plan.md` listing every file to change, layer by layer (staging, dbo, bi, tests, Metabase, docs).
4. **Tasks:** write `specs/NNN-<slug>/tasks.md` as a numbered checklist. Every acceptance criterion in the spec must map to at least one task and to one test.
5. **Implement:** follow the tasks in order and tick each one when it is done.
6. **Verify:** run `make pipeline`. All tests must pass, including the new ones. Then run `make dashboard`.
7. **Close:** set the spec to `Status: Done`, and update `docs/DATA_DICTIONARY.md` and `docs/ARCHITECTURE.md`.

## Definition of done for a new column

- [ ] Source column added in `staging` (only if it comes from a source file)
- [ ] Column added to the `dbo` table DDL, with type, nullability and a comment
- [ ] Calculation implemented in the relevant `dbo.usp_*` procedure, with null and edge-case rules exactly as specified
- [ ] Propagated to `dbo.facility_month` (if it is needed per facility and month) and exposed in the relevant `bi` view(s)
- [ ] New test file(s) in `tests/sql/` covering every acceptance criterion
- [ ] Metabase card(s) added in `metabase/cards/` and `metabase/dashboard.json`, with the brand colours
- [ ] `make pipeline` and `make dashboard` both succeed
- [ ] Data dictionary updated

## Commands

`make up` · `make pipeline` (deploy, load, ETL and tests) · `make test` · `make dashboard` · `make psql` · `make reset`
