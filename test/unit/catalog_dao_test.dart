import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/core/errors/app_failure.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/shared/models/catalog_models.dart';

const libA = 'lib-a';
const libB = 'lib-b';
const device = '3f2a9c10-0000-4000-8000-000000000001';

void main() {
  late AppDatabase db;
  late CatalogDao dao;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = CatalogDao(db);
  });
  tearDown(() => db.close());

  Future<List<SyncQueueEntry>> queue() =>
      (db.select(db.syncQueue)..orderBy([(q) => OrderingTerm.asc(q.createdAt)])).get();
  Map<String, dynamic> payload(SyncQueueEntry e) => jsonDecode(e.payload) as Map<String, dynamic>;

  /// Simulates the sync engine confirming everything (Phase 6).
  Future<void> markAllSynced() async {
    await db.update(db.syncQueue).write(const SyncQueueCompanion(state: Value('applied')));
    for (final t in ['local_books', 'local_book_copies', 'local_categories', 'local_locations']) {
      await db.customStatement("UPDATE $t SET server_version = 1, sync_state = 'synced'");
    }
  }

  test('createBook with copies writes rows and FIFO outbox ops in one transaction', () async {
    final bookId = await dao.createBook(libA, const BookInput(title: 'Sejarah Melayu', isbn: '9789830000099'),
        copies: const [CopyInput(barcode: 'A1'), CopyInput(barcode: 'A2')],
        meta: const MovementMeta(referenceNumber: 'PO-1'));
    final q = await queue();
    expect(q.map((e) => '${e.entityType}:${e.operationType}'),
        ['books:insert', 'book_copies:insert', 'book_copies:insert']);
    expect(q.first.entityId, bookId);
    expect(payload(q[1])['book_id'], bookId);
    expect(jsonDecode(q[1].meta!), {'reference_number': 'PO-1'});
    expect(q.every((e) => e.baseVersion == null && e.state == 'pending'), isTrue);
    expect(await dao.copyCount(libA, bookId), 2);
  });

  test('duplicate barcode is rejected locally; same barcode allowed in another library', () async {
    final a = await dao.createBook(libA, const BookInput(title: 'A'), copies: const [CopyInput(barcode: 'X1')]);
    await expectLater(dao.addCopy(libA, a, const CopyInput(barcode: 'X1')),
        throwsA(isA<AppFailure>().having((f) => f.code, 'code', 'duplicate_barcode')));
    final b = await dao.createBook(libB, const BookInput(title: 'B'));
    await dao.addCopy(libB, b, const CopyInput(barcode: 'X1'));
    expect((await queue()).where((e) => e.entityType == 'book_copies').length, 2);
  });

  test('a failed copy insert rolls back the whole createBook transaction', () async {
    await dao.createBook(libA, const BookInput(title: 'A'), copies: const [CopyInput(barcode: 'X1')]);
    await expectLater(
        dao.createBook(libA, const BookInput(title: 'B'), copies: const [CopyInput(barcode: 'X1')]), throwsA(isA<AppFailure>()));
    expect((await db.select(db.localBooks).get()).map((b) => b.title), ['A']);
    expect((await queue()).length, 2);
  });

  test('edit before sync is merged into the pending insert', () async {
    final id = await dao.createBook(libA, const BookInput(title: 'Draf'));
    await dao.updateBook(libA, id, const BookInput(title: 'Tajuk Akhir', publisher: 'DBP'));
    final q = await queue();
    expect(q.length, 1);
    expect(q.single.operationType, 'insert');
    expect(payload(q.single)['title'], 'Tajuk Akhir');
    expect(payload(q.single)['publisher'], 'DBP');
  });

  test('edit after sync creates an update carrying the server version; repeated edits merge', () async {
    final id = await dao.createBook(libA, const BookInput(title: 'Asal'));
    await markAllSynced();
    await dao.updateBook(libA, id, const BookInput(title: 'Satu'));
    await dao.updateBook(libA, id, const BookInput(title: 'Dua'));
    final pending = (await queue()).where((e) => e.state == 'pending').toList();
    expect(pending.single.operationType, 'update');
    expect(pending.single.baseVersion, 1);
    expect(payload(pending.single)['title'], 'Dua');
  });

  test('delete of a never-synced record drops its outbox ops', () async {
    final cat = await dao.saveCategory(libA, const CategoryInput(name: 'Sementara'));
    await dao.deleteCategory(libA, cat);
    expect(await queue(), isEmpty);
    expect(await dao.watchCategories(libA).first, isEmpty);
  });

  test('delete after a pending update becomes one delete with the update base_version', () async {
    final cat = await dao.saveCategory(libA, const CategoryInput(name: 'Fiksyen'));
    await markAllSynced();
    await dao.saveCategory(libA, const CategoryInput(name: 'Fiksyen Moden'), id: cat);
    await dao.deleteCategory(libA, cat);
    final pending = (await queue()).where((e) => e.state == 'pending').toList();
    expect(pending.single.operationType, 'delete');
    expect(pending.single.baseVersion, 1);
  });

  test('category names unique per library (case-insensitive); locations unique per slot', () async {
    await dao.saveCategory(libA, const CategoryInput(name: 'Sains'));
    await expectLater(dao.saveCategory(libA, const CategoryInput(name: 'SAINS')), throwsA(isA<AppFailure>()));
    await dao.saveCategory(libB, const CategoryInput(name: 'Sains'));
    await dao.saveLocation(libA, const LocationInput(building: 'Blok A', rackCode: 'R1', shelfCode: 'S1'));
    await expectLater(dao.saveLocation(libA, const LocationInput(building: 'blok a', rackCode: 'r1', shelfCode: 's1')),
        throwsA(isA<AppFailure>()));
    await dao.saveLocation(libA, const LocationInput(building: 'Blok A', rackCode: 'R1', shelfCode: 'S2'));
  });

  test('location in use cannot be deleted; book with copies cannot be deleted', () async {
    final loc = await dao.saveLocation(libA, const LocationInput(rackCode: 'R1'));
    final book = await dao.createBook(libA, const BookInput(title: 'A'), copies: [CopyInput(barcode: 'C1', locationId: loc)]);
    await expectLater(dao.deleteLocation(libA, loc), throwsA(isA<AppFailure>()));
    await expectLater(dao.deleteBook(libA, book), throwsA(isA<AppFailure>()));
    final copy = (await dao.watchCopies(libA, book).first).single.copy;
    await dao.deleteCopy(libA, copy.id);
    await dao.deleteBook(libA, book);
    await dao.deleteLocation(libA, loc);
  });

  test('copy payload uses server types (decimal cost, ISO date)', () async {
    final book = await dao.createBook(libA, const BookInput(title: 'A'));
    await dao.addCopy(libA, book,
        CopyInput(barcode: 'C9', acquisitionCostCents: 2590, acquisitionDate: DateTime(2026, 3, 7),
            acquisitionSource: AcquisitionSource.donation, status: CopyStatus.inProcessing));
    final p = payload((await queue()).last);
    expect(p['acquisition_cost'], 25.9);
    expect(p['acquisition_date'], '2026-03-07');
    expect(p['acquisition_source'], 'donation');
    expect(p['status'], 'in_processing');
  });

  test('search, category filter and copy counts are library-scoped', () async {
    final cat = await dao.saveCategory(libA, const CategoryInput(name: 'Sejarah'));
    await dao.createBook(libA, BookInput(title: 'Sejarah Melayu', author: 'Tun Sri Lanang', categoryId: cat),
        copies: const [CopyInput(barcode: 'S1'), CopyInput(barcode: 'S2')]);
    await dao.createBook(libA, const BookInput(title: 'Asas Fizik', isbn: '9789830000002'));
    await dao.createBook(libB, const BookInput(title: 'Sejarah Dunia'));

    final all = await dao.watchBooks(libA).first;
    expect(all.map((b) => b.book.title), ['Asas Fizik', 'Sejarah Melayu']);
    final byTitle = await dao.watchBooks(libA, query: 'sejarah').first;
    expect(byTitle.single.copyCount, 2);
    expect(byTitle.single.categoryName, 'Sejarah');
    expect((await dao.watchBooks(libA, query: 'lanang').first).length, 1);
    expect((await dao.watchBooks(libA, query: '978-983').first).single.book.title, 'Asas Fizik');
    expect((await dao.watchBooks(libA, categoryId: cat).first).length, 1);
  });

  test('possible duplicates: ISBN or similar title; different library ignored; never merged', () async {
    await dao.createBook(libA, const BookInput(title: 'Hikayat Hang Tuah', author: 'Kassim Ahmad', isbn: '9789836261234',
        publisher: 'DBP', publicationYear: 1997));
    await dao.createBook(libB, const BookInput(title: 'Hikayat Hang Tuah', isbn: '9789836261234'));

    final byIsbn = await dao.findPossibleDuplicates(libA, isbn: '9789836261234', title: 'Buku Lain');
    expect(byIsbn.single.reasons, contains('isbn'));

    final byTitle = await dao.findPossibleDuplicates(libA,
        title: 'Hikayat Hang Tuah', author: 'Kassim Ahmad', publisher: 'DBP', year: 1997);
    expect(byTitle.single.reasons, containsAll(['title', 'author', 'publisher', 'year']));

    expect(await dao.findPossibleDuplicates(libA, title: 'Asas Kimia'), isEmpty);
    expect((await db.select(db.localBooks).get()).length, 2, reason: 'suggestions never merge records');
  });

  test('barcode lookup finds the copy and its title (incl. soft-deleted)', () async {
    final book = await dao.createBook(libA, const BookInput(title: 'A'), copies: const [CopyInput(barcode: 'Q1')]);
    final hit = await dao.findByBarcode(libA, ' Q1 ');
    expect(hit!.$2!.id, book);
    expect(await dao.findByBarcode(libB, 'Q1'), isNull);
  });

  test('generated barcodes increment per library and skip used values', () async {
    final first = await dao.nextGeneratedBarcode(libraryId: libA, libraryCode: 'LIBA', deviceId: device);
    final book = await dao.createBook(libA, const BookInput(title: 'A'));
    final second = await dao.nextGeneratedBarcode(libraryId: libA, libraryCode: 'LIBA', deviceId: device);
    expect(first, endsWith('-000001'));
    expect(second, endsWith('-000002'));
    // Someone typed the next value manually: it must be skipped.
    final third = second.replaceFirst('000002', '000003');
    await dao.addCopy(libA, book, CopyInput(barcode: third));
    expect(await dao.nextGeneratedBarcode(libraryId: libA, libraryCode: 'LIBA', deviceId: device), endsWith('-000004'));
    expect(await dao.nextGeneratedBarcode(libraryId: libB, libraryCode: 'LIBB', deviceId: device), endsWith('-000001'));
  });

  test('records are invisible across libraries for update/delete', () async {
    final id = await dao.createBook(libA, const BookInput(title: 'A'));
    await expectLater(dao.updateBook(libB, id, const BookInput(title: 'X')), throwsA(isA<AppFailure>()));
    await expectLater(dao.deleteBook(libB, id), throwsA(isA<AppFailure>()));
  });
}
