# Demo runbook

**Audience:** investment fund (private credit). **Length:** about 35 minutes plus Q&A.

## Before the meeting (the day before and again 30 minutes before)
- [ ] Docker Desktop running. Run `make reset && make demo` and confirm "All data-quality tests passed" and "Dashboard ready".
- [ ] Open http://localhost:3000 and log in as `admin@demo.local` / `Demo-Passw0rd!`. Open the "Direct Lending Portfolio Monitor" dashboard.
- [ ] Prepare four tabs: the dashboard, the repo in an editor, a terminal at the repo root, and Claude Code.
- [ ] `specs/001-net-leverage/spec.md` is at **Status: Draft**, and git is clean on a fresh branch (`git switch -c demo/net-leverage`).
- [ ] Fallback: the `demo/net-leverage-rehearsal` branch holds the finished change, and `docs/screenshots/` holds a static image.

## Part 1: the pipeline and dashboard (about 15 minutes)

| Time | Show | Talking points |
|---|---|---|
| 0:00 | `docs/mockup/dashboard_mockup.png` | The target: a standard portfolio monitoring pack, in your colours. |
| 0:02 | `data/raw/facilities.csv` | Real extracts are messy: mixed date formats, `"12,500,000.00"`, `gbp`, duplicates, one row with 30 February. |
| 0:04 | `sql/01_staging/01_create_staging_tables.sql` | Layer 1 lands everything as text, with lineage columns. Nothing is lost. |
| 0:06 | `sql/02_dbo/13_usp_load_facility.sql` | Layer 2 is stored procedures: parse, conform, dedupe, and send rejects to `dbo.etl_reject` with a reason. |
| 0:08 | Terminal: `make pipeline` | Live log: read, loaded and rejected counts per procedure, then 9 tests pass. |
| 0:10 | `make psql`, then `SELECT reason, raw_record FROM dbo.etl_reject;` | Auditability: you can see exactly why a row was rejected. |
| 0:11 | `sql/03_bi/01_create_bi_views.sql` | Layer 3: Metabase can only see these views (least privilege). |
| 0:12 | Metabase dashboard | KPIs with month-on-month change, then trend, concentration, rating mix and watchlist. Switch the **Fund** filter to SCF-I. Show the pipeline health card. |

## Part 2: a new column built with AI from a spec (about 20 minutes)

| Time | Step | Prompt or action |
|---|---|---|
| 0:15 | Show `CLAUDE.md` | "The AI follows our engineering rules, and there's no code without an approved spec." |
| 0:16 | Show `specs/001-net-leverage/spec.md` | Walk through the definition, edge cases and acceptance criteria. Change `Status: Draft` to **`Approved`** live. |
| 0:18 | Claude Code | **Prompt A:** *"Read CLAUDE.md and specs/001-net-leverage/spec.md. Write plan.md and tasks.md for this spec. Don't change code yet."* |
| 0:21 | Review the plan | Point out that it touches every layer: dbo DDL, two procedures, three views, tests, cards, docs. |
| 0:22 | Claude Code | **Prompt B:** *"Implement tasks.md in order. Add one test per acceptance criterion. Run make pipeline until all tests pass, then make dashboard."* |
| 0:30 | Terminal and dashboard | New tests t10+ pass. Refresh Metabase: a new "Net leverage" tile, an exposure-by-leverage-band chart, and leverage in the watchlist. |
| 0:32 | `git diff --stat` | Every change is reviewable, tested and documented. Optionally open a PR. |

## If something goes wrong
- **The AI run is slow or fails:** `git switch demo/net-leverage-rehearsal && make pipeline && make dashboard`.
- **Metabase isn't healthy:** `docker compose restart metabase` (about 60 seconds), or show `docs/screenshots/metabase_dashboard.png`.
- **The port is taken:** set `MB_PORT=3001` or `PG_PORT=5433` in `.env`.

## Likely questions
- *Why stored procedures?* They're testable and auditable, they run in the database, they're familiar to SQL teams, and they're transactional (all or nothing).
- *Production?* Incremental `MERGE` loads, a scheduler, migrations, and SSO on Metabase. The layer contract stays the same.
- *Is the data real?* No. It's fully synthetic: generated, deterministic and with no real companies.
