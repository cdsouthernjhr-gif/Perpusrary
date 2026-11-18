-- =============================================================================
-- SmartLibrary Manager — 1100 Phase 7: backup restore
--
-- public.restore_library_backup(library, backup jsonb, delete_missing)
--   * SECURITY INVOKER: runs as the caller, so RLS applies to every row; on
--     top of that the caller must be Library Admin of an ACTIVE library
--     (or Super Admin).
--   * ONE transaction: either the whole backup is restored or nothing is.
--   * Validates (again, server-side): format/version, that the backup belongs
--     to THIS library, that every row carries this library_id, relations
--     between records, and barcode uniqueness inside the backup.
--   * Upserts by id (unchanged rows are not touched → no audit noise);
--     optional soft delete of records that are not in the backup.
--   * Removes sync tombstones of restored ids so devices re-download them.
--   * The stock ledger is history and is never rewritten; status changes made
--     by the restore are recorded as new movements ("Restore backup …").
-- Safe to re-run.
-- =============================================================================

create or replace function private.restore_rows(
  p_table      text,
  p_cols       text[],
  p_rows       jsonb,
  p_library_id uuid
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  _cols   text := (select string_agg(format('%I', c), ', ') from unnest(p_cols) c);
  _src    text := (select string_agg(format('src.%I', c), ', ') from unnest(p_cols) c);
  _exc    text := (select string_agg(format('excluded.%I', c), ', ') from unnest(p_cols) c);
  _tgt    text := (select string_agg(format('t.%I', c), ', ') from unnest(p_cols) c);
  _ins    bigint;
  _upd    bigint;
begin
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then
    raise exception 'Backup data for % is not an array', p_table using errcode = '22023';
  end if;
  execute format($q$
    with src as (
      select * from jsonb_populate_recordset(null::public.%1$I, $1)
    ), up as (
      insert into public.%1$I as t (id, library_id, %2$s)
      select src.id, $2, %3$s from src
      on conflict (id) do update set (%2$s) = row(%4$s)
        where t.library_id = $2 and (%5$s) is distinct from (%4$s)
      returning (xmax = 0) as ins
    )
    select count(*) filter (where ins), count(*) filter (where not ins) from up
  $q$, p_table, _cols, _src, _exc, _tgt)
  into _ins, _upd
  using coalesce(p_rows, '[]'::jsonb), p_library_id;
  return jsonb_build_object('inserted', _ins, 'updated', _upd,
                            'total', jsonb_array_length(coalesce(p_rows, '[]'::jsonb)));
end
$$;

-- Clients have no DELETE on sync_tombstones (append-only for them). Restore
-- needs to remove tombstones of ids it brings back, so this one narrow
-- SECURITY DEFINER helper does it after re-checking the caller's role.
create or replace function private.clear_tombstones(p_library_id uuid, p_ids uuid[])
returns int
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare _n int;
begin
  if not private.has_library_role(p_library_id, 'library_admin', true) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  delete from public.sync_tombstones st
  where st.library_id = p_library_id and st.entity_id = any (p_ids);
  get diagnostics _n = row_count;
  return _n;
end
$$;
revoke all on function private.clear_tombstones(uuid, uuid[]) from public, anon;
grant execute on function private.clear_tombstones(uuid, uuid[]) to authenticated;

create or replace function public.restore_library_backup(
  p_library_id     uuid,
  p_backup         jsonb,
  p_delete_missing boolean default false
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  _data    jsonb := p_backup -> 'data';
  _ids     jsonb;
  _result  jsonb := '{}'::jsonb;
  _deleted jsonb := '{}'::jsonb;
  _n       bigint;
  _bad     text;
  t        text;
  _cols    constant jsonb := jsonb_build_object(
    'categories',  jsonb_build_array('name', 'code', 'description', 'deleted_at'),
    'locations',   jsonb_build_array('building', 'room', 'section', 'rack_code', 'shelf_code', 'description', 'deleted_at'),
    'books',       jsonb_build_array('title', 'subtitle', 'isbn', 'author', 'publisher', 'publication_year', 'edition',
                                     'language', 'description', 'category_id', 'call_number', 'cover_image_path',
                                     'metadata_source', 'deleted_at'),
    'book_copies', jsonb_build_array('book_id', 'barcode', 'accession_number', 'condition', 'location_id',
                                     'acquisition_date', 'acquisition_source', 'acquisition_cost', 'status',
                                     'remarks', 'deleted_at'));
begin
  -- Authorization (RLS also applies to every statement below).
  if not private.has_library_role(p_library_id, 'library_admin', true) then
    raise exception 'Only the Library Admin of this (active) library can restore a backup'
      using errcode = '42501';
  end if;

  -- Format & ownership
  if p_backup ->> 'format' is distinct from 'smartlibrary-backup' or (p_backup ->> 'version')::int is distinct from 1 then
    raise exception 'Unsupported backup format' using errcode = '22023';
  end if;
  if (p_backup -> 'library' ->> 'id') is distinct from p_library_id::text then
    raise exception 'This backup belongs to another library' using errcode = '22023';
  end if;
  foreach t in array array['categories', 'locations', 'books', 'book_copies'] loop
    if jsonb_typeof(coalesce(_data -> t, '[]'::jsonb)) <> 'array' then
      raise exception 'Backup section % is invalid', t using errcode = '22023';
    end if;
    select e ->> 'id' into _bad from jsonb_array_elements(coalesce(_data -> t, '[]'::jsonb)) e
    where (e ->> 'library_id') is distinct from p_library_id::text or private.try_uuid(e ->> 'id') is null
    limit 1;
    if found then
      raise exception 'Backup row % in % does not belong to this library', _bad, t using errcode = '22023';
    end if;
  end loop;

  -- Relations inside the backup
  select b ->> 'id' into _bad from jsonb_array_elements(coalesce(_data -> 'books', '[]')) b
  where b ->> 'category_id' is not null
    and not exists (select 1 from jsonb_array_elements(coalesce(_data -> 'categories', '[]')) c
                    where c ->> 'id' = b ->> 'category_id')
  limit 1;
  if found then raise exception 'Book % references a category missing from the backup', _bad using errcode = '23503'; end if;

  select c ->> 'id' into _bad from jsonb_array_elements(coalesce(_data -> 'book_copies', '[]')) c
  where not exists (select 1 from jsonb_array_elements(coalesce(_data -> 'books', '[]')) b where b ->> 'id' = c ->> 'book_id')
     or (c ->> 'location_id' is not null
         and not exists (select 1 from jsonb_array_elements(coalesce(_data -> 'locations', '[]')) l
                         where l ->> 'id' = c ->> 'location_id'))
  limit 1;
  if found then raise exception 'Copy % references a book/location missing from the backup', _bad using errcode = '23503'; end if;

  select c ->> 'barcode' into _bad from jsonb_array_elements(coalesce(_data -> 'book_copies', '[]')) c
  group by c ->> 'barcode' having count(*) > 1 limit 1;
  if found then raise exception 'Barcode % appears twice in the backup', _bad using errcode = '23505'; end if;

  perform set_config('app.movement_reference',
                     left('Restore backup ' || coalesce(p_backup ->> 'created_at', ''), 100), true);

  -- Optional: soft delete records that are not in the backup (children first).
  if p_delete_missing then
    foreach t in array array['book_copies', 'books', 'locations', 'categories'] loop
      execute format($q$
        with gone as (
          update public.%1$I x set deleted_at = now()
          where x.library_id = $1 and x.deleted_at is null
            and x.id::text not in (select e ->> 'id' from jsonb_array_elements($2) e)
          returning 1)
        select count(*) from gone $q$, t)
      into _n using p_library_id, coalesce(_data -> t, '[]'::jsonb);
      _deleted := _deleted || jsonb_build_object(t, _n);
    end loop;
  end if;

  -- Upserts, parents first.
  foreach t in array array['categories', 'locations', 'books', 'book_copies'] loop
    _result := _result || jsonb_build_object(t, private.restore_rows(
      t, array(select jsonb_array_elements_text(_cols -> t)), _data -> t, p_library_id));
  end loop;

  -- Restored ids must not be deleted again by an old tombstone on devices.
  select jsonb_agg(e -> 'id') into _ids from (
    select jsonb_array_elements(coalesce(_data -> 'categories', '[]')) e
    union all select jsonb_array_elements(coalesce(_data -> 'locations', '[]'))
    union all select jsonb_array_elements(coalesce(_data -> 'books', '[]'))
    union all select jsonb_array_elements(coalesce(_data -> 'book_copies', '[]'))) s;
  perform private.clear_tombstones(p_library_id,
    array(select private.try_uuid(jsonb_array_elements_text(coalesce(_ids, '[]'::jsonb)))));

  return jsonb_build_object('restored', _result, 'soft_deleted', _deleted, 'restored_at', now());
end
$$;

revoke all on function private.restore_rows(text, text[], jsonb, uuid) from public, anon;
grant execute on function private.restore_rows(text, text[], jsonb, uuid) to authenticated;
revoke all on function public.restore_library_backup(uuid, jsonb, boolean) from public, anon;
grant execute on function public.restore_library_backup(uuid, jsonb, boolean) to authenticated;

-- -----------------------------------------------------------------------------
-- Fix: the role guards (0500) also blocked the database owner / service jobs
-- (no JWT, e.g. SQL editor maintenance). They are meant for API users only.
-- -----------------------------------------------------------------------------
create or replace function private.is_api_user()
returns boolean
language sql
stable
set search_path = ''
as $$
  select current_user in ('authenticated', 'anon')
$$;
revoke all on function private.is_api_user() from public, anon;
grant execute on function private.is_api_user() to authenticated;

create or replace function private.tg_libraries_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if private.is_api_user() and not private.is_super_admin()
     and (new.status is distinct from old.status or new.code is distinct from old.code) then
    raise exception 'Only a Super Admin can change library code or status' using errcode = '42501';
  end if;
  return new;
end
$$;

create or replace function private.tg_book_copies_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if private.is_api_user()
     and (new.barcode is distinct from old.barcode
          or new.book_id is distinct from old.book_id
          or new.deleted_at is distinct from old.deleted_at)
     and not private.has_library_role(old.library_id, 'editor', true) then
    raise exception 'Editor role required to change barcode, book or deletion state'
      using errcode = '42501';
  end if;
  return new;
end
$$;
revoke all on function private.tg_libraries_guard(), private.tg_book_copies_guard() from public, anon, authenticated;
