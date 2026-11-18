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
  SyncQueue,
  SyncCursors,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// On-device database file (app-private storage).
  factory AppDatabase.open() => AppDatabase(driftDatabase(name: 'smartlibrary'));

  @override
  int get schemaVersion => 1;

  /// Tables whose rows belong to a single library.
  List<TableInfo<Table, Object?>> get libraryOwnedTables =>
      [localCategories, localLocations, localBooks, localBookCopies, syncQueue, syncCursors];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement('CREATE INDEX IF NOT EXISTS idx_books_library ON local_books (library_id, title)');
          await customStatement('CREATE INDEX IF NOT EXISTS idx_books_isbn ON local_books (library_id, isbn)');
          await customStatement('CREATE INDEX IF NOT EXISTS idx_copies_book ON local_book_copies (library_id, book_id)');
          await customStatement('CREATE INDEX IF NOT EXISTS idx_queue_state ON sync_queue (library_id, state, created_at)');
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
