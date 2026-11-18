import 'dart:typed_data';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/core/xlsx/xlsx_writer.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/features/excel_import/application/excel_import.dart';
import 'package:smartlibrary_manager/shared/models/catalog_models.dart';

const lib = 'lib-a';
const device = '3f2a9c10-0000-4000-8000-000000000001';

void main() {
  late AppDatabase db;
  late CatalogDao dao;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = CatalogDao(db);
  });
  tearDown(() => db.close());

  Uint8ListLike xlsx(List<String> header, List<List<Object?>> rows) =>
      (XlsxWriter()..addSheet(XlsxSheet('Buku', header: header, rows: rows))).build();

  Future<ImportPlan> plan(Uint8ListLike bytes, [ImportOptions o = const ImportOptions()]) =>
      ImportPlanner(db, lib).plan(bytes, 'ujian.xlsx', o);

  Future<ImportResult> run(ImportPlan p) =>
      ImportExecutor(db, dao, libraryId: lib, libraryCode: 'LIBA', deviceId: device).run(p);

  test('the template itself imports cleanly: 1 title, 2 copies, new category & location', () async {
    final p = await plan(buildImportTemplate());
    expect(p.errorRows, 0, reason: p.rows.expand((r) => r.errors).join('; '));
    expect(p.newBooks, 1);
    expect(p.newCopies, 2);
    expect(p.newCategories, {'Kesusasteraan'});
    expect(p.newLocations, hasLength(1));
    final r = await run(p);
    expect((r.booksCreated, r.copiesCreated, r.failed), (1, 2, 0));
    final copies = await db.select(db.localBookCopies).get();
    expect(copies.map((c) => c.barcode).toSet(), {'B000101', 'B000102'});
    expect(copies.first.acquisitionCostCents ?? copies.last.acquisitionCostCents, 3500);
    final q = await db.select(db.syncQueue).get();
    expect(q.map((o) => o.entityType).toSet(), {'categories', 'locations', 'books', 'book_copies'},
        reason: 'imported data is queued for sync like manual edits');
    expect(q.every((o) => o.libraryId == lib), isTrue);
  });

  test('row validation: every problem is reported with its row number', () async {
    await dao.createBook(lib, const BookInput(title: 'Ada'), copies: const [CopyInput(barcode: 'EXIST-1')]);
    final p = await plan(xlsx(
      ['Tajuk', 'ISBN', 'Tahun', 'Barcode', 'Status', 'Kos', 'Tarikh Perolehan', 'Para'],
      [
        [null, null, null, 'X1', null, null, null, null], // row 2: no title
        ['A', '12345', null, 'X2', null, null, null, null], // row 3: bad ISBN
        ['B', null, 'abc', 'X3', null, null, null, null], // row 4: bad year
        ['C', null, null, 'X 4', null, null, null, null], // row 5: barcode with space
        ['D', null, null, 'X5', 'Dipinjam', null, null, null], // row 6: unknown status (no loans)
        ['E', null, null, 'X6', null, '-3', null, null], // row 7: negative cost
        ['F', null, null, 'X7', null, null, '31/31/2026', null], // row 8: bad date
        ['G', null, null, 'X8', null, null, null, 'S1'], // row 9: shelf without rack
        ['H', null, null, 'EXIST-1', null, null, null, null], // row 10: barcode exists
        ['I', null, null, 'DUP', null, null, null, null], // row 11
        ['J', null, null, 'DUP', null, null, null, null], // row 12: duplicate in file
        ['K', '9780306406158', null, 'X9', 'Tersedia', 'RM 12,50', '07/03/2026', null], // row 13: ok (+warning)
      ],
    ));
    final errs = {for (final r in p.rows) if (!r.ok) r.rowNumber: r.errors.join(' | ')};
    expect(errs.keys.toList(), [2, 3, 4, 5, 6, 7, 8, 9, 10, 12]);
    expect(errs[6], contains('Status "Dipinjam"'));
    expect(errs[10], contains('sudah digunakan'));
    expect(errs[12], contains('berulang dalam fail (baris 11)'));
    final ok = p.rows.firstWhere((r) => r.rowNumber == 13);
    expect(ok.ok, isTrue);
    expect(ok.warnings.single, contains('digit semak'));
    expect(ok.copy!.acquisitionCostCents, 1250);
    expect(ok.copy!.acquisitionDate, DateTime(2026, 3, 7));

    final r = await run(p);
    expect(r.booksCreated, 2, reason: 'only valid rows (I and K) are imported');
    expect((await db.select(db.localBooks).get()).length, 3);
  });

  test('a library_id / Perpustakaan column is ignored with a warning', () async {
    final p = await plan(xlsx(['library_id', 'Perpustakaan', 'Tajuk'], [
      ['00000000-0000-0000-0000-00000000000b', 'LIBB', 'Buku Saya'],
    ]));
    expect(p.fileWarnings, hasLength(2));
    await run(p);
    final b = (await db.select(db.localBooks).get()).single;
    expect(b.libraryId, lib);
    final payload = jsonDecode((await db.select(db.syncQueue).get()).single.payload) as Map<String, dynamic>;
    expect(payload.containsKey('library_id'), isFalse);
  });

  test('duplicate modes: skip / update / insert_new', () async {
    await dao.createBook(lib, const BookInput(title: 'Hikayat Hang Tuah', isbn: '9789836261234', publisher: 'Lama'),
        copies: const [CopyInput(barcode: 'H1')]);
    final file = xlsx(['Tajuk', 'ISBN', 'Penerbit', 'Barcode', 'Status'], [
      ['Hikayat Hang Tuah', '978-983-626-123-4', 'DBP', 'H1', 'Rosak'], // existing copy
      ['Hikayat Hang Tuah', '9789836261234', 'DBP', 'H2', null], // new copy
      ['Hikayat Hang Tuah', '9789836261234', 'DBP', null, null], // title only
    ]);

    final skip = await plan(file);
    expect(skip.rows.map((r) => r.ok), [false, true, true], reason: 'existing barcode is an error in skip mode');
    expect(skip.rows[1].action, RowAction.existingBook);
    expect(skip.rows[2].action, RowAction.skip);

    final upd = await plan(file, const ImportOptions(duplicateMode: DuplicateMode.update));
    expect(upd.rows.every((r) => r.ok), isTrue);
    final ru = await run(upd);
    expect((ru.booksUpdated, ru.copiesUpdated, ru.copiesCreated), (1, 1, 1));
    final book = (await db.select(db.localBooks).get()).single;
    expect(book.publisher, 'DBP');
    final h1 = (await db.select(db.localBookCopies).get()).firstWhere((c) => c.barcode == 'H1');
    expect(h1.status, 'damaged');

    final ins = await plan(xlsx(['Tajuk', 'ISBN'], [
      ['Hikayat Hang Tuah', '9789836261234'],
    ]), const ImportOptions(duplicateMode: DuplicateMode.insertNew));
    await run(ins);
    expect((await db.select(db.localBooks).get()).length, 2, reason: 'new edition record');
  });

  test('missing category/location without auto-create is an error; generated barcodes when asked', () async {
    final file = xlsx(['Tajuk', 'Kategori', 'Rak'], [
      ['A', 'Baru', 'R9'],
    ]);
    final strict = await plan(file, const ImportOptions(createMissingCategories: false, createMissingLocations: false));
    expect(strict.rows.single.errors, hasLength(2));

    final gen = await plan(file, const ImportOptions(generateMissingBarcodes: true));
    final r = await run(gen);
    expect(r.copiesCreated, 1);
    expect((await db.select(db.localBookCopies).get()).single.barcode, matches(RegExp(r'^LIBA-[0-9A-Z]{4}-000001$')));
  });

  test('missing title column → clear error; non-xlsx rejected', () async {
    await expectLater(plan(xlsx(['Nama', 'Harga'], [
      ['x', 1]
    ])), throwsA(predicate((e) => '$e'.contains('Tajuk'))));
    await expectLater(plan(Uint8ListLike.fromList(utf8.encode('Tajuk,ISBN\nA,1'))), throwsA(anything));
  });
}

typedef Uint8ListLike = Uint8List;
