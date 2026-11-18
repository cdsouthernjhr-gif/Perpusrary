-- =============================================================================
-- Sync push/pull: idempotency, conflicts, barcode collisions, isolation.
-- =============================================================================
begin;
select tests.seed();

create temp table t_ids (k text primary key, v uuid);
insert into t_ids values
  ('dev', gen_random_uuid()),
  ('book', gen_random_uuid()), ('copy1', gen_random_uuid()), ('copy2', gen_random_uuid()),
  ('op1', gen_random_uuid()), ('op2', gen_random_uuid()), ('op3', gen_random_uuid()),
  ('op4', gen_random_uuid()), ('op5', gen_random_uuid()), ('op6', gen_random_uuid()),
  ('op7', gen_random_uuid()), ('op8', gen_random_uuid()), ('op9', gen_random_uuid());
grant select on t_ids to authenticated;
create function pg_temp.v(text) returns uuid language sql as $$ select v from t_ids where k = $1 $$;
create temp table t_res (k text primary key, r jsonb);
grant all on t_res to authenticated;

-- ---------------------------------------------------------------------------
-- Staff registers a book + copy offline, then pushes.
-- ---------------------------------------------------------------------------
select tests.become('staff_a'); set local role authenticated;
insert into public.device_registry (id, user_id, device_name) values (pg_temp.v('dev'), tests.uid('staff_a'), 'Tablet Kaunter');

insert into t_res select 'push1', public.sync_push(tests.id('lib_a'), pg_temp.v('dev'), jsonb_build_array(
  jsonb_build_object('operation_id', pg_temp.v('op1'), 'entity_type', 'books', 'entity_id', pg_temp.v('book'),
    'operation_type', 'insert',
    -- library_id / version / created_by in the payload must be ignored
    'payload', jsonb_build_object('title', 'Sejarah Melayu', 'isbn', '9789830000099',
                                  'library_id', tests.id('lib_b'), 'version', 99, 'created_by', tests.uid('admin_b'))),
  jsonb_build_object('operation_id', pg_temp.v('op2'), 'entity_type', 'book_copies', 'entity_id', pg_temp.v('copy1'),
    'operation_type', 'insert',
    'payload', jsonb_build_object('book_id', pg_temp.v('book'), 'barcode', 'A1000', 'location_id', tests.id('loc_a')),
    'meta', jsonb_build_object('reference_number', 'PO-2026-01', 'remarks', 'Pembelian'))
));
select tests.is((select r #>> '{results,0,status}' from t_res where k = 'push1'), 'applied', 'push: book insert applied');
select tests.is((select r #>> '{results,1,status}' from t_res where k = 'push1'), 'applied', 'push: copy insert applied');
reset role;

select tests.is((select library_id from public.books where id = pg_temp.v('book')), tests.id('lib_a'),
  'push: payload library_id ignored, row stays in library A');
select tests.is((select version from public.books where id = pg_temp.v('book')), 1::bigint,
  'push: payload version ignored (server sets 1)');
select tests.is((select created_by from public.books where id = pg_temp.v('book')), tests.uid('staff_a'),
  'push: created_by forced to caller');
select tests.is((select reference_number from public.stock_movements where copy_id = pg_temp.v('copy1')), 'PO-2026-01',
  'push: acquisition stock movement carries reference number');
select tests.is((select device_id from public.activity_logs where entity_id = pg_temp.v('copy1') and action = 'create'),
  pg_temp.v('dev'), 'push: activity log carries device id');
select tests.ok((select last_seen_at is not null from public.device_registry where id = pg_temp.v('dev')),
  'push: device last_seen_at updated');

-- ---------------------------------------------------------------------------
-- Retry after a dropped connection: same operation ids => no duplicates.
-- ---------------------------------------------------------------------------
select tests.become('staff_a'); set local role authenticated;
insert into t_res select 'push1_retry', public.sync_push(tests.id('lib_a'), pg_temp.v('dev'), jsonb_build_array(
  jsonb_build_object('operation_id', pg_temp.v('op1'), 'entity_type', 'books', 'entity_id', pg_temp.v('book'),
    'operation_type', 'insert', 'payload', jsonb_build_object('title', 'Sejarah Melayu')),
  jsonb_build_object('operation_id', pg_temp.v('op2'), 'entity_type', 'book_copies', 'entity_id', pg_temp.v('copy1'),
    'operation_type', 'insert', 'payload', jsonb_build_object('book_id', pg_temp.v('book'), 'barcode', 'A1000'))
));
select tests.is((select r #>> '{results,0,duplicate}' from t_res where k = 'push1_retry'), 'true',
  'retry: op1 recognised as duplicate');
select tests.is((select r #>> '{results,1,status}' from t_res where k = 'push1_retry'), 'applied',
  'retry: op2 returns stored "applied" result');
reset role;
select tests.is((select count(*) from public.books where id = pg_temp.v('book')), 1::bigint, 'retry: still exactly 1 book');
select tests.is((select count(*) from public.stock_movements where copy_id = pg_temp.v('copy1')), 1::bigint,
  'retry: still exactly 1 stock movement');
select tests.is((select count(*) from public.sync_operations where operation_id in (pg_temp.v('op1'), pg_temp.v('op2'))),
  2::bigint, 'retry: 2 sync_operations rows');

-- ---------------------------------------------------------------------------
-- Barcode collision from another offline device => rejected, clear code.
-- ---------------------------------------------------------------------------
select tests.become('editor_a'); set local role authenticated;
insert into t_res select 'dup_barcode', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', pg_temp.v('op3'), 'entity_type', 'book_copies', 'entity_id', pg_temp.v('copy2'),
    'operation_type', 'insert', 'payload', jsonb_build_object('book_id', pg_temp.v('book'), 'barcode', 'A1000'))
));
select tests.is((select r #>> '{results,0,status}' from t_res where k = 'dup_barcode'), 'rejected',
  'barcode collision: rejected');
select tests.is((select r #>> '{results,0,error_code}' from t_res where k = 'dup_barcode'), 'duplicate_barcode',
  'barcode collision: error_code duplicate_barcode');
reset role;
select tests.is((select count(*) from public.book_copies where id = pg_temp.v('copy2')), 0::bigint,
  'barcode collision: copy not stored');
select tests.is((select sync_status from public.sync_operations where operation_id = pg_temp.v('op3')), 'rejected',
  'barcode collision: recorded as rejected in sync_operations');

-- ---------------------------------------------------------------------------
-- Concurrent edits => conflict, never silent overwrite.
-- ---------------------------------------------------------------------------
select tests.become('editor_a'); set local role authenticated;
insert into t_res select 'edit1', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', pg_temp.v('op4'), 'entity_type', 'books', 'entity_id', pg_temp.v('book'),
    'operation_type', 'update', 'base_version', 1, 'payload', jsonb_build_object('publisher', 'DBP'))
));
select tests.is((select r #>> '{results,0,status}' from t_res where k = 'edit1'), 'applied', 'edit with current version applied');
reset role;
select tests.become('dual'); set local role authenticated;
insert into t_res select 'edit2', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', pg_temp.v('op5'), 'entity_type', 'books', 'entity_id', pg_temp.v('book'),
    'operation_type', 'update', 'base_version', 1, 'payload', jsonb_build_object('publisher', 'Pustaka Lain'))
));
select tests.is((select r #>> '{results,0,status}' from t_res where k = 'edit2'), 'conflict', 'stale edit reported as conflict');
select tests.is((select r #>> '{results,0,server_row,publisher}' from t_res where k = 'edit2'), 'DBP',
  'conflict result includes current server row');
reset role;
select tests.is((select publisher from public.books where id = pg_temp.v('book')), 'DBP', 'stale edit did not overwrite');

-- Staff lacks rights to edit catalog => rejected/forbidden (not "applied").
select tests.become('staff_a'); set local role authenticated;
insert into t_res select 'forbidden', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', pg_temp.v('op6'), 'entity_type', 'books', 'entity_id', pg_temp.v('book'),
    'operation_type', 'update', 'base_version', 2, 'payload', jsonb_build_object('title', 'X'))
));
select tests.is((select r #>> '{results,0,error_code}' from t_res where k = 'forbidden'), 'forbidden',
  'staff catalog edit via sync => forbidden');
-- Malformed op does not break the batch
insert into t_res select 'malformed', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', 'not-a-uuid', 'entity_type', 'books'),
  jsonb_build_object('operation_id', pg_temp.v('op7'), 'entity_type', 'library_members', 'entity_id', gen_random_uuid(),
    'operation_type', 'insert', 'payload', '{}'::jsonb)
));
select tests.is((select r #>> '{results,0,error_code}' from t_res where k = 'malformed'), 'malformed_operation',
  'malformed op rejected');
select tests.is((select r #>> '{results,1,error_code}' from t_res where k = 'malformed'), 'malformed_operation',
  'non-syncable entity (library_members) rejected');
-- Pushing to another library is refused outright
select tests.throws(format('select public.sync_push(%L, null, %L::jsonb)', tests.id('lib_b'), '[]'), '42501',
  'staff_a cannot push into library B');
reset role;

-- Re-using another library's operation_id cannot leak its result.
select tests.become('dual'); set local role authenticated;
insert into t_res select 'opid_reuse', public.sync_push(tests.id('lib_b'), null, jsonb_build_array(
  jsonb_build_object('operation_id', pg_temp.v('op1'), 'entity_type', 'books', 'entity_id', gen_random_uuid(),
    'operation_type', 'insert', 'payload', jsonb_build_object('title', 'X'))
));
select tests.is((select r #>> '{results,0,error_code}' from t_res where k = 'opid_reuse'), 'operation_id_conflict',
  'operation_id from another library => operation_id_conflict');
reset role;

-- ---------------------------------------------------------------------------
-- Soft delete through sync => tombstone-like deleted_at + removal movement.
-- ---------------------------------------------------------------------------
select tests.become('editor_a'); set local role authenticated;
insert into t_res select 'del', public.sync_push(tests.id('lib_a'), null, jsonb_build_array(
  jsonb_build_object('operation_id', pg_temp.v('op8'), 'entity_type', 'book_copies', 'entity_id', pg_temp.v('copy1'),
    'operation_type', 'delete', 'base_version', 1, 'payload', '{}'::jsonb)
));
select tests.is((select r #>> '{results,0,status}' from t_res where k = 'del'), 'applied', 'soft delete applied');
reset role;
select tests.ok((select deleted_at is not null from public.book_copies where id = pg_temp.v('copy1')), 'copy soft-deleted');
select tests.is((select quantity from public.stock_movements where copy_id = pg_temp.v('copy1') and movement_type = 'removal'),
  -1, 'removal movement recorded (-1)');

-- ---------------------------------------------------------------------------
-- Pull: pagination and isolation.
-- ---------------------------------------------------------------------------
select tests.become('viewer_a'); set local role authenticated;
insert into t_res select 'pull1', public.sync_pull(tests.id('lib_a'), 'books', null, null, null, 1);
select tests.is(jsonb_array_length((select r -> 'rows' from t_res where k = 'pull1')), 1, 'pull page size 1');
select tests.is((select r ->> 'has_more' from t_res where k = 'pull1'), 'true', 'pull has_more = true');
insert into t_res select 'pull2', public.sync_pull(tests.id('lib_a'), 'books', null,
  (select r ->> 'last_xid' from t_res where k = 'pull1'), (select (r ->> 'last_id')::uuid from t_res where k = 'pull1'), 100);
select tests.is(jsonb_array_length((select r -> 'rows' from t_res where k = 'pull2')), 1, 'pull page 2 returns the remaining book');
select tests.ok((select r #>> '{rows,0,id}' from t_res where k = 'pull2') <> (select r #>> '{rows,0,id}' from t_res where k = 'pull1'),
  'pull pages do not repeat rows');
select tests.ok(not exists (
  select 1 from t_res, jsonb_array_elements(r -> 'rows') e
  where k in ('pull1', 'pull2') and (e ->> 'library_id')::uuid <> tests.id('lib_a')),
  'pull returns only library A rows');
insert into t_res select 'pull_since', public.sync_pull(tests.id('lib_a'), 'books',
  (select r ->> 'snapshot_xmin' from t_res where k = 'pull1'), null, null, 100);
select tests.ok(jsonb_array_length((select r -> 'rows' from t_res where k = 'pull_since')) <= 2,
  'incremental pull since snapshot_xmin returns at most the rows changed in this tx');
select tests.throws(format('select public.sync_pull(%L, %L)', tests.id('lib_a'), 'library_members'), '22023',
  'pull refuses non-syncable entity types');
reset role;

-- Hard delete by library admin leaves a tombstone for devices.
select tests.become('admin_a'); set local role authenticated;
insert into public.categories (library_id, name) values (tests.id('lib_a'), 'Sementara');
select tests.is(tests.rows_affected(format('delete from public.categories where library_id = %L and name = %L',
  tests.id('lib_a'), 'Sementara')), 1::bigint, 'library admin can hard-delete a category');
select tests.is(tests.count(format('select 1 from public.sync_tombstones where library_id = %L and entity_type = %L',
  tests.id('lib_a'), 'categories')), 1::bigint, 'hard delete produced a sync tombstone');
reset role;

rollback;
