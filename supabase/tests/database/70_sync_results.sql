-- =============================================================================
-- Phase 6: rejected operations carry the current server row (for "discard").
-- =============================================================================
begin;
select tests.seed();
create temp table r (k text primary key, j jsonb);
grant all on r to authenticated;

select tests.become('staff_a'); set local role authenticated;
insert into r select 'forbidden', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', gen_random_uuid(), 'entity_type', 'books', 'entity_id', tests.id('book_a'),
    'operation_type', 'update', 'base_version', 1, 'payload', jsonb_build_object('title', 'X'))));
select tests.is((select j #>> '{results,0,error_code}' from r where k = 'forbidden'), 'forbidden', 'staff edit forbidden');
select tests.is((select j #>> '{results,0,server_row,title}' from r where k = 'forbidden'), 'Hikayat Hang Tuah',
  'rejected result includes current server row');

insert into r select 'dup', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', gen_random_uuid(), 'entity_type', 'book_copies', 'entity_id', gen_random_uuid(),
    'operation_type', 'insert', 'payload', jsonb_build_object('book_id', tests.id('book_a'), 'barcode', 'A0001'))));
select tests.is((select j #>> '{results,0,error_code}' from r where k = 'dup'), 'duplicate_barcode', 'duplicate barcode');
select tests.ok((select (j #> '{results,0,server_row}') is null or (j #> '{results,0,server_row}') = 'null'::jsonb
                 from r where k = 'dup'), 'rejected insert has no server row (record never existed)');
reset role;

-- Other library's rows are never leaked through server_row.
select tests.become('dual'); set local role authenticated;
insert into r select 'leak', public.sync_push(tests.id('lib_b'), null, jsonb_build_array(
  jsonb_build_object('operation_id', gen_random_uuid(), 'entity_type', 'books', 'entity_id', tests.id('book_a'),
    'operation_type', 'update', 'base_version', 1, 'payload', jsonb_build_object('title', 'X'))));
select tests.is((select j #>> '{results,0,error_code}' from r where k = 'leak'), 'not_found',
  'book of library A addressed through library B is not found');
select tests.ok((select (j #> '{results,0,server_row}') is null or (j #> '{results,0,server_row}') = 'null'::jsonb
                 from r where k = 'leak'), 'no cross-library row leaked');
reset role;

select tests.is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'sync_push_core'), 0::bigint,
  'core push function is not exposed in public');
rollback;
