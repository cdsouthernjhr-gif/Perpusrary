import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../local/database/app_database.dart';
import 'backoff.dart';
import 'server_row_mapper.dart';
import 'sync_remote.dart';

/// Outcome of one sync run for one library.
class SyncReport {
  SyncReport(this.libraryId);

  final String libraryId;
  int pushed = 0;
  int applied = 0;
  int conflicts = 0;
  int rejected = 0;
  int failed = 0;
  int pulled = 0;
  bool offline = false;
  bool accessDenied = false;
  String? error;
  DateTime? finishedAt;

  bool get ok => !offline && !accessDenied && error == null;

  @override
  String toString() =>
      'SyncReport(pushed $pushed, applied $applied, conflicts $conflicts, rejected $rejected, failed $failed, '
      'pulled $pulled, offline $offline, denied $accessDenied, error $error)';
}

/// Offline-first sync for ONE device.
///
/// Push:
///  * outbox ops are sent FIFO in batches; a batch is marked `in_flight`
///    before sending, so a crash or lost response is retried with the SAME
///    operation ids (the server is idempotent on operation_id);
///  * an op is only "done" when the server answers `applied`;
///  * `conflict` / `rejected` ops are parked for the user (Sync Center) and
///    block later ops of the same entity;
///  * transient failures back off exponentially (see [retryDelay]);
///  * when an op is applied while newer local edits exist, those edits are
///    rebased onto the new server version instead of producing a false conflict.
///
/// Pull: per entity type, keyset pages over the server's transaction-id
/// cursor (see docs/sync-design.md). Rows with unconfirmed local changes are
/// not overwritten — the push of those changes decides (conflict detection).
class SyncEngine {
  SyncEngine(this._db, this._remote, {this.batchSize = 200, DateTime Function()? clock, Random? random})
      : _clock = clock ?? DateTime.now,
        _random = random ?? Random();

  final AppDatabase _db;
  final SyncRemote _remote;
  final int batchSize;
  final DateTime Function() _clock;
  final Random _random;
  final _running = <String, Future<SyncReport>>{};

  static const pullOrder = ['categories', 'locations', 'books', 'book_copies', 'stock_movements', 'sync_tombstones'];
  static const _unconfirmed = ['pending', 'in_flight', 'failed', 'conflict', 'rejected'];

  /// Single-flight per library: concurrent callers share the running sync.
  Future<SyncReport> syncLibrary(String libraryId, {String? deviceId, bool pull = true}) {
    final existing = _running[libraryId];
    if (existing != null) return existing;
    // NB: block body — `=> _running.remove(..)` would return this very future
    // to whenComplete, which would then wait for itself forever.
    final f = _run(libraryId, deviceId, pull).whenComplete(() {
      _running.remove(libraryId);
    });
    _running[libraryId] = f;
    return f;
  }

  bool isRunning(String libraryId) => _running.containsKey(libraryId);

  Future<SyncReport> _run(String libraryId, String? deviceId, bool pull) async {
    final report = SyncReport(libraryId);
    try {
      await _push(libraryId, deviceId, report);
      if (pull && !report.offline) await _pull(libraryId, report);
    } on SyncTransportException catch (e) {
      report
        ..offline = true
        ..error = e.message;
    } on SyncAccessDenied catch (e) {
      report
        ..accessDenied = true
        ..error = e.message;
    }
    report.finishedAt = _clock();
    return report;
  }

  // ======================================================================
  // Push
  // ======================================================================

  /// Ops that may be sent now, FIFO, stopping at the first op that is still
  /// backing off (later ops may depend on it, e.g. a copy on its book).
  Future<List<SyncQueueEntry>> _nextBatch(String libraryId) async {
    final all = await (_db.select(_db.syncQueue)
          ..where((q) => q.libraryId.equals(libraryId) & q.state.isIn(_unconfirmed))
          ..orderBy([(q) => OrderingTerm.asc(q.createdAt)]))
        .get();
    final parkedEntities = <String>{};
    final batch = <SyncQueueEntry>[];
    final now = _clock();
    for (final op in all) {
      if (op.state == 'conflict' || op.state == 'rejected') {
        parkedEntities.add(op.entityId);
        continue;
      }
      if (parkedEntities.contains(op.entityId)) continue;
      if (op.state == 'failed' && op.nextAttemptAt != null && op.nextAttemptAt!.isAfter(now)) break;
      batch.add(op);
      if (batch.length >= batchSize) break;
    }
    return batch;
  }

  Map<String, dynamic> _wire(SyncQueueEntry op) => {
        'operation_id': op.operationId,
        'entity_type': op.entityType,
        'entity_id': op.entityId,
        'operation_type': op.operationType,
        'base_version': op.baseVersion,
        'payload': jsonDecode(op.payload),
        if (op.meta != null) 'meta': jsonDecode(op.meta!),
      };

  Future<void> _push(String libraryId, String? deviceId, SyncReport report) async {
    for (var round = 0; round < 100; round++) {
      final batch = await _nextBatch(libraryId);
      if (batch.isEmpty) return;
      final ids = batch.map((o) => o.operationId).toList();
      await (_db.update(_db.syncQueue)..where((q) => q.operationId.isIn(ids)))
          .write(SyncQueueCompanion(state: const Value('in_flight'), updatedAt: Value(_clock())));

      List<PushResult> results;
      try {
        results = await _remote.push(libraryId, deviceId, batch.map(_wire).toList());
      } on SyncTransportException {
        // The server may or may not have applied them: retry later with the
        // same operation ids (idempotent).
        await _markFailed(batch, 'network', 'Tiada sambungan ke pelayan.');
        report.failed += batch.length;
        rethrow;
      } on SyncAccessDenied {
        await (_db.update(_db.syncQueue)..where((q) => q.operationId.isIn(ids)))
            .write(const SyncQueueCompanion(state: Value('pending')));
        rethrow;
      }
      report.pushed += batch.length;
      final byId = {for (final r in results) r.operationId: r};
      await _db.transaction(() async {
        for (final op in batch) {
          final r = byId[op.operationId];
          if (r == null) {
            await _markFailed([op], 'no_result', 'Pelayan tidak memulangkan keputusan.');
            report.failed++;
            continue;
          }
          await _applyResult(op, r, report);
        }
      });
      // A batch that only produced failures would loop forever: stop.
      if (results.every((r) => r.status == 'failed')) return;
    }
  }

  Future<void> _markFailed(List<SyncQueueEntry> ops, String code, String message) async {
    for (final op in ops) {
      final attempts = op.attempts + 1;
      await (_db.update(_db.syncQueue)..where((q) => q.operationId.equals(op.operationId))).write(SyncQueueCompanion(
        state: const Value('failed'),
        attempts: Value(attempts),
        nextAttemptAt: Value(_clock().add(retryDelay(attempts, random: _random))),
        lastErrorCode: Value(code),
        lastErrorMessage: Value(message),
        updatedAt: Value(_clock()),
      ));
    }
  }

  Future<void> _applyResult(SyncQueueEntry op, PushResult r, SyncReport report) async {
    final resultJson = jsonEncode({
      'status': r.status,
      'error_code': r.errorCode,
      'error_message': r.errorMessage,
      'server_row': r.serverRow,
    });
    switch (r.status) {
      case 'applied':
        report.applied++;
        // Confirmed: drop the op and the provisional ledger rows it produced
        // (the server's own movements arrive with the pull).
        await (_db.delete(_db.syncQueue)..where((q) => q.operationId.equals(op.operationId))).go();
        await (_db.delete(_db.localStockMovements)..where((m) => m.operationId.equals(op.operationId))).go();
        if (r.serverRow != null) await _absorbServerRow(op.libraryId, op.entityType, op.entityId, r.serverRow!);
      case 'conflict':
      case 'rejected':
        if (r.status == 'conflict') {
          report.conflicts++;
        } else {
          report.rejected++;
        }
        await (_db.update(_db.syncQueue)..where((q) => q.operationId.equals(op.operationId))).write(SyncQueueCompanion(
          state: Value(r.status),
          lastErrorCode: Value(r.errorCode),
          lastErrorMessage: Value(r.errorMessage),
          serverResult: Value(resultJson),
          updatedAt: Value(_clock()),
        ));
        await _setLocalSyncState(op.entityType, op.libraryId, op.entityId, r.status);
      default: // failed (server error) → retry later
        report.failed++;
        await _markFailed([op], r.errorCode ?? 'server_error', r.errorMessage ?? 'Ralat pelayan.');
    }
  }

  /// After an applied op: take the server row if nothing else is pending for
  /// the entity, otherwise only adopt its version and rebase pending ops.
  Future<void> _absorbServerRow(String libraryId, String entity, String entityId, Map<String, dynamic> row) async {
    final version = (row['version'] as num?)?.toInt();
    final others = await (_db.select(_db.syncQueue)
          ..where((q) => q.libraryId.equals(libraryId) & q.entityId.equals(entityId) & q.state.isIn(_unconfirmed)))
        .get();
    if (others.isEmpty) {
      await _upsert(entity, row);
      return;
    }
    await _db.customUpdate(
      'UPDATE ${_table(entity)} SET server_version = ? WHERE id = ? AND library_id = ?',
      variables: [Variable.withInt(version ?? 0), Variable.withString(entityId), Variable.withString(libraryId)],
    );
    for (final o in others) {
      if (o.operationType == 'insert' || o.state == 'in_flight') continue;
      await (_db.update(_db.syncQueue)..where((q) => q.operationId.equals(o.operationId)))
          .write(SyncQueueCompanion(baseVersion: Value(version)));
    }
  }

  static String _table(String entity) => switch (entity) {
        'categories' => 'local_categories',
        'locations' => 'local_locations',
        'books' => 'local_books',
        'book_copies' => 'local_book_copies',
        _ => throw ArgumentError('Unknown entity $entity'),
      };

  Future<void> _setLocalSyncState(String entity, String libraryId, String id, String state) => _db.customUpdate(
        'UPDATE ${_table(entity)} SET sync_state = ? WHERE id = ? AND library_id = ?',
        variables: [Variable.withString(state), Variable.withString(id), Variable.withString(libraryId)],
      );

  Future<void> _upsert(String entity, Map<String, dynamic> row) async {
    switch (entity) {
      case 'categories':
        await _db.into(_db.localCategories).insertOnConflictUpdate(ServerRowMapper.category(row));
      case 'locations':
        await _db.into(_db.localLocations).insertOnConflictUpdate(ServerRowMapper.location(row));
      case 'books':
        await _db.into(_db.localBooks).insertOnConflictUpdate(ServerRowMapper.book(row));
      case 'book_copies':
        await _db.into(_db.localBookCopies).insertOnConflictUpdate(ServerRowMapper.copy(row));
      case 'stock_movements':
        await _db.into(_db.localStockMovements).insertOnConflictUpdate(ServerRowMapper.movement(row));
    }
  }

  // ======================================================================
  // Pull
  // ======================================================================

  Future<void> _pull(String libraryId, SyncReport report) async {
    for (final entity in pullOrder) {
      final cursor = await (_db.select(_db.syncCursors)
            ..where((c) => c.libraryId.equals(libraryId) & c.entityType.equals(entity)))
          .getSingleOrNull();
      String? firstXmin;
      String? afterXid;
      String? afterId;
      for (var page = 0; page < 10000; page++) {
        final p = await _remote.pull(libraryId, entity, since: cursor?.sinceXid, afterXid: afterXid, afterId: afterId);
        firstXmin ??= p.snapshotXmin;
        await _db.transaction(() async {
          for (final row in p.rows) {
            await _applyPulledRow(libraryId, entity, row);
          }
        });
        report.pulled += p.rows.length;
        if (!p.hasMore) break;
        afterXid = p.lastXid;
        afterId = p.lastId;
      }
      // The first page's snapshot_xmin is the safe next cursor (see docs).
      await _db.into(_db.syncCursors).insertOnConflictUpdate(SyncCursorsCompanion.insert(
            libraryId: libraryId,
            entityType: entity,
            sinceXid: firstXmin!,
            updatedAt: _clock(),
          ));
    }
  }

  Future<bool> _hasUnconfirmed(String libraryId, String entityId) async {
    final row = await (_db.select(_db.syncQueue)
          ..where((q) => q.libraryId.equals(libraryId) & q.entityId.equals(entityId) & q.state.isIn(_unconfirmed))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  Future<void> _applyPulledRow(String libraryId, String entity, Map<String, dynamic> row) async {
    if ((row['library_id'] as String?) != libraryId) return; // defence in depth
    if (entity == 'stock_movements') {
      await _upsert(entity, row);
      return;
    }
    if (entity == 'sync_tombstones') {
      final target = row['entity_type'] as String;
      final id = row['entity_id'] as String;
      if (await _hasUnconfirmed(libraryId, id)) return;
      await _db.customStatement(
          'DELETE FROM ${_table(target)} WHERE id = ? AND library_id = ?', [id, libraryId]);
      return;
    }
    final id = row['id'] as String;
    // Unconfirmed local change wins locally until its push is decided.
    if (await _hasUnconfirmed(libraryId, id)) return;
    await _upsert(entity, row);
  }

  // ======================================================================
  // Resolution (Sync Center)
  // ======================================================================

  Map<String, dynamic>? _serverRowOf(SyncQueueEntry op) {
    if (op.serverResult == null) return null;
    return (jsonDecode(op.serverResult!) as Map<String, dynamic>)['server_row'] as Map<String, dynamic>?;
  }

  /// Discards the local change and adopts the server state. For a rejected
  /// insert (record never existed on the server) the local record is removed.
  Future<void> keepServerVersion(String operationId) => _db.transaction(() async {
        final op = await _op(operationId);
        final serverRow = _serverRowOf(op);
        await (_db.delete(_db.syncQueue)..where((q) => q.operationId.equals(operationId))).go();
        await (_db.delete(_db.localStockMovements)..where((m) => m.operationId.equals(operationId))).go();
        if (serverRow != null && serverRow['id'] == op.entityId) {
          await _upsert(op.entityType, serverRow);
        } else if (op.operationType == 'insert') {
          await _db.customStatement(
              'DELETE FROM ${_table(op.entityType)} WHERE id = ? AND library_id = ?', [op.entityId, op.libraryId]);
          await (_db.delete(_db.localStockMovements)..where((m) => m.copyId.equals(op.entityId))).go();
        } else {
          // No server row to restore from (older server / not readable):
          // force a full re-download of this entity type on the next pull.
          await _setLocalSyncState(op.entityType, op.libraryId, op.entityId, 'synced');
          await (_db.delete(_db.syncCursors)
                ..where((c) => c.libraryId.equals(op.libraryId) & c.entityType.equals(op.entityType)))
              .go();
          await _db.customUpdate(
            'UPDATE ${_table(op.entityType)} SET server_version = NULL WHERE id = ? AND library_id = ?',
            variables: [Variable.withString(op.entityId), Variable.withString(op.libraryId)],
          );
        }
      });

  /// Re-sends the local change on top of the current server version
  /// (conflict only). Server permissions still apply.
  Future<void> keepMyVersion(String operationId) => _db.transaction(() async {
        final op = await _op(operationId);
        if (op.state != 'conflict') throw StateError('Only conflicts can be overridden');
        final serverRow = _serverRowOf(op);
        final version = (serverRow?['version'] as num?)?.toInt();
        await _requeue(op, baseVersion: Value(version), operationType: op.operationType == 'insert' && serverRow != null ? 'update' : null);
        if (version != null) {
          await _db.customUpdate(
            'UPDATE ${_table(op.entityType)} SET server_version = ?, sync_state = ? WHERE id = ? AND library_id = ?',
            variables: [
              Variable.withInt(version),
              Variable.withString('pending'),
              Variable.withString(op.entityId),
              Variable.withString(op.libraryId),
            ],
          );
        }
      });

  /// Rejected because the barcode is already used on the server: give the
  /// copy a new barcode and send again.
  Future<void> replaceBarcode(String operationId, String newBarcode) => _db.transaction(() async {
        final op = await _op(operationId);
        if (op.entityType != 'book_copies') throw StateError('Not a copy operation');
        final payload = {...(jsonDecode(op.payload) as Map<String, dynamic>), 'barcode': newBarcode};
        await (_db.update(_db.localBookCopies)
              ..where((c) => c.id.equals(op.entityId) & c.libraryId.equals(op.libraryId)))
            .write(LocalBookCopiesCompanion(barcode: Value(newBarcode), syncState: const Value('pending')));
        await _requeue(op, payload: payload);
      });

  /// Retry a failed op immediately (skip the remaining backoff).
  Future<void> retryNow(String operationId) =>
      (_db.update(_db.syncQueue)..where((q) => q.operationId.equals(operationId)))
          .write(const SyncQueueCompanion(nextAttemptAt: Value(null)));

  Future<SyncQueueEntry> _op(String operationId) =>
      (_db.select(_db.syncQueue)..where((q) => q.operationId.equals(operationId))).getSingle();

  /// A resolved op gets a NEW operation id: the old id is already recorded
  /// on the server with its old result and would be answered from there.
  Future<void> _requeue(SyncQueueEntry op,
      {Value<int?> baseVersion = const Value.absent(), Map<String, dynamic>? payload, String? operationType}) async {
    final newId = const Uuid().v4();
    await (_db.update(_db.syncQueue)..where((q) => q.operationId.equals(op.operationId))).write(SyncQueueCompanion(
      operationId: Value(newId),
      state: const Value('pending'),
      attempts: const Value(0),
      nextAttemptAt: const Value(null),
      lastErrorCode: const Value(null),
      lastErrorMessage: const Value(null),
      serverResult: const Value(null),
      baseVersion: baseVersion,
      operationType: operationType == null ? const Value.absent() : Value(operationType),
      payload: payload == null ? const Value.absent() : Value(jsonEncode(payload)),
      updatedAt: Value(_clock()),
    ));
    await (_db.update(_db.localStockMovements)..where((m) => m.operationId.equals(op.operationId)))
        .write(LocalStockMovementsCompanion(operationId: Value(newId)));
    await _setLocalSyncState(op.entityType, op.libraryId, op.entityId, 'pending');
  }
}
