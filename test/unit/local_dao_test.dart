import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/data/local/dao/local_dao.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/shared/models/library_models.dart';

LibrarySummary lib(String id, {LibraryRole role = LibraryRole.staff, int titles = 0}) =>
    LibrarySummary(id: id, name: 'Perpustakaan $id', code: 'C$id', status: 'active', role: role, titleCount: titles);

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> addBook(String libraryId, String id) => db.into(db.localBooks).insert(LocalBooksCompanion.insert(
        id: id,
        libraryId: libraryId,
        title: 'Buku $id',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

  test('replaceWithServerList caches libraries and purges revoked ones', () async {
    final dao = LibrariesDao(db);
    await dao.replaceWithServerList([lib('A'), lib('B')], DateTime.now());
    await addBook('A', 'b1');
    await addBook('B', 'b2');
    await db.into(db.syncQueue).insert(SyncQueueCompanion.insert(
          operationId: 'op1',
          libraryId: 'B',
          entityType: 'books',
          entityId: 'b2',
          operationType: 'insert',
          payload: '{}',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ));

    final revoked = await dao.replaceWithServerList([lib('A', titles: 5)], DateTime.now());

    expect(revoked, {'B'});
    expect((await dao.getAll()).map((l) => l.id), ['A']);
    expect((await dao.getById('A'))!.titleCount, 5);
    final books = await db.select(db.localBooks).get();
    expect(books.map((b) => b.libraryId), ['A'], reason: 'library B data must be purged');
    expect(await db.select(db.syncQueue).get(), isEmpty);
  });

  test('local barcode uniqueness is per library', () async {
    Future<void> copy(String lib, String id, String barcode) =>
        db.into(db.localBookCopies).insert(LocalBookCopiesCompanion.insert(
              id: id,
              libraryId: lib,
              bookId: 'b',
              barcode: barcode,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ));
    await copy('A', 'c1', 'X1');
    await copy('B', 'c2', 'X1');
    expect(() => copy('A', 'c3', 'X1'), throwsA(isA<SqliteException>()));
  });

  test('stats ignore soft-deleted rows and other libraries', () async {
    await addBook('A', 'b1');
    await addBook('A', 'b2');
    await addBook('B', 'b3');
    await (db.update(db.localBooks)..where((t) => t.id.equals('b2')))
        .write(LocalBooksCompanion(deletedAt: Value(DateTime.now())));
    final s = await LocalDataDao(db).statsFor('A');
    expect(s.titles, 1);
    expect(s.copies, 0);
  });

  test('sync counts per state', () async {
    var n = 0;
    Future<void> op(String state) => db.into(db.syncQueue).insert(SyncQueueCompanion.insert(
          operationId: 'op${n++}',
          libraryId: 'A',
          entityType: 'books',
          entityId: 'x',
          operationType: 'insert',
          payload: '{}',
          state: Value(state),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ));
    await op('pending');
    await op('in_flight');
    await op('conflict');
    await op('applied');
    final c = await SyncQueueDao(db).watchCounts('A').first;
    expect(c.pending, 2);
    expect(c.conflicts, 1);
    expect(c.hasProblems, isTrue);
    expect(await SyncQueueDao(db).unsyncedCount(), 2);
  });

  test('wipeAllUserData removes everything incl. device id', () async {
    final kv = KeyValueDao(db);
    await kv.put(LocalKeys.deviceId, 'dev-1');
    await kv.put(LocalKeys.activeLibraryId, 'A');
    await LibrariesDao(db).replaceWithServerList([lib('A')], DateTime.now());
    await addBook('A', 'b1');
    await LocalDataDao(db).wipeAllUserData();
    expect(await kv.get(LocalKeys.deviceId), isNull);
    expect(await kv.get(LocalKeys.activeLibraryId), isNull);
    expect(await LibrariesDao(db).getAll(), isEmpty);
    expect(await db.select(db.localBooks).get(), isEmpty);
  });
}
