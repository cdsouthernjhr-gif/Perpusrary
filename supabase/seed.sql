-- =============================================================================
-- Local development seed (applied by `supabase db reset`).
-- Creates two demo libraries. Users are NOT seeded: sign up through the app,
-- then bootstrap the first Super Admin from the SQL editor:
--
--   insert into public.system_admins (user_id)
--   select id from auth.users where email = 'you@example.com';
--
-- and give a user a library role:
--
--   insert into public.library_members (library_id, user_id, role)
--   select l.id, u.id, 'library_admin'
--   from public.libraries l, auth.users u
--   where l.code = 'DEMO-A' and u.email = 'you@example.com';
-- =============================================================================
insert into public.libraries (name, code, organization_name, address)
values
  ('Perpustakaan Demo A', 'DEMO-A', 'Sekolah Demo A', 'Jalan Ilmu 1'),
  ('Perpustakaan Demo B', 'DEMO-B', 'Sekolah Demo B', 'Jalan Ilmu 2')
on conflict do nothing;
