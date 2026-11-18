import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/core/errors/app_failure.dart';
import 'package:smartlibrary_manager/data/local/dao/local_dao.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/features/libraries/application/library_context.dart';
import 'package:smartlibrary_manager/shared/models/library_models.dart';

import '../helpers/fakes.dart';

void main() {
  late TestHarness h;
  setUp(() => h = TestHarness());
  tearDown(() => h.db.close());

  Future<void> addLocalBook(String lib) => h.db.into(h.db.localBooks).insert(LocalBooksCompanion.insert(
      id: 'b-$lib', libraryId: lib, title: 'x', createdAt: DateTime.now(), updatedAt: DateTime.now()));

  test('initialize verifies with server, caches list and registers device', () async {
    final c = h.container();
    await c.read(libraryContextProvider.notifier).initialize();
    final s = c.read(libraryContextProvider);
    expect(s.phase, LibraryContextPhase.ready);
    expect(s.verifiedWithServer, isTrue);
    expect(s.libraries.map((l) => l.id), ['lib-a', 'lib-b']);
    expect(s.active, isNull);
    expect((await LibrariesDao(h.db).getAll()).length, 2);
    expect(await KeyValueDao(h.db).get(LocalKeys.deviceId), isNotNull);
    expect(await KeyValueDao(h.db).get(LocalKeys.ownerUserId), 'user-1');
  });

  test('select switches context and persists the choice', () async {
    final c = h.container();
    final ctl = c.read(libraryContextProvider.notifier);
    await ctl.initialize();
    await ctl.select('lib-a');
    expect(c.read(activeLibraryProvider)!.id, 'lib-a');
    expect(c.read(activePermissionsProvider).canManageMembers, isTrue);
    await ctl.select('lib-b');
    expect(c.read(activeLibraryProvider)!.id, 'lib-b');
    expect(c.read(activePermissionsProvider).canManageMembers, isFalse, reason: 'staff in B');
    expect(await KeyValueDao(h.db).get(LocalKeys.activeLibraryId), 'lib-b');
  });

  test('select re-verifies membership with the server and refuses revoked access', () async {
    final c = h.container();
    final ctl = c.read(libraryContextProvider.notifier);
    await ctl.initialize();
    h.libraries.serverLibraries = [libA()]; // removed from B on the server
    await expectLater(ctl.select('lib-b'), throwsA(isA<AppFailure>()));
    expect(c.read(activeLibraryProvider), isNull);
  });

  test('last library is restored on next session only if still accessible', () async {
    var c = h.container();
    await c.read(libraryContextProvider.notifier).initialize();
    await c.read(libraryContextProvider.notifier).select('lib-b');
    c.dispose();

    c = h.container();
    await c.read(libraryContextProvider.notifier).initialize();
    expect(c.read(activeLibraryProvider)?.id, 'lib-b');
    c.dispose();

    h.libraries.serverLibraries = [libA()];
    c = h.container();
    await c.read(libraryContextProvider.notifier).initialize();
    expect(c.read(activeLibraryProvider), isNull, reason: 'access to B was revoked');
    expect(await KeyValueDao(h.db).get(LocalKeys.activeLibraryId), isNull);
  });

  test('revoked library data is purged from the device on refresh', () async {
    final c = h.container();
    await c.read(libraryContextProvider.notifier).initialize();
    await addLocalBook('lib-a');
    await addLocalBook('lib-b');
    h.libraries.serverLibraries = [libA()];
    await c.read(libraryContextProvider.notifier).refresh();
    final books = await h.db.select(h.db.localBooks).get();
    expect(books.map((b) => b.libraryId), ['lib-a']);
  });

  test('offline: uses cached list, marked unverified', () async {
    var c = h.container();
    await c.read(libraryContextProvider.notifier).initialize();
    c.dispose();
    h.libraries.offline = true;
    c = h.container();
    await c.read(libraryContextProvider.notifier).initialize();
    final s = c.read(libraryContextProvider);
    expect(s.verifiedWithServer, isFalse);
    expect(s.libraries.length, 2);
    expect(s.lastError, 'Tiada sambungan internet.');
  });

  test('another user on the same device wipes previous local data', () async {
    var c = h.container();
    await c.read(libraryContextProvider.notifier).initialize();
    await addLocalBook('lib-a');
    await h.db.into(h.db.syncQueue).insert(SyncQueueCompanion.insert(
        operationId: 'op',
        libraryId: 'lib-a',
        entityType: 'books',
        entityId: 'b',
        operationType: 'insert',
        payload: '{}',
        state: const Value('pending'),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now()));
    c.dispose();

    h.setUser('user-2');
    h.libraries.serverLibraries = [libB()];
    c = h.container();
    await c.read(libraryContextProvider.notifier).initialize();
    expect(await h.db.select(h.db.localBooks).get(), isEmpty);
    expect(await h.db.select(h.db.syncQueue).get(), isEmpty);
    expect(c.read(libraryContextProvider).libraries.map((l) => l.id), ['lib-b']);
    expect(await KeyValueDao(h.db).get(LocalKeys.ownerUserId), 'user-2');
  });

  test('super admin flag comes from the server, not from library rows', () async {
    h.libraries.superAdmin = true;
    h.libraries.serverLibraries = [];
    final c = h.container();
    await c.read(libraryContextProvider.notifier).initialize();
    expect(c.read(isSuperAdminProvider), isTrue);
  });

  test('LibraryPermissions mirrors server role ranks', () {
    const viewer = LibraryPermissions(role: LibraryRole.viewer, isSuperAdmin: false, libraryActive: true);
    const staff = LibraryPermissions(role: LibraryRole.staff, isSuperAdmin: false, libraryActive: true);
    const editorInactive = LibraryPermissions(role: LibraryRole.editor, isSuperAdmin: false, libraryActive: false);
    const superA = LibraryPermissions(role: null, isSuperAdmin: true, libraryActive: false);
    expect(viewer.canRegisterBooks, isFalse);
    expect(staff.canRegisterBooks, isTrue);
    expect(staff.canEditCatalog, isFalse);
    expect(editorInactive.canEditCatalog, isFalse, reason: 'inactive library is read-only');
    expect(superA.canManageMembers && superA.canChangeLibraryStatus, isTrue);
  });
}
