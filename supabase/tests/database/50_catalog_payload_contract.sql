-- =============================================================================
-- Contract test: payloads exactly as produced by the app's CatalogDao
-- (lib/data/local/dao/catalog_dao.dart) must be accepted by sync_push.
-- Keep in sync with _bookPayload/_copyPayload/_categoryPayload/_locationPayload.
-- =============================================================================
begin;
select tests.seed();

create temp table t (k text primary key, v uuid default gen_random_uuid());
insert into t (k) values ('cat'), ('loc'), ('book'), ('copy'), ('o1'), ('o2'), ('o3'), ('o4'), ('o5'), ('o6');
grant select on t to authenticated;
create function pg_temp.v(text) returns uuid language sql as $$ select v from t where k = $1 $$;
create temp table r (k text primary key, j jsonb);
grant all on r to authenticated;

select tests.become('editor_a'); set local role authenticated;
insert into r select 'push', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', pg_temp.v('o1'), 'entity_type', 'categories', 'entity_id', pg_temp.v('cat'),
    'operation_type', 'insert', 'base_version', null,
    'payload', jsonb_build_object('name', 'Sastera', 'code', null, 'description', null)),
  jsonb_build_object('operation_id', pg_temp.v('o2'), 'entity_type', 'locations', 'entity_id', pg_temp.v('loc'),
    'operation_type', 'insert', 'base_version', null,
    'payload', jsonb_build_object('building', 'Blok A', 'room', null, 'section', null, 'rack_code', 'R7',
                                  'shelf_code', 'S1', 'description', null)),
  jsonb_build_object('operation_id', pg_temp.v('o3'), 'entity_type', 'books', 'entity_id', pg_temp.v('book'),
    'operation_type', 'insert', 'base_version', null,
    'payload', jsonb_build_object('title', 'Hikayat Hang Tuah', 'subtitle', null, 'isbn', '9789836261234',
      'author', 'Kassim Ahmad', 'publisher', 'DBP', 'publication_year', 1997, 'edition', null, 'language', 'ms',
      'description', null, 'category_id', pg_temp.v('cat'), 'call_number', null,
      'cover_image_path', 'https://books.google.com/x.jpg', 'metadata_source', 'google_books')),
  jsonb_build_object('operation_id', pg_temp.v('o4'), 'entity_type', 'book_copies', 'entity_id', pg_temp.v('copy'),
    'operation_type', 'insert', 'base_version', null,
    'payload', jsonb_build_object('book_id', pg_temp.v('book'), 'barcode', 'LIBA-7F3K-000001',
      'accession_number', null, 'condition', 'new', 'status', 'in_processing', 'location_id', pg_temp.v('loc'),
      'acquisition_date', '2026-03-07', 'acquisition_source', 'donation', 'acquisition_cost', 25.9, 'remarks', null),
    'meta', jsonb_build_object('reference_number', 'PO-1'))
));
select tests.is((select string_agg(e ->> 'status', ',' order by ord)
                 from r, jsonb_array_elements(j -> 'results') with ordinality as x(e, ord) where k = 'push'),
  'applied,applied,applied,applied', 'all four app-shaped inserts applied in FIFO order');
reset role;

select tests.is((select acquisition_cost from public.book_copies where id = pg_temp.v('copy')), 25.90::numeric(12,2),
  'decimal cost stored as numeric(12,2)');
select tests.is((select acquisition_date from public.book_copies where id = pg_temp.v('copy')), date '2026-03-07',
  'ISO date stored as date');
select tests.is((select category_id from public.books where id = pg_temp.v('book')), pg_temp.v('cat'),
  'book linked to category created in the same batch');
select tests.is((select reference_number from public.stock_movements where copy_id = pg_temp.v('copy')), 'PO-1',
  'movement meta forwarded');
select tests.is((select quantity from public.stock_movements where copy_id = pg_temp.v('copy')), 1,
  'in_processing copy counts as in stock');

-- App-shaped update (full writable field set) and soft delete
select tests.become('staff_a'); set local role authenticated;
insert into r select 'upd', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', pg_temp.v('o5'), 'entity_type', 'book_copies', 'entity_id', pg_temp.v('copy'),
    'operation_type', 'update', 'base_version', 1,
    'payload', jsonb_build_object('book_id', pg_temp.v('book'), 'barcode', 'LIBA-7F3K-000001',
      'accession_number', null, 'condition', 'good', 'status', 'available', 'location_id', null,
      'acquisition_date', '2026-03-07', 'acquisition_source', 'donation', 'acquisition_cost', 25.9, 'remarks', 'Siap diproses'))
));
select tests.is((select j #>> '{results,0,status}' from r where k = 'upd'), 'applied',
  'staff full-payload copy update (same barcode/book) is applied');
reset role;
select tests.is((select status from public.book_copies where id = pg_temp.v('copy')), 'available', 'status updated');

select tests.become('editor_a'); set local role authenticated;
insert into r select 'del', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', pg_temp.v('o6'), 'entity_type', 'categories', 'entity_id', pg_temp.v('cat'),
    'operation_type', 'delete', 'base_version', 1, 'payload', '{}'::jsonb)
));
select tests.is((select j #>> '{results,0,status}' from r where k = 'del'), 'applied', 'app-shaped soft delete applied');
reset role;

-- metadata_source accepts every source the app can produce (incl. LoC, 1200)
select tests.become('staff_a'); set local role authenticated;
insert into r select 'loc', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', gen_random_uuid(), 'entity_type', 'books', 'entity_id', gen_random_uuid(),
    'operation_type', 'insert',
    'payload', jsonb_build_object('title', 'Sejarah Melaka', 'isbn', '9789834923129',
      'metadata_source', 'library_of_congress', 'call_number', '959.51'))
));
select tests.is((select j #>> '{results,0,status}' from r where k = 'loc'), 'applied',
  'book with metadata_source library_of_congress is applied');
insert into r select 'badsrc', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', gen_random_uuid(), 'entity_type', 'books', 'entity_id', gen_random_uuid(),
    'operation_type', 'insert', 'payload', jsonb_build_object('title', 'X', 'metadata_source', 'random_site'))
));
select tests.is((select j #>> '{results,0,error_code}' from r where k = 'badsrc'), 'validation_failed',
  'unknown metadata_source is still rejected');
reset role;

rollback;
