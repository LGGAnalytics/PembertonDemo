#!/bin/sh
# =============================================================================
# End-to-end pipeline (POSIX sh, runs inside the postgres image or on a host
# with psql). Must be run from the repository root.
#
#   1. deploy   : reset + create staging tables, dbo tables/functions/procedures, bi views
#   2. stage    : \copy the original CSV extracts into staging (as-is)
#   3. etl      : CALL dbo.usp_run_etl()  -> staging -> dbo
#   4. test     : data-quality tests in tests/sql
# Connection comes from the standard PG* environment variables.
# =============================================================================
set -eu
cd "$(dirname "$0")/.."
PSQL="psql -X -v ON_ERROR_STOP=1 -q"
export PGOPTIONS="-c client_min_messages=warning"

echo "==> [1/4] Deploying schema objects (staging, dbo, bi)"
$PSQL -f sql/00_reset.sql
for f in sql/01_staging/0*.sql sql/02_dbo/*.sql sql/03_bi/*.sql; do
  echo "    - $f"
  $PSQL -f "$f"
done

echo "==> [2/4] Loading original extracts into staging"
$PSQL -f sql/01_staging/10_load_staging.sql

echo "==> [3/4] Running ETL procedures: CALL dbo.usp_run_etl()"
PGOPTIONS="-c client_min_messages=warning" $PSQL -c "CALL dbo.usp_run_etl();"

echo "==> [4/4] Data-quality tests"
sh scripts/run_tests.sh
