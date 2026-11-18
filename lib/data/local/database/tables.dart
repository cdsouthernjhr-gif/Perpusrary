import 'package:drift/drift.dart';

/// Local (per-device) mirror of server data + sync bookkeeping.
///
/// Every library-owned table carries `libraryId`; DAOs always filter by it.
/// Server-controlled values (`serverVersion`) are only ever written from
/// server responses, never from local edits.

/// Libraries the signed-in user may access, as last confirmed by the server
/// via `my_libraries()`. Only a cache: access is re-validated every session.
@DataClassName('LocalLibrary')
class LocalLibraries extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get code => text()();
  TextColumn get organizationName => text().nullable()();
  TextColumn get logoPath => text().nullable()();
  TextColumn get status => text()();
  TextColumn get role => text().nullable()(); // null for Super Admin without membership
  BoolColumn get isSuperAdmin => boolean().withDefault(const Constant(false))();
  IntColumn get titleCount => integer().withDefault(const Constant(0))();
  IntColumn get copyCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get verifiedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Small key/value store (device id, owner user id, last active library).
@DataClassName('KeyValue')
class KeyValues extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Sync state of a local row.
///   synced   – equals the server version
///   pending  – local change waiting in sync_queue
///   conflict – server reported a version conflict
///   rejected – server rejected the change (e.g. duplicate barcode)
mixin SyncColumns on Table {
  TextColumn get id => text()();
  TextColumn get libraryId => text()();
  IntColumn get serverVersion => integer().nullable()(); // null = never reached server
  TextColumn get syncState => text().withDefault(const Constant('synced'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
}

@DataClassName('LocalCategory')
class LocalCategories extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get code => text().nullable()();
  TextColumn get description => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('LocalLocation')
class LocalLocations extends Table with SyncColumns {
  TextColumn get building => text().nullable()();
  TextColumn get room => text().nullable()();
  TextColumn get section => text().nullable()();
  TextColumn get rackCode => text()();
  TextColumn get shelfCode => text().nullable()();
  TextColumn get description => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('LocalBook')
class LocalBooks extends Table with SyncColumns {
  TextColumn get title => text()();
  TextColumn get subtitle => text().nullable()();
  TextColumn get isbn => text().nullable()();
  TextColumn get author => text().nullable()();
  TextColumn get publisher => text().nullable()();
  IntColumn get publicationYear => integer().nullable()();
  TextColumn get edition => text().nullable()();
  TextColumn get language => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get categoryId => text().nullable()();
  TextColumn get callNumber => text().nullable()();
  TextColumn get coverImagePath => text().nullable()();
  TextColumn get metadataSource => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('LocalBookCopy')
class LocalBookCopies extends Table with SyncColumns {
  TextColumn get bookId => text()();
  TextColumn get barcode => text()();
  TextColumn get accessionNumber => text().nullable()();
  TextColumn get condition => text().withDefault(const Constant('good'))();
  TextColumn get locationId => text().nullable()();
  DateTimeColumn get acquisitionDate => dateTime().nullable()();
  TextColumn get acquisitionSource => text().nullable()();
  /// Stored as cents to avoid floating point rounding.
  IntColumn get acquisitionCostCents => integer().nullable()();
  TextColumn get status => text().withDefault(const Constant('available'))();
  TextColumn get remarks => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  // Local guard only — the server UNIQUE constraint is authoritative, since
  // another offline device may use the same barcode.
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {libraryId, barcode},
      ];
}

/// Inventory ledger mirror. Rows come from two places:
///  * provisional=true  – recorded on this device when a local change is made
///    (same rules as the server trigger), tied to the outbox [operationId];
///  * provisional=false – authoritative rows pulled from the server (Phase 6).
/// When the server confirms an operation, its provisional rows are replaced
/// by the server's rows. Counts are never stored: stock is always computed
/// from book_copies, so there is no read-modify-write of stock totals.
@DataClassName('LocalStockMovement')
class LocalStockMovements extends Table {
  TextColumn get id => text()();
  TextColumn get libraryId => text()();
  TextColumn get copyId => text()();
  TextColumn get movementType => text()();
  IntColumn get quantity => integer()();
  TextColumn get fromStatus => text().nullable()();
  TextColumn get toStatus => text().nullable()();
  TextColumn get fromLocationId => text().nullable()();
  TextColumn get toLocationId => text().nullable()();
  TextColumn get referenceNumber => text().nullable()();
  TextColumn get remarks => text().nullable()();
  TextColumn get createdBy => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  BoolColumn get provisional => boolean().withDefault(const Constant(true))();
  TextColumn get operationId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Outbox of local changes. operationId is the server idempotency key, so a
/// retried operation is never applied twice.
@DataClassName('SyncQueueEntry')
class SyncQueue extends Table {
  TextColumn get operationId => text()();
  TextColumn get libraryId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get operationType => text()(); // insert | update | delete
  IntColumn get baseVersion => integer().nullable()();
  TextColumn get payload => text()(); // JSON
  TextColumn get meta => text().nullable()(); // JSON
  /// pending | in_flight | applied | conflict | rejected | failed
  TextColumn get state => text().withDefault(const Constant('pending'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  TextColumn get lastErrorCode => text().nullable()();
  TextColumn get lastErrorMessage => text().nullable()();
  TextColumn get serverResult => text().nullable()(); // JSON
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {operationId};
}

/// Pull cursor (server `snapshot_xmin`) per library and entity type.
@DataClassName('SyncCursor')
class SyncCursors extends Table {
  TextColumn get libraryId => text()();
  TextColumn get entityType => text()();
  TextColumn get sinceXid => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {libraryId, entityType};
}
