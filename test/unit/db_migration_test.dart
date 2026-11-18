import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';

void main() {
  test('v1 database upgrades to v4 keeping existing data', () async {
    final dir = await Directory.systemTemp.createTemp('slm_mig');
    final file = File('${dir.path}/db.sqlite');
    try {
      // Build a v1-shaped file: current schema minus the v2 table, user_version 1.
      var db = AppDatabase(NativeDatabase(file));
      await db.into(db.localBooks).insert(LocalBooksCompanion.insert(
          id: 'b1', libraryId: 'lib-a', title: 'Buku Lama', createdAt: DateTime(2026), updatedAt: DateTime(2026)));
      await db.customStatement('DROP TABLE local_stock_movements');
      // Recreate local_book_copies exactly as v1/v2 had it: with the local
      // UNIQUE (library_id, barcode) constraint that v3 removes.
      final ddl = (await db.customSelect(
              "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'local_book_copies'").getSingle())
          .read<String>('sql');
      final oldDdl = '${ddl.substring(0, ddl.lastIndexOf(')'))}, UNIQUE ("library_id", "barcode"))';
      await db.customStatement('DROP TABLE local_book_copies');
      await db.customStatement(oldDdl);
      await db.into(db.localBookCopies).insert(LocalBookCopiesCompanion.insert(
          id: 'c0', libraryId: 'lib-a', bookId: 'b1', barcode: 'OLD-1', createdAt: DateTime(2026), updatedAt: DateTime(2026)));
      await db.customStatement('PRAGMA user_version = 1');
      await db.close();

      db = AppDatabase(NativeDatabase(file));
      final books = await db.select(db.localBooks).get();
      expect(books.single.title, 'Buku Lama', reason: 'data preserved across upgrade');
      expect((await db.select(db.localBookCopies).get()).single.barcode, 'OLD-1', reason: 'copies preserved by v3 rebuild');
      expect(await db.select(db.localStockMovements).get(), isEmpty, reason: 'v2 table created');
      final v = await db.customSelect('PRAGMA user_version').getSingle();
      expect(v.data.values.first, 4);
      final idx = await db.customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN ('idx_movements_copy', 'idx_copies_barcode', 'idx_queue_entity', 'idx_copies_accession')").get();
      expect(idx, hasLength(4));
      // v3: duplicate barcodes no longer violate a local constraint.
      for (final id in ['c1', 'c2']) {
        await db.into(db.localBookCopies).insert(LocalBookCopiesCompanion.insert(
            id: id, libraryId: 'lib-a', bookId: 'b1', barcode: 'SAME', createdAt: DateTime(2026), updatedAt: DateTime(2026)));
      }
      await db.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
