-- =============================================================================
-- SmartLibrary Manager — 0700 Storage buckets & policies
--
-- Both buckets are PRIVATE (no public URLs). Clients download via short-lived
-- signed URLs, which Storage only issues if the SELECT policy below allows it.
-- Object path convention:  <library_id>/<...>
--   library-assets : <library_id>/logo/<file>, <library_id>/covers/<book_id>.<ext>
--   library-backups: <library_id>/<yyyy>/<backup_id>.json.gz
-- The first folder segment is parsed with private.try_uuid so a malformed
-- name simply fails the check instead of raising.
-- Safe to re-run.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('library-assets',  'library-assets',  false, 5 * 1024 * 1024,
     array['image/jpeg', 'image/png', 'image/webp']),
  ('library-backups', 'library-backups', false, 200 * 1024 * 1024,
     array['application/gzip', 'application/json', 'application/octet-stream'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

do $$
declare p text;
begin
  foreach p in array array[
    'slm_assets_select', 'slm_assets_insert', 'slm_assets_update', 'slm_assets_delete',
    'slm_backups_select', 'slm_backups_insert', 'slm_backups_update', 'slm_backups_delete'] loop
    execute format('drop policy if exists %I on storage.objects', p);
  end loop;
end $$;

-- ------------------------------------------------------- library-assets --
create policy slm_assets_select on storage.objects for select to authenticated
using (
  bucket_id = 'library-assets'
  and private.try_uuid((storage.foldername(name))[1]) in (select private.readable_library_ids())
);
create policy slm_assets_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'library-assets'
  and private.try_uuid((storage.foldername(name))[1]) in (select private.writable_library_ids('staff'))
);
create policy slm_assets_update on storage.objects for update to authenticated
using (
  bucket_id = 'library-assets'
  and private.try_uuid((storage.foldername(name))[1]) in (select private.writable_library_ids('staff'))
)
with check (
  bucket_id = 'library-assets'
  and private.try_uuid((storage.foldername(name))[1]) in (select private.writable_library_ids('staff'))
);
create policy slm_assets_delete on storage.objects for delete to authenticated
using (
  bucket_id = 'library-assets'
  and private.try_uuid((storage.foldername(name))[1]) in (select private.writable_library_ids('editor'))
);

-- ------------------------------------------------------ library-backups --
-- Library Admins (of that library) and Super Admins only.
create policy slm_backups_select on storage.objects for select to authenticated
using (
  bucket_id = 'library-backups'
  and private.try_uuid((storage.foldername(name))[1])
      in (select private.library_ids_with_role('library_admin', false))
);
create policy slm_backups_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'library-backups'
  and private.try_uuid((storage.foldername(name))[1]) in (select private.writable_library_ids('library_admin'))
);
create policy slm_backups_update on storage.objects for update to authenticated
using (
  bucket_id = 'library-backups'
  and private.try_uuid((storage.foldername(name))[1]) in (select private.writable_library_ids('library_admin'))
)
with check (
  bucket_id = 'library-backups'
  and private.try_uuid((storage.foldername(name))[1]) in (select private.writable_library_ids('library_admin'))
);
create policy slm_backups_delete on storage.objects for delete to authenticated
using (
  bucket_id = 'library-backups'
  and private.try_uuid((storage.foldername(name))[1]) in (select private.writable_library_ids('library_admin'))
);
