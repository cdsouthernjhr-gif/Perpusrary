-- =============================================================================
-- RLS: library isolation & role enforcement.
-- Covers the 7 mandatory tests from the specification plus extra cases.
-- Everything runs in one transaction and is rolled back.
-- =============================================================================
begin;
select tests.seed();

-- ---------------------------------------------------------------------------
-- [1] User A can read Library A
-- ---------------------------------------------------------------------------
select tests.become('admin_a'); set local role authenticated;
select tests.is(tests.count('select 1 from public.libraries'), 1::bigint, '[1] admin_a sees exactly 1 library');
select tests.is(tests.count(format('select 1 from public.books where library_id = %L', tests.id('lib_a'))), 1::bigint,
  '[1] admin_a reads books of library A');
select tests.is(tests.count(format('select 1 from public.book_copies where library_id = %L', tests.id('lib_a'))), 1::bigint,
  '[1] admin_a reads copies of library A');

-- ---------------------------------------------------------------------------
-- [2] User A cannot read Library B (even when asking for it explicitly)
-- ---------------------------------------------------------------------------
select tests.is(tests.count(format('select 1 from public.libraries where id = %L', tests.id('lib_b'))), 0::bigint,
  '[2] admin_a cannot see library B row');
select tests.is(tests.count(format('select 1 from public.books where library_id = %L', tests.id('lib_b'))), 0::bigint,
  '[2] admin_a cannot read books of library B');
select tests.is(tests.count(format('select 1 from public.book_copies where id = %L', tests.id('copy_b'))), 0::bigint,
  '[2] admin_a cannot read copy of library B by id (IDOR)');
select tests.is(tests.count(format('select 1 from public.categories where library_id = %L', tests.id('lib_b'))), 0::bigint,
  '[2] admin_a cannot read categories of library B');
select tests.is(tests.count(format('select 1 from public.stock_movements where library_id = %L', tests.id('lib_b'))), 0::bigint,
  '[2] admin_a cannot read stock movements of library B');
select tests.is(tests.count(format('select 1 from public.activity_logs where library_id = %L', tests.id('lib_b'))), 0::bigint,
  '[2] admin_a cannot read activity logs of library B');
select tests.throws(format('select public.library_dashboard(%L)', tests.id('lib_b')), '42501',
  '[2] admin_a cannot load dashboard of library B');
select tests.throws(format('select public.sync_pull(%L, %L)', tests.id('lib_b'), 'books'), '42501',
  '[2] admin_a cannot sync_pull library B');
select tests.is(tests.count(format('select 1 from public.find_possible_duplicate_books(%L, %L)', tests.id('lib_b'), '9789830000002')),
  0::bigint, '[2] duplicate finder returns nothing for library B');
-- Poisoned JWT metadata ("user_metadata.role = super_admin") grants nothing.
select tests.is(tests.count('select 1 from public.my_libraries() where is_super_admin'), 0::bigint,
  '[2] user_metadata role claim is ignored');
reset role;

-- ---------------------------------------------------------------------------
-- [3] User B can read Library B (and only B)
-- ---------------------------------------------------------------------------
select tests.become('staff_b'); set local role authenticated;
select tests.is(tests.count(format('select 1 from public.books where library_id = %L', tests.id('lib_b'))), 1::bigint,
  '[3] staff_b reads books of library B');
select tests.is(tests.count('select 1 from public.books'), 1::bigint, '[3] staff_b sees only library B books');
select tests.is(tests.count('select 1 from public.my_libraries()'), 1::bigint, '[3] my_libraries for staff_b = 1');
reset role;

-- ---------------------------------------------------------------------------
-- [4] User A cannot move a record to Library B (change library_id)
-- ---------------------------------------------------------------------------
select tests.become('admin_a'); set local role authenticated;
select tests.throws(format('update public.books set library_id = %L where id = %L', tests.id('lib_b'), tests.id('book_a')),
  '42501', '[4] admin_a cannot change book.library_id to B');
select tests.throws(format('insert into public.books (library_id, title) values (%L, %L)', tests.id('lib_b'), 'Injected'),
  '42501', '[4] admin_a cannot insert a book into library B');
select tests.throws(format('insert into public.book_copies (library_id, book_id, barcode) values (%L, %L, %L)',
  tests.id('lib_b'), tests.id('book_b'), 'X-1'), '42501', '[4] admin_a cannot insert a copy into library B');
reset role;
-- Even a user who is editor in BOTH libraries cannot move data between them.
select tests.become('dual'); set local role authenticated;
select tests.throws(format('update public.books set library_id = %L where id = %L', tests.id('lib_b'), tests.id('book_a')),
  '42501', '[4] dual-library editor cannot move a book between libraries');
select tests.throws(format('update public.book_copies set library_id = %L where id = %L', tests.id('lib_b'), tests.id('copy_a')),
  '42501', '[4] dual-library editor cannot move a copy between libraries');
-- Composite FK: a copy in A cannot point at a book in B.
select tests.throws(format('insert into public.book_copies (library_id, book_id, barcode) values (%L, %L, %L)',
  tests.id('lib_a'), tests.id('book_b'), 'XLIB-1'), '23503', '[4] copy in A cannot reference a book in B (composite FK)');
select tests.throws(format('update public.books set category_id = %L where id = %L', tests.id('cat_b'), tests.id('book_a')),
  '23503', '[4] book in A cannot reference a category in B (composite FK)');
reset role;

-- ---------------------------------------------------------------------------
-- [5] Users without membership cannot access data
-- ---------------------------------------------------------------------------
select tests.become('outsider'); set local role authenticated;
select tests.is(tests.count('select 1 from public.libraries'), 0::bigint, '[5] outsider sees no libraries');
select tests.is(tests.count('select 1 from public.books'), 0::bigint, '[5] outsider sees no books');
select tests.is(tests.count('select 1 from public.book_copies'), 0::bigint, '[5] outsider sees no copies');
select tests.is(tests.count('select 1 from public.library_members'), 0::bigint, '[5] outsider sees no memberships');
select tests.is(tests.count('select 1 from public.my_libraries()'), 0::bigint, '[5] my_libraries empty for outsider');
select tests.throws(format('insert into public.books (library_id, title) values (%L, %L)', tests.id('lib_a'), 'X'),
  '42501', '[5] outsider cannot insert into library A');
select tests.throws(format('insert into public.library_members (library_id, user_id, role) values (%L, %L, %L)',
  tests.id('lib_a'), tests.uid('outsider'), 'library_admin'), '42501', '[5] outsider cannot add themselves as member');
select tests.throws(format('insert into public.system_admins (user_id) values (%L)', tests.uid('outsider')),
  '42501', '[5] outsider cannot make themselves Super Admin');
reset role;

-- Removed (deactivated) member
select tests.become('removed_a'); set local role authenticated;
select tests.is(tests.count('select 1 from public.books'), 0::bigint, '[5] removed member sees no books');
select tests.is(tests.count('select 1 from public.library_members'), 1::bigint, '[5] removed member still sees own membership row');
-- UPDATE is silently filtered by RLS (0 rows), not an error:
select tests.is(tests.rows_affected(format('update public.library_members set membership_status = %L where user_id = %L',
  'active', tests.uid('removed_a'))), 0::bigint, '[5] removed member cannot reactivate own membership');
reset role;

-- Anonymous (not logged in)
select tests.clear_claims(); set local role anon;
select tests.throws('select 1 from public.books', '42501', '[5] anon has no privilege on books');
select tests.throws('select 1 from public.libraries', '42501', '[5] anon has no privilege on libraries');
select tests.throws('select public.my_libraries()', '42501', '[5] anon cannot execute my_libraries');
reset role;

-- ---------------------------------------------------------------------------
-- [6] Viewer cannot modify data
-- ---------------------------------------------------------------------------
select tests.become('viewer_a'); set local role authenticated;
select tests.is(tests.count('select 1 from public.books'), 1::bigint, '[6] viewer can read books');
select tests.throws(format('insert into public.books (library_id, title) values (%L, %L)', tests.id('lib_a'), 'X'),
  '42501', '[6] viewer cannot insert books');
select tests.is(tests.rows_affected(format('update public.books set title = %L where id = %L', 'Hacked', tests.id('book_a'))),
  0::bigint, '[6] viewer update of books affects 0 rows');
select tests.is(tests.rows_affected(format('update public.book_copies set status = %L where id = %L', 'lost', tests.id('copy_a'))),
  0::bigint, '[6] viewer update of copies affects 0 rows');
select tests.is(tests.rows_affected(format('delete from public.book_copies where id = %L', tests.id('copy_a'))),
  0::bigint, '[6] viewer delete of copies affects 0 rows');
select tests.throws(format('insert into public.categories (library_id, name) values (%L, %L)', tests.id('lib_a'), 'X'),
  '42501', '[6] viewer cannot insert categories');
select tests.throws(format('select public.sync_push(%L, null, %L::jsonb)', tests.id('lib_a'), '[]'),
  '42501', '[6] viewer cannot sync_push');
select tests.throws('insert into public.stock_movements (library_id, copy_id, movement_type, quantity) values ('
  || quote_literal(tests.id('lib_a')) || ',' || quote_literal(tests.id('copy_a')) || ', ''adjustment'', 1)',
  '42501', '[6] nobody can write stock_movements directly');
reset role;
select tests.is((select title from public.books where id = tests.id('book_a')), 'Hikayat Hang Tuah',
  '[6] book title unchanged after viewer attempts');

-- ---------------------------------------------------------------------------
-- [7] Library Admin cannot manage another library
-- ---------------------------------------------------------------------------
select tests.become('admin_a'); set local role authenticated;
select tests.is(tests.rows_affected(format('update public.libraries set name = %L where id = %L', 'Hijacked', tests.id('lib_b'))),
  0::bigint, '[7] admin_a cannot rename library B');
select tests.throws(format('insert into public.library_members (library_id, user_id, role) values (%L, %L, %L)',
  tests.id('lib_b'), tests.uid('outsider'), 'library_admin'), '42501', '[7] admin_a cannot add members to library B');
select tests.is(tests.rows_affected(format('update public.library_members set role = %L where library_id = %L',
  'viewer', tests.id('lib_b'))), 0::bigint, '[7] admin_a cannot change roles in library B');
select tests.throws(format('insert into public.library_invitations (library_id, email, role) values (%L, %L, %L)',
  tests.id('lib_b'), 'x@test.local', 'editor'), '42501', '[7] admin_a cannot invite to library B');
select tests.is(tests.rows_affected(format('delete from public.books where library_id = %L', tests.id('lib_b'))),
  0::bigint, '[7] admin_a cannot delete books of library B');
select tests.throws(format('insert into public.backup_records (library_id, file_path) values (%L, %L)',
  tests.id('lib_b'), tests.id('lib_b')::text || '/x.json.gz'), '42501', '[7] admin_a cannot create backup records for B');
-- ...but can manage their own library
select tests.is(tests.rows_affected(format('update public.libraries set name = %L where id = %L',
  'Perpustakaan Sekolah A (Baharu)', tests.id('lib_a'))), 1::bigint, '[7] admin_a can rename library A');
select tests.throws(format('update public.libraries set status = %L where id = %L', 'inactive', tests.id('lib_a')),
  '42501', '[7] only Super Admin can change library status');
select tests.throws('insert into public.libraries (name, code) values (''Baru'', ''NEW1'')', '42501',
  '[7] library admin cannot create libraries');
select tests.is(tests.rows_affected(format('insert into public.library_members (library_id, user_id, role) values (%L, %L, %L)',
  tests.id('lib_a'), tests.uid('outsider'), 'viewer')), 1::bigint, '[7] admin_a can add a member to library A');
-- Last-admin protection
select tests.throws(format('update public.library_members set role = %L where library_id = %L and user_id = %L',
  'editor', tests.id('lib_a'), tests.uid('admin_a')), '23514', '[7] cannot demote the last library_admin');
reset role;

-- ---------------------------------------------------------------------------
-- Role escalation & staff limits
-- ---------------------------------------------------------------------------
select tests.become('staff_a'); set local role authenticated;
select tests.is(tests.rows_affected(format('update public.library_members set role = %L where user_id = %L',
  'library_admin', tests.uid('staff_a'))), 0::bigint, 'staff cannot promote themselves');
select tests.is(tests.rows_affected(format('insert into public.books (library_id, title) values (%L, %L)',
  tests.id('lib_a'), 'Buku Staff')), 1::bigint, 'staff can register a book');
select tests.is(tests.rows_affected(format('update public.books set title = %L where id = %L', 'X', tests.id('book_a'))),
  0::bigint, 'staff cannot edit catalog records (editor+)');
select tests.is(tests.rows_affected(format('update public.book_copies set status = %L, location_id = null where id = %L',
  'damaged', tests.id('copy_a'))), 1::bigint, 'staff can update copy status/location');
select tests.throws(format('update public.book_copies set barcode = %L where id = %L', 'A9999', tests.id('copy_a')),
  '42501', 'staff cannot change a barcode');
select tests.throws(format('update public.book_copies set deleted_at = now() where id = %L', tests.id('copy_a')),
  '42501', 'staff cannot soft-delete a copy');
select tests.throws(format('insert into public.categories (library_id, name) values (%L, %L)', tests.id('lib_a'), 'X'),
  '42501', 'staff cannot create categories');
-- Audit: clients cannot forge entity audit rows, only app events
select tests.throws(format('insert into public.activity_logs (library_id, user_id, action, entity_type) values (%L, %L, %L, %L)',
  tests.id('lib_a'), tests.uid('staff_a'), 'delete', 'books'), '42501', 'client cannot forge entity audit rows');
select tests.throws(format('insert into public.activity_logs (library_id, user_id, action, entity_type) values (%L, %L, %L, %L)',
  tests.id('lib_a'), tests.uid('admin_a'), 'export', 'app_event'), '42501', 'client cannot log events as another user');
select tests.is(tests.rows_affected(format('insert into public.activity_logs (library_id, user_id, action, entity_type) values (%L, %L, %L, %L)',
  tests.id('lib_a'), tests.uid('staff_a'), 'export_excel', 'app_event')), 1::bigint, 'client can log own app event');
reset role;

-- Server-side ledger & audit were written for the staff change
select tests.is((select count(*) from public.stock_movements
                 where copy_id = tests.id('copy_a') and movement_type = 'status_change' and quantity = -1
                   and created_by = tests.uid('staff_a')), 1::bigint,
  'status change produced a stock movement (-1) attributed to staff_a');
select tests.is((select count(*) from public.activity_logs
                 where entity_id = tests.id('copy_a') and action = 'update' and user_id = tests.uid('staff_a')), 1::bigint,
  'status change produced an activity log attributed to staff_a');
select tests.ok((select version from public.book_copies where id = tests.id('copy_a')) = 2,
  'server bumped copy version to 2');
select tests.throws(format('update public.stock_movements set quantity = 1 where copy_id = %L', tests.id('copy_a')),
  '42501', 'stock_movements are append-only even for the owner');

-- ---------------------------------------------------------------------------
-- Barcode uniqueness (per library)
-- ---------------------------------------------------------------------------
select tests.become('editor_a'); set local role authenticated;
select tests.throws(format('insert into public.book_copies (library_id, book_id, barcode) values (%L, %L, %L)',
  tests.id('lib_a'), tests.id('book_a'), 'A0001'), '23505', 'duplicate barcode in the same library is rejected');
reset role;
select tests.become('staff_b'); set local role authenticated;
select tests.is(tests.rows_affected(format('insert into public.book_copies (library_id, book_id, barcode) values (%L, %L, %L)',
  tests.id('lib_b'), tests.id('book_b'), 'A0001')), 1::bigint, 'same barcode is allowed in a different library');
reset role;

-- ---------------------------------------------------------------------------
-- Profiles visibility
-- ---------------------------------------------------------------------------
select tests.become('staff_a'); set local role authenticated;
select tests.is(tests.count(format('select 1 from public.user_profiles where id = %L', tests.uid('admin_a'))), 1::bigint,
  'members of the same library can see each other''s profile');
select tests.is(tests.count(format('select 1 from public.user_profiles where id = %L', tests.uid('admin_b'))), 0::bigint,
  'profiles of other libraries'' users are hidden');
select tests.is(tests.rows_affected(format('update public.user_profiles set full_name = %L where id = %L', 'X', tests.uid('admin_a'))),
  0::bigint, 'cannot edit another user''s profile');
reset role;

-- ---------------------------------------------------------------------------
-- Super Admin & inactive library
-- ---------------------------------------------------------------------------
select tests.become('super'); set local role authenticated;
select tests.is(tests.count('select 1 from public.libraries'), 2::bigint, 'super admin sees all libraries');
select tests.is(tests.rows_affected('insert into public.libraries (name, code) values (''Perpustakaan Organisasi D'', ''LIBD'')'),
  1::bigint, 'super admin can create a library');
select tests.throws('insert into public.libraries (name, code) values (''Dup'', ''libd'')', '23514',
  'library code must be upper-case (check)');
select tests.throws('insert into public.libraries (name, code) values (''Dup'', ''LIBD'')', '23505',
  'library code is unique');
select tests.is(tests.rows_affected(format('update public.libraries set status = %L where id = %L', 'inactive', tests.id('lib_b'))),
  1::bigint, 'super admin can deactivate library B');
reset role;
select tests.become('staff_b'); set local role authenticated;
select tests.is(tests.count('select 1 from public.books'), 1::bigint, 'members can still read an inactive library');
select tests.throws(format('insert into public.books (library_id, title) values (%L, %L)', tests.id('lib_b'), 'X'),
  '42501', 'nobody but Super Admin can write to an inactive library');
reset role;

rollback;
