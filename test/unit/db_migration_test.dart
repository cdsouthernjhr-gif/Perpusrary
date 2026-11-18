import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';

void main() {
  test('v1 database upgrades to v2 keeping existing data', () async {
    final dir = await Directory.systemTemp.createTemp('slm_mig');
    final file = File('${dir.path}/db.sqlite');
    try {
      // Build a v1-shaped file: current schema minus the v2 table, user_version 1.
      var db = AppDatabase(NativeDatabase(file));
      await db.into(db.localBooks).insert(LocalBooksCompanion.insert(
          id: 'b1', libraryId: 'lib-a', title: 'Buku Lama', createdAt: DateTime(2026), updatedAt: DateTime(2026)));
      await db.customStatement('DROP TABLE local_stock_movements');
      await db.customStatement('PRAGMA user_version = 1');
      await db.close();

      db = AppDatabase(NativeDatabase(file));
      final books = await db.select(db.localBooks).get();
      expect(books.single.title, 'Buku Lama', reason: 'data preserved across upgrade');
      expect(await db.select(db.localStockMovements).get(), isEmpty, reason: 'v2 table created');
      final v = await db.customSelect('PRAGMA user_version').getSingle();
      expect(v.data.values.first, 2);
      final idx = await db.customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_movements_copy'").get();
      expect(idx, hasLength(1));
      await db.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
