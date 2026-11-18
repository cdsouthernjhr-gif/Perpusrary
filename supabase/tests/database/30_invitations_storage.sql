-- =============================================================================
-- Invitations + Storage (backups / assets) isolation.
-- =============================================================================
begin;
select tests.seed();
create temp table t_inv (id uuid);
grant all on t_inv to authenticated;

-- ------------------------------------------------------------ invitations --
select tests.become('admin_a'); set local role authenticated;
insert into public.library_invitations (library_id, email, role, invited_by)
values (tests.id('lib_a'), 'Invitee@Test.Local', 'viewer', tests.uid('admin_b'));  -- invited_by is forced to caller
reset role;
insert into t_inv select id from public.library_invitations where library_id = tests.id('lib_a');
select tests.is((select invited_by from public.library_invitations limit 1), tests.uid('admin_a'),
  'invited_by is forced to the caller');

select tests.become('outsider'); set local role authenticated;
select tests.is(tests.count('select 1 from public.library_invitations'), 0::bigint, 'others cannot see the invitation');
select tests.throws(format('select public.accept_invitation(%L)', (select id from t_inv)), '42501',
  'a different user cannot accept the invitation');
reset role;

select tests.become('invitee'); set local role authenticated;
select tests.is(tests.count('select 1 from public.library_invitations'), 1::bigint, 'invitee sees own pending invitation');
select tests.is(public.accept_invitation((select id from t_inv)), tests.id('lib_a'), 'invitee accepts invitation');
select tests.is(tests.count('select 1 from public.books'), 1::bigint, 'invitee now reads library A');
select tests.is((select role from public.my_libraries()), 'viewer', 'invitee has the invited role (viewer)');
select tests.throws(format('select public.accept_invitation(%L)', (select id from t_inv)), 'P0002',
  'invitation cannot be accepted twice');
reset role;

-- ----------------------------------------------------------------- storage --
select tests.become('admin_a'); set local role authenticated;
select tests.is(tests.rows_affected(format(
  'insert into storage.objects (bucket_id, name) values (%L, %L)', 'library-backups', tests.id('lib_a')::text || '/2026/b1.json.gz')),
  1::bigint, 'admin_a can upload a backup into library A folder');
select tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)',
  'library-backups', tests.id('lib_b')::text || '/2026/evil.json.gz'), '42501', 'admin_a cannot upload into library B folder');
select tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)',
  'library-backups', 'not-a-uuid/x.json.gz'), '42501', 'malformed backup path is rejected');
select tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)',
  'library-backups', 'top-level.json.gz'), '42501', 'backup outside any library folder is rejected');
reset role;
-- Seed a backup for library B as owner
insert into storage.objects (bucket_id, name) values ('library-backups', tests.id('lib_b')::text || '/2026/b2.json.gz');

select tests.become('admin_a'); set local role authenticated;
select tests.is(tests.count(format('select 1 from storage.objects where bucket_id = %L', 'library-backups')), 1::bigint,
  'admin_a lists only library A backups');
select tests.is(tests.rows_affected(format('delete from storage.objects where name like %L', tests.id('lib_b')::text || '/%')),
  0::bigint, 'admin_a cannot delete library B backups');
reset role;

select tests.become('viewer_a'); set local role authenticated;
select tests.is(tests.count(format('select 1 from storage.objects where bucket_id = %L', 'library-backups')), 0::bigint,
  'viewer cannot see backups even of own library');
reset role;

select tests.become('admin_b'); set local role authenticated;
select tests.is(tests.count(format('select 1 from storage.objects where name like %L', tests.id('lib_a')::text || '/%')),
  0::bigint, 'admin_b cannot read library A backup objects');
reset role;

-- Assets (covers/logos)
select tests.become('staff_a'); set local role authenticated;
select tests.is(tests.rows_affected(format('insert into storage.objects (bucket_id, name) values (%L, %L)',
  'library-assets', tests.id('lib_a')::text || '/covers/x.jpg')), 1::bigint, 'staff can upload a cover to library A');
select tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)',
  'library-assets', tests.id('lib_b')::text || '/covers/x.jpg'), '42501', 'staff cannot upload a cover to library B');
reset role;
select tests.become('staff_b'); set local role authenticated;
select tests.is(tests.count(format('select 1 from storage.objects where bucket_id = %L', 'library-assets')), 0::bigint,
  'staff_b cannot see library A assets');
reset role;

select tests.is((select bool_and(not public) from storage.buckets where id in ('library-assets', 'library-backups')), true,
  'both buckets are private');

rollback;
