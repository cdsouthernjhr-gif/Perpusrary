import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/core/errors/app_failure.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
import 'package:smartlibrary_manager/data/local/dao/inventory_dao.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/shared/models/catalog_models.dart';

const lib = 'lib-a';

/// Same cases as supabase/tests/database/60_inventory.sql (server trigger).
final parityCases = <(String, CopySnapshot?, CopySnapshot, String?, int?)>[
  ('new available', null, const CopySnapshot(status: 'available', condition: 'good'), 'acquisition', 1),
  ('new damaged', null, const CopySnapshot(status: 'damaged', condition: 'damaged'), 'acquisition', 0),
  ('available→lost', const CopySnapshot(status: 'available', condition: 'good'),
      const CopySnapshot(status: 'lost', condition: 'good'), 'status_change', -1),
  ('lost→available', const CopySnapshot(status: 'lost', condition: 'good'),
      const CopySnapshot(status: 'available', condition: 'good'), 'status_change', 1),
  ('available→in_processing', const CopySnapshot(status: 'available', condition: 'good'),
      const CopySnapshot(status: 'in_processing', condition: 'good'), 'status_change', 0),
  ('relocate', const CopySnapshot(status: 'available', locationId: 'L1', condition: 'good'),
      const CopySnapshot(status: 'available', locationId: 'L2', condition: 'good'), 'relocation', 0),
  ('condition', const CopySnapshot(status: 'available', condition: 'good'),
      const CopySnapshot(status: 'available', condition: 'poor'), 'adjustment', 0),
  ('delete available', const CopySnapshot(status: 'available', condition: 'good'),
      const CopySnapshot(status: 'available', condition: 'good', deleted: true), 'removal', -1),
  ('delete damaged', const CopySnapshot(status: 'damaged', condition: 'good'),
      const CopySnapshot(status: 'damaged', condition: 'good', deleted: true), 'removal', 0),
  ('status+location', const CopySnapshot(status: 'available', locationId: 'L1', condition: 'good'),
      const CopySnapshot(status: 'damaged', locationId: 'L2', condition: 'good'), 'status_change', -1),
  ('no change', const CopySnapshot(status: 'available', condition: 'good'),
      const CopySnapshot(status: 'available', condition: 'good'), null, null),
];

void main() {
  group('copyMovement parity with server trigger', () {
    for (final (name, before, after, type, qty) in parityCases) {
      test(name, () {
        final m = copyMovement(before: before, after: after);
        expect(m?.type, type);
        expect(m?.quantity, qty);
      });
    }
  });

  late AppDatabase db;
  late CatalogDao cat;
  late InventoryDao inv;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    cat = CatalogDao(db);
    inv = InventoryDao(db, cat);
  });
  tearDown(() => db.close());

  Future<List<LocalStockMovement>> movements() =>
      (db.select(db.localStockMovements)..orderBy([(m) => OrderingTerm.asc(m.createdAt)])).get();

  Future<(String, String, List<String>)> seed() async {
    final l1 = await cat.saveLocation(lib, const LocationInput(rackCode: 'R1'));
    final l2 = await cat.saveLocation(lib, const LocationInput(rackCode: 'R2'));
    final book = await cat.createBook(lib, const BookInput(title: 'Asas Fizik'), copies: [
      CopyInput(barcode: 'C1', locationId: l1, acquisitionCostCents: 2500),
      CopyInput(barcode: 'C2', locationId: l1, acquisitionCostCents: 1500),
      CopyInput(barcode: 'C3', locationId: l1),
    ]);
    final ids = (await cat.watchCopies(lib, book).first).map((c) => c.copy.id).toList();
    return (l1, l2, ids);
  }

  test('local changes record provisional movements tied to their outbox operation', () async {
    final (_, l2, ids) = await seed();
    final m0 = await movements();
    expect(m0.map((m) => m.movementType), ['acquisition', 'acquisition', 'acquisition']);
    expect(m0.every((m) => m.provisional && m.operationId != null), isTrue);

    await cat.applyInventoryChange(lib, [ids[0]], status: CopyStatus.damaged,
        meta: const MovementMeta(referenceNumber: 'ADJ-1', remarks: 'Basah'));
    await cat.applyInventoryChange(lib, [ids[1]], locationId: l2, setLocation: true);
    final m = await movements();
    expect(m[3].movementType, 'status_change');
    expect(m[3].quantity, -1);
    expect(m[3].referenceNumber, 'ADJ-1');
    expect(m[4].movementType, 'relocation');
    expect(m[4].toLocationId, l2);
  });

  test('bulk change is all-or-nothing and skips copies already in the target state', () async {
    final (_, _, ids) = await seed();
    expect(await cat.applyInventoryChange(lib, ids, status: CopyStatus.inactive), 3);
    expect(await cat.applyInventoryChange(lib, ids, status: CopyStatus.inactive), 0, reason: 'nothing to change');

    await cat.deleteCopy(lib, ids[2]);
    final before = (await movements()).length;
    await expectLater(cat.applyInventoryChange(lib, ids, status: CopyStatus.available), throwsA(isA<AppFailure>()));
    expect((await movements()).length, before, reason: 'rolled back');
    final statuses = (await db.select(db.localBookCopies).get()).map((c) => c.status).toSet();
    expect(statuses, {'inactive'});
  });

  test('deleting a never-synced copy drops its ops and provisional ledger rows', () async {
    final (_, _, ids) = await seed();
    await cat.deleteCopy(lib, ids[0]);
    final m = await movements();
    expect(m.where((x) => x.copyId == ids[0]), isEmpty);
    expect((await db.select(db.syncQueue).get()).where((q) => q.entityId == ids[0]), isEmpty);
  });

  test('deleting a synced copy records a removal (-1)', () async {
    final (_, _, ids) = await seed();
    await db.update(db.syncQueue).write(const SyncQueueCompanion(state: Value('applied')));
    await db.customStatement("UPDATE local_book_copies SET server_version = 1, sync_state = 'synced'");
    await cat.deleteCopy(lib, ids[0], meta: const MovementMeta(remarks: 'Lupus'));
    final last = (await movements()).last;
    expect(last.movementType, 'removal');
    expect(last.quantity, -1);
    expect(last.remarks, 'Lupus');
  });

  test('inventory report is derived from copies (status, location, category, value)', () async {
    final (l1, l2, ids) = await seed();
    await cat.applyInventoryChange(lib, [ids[0]], status: CopyStatus.lost);
    await cat.applyInventoryChange(lib, [ids[1]], locationId: l2, setLocation: true);
    final r = await inv.report(lib);
    expect(r.titles, 1);
    expect(r.copies, 3);
    expect(r.inStock, 2);
    expect(r.byStatus, {'lost': 1, 'available': 2});
    expect({for (final l in r.byLocation) l.locationId: l.count}, {l1: 2, l2: 1});
    expect(r.byCategory.single.name, '(Tiada kategori)');
    expect(r.totalValueCents, 4000);
    expect(r.pendingChanges, greaterThan(0));
  });

  test('movement history view joins barcode, title and location labels', () async {
    final (_, l2, ids) = await seed();
    await cat.applyInventoryChange(lib, [ids[0]], locationId: l2, setLocation: true);
    final v = await inv.watchMovements(lib, copyId: ids[0]).first;
    expect(v.first.movement.movementType, 'relocation');
    expect(v.first.barcode, 'C1');
    expect(v.first.title, 'Asas Fizik');
    expect(v.first.from, 'Rak R1');
    expect(v.first.to, 'Rak R2');
  });

  test('stocktake: found / wrong shelf / unknown / duplicate, persisted, then finish', () async {
    final (l1, l2, ids) = await seed();
    final other = await cat.createBook(lib, const BookInput(title: 'Lain'), copies: [CopyInput(barcode: 'X9', locationId: l2)]);
    expect(other, isNotNull);

    expect((await inv.scan(lib, l1, 'C1')).outcome, ScanOutcome.found);
    expect((await inv.scan(lib, l1, 'C1')).outcome, ScanOutcome.alreadyScanned);
    expect((await inv.scan(lib, l1, 'X9')).outcome, ScanOutcome.otherLocation);
    expect((await inv.scan(lib, l1, 'NOPE')).outcome, ScanOutcome.unknown);

    // Session survives "app restart" (new DAO instance, same DB).
    final s = await InventoryDao(db, CatalogDao(db)).stocktake(lib, l1);
    expect(s.found.map((e) => e.$1.barcode), ['C1']);
    expect(s.missing.map((e) => e.$1.barcode), ['C2', 'C3']);
    expect(s.unexpected.map((e) => e.$1.barcode), ['X9']);

    final res = await inv.finishStocktake(lib, l1, markMissingAsLost: true, relocateUnexpected: true, reference: 'ST-1');
    expect(res, (markedLost: 2, relocated: 1));
    final copies = {for (final c in await db.select(db.localBookCopies).get()) c.barcode: c};
    expect(copies['C2']!.status, 'lost');
    expect(copies['C3']!.status, 'lost');
    expect(copies['X9']!.locationId, l1);
    expect((await movements()).where((m) => m.referenceNumber == 'ST-1').length, 3);
    // Session cleared → a new stocktake starts empty.
    expect((await inv.stocktake(lib, l1)).scannedBarcodes, isEmpty);
    expect(ids, hasLength(3));
  });
}
