-- =============================================================================
-- SmartLibrary Manager — 1000 Phase 6: richer sync_push results
--
-- Rejected update/delete operations ("forbidden", constraint violations, …)
-- now also return the current server row (when the caller may read it), so a
-- device can discard its local change and restore the exact server state
-- without a full re-download.
-- Safe to re-run (CREATE OR REPLACE).
-- =============================================================================

create or replace function private.sync_current_row(p_entity text, p_library_id uuid, p_entity_id uuid)
returns jsonb
language plpgsql
stable
security invoker          -- RLS applies: only rows the caller may read
set search_path = ''
as $$
declare _row jsonb;
begin
  if p_entity not in ('categories', 'locations', 'books', 'book_copies') then
    return null;
  end if;
  execute format('select to_jsonb(t) from public.%I t where t.id = $1 and t.library_id = $2', p_entity)
    into _row using p_entity_id, p_library_id;
  return _row;
end
$$;
revoke all on function private.sync_current_row(text, uuid, uuid) from public, anon;
grant execute on function private.sync_current_row(text, uuid, uuid) to authenticated;

-- Wrap sync_push results: add server_row to rejected/failed results that lack
-- one. The core push logic from 0600 is kept unchanged and moved to
-- private.sync_push_core (not exposed); public.sync_push becomes a wrapper.
-- Idempotent: if 0600 is re-applied it recreates public.sync_push as the core,
-- which is moved again here (replacing the previous core).
do $$
begin
  -- public.sync_push is the 0600 core when it does not call sync_push_core.
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'sync_push'
      and pg_get_functiondef(p.oid) not like '%sync_push_core%'
  ) then
    drop function if exists private.sync_push_core(uuid, uuid, jsonb);
    alter function public.sync_push(uuid, uuid, jsonb) rename to sync_push_core;
    alter function public.sync_push_core(uuid, uuid, jsonb) set schema private;
  end if;
end $$;
revoke all on function private.sync_push_core(uuid, uuid, jsonb) from public, anon;
grant execute on function private.sync_push_core(uuid, uuid, jsonb) to authenticated;
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
  _res     jsonb;
  _out     jsonb := '[]'::jsonb;
  _r       jsonb;
begin
  _res := private.sync_push_core(p_library_id, p_device_id, p_operations);
  for _r in select value from jsonb_array_elements(_res -> 'results') loop
    if (_r ->> 'status') in ('rejected', 'failed')
       and (_r -> 'server_row') is null
       and private.try_uuid(_r ->> 'entity_id') is not null then
      _r := _r || jsonb_build_object('server_row',
        private.sync_current_row(_r ->> 'entity_type', p_library_id, (_r ->> 'entity_id')::uuid));
    end if;
    _out := _out || _r;
  end loop;
  return jsonb_set(_res, '{results}', _out);
end
$$;

revoke all on function public.sync_push(uuid, uuid, jsonb) from public, anon;
grant execute on function public.sync_push(uuid, uuid, jsonb) to authenticated;
