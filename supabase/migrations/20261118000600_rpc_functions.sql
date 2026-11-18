-- =============================================================================
-- SmartLibrary Manager — 0600 RPC functions (exposed via /rest/v1/rpc/*)
--
-- All public RPCs are SECURITY INVOKER: they run as the calling user, so every
-- read/write inside them is still filtered by RLS. The single exception is
-- accept_invitation, whose privileged part lives in private.* (see below).
-- Safe to re-run.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- my_libraries(): libraries the caller can access, with role and counts.
-- Used by the Library Switcher. Access is re-validated server-side on every
-- call; the app's locally cached "last library" is only a hint.
-- ----------------------------------------------------------------------------
create or replace function public.my_libraries()
returns table (
  library_id        uuid,
  name              text,
  code              text,
  organization_name text,
  logo_path         text,
  status            text,
  role              text,
  is_super_admin    boolean,
  title_count       bigint,
  copy_count        bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    l.id, l.name, l.code, l.organization_name, l.logo_path, l.status,
    (select m.role from public.library_members m
      where m.library_id = l.id and m.user_id = (select auth.uid())
        and m.membership_status = 'active'),
    (select private.is_super_admin()),
    (select count(*) from public.books b where b.library_id = l.id and b.deleted_at is null),
    (select count(*) from public.book_copies c where c.library_id = l.id and c.deleted_at is null)
  from public.libraries l          -- RLS: only readable libraries are visible
  order by l.name
$$;

-- ----------------------------------------------------------------------------
-- Invitations
-- ----------------------------------------------------------------------------
-- Accepting an invitation must create a library_members row for the caller,
-- which RLS (correctly) does not allow a non-admin to do. The privileged part
-- is therefore a SECURITY DEFINER function in the unexposed private schema,
-- reachable only through the public wrapper. It trusts nothing from the
-- client except the invitation id, and verifies the caller's e-mail against
-- auth.users (not user_metadata).
create or replace function private.accept_invitation_impl(p_invitation_id uuid)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  _uid   uuid := (select auth.uid());
  _email text;
  _inv   public.library_invitations%rowtype;
begin
  if _uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select u.email into _email from auth.users u where u.id = _uid;

  select * into _inv from public.library_invitations i
  where i.id = p_invitation_id
  for update;

  if not found or _inv.status <> 'pending' then
    raise exception 'Invitation not found or no longer pending' using errcode = 'P0002';
  end if;
  if _email is null or lower(_email) <> lower(_inv.email) then
    raise exception 'This invitation was issued to a different e-mail address' using errcode = '42501';
  end if;
  if _inv.expires_at < now() then
    update public.library_invitations set status = 'expired' where id = _inv.id;
    raise exception 'Invitation has expired' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.libraries l where l.id = _inv.library_id and l.status = 'active') then
    raise exception 'Library is not active' using errcode = 'P0001';
  end if;

  insert into public.library_members (library_id, user_id, role, membership_status, invited_by, joined_at)
  values (_inv.library_id, _uid, _inv.role, 'active', _inv.invited_by, now())
  on conflict (library_id, user_id) do update
    set role = excluded.role,
        membership_status = 'active',
        invited_by = excluded.invited_by,
        joined_at = now();

  update public.library_invitations
     set status = 'accepted', accepted_by = _uid, accepted_at = now()
   where id = _inv.id;

  return _inv.library_id;
end
$$;

revoke all on function private.accept_invitation_impl(uuid) from public, anon;
grant execute on function private.accept_invitation_impl(uuid) to authenticated;

create or replace function public.accept_invitation(p_invitation_id uuid)
returns uuid
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.accept_invitation_impl(p_invitation_id)
$$;

-- ----------------------------------------------------------------------------
-- Sync: push
-- ----------------------------------------------------------------------------
-- Columns a client may write per entity. Everything else (library_id, id,
-- version, sync_xid, created_by, timestamps, deleted_at) is server-controlled.
create or replace function private.sync_writable_columns(p_entity text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_entity
    when 'categories'  then array['name', 'code', 'description']
    when 'locations'   then array['building', 'room', 'section', 'rack_code', 'shelf_code', 'description']
    when 'books'       then array['title', 'subtitle', 'isbn', 'author', 'publisher', 'publication_year',
                                  'edition', 'language', 'description', 'category_id', 'call_number',
                                  'cover_image_path', 'metadata_source']
    when 'book_copies' then array['book_id', 'barcode', 'accession_number', 'condition', 'location_id',
                                  'acquisition_date', 'acquisition_source', 'acquisition_cost', 'status',
                                  'remarks']
  end
$$;

-- Applies ONE operation as the calling user (SECURITY INVOKER => RLS applies).
-- Returns {"status": "applied"|"conflict"|"rejected", ...}.
create or replace function private.sync_apply_op(
  p_library_id uuid,
  p_entity     text,
  p_entity_id  uuid,
  p_op         text,
  p_base       bigint,
  p_payload    jsonb
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  _allowed text[] := private.sync_writable_columns(p_entity);
  _cols    text[];
  _collist text;
  _row     jsonb;
  _current jsonb;
begin
  if _allowed is null then
    return jsonb_build_object('status', 'rejected', 'error_code', 'unknown_entity');
  end if;

  select coalesce(array_agg(k order by k), '{}') into _cols
  from jsonb_object_keys(coalesce(p_payload, '{}'::jsonb)) k
  where k = any (_allowed);

  execute format('select to_jsonb(t) from public.%I t where t.id = $1 and t.library_id = $2', p_entity)
    into _current using p_entity_id, p_library_id;

  -- INSERT ------------------------------------------------------------------
  if p_op = 'insert' then
    if _current is not null then
      return jsonb_build_object('status', 'conflict', 'error_code', 'already_exists', 'server_row', _current);
    end if;
    if exists (select 1 from public.sync_tombstones s
               where s.library_id = p_library_id and s.entity_id = p_entity_id) then
      return jsonb_build_object('status', 'rejected', 'error_code', 'deleted_on_server');
    end if;
    _collist := (select string_agg(format('%I', c), ', ') from unnest(_cols) c);
    execute format(
      'insert into public.%1$I (id, library_id%2$s) select $1, $2%3$s from jsonb_populate_record(null::public.%1$I, $3) r returning to_jsonb(%1$I.*)',
      p_entity,
      case when _collist is null then '' else ', ' || _collist end,
      case when _collist is null then '' else ', ' || (select string_agg(format('r.%I', c), ', ') from unnest(_cols) c) end)
      into _row using p_entity_id, p_library_id, p_payload;
    return jsonb_build_object('status', 'applied', 'server_row', _row);
  end if;

  -- UPDATE / DELETE (soft) -----------------------------------------------------
  if _current is null then
    return jsonb_build_object('status', 'rejected', 'error_code', 'not_found');
  end if;
  if p_base is null or p_base <> (_current ->> 'version')::bigint then
    -- Never overwrite silently: report the server row so the user can decide.
    return jsonb_build_object('status', 'conflict', 'error_code', 'version_mismatch',
                              'base_version', p_base, 'server_row', _current);
  end if;

  if p_op = 'delete' then
    if (_current ->> 'deleted_at') is not null then
      return jsonb_build_object('status', 'applied', 'server_row', _current);
    end if;
    execute format(
      'update public.%1$I t set deleted_at = now() where t.id = $1 and t.library_id = $2 and t.version = $3 returning to_jsonb(t.*)',
      p_entity) into _row using p_entity_id, p_library_id, p_base;
  else
    if cardinality(_cols) = 0 then
      return jsonb_build_object('status', 'applied', 'server_row', _current);
    end if;
    execute format(
      'update public.%1$I t set (%2$s) = (select %3$s from jsonb_populate_record(null::public.%1$I, $4) r) where t.id = $1 and t.library_id = $2 and t.version = $3 returning to_jsonb(t.*)',
      p_entity,
      (select string_agg(format('%I', c), ', ') from unnest(_cols) c),
      (select string_agg(format('r.%I', c), ', ') from unnest(_cols) c))
      into _row using p_entity_id, p_library_id, p_base, p_payload;
  end if;

  if _row is null then
    -- Either a concurrent writer bumped the version, or RLS (USING) hid the row
    -- from UPDATE because the caller lacks the required role.
    execute format('select to_jsonb(t) from public.%I t where t.id = $1 and t.library_id = $2', p_entity)
      into _current using p_entity_id, p_library_id;
    if (_current ->> 'version')::bigint = p_base then
      return jsonb_build_object('status', 'rejected', 'error_code', 'forbidden');
    end if;
    return jsonb_build_object('status', 'conflict', 'error_code', 'version_mismatch',
                              'base_version', p_base, 'server_row', _current);
  end if;
  return jsonb_build_object('status', 'applied', 'server_row', _row);
end
$$;

revoke all on function private.sync_writable_columns(text) from public, anon;
revoke all on function private.sync_apply_op(uuid, text, uuid, text, bigint, jsonb) from public, anon;
grant execute on function private.sync_writable_columns(text) to authenticated;
grant execute on function private.sync_apply_op(uuid, text, uuid, text, bigint, jsonb) to authenticated;

-- p_operations: [{operation_id, entity_type, entity_id, operation_type,
--                 base_version, payload, meta: {reference_number, remarks}}]
-- Each operation runs in its own sub-transaction; one bad op never blocks the
-- rest of the batch. Re-sending an operation_id returns the stored result
-- without applying it again (idempotency).
create or replace function public.sync_push(
  p_library_id uuid,
  p_device_id  uuid,
  p_operations jsonb
)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  _uid     uuid := (select auth.uid());
  _op      jsonb;
  _opid    uuid;
  _etype   text;
  _eid     uuid;
  _otype   text;
  _base    bigint;
  _res     jsonb;
  _status  text;
  _code    text;
  _msg     text;
  _cons    text;
  _state   text;
  _prev    record;
  _results jsonb := '[]'::jsonb;
begin
  if _uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if not private.has_library_role(p_library_id, 'staff', true) then
    raise exception 'No write access to this library' using errcode = '42501';
  end if;
  if jsonb_typeof(p_operations) is distinct from 'array' then
    raise exception 'p_operations must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_operations) > 200 then
    raise exception 'Batch too large (max 200 operations)' using errcode = '22023';
  end if;

  perform set_config('app.device_id', coalesce(p_device_id::text, ''), true);

  for _op in select value from jsonb_array_elements(p_operations) loop
    _opid  := private.try_uuid(_op ->> 'operation_id');
    _etype := _op ->> 'entity_type';
    _eid   := private.try_uuid(_op ->> 'entity_id');
    _otype := _op ->> 'operation_type';
    _base  := case when jsonb_typeof(_op -> 'base_version') = 'number'
                   then (_op ->> 'base_version')::bigint end;

    if _opid is null or _eid is null
       or _etype not in ('categories', 'locations', 'books', 'book_copies')
       or _otype not in ('insert', 'update', 'delete') then
      _results := _results || jsonb_build_object(
        'operation_id', _op -> 'operation_id', 'status', 'rejected', 'error_code', 'malformed_operation');
      continue;
    end if;

    insert into public.sync_operations
      (library_id, user_id, device_id, operation_id, entity_type, entity_id, operation_type, base_version, payload)
    values
      (p_library_id, _uid, p_device_id, _opid, _etype, _eid, _otype, _base, coalesce(_op -> 'payload', '{}'::jsonb))
    on conflict (operation_id) do nothing;

    if not found then
      select s.sync_status, s.result, s.library_id into _prev
      from public.sync_operations s where s.operation_id = _opid;
      if not found or _prev.library_id <> p_library_id then
        _results := _results || jsonb_build_object(
          'operation_id', _opid, 'status', 'rejected', 'error_code', 'operation_id_conflict');
      else
        _results := _results || (coalesce(_prev.result, '{}'::jsonb)
          || jsonb_build_object('operation_id', _opid, 'duplicate', true));
      end if;
      continue;
    end if;

    perform set_config('app.movement_reference', coalesce(_op -> 'meta' ->> 'reference_number', ''), true);
    perform set_config('app.movement_remarks', coalesce(_op -> 'meta' ->> 'remarks', ''), true);

    _code := null; _msg := null;
    begin
      _res := private.sync_apply_op(p_library_id, _etype, _eid, _otype, _base, _op -> 'payload');
      _status := _res ->> 'status';
      _code := _res ->> 'error_code';
    exception
      when unique_violation then
        get stacked diagnostics _cons = constraint_name, _msg = message_text;
        _status := 'rejected';
        _code := case _cons
          when 'book_copies_library_barcode_key' then 'duplicate_barcode'
          when 'book_copies_accession_key'       then 'duplicate_accession_number'
          when 'categories_name_key'             then 'duplicate_category'
          when 'locations_slot_key'              then 'duplicate_location'
          else 'duplicate_key' end;
      when foreign_key_violation then
        get stacked diagnostics _msg = message_text;
        _status := 'rejected'; _code := 'invalid_reference';
      when check_violation or not_null_violation or invalid_text_representation
           or numeric_value_out_of_range or datetime_field_overflow or invalid_datetime_format then
        get stacked diagnostics _msg = message_text;
        _status := 'rejected'; _code := 'validation_failed';
      when insufficient_privilege then
        get stacked diagnostics _msg = message_text;
        _status := 'rejected'; _code := 'forbidden';
      when others then
        get stacked diagnostics _state = returned_sqlstate, _msg = message_text;
        _status := 'failed'; _code := 'server_error_' || _state;
    end;

    _res := coalesce(_res, '{}'::jsonb) || jsonb_build_object(
      'operation_id', _opid, 'entity_type', _etype, 'entity_id', _eid,
      'status', _status, 'error_code', _code, 'error_message', _msg);

    update public.sync_operations
       set sync_status = _status, error_code = _code, error_message = _msg,
           result = _res, processed_at = now()
     where operation_id = _opid;

    _results := _results || _res;
  end loop;

  update public.device_registry set last_seen_at = now()
   where id = p_device_id and user_id = _uid;

  return jsonb_build_object('results', _results, 'server_time', now());
end
$$;

-- ----------------------------------------------------------------------------
-- Sync: pull (keyset pagination over transaction ids)
-- ----------------------------------------------------------------------------
-- Algorithm (see docs/sync-design.md):
--   * every write stamps sync_xid = pg_current_xact_id();
--   * a pull "pass" returns rows with sync_xid >= p_since, paginated by
--     (sync_xid, id) using p_after_xid/p_after_id;
--   * the FIRST page returns snapshot_xmin; when the pass finishes the client
--     stores that value as its next p_since.
--   This never misses rows committed by long-running transactions (unlike
--   timestamp or sequence cursors); some rows may be re-sent, which is
--   harmless because the client upserts by (id, version).
create or replace function public.sync_pull(
  p_library_id  uuid,
  p_entity_type text,
  p_since       text default null,
  p_after_xid   text default null,
  p_after_id    uuid default null,
  p_limit       int  default 500
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  _rows  jsonb;
  _n     int;
  _limit int := greatest(1, least(coalesce(p_limit, 500), 1000));
  _since xid8 := coalesce(nullif(p_since, '')::xid8, '0'::xid8);
  _after xid8 := nullif(p_after_xid, '')::xid8;
begin
  if not private.has_library_role(p_library_id, 'viewer', false) then
    raise exception 'No access to this library' using errcode = '42501';
  end if;
  if p_entity_type not in ('categories', 'locations', 'books', 'book_copies',
                           'stock_movements', 'sync_tombstones') then
    raise exception 'Unknown entity type %', p_entity_type using errcode = '22023';
  end if;

  execute format($q$
    select coalesce(jsonb_agg(to_jsonb(t) order by t.sync_xid, t.id), '[]'::jsonb), count(*)
    from (
      select * from public.%I t
      where t.library_id = $1
        and t.sync_xid >= $2
        and ($3::xid8 is null or (t.sync_xid, t.id) > ($3::xid8, $4::uuid))
      order by t.sync_xid, t.id
      limit $5
    ) t
  $q$, p_entity_type)
  into _rows, _n
  using p_library_id, _since, _after, p_after_id, _limit;

  return jsonb_build_object(
    'entity_type',   p_entity_type,
    'rows',          _rows,
    'has_more',      _n = _limit,
    'last_xid',      case when _n > 0 then _rows -> (_n - 1) ->> 'sync_xid' end,
    'last_id',       case when _n > 0 then _rows -> (_n - 1) ->> 'id' end,
    'snapshot_xmin', pg_catalog.pg_snapshot_xmin(pg_catalog.pg_current_snapshot())::text,
    'server_time',   now()
  );
end
$$;

-- ----------------------------------------------------------------------------
-- Dashboard statistics for ONE library (RLS limits what each role sees).
-- ----------------------------------------------------------------------------
create or replace function public.library_dashboard(
  p_library_id uuid,
  p_timezone   text default 'Asia/Kuala_Lumpur'
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  _today_start timestamptz;
  _result jsonb;
begin
  if not private.has_library_role(p_library_id, 'viewer', false) then
    raise exception 'No access to this library' using errcode = '42501';
  end if;
  _today_start := (date_trunc('day', now() at time zone p_timezone)) at time zone p_timezone;

  select jsonb_build_object(
    'library_id', p_library_id,
    'title_count', (select count(*) from public.books b
                    where b.library_id = p_library_id and b.deleted_at is null),
    'copy_count', (select count(*) from public.book_copies c
                   where c.library_id = p_library_id and c.deleted_at is null),
    'copies_by_status', (select coalesce(jsonb_object_agg(s.status, s.n), '{}'::jsonb) from (
                           select c.status, count(*) n from public.book_copies c
                           where c.library_id = p_library_id and c.deleted_at is null
                           group by c.status) s),
    'category_count', (select count(*) from public.categories x
                       where x.library_id = p_library_id and x.deleted_at is null),
    'location_count', (select count(*) from public.locations x
                       where x.library_id = p_library_id and x.deleted_at is null),
    'titles_registered_today', (select count(*) from public.books b
                                where b.library_id = p_library_id and b.created_at >= _today_start),
    'copies_registered_today', (select count(*) from public.book_copies c
                                where c.library_id = p_library_id and c.created_at >= _today_start),
    'active_member_count', (select count(*) from public.library_members m
                            where m.library_id = p_library_id and m.membership_status = 'active'),
    'users_syncing_now', (select count(distinct s.user_id) from public.sync_operations s
                          where s.library_id = p_library_id and s.created_at > now() - interval '5 minutes'),
    'failed_sync_count', (select count(*) from public.sync_operations s
                          where s.library_id = p_library_id
                            and s.sync_status in ('conflict', 'rejected', 'failed')
                            and s.created_at > now() - interval '7 days'),
    'devices', (select coalesce(jsonb_agg(d order by d.last_sync_at desc), '[]'::jsonb) from (
                  select s.device_id, s.user_id, max(s.processed_at) last_sync_at
                  from public.sync_operations s
                  where s.library_id = p_library_id and s.device_id is not null
                  group by s.device_id, s.user_id
                  order by max(s.processed_at) desc nulls last
                  limit 20) d),
    'recent_activity', (select coalesce(jsonb_agg(a order by a.created_at desc), '[]'::jsonb) from (
                          select a.id, a.user_id, a.action, a.entity_type, a.entity_id, a.created_at
                          from public.activity_logs a
                          where a.library_id = p_library_id
                          order by a.created_at desc
                          limit 15) a),
    'by_category', (select coalesce(jsonb_agg(x order by x.title_count desc), '[]'::jsonb) from (
                      select cat.id category_id, coalesce(cat.name, '(Tiada kategori)') category_name,
                             count(distinct b.id) title_count, count(c.id) copy_count
                      from public.books b
                      left join public.categories cat on cat.library_id = b.library_id and cat.id = b.category_id
                      left join public.book_copies c on c.library_id = b.library_id and c.book_id = b.id
                                                      and c.deleted_at is null
                      where b.library_id = p_library_id and b.deleted_at is null
                      group by cat.id, cat.name) x),
    'generated_at', now()
  ) into _result;
  -- Note: library_members / sync_operations rows are RLS-filtered, so a
  -- non-admin sees only their own sync stats and membership.
  return _result;
end
$$;

-- ----------------------------------------------------------------------------
-- Possible duplicate titles (suggestions only; never merges automatically).
-- ----------------------------------------------------------------------------
create or replace function public.find_possible_duplicate_books(
  p_library_id uuid,
  p_isbn       text default null,
  p_title      text default null,
  p_author     text default null,
  p_publisher  text default null,
  p_year       int  default null,
  p_limit      int  default 10
)
returns table (
  book_id          uuid,
  title            text,
  author           text,
  publisher        text,
  publication_year int,
  edition          text,
  isbn             text,
  score            real,
  reasons          text[]
)
language sql
stable
security invoker
set search_path = ''
as $$
  with c as (
    select b.*,
      (p_isbn is not null and b.isbn = p_isbn) as isbn_match,
      case when p_title is null then 0
           else extensions.similarity(lower(b.title), lower(p_title)) end as title_sim,
      case when p_author is null or b.author is null then 0
           else extensions.similarity(lower(b.author), lower(p_author)) end as author_sim,
      (p_publisher is not null and lower(b.publisher) = lower(p_publisher)) as publisher_match,
      (p_year is not null and b.publication_year = p_year) as year_match
    from public.books b
    where b.library_id = p_library_id
      and b.deleted_at is null
      and ((p_isbn is not null and b.isbn = p_isbn)
           or (p_title is not null and extensions.similarity(lower(b.title), lower(p_title)) > 0.4))
  )
  select c.id, c.title, c.author, c.publisher, c.publication_year, c.edition, c.isbn,
    (case when c.isbn_match then 0.5 else 0 end
     + c.title_sim * 0.3 + c.author_sim * 0.1
     + case when c.publisher_match then 0.05 else 0 end
     + case when c.year_match then 0.05 else 0 end)::real as score,
    array_remove(array[
      case when c.isbn_match then 'isbn' end,
      case when c.title_sim > 0.6 then 'title' end,
      case when c.author_sim > 0.6 then 'author' end,
      case when c.publisher_match then 'publisher' end,
      case when c.year_match then 'year' end], null)
  from c
  order by 8 desc
  limit greatest(1, least(coalesce(p_limit, 10), 50))
$$;

-- ----------------------------------------------------------------- grants --
revoke all on function public.my_libraries() from public, anon;
revoke all on function public.accept_invitation(uuid) from public, anon;
revoke all on function public.sync_push(uuid, uuid, jsonb) from public, anon;
revoke all on function public.sync_pull(uuid, text, text, text, uuid, int) from public, anon;
revoke all on function public.library_dashboard(uuid, text) from public, anon;
revoke all on function public.find_possible_duplicate_books(uuid, text, text, text, text, int, int) from public, anon;

grant execute on function public.my_libraries() to authenticated;
grant execute on function public.accept_invitation(uuid) to authenticated;
grant execute on function public.sync_push(uuid, uuid, jsonb) to authenticated;
grant execute on function public.sync_pull(uuid, text, text, text, uuid, int) to authenticated;
grant execute on function public.library_dashboard(uuid, text) to authenticated;
grant execute on function public.find_possible_duplicate_books(uuid, text, text, text, text, int, int) to authenticated;
