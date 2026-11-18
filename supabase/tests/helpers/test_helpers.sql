-- =============================================================================
-- Test helpers (schema "tests"). Installed by scripts/db_test.sh before the
-- tests and dropped afterwards. Plain PL/pgSQL — no pgTAP dependency, so the
-- same tests run on plain PostgreSQL and on a local Supabase stack.
--
-- Assertions RAISE WARNING 'ok - ...' on success and RAISE EXCEPTION on
-- failure (psql ON_ERROR_STOP then fails the test file).
-- =============================================================================
drop schema if exists tests cascade;
create schema tests;
grant usage on schema tests to anon, authenticated;

create table tests.users (
  alias text primary key,
  id    uuid not null
);
grant select on tests.users to anon, authenticated;

-- Creates an auth user (and, via trigger, a profile) and remembers its alias.
create function tests.create_user(p_alias text, p_email text default null)
returns uuid language plpgsql as $$
declare _id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, raw_user_meta_data)
  values (_id, coalesce(p_email, p_alias || '@test.local'), jsonb_build_object('full_name', initcap(p_alias)));
  insert into tests.users values (p_alias, _id)
    on conflict (alias) do update set id = excluded.id;
  return _id;
end $$;

create function tests.uid(p_alias text) returns uuid
language sql stable as $$ select id from tests.users where alias = p_alias $$;

-- Impersonates a user exactly like PostgREST does (role + JWT claims).
-- Must be followed by "set local role authenticated" in the test script.
create function tests.claims_for(p_alias text) returns void
language plpgsql as $$
declare _id uuid := tests.uid(p_alias);
        _email text;
begin
  select email into _email from auth.users where id = _id;
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', _id, 'role', 'authenticated', 'email', _email,
                       -- deliberately poisoned metadata: must never grant access
                       'user_metadata', jsonb_build_object('role', 'super_admin'),
                       'app_metadata',  jsonb_build_object('library_ids', '[]'::jsonb))::text,
    true);
end $$;

create function tests.clear_claims() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
end $$;

create function tests.ok(p_cond boolean, p_desc text) returns void
language plpgsql as $$
begin
  if p_cond is distinct from true then
    raise exception 'not ok - %', p_desc;
  end if;
  raise warning 'ok - %', p_desc;
end $$;

create function tests.is(p_got anyelement, p_want anyelement, p_desc text) returns void
language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception 'not ok - % (got %, want %)', p_desc, p_got, p_want;
  end if;
  raise warning 'ok - %', p_desc;
end $$;

-- Asserts that p_sql raises SQLSTATE p_state (as the CURRENT role).
create function tests.throws(p_sql text, p_state text, p_desc text) returns void
language plpgsql as $$
declare _state text; _msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics _state = returned_sqlstate, _msg = message_text;
    if _state = p_state then
      raise warning 'ok - % [% %]', p_desc, _state, _msg;
      return;
    end if;
    raise exception 'not ok - % (expected SQLSTATE %, got %: %)', p_desc, p_state, _state, _msg;
  end;
  raise exception 'not ok - % (expected SQLSTATE %, but statement succeeded)', p_desc, p_state;
end $$;

-- Executes p_sql and returns affected row count (for silent RLS filtering).
create function tests.rows_affected(p_sql text) returns bigint
language plpgsql as $$
declare _n bigint;
begin
  execute p_sql;
  get diagnostics _n = row_count;
  return _n;
end $$;

-- Scalar count helper executed as the current role.
create function tests.count(p_sql text) returns bigint
language plpgsql as $$
declare _n bigint;
begin
  execute 'select count(*) from (' || p_sql || ') q' into _n;
  return _n;
end $$;

grant execute on all functions in schema tests to anon, authenticated;

-- ---------------------------------------------------------------- fixture --
create table tests.ids (key text primary key, id uuid not null);
grant select on tests.ids to authenticated;

create function tests.id(p_key text) returns uuid
language sql stable as $$ select id from tests.ids where key = p_key $$;
grant execute on function tests.id(text) to authenticated;

-- Two libraries (A, B) with members in every role. Run as the DB owner
-- inside the test's own transaction (rolled back at the end).
create function tests.seed() returns void
language plpgsql as $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  u text;
begin
  delete from tests.ids;
  delete from tests.users;
  foreach u in array array['super', 'admin_a', 'editor_a', 'staff_a', 'viewer_a', 'removed_a',
                           'admin_b', 'staff_b', 'dual', 'outsider', 'invitee'] loop
    perform tests.create_user(u);
  end loop;

  insert into public.system_admins (user_id) values (tests.uid('super'));

  insert into public.libraries (id, name, code) values
    (a, 'Perpustakaan Sekolah A', 'LIBA'),
    (b, 'Perpustakaan Daerah B', 'LIBB');
  insert into tests.ids values ('lib_a', a), ('lib_b', b);

  insert into public.library_members (library_id, user_id, role, membership_status) values
    (a, tests.uid('admin_a'),   'library_admin', 'active'),
    (a, tests.uid('editor_a'),  'editor',        'active'),
    (a, tests.uid('staff_a'),   'staff',         'active'),
    (a, tests.uid('viewer_a'),  'viewer',        'active'),
    (a, tests.uid('removed_a'), 'editor',        'removed'),
    (a, tests.uid('dual'),      'editor',        'active'),
    (b, tests.uid('admin_b'),   'library_admin', 'active'),
    (b, tests.uid('staff_b'),   'staff',         'active'),
    (b, tests.uid('dual'),      'editor',        'active');

  insert into public.categories (id, library_id, name) values
    (gen_random_uuid(), a, 'Fiksyen'), (gen_random_uuid(), b, 'Sains');
  insert into tests.ids select 'cat_a', id from public.categories where library_id = a;
  insert into tests.ids select 'cat_b', id from public.categories where library_id = b;

  insert into public.locations (library_id, building, rack_code, shelf_code) values
    (a, 'Blok Utama', 'R01', 'S1'), (b, 'Blok Timur', 'R10', 'S2');
  insert into tests.ids select 'loc_a', id from public.locations where library_id = a;
  insert into tests.ids select 'loc_b', id from public.locations where library_id = b;

  insert into public.books (library_id, title, author, isbn, category_id) values
    (a, 'Hikayat Hang Tuah', 'Anonim', '9789830000001', tests.id('cat_a')),
    (b, 'Asas Fizik', 'Ahmad', '9789830000002', tests.id('cat_b'));
  insert into tests.ids select 'book_a', id from public.books where library_id = a;
  insert into tests.ids select 'book_b', id from public.books where library_id = b;

  insert into public.book_copies (library_id, book_id, barcode, location_id) values
    (a, tests.id('book_a'), 'A0001', tests.id('loc_a')),
    (b, tests.id('book_b'), 'B0001', tests.id('loc_b'));
  insert into tests.ids select 'copy_a', id from public.book_copies where library_id = a;
  insert into tests.ids select 'copy_b', id from public.book_copies where library_id = b;
end $$;

-- Switch identity inside a test transaction.
create function tests.become(p_alias text) returns void
language plpgsql as $$
begin
  perform tests.claims_for(p_alias);
end $$;
