-- =============================================================================
-- Systematic RLS matrix: every role × every library-scoped table × every
-- operation, against library A, compared with the documented access matrix
-- (docs/rls-security.md). Each probe runs in a sub-transaction that is always
-- rolled back, so probes never influence each other.
--
-- Result of a probe: 'allow' (statement affected/returned ≥1 row),
-- 'deny' (0 rows or permission error), or 'fk' (allowed by RLS but blocked by
-- a foreign key — e.g. deleting a copy that has ledger history).
-- =============================================================================
begin;
select tests.seed();

create function pg_temp.probe(p_sql text) returns text language plpgsql as $$
declare n bigint;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
    raise exception using errcode = 'P0099', message = case when n > 0 then 'allow' else 'deny' end;
  exception
    when sqlstate 'P0099' then return sqlerrm;
    when insufficient_privilege then return 'deny';
    when foreign_key_violation then return 'fk';
    when others then return 'error ' || sqlstate || ': ' || sqlerrm;
  end;
end $$;
grant execute on function pg_temp.probe(text) to authenticated;

-- Extra fixtures (as owner)
insert into tests.ids values ('probe_book', gen_random_uuid()), ('probe_job', gen_random_uuid()),
  ('probe_backup', gen_random_uuid()), ('probe_inv', gen_random_uuid()), ('probe_op', gen_random_uuid());
insert into public.books (id, library_id, title) values (tests.id('probe_book'), tests.id('lib_a'), 'Probe');
insert into public.import_jobs (id, library_id, file_name) values (tests.id('probe_job'), tests.id('lib_a'), 'x.xlsx');
insert into public.backup_records (id, library_id) values (tests.id('probe_backup'), tests.id('lib_a'));
insert into public.library_invitations (id, library_id, email, role)
  values (tests.id('probe_inv'), tests.id('lib_a'), 'someone@test.local', 'viewer');
insert into public.sync_operations (id, library_id, user_id, operation_id, entity_type, entity_id, operation_type)
  values (tests.id('probe_op'), tests.id('lib_a'), tests.uid('staff_a'), gen_random_uuid(), 'books', gen_random_uuid(), 'insert');
insert into public.sync_tombstones (library_id, entity_type, entity_id) values (tests.id('lib_a'), 'books', gen_random_uuid());

-- Expected matrix. Roles: super, admin_a, editor_a, staff_a, viewer_a, removed_a, outsider, admin_b
create temp table matrix (tbl text, op text, sql text, allowed text[], allowed_result text);
insert into matrix values
  -- libraries
  ('libraries', 'select', $$select 1 from public.libraries where id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a,staff_a,viewer_a}', 'allow'),
  ('libraries', 'insert', $$insert into public.libraries (name, code) values ('Probe', 'PROBE')$$, '{super}', 'allow'),
  ('libraries', 'update', $$update public.libraries set name = name || '' where id = tests.id('lib_a')$$, '{super,admin_a}', 'allow'),
  ('libraries', 'delete', $$delete from public.libraries where id = tests.id('lib_a')$$, '{super}', 'allow'),
  -- categories
  ('categories', 'select', $$select 1 from public.categories where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a,staff_a,viewer_a}', 'allow'),
  ('categories', 'insert', $$insert into public.categories (library_id, name) values (tests.id('lib_a'), 'Probe')$$,
     '{super,admin_a,editor_a}', 'allow'),
  ('categories', 'update', $$update public.categories set description = 'p' where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a}', 'allow'),
  ('categories', 'delete', $$delete from public.categories where id = tests.id('cat_a')$$, '{super,admin_a}', 'allow'),
  -- locations
  ('locations', 'select', $$select 1 from public.locations where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a,staff_a,viewer_a}', 'allow'),
  ('locations', 'insert', $$insert into public.locations (library_id, rack_code) values (tests.id('lib_a'), 'PROBE')$$,
     '{super,admin_a,editor_a}', 'allow'),
  ('locations', 'update', $$update public.locations set description = 'p' where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a}', 'allow'),
  ('locations', 'delete', $$delete from public.locations where id = tests.id('loc_a')$$, '{super,admin_a}', 'allow'),
  -- books
  ('books', 'select', $$select 1 from public.books where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a,staff_a,viewer_a}', 'allow'),
  ('books', 'insert', $$insert into public.books (library_id, title) values (tests.id('lib_a'), 'Probe')$$,
     '{super,admin_a,editor_a,staff_a}', 'allow'),
  ('books', 'update', $$update public.books set subtitle = 'p' where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a}', 'allow'),
  ('books', 'delete', $$delete from public.books where id = tests.id('probe_book')$$, '{super,admin_a}', 'allow'),
  -- book_copies
  ('book_copies', 'select', $$select 1 from public.book_copies where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a,staff_a,viewer_a}', 'allow'),
  ('book_copies', 'insert', $$insert into public.book_copies (library_id, book_id, barcode)
                              values (tests.id('lib_a'), tests.id('book_a'), 'PROBE-1')$$,
     '{super,admin_a,editor_a,staff_a}', 'allow'),
  ('book_copies', 'update', $$update public.book_copies set remarks = 'p' where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a,staff_a}', 'allow'),
  ('book_copies', 'delete', $$delete from public.book_copies where id = tests.id('copy_a')$$, '{super,admin_a}', 'fk'),
  -- stock_movements (server-written, append-only)
  ('stock_movements', 'select', $$select 1 from public.stock_movements where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a,staff_a,viewer_a}', 'allow'),
  ('stock_movements', 'insert', $$insert into public.stock_movements (library_id, copy_id, movement_type, quantity)
                                  values (tests.id('lib_a'), tests.id('copy_a'), 'adjustment', 0)$$, '{}', 'allow'),
  ('stock_movements', 'update', $$update public.stock_movements set remarks = 'x' where library_id = tests.id('lib_a')$$, '{}', 'allow'),
  ('stock_movements', 'delete', $$delete from public.stock_movements where library_id = tests.id('lib_a')$$, '{}', 'allow'),
  -- activity_logs
  ('activity_logs', 'select', $$select 1 from public.activity_logs where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a,staff_a,viewer_a}', 'allow'),
  ('activity_logs', 'insert', $$insert into public.activity_logs (library_id, user_id, action, entity_type)
                                values (tests.id('lib_a'), auth.uid(), 'probe', 'app_event')$$,
     '{super,admin_a,editor_a,staff_a,viewer_a}', 'allow'),
  ('activity_logs', 'update', $$update public.activity_logs set action = 'x' where library_id = tests.id('lib_a')$$, '{}', 'allow'),
  ('activity_logs', 'delete', $$delete from public.activity_logs where library_id = tests.id('lib_a')$$, '{}', 'allow'),
  -- sync_operations (one seeded op owned by staff_a)
  ('sync_operations', 'select', $$select 1 from public.sync_operations where library_id = tests.id('lib_a')$$,
     '{super,admin_a,staff_a}', 'allow'),
  ('sync_operations', 'insert', $$insert into public.sync_operations (library_id, user_id, operation_id, entity_type,
                                    entity_id, operation_type)
                                  values (tests.id('lib_a'), auth.uid(), gen_random_uuid(), 'books', gen_random_uuid(), 'insert')$$,
     '{super,admin_a,editor_a,staff_a}', 'allow'),
  ('sync_operations', 'update', $$update public.sync_operations set error_message = 'x' where id = tests.id('probe_op')$$,
     '{staff_a}', 'allow'),
  ('sync_operations', 'delete', $$delete from public.sync_operations where id = tests.id('probe_op')$$, '{}', 'allow'),
  -- sync_tombstones
  ('sync_tombstones', 'select', $$select 1 from public.sync_tombstones where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a,staff_a,viewer_a}', 'allow'),
  ('sync_tombstones', 'delete', $$delete from public.sync_tombstones where library_id = tests.id('lib_a')$$, '{}', 'allow'),
  -- import_jobs
  ('import_jobs', 'select', $$select 1 from public.import_jobs where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a}', 'allow'),
  ('import_jobs', 'insert', $$insert into public.import_jobs (library_id, file_name) values (tests.id('lib_a'), 'p.xlsx')$$,
     '{super,admin_a,editor_a}', 'allow'),
  ('import_jobs', 'update', $$update public.import_jobs set status = 'completed' where id = tests.id('probe_job')$$,
     '{super,admin_a,editor_a}', 'allow'),
  ('import_jobs', 'delete', $$delete from public.import_jobs where id = tests.id('probe_job')$$, '{super,admin_a}', 'allow'),
  -- backup_records
  ('backup_records', 'select', $$select 1 from public.backup_records where library_id = tests.id('lib_a')$$,
     '{super,admin_a}', 'allow'),
  ('backup_records', 'insert', $$insert into public.backup_records (library_id) values (tests.id('lib_a'))$$,
     '{super,admin_a}', 'allow'),
  ('backup_records', 'update', $$update public.backup_records set notes = 'x' where id = tests.id('probe_backup')$$,
     '{super,admin_a}', 'allow'),
  ('backup_records', 'delete', $$delete from public.backup_records where id = tests.id('probe_backup')$$, '{super,admin_a}', 'allow'),
  -- library_members (every member sees at least their own row; removed_a too)
  ('library_members', 'select', $$select 1 from public.library_members where library_id = tests.id('lib_a')$$,
     '{super,admin_a,editor_a,staff_a,viewer_a,removed_a}', 'allow'),
  ('library_members', 'insert', $$insert into public.library_members (library_id, user_id, role)
                                  values (tests.id('lib_a'), tests.uid('outsider'), 'viewer')$$, '{super,admin_a}', 'allow'),
  ('library_members', 'update', $$update public.library_members set role = 'staff'
                                  where library_id = tests.id('lib_a') and user_id = tests.uid('viewer_a')$$,
     '{super,admin_a}', 'allow'),
  ('library_members', 'delete', $$delete from public.library_members
                                  where library_id = tests.id('lib_a') and user_id = tests.uid('viewer_a')$$, '{super}', 'allow'),
  -- library_invitations
  ('library_invitations', 'select', $$select 1 from public.library_invitations where id = tests.id('probe_inv')$$,
     '{super,admin_a}', 'allow'),
  ('library_invitations', 'insert', $$insert into public.library_invitations (library_id, email, role)
                                      values (tests.id('lib_a'), 'probe@test.local', 'viewer')$$, '{super,admin_a}', 'allow'),
  ('library_invitations', 'update', $$update public.library_invitations set status = 'revoked' where id = tests.id('probe_inv')$$,
     '{super,admin_a}', 'allow'),
  ('library_invitations', 'delete', $$delete from public.library_invitations where id = tests.id('probe_inv')$$,
     '{super,admin_a}', 'allow');
grant select on matrix to authenticated;

create temp table results (tbl text, op text, role text, expected text, got text);
grant all on results to authenticated;

do $$
declare
  r record;
  who text;
  got text;
begin
  foreach who in array array['super', 'admin_a', 'editor_a', 'staff_a', 'viewer_a', 'removed_a', 'outsider', 'admin_b'] loop
    perform tests.become(who);
    for r in select * from matrix loop
      execute 'set local role authenticated';
      got := pg_temp.probe(r.sql);
      execute 'reset role';
      insert into results values (r.tbl, r.op, who,
        case when who = any (r.allowed) then r.allowed_result else 'deny' end, got);
    end loop;
  end loop;
  perform tests.clear_claims();
end $$;

-- Report every cell; fail listing all mismatches at once.
do $$
declare
  bad text;
  n int;
begin
  select count(*), string_agg(format('%s.%s as %s: expected %s, got %s', tbl, op, role, expected, got), E'\n')
    into n, bad
  from results where expected <> got;
  if n > 0 then
    raise exception 'not ok - RLS matrix: % mismatches%', n, E'\n' || bad;
  end if;
end $$;
select tests.is((select count(*) from results), (select count(*) * 8 from matrix),
  format('RLS matrix: %s probes (%s cases on %s tables × 8 roles) all match the documented access matrix',
         (select count(*) from results), (select count(*) from matrix), (select count(distinct tbl) from matrix)));
select tests.is((select count(*) from results where got like 'error%'), 0::bigint, 'no unexpected errors in any probe');

rollback;
