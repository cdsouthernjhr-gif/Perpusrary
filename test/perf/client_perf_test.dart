// Client performance at "10,000+ titles" scale (Drift on the host VM).
// Run: PERF=1 flutter test test/perf/client_perf_test.dart
// Timings on a phone are typically 2–5× slower than on a desktop CPU; the
// budgets below are set with that margin in mind.
@Tags(['perf'])
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/core/xlsx/xlsx_writer.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
import 'package:smartlibrary_manager/data/local/dao/inventory_dao.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/data/sync/sync_engine.dart';
import 'package:smartlibrary_manager/data/sync/sync_remote.dart';
import 'package:smartlibrary_manager/features/excel_export/application/excel_export.dart';
import 'package:smartlibrary_manager/features/excel_import/application/excel_import.dart';
import 'package:smartlibrary_manager/shared/models/catalog_models.dart';

const lib = 'lib-a';
const titles = 12000;
const copies = 20000;
final _skip = Platform.environment['PERF'] == null ? 'set PERF=1' : null;

/// Serves a full first sync of [titles] books and [copies] copies.
class _BigServer implements SyncRemote {
  final _rows = <String, List<Map<String, dynamic>>>{};
  _BigServer() {
    final now = DateTime.now().toUtc().toIso8601String();
    Map<String, dynamic> base(String id, int xid) =>
        {'id': id, 'library_id': lib, 'version': 1, 'sync_xid': '$xid', 'created_at': now, 'updated_at': now, 'deleted_at': null};
    _rows['categories'] = [];
    _rows['locations'] = [
      {...base('loc-1', 1), 'rack_code': 'R1'},
    ];
    _rows['books'] = [
      for (var i = 0; i < titles; i++)
        {
          ...base('b$i', 10 + i),
          'title': '${['Sejarah', 'Asas', 'Kamus', 'Hikayat'][i % 4]} Jilid $i',
          'author': 'Pengarang ${i % 900}',
          'isbn': (9789830000000 + i).toString(),
          'publisher': 'Penerbit ${i % 40}',
          'publication_year': 1950 + i % 75,
        },
    ];
    _rows['book_copies'] = [
      for (var i = 0; i < copies; i++)
        {
          ...base('c$i', 20000 + i),
          'book_id': 'b${i % titles}',
          'barcode': 'P-${i.toString().padLeft(7, '0')}',
          'condition': 'good',
          'status': ['available', 'available', 'damaged', 'lost'][i % 4],
          'location_id': 'loc-1',
          'acquisition_cost': 12.5,
        },
    ];
    _rows['stock_movements'] = [];
    _rows['sync_tombstones'] = [];
  }

  @override
  Future<PullPage> pull(String libraryId, String entityType,
      {String? since, String? afterXid, String? afterId, int limit = 500}) async {
    final all = _rows[entityType]!;
    final start = afterId == null ? 0 : all.indexWhere((r) => r['id'] == afterId) + 1;
    final page = all.sublist(start, (start + limit).clamp(0, all.length));
    return PullPage(
      rows: page,
      hasMore: start + limit < all.length,
      snapshotXmin: '999999',
      lastXid: page.isEmpty ? null : page.last['sync_xid'] as String,
      lastId: page.isEmpty ? null : page.last['id'] as String,
    );
  }

  @override
  Future<List<PushResult>> push(String libraryId, String? deviceId, List<Map<String, dynamic>> operations) async => [];
}

Future<Duration> _time(String label, Future<void> Function() f, Duration budget) async {
  final sw = Stopwatch()..start();
  await f();
  sw.stop();
  // ignore: avoid_print
  print('${label.padRight(48)} ${sw.elapsedMilliseconds.toString().padLeft(7)} ms  (budget ${budget.inMilliseconds} ms)');
  expect(sw.elapsed, lessThan(budget), reason: label);
  return sw.elapsed;
}

void main() {
  test('client at 12k titles / 20k copies', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dao = CatalogDao(db);

    await _time('first sync (pull 12k titles + 20k copies)', () async {
      final r = await SyncEngine(db, _BigServer()).syncLibrary(lib);
      expect(r.pulled, titles + copies + 1);
    }, const Duration(seconds: 60));

    await _time('catalogue list (first 200, with copy counts)', () async {
      expect((await dao.watchBooks(lib).first).length, 200);
    }, const Duration(milliseconds: 1500));

    await _time('search "hikayat jilid 11" (title/author/ISBN)', () async {
      expect(await dao.watchBooks(lib, query: 'hikayat jilid 11').first, isNotEmpty);
    }, const Duration(milliseconds: 1500));

    await _time('barcode lookup', () async {
      expect(await dao.findByBarcode(lib, 'P-0012345'), isNotNull);
    }, const Duration(milliseconds: 100));

    await _time('duplicate check on save (scans all titles)', () async {
      await dao.findPossibleDuplicates(lib, isbn: '9789830005000', title: 'Sejarah Jilid 5000');
    }, const Duration(milliseconds: 2000));

    await _time('register a book + 1 copy (local write + outbox)', () async {
      await dao.createBook(lib, const BookInput(title: 'Buku Baharu'), copies: const [CopyInput(barcode: 'NEW-1')]);
    }, const Duration(milliseconds: 300));

    await _time('inventory report', () async {
      final r = await InventoryDao(db, dao).report(lib);
      expect(r.copies, copies + 1);
    }, const Duration(seconds: 5));

    await _time('Excel export (8 worksheets)', () async {
      final bytes = await ExcelExporter(db)
          .build(libraryId: lib, libraryName: 'A', libraryCode: 'LIBA', exportedAt: DateTime.now());
      expect(bytes.length, greaterThan(100000));
    }, const Duration(seconds: 30));

    final importFile = (XlsxWriter()
          ..addSheet(XlsxSheet('Buku', header: ['Tajuk', 'ISBN', 'Pengarang', 'Barcode', 'Rak'], rows: [
            for (var i = 0; i < 5000; i++) ['Import $i', null, 'Penulis ${i % 50}', 'IMP-$i', 'R1'],
          ])))
        .build();
    late ImportPlan plan;
    await _time('Excel import: read + validate 5,000 rows', () async {
      plan = await ImportPlanner(db, lib).plan(importFile, 'besar.xlsx', const ImportOptions());
      expect(plan.errorRows, 0);
    }, const Duration(seconds: 20));
    await _time('Excel import: write 5,000 rows (local + outbox)', () async {
      final r = await ImportExecutor(db, dao, libraryId: lib, libraryCode: 'LIBA', deviceId: '3f2a9c10-0000-4000-8000-000000000001')
          .run(plan);
      expect(r.copiesCreated, 5000);
    }, const Duration(seconds: 120));

    await db.close();
  }, skip: _skip, timeout: const Timeout(Duration(minutes: 10)));
}
