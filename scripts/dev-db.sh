#!/usr/bin/env bash
# Start a throwaway local PostgreSQL 16 cluster for development and CI.
# Not for production -- production runs on Supabase/managed Postgres.
set -euo pipefail

PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
PGDATA="${PGDATA:-/var/lib/postgresql/hotel-erp/pgdata}"
PGPORT="${PGPORT:-5433}"
SOCKDIR="$(dirname "$PGDATA")"

case "${1:-start}" in
  start)
    if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
      mkdir -p "$PGDATA"
      # initdb refuses to run as root, so drop to the postgres account.
      if [[ "$(id -u)" -eq 0 ]]; then
        chmod 755 "$SOCKDIR"; chown -R postgres:postgres "$PGDATA"
        su postgres -c "$PGBIN/initdb -D $PGDATA -U postgres --auth=trust -E UTF8" >/dev/null
      else
        "$PGBIN/initdb" -D "$PGDATA" -U postgres --auth=trust -E UTF8 >/dev/null
      fi
    fi
    RUN="$PGBIN/pg_ctl -D $PGDATA -l $SOCKDIR/pg.log -o '-p $PGPORT -k $SOCKDIR' start"
    if [[ "$(id -u)" -eq 0 ]]; then su postgres -c "$RUN"; else eval "$RUN"; fi
    sleep 1
    PGHOST="$SOCKDIR" psql -p "$PGPORT" -U postgres -d postgres -c "SELECT 1" >/dev/null \
      && echo "PostgreSQL up on port $PGPORT (socket $SOCKDIR)"
    echo "  export PGHOST=$SOCKDIR PGPORT=$PGPORT PGUSER=postgres PGDATABASE=erp"
    ;;
  stop)
    RUN="$PGBIN/pg_ctl -D $PGDATA stop"
    if [[ "$(id -u)" -eq 0 ]]; then su postgres -c "$RUN"; else eval "$RUN"; fi
    ;;
  reset)
    PGHOST="$SOCKDIR" psql -p "$PGPORT" -U postgres -d postgres \
      -c "DROP DATABASE IF EXISTS erp" -c "CREATE DATABASE erp" >/dev/null
    echo "Database 'erp' recreated."
    ;;
  *) echo "usage: $0 {start|stop|reset}"; exit 1 ;;
esac
