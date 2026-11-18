#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Real multi-session concurrency tests (two simultaneous DB connections).
# Requires the schema + tests helpers installed (run via scripts/db_test.sh,
# which calls this before dropping the helpers).
#
#   C1: two users save the SAME barcode at the same time -> exactly one wins,
#       the other gets unique_violation (23505).
#   C2: the SAME sync operation_id pushed twice at the same time (retry storm)
#       -> applied exactly once.
#   C3: 2 users x 25 different copies registered concurrently -> all 50 stored.
# -----------------------------------------------------------------------------
set -euo pipefail
TEST_DB="${TEST_DB:-slm_test}"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1 -d "$TEST_DB")
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "not ok - $*"; cleanup; exit 1; }
ok()   { echo "ok - $*"; }

cleanup() {
  "${PSQL[@]}" >/dev/null <<'SQL' || true
delete from public.libraries where id in (select id from tests.ids where key like 'lib_%');
delete from auth.users where email like '%@test.local';
SQL
}

# Committed fixture (the concurrent sessions must see it).
"${PSQL[@]}" -c "select tests.seed()" >/dev/null
LIB_A="$("${PSQL[@]}" -c "select tests.id('lib_a')")"
BOOK_A="$("${PSQL[@]}" -c "select tests.id('book_a')")"

as_user() {  # $1 alias, stdin = SQL
  { echo "begin;"
    echo "select tests.become('$1');"
    echo "set local role authenticated;"
    cat
    echo "commit;"; } | "${PSQL[@]}" 2>&1
}

# ---------------------------------------------------------------- C1 --------
( as_user staff_a > "$TMP/c1_a" <<SQL || true
insert into public.book_copies (library_id, book_id, barcode) values ('$LIB_A', '$BOOK_A', 'RACE-0001');
select pg_sleep(1.5);
SQL
) &
P1=$!
sleep 0.4
( as_user editor_a > "$TMP/c1_b" <<SQL || true
insert into public.book_copies (library_id, book_id, barcode) values ('$LIB_A', '$BOOK_A', 'RACE-0001');
SQL
) &
P2=$!
wait $P1 $P2 || true
n="$("${PSQL[@]}" -c "select count(*) from public.book_copies where library_id = '$LIB_A' and barcode = 'RACE-0001'")"
[[ "$n" == "1" ]] || fail "C1 expected exactly 1 copy with barcode RACE-0001, got $n"
grep -q "book_copies_library_barcode_key" "$TMP/c1_b" || fail "C1 second writer did not get a unique violation: $(cat "$TMP/c1_b")"
ok "C1 concurrent duplicate barcode: first writer wins, second gets unique_violation"

# ---------------------------------------------------------------- C2 --------
OPID="$(cat /proc/sys/kernel/random/uuid)"
COPY="$(cat /proc/sys/kernel/random/uuid)"
OPS="[{\"operation_id\":\"$OPID\",\"entity_type\":\"book_copies\",\"entity_id\":\"$COPY\",\"operation_type\":\"insert\",\"payload\":{\"book_id\":\"$BOOK_A\",\"barcode\":\"RACE-0002\"}}]"
for i in 1 2 3; do
  ( as_user staff_a > "$TMP/c2_$i" <<SQL || true
select public.sync_push('$LIB_A', null, '$OPS'::jsonb);
select pg_sleep(0.5);
SQL
  ) &
done
wait || true
n="$("${PSQL[@]}" -c "select count(*) from public.book_copies where id = '$COPY'")"
m="$("${PSQL[@]}" -c "select count(*) from public.stock_movements where copy_id = '$COPY'")"
s="$("${PSQL[@]}" -c "select count(*) from public.sync_operations where operation_id = '$OPID'")"
[[ "$n" == "1" && "$m" == "1" && "$s" == "1" ]] || fail "C2 expected 1/1/1 (copy/movement/op), got $n/$m/$s"
dups="$(grep -c '"duplicate": true' "$TMP"/c2_* | awk -F: '{s+=$2} END {print s}')"
[[ "$dups" == "2" ]] || fail "C2 expected 2 responses flagged duplicate, got $dups"
ok "C2 same operation_id pushed 3x concurrently: applied once, 2 duplicates"

# ---------------------------------------------------------------- C3 --------
for who in staff_a editor_a; do
  ( for i in $(seq 1 25); do
      echo "insert into public.book_copies (library_id, book_id, barcode) values ('$LIB_A', '$BOOK_A', 'BULK-$who-$i');"
    done | as_user "$who" > "$TMP/c3_$who" ) &
done
wait
n="$("${PSQL[@]}" -c "select count(*) from public.book_copies where library_id = '$LIB_A' and barcode like 'BULK-%'")"
[[ "$n" == "50" ]] || fail "C3 expected 50 copies, got $n"
m="$("${PSQL[@]}" -c "select count(*) from public.stock_movements sm join public.book_copies c on c.id = sm.copy_id where c.barcode like 'BULK-%'")"
[[ "$m" == "50" ]] || fail "C3 expected 50 stock movements, got $m"
ok "C3 two users registering 25 copies each concurrently: 50 copies, 50 movements"

cleanup
echo "PASS  concurrency"
