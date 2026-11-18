import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [
  LocalLibraries,
  KeyValues,
  LocalCategories,
  LocalLocations,
  LocalBooks,
  LocalBookCopies,
  LocalStockMovements,
  SyncQueue,
  SyncCursors,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// On-device database file (app-private storage).
  factory AppDatabase.open() => AppDatabase(driftDatabase(name: 'smartlibrary'));

  @override
  int get schemaVersion => 3;

  /// Tables whose rows belong to a single library.
  List<TableInfo<Table, Object?>> get libraryOwnedTables =>
      [localCategories, localLocations, localBooks, localBookCopies, localStockMovements, syncQueue, syncCursors];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement('CREATE INDEX IF NOT EXISTS idx_books_library ON local_books (library_id, title)');
          await customStatement('CREATE INDEX IF NOT EXISTS idx_books_isbn ON local_books (library_id, isbn)');
          await customStatement('CREATE INDEX IF NOT EXISTS idx_copies_book ON local_book_copies (library_id, book_id)');
          await customStatement('CREATE INDEX IF NOT EXISTS idx_queue_state ON sync_queue (library_id, state, created_at)');
          await _createMovementIndexes();
          await _createBarcodeIndex();
        },
        onUpgrade: (m, from, to) async {
          // v1 → v2: local inventory ledger (Phase 5)
          if (from < 2) {
            await m.createTable(localStockMovements);
            await _createMovementIndexes();
          }
          // v2 → v3: local barcode uniqueness removed (server is authoritative)
          if (from < 3) {
            await m.alterTable(TableMigration(localBookCopies));
            await customStatement('CREATE INDEX IF NOT EXISTS idx_copies_book ON local_book_copies (library_id, book_id)');
            await _createBarcodeIndex();
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  Future<void> _createBarcodeIndex() =>
      customStatement('CREATE INDEX IF NOT EXISTS idx_copies_barcode ON local_book_copies (library_id, barcode)');

  Future<void> _createMovementIndexes() async {
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_movements_copy ON local_stock_movements (library_id, copy_id, created_at)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_movements_op ON local_stock_movements (operation_id)');
  }
}
