#!/bin/sh
# Each <dir>/*.sql returns ONE integer (its last result): the number of failing rows.
# 0 = pass. Any other value fails the run.   Usage: run_tests.sh [tests/sql]
set -eu
cd "$(dirname "$0")/.."
dir="${1:-tests/sql}"
fail=0
for f in "$dir"/*.sql; do
  n=$(psql -X -v ON_ERROR_STOP=1 -qtA -f "$f" | tail -n 1)
  name=$(basename "$f" .sql)
  if [ "$n" = "0" ]; then echo "    PASS  $name"; else echo "    FAIL  $name  ($n failing rows)"; fail=1; fi
done
[ "$fail" = "0" ] && echo "    All data-quality tests passed ($dir)." || { echo "    Data-quality tests FAILED ($dir)."; exit 1; }
