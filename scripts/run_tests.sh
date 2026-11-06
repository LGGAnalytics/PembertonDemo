#!/bin/sh
# Each tests/sql/*.sql returns ONE integer: the number of failing rows.
# 0 = pass. Any other value fails the run.
set -eu
cd "$(dirname "$0")/.."
fail=0
for f in tests/sql/*.sql; do
  n=$(psql -X -v ON_ERROR_STOP=1 -qtA -f "$f")
  name=$(basename "$f" .sql)
  if [ "$n" = "0" ]; then echo "    PASS  $name"; else echo "    FAIL  $name  ($n failing rows)"; fail=1; fi
done
[ "$fail" = "0" ] && echo "    All data-quality tests passed." || { echo "    Data-quality tests FAILED."; exit 1; }
