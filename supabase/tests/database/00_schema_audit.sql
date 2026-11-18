-- =============================================================================
-- Static security audit of the schema (guards against future regressions).
-- =============================================================================
begin;

select tests.is((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity),
  0::bigint, 'every table in public has RLS enabled');

select tests.is((select count(*) from information_schema.role_table_grants
                 where table_schema = 'public' and grantee = 'anon'),
  0::bigint, 'anon has no table privileges in public');

select tests.is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where p.prosecdef and n.nspname not in ('private', 'auth', 'storage', 'extensions', 'tests')
                   and n.nspname not like 'pg_%' and n.nspname <> 'information_schema'),
  0::bigint, 'no SECURITY DEFINER functions outside schema private');

select tests.is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where p.prosecdef and n.nspname = 'private'
                   and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) cfg where cfg like 'search_path=%')),
  0::bigint, 'every SECURITY DEFINER function pins search_path');

select tests.is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')),
  0::bigint, 'anon cannot execute any public function');

select tests.is((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'private' and has_function_privilege('anon', p.oid, 'execute')),
  0::bigint, 'anon cannot execute any private function');

-- Every library-owned table has a NOT NULL library_id (activity_logs allows
-- NULL for system-level events only).
select tests.is((select count(*) from information_schema.columns
                 where table_schema = 'public' and column_name = 'library_id' and is_nullable = 'YES'
                   and table_name <> 'activity_logs'),
  0::bigint, 'library_id is NOT NULL on all library-owned tables');

-- Every table that has library_id has the immutability trigger.
select tests.is((select count(*) from information_schema.columns col
                 where col.table_schema = 'public' and col.column_name = 'library_id'
                   and not exists (select 1 from pg_trigger t
                                   where t.tgrelid = format('public.%I', col.table_name)::regclass
                                     and t.tgname = 'tg_05_library_id_immutable')),
  0::bigint, 'library_id immutability trigger on all library-owned tables');

-- Each table with RLS has policies for every command it grants to authenticated.
select tests.is((
  select count(*) from information_schema.role_table_grants g
  where g.table_schema = 'public' and g.grantee = 'authenticated'
    and g.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
    and not exists (
      select 1 from pg_policies p
      where p.schemaname = 'public' and p.tablename = g.table_name
        and (p.cmd = g.privilege_type or p.cmd = 'ALL'))),
  0::bigint, 'every privilege granted to authenticated is backed by an RLS policy');

rollback;
