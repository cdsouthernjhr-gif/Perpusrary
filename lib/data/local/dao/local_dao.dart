import 'package:drift/drift.dart';

import '../../../shared/models/library_models.dart';
import '../database/app_database.dart';

/// Keys stored in [KeyValues].
abstract final class LocalKeys {
  static const deviceId = 'device_id';
  static const ownerUserId = 'owner_user_id';
  static const activeLibraryId = 'active_library_id';
}

class KeyValueDao {
  KeyValueDao(this._db);
  final AppDatabase _db;

  Future<String?> get(String key) async =>
      (await (_db.select(_db.keyValues)..where((t) => t.key.equals(key))).getSingleOrNull())?.value;

  Future<void> put(String key, String value) =>
      _db.into(_db.keyValues).insertOnConflictUpdate(KeyValuesCompanion.insert(key: key, value: value));

  Future<void> remove(String key) => (_db.delete(_db.keyValues)..where((t) => t.key.equals(key))).go();
}

class LibrariesDao {
  LibrariesDao(this._db);
  final AppDatabase _db;

  static LibrarySummary _toModel(LocalLibrary r) => LibrarySummary(
        id: r.id,
        name: r.name,
        code: r.code,
        status: r.status,
        organizationName: r.organizationName,
        logoPath: r.logoPath,
        role: LibraryRole.tryParse(r.role),
        isSuperAdmin: r.isSuperAdmin,
        titleCount: r.titleCount,
        copyCount: r.copyCount,
      );

  Stream<List<LibrarySummary>> watchAll() =>
      (_db.select(_db.localLibraries)..orderBy([(t) => OrderingTerm.asc(t.name)]))
          .watch()
          .map((rows) => rows.map(_toModel).toList());

  Future<List<LibrarySummary>> getAll() async =>
      (await (_db.select(_db.localLibraries)..orderBy([(t) => OrderingTerm.asc(t.name)])).get())
          .map(_toModel)
          .toList();

  Future<LibrarySummary?> getById(String id) async {
    final r = await (_db.select(_db.localLibraries)..where((t) => t.id.equals(id))).getSingleOrNull();
    return r == null ? null : _toModel(r);
  }

  /// Replaces the cache with the server's authoritative list, in one
  /// transaction. Returns the ids of libraries the user LOST access to; their
  /// local data is purged so it can no longer be viewed on this device.
  Future<Set<String>> replaceWithServerList(List<LibrarySummary> libs, DateTime verifiedAt) {
    return _db.transaction(() async {
      final keep = libs.map((l) => l.id).toSet();
      final existing = (await _db.select(_db.localLibraries).get()).map((r) => r.id).toSet();
      final revoked = existing.difference(keep);

      for (final id in revoked) {
        await LocalDataDao(_db).purgeLibrary(id);
      }
      await (_db.delete(_db.localLibraries)..where((t) => t.id.isNotIn(keep))).go();
      await _db.batch((b) {
        b.insertAllOnConflictUpdate(
          _db.localLibraries,
          libs.map((l) => LocalLibrariesCompanion.insert(
                id: l.id,
                name: l.name,
                code: l.code,
                status: l.status,
                organizationName: Value(l.organizationName),
                logoPath: Value(l.logoPath),
                role: Value(l.role?.value),
                isSuperAdmin: Value(l.isSuperAdmin),
                titleCount: Value(l.titleCount),
                copyCount: Value(l.copyCount),
                verifiedAt: verifiedAt,
              )),
        );
      });
      return revoked;
    });
  }
}

/// Aggregate sync state per library, for status indicators.
class SyncCounts {
  const SyncCounts({this.pending = 0, this.failed = 0, this.conflicts = 0, this.rejected = 0});

  final int pending;
  final int failed;
  final int conflicts;
  final int rejected;

  bool get hasProblems => failed > 0 || conflicts > 0 || rejected > 0;
}

class SyncQueueDao {
  SyncQueueDao(this._db);
  final AppDatabase _db;

  Stream<SyncCounts> watchCounts(String libraryId) {
    final count = _db.syncQueue.operationId.count();
    final q = _db.selectOnly(_db.syncQueue)
      ..addColumns([_db.syncQueue.state, count])
      ..where(_db.syncQueue.libraryId.equals(libraryId))
      ..groupBy([_db.syncQueue.state]);
    return q.watch().map((rows) {
      final m = {for (final r in rows) r.read(_db.syncQueue.state)!: r.read(count) ?? 0};
      return SyncCounts(
        pending: (m['pending'] ?? 0) + (m['in_flight'] ?? 0),
        failed: m['failed'] ?? 0,
        conflicts: m['conflict'] ?? 0,
        rejected: m['rejected'] ?? 0,
      );
    });
  }

  /// Operations not yet confirmed by the server (any library).
  Future<int> unsyncedCount() async {
    final count = _db.syncQueue.operationId.count();
    final row = await (_db.selectOnly(_db.syncQueue)
          ..addColumns([count])
          ..where(_db.syncQueue.state.isIn(const ['pending', 'in_flight', 'failed'])))
        .getSingle();
    return row.read(count) ?? 0;
  }
}

/// Locally computed statistics (offline dashboard fallback).
class LocalStats {
  const LocalStats({required this.titles, required this.copies, required this.categories, required this.locations});
  final int titles;
  final int copies;
  final int categories;
  final int locations;
}

class LocalDataDao {
  LocalDataDao(this._db);
  final AppDatabase _db;

  Future<LocalStats> statsFor(String libraryId) async {
    Future<int> countOf<T extends Table, R>(TableInfo<T, R> table, Expression<String> libCol,
        Expression<DateTime> deletedCol) async {
      final c = countAll();
      final row = await (_db.selectOnly(table)
            ..addColumns([c])
            ..where(libCol.equals(libraryId) & deletedCol.isNull()))
          .getSingle();
      return row.read(c) ?? 0;
    }

    return LocalStats(
      titles: await countOf(_db.localBooks, _db.localBooks.libraryId, _db.localBooks.deletedAt),
      copies: await countOf(_db.localBookCopies, _db.localBookCopies.libraryId, _db.localBookCopies.deletedAt),
      categories: await countOf(_db.localCategories, _db.localCategories.libraryId, _db.localCategories.deletedAt),
      locations: await countOf(_db.localLocations, _db.localLocations.libraryId, _db.localLocations.deletedAt),
    );
  }

  /// Removes every local row of one library (access revoked).
  Future<void> purgeLibrary(String libraryId) => _db.transaction(() async {
        await (_db.delete(_db.localBookCopies)..where((t) => t.libraryId.equals(libraryId))).go();
        await (_db.delete(_db.localBooks)..where((t) => t.libraryId.equals(libraryId))).go();
        await (_db.delete(_db.localCategories)..where((t) => t.libraryId.equals(libraryId))).go();
        await (_db.delete(_db.localLocations)..where((t) => t.libraryId.equals(libraryId))).go();
        await (_db.delete(_db.syncQueue)..where((t) => t.libraryId.equals(libraryId))).go();
        await (_db.delete(_db.syncCursors)..where((t) => t.libraryId.equals(libraryId))).go();
        await (_db.delete(_db.localLibraries)..where((t) => t.id.equals(libraryId))).go();
      });

  /// Wipes all user data (a different user signed in on this device).
  /// The device id is wiped too: a device_registry row belongs to one user,
  /// so the next user registers this install under a fresh id.
  Future<void> wipeAllUserData() => _db.transaction(() async {
        for (final t in [..._db.libraryOwnedTables, _db.localLibraries, _db.keyValues]) {
          await _db.delete(t).go();
        }
      });
}
