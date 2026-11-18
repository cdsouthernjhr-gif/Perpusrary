-- =============================================================================
-- Phase 7: restore_library_backup
-- =============================================================================
begin;
select tests.seed();

-- Build a backup of library A from its current rows (what the app does via sync_pull).
create temp table bk (j jsonb);
insert into bk select jsonb_build_object(
  'format', 'smartlibrary-backup', 'version', 1, 'created_at', '2026-11-18T10:00:00Z',
  'library', jsonb_build_object('id', tests.id('lib_a'), 'code', 'LIBA'),
  'data', jsonb_build_object(
    'categories',  (select jsonb_agg(to_jsonb(x)) from public.categories x where library_id = tests.id('lib_a')),
    'locations',   (select jsonb_agg(to_jsonb(x)) from public.locations x where library_id = tests.id('lib_a')),
    'books',       (select jsonb_agg(to_jsonb(x)) from public.books x where library_id = tests.id('lib_a')),
    'book_copies', (select jsonb_agg(to_jsonb(x)) from public.book_copies x where library_id = tests.id('lib_a'))));
grant select on bk to authenticated;
create temp table res (k text primary key, j jsonb);
grant all on res to authenticated;

-- Damage library A after the backup: rename, mark lost, add a new book, hard-delete the category.
update public.books set title = 'ROSAK' where id = tests.id('book_a');
update public.book_copies set status = 'lost' where id = tests.id('copy_a');
insert into public.books (library_id, title) values (tests.id('lib_a'), 'Ditambah selepas backup');
update public.books set category_id = null where id = tests.id('book_a');
delete from public.categories where id = tests.id('cat_a');

-- Non-admins and other libraries' admins are refused
select tests.become('editor_a'); set local role authenticated;
select tests.throws(format('select public.restore_library_backup(%L, (select j from bk))', tests.id('lib_a')), '42501',
  'editor cannot restore');
reset role;
select tests.become('admin_b'); set local role authenticated;
select tests.throws(format('select public.restore_library_backup(%L, (select j from bk))', tests.id('lib_a')), '42501',
  'admin of library B cannot restore library A');
-- A backup of A can never be restored into B
select tests.throws(format('select public.restore_library_backup(%L, (select j from bk))', tests.id('lib_b')), '22023',
  'backup of A refused for library B');
-- Rows smuggled in with another library_id are refused
select tests.throws(format('select public.restore_library_backup(%L, %L::jsonb)', tests.id('lib_b'),
  (select jsonb_set(jsonb_set(j, '{library,id}', to_jsonb(tests.id('lib_b')::text)), '{data,books,0,library_id}',
                    to_jsonb(tests.id('lib_b')::text)) from bk)), '22023',
  'rows with a foreign library_id are refused');
reset role;

select tests.become('admin_a'); set local role authenticated;
select tests.throws(format('select public.restore_library_backup(%L, %L::jsonb)', tests.id('lib_a'),
  (select jsonb_set(j, '{format}', '"other"') from bk)), '22023', 'unknown format refused');
select tests.throws(format('select public.restore_library_backup(%L, %L::jsonb)', tests.id('lib_a'),
  (select jsonb_set(j, '{data,books}', '[]') from bk)), '23503', 'copy without its book in the backup refused');
select tests.throws(format('select public.restore_library_backup(%L, %L::jsonb)', tests.id('lib_a'),
  (select jsonb_set(j, '{data,book_copies}', (j #> '{data,book_copies}') || jsonb_set(j #> '{data,book_copies,0}', '{id}',
     to_jsonb(gen_random_uuid()::text))) from bk)), '23505', 'duplicate barcode inside the backup refused');

insert into res select 'ok', public.restore_library_backup(tests.id('lib_a'), (select j from bk), false);
reset role;

select tests.is((select title from public.books where id = tests.id('book_a')), 'Hikayat Hang Tuah', 'title restored');
select tests.is((select category_id from public.books where id = tests.id('book_a')), tests.id('cat_a'),
  'hard-deleted category re-created with the same id');
select tests.is((select status from public.book_copies where id = tests.id('copy_a')), 'available', 'copy status restored');
select tests.is((select count(*) from public.books where title = 'Ditambah selepas backup' and deleted_at is null),
  1::bigint, 'without delete_missing, newer records are kept');
select tests.is((select count(*) from public.sync_tombstones where entity_id = tests.id('cat_a')), 0::bigint,
  'tombstone of the restored category removed');
select tests.is((select reference_number from public.stock_movements where copy_id = tests.id('copy_a')
                 order by created_at desc limit 1), 'Restore backup 2026-11-18T10:00:00Z',
  'restore recorded as a stock movement with reference');
select tests.is((select (j #>> '{restored,categories,inserted}')::int from res where k = 'ok'), 1, 'category counted as inserted');
select tests.is((select (j #>> '{restored,locations,updated}')::int from res where k = 'ok'), 0, 'unchanged rows not touched');

-- Restoring the same backup again changes nothing
select tests.become('admin_a'); set local role authenticated;
insert into res select 'again', public.restore_library_backup(tests.id('lib_a'), (select j from bk), true);
reset role;
select tests.is((select (j #>> '{restored,books,updated}')::int + (j #>> '{restored,books,inserted}')::int
                 from res where k = 'again'), 0, 'second restore of the same backup: no book changes');
select tests.is((select deleted_at is not null from public.books where title = 'Ditambah selepas backup'), true,
  'delete_missing soft-deletes records that are not in the backup');
select tests.is((select count(*) from public.books where library_id = tests.id('lib_b') and deleted_at is null), 1::bigint,
  'library B untouched');

-- Inactive library cannot be restored by its admin
select tests.clear_claims();
update public.libraries set status = 'inactive' where id = tests.id('lib_a');
select tests.become('admin_a'); set local role authenticated;
select tests.throws(format('select public.restore_library_backup(%L, (select j from bk))', tests.id('lib_a')), '42501',
  'inactive library cannot be restored by its admin');
reset role;

rollback;
