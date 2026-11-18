#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Server performance check at "10,000+ titles" scale, with RLS active.
#
#   PGHOST=... PGPORT=... PGUSER=postgres ./scripts/perf_test.sh
#
# Creates a scratch database (perf_test), applies stub + migrations, seeds
# 2 libraries × 12,000 titles × 20,000 copies (+ ledger rows via triggers),
# then times the hot API paths as an authenticated library member and fails
# if any exceeds its budget. Prints the plans of the slowest queries.
# -----------------------------------------------------------------------------
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${PERF_DB:-perf_test}"
TITLES="${PERF_TITLES:-12000}"
COPIES="${PERF_COPIES:-20000}"
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

"${PSQL[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB"
"${PSQL[@]}" -d "$DB" -f "$ROOT/supabase/tests/local_stub/supabase_stub.sql" >/dev/null
for f in "$ROOT"/supabase/migrations/*.sql; do "${PSQL[@]}" -d "$DB" -f "$f" >/dev/null; done
"${PSQL[@]}" -d "$DB" -f "$ROOT/supabase/tests/helpers/test_helpers.sql" >/dev/null

echo "Seeding 2 × $TITLES titles, 2 × $COPIES copies …"
start=$(date +%s)
"${PSQL[@]}" -d "$DB" <<SQL
select tests.seed();
do \$\$
declare lib uuid; cat uuid; loc uuid;
begin
  foreach lib in array array[tests.id('lib_a'), tests.id('lib_b')] loop
    select id into cat from public.categories where library_id = lib limit 1;
    select id into loc from public.locations where library_id = lib limit 1;
    insert into public.books (library_id, title, author, isbn, publisher, publication_year, category_id)
    select lib,
           (array['Sejarah','Asas','Pengenalan','Kamus','Hikayat','Teknologi','Sains','Matematik'])[1 + g % 8]
             || ' ' || md5(g::text || lib::text)::text,
           'Pengarang ' || (g % 900), lpad((9789830000000 + g)::text, 13, '0'), 'Penerbit ' || (g % 40),
           1950 + g % 75, case when g % 3 = 0 then cat end
    from generate_series(1, $TITLES) g;
    insert into public.book_copies (library_id, book_id, barcode, location_id, status)
    select lib, b.id, 'P' || substr(lib::text, 1, 4) || '-' || lpad(n::text, 7, '0'), loc,
           (array['available','available','available','in_processing','damaged','lost'])[1 + n % 6]
    from (select id, row_number() over (order by id) rn from public.books where library_id = lib) b
    join generate_series(1, $COPIES) n on b.rn = 1 + (n % $TITLES);
  end loop;
end \$\$;
analyze;
SQL
echo "Seeded in $(( $(date +%s) - start )) s: $("${PSQL[@]}" -At -d "$DB" -c "select count(*) from public.books") books, $("${PSQL[@]}" -At -d "$DB" -c "select count(*) from public.book_copies") copies, $("${PSQL[@]}" -At -d "$DB" -c "select count(*) from public.stock_movements") ledger rows"

# name | budget ms | sql (runs as staff_a of library A)
CASES=(
  "count titles (RLS)|300|select count(*) from public.books"
  "search title (trigram, RLS)|300|select id, title from public.books where title ilike '%sejarah 1a%' order by title limit 50"
  "lookup barcode (RLS)|50|select * from public.book_copies where library_id = tests.id('lib_a') and barcode = 'P' || substr(tests.id('lib_a')::text,1,4) || '-0012345'"
  "sync_pull books page 500|300|select public.sync_pull(tests.id('lib_a'), 'books', null, null, null, 500)"
  "sync_pull copies page 500|300|select public.sync_pull(tests.id('lib_a'), 'book_copies', null, null, null, 500)"
  "sync_pull incremental (no changes)|100|select public.sync_pull(tests.id('lib_a'), 'book_copies', (pg_snapshot_xmin(pg_current_snapshot()))::text, null, null, 500)"
  "library_dashboard|800|select public.library_dashboard(tests.id('lib_a'))"
  "my_libraries|300|select * from public.my_libraries()"
  "find_possible_duplicate_books|500|select * from public.find_possible_duplicate_books(tests.id('lib_a'), '9789830005000', 'Sejarah Melayu', 'Pengarang 1')"
  "sync_push 200 inserts|2000|select public.sync_push(tests.id('lib_a'), null, (select jsonb_agg(jsonb_build_object('operation_id', gen_random_uuid(), 'entity_type', 'books', 'entity_id', gen_random_uuid(), 'operation_type', 'insert', 'payload', jsonb_build_object('title', 'Perf ' || g))) from generate_series(1,200) g))"
)

failed=0
printf "\n%-38s %10s %10s\n" "case" "ms" "budget"
for c in "${CASES[@]}"; do
  IFS='|' read -r name budget sql <<< "$c"
  ms="$("${PSQL[@]}" -At -d "$DB" <<SQL | tail -1
begin;
select tests.become('staff_a');
set local role authenticated;
$sql;  -- warm-up
create temp table _t on commit drop as select clock_timestamp() t0;
$sql;
select round(extract(epoch from clock_timestamp() - (select t0 from _t)) * 1000);
rollback;
SQL
)"
  status=ok
  if [ "${ms%.*}" -gt "$budget" ]; then status=SLOW; failed=1; fi
  printf "%-38s %10s %10s  %s\n" "$name" "$ms" "$budget" "$status"
done

"${PSQL[@]}" -d postgres -c "drop database if exists $DB" >/dev/null
exit $failed
