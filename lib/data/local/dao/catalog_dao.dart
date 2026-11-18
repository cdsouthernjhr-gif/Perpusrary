import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/barcode.dart';
import '../../../shared/models/catalog_models.dart';
import '../database/app_database.dart';

/// Local-first catalogue writes.
///
/// Every mutation updates the local row AND records an outbox operation in
/// `sync_queue` inside ONE transaction, so the UI is instantly consistent and
/// nothing is lost if the app is closed before syncing. Operations stay
/// "pending" until the server confirms them (sync engine: Phase 6).
///
/// Outbox coalescing (per entity, only for ops still `pending`):
///   insert + update  → update merged into the insert payload
///   update + update  → merged, original base_version kept
///   insert + delete  → both dropped (row never reached the server)
///   update + delete  → replaced by delete with the update's base_version
class CatalogDao {
  CatalogDao(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _db;
  final Uuid _uuid;

  // ======================================================================
  // Outbox
  // ======================================================================

  Future<void> _enqueue({
    required String libraryId,
    required String entityType,
    required String entityId,
    required String op,
    required Map<String, dynamic> payload,
    int? serverVersion,
    Map<String, dynamic>? meta,
  }) async {
    final now = DateTime.now();
    final pending = await (_db.select(_db.syncQueue)
          ..where((q) => q.libraryId.equals(libraryId) & q.entityId.equals(entityId) & q.state.equals('pending'))
          ..orderBy([(q) => OrderingTerm.asc(q.createdAt)]))
        .get();
    SyncQueueEntry? find(String type) {
      for (final p in pending) {
        if (p.operationType == type) return p;
      }
      return null;
    }

    final pendingInsert = find('insert');
    final pendingUpdate = find('update');

    Future<void> merge(SyncQueueEntry e) async {
      final merged = {...(jsonDecode(e.payload) as Map<String, dynamic>), ...payload};
      final oldMeta = e.meta == null ? null : jsonDecode(e.meta!) as Map<String, dynamic>;
      final newMeta = meta == null ? oldMeta : {...?oldMeta, ...meta};
      await (_db.update(_db.syncQueue)..where((q) => q.operationId.equals(e.operationId))).write(
        SyncQueueCompanion(
          payload: Value(jsonEncode(merged)),
          meta: Value(newMeta == null ? null : jsonEncode(newMeta)),
          updatedAt: Value(now),
        ),
      );
    }

    if (op == 'update') {
      if (pendingInsert != null) return merge(pendingInsert);
      if (pendingUpdate != null) return merge(pendingUpdate);
    }
    if (op == 'delete') {
      if (pendingInsert != null) {
        await (_db.delete(_db.syncQueue)
              ..where((q) => q.libraryId.equals(libraryId) & q.entityId.equals(entityId) & q.state.equals('pending')))
            .go();
        return;
      }
      if (pendingUpdate != null) {
        serverVersion = pendingUpdate.baseVersion;
        await (_db.delete(_db.syncQueue)..where((q) => q.operationId.equals(pendingUpdate.operationId))).go();
      }
    }

    await _db.into(_db.syncQueue).insert(SyncQueueCompanion.insert(
          operationId: _uuid.v4(),
          libraryId: libraryId,
          entityType: entityType,
          entityId: entityId,
          operationType: op,
          baseVersion: Value(op == 'insert' ? null : serverVersion),
          payload: jsonEncode(payload),
          meta: Value(meta == null ? null : jsonEncode(meta)),
          createdAt: now,
          updatedAt: now,
        ));
  }

  /// Local operations for one entity that the server has not confirmed.
  Future<List<SyncQueueEntry>> unconfirmedOps(String libraryId, String entityId) =>
      (_db.select(_db.syncQueue)
            ..where((q) => q.libraryId.equals(libraryId) & q.entityId.equals(entityId) & q.state.isNotIn(['applied']))
            ..orderBy([(q) => OrderingTerm.asc(q.createdAt)]))
          .get();

  static String? _t(String? v) => (v == null || v.trim().isEmpty) ? null : v.trim();
  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ======================================================================
  // Categories
  // ======================================================================

  Stream<List<LocalCategory>> watchCategories(String libraryId) => (_db.select(_db.localCategories)
        ..where((c) => c.libraryId.equals(libraryId) & c.deletedAt.isNull())
        ..orderBy([(c) => OrderingTerm.asc(c.name)]))
      .watch();

  Map<String, dynamic> _categoryPayload(CategoryInput i) =>
      {'name': i.name.trim(), 'code': _t(i.code), 'description': _t(i.description)};

  Future<String> saveCategory(String libraryId, CategoryInput input, {String? id}) => _db.transaction(() async {
        final name = input.name.trim();
        if (name.isEmpty) throw const AppFailure('Nama kategori diperlukan.');
        final clash = await (_db.select(_db.localCategories)
              ..where((c) =>
                  c.libraryId.equals(libraryId) &
                  c.deletedAt.isNull() &
                  c.name.lower().equals(name.toLowerCase()) &
                  (id == null ? const Constant(true) : c.id.equals(id).not())))
            .getSingleOrNull();
        if (clash != null) throw const AppFailure('Kategori dengan nama ini sudah wujud.', code: 'duplicate_category');

        final now = DateTime.now();
        if (id == null) {
          final newId = _uuid.v4();
          await _db.into(_db.localCategories).insert(LocalCategoriesCompanion.insert(
                id: newId,
                libraryId: libraryId,
                name: name,
                code: Value(_t(input.code)),
                description: Value(_t(input.description)),
                syncState: const Value('pending'),
                createdAt: now,
                updatedAt: now,
              ));
          await _enqueue(
              libraryId: libraryId, entityType: 'categories', entityId: newId, op: 'insert', payload: _categoryPayload(input));
          return newId;
        }
        final row = await _requireRow(_db.localCategories, libraryId, id);
        await (_db.update(_db.localCategories)..where((c) => c.id.equals(id) & c.libraryId.equals(libraryId))).write(
          LocalCategoriesCompanion(
            name: Value(name),
            code: Value(_t(input.code)),
            description: Value(_t(input.description)),
            syncState: const Value('pending'),
            updatedAt: Value(now),
          ),
        );
        await _enqueue(
            libraryId: libraryId,
            entityType: 'categories',
            entityId: id,
            op: 'update',
            payload: _categoryPayload(input),
            serverVersion: row.serverVersion);
        return id;
      });

  Future<void> deleteCategory(String libraryId, String id) =>
      _softDelete(_db.localCategories, 'categories', libraryId, id);

  // ======================================================================
  // Locations
  // ======================================================================

  Stream<List<LocalLocation>> watchLocations(String libraryId) => (_db.select(_db.localLocations)
        ..where((l) => l.libraryId.equals(libraryId) & l.deletedAt.isNull())
        ..orderBy([
          (l) => OrderingTerm.asc(l.building),
          (l) => OrderingTerm.asc(l.rackCode),
          (l) => OrderingTerm.asc(l.shelfCode),
        ]))
      .watch();

  Map<String, dynamic> _locationPayload(LocationInput i) => {
        'building': _t(i.building),
        'room': _t(i.room),
        'section': _t(i.section),
        'rack_code': i.rackCode.trim(),
        'shelf_code': _t(i.shelfCode),
        'description': _t(i.description),
      };

  Future<String> saveLocation(String libraryId, LocationInput input, {String? id}) => _db.transaction(() async {
        if (input.rackCode.trim().isEmpty) throw const AppFailure('Kod rak diperlukan.');
        String k(String? v) => (_t(v) ?? '').toLowerCase();
        final key = [k(input.building), k(input.room), k(input.section), k(input.rackCode), k(input.shelfCode)];
        final existing = await (_db.select(_db.localLocations)
              ..where((l) => l.libraryId.equals(libraryId) & l.deletedAt.isNull()))
            .get();
        final clash = existing.any((l) =>
            l.id != id &&
            [k(l.building), k(l.room), k(l.section), k(l.rackCode), k(l.shelfCode)].join('|') == key.join('|'));
        if (clash) throw const AppFailure('Lokasi rak ini sudah wujud.', code: 'duplicate_location');

        final now = DateTime.now();
        final companion = LocalLocationsCompanion(
          building: Value(_t(input.building)),
          room: Value(_t(input.room)),
          section: Value(_t(input.section)),
          rackCode: Value(input.rackCode.trim()),
          shelfCode: Value(_t(input.shelfCode)),
          description: Value(_t(input.description)),
          syncState: const Value('pending'),
          updatedAt: Value(now),
        );
        if (id == null) {
          final newId = _uuid.v4();
          await _db.into(_db.localLocations).insert(
              companion.copyWith(id: Value(newId), libraryId: Value(libraryId), createdAt: Value(now)));
          await _enqueue(
              libraryId: libraryId, entityType: 'locations', entityId: newId, op: 'insert', payload: _locationPayload(input));
          return newId;
        }
        final row = await _requireRow(_db.localLocations, libraryId, id);
        await (_db.update(_db.localLocations)..where((l) => l.id.equals(id) & l.libraryId.equals(libraryId)))
            .write(companion);
        await _enqueue(
            libraryId: libraryId,
            entityType: 'locations',
            entityId: id,
            op: 'update',
            payload: _locationPayload(input),
            serverVersion: row.serverVersion);
        return id;
      });

  Future<void> deleteLocation(String libraryId, String id) => _db.transaction(() async {
        final inUse = await (_db.select(_db.localBookCopies)
              ..where((c) => c.libraryId.equals(libraryId) & c.locationId.equals(id) & c.deletedAt.isNull())
              ..limit(1))
            .getSingleOrNull();
        if (inUse != null) {
          throw const AppFailure('Lokasi ini masih digunakan oleh naskhah. Pindahkan naskhah dahulu.',
              code: 'location_in_use');
        }
        await _softDelete(_db.localLocations, 'locations', libraryId, id);
      });

  // ======================================================================
  // Books
  // ======================================================================

  /// Catalogue list with copy counts. [query] matches title, author or ISBN.
  Stream<List<BookListItem>> watchBooks(String libraryId, {String query = '', String? categoryId, int limit = 200}) {
    final q = query.trim().toLowerCase();
    final isbnQ = q.replaceAll(RegExp(r'[\s\-]'), '');
    final where = StringBuffer('b.library_id = ?1 AND b.deleted_at IS NULL');
    final vars = <Variable<Object>>[Variable.withString(libraryId)];
    if (q.isNotEmpty) {
      vars.add(Variable.withString('%$q%'));
      vars.add(Variable.withString('$isbnQ%'));
      where.write(' AND (lower(b.title) LIKE ?2 OR lower(coalesce(b.author, \'\')) LIKE ?2 OR b.isbn LIKE ?3)');
    }
    if (categoryId != null) {
      vars.add(Variable.withString(categoryId));
      where.write(' AND b.category_id = ?${vars.length}');
    }
    return _db
        .customSelect(
          'SELECT b.*, '
          '(SELECT count(*) FROM local_book_copies c WHERE c.library_id = b.library_id AND c.book_id = b.id '
          '   AND c.deleted_at IS NULL) AS copy_count, '
          '(SELECT name FROM local_categories k WHERE k.library_id = b.library_id AND k.id = b.category_id) '
          '   AS category_name '
          'FROM local_books b WHERE $where ORDER BY lower(b.title) LIMIT $limit',
          variables: vars,
          readsFrom: {_db.localBooks, _db.localBookCopies, _db.localCategories},
        )
        .watch()
        .asyncMap((rows) async => [
              for (final r in rows)
                BookListItem(
                  book: await _db.localBooks.mapFromRow(r),
                  copyCount: r.read<int>('copy_count'),
                  categoryName: r.readNullable<String>('category_name'),
                ),
            ]);
  }

  Stream<LocalBook?> watchBook(String libraryId, String id) =>
      (_db.select(_db.localBooks)..where((b) => b.libraryId.equals(libraryId) & b.id.equals(id))).watchSingleOrNull();

  Map<String, dynamic> _bookPayload(BookInput i) => {
        'title': i.title.trim(),
        'subtitle': _t(i.subtitle),
        'isbn': _t(i.isbn),
        'author': _t(i.author),
        'publisher': _t(i.publisher),
        'publication_year': i.publicationYear,
        'edition': _t(i.edition),
        'language': _t(i.language),
        'description': _t(i.description),
        'category_id': i.categoryId,
        'call_number': _t(i.callNumber),
        'cover_image_path': _t(i.coverImagePath),
        'metadata_source': i.metadataSource,
      };

  LocalBooksCompanion _bookCompanion(BookInput i, DateTime now) => LocalBooksCompanion(
        title: Value(i.title.trim()),
        subtitle: Value(_t(i.subtitle)),
        isbn: Value(_t(i.isbn)),
        author: Value(_t(i.author)),
        publisher: Value(_t(i.publisher)),
        publicationYear: Value(i.publicationYear),
        edition: Value(_t(i.edition)),
        language: Value(_t(i.language)),
        description: Value(_t(i.description)),
        categoryId: Value(i.categoryId),
        callNumber: Value(_t(i.callNumber)),
        coverImagePath: Value(_t(i.coverImagePath)),
        metadataSource: Value(i.metadataSource),
        syncState: const Value('pending'),
        updatedAt: Value(now),
      );

  /// Registers a title and (optionally) its first copies atomically.
  Future<String> createBook(String libraryId, BookInput input,
      {List<CopyInput> copies = const [], MovementMeta? meta}) {
    return _db.transaction(() async {
      if (input.title.trim().isEmpty) throw const AppFailure('Tajuk diperlukan.');
      final now = DateTime.now();
      final id = _uuid.v4();
      await _db.into(_db.localBooks).insert(
          _bookCompanion(input, now).copyWith(id: Value(id), libraryId: Value(libraryId), createdAt: Value(now)));
      await _enqueue(libraryId: libraryId, entityType: 'books', entityId: id, op: 'insert', payload: _bookPayload(input));
      for (final c in copies) {
        await _insertCopy(libraryId, id, c, meta);
      }
      return id;
    });
  }

  Future<void> updateBook(String libraryId, String id, BookInput input) => _db.transaction(() async {
        if (input.title.trim().isEmpty) throw const AppFailure('Tajuk diperlukan.');
        final row = await _requireRow(_db.localBooks, libraryId, id);
        await (_db.update(_db.localBooks)..where((b) => b.id.equals(id) & b.libraryId.equals(libraryId)))
            .write(_bookCompanion(input, DateTime.now()));
        await _enqueue(
            libraryId: libraryId,
            entityType: 'books',
            entityId: id,
            op: 'update',
            payload: _bookPayload(input),
            serverVersion: row.serverVersion);
      });

  /// Soft delete. Refused while the title still has active copies, so no
  /// physical copy is left pointing at a deleted title.
  Future<void> deleteBook(String libraryId, String id) => _db.transaction(() async {
        final copies = await copyCount(libraryId, id);
        if (copies > 0) {
          throw AppFailure('Judul ini masih mempunyai $copies naskhah. Padam atau pindahkan naskhah dahulu.',
              code: 'book_has_copies');
        }
        await _softDelete(_db.localBooks, 'books', libraryId, id);
      });

  /// Suggests possible duplicates (never merges). Edition differences are
  /// legitimate: same title + different edition/year scores lower.
  Future<List<DuplicateCandidate>> findPossibleDuplicates(
    String libraryId, {
    String? isbn,
    required String title,
    String? author,
    String? publisher,
    int? year,
    String? excludeId,
  }) async {
    final rows = await (_db.select(_db.localBooks)..where((b) => b.libraryId.equals(libraryId) & b.deletedAt.isNull()))
        .get();
    final tTokens = _tokens(title);
    final aTokens = _tokens(author ?? '');
    final out = <DuplicateCandidate>[];
    for (final b in rows) {
      if (b.id == excludeId) continue;
      final reasons = <String>[];
      var score = 0.0;
      if (isbn != null && isbn.isNotEmpty && b.isbn == isbn) {
        score += 0.5;
        reasons.add('isbn');
      }
      final tSim = _jaccard(tTokens, _tokens(b.title));
      if (tSim >= 0.6) {
        score += 0.3 * tSim;
        reasons.add('title');
      }
      if (aTokens.isNotEmpty && b.author != null) {
        final aSim = _jaccard(aTokens, _tokens(b.author!));
        if (aSim >= 0.5) {
          score += 0.1 * aSim;
          reasons.add('author');
        }
      }
      if (publisher != null && publisher.trim().isNotEmpty &&
          b.publisher?.trim().toLowerCase() == publisher.trim().toLowerCase()) {
        score += 0.05;
        reasons.add('publisher');
      }
      if (year != null && b.publicationYear == year) {
        score += 0.05;
        reasons.add('year');
      }
      if (reasons.contains('isbn') || (reasons.contains('title') && score >= 0.3)) {
        out.add(DuplicateCandidate(book: b, score: score, reasons: reasons));
      }
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    return out.take(10).toList();
  }

  static Set<String> _tokens(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9À-ɏ\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toSet();

  static double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    return a.intersection(b).length / a.union(b).length;
  }

  // ======================================================================
  // Copies
  // ======================================================================

  Future<int> copyCount(String libraryId, String bookId) async {
    final c = _db.localBookCopies.id.count();
    final row = await (_db.selectOnly(_db.localBookCopies)
          ..addColumns([c])
          ..where(_db.localBookCopies.libraryId.equals(libraryId) &
              _db.localBookCopies.bookId.equals(bookId) &
              _db.localBookCopies.deletedAt.isNull()))
        .getSingle();
    return row.read(c) ?? 0;
  }

  Stream<List<CopyListItem>> watchCopies(String libraryId, String bookId) {
    final q = _db.select(_db.localBookCopies).join([
      leftOuterJoin(
        _db.localLocations,
        _db.localLocations.id.equalsExp(_db.localBookCopies.locationId) &
            _db.localLocations.libraryId.equalsExp(_db.localBookCopies.libraryId),
      ),
    ])
      ..where(_db.localBookCopies.libraryId.equals(libraryId) &
          _db.localBookCopies.bookId.equals(bookId) &
          _db.localBookCopies.deletedAt.isNull())
      ..orderBy([OrderingTerm.asc(_db.localBookCopies.barcode)]);
    return q.watch().map((rows) => [
          for (final r in rows)
            CopyListItem(copy: r.readTable(_db.localBookCopies), location: r.readTableOrNull(_db.localLocations)),
        ]);
  }

  /// All copies of the library (copy management screen), with title and
  /// location. [query] matches barcode, accession number or title.
  Stream<List<(CopyListItem, LocalBook)>> watchAllCopies(String libraryId,
      {String query = '', String? status, int limit = 300}) {
    final q = query.trim().toLowerCase();
    final join = _db.select(_db.localBookCopies).join([
      innerJoin(
        _db.localBooks,
        _db.localBooks.id.equalsExp(_db.localBookCopies.bookId) &
            _db.localBooks.libraryId.equalsExp(_db.localBookCopies.libraryId),
      ),
      leftOuterJoin(
        _db.localLocations,
        _db.localLocations.id.equalsExp(_db.localBookCopies.locationId) &
            _db.localLocations.libraryId.equalsExp(_db.localBookCopies.libraryId),
      ),
    ]);
    Expression<bool> where = _db.localBookCopies.libraryId.equals(libraryId) & _db.localBookCopies.deletedAt.isNull();
    if (q.isNotEmpty) {
      where = where &
          (_db.localBookCopies.barcode.lower().like('%$q%') |
              _db.localBookCopies.accessionNumber.lower().like('%$q%') |
              _db.localBooks.title.lower().like('%$q%'));
    }
    if (status != null) where = where & _db.localBookCopies.status.equals(status);
    join
      ..where(where)
      ..orderBy([OrderingTerm.asc(_db.localBookCopies.barcode)])
      ..limit(limit);
    return join.watch().map((rows) => [
          for (final r in rows)
            (
              CopyListItem(copy: r.readTable(_db.localBookCopies), location: r.readTableOrNull(_db.localLocations)),
              r.readTable(_db.localBooks),
            ),
        ]);
  }

  /// Barcode lookup (scanner / keyboard-wedge input), including soft-deleted
  /// copies so the user learns the barcode is reserved.
  Future<(LocalBookCopy, LocalBook?)?> findByBarcode(String libraryId, String barcode) async {
    final copy = await (_db.select(_db.localBookCopies)
          ..where((c) => c.libraryId.equals(libraryId) & c.barcode.equals(barcode.trim())))
        .getSingleOrNull();
    if (copy == null) return null;
    final book = await (_db.select(_db.localBooks)
          ..where((b) => b.libraryId.equals(libraryId) & b.id.equals(copy.bookId)))
        .getSingleOrNull();
    return (copy, book);
  }

  Map<String, dynamic> _copyPayload(String bookId, CopyInput i) => {
        'book_id': bookId,
        'barcode': i.barcode.trim(),
        'accession_number': _t(i.accessionNumber),
        'condition': i.condition.value,
        'status': i.status.value,
        'location_id': i.locationId,
        'acquisition_date': i.acquisitionDate == null ? null : _date(i.acquisitionDate!),
        'acquisition_source': i.acquisitionSource?.value,
        // numeric(12,2) on the server
        'acquisition_cost': i.acquisitionCostCents == null ? null : i.acquisitionCostCents! / 100,
        'remarks': _t(i.remarks),
      };

  Future<void> _assertBarcodeFree(String libraryId, String barcode, {String? exceptId}) async {
    final hit = await (_db.select(_db.localBookCopies)
          ..where((c) => c.libraryId.equals(libraryId) & c.barcode.equals(barcode)))
        .getSingleOrNull();
    if (hit != null && hit.id != exceptId) {
      throw AppFailure('Barcode "$barcode" sudah digunakan dalam perpustakaan ini.',
          code: 'duplicate_barcode', cause: hit.id);
    }
  }

  Future<void> _assertAccessionFree(String libraryId, String? accession, {String? exceptId}) async {
    if (accession == null || accession.trim().isEmpty) return;
    final hit = await (_db.select(_db.localBookCopies)
          ..where((c) => c.libraryId.equals(libraryId) & c.accessionNumber.equals(accession.trim())))
        .getSingleOrNull();
    if (hit != null && hit.id != exceptId) {
      throw AppFailure('Nombor perolehan "${accession.trim()}" sudah digunakan.', code: 'duplicate_accession_number');
    }
  }

  Future<String> _insertCopy(String libraryId, String bookId, CopyInput i, MovementMeta? meta) async {
    final barcode = i.barcode.trim();
    await _assertBarcodeFree(libraryId, barcode);
    await _assertAccessionFree(libraryId, i.accessionNumber);
    final now = DateTime.now();
    final id = _uuid.v4();
    await _db.into(_db.localBookCopies).insert(LocalBookCopiesCompanion.insert(
          id: id,
          libraryId: libraryId,
          bookId: bookId,
          barcode: barcode,
          accessionNumber: Value(_t(i.accessionNumber)),
          condition: Value(i.condition.value),
          status: Value(i.status.value),
          locationId: Value(i.locationId),
          acquisitionDate: Value(i.acquisitionDate),
          acquisitionSource: Value(i.acquisitionSource?.value),
          acquisitionCostCents: Value(i.acquisitionCostCents),
          remarks: Value(_t(i.remarks)),
          syncState: const Value('pending'),
          createdAt: now,
          updatedAt: now,
        ));
    await _enqueue(
        libraryId: libraryId,
        entityType: 'book_copies',
        entityId: id,
        op: 'insert',
        payload: _copyPayload(bookId, i),
        meta: meta?.toJson());
    return id;
  }

  Future<String> addCopy(String libraryId, String bookId, CopyInput input, {MovementMeta? meta}) =>
      _db.transaction(() async {
        await _requireRow(_db.localBooks, libraryId, bookId);
        return _insertCopy(libraryId, bookId, input, meta);
      });

  Future<void> updateCopy(String libraryId, String id, CopyInput input, {MovementMeta? meta}) =>
      _db.transaction(() async {
        final row = await _requireRow(_db.localBookCopies, libraryId, id);
        final barcode = input.barcode.trim();
        await _assertBarcodeFree(libraryId, barcode, exceptId: id);
        await _assertAccessionFree(libraryId, input.accessionNumber, exceptId: id);
        await (_db.update(_db.localBookCopies)..where((c) => c.id.equals(id) & c.libraryId.equals(libraryId))).write(
          LocalBookCopiesCompanion(
            barcode: Value(barcode),
            accessionNumber: Value(_t(input.accessionNumber)),
            condition: Value(input.condition.value),
            status: Value(input.status.value),
            locationId: Value(input.locationId),
            acquisitionDate: Value(input.acquisitionDate),
            acquisitionSource: Value(input.acquisitionSource?.value),
            acquisitionCostCents: Value(input.acquisitionCostCents),
            remarks: Value(_t(input.remarks)),
            syncState: const Value('pending'),
            updatedAt: Value(DateTime.now()),
          ),
        );
        await _enqueue(
            libraryId: libraryId,
            entityType: 'book_copies',
            entityId: id,
            op: 'update',
            payload: _copyPayload(row.bookId, input),
            serverVersion: row.serverVersion,
            meta: meta?.toJson());
      });

  Future<void> deleteCopy(String libraryId, String id) =>
      _softDelete(_db.localBookCopies, 'book_copies', libraryId, id);

  /// Next system barcode for this device. The per-library counter lives in
  /// key_values; candidates already used locally are skipped.
  Future<String> nextGeneratedBarcode({
    required String libraryId,
    required String libraryCode,
    required String deviceId,
  }) =>
      _db.transaction(() async {
        final key = 'barcode_seq:$libraryId';
        final cur = await (_db.select(_db.keyValues)..where((k) => k.key.equals(key))).getSingleOrNull();
        var seq = int.tryParse(cur?.value ?? '') ?? 0;
        String candidate;
        while (true) {
          seq++;
          candidate = CopyBarcode.generate(libraryCode: libraryCode, deviceId: deviceId, sequence: seq);
          final used = await (_db.select(_db.localBookCopies)
                ..where((c) => c.libraryId.equals(libraryId) & c.barcode.equals(candidate)))
              .getSingleOrNull();
          if (used == null) break;
        }
        await _db.into(_db.keyValues).insertOnConflictUpdate(KeyValuesCompanion.insert(key: key, value: '$seq'));
        return candidate;
      });

  // ======================================================================
  // Shared
  // ======================================================================

  Future<D> _requireRow<T extends Table, D>(TableInfo<T, D> table, String libraryId, String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM ${table.actualTableName} WHERE id = ? AND library_id = ?',
      variables: [Variable.withString(id), Variable.withString(libraryId)],
      readsFrom: {table},
    ).getSingleOrNull();
    if (row == null) throw const AppFailure('Rekod tidak dijumpai dalam perpustakaan ini.', code: 'not_found');
    return table.map(row.data);
  }

  Future<void> _softDelete<T extends Table, D>(TableInfo<T, D> table, String entity, String libraryId, String id) =>
      _db.transaction(() async {
        final row = await _db.customSelect(
          'SELECT server_version FROM ${table.actualTableName} WHERE id = ? AND library_id = ? AND deleted_at IS NULL',
          variables: [Variable.withString(id), Variable.withString(libraryId)],
          readsFrom: {table},
        ).getSingleOrNull();
        if (row == null) throw const AppFailure('Rekod tidak dijumpai dalam perpustakaan ini.', code: 'not_found');
        final serverVersion = row.readNullable<int>('server_version');
        final now = DateTime.now();
        await _db.customUpdate(
          'UPDATE ${table.actualTableName} SET deleted_at = ?, updated_at = ?, sync_state = ? '
          'WHERE id = ? AND library_id = ?',
          variables: [
            Variable.withDateTime(now),
            Variable.withDateTime(now),
            Variable.withString('pending'),
            Variable.withString(id),
            Variable.withString(libraryId),
          ],
          updates: {table},
        );
        await _enqueue(
            libraryId: libraryId, entityType: entity, entityId: id, op: 'delete', payload: const {}, serverVersion: serverVersion);
      });
}
