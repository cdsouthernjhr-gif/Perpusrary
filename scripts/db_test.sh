#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Runs SmartLibrary database migrations + RLS/security tests against a plain
# PostgreSQL 15+ server, using the local Supabase stub.
#
#   PGHOST=... PGPORT=... PGUSER=postgres ./scripts/db_test.sh
#
# What it does:
#   1. drops & recreates database $TEST_DB (default slm_test)
#   2. applies supabase/tests/local_stub/supabase_stub.sql
#   3. applies every migration in supabase/migrations TWICE (idempotency check)
#   4. runs every supabase/tests/database/*.sql test file
#
# Against a real local Supabase stack (`supabase start`) skip the stub:
#   SKIP_STUB=1 SKIP_RESET=1 PGHOST=127.0.0.1 PGPORT=54322 PGUSER=postgres \
#     PGPASSWORD=postgres TEST_DB=postgres ./scripts/db_test.sh
# (the tests create and clean up their own users/libraries).
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DB="${TEST_DB:-slm_test}"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

if [[ "${SKIP_RESET:-0}" != "1" ]]; then
  "${PSQL[@]}" -d postgres -c "drop database if exists ${TEST_DB}" -c "create database ${TEST_DB}"
fi

if [[ "${SKIP_STUB:-0}" != "1" ]]; then
  "${PSQL[@]}" -d "$TEST_DB" -f "$ROOT/supabase/tests/local_stub/supabase_stub.sql" >/dev/null
fi

for pass in 1 2; do
  for f in "$ROOT"/supabase/migrations/*.sql; do
    "${PSQL[@]}" -d "$TEST_DB" -f "$f" >/dev/null
  done
  echo "migrations: pass $pass OK"
done

"${PSQL[@]}" -d "$TEST_DB" -f "$ROOT/supabase/tests/helpers/test_helpers.sql" >/dev/null

failed=0
for t in "$ROOT"/supabase/tests/database/*.sql; do
  name="$(basename "$t")"
  # Assertions report through RAISE WARNING so they show at client_min_messages=warning.
  if out="$("${PSQL[@]}" -d "$TEST_DB" -f "$t" 2>&1)"; then
    echo "$out" | sed -n 's/.*WARNING:  //p'
    echo "PASS  $name"
  else
    echo "$out"
    echo "FAIL  $name"
    failed=1
  fi
done

if [[ "${SKIP_CONCURRENCY:-0}" != "1" ]]; then
  TEST_DB="$TEST_DB" "$ROOT/scripts/db_concurrency_test.sh" || failed=1
fi

"${PSQL[@]}" -d "$TEST_DB" -c "drop schema if exists tests cascade" >/dev/null
exit $failed
