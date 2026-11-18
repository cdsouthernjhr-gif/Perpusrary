-- =============================================================================
-- SmartLibrary Manager — 0400 Membership helpers & triggers
--
-- SECURITY DEFINER is used ONLY for:
--   (a) membership lookup helpers used inside RLS policies — they must read
--       library_members without recursing into library_members' own RLS;
--   (b) trigger functions that write tamper-proof audit rows
--       (activity_logs, stock_movements, sync_tombstones, user_profiles).
-- All of them live in schema "private" (not exposed by the Data API), pin
-- search_path to '' and derive the caller exclusively from auth.uid().
-- Trigger functions cannot be invoked directly by clients.
-- Safe to re-run.
-- =============================================================================

-- ------------------------------------------------------------ helpers --

create or replace function private.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.system_admins s where s.user_id = (select auth.uid())
  )
$$;

-- Library ids where the caller has an ACTIVE membership with at least
-- p_min_role. With p_require_active_library the library itself must also be
-- active (used for writes). Super Admins get every library.
create or replace function private.library_ids_with_role(
  p_min_role text,
  p_require_active_library boolean
)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.library_id
  from public.library_members m
  join public.libraries l on l.id = m.library_id
  where m.user_id = (select auth.uid())
    and m.membership_status = 'active'
    and private.role_rank(m.role) >= private.role_rank(p_min_role)
    and (not p_require_active_library or l.status = 'active')
  union
  select l.id
  from public.libraries l
  where exists (select 1 from public.system_admins s where s.user_id = (select auth.uid()))
$$;

create or replace function private.readable_library_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select private.library_ids_with_role('viewer', false)
$$;

create or replace function private.writable_library_ids(p_min_role text)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select private.library_ids_with_role(p_min_role, true)
$$;

create or replace function private.has_library_role(
  p_library_id uuid,
  p_min_role text,
  p_require_active_library boolean default true
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_library_id in (select private.library_ids_with_role(p_min_role, p_require_active_library))
$$;

-- Device id for audit rows: set by sync_push (app.device_id) or sent by the
-- app as the x-device-id request header. Informational only — never used for
-- authorization.
create or replace function private.current_device_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select coalesce(
    private.try_uuid(nullif(current_setting('app.device_id', true), '')),
    private.try_uuid(nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-device-id')
  )
$$;

-- --------------------------------------------------- trigger functions --

-- New auth user -> profile row. raw_user_meta_data is user-editable, so it is
-- used ONLY as a display-name default, never for authorization.
create or replace function private.tg_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.user_profiles (id, full_name)
  values (new.id, left(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''), 200))
  on conflict (id) do nothing;
  return new;
end
$$;

-- Generic audit trail into activity_logs.
create or replace function private.tg_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  _row      jsonb;
  _old      jsonb;
  _lib      uuid;
  _action   text;
  _details  jsonb := '{}'::jsonb;
  _key      text;
begin
  if tg_op = 'DELETE' then
    _row := to_jsonb(old);
  else
    _row := to_jsonb(new);
  end if;

  _lib := case when tg_table_name = 'libraries'
               then (_row ->> 'id')::uuid
               else (_row ->> 'library_id')::uuid end;

  if tg_op = 'INSERT' then
    _action := 'create';
  elsif tg_op = 'DELETE' then
    _action := 'delete';
    _details := jsonb_build_object('old', _row);
  else
    _old := to_jsonb(old);
    if (_old ->> 'deleted_at') is null and (_row ->> 'deleted_at') is not null then
      _action := 'soft_delete';
    elsif (_old ->> 'deleted_at') is not null and (_row ->> 'deleted_at') is null then
      _action := 'restore';
    else
      _action := 'update';
    end if;
    -- Store only changed fields: {"field": {"old": .., "new": ..}}
    for _key in select jsonb_object_keys(_row) loop
      if _key not in ('version', 'sync_xid', 'updated_at')
         and (_row -> _key) is distinct from (_old -> _key) then
        _details := _details || jsonb_build_object(
          _key, jsonb_build_object('old', _old -> _key, 'new', _row -> _key));
      end if;
    end loop;
    if _details = '{}'::jsonb then
      return null;  -- nothing meaningful changed
    end if;
    _details := jsonb_build_object('changes', _details);
  end if;

  insert into public.activity_logs (library_id, user_id, action, entity_type, entity_id, details, device_id)
  values (_lib, (select auth.uid()), _action, tg_table_name, (_row ->> 'id')::uuid, _details,
          private.current_device_id());
  return null;
end
$$;

-- Server-derived inventory ledger for every physical copy change, written in
-- the same transaction as the change itself.
create or replace function private.tg_copy_stock_movement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  _type     text;
  _qty      int;
  _ref      text := left(nullif(current_setting('app.movement_reference', true), ''), 100);
  _remarks  text := left(nullif(current_setting('app.movement_remarks', true), ''), 1000);
  _in_old   int;
  _in_new   int;
begin
  if tg_op = 'INSERT' then
    insert into public.stock_movements (library_id, copy_id, movement_type, quantity,
      to_status, to_location_id, reference_number, remarks, created_by)
    values (new.library_id, new.id, 'acquisition',
      case when new.status in ('available', 'in_processing') then 1 else 0 end,
      new.status, new.location_id, _ref, _remarks, (select auth.uid()));
    return null;
  end if;

  -- In-stock = physically present and usable.
  _in_old := case when old.deleted_at is null and old.status in ('available', 'in_processing') then 1 else 0 end;
  _in_new := case when new.deleted_at is null and new.status in ('available', 'in_processing') then 1 else 0 end;
  _qty := _in_new - _in_old;

  if old.deleted_at is null and new.deleted_at is not null then
    _type := 'removal';
  elsif old.deleted_at is not null and new.deleted_at is null then
    _type := 'restoration';
  elsif new.status is distinct from old.status then
    _type := 'status_change';
  elsif new.location_id is distinct from old.location_id then
    _type := 'relocation';
  elsif new.condition is distinct from old.condition then
    _type := 'adjustment';
  else
    return null;
  end if;

  insert into public.stock_movements (library_id, copy_id, movement_type, quantity,
    from_status, to_status, from_location_id, to_location_id, reference_number, remarks, created_by)
  values (new.library_id, new.id, _type, _qty,
    old.status, new.status, old.location_id, new.location_id, _ref, _remarks, (select auth.uid()));
  return null;
end
$$;

-- Hard deletes leave a tombstone so offline devices can remove local copies.
create or replace function private.tg_sync_tombstone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Skip when the whole library is being deleted (cascade).
  if exists (select 1 from public.libraries l where l.id = old.library_id) then
    insert into public.sync_tombstones (library_id, entity_type, entity_id, deleted_by)
    values (old.library_id, tg_table_name, old.id, (select auth.uid()));
  end if;
  return null;
end
$$;

-- Membership integrity:
--   * user_id never changes;
--   * a library can never lose its last active library_admin
--     (Super Admins and whole-library deletes are exempt).
create or replace function private.tg_library_members_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  _was_admin boolean;
  _still_admin boolean;
begin
  if tg_op = 'UPDATE' and new.user_id is distinct from old.user_id then
    raise exception 'user_id is immutable' using errcode = '42501';
  end if;

  _was_admin := old.role = 'library_admin' and old.membership_status = 'active';
  _still_admin := tg_op = 'UPDATE' and new.role = 'library_admin' and new.membership_status = 'active';

  if _was_admin and not _still_admin
     and not private.is_super_admin()
     and exists (select 1 from public.libraries l where l.id = old.library_id)
     and not exists (
       select 1 from public.library_members m
       where m.library_id = old.library_id and m.id <> old.id
         and m.role = 'library_admin' and m.membership_status = 'active')
  then
    raise exception 'A library must keep at least one active library_admin'
      using errcode = '23514';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end
$$;

-- invited_by is always the caller.
create or replace function private.tg_set_invited_by()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.invited_by := (select auth.uid());
  else
    new.invited_by := old.invited_by;
  end if;
  return new;
end
$$;

-- import_jobs.uploaded_by is always the caller.
create or replace function private.tg_set_uploaded_by()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.uploaded_by := (select auth.uid());
  else
    new.uploaded_by := old.uploaded_by;
  end if;
  return new;
end
$$;

revoke all on all functions in schema private from public, anon;
grant execute on function
  private.role_rank(text),
  private.try_uuid(text),
  private.is_super_admin(),
  private.library_ids_with_role(text, boolean),
  private.readable_library_ids(),
  private.writable_library_ids(text),
  private.has_library_role(uuid, text, boolean),
  private.current_device_id()
to authenticated;

-- -------------------------------------------------------- attach triggers --

-- Auth -> profile
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.tg_handle_new_user();

-- Versioned + synced tables
do $$
declare t text;
begin
  foreach t in array array['libraries', 'categories', 'locations', 'books', 'book_copies'] loop
    execute format('drop trigger if exists tg_10_versioning on public.%I', t);
    execute format('create trigger tg_10_versioning before insert or update on public.%I
                    for each row execute function private.tg_row_versioning()', t);
    execute format('drop trigger if exists tg_20_created_by on public.%I', t);
    execute format('create trigger tg_20_created_by before insert or update on public.%I
                    for each row execute function private.tg_set_created_by()', t);
    execute format('drop trigger if exists tg_90_audit on public.%I', t);
    execute format('create trigger tg_90_audit after insert or update or delete on public.%I
                    for each row execute function private.tg_audit()', t);
  end loop;

  foreach t in array array['categories', 'locations', 'books', 'book_copies'] loop
    execute format('drop trigger if exists tg_95_tombstone on public.%I', t);
    execute format('create trigger tg_95_tombstone after delete on public.%I
                    for each row execute function private.tg_sync_tombstone()', t);
  end loop;

  -- library_id immutability on every library-owned table
  foreach t in array array['library_members', 'library_invitations', 'categories', 'locations', 'books',
                           'book_copies', 'stock_movements', 'activity_logs', 'sync_operations',
                           'sync_tombstones', 'import_jobs', 'backup_records'] loop
    execute format('drop trigger if exists tg_05_library_id_immutable on public.%I', t);
    execute format('create trigger tg_05_library_id_immutable before update on public.%I
                    for each row execute function private.tg_library_id_immutable()', t);
  end loop;

  -- updated_at on non-versioned mutable tables
  foreach t in array array['user_profiles', 'library_members', 'library_invitations', 'device_registry',
                           'import_jobs', 'backup_records'] loop
    execute format('drop trigger if exists tg_10_touch on public.%I', t);
    execute format('create trigger tg_10_touch before insert or update on public.%I
                    for each row execute function private.tg_touch_updated_at()', t);
  end loop;

  -- Append-only tables
  foreach t in array array['stock_movements', 'activity_logs', 'sync_tombstones'] loop
    execute format('drop trigger if exists tg_00_append_only on public.%I', t);
    execute format('create trigger tg_00_append_only before update on public.%I
                    for each row execute function private.tg_append_only()', t);
  end loop;
end $$;

drop trigger if exists tg_50_stock_movement on public.book_copies;
create trigger tg_50_stock_movement
  after insert or update on public.book_copies
  for each row execute function private.tg_copy_stock_movement();

drop trigger if exists tg_20_guard on public.library_members;
create trigger tg_20_guard
  before update or delete on public.library_members
  for each row execute function private.tg_library_members_guard();

drop trigger if exists tg_90_audit on public.library_members;
create trigger tg_90_audit
  after insert or update or delete on public.library_members
  for each row execute function private.tg_audit();

drop trigger if exists tg_20_invited_by on public.library_invitations;
create trigger tg_20_invited_by
  before insert or update on public.library_invitations
  for each row execute function private.tg_set_invited_by();

drop trigger if exists tg_20_uploaded_by on public.import_jobs;
create trigger tg_20_uploaded_by
  before insert or update on public.import_jobs
  for each row execute function private.tg_set_uploaded_by();
