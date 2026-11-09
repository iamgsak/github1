#!/usr/bin/env bash
# Apply every migration in order against $DATABASE_URL (or the local dev
# cluster). Stops at the first failing statement and exits non-zero.
set -euo pipefail

MIGRATIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../db/migrations" && pwd)"
PSQL_ARGS=(-v ON_ERROR_STOP=1 -q --single-transaction)

if [[ -n "${DATABASE_URL:-}" ]]; then
  TARGET=("$DATABASE_URL")
else
  TARGET=(-d "${PGDATABASE:-erp}")
fi

for f in "$MIGRATIONS_DIR"/*.sql; do
  printf '  applying %-45s' "$(basename "$f")"
  if psql "${TARGET[@]}" "${PSQL_ARGS[@]}" -f "$f" >/dev/null 2>/tmp/migrate_err; then
    echo 'ok'
  else
    echo 'FAILED'
    cat /tmp/migrate_err >&2
    exit 1
  fi
done
echo "All migrations applied."
