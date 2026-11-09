#!/usr/bin/env bash
# Full database verification: rebuild from migrations, load fixtures,
# then run the integrity, security and concurrency suites.
#
#   ./scripts/db-test.sh                 # against the local dev cluster
#   DATABASE_URL=... ./scripts/db-test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

psql_args=(-q -At)
[[ -n "${DATABASE_URL:-}" ]] && psql_args=("$DATABASE_URL" "${psql_args[@]}")

echo "== Applying migrations =="
./scripts/db-migrate.sh || exit 1

echo
echo "== Loading fixtures =="
psql "${psql_args[@]}" -v ON_ERROR_STOP=1 -f db/tests/00_fixtures.sql >/dev/null || exit 1
echo "  ok"

echo
echo "== Integrity suite =="
psql "${psql_args[@]}" -v ON_ERROR_STOP=1 -f db/tests/01_integrity.sql >/dev/null || exit 1
psql "${psql_args[@]}" -c \
  "SELECT CASE WHEN passed THEN '  PASS  ' ELSE '  FAIL  ' END || suite || ' :: ' || name
          || COALESCE(' -- ' || detail, '') FROM test_results ORDER BY suite, name"
INT_FAIL=$(psql "${psql_args[@]}" -c "SELECT count(*) FROM test_results WHERE NOT passed")
INT_PASS=$(psql "${psql_args[@]}" -c "SELECT count(*) FROM test_results WHERE passed")
echo "Integrity: $INT_PASS passed, $INT_FAIL failed"

echo
echo "== Security suite =="
./scripts/db-test-security.sh; SEC=$?

echo
echo "== Concurrency suite =="
./scripts/db-test-concurrency.sh; CON=$?

echo
echo "=============================================="
if [[ "$INT_FAIL" -eq 0 && "$SEC" -eq 0 && "$CON" -eq 0 ]]; then
  echo "ALL SUITES PASSED"; exit 0
fi
echo "FAILURES PRESENT"; exit 1
