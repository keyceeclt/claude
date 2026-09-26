#!/usr/bin/env bash
# Applies migrations + seed to a throwaway database and runs the test suite.
#   DATABASE_URL set   -> uses that server (creates/drops database kc_crm_test)
#   DATABASE_URL unset -> starts a temporary local PostgreSQL cluster
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DB=kc_crm_test

as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }

if [ -z "${DATABASE_URL:-}" ]; then
    PGBIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
    TMP=$(mktemp -d)
    chmod 777 "$TMP"
    as_pg "$PGBIN/initdb -D $TMP/data -A trust -U postgres >/dev/null"
    as_pg "$PGBIN/pg_ctl -D $TMP/data -o \"-k $TMP -p 55432 -c listen_addresses=''\" -l $TMP/log -w start >/dev/null"
    trap 'as_pg "$PGBIN/pg_ctl -D $TMP/data -m immediate stop" >/dev/null; rm -rf "$TMP"' EXIT
    SERVER_URL="postgresql://postgres@/postgres?host=$TMP&port=55432"
    DB_URL="postgresql://postgres@/$TEST_DB?host=$TMP&port=55432"
else
    SERVER_URL=$DATABASE_URL
    DB_URL=$(python3 -c "import sys,urllib.parse as u;p=u.urlsplit(sys.argv[1]);print(u.urlunsplit(p._replace(path='/$TEST_DB')))" "$DATABASE_URL")
fi

psql "$SERVER_URL" -q -v ON_ERROR_STOP=1 -c "drop database if exists $TEST_DB" -c "create database $TEST_DB"

for f in "$ROOT"/db/migrations/*.sql "$ROOT"/db/seed/*.sql "$ROOT"/db/tests/*.sql; do
    echo "== $(basename "$f")"
    psql "$DB_URL" -q -X -v ON_ERROR_STOP=1 -o /dev/null -f "$f" 2>&1 | sed -E "s/^psql:[^ ]+ NOTICE:  /   /"; test "${PIPESTATUS[0]}" = 0
done

psql "$SERVER_URL" -q -c "drop database $TEST_DB"
echo "All database tests passed."
