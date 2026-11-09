#!/bin/sh
# =============================================================================
# Incremental run (after a full `make pipeline`):
#   1. append the delta extracts to staging (no truncate)
#   2. CALL dbo.usp_run_etl('incremental')  -> only the changed periods are rebuilt
#   3. full-mode tests + incremental tests (tests/incremental)
# =============================================================================
set -eu
cd "$(dirname "$0")/.."
PSQL="psql -X -v ON_ERROR_STOP=1 -q"
export PGOPTIONS="-c client_min_messages=warning"

echo "==> [1/3] Appending delta extracts to staging"
$PSQL -f sql/01_staging/11_load_delta.sql

echo "==> [2/3] Running ETL procedures: CALL dbo.usp_run_etl('incremental')"
$PSQL -c "CALL dbo.usp_run_etl('incremental');"

echo "==> [3/3] Data-quality tests (incremental assertions first: t15 rebuilds periods and would mask them)"
sh scripts/run_tests.sh tests/incremental
sh scripts/run_tests.sh tests/sql
