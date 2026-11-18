-- =============================================================================
-- SmartLibrary Manager — 0800 Phase 3: user management & library admin
--   * user_profiles.email mirrored from auth.users (read-only for clients)
--   * column-level grants on user_profiles
--   * RPC library_member_list(), create_library()
-- Safe to re-run.
-- =============================================================================

alter table public.user_profiles add column if not exists email text;

-- Backfill + keep in sync with auth.users (the only trusted e-mail source).
update public.user_profiles p set email = u.email
from auth.users u where u.id = p.id and p.email is distinct from u.email;

create or replace function private.tg_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.user_profiles (id, full_name, email)
  values (new.id, left(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''), 200), new.email)
  on conflict (id) do update set email = excluded.email;
  return new;
end
$$;

create or replace function private.tg_sync_user_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.user_profiles set email = new.email where id = new.id;
  return new;
end
$$;
revoke all on function private.tg_sync_user_email() from public, anon, authenticated;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row when (new.email is distinct from old.email)
  execute function private.tg_sync_user_email();

-- Clients may edit only their display fields; e-mail and id stay server-owned.
revoke insert, update on public.user_profiles from authenticated;
grant insert (id, full_name, phone, avatar_path) on public.user_profiles to authenticated;
grant update (full_name, phone, avatar_path) on public.user_profiles to authenticated;

-- ----------------------------------------------------------------------------
-- Member list with profile data (SECURITY INVOKER: RLS on library_members
-- means only Library Admins / Super Admins see the full list; other members
-- see just themselves).
-- ----------------------------------------------------------------------------
create or replace function public.library_member_list(p_library_id uuid)
returns table (
  member_id         uuid,
  user_id           uuid,
  role              text,
  membership_status text,
  joined_at         timestamptz,
  full_name         text,
  email             text,
  is_self           boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  select m.id, m.user_id, m.role, m.membership_status, m.joined_at,
         p.full_name, p.email, m.user_id = (select auth.uid())
  from public.library_members m
  left join public.user_profiles p on p.id = m.user_id
  where m.library_id = p_library_id
  order by (m.membership_status = 'active') desc, private.role_rank(m.role) desc, p.full_name nulls last
$$;

-- ----------------------------------------------------------------------------
-- Create a library and (optionally) invite its first Library Admin, atomically.
-- SECURITY INVOKER: the libraries INSERT policy restricts this to Super Admins.
-- ----------------------------------------------------------------------------
create or replace function public.create_library(
  p_name              text,
  p_code              text,
  p_organization_name text default null,
  p_address           text default null,
  p_contact_person    text default null,
  p_phone             text default null,
  p_email             text default null,
  p_established_on    date default null,
  p_admin_email       text default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  _id uuid;
begin
  insert into public.libraries (name, code, organization_name, address, contact_person, phone, email, established_on)
  values (btrim(p_name), upper(btrim(p_code)), nullif(btrim(p_organization_name), ''), nullif(btrim(p_address), ''),
          nullif(btrim(p_contact_person), ''), nullif(btrim(p_phone), ''), nullif(btrim(p_email), ''), p_established_on)
  returning id into _id;

  if nullif(btrim(p_admin_email), '') is not null then
    insert into public.library_invitations (library_id, email, role)
    values (_id, lower(btrim(p_admin_email)), 'library_admin');
  end if;
  return _id;
end
$$;

revoke all on function public.library_member_list(uuid) from public, anon;
revoke all on function public.create_library(text, text, text, text, text, text, text, date, text) from public, anon;
grant execute on function public.library_member_list(uuid) to authenticated;
grant execute on function public.create_library(text, text, text, text, text, text, text, date, text) to authenticated;

-- ----------------------------------------------------------------------------
-- Fix: Super Admin INSERT ... RETURNING on libraries. The SELECT policy's
-- subquery cannot see a row inserted by the same statement, so allow Super
-- Admins explicitly.
-- ----------------------------------------------------------------------------
select private.reset_policy('libraries', 'libraries_select', $p$
  create policy libraries_select on public.libraries for select to authenticated
  using (id in (select private.readable_library_ids()) or (select private.is_super_admin()))
$p$);

-- ----------------------------------------------------------------------------
-- Fix: audit trigger during whole-library deletion (cascade). Child rows of a
-- deleted library are not logged; the library deletion itself is logged as a
-- system-level event (library_id NULL, visible to Super Admins).
-- ----------------------------------------------------------------------------
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
    if not exists (select 1 from public.libraries l where l.id = _lib) then
      if tg_table_name <> 'libraries' then
        return null;          -- part of a whole-library cascade
      end if;
      _lib := null;           -- system-level event
    end if;
  else
    _old := to_jsonb(old);
    if (_old ->> 'deleted_at') is null and (_row ->> 'deleted_at') is not null then
      _action := 'soft_delete';
    elsif (_old ->> 'deleted_at') is not null and (_row ->> 'deleted_at') is null then
      _action := 'restore';
    else
      _action := 'update';
    end if;
    for _key in select jsonb_object_keys(_row) loop
      if _key not in ('version', 'sync_xid', 'updated_at')
         and (_row -> _key) is distinct from (_old -> _key) then
        _details := _details || jsonb_build_object(
          _key, jsonb_build_object('old', _old -> _key, 'new', _row -> _key));
      end if;
    end loop;
    if _details = '{}'::jsonb then
      return null;
    end if;
    _details := jsonb_build_object('changes', _details);
  end if;

  insert into public.activity_logs (library_id, user_id, action, entity_type, entity_id, details, device_id)
  values (_lib, (select auth.uid()), _action, tg_table_name, (_row ->> 'id')::uuid, _details,
          private.current_device_id());
  return null;
end
$$;
revoke all on function private.tg_audit() from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- Invitations carry a snapshot of the library name: the invitee is not a
-- member yet, so RLS (correctly) hides the libraries row from them.
-- ----------------------------------------------------------------------------
alter table public.library_invitations add column if not exists library_name text;

create or replace function private.tg_invitation_library_name()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Runs as the inviting admin, who can read the library row.
  select l.name into new.library_name from public.libraries l where l.id = new.library_id;
  return new;
end
$$;
revoke all on function private.tg_invitation_library_name() from public, anon, authenticated;

drop trigger if exists tg_30_library_name on public.library_invitations;
create trigger tg_30_library_name
  before insert on public.library_invitations
  for each row execute function private.tg_invitation_library_name();
