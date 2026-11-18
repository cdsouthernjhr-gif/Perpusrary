-- =============================================================================
-- Phase 3: member management, profiles, library creation.
-- =============================================================================
begin;
select tests.seed();

-- Profile e-mail mirrored from auth.users and not client-editable
select tests.is((select email from public.user_profiles where id = tests.uid('admin_a')), 'admin_a@test.local',
  'profile e-mail mirrored from auth.users');
update auth.users set email = 'admin.a.new@test.local' where id = tests.uid('admin_a');
select tests.is((select email from public.user_profiles where id = tests.uid('admin_a')), 'admin.a.new@test.local',
  'profile e-mail follows auth.users changes');

select tests.become('staff_a'); set local role authenticated;
select tests.throws(format('update public.user_profiles set email = %L where id = %L', 'fake@x.my', tests.uid('staff_a')),
  '42501', 'user cannot change own profile e-mail');
select tests.is(tests.rows_affected(format('update public.user_profiles set full_name = %L, phone = %L where id = %L',
  'Staf A', '012-3456789', tests.uid('staff_a'))), 1::bigint, 'user can edit own name and phone');
-- Non-admin sees only themselves in the member list
select tests.is(tests.count(format('select 1 from public.library_member_list(%L)', tests.id('lib_a'))), 1::bigint,
  'staff sees only own membership in member list');
reset role;

select tests.become('admin_a'); set local role authenticated;
select tests.is(tests.count(format('select 1 from public.library_member_list(%L)', tests.id('lib_a'))), 6::bigint,
  'library admin sees all 6 members of library A');
select tests.is((select full_name from public.library_member_list(tests.id('lib_a')) where user_id = tests.uid('staff_a')),
  'Staf A', 'member list includes profile names');
select tests.is(tests.count(format('select 1 from public.library_member_list(%L)', tests.id('lib_b'))), 0::bigint,
  'library admin A sees no members of library B');
-- Role change / deactivate / reactivate in own library
select tests.is(tests.rows_affected(format('update public.library_members set role = %L where library_id = %L and user_id = %L',
  'editor', tests.id('lib_a'), tests.uid('staff_a'))), 1::bigint, 'admin can change a member role');
select tests.is(tests.rows_affected(format('update public.library_members set membership_status = %L where library_id = %L and user_id = %L',
  'removed', tests.id('lib_a'), tests.uid('viewer_a'))), 1::bigint, 'admin can deactivate a member');
select tests.throws('select public.create_library(''X'', ''XLIB'')', '42501', 'library admin cannot create_library');
reset role;

select tests.become('viewer_a'); set local role authenticated;
select tests.is(tests.count('select 1 from public.books'), 0::bigint, 'deactivated member immediately loses access');
reset role;

-- Super Admin creates a library with an invited first admin
select tests.become('super'); set local role authenticated;
create temp table t_new (id uuid);
insert into t_new select public.create_library('Perpustakaan Organisasi D', 'lib-d', p_admin_email => 'Outsider@Test.Local');
select tests.is((select code from public.libraries where id = (select id from t_new)), 'LIB-D', 'create_library normalises code');
select tests.is((select role from public.library_invitations where library_id = (select id from t_new)), 'library_admin',
  'create_library invites the first library admin');
select tests.throws('select public.create_library(''Dup'', ''LIB-D'')', '23505', 'create_library rejects duplicate code');
reset role;

select tests.become('outsider'); set local role authenticated;
select tests.is((select library_name from public.library_invitations where library_id = (select id from t_new)),
  'Perpustakaan Organisasi D', 'invitee sees the inviting library name');
select tests.is(public.accept_invitation((select id from public.library_invitations where library_id = (select id from t_new))),
  (select id from t_new), 'invited admin accepts');
select tests.is((select role from public.my_libraries() where library_id = (select id from t_new)), 'library_admin',
  'new library now has its admin');
reset role;

rollback;
