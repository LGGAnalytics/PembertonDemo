# Direct Lending demo: staging -> dbo (stored procedures) -> bi (views) -> Metabase
.PHONY: help up pipeline incremental test dashboard demo psql logs down reset generate

help:            ## list targets
	@grep -E '^[a-z]+:.*##' Makefile | sed 's/:.*##/\t/'

up:              ## start Postgres + Metabase
	docker compose up -d postgres metabase

pipeline:        ## deploy all SQL, load staging, CALL dbo.usp_run_etl(), run tests
	docker compose --profile pipeline run --rm pipeline

incremental:     ## append data/raw/delta to staging and CALL dbo.usp_run_etl('incremental'), then tests
	docker compose --profile pipeline run --rm --entrypoint sh pipeline /workspace/scripts/run_incremental.sh

test:            ## run only the data-quality tests
	docker compose --profile pipeline run --rm --entrypoint sh pipeline /workspace/scripts/run_tests.sh

dashboard:       ## (re)build the Metabase dashboard from metabase/dashboard.json
	python3 metabase/setup_metabase.py

demo: up pipeline dashboard  ## everything, from zero to dashboard

psql:            ## open a SQL prompt on the warehouse
	docker exec -it credit-dw-postgres psql -U dw_admin -d credit_dw

logs:            ## follow Metabase logs
	docker compose logs -f metabase

down:            ## stop containers (keeps data)
	docker compose down

reset:           ## stop and DELETE all data (Postgres + Metabase app DB)
	docker compose down -v

generate:        ## regenerate the synthetic source extracts (deterministic, seed 42)
	python3 data/generator/generate_data.py
