#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# End-to-end sync engine tests: Dart SyncEngine + Drift on "devices" talking to
# a real PostgreSQL with all migrations (via the same RPCs as PostgREST).
#
#   PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres ./scripts/sync_integration_test.sh
#
# Requires TCP access to PostgreSQL and `flutter` on PATH (or FLUTTER=...).
# -----------------------------------------------------------------------------
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DB="${TEST_DB:-slm_sync_test}"
FLUTTER="${FLUTTER:-flutter}"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

"${PSQL[@]}" -d postgres -c "drop database if exists ${TEST_DB}" -c "create database ${TEST_DB}"
"${PSQL[@]}" -d "$TEST_DB" -f "$ROOT/supabase/tests/local_stub/supabase_stub.sql" >/dev/null
for f in "$ROOT"/supabase/migrations/*.sql; do "${PSQL[@]}" -d "$TEST_DB" -f "$f" >/dev/null; done
"${PSQL[@]}" -d "$TEST_DB" -f "$ROOT/supabase/tests/helpers/test_helpers.sql" >/dev/null

cd "$ROOT"
SLM_PG_HOST="${PGHOST:-127.0.0.1}" SLM_PG_PORT="${PGPORT:-5432}" SLM_PG_DB="$TEST_DB" \
SLM_PG_USER="${PGUSER:-postgres}" SLM_PG_PASSWORD="${PGPASSWORD:-}" \
  "$FLUTTER" test test/integration/sync_engine_pg_test.dart --concurrency=1 --timeout 120s
