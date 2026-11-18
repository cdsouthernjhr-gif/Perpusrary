-- =============================================================================
-- Inventory ledger (server trigger) — same cases as the app's copyMovement()
-- in test/unit/inventory_test.dart, so device-side provisional movements and
-- server movements always agree. Also: reference/remarks, permissions,
-- immutability, deletion of the last copy.
-- =============================================================================
begin;
select tests.seed();

-- Fresh copies so earlier fixture movements don't interfere.
create temp table c (k text primary key, id uuid default gen_random_uuid());
insert into c (k) values ('avail'), ('dmg'), ('l1'), ('l2');
grant select on c to authenticated;
create function pg_temp.c(text) returns uuid language sql as $$ select id from c where k = $1 $$;
insert into public.locations (id, library_id, rack_code) values
  (pg_temp.c('l1'), tests.id('lib_a'), 'INV1'), (pg_temp.c('l2'), tests.id('lib_a'), 'INV2');

create function pg_temp.last_move(p_copy uuid) returns text language sql as $$
  select movement_type || ':' || quantity from public.stock_movements
  where copy_id = p_copy order by created_at desc, sync_xid desc limit 1 $$;

select tests.become('staff_a'); set local role authenticated;
insert into public.book_copies (id, library_id, book_id, barcode, status, location_id)
values (pg_temp.c('avail'), tests.id('lib_a'), tests.id('book_a'), 'INV-A', 'available', pg_temp.c('l1'));
select tests.is(pg_temp.last_move(pg_temp.c('avail')), 'acquisition:1', 'parity: new available → acquisition +1');
insert into public.book_copies (id, library_id, book_id, barcode, status, condition)
values (pg_temp.c('dmg'), tests.id('lib_a'), tests.id('book_a'), 'INV-D', 'damaged', 'damaged');
select tests.is(pg_temp.last_move(pg_temp.c('dmg')), 'acquisition:0', 'parity: new damaged → acquisition 0');

-- Each statement below is its own "change" (separate rows in the ledger).
select set_config('app.movement_reference', 'ADJ-77', true);
select set_config('app.movement_remarks', 'Hilang semasa pameran', true);
update public.book_copies set status = 'lost' where id = pg_temp.c('avail');
select tests.is(pg_temp.last_move(pg_temp.c('avail')), 'status_change:-1', 'parity: available→lost −1');
select tests.is((select reference_number || '/' || remarks from public.stock_movements
                 where copy_id = pg_temp.c('avail') and movement_type = 'status_change'),
  'ADJ-77/Hilang semasa pameran', 'reference and remarks recorded on the movement');
select set_config('app.movement_reference', '', true);
select set_config('app.movement_remarks', '', true);

update public.book_copies set status = 'available' where id = pg_temp.c('avail');
select tests.is(pg_temp.last_move(pg_temp.c('avail')), 'status_change:1', 'parity: lost→available +1');
update public.book_copies set status = 'in_processing' where id = pg_temp.c('avail');
select tests.is(pg_temp.last_move(pg_temp.c('avail')), 'status_change:0', 'parity: available→in_processing 0');
update public.book_copies set status = 'available' where id = pg_temp.c('avail');
update public.book_copies set location_id = pg_temp.c('l2') where id = pg_temp.c('avail');
select tests.is(pg_temp.last_move(pg_temp.c('avail')), 'relocation:0', 'parity: relocate 0');
update public.book_copies set condition = 'poor' where id = pg_temp.c('avail');
select tests.is(pg_temp.last_move(pg_temp.c('avail')), 'adjustment:0', 'parity: condition change → adjustment 0');
update public.book_copies set status = 'damaged', location_id = pg_temp.c('l1') where id = pg_temp.c('avail');
select tests.is(pg_temp.last_move(pg_temp.c('avail')), 'status_change:-1', 'parity: status+location → status_change −1');
select tests.is(tests.rows_affected(format('update public.book_copies set remarks = %L where id = %L', 'nota', pg_temp.c('avail'))),
  1::bigint, 'remarks-only edit allowed');
select tests.is((select count(*) from public.stock_movements where copy_id = pg_temp.c('avail')), 8::bigint,
  'parity: no-change edit adds no movement');
reset role;

select tests.become('editor_a'); set local role authenticated;
update public.book_copies set status = 'available' where id = pg_temp.c('avail');
update public.book_copies set deleted_at = now() where id = pg_temp.c('avail');
select tests.is(pg_temp.last_move(pg_temp.c('avail')), 'removal:-1', 'parity: delete available → removal −1');
update public.book_copies set deleted_at = now() where id = pg_temp.c('dmg');
select tests.is(pg_temp.last_move(pg_temp.c('dmg')), 'removal:0', 'parity: delete damaged → removal 0');
update public.book_copies set deleted_at = null where id = pg_temp.c('dmg');
select tests.is(pg_temp.last_move(pg_temp.c('dmg')), 'restoration:0', 'restore damaged → restoration 0');
reset role;

-- Ledger sum == current in-stock count (stock is derived, never stored).
select tests.is(
  (select coalesce(sum(quantity), 0) from public.stock_movements where copy_id in (pg_temp.c('avail'), pg_temp.c('dmg'))),
  (select count(*) from public.book_copies where id in (pg_temp.c('avail'), pg_temp.c('dmg'))
     and deleted_at is null and status in ('available', 'in_processing'))::bigint,
  'sum of movement quantities equals derived in-stock count');

select tests.become('viewer_a'); set local role authenticated;
select tests.is(tests.count(format('select 1 from public.stock_movements where copy_id = %L', pg_temp.c('avail'))),
  10::bigint, 'viewer can read movement history');
select tests.is(tests.rows_affected(format('update public.book_copies set status = %L where id = %L', 'lost', pg_temp.c('dmg'))),
  0::bigint, 'viewer cannot change inventory');
select tests.throws(format('delete from public.stock_movements where copy_id = %L', pg_temp.c('avail')),
  '42501', 'viewer cannot delete ledger rows');
reset role;

select tests.become('admin_b'); set local role authenticated;
select tests.is(tests.count(format('select 1 from public.stock_movements where copy_id = %L', pg_temp.c('avail'))),
  0::bigint, 'other library admin cannot read this ledger');
reset role;

rollback;
