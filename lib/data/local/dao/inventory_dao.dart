import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../shared/models/catalog_models.dart';
import '../database/app_database.dart';
import 'catalog_dao.dart';

class LocationCount {
  const LocationCount({required this.locationId, required this.label, required this.count});
  final String? locationId; // null = not assigned
  final String label;
  final int count;
}

class CategoryCount {
  const CategoryCount({required this.name, required this.titles, required this.copies});
  final String name;
  final int titles;
  final int copies;
}

/// Inventory report computed from the copies on this device. Stock is never
/// stored as a counter — it is always derived, so concurrent edits cannot
/// corrupt a total.
class InventoryReport {
  const InventoryReport({
    required this.titles,
    required this.copies,
    required this.inStock,
    required this.byStatus,
    required this.byCondition,
    required this.byLocation,
    required this.byCategory,
    required this.totalValueCents,
    required this.pendingChanges,
    required this.generatedAt,
  });

  final int titles;
  final int copies;
  final int inStock;
  final Map<String, int> byStatus;
  final Map<String, int> byCondition;
  final List<LocationCount> byLocation;
  final List<CategoryCount> byCategory;
  final int totalValueCents;
  final int pendingChanges; // local changes not yet confirmed by the server
  final DateTime generatedAt;
}

class MovementView {
  const MovementView({required this.movement, required this.barcode, required this.title, this.from, this.to});
  final LocalStockMovement movement;
  final String barcode;
  final String title;
  final String? from; // location labels
  final String? to;
}

enum ScanOutcome { found, alreadyScanned, otherLocation, unknown, deleted }

class StocktakeScan {
  const StocktakeScan({required this.outcome, required this.barcode, this.copy, this.book});
  final ScanOutcome outcome;
  final String barcode;
  final LocalBookCopy? copy;
  final LocalBook? book;
}

class StocktakeState {
  const StocktakeState({
    required this.locationId,
    required this.startedAt,
    required this.expected,
    required this.scannedBarcodes,
    required this.unexpected,
  });

  final String locationId;
  final DateTime startedAt;

  /// Copies recorded at this location and expected on the shelf.
  final List<(LocalBookCopy, LocalBook)> expected;
  final Set<String> scannedBarcodes;

  /// Scanned copies that belong elsewhere (wrong shelf).
  final List<(LocalBookCopy, LocalBook)> unexpected;

  List<(LocalBookCopy, LocalBook)> get found =>
      expected.where((e) => scannedBarcodes.contains(e.$1.barcode)).toList();
  List<(LocalBookCopy, LocalBook)> get missing =>
      expected.where((e) => !scannedBarcodes.contains(e.$1.barcode)).toList();
}

class InventoryDao {
  InventoryDao(this._db, this._catalog);

  final AppDatabase _db;
  final CatalogDao _catalog;

  // ------------------------------------------------------------------ report
  Future<InventoryReport> report(String libraryId) async {
    final copies = await (_db.select(_db.localBookCopies)
          ..where((c) => c.libraryId.equals(libraryId) & c.deletedAt.isNull()))
        .get();
    final books = await (_db.select(_db.localBooks)..where((b) => b.libraryId.equals(libraryId) & b.deletedAt.isNull()))
        .get();
    final locations = {
      for (final l in await (_db.select(_db.localLocations)..where((l) => l.libraryId.equals(libraryId))).get()) l.id: l,
    };
    final categories = {
      for (final c in await (_db.select(_db.localCategories)..where((c) => c.libraryId.equals(libraryId))).get())
        c.id: c,
    };
    final bookById = {for (final b in books) b.id: b};

    final byStatus = <String, int>{};
    final byCondition = <String, int>{};
    final byLoc = <String?, int>{};
    var value = 0;
    var inStock = 0;
    for (final c in copies) {
      byStatus[c.status] = (byStatus[c.status] ?? 0) + 1;
      byCondition[c.condition] = (byCondition[c.condition] ?? 0) + 1;
      byLoc[c.locationId] = (byLoc[c.locationId] ?? 0) + 1;
      value += c.acquisitionCostCents ?? 0;
      if (c.status == 'available' || c.status == 'in_processing') inStock++;
    }
    final byLocation = [
      for (final e in byLoc.entries)
        LocationCount(
          locationId: e.key,
          label: e.key == null
              ? 'Belum ditetapkan'
              : (locations[e.key] == null ? '(lokasi tidak dijumpai)' : locationLabel(locations[e.key]!)),
          count: e.value,
        ),
    ]..sort((a, b) => b.count.compareTo(a.count));

    final catTitles = <String, int>{};
    final catCopies = <String, int>{};
    String catName(String? id) => id == null ? '(Tiada kategori)' : (categories[id]?.name ?? '(Kategori dipadam)');
    for (final b in books) {
      catTitles[catName(b.categoryId)] = (catTitles[catName(b.categoryId)] ?? 0) + 1;
    }
    for (final c in copies) {
      final name = catName(bookById[c.bookId]?.categoryId);
      catCopies[name] = (catCopies[name] ?? 0) + 1;
    }
    final byCategory = [
      for (final n in {...catTitles.keys, ...catCopies.keys})
        CategoryCount(name: n, titles: catTitles[n] ?? 0, copies: catCopies[n] ?? 0),
    ]..sort((a, b) => b.copies.compareTo(a.copies));

    final pendingCount = _db.syncQueue.operationId.count();
    final pending = await (_db.selectOnly(_db.syncQueue)
          ..addColumns([pendingCount])
          ..where(_db.syncQueue.libraryId.equals(libraryId) & _db.syncQueue.state.isNotIn(const ['applied'])))
        .getSingle();

    return InventoryReport(
      titles: books.length,
      copies: copies.length,
      inStock: inStock,
      byStatus: byStatus,
      byCondition: byCondition,
      byLocation: byLocation,
      byCategory: byCategory,
      totalValueCents: value,
      pendingChanges: pending.read(pendingCount) ?? 0,
      generatedAt: DateTime.now(),
    );
  }

  // --------------------------------------------------------------- movements
  Stream<List<MovementView>> watchMovements(String libraryId, {String? copyId, int limit = 300}) {
    final from = _db.alias(_db.localLocations, 'from_loc');
    final to = _db.alias(_db.localLocations, 'to_loc');
    final q = _db.select(_db.localStockMovements).join([
      leftOuterJoin(
        _db.localBookCopies,
        _db.localBookCopies.id.equalsExp(_db.localStockMovements.copyId) &
            _db.localBookCopies.libraryId.equalsExp(_db.localStockMovements.libraryId),
      ),
      leftOuterJoin(
        _db.localBooks,
        _db.localBooks.id.equalsExp(_db.localBookCopies.bookId) &
            _db.localBooks.libraryId.equalsExp(_db.localBookCopies.libraryId),
      ),
      leftOuterJoin(from, from.id.equalsExp(_db.localStockMovements.fromLocationId)),
      leftOuterJoin(to, to.id.equalsExp(_db.localStockMovements.toLocationId)),
    ]);
    Expression<bool> where = _db.localStockMovements.libraryId.equals(libraryId);
    if (copyId != null) where = where & _db.localStockMovements.copyId.equals(copyId);
    q
      ..where(where)
      ..orderBy([OrderingTerm.desc(_db.localStockMovements.createdAt)])
      ..limit(limit);
    return q.watch().map((rows) => [
          for (final r in rows)
            MovementView(
              movement: r.readTable(_db.localStockMovements),
              barcode: r.readTableOrNull(_db.localBookCopies)?.barcode ?? '?',
              title: r.readTableOrNull(_db.localBooks)?.title ?? '?',
              from: r.readTableOrNull(from) == null ? null : locationLabel(r.readTable(from)),
              to: r.readTableOrNull(to) == null ? null : locationLabel(r.readTable(to)),
            ),
        ]);
  }

  // --------------------------------------------------------------- stocktake
  String _key(String libraryId, String locationId) => 'stocktake:$libraryId:$locationId';

  Future<(DateTime, Set<String>)?> _loadSession(String libraryId, String locationId) async {
    final row = await (_db.select(_db.keyValues)..where((k) => k.key.equals(_key(libraryId, locationId))))
        .getSingleOrNull();
    if (row == null) return null;
    final j = jsonDecode(row.value) as Map<String, dynamic>;
    return (DateTime.parse(j['started_at'] as String), ((j['scanned'] as List?) ?? const []).cast<String>().toSet());
  }

  Future<void> _saveSession(String libraryId, String locationId, DateTime started, Set<String> scanned) =>
      _db.into(_db.keyValues).insertOnConflictUpdate(KeyValuesCompanion.insert(
            key: _key(libraryId, locationId),
            value: jsonEncode({'started_at': started.toIso8601String(), 'scanned': scanned.toList()}),
          ));

  /// Starts (or resumes) a stocktake for one shelf location. Scans are
  /// persisted after every scan, so closing the app loses nothing.
  Future<StocktakeState> stocktake(String libraryId, String locationId) async {
    var session = await _loadSession(libraryId, locationId);
    if (session == null) {
      session = (DateTime.now(), <String>{});
      await _saveSession(libraryId, locationId, session.$1, session.$2);
    }
    final rows = await (_db.select(_db.localBookCopies).join([
      innerJoin(
        _db.localBooks,
        _db.localBooks.id.equalsExp(_db.localBookCopies.bookId) &
            _db.localBooks.libraryId.equalsExp(_db.localBookCopies.libraryId),
      ),
    ])
          ..where(_db.localBookCopies.libraryId.equals(libraryId) &
              _db.localBookCopies.deletedAt.isNull() &
              _db.localBookCopies.status.isNotIn(const ['lost', 'inactive']))
          ..orderBy([OrderingTerm.asc(_db.localBookCopies.barcode)]))
        .get();
    final expected = <(LocalBookCopy, LocalBook)>[];
    final unexpected = <(LocalBookCopy, LocalBook)>[];
    for (final r in rows) {
      final c = r.readTable(_db.localBookCopies);
      final pair = (c, r.readTable(_db.localBooks));
      if (c.locationId == locationId) {
        expected.add(pair);
      } else if (session.$2.contains(c.barcode)) {
        unexpected.add(pair);
      }
    }
    return StocktakeState(
      locationId: locationId,
      startedAt: session.$1,
      expected: expected,
      scannedBarcodes: session.$2,
      unexpected: unexpected,
    );
  }

  Future<StocktakeScan> scan(String libraryId, String locationId, String rawBarcode) async {
    final barcode = rawBarcode.trim();
    final session = await _loadSession(libraryId, locationId) ?? (DateTime.now(), <String>{});
    final hit = await _catalog.findByBarcode(libraryId, barcode);
    if (hit == null) return StocktakeScan(outcome: ScanOutcome.unknown, barcode: barcode);
    final (copy, book) = hit;
    if (copy.deletedAt != null) {
      return StocktakeScan(outcome: ScanOutcome.deleted, barcode: barcode, copy: copy, book: book);
    }
    if (session.$2.contains(barcode)) {
      return StocktakeScan(outcome: ScanOutcome.alreadyScanned, barcode: barcode, copy: copy, book: book);
    }
    await _saveSession(libraryId, locationId, session.$1, {...session.$2, barcode});
    return StocktakeScan(
      outcome: copy.locationId == locationId ? ScanOutcome.found : ScanOutcome.otherLocation,
      barcode: barcode,
      copy: copy,
      book: book,
    );
  }

  /// Ends the session. Optionally marks missing copies as lost and moves
  /// wrongly-shelved copies to this location — all in one transaction, each
  /// change recorded as a stock movement with the stocktake reference.
  Future<({int markedLost, int relocated})> finishStocktake(
    String libraryId,
    String locationId, {
    required bool markMissingAsLost,
    required bool relocateUnexpected,
    String? reference,
  }) =>
      _db.transaction(() async {
        final s = await stocktake(libraryId, locationId);
        final ref = reference ?? 'Semakan stok ${s.startedAt.toIso8601String().substring(0, 10)}';
        var lost = 0;
        var moved = 0;
        if (markMissingAsLost && s.missing.isNotEmpty) {
          lost = await _catalog.applyInventoryChange(
            libraryId,
            [for (final m in s.missing) m.$1.id],
            status: CopyStatus.lost,
            meta: MovementMeta(referenceNumber: ref, remarks: 'Tidak dijumpai semasa semakan stok'),
          );
        }
        if (relocateUnexpected && s.unexpected.isNotEmpty) {
          moved = await _catalog.applyInventoryChange(
            libraryId,
            [for (final u in s.unexpected) u.$1.id],
            locationId: locationId,
            setLocation: true,
            meta: MovementMeta(referenceNumber: ref, remarks: 'Dijumpai di rak lain semasa semakan stok'),
          );
        }
        await (_db.delete(_db.keyValues)..where((k) => k.key.equals(_key(libraryId, locationId)))).go();
        return (markedLost: lost, relocated: moved);
      });

  Future<void> cancelStocktake(String libraryId, String locationId) =>
      (_db.delete(_db.keyValues)..where((k) => k.key.equals(_key(libraryId, locationId)))).go();
}
