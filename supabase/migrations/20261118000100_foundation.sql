-- =============================================================================
-- SmartLibrary Manager — 0100 Foundation
--   * extensions
--   * "private" schema (NOT exposed through the Data API)
--   * generic trigger functions (updated_at, version, sync xid, immutability)
-- Safe to re-run.
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm  with schema extensions;

-- The "private" schema holds helper functions used by RLS policies and
-- triggers. It must never be added to the API "Exposed schemas" list.
create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon;
-- authenticated needs USAGE so RLS policies evaluated as that role can call
-- the membership helper functions; EXECUTE is still granted per function.
grant usage on schema private to authenticated;

-- Role rank used for "at least role X" checks. Super admin is NOT a library
-- role; it lives in public.system_admins.
create or replace function private.role_rank(p_role text)
returns int
language sql
immutable
set search_path = ''
as $$
  select case p_role
    when 'viewer'        then 1
    when 'staff'         then 2
    when 'editor'        then 3
    when 'library_admin' then 4
    else 0
  end
$$;

-- Converts text to uuid, returning NULL instead of raising on bad input.
-- Used by Storage policies on user-controlled object names.
create or replace function private.try_uuid(p text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  return p::uuid;
exception when others then
  return null;
end
$$;

-- ---------------------------------------------------------------------------
-- Generic triggers
-- ---------------------------------------------------------------------------

-- Maintains updated_at, server-side version, and the sync transaction id.
--  * version:   optimistic-concurrency counter, never trusted from the client.
--  * sync_xid:  transaction id of the last write; used as the pull cursor
--               (see docs/sync-design.md). Never trusted from the client.
create or replace function private.tg_row_versioning()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.version    := 1;
    new.created_at := now();
    new.updated_at := now();
  else
    new.version    := old.version + 1;
    new.created_at := old.created_at;
    new.updated_at := now();
  end if;
  new.sync_xid := pg_catalog.pg_current_xact_id();
  return new;
end
$$;

-- Simple updated_at maintenance for tables that are not synced.
create or replace function private.tg_touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
  else
    new.created_at := old.created_at;
  end if;
  new.updated_at := now();
  return new;
end
$$;

-- Records belong to exactly one library forever: library_id can never change.
-- (RLS WITH CHECK alone would allow a user who is a member of two libraries
-- to move a record between them.)
create or replace function private.tg_library_id_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.library_id is distinct from old.library_id then
    raise exception 'library_id is immutable'
      using errcode = '42501', hint = 'Records cannot be moved between libraries.';
  end if;
  return new;
end
$$;

-- created_by is always the authenticated caller; the client value is ignored.
create or replace function private.tg_set_created_by()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce((select auth.uid()), new.created_by);
  else
    new.created_by := old.created_by;
  end if;
  return new;
end
$$;

-- Rejects UPDATE/DELETE on append-only tables (audit-style data).
create or replace function private.tg_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '42501';
end
$$;

revoke all on all functions in schema private from public, anon;
