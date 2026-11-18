-- =============================================================================
-- SmartLibrary Manager — 0500 Grants + Row Level Security
--
-- Principles
--   * anon gets NOTHING. All access requires a signed-in user.
--   * Every API-reachable table has RLS enabled with separate
--     SELECT / INSERT / UPDATE / DELETE policies.
--   * Authorization comes ONLY from public.library_members (+ system_admins),
--     never from user_metadata / app_metadata / client-supplied values.
--   * UPDATE policies use both USING and WITH CHECK; library_id is also
--     immutable via trigger (0400).
--   * Grants and RLS are kept consistent: a privilege is granted only where a
--     matching policy exists.
-- Role ranks: viewer(1) < staff(2) < editor(3) < library_admin(4).
-- Safe to re-run.
-- =============================================================================

-- ------------------------------------------------------- extra guards --

-- Only Super Admins may change a library's code or (de)activate it.
create or replace function private.tg_libraries_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_super_admin()
     and (new.status is distinct from old.status or new.code is distinct from old.code) then
    raise exception 'Only a Super Admin can change library code or status' using errcode = '42501';
  end if;
  return new;
end
$$;

drop trigger if exists tg_15_guard on public.libraries;
create trigger tg_15_guard
  before update on public.libraries
  for each row execute function private.tg_libraries_guard();

-- Staff may update copy status/location/condition, but changing the barcode,
-- the parent book, or soft-deleting/restoring a copy requires Editor+.
create or replace function private.tg_book_copies_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.barcode is distinct from old.barcode
      or new.book_id is distinct from old.book_id
      or new.deleted_at is distinct from old.deleted_at)
     and not private.has_library_role(old.library_id, 'editor', true) then
    raise exception 'Editor role required to change barcode, book or deletion state'
      using errcode = '42501';
  end if;
  return new;
end
$$;

drop trigger if exists tg_15_guard on public.book_copies;
create trigger tg_15_guard
  before update on public.book_copies
  for each row execute function private.tg_book_copies_guard();

-- Users visible to the caller: themselves + anyone sharing a library.
create or replace function private.visible_user_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid())
  union
  select m.user_id
  from public.library_members m
  where m.library_id in (select private.readable_library_ids())
$$;

-- Users whose devices the caller may see (library admins of a shared library).
create or replace function private.managed_user_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.user_id
  from public.library_members m
  where m.library_id in (select private.library_ids_with_role('library_admin', false))
$$;

revoke all on function private.tg_libraries_guard(), private.tg_book_copies_guard(),
  private.visible_user_ids(), private.managed_user_ids() from public, anon;
grant execute on function private.visible_user_ids(), private.managed_user_ids() to authenticated;

-- ------------------------------------------------------------- grants --

revoke all on all tables in schema public from anon, authenticated;

grant select, insert, update, delete on public.libraries          to authenticated;
grant select                         on public.system_admins      to authenticated;
grant select, insert, update         on public.user_profiles      to authenticated;
grant select, insert, update, delete on public.library_members    to authenticated;
grant select, insert, update, delete on public.library_invitations to authenticated;
grant select, insert, update, delete on public.device_registry    to authenticated;
grant select, insert, update, delete on public.categories         to authenticated;
grant select, insert, update, delete on public.locations          to authenticated;
grant select, insert, update, delete on public.books              to authenticated;
grant select, insert, update, delete on public.book_copies        to authenticated;
grant select                         on public.stock_movements    to authenticated;
grant select, insert                 on public.activity_logs      to authenticated;
grant select, insert, update         on public.sync_operations    to authenticated;
grant select                         on public.sync_tombstones    to authenticated;
grant select, insert, update, delete on public.import_jobs        to authenticated;
grant select, insert, update, delete on public.backup_records     to authenticated;

-- --------------------------------------------------------- enable RLS --
do $$
declare t text;
begin
  foreach t in array array['libraries', 'system_admins', 'user_profiles', 'library_members',
                           'library_invitations', 'device_registry', 'categories', 'locations',
                           'books', 'book_copies', 'stock_movements', 'activity_logs',
                           'sync_operations', 'sync_tombstones', 'import_jobs', 'backup_records'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Helper to (re)create a policy idempotently.
create or replace function private.reset_policy(p_table text, p_name text, p_sql text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  execute format('drop policy if exists %I on public.%I', p_name, p_table);
  execute p_sql;
end
$$;
revoke all on function private.reset_policy(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------- libraries --
select private.reset_policy('libraries', 'libraries_select', $p$
  create policy libraries_select on public.libraries for select to authenticated
  using (id in (select private.readable_library_ids()))
$p$);
select private.reset_policy('libraries', 'libraries_insert', $p$
  create policy libraries_insert on public.libraries for insert to authenticated
  with check ((select private.is_super_admin()))
$p$);
select private.reset_policy('libraries', 'libraries_update', $p$
  create policy libraries_update on public.libraries for update to authenticated
  using (id in (select private.library_ids_with_role('library_admin', false)))
  with check (id in (select private.library_ids_with_role('library_admin', false)))
$p$);
select private.reset_policy('libraries', 'libraries_delete', $p$
  create policy libraries_delete on public.libraries for delete to authenticated
  using ((select private.is_super_admin()))
$p$);

-- ------------------------------------------------------ system_admins --
-- Read-only and only your own row. No write policies: managed via SQL only.
select private.reset_policy('system_admins', 'system_admins_select_self', $p$
  create policy system_admins_select_self on public.system_admins for select to authenticated
  using (user_id = (select auth.uid()))
$p$);

-- ------------------------------------------------------ user_profiles --
select private.reset_policy('user_profiles', 'user_profiles_select', $p$
  create policy user_profiles_select on public.user_profiles for select to authenticated
  using (id in (select private.visible_user_ids()))
$p$);
select private.reset_policy('user_profiles', 'user_profiles_insert_self', $p$
  create policy user_profiles_insert_self on public.user_profiles for insert to authenticated
  with check (id = (select auth.uid()))
$p$);
select private.reset_policy('user_profiles', 'user_profiles_update_self', $p$
  create policy user_profiles_update_self on public.user_profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()))
$p$);

-- ---------------------------------------------------- library_members --
select private.reset_policy('library_members', 'library_members_select', $p$
  create policy library_members_select on public.library_members for select to authenticated
  using (
    user_id = (select auth.uid())
    or library_id in (select private.library_ids_with_role('library_admin', false))
  )
$p$);
select private.reset_policy('library_members', 'library_members_insert', $p$
  create policy library_members_insert on public.library_members for insert to authenticated
  with check (library_id in (select private.writable_library_ids('library_admin')))
$p$);
select private.reset_policy('library_members', 'library_members_update', $p$
  create policy library_members_update on public.library_members for update to authenticated
  using (library_id in (select private.writable_library_ids('library_admin')))
  with check (library_id in (select private.writable_library_ids('library_admin')))
$p$);
-- Memberships are deactivated (membership_status = 'removed'), not deleted.
select private.reset_policy('library_members', 'library_members_delete', $p$
  create policy library_members_delete on public.library_members for delete to authenticated
  using ((select private.is_super_admin()))
$p$);

-- ------------------------------------------------ library_invitations --
select private.reset_policy('library_invitations', 'library_invitations_select', $p$
  create policy library_invitations_select on public.library_invitations for select to authenticated
  using (
    library_id in (select private.library_ids_with_role('library_admin', false))
    or (status = 'pending' and lower(email) = lower((select auth.jwt()) ->> 'email'))
  )
$p$);
select private.reset_policy('library_invitations', 'library_invitations_insert', $p$
  create policy library_invitations_insert on public.library_invitations for insert to authenticated
  with check (library_id in (select private.writable_library_ids('library_admin')) and status = 'pending')
$p$);
select private.reset_policy('library_invitations', 'library_invitations_update', $p$
  create policy library_invitations_update on public.library_invitations for update to authenticated
  using (library_id in (select private.writable_library_ids('library_admin')))
  with check (library_id in (select private.writable_library_ids('library_admin')))
$p$);
select private.reset_policy('library_invitations', 'library_invitations_delete', $p$
  create policy library_invitations_delete on public.library_invitations for delete to authenticated
  using (library_id in (select private.writable_library_ids('library_admin')))
$p$);

-- ---------------------------------------------------- device_registry --
select private.reset_policy('device_registry', 'device_registry_select', $p$
  create policy device_registry_select on public.device_registry for select to authenticated
  using (user_id = (select auth.uid()) or user_id in (select private.managed_user_ids()))
$p$);
select private.reset_policy('device_registry', 'device_registry_insert', $p$
  create policy device_registry_insert on public.device_registry for insert to authenticated
  with check (user_id = (select auth.uid()))
$p$);
select private.reset_policy('device_registry', 'device_registry_update', $p$
  create policy device_registry_update on public.device_registry for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()))
$p$);
select private.reset_policy('device_registry', 'device_registry_delete', $p$
  create policy device_registry_delete on public.device_registry for delete to authenticated
  using (user_id = (select auth.uid()))
$p$);

-- ------------------------------- catalog: categories / locations / books --
--  SELECT: any active member (viewer+)
--  INSERT: categories/locations editor+, books staff+
--  UPDATE: editor+ (includes soft delete)
--  DELETE: library_admin (hard delete; leaves a sync tombstone)
do $$
declare
  t text;
  ins_role text;
begin
  foreach t in array array['categories', 'locations', 'books'] loop
    ins_role := case when t = 'books' then 'staff' else 'editor' end;

    perform private.reset_policy(t, t || '_select', format($f$
      create policy %I on public.%I for select to authenticated
      using (library_id in (select private.readable_library_ids()))
    $f$, t || '_select', t));

    perform private.reset_policy(t, t || '_insert', format($f$
      create policy %I on public.%I for insert to authenticated
      with check (library_id in (select private.writable_library_ids(%L)))
    $f$, t || '_insert', t, ins_role));

    perform private.reset_policy(t, t || '_update', format($f$
      create policy %I on public.%I for update to authenticated
      using (library_id in (select private.writable_library_ids('editor')))
      with check (library_id in (select private.writable_library_ids('editor')))
    $f$, t || '_update', t));

    perform private.reset_policy(t, t || '_delete', format($f$
      create policy %I on public.%I for delete to authenticated
      using (library_id in (select private.writable_library_ids('library_admin')))
    $f$, t || '_delete', t));
  end loop;
end $$;

-- -------------------------------------------------------- book_copies --
select private.reset_policy('book_copies', 'book_copies_select', $p$
  create policy book_copies_select on public.book_copies for select to authenticated
  using (library_id in (select private.readable_library_ids()))
$p$);
select private.reset_policy('book_copies', 'book_copies_insert', $p$
  create policy book_copies_insert on public.book_copies for insert to authenticated
  with check (library_id in (select private.writable_library_ids('staff')))
$p$);
-- Staff may update inventory fields; tg_book_copies_guard restricts the rest.
select private.reset_policy('book_copies', 'book_copies_update', $p$
  create policy book_copies_update on public.book_copies for update to authenticated
  using (library_id in (select private.writable_library_ids('staff')))
  with check (library_id in (select private.writable_library_ids('staff')))
$p$);
select private.reset_policy('book_copies', 'book_copies_delete', $p$
  create policy book_copies_delete on public.book_copies for delete to authenticated
  using (library_id in (select private.writable_library_ids('library_admin')))
$p$);

-- ---------------------------------------------------- stock_movements --
-- Read-only for clients; rows are written by tg_copy_stock_movement.
select private.reset_policy('stock_movements', 'stock_movements_select', $p$
  create policy stock_movements_select on public.stock_movements for select to authenticated
  using (library_id in (select private.readable_library_ids()))
$p$);

-- ------------------------------------------------------ activity_logs --
select private.reset_policy('activity_logs', 'activity_logs_select', $p$
  create policy activity_logs_select on public.activity_logs for select to authenticated
  using (
    library_id in (select private.readable_library_ids())
    or (library_id is null and (select private.is_super_admin()))
  )
$p$);
-- Clients may only add their own application events (e.g. "export"),
-- never forge entity audit rows (those come from tg_audit).
select private.reset_policy('activity_logs', 'activity_logs_insert_app_event', $p$
  create policy activity_logs_insert_app_event on public.activity_logs for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and entity_type = 'app_event'
    and library_id in (select private.writable_library_ids('viewer'))
  )
$p$);

-- ---------------------------------------------------- sync_operations --
select private.reset_policy('sync_operations', 'sync_operations_select', $p$
  create policy sync_operations_select on public.sync_operations for select to authenticated
  using (
    user_id = (select auth.uid())
    or library_id in (select private.library_ids_with_role('library_admin', false))
  )
$p$);
select private.reset_policy('sync_operations', 'sync_operations_insert', $p$
  create policy sync_operations_insert on public.sync_operations for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and library_id in (select private.writable_library_ids('staff'))
  )
$p$);
select private.reset_policy('sync_operations', 'sync_operations_update', $p$
  create policy sync_operations_update on public.sync_operations for update to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and library_id in (select private.writable_library_ids('staff'))
  )
$p$);

-- ---------------------------------------------------- sync_tombstones --
select private.reset_policy('sync_tombstones', 'sync_tombstones_select', $p$
  create policy sync_tombstones_select on public.sync_tombstones for select to authenticated
  using (library_id in (select private.readable_library_ids()))
$p$);

-- -------------------------------------------------------- import_jobs --
select private.reset_policy('import_jobs', 'import_jobs_select', $p$
  create policy import_jobs_select on public.import_jobs for select to authenticated
  using (library_id in (select private.library_ids_with_role('editor', false)))
$p$);
select private.reset_policy('import_jobs', 'import_jobs_insert', $p$
  create policy import_jobs_insert on public.import_jobs for insert to authenticated
  with check (library_id in (select private.writable_library_ids('editor')))
$p$);
select private.reset_policy('import_jobs', 'import_jobs_update', $p$
  create policy import_jobs_update on public.import_jobs for update to authenticated
  using (library_id in (select private.writable_library_ids('editor')))
  with check (library_id in (select private.writable_library_ids('editor')))
$p$);
select private.reset_policy('import_jobs', 'import_jobs_delete', $p$
  create policy import_jobs_delete on public.import_jobs for delete to authenticated
  using (library_id in (select private.writable_library_ids('library_admin')))
$p$);

-- ----------------------------------------------------- backup_records --
select private.reset_policy('backup_records', 'backup_records_select', $p$
  create policy backup_records_select on public.backup_records for select to authenticated
  using (library_id in (select private.library_ids_with_role('library_admin', false)))
$p$);
select private.reset_policy('backup_records', 'backup_records_insert', $p$
  create policy backup_records_insert on public.backup_records for insert to authenticated
  with check (library_id in (select private.writable_library_ids('library_admin')))
$p$);
select private.reset_policy('backup_records', 'backup_records_update', $p$
  create policy backup_records_update on public.backup_records for update to authenticated
  using (library_id in (select private.writable_library_ids('library_admin')))
  with check (library_id in (select private.writable_library_ids('library_admin')))
$p$);
select private.reset_policy('backup_records', 'backup_records_delete', $p$
  create policy backup_records_delete on public.backup_records for delete to authenticated
  using (library_id in (select private.writable_library_ids('library_admin')))
$p$);
