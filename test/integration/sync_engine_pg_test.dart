// End-to-end sync tests: two "devices" (two Drift databases) syncing through
// a real PostgreSQL that has the SmartLibrary migrations applied.
//
// Run with scripts/sync_integration_test.sh (sets SLM_PG_* and prepares the
// database). Skipped when SLM_PG_PORT is not set.
@Tags(['postgres'])
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/data/sync/sync_engine.dart';
import 'package:smartlibrary_manager/shared/models/catalog_models.dart';

import 'helpers/pg_sync_remote.dart';

final _env = Platform.environment;
final _skip = _env['SLM_PG_PORT'] == null ? 'SLM_PG_PORT not set (run scripts/sync_integration_test.sh)' : null;

class Device {
  Device(Connection conn, String user, {File? file})
      : db = AppDatabase(file == null ? NativeDatabase.memory() : NativeDatabase(file)),
        remote = FlakyRemote(PgSyncRemote(conn, user)) {
    dao = CatalogDao(db);
    engine = SyncEngine(db, remote, clock: () => now);
  }

  final AppDatabase db;
  final FlakyRemote remote;
  late final CatalogDao dao;
  late final SyncEngine engine;
  DateTime now = DateTime.now();

  Future<SyncReport> sync(String lib) => engine.syncLibrary(lib);
  Future<List<SyncQueueEntry>> queue() => db.select(db.syncQueue).get();
  Future<LocalBookCopy> copy(String id) =>
      (db.select(db.localBookCopies)..where((c) => c.id.equals(id))).getSingle();
}

void main() {
  late Connection pg;
  late String libA;
  late String libB;
  final devices = <Device>[];

  Future<Object?> q(String sql, [Map<String, Object?>? p]) async {
    final r = await pg.execute(p == null ? sql : Sql.named(sql), parameters: p);
    return r.isEmpty ? null : r.first.first;
  }

  Device device(String user, {File? file}) {
    final d = Device(pg, user, file: file);
    devices.add(d);
    return d;
  }

  setUpAll(() async {
    if (_skip != null) return;
    pg = await Connection.open(
      Endpoint(
        host: _env['SLM_PG_HOST'] ?? '127.0.0.1',
        port: int.parse(_env['SLM_PG_PORT']!),
        database: _env['SLM_PG_DB'] ?? 'slm_test',
        username: _env['SLM_PG_USER'] ?? 'postgres',
        password: _env['SLM_PG_PASSWORD'],
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  setUp(() async {
    if (_skip != null) return;
    await q('select tests.seed()');
    libA = '${await q("select tests.id('lib_a')")}';
    libB = '${await q("select tests.id('lib_b')")}';
  });

  tearDown(() async {
    if (_skip != null) return;
    for (final d in devices) {
      await d.db.close();
    }
    devices.clear();
    await q("delete from public.libraries where id in (select id from tests.ids where key like 'lib_%')");
    await q("delete from auth.users where email like '%@test.local'");
  });

  tearDownAll(() async {
    if (_skip != null) return;
    await pg.close();
  });

  test('initial pull brings only the library\'s own data', () async {
    final a = device('staff_a');
    final r = await a.sync(libA);
    expect(r.ok, isTrue, reason: '$r');
    final books = await a.db.select(a.db.localBooks).get();
    expect(books.map((b) => b.title), ['Hikayat Hang Tuah']);
    expect(books.single.syncState, 'synced');
    expect(books.single.serverVersion, 1);
    expect((await a.db.select(a.db.localBookCopies).get()).single.barcode, 'A0001');
    expect(await a.db.select(a.db.localCategories).get(), hasLength(1));
    expect(await a.db.select(a.db.localLocations).get(), hasLength(1));
    final moves = await a.db.select(a.db.localStockMovements).get();
    expect(moves.single.provisional, isFalse);
    expect(moves.every((m) => m.libraryId == libA), isTrue);
  }, skip: _skip);

  test('register offline → sync: applied, server has rows once, provisional ledger replaced', () async {
    final a = device('staff_a');
    await a.sync(libA);
    a.remote.offline = true;
    final bookId = await a.dao.createBook(libA, const BookInput(title: 'Sejarah Melayu'),
        copies: const [CopyInput(barcode: 'SM-1'), CopyInput(barcode: 'SM-2')]);
    expect((await a.sync(libA)).offline, isTrue);
    expect((await a.queue()).every((o) => o.state == 'failed'), isTrue);

    a.remote.offline = false;
    a.now = a.now.add(const Duration(minutes: 20)); // past the backoff
    final r = await a.sync(libA);
    expect(r.applied, 3, reason: '$r');
    expect(await a.queue(), isEmpty);
    expect(await q('select count(*) from public.books where id = @id', {'id': bookId}), 1);
    expect(await q("select count(*) from public.book_copies where barcode in ('SM-1','SM-2')"), 2);
    final local = await (a.db.select(a.db.localBooks)..where((b) => b.id.equals(bookId))).getSingle();
    expect(local.syncState, 'synced');
    expect(local.serverVersion, 1);
    final moves = await a.db.select(a.db.localStockMovements).get();
    expect(moves.where((m) => m.provisional), isEmpty, reason: 'replaced by server rows');
    expect(moves.where((m) => m.movementType == 'acquisition').length, 3);
  }, skip: _skip);

  test('second device sees the first device\'s changes; isolation from library B', () async {
    final a = device('staff_a');
    final b = device('editor_a');
    final outsider = device('staff_b');
    await a.dao.createBook(libA, const BookInput(title: 'Buku Peranti A'), copies: const [CopyInput(barcode: 'PA-1')]);
    await a.sync(libA);

    await b.sync(libA);
    final copyId = (await (b.db.select(b.db.localBookCopies)..where((c) => c.barcode.equals('PA-1'))).getSingle()).id;
    await b.dao.applyInventoryChange(libA, [copyId], status: CopyStatus.damaged);
    expect((await b.sync(libA)).applied, 1);

    await a.sync(libA);
    expect((await a.copy(copyId)).status, 'damaged');
    expect((await a.copy(copyId)).serverVersion, 2);

    await outsider.sync(libB);
    expect((await outsider.db.select(outsider.db.localBooks).get()).map((x) => x.title), ['Asas Fizik']);
  }, skip: _skip);

  test('connection lost after server commit: retry does not duplicate anything', () async {
    final a = device('staff_a');
    await a.sync(libA);
    final bookId = await a.dao.createBook(libA, const BookInput(title: 'Rangkaian Putus'),
        copies: const [CopyInput(barcode: 'NET-1')]);
    a.remote.loseNextPushResponse = true;
    final r1 = await a.sync(libA);
    expect(r1.offline, isTrue);
    expect(await q('select count(*) from public.books where id = @id', {'id': bookId}), 1,
        reason: 'server committed before the response was lost');
    expect((await a.queue()).map((o) => o.state).toSet(), {'failed'});

    a.now = a.now.add(const Duration(minutes: 20));
    final r2 = await a.sync(libA);
    expect(r2.applied, 2, reason: '$r2');
    expect(await a.queue(), isEmpty);
    expect(await q('select count(*) from public.books where id = @id', {'id': bookId}), 1);
    expect(
        await q("select count(*) from public.stock_movements sm join public.book_copies c on c.id = sm.copy_id where c.barcode = 'NET-1'"),
        1);
    expect(await q('select count(*) from public.sync_operations where entity_id = @id', {'id': bookId}), 1);
  }, skip: _skip);

  test('same barcode on two offline devices: second is rejected, new barcode resolves it', () async {
    final a = device('staff_a');
    final b = device('editor_a');
    await a.sync(libA);
    await b.sync(libA);
    final bookA = (await a.db.select(a.db.localBooks).get()).single.id;
    await a.dao.addCopy(libA, bookA, const CopyInput(barcode: 'DUP-1'));
    final bCopy = await b.dao.addCopy(libA, bookA, const CopyInput(barcode: 'DUP-1'));

    expect((await a.sync(libA)).applied, 1);
    final rb = await b.sync(libA);
    expect(rb.rejected, 1, reason: '$rb');
    final parked = (await b.queue()).single;
    expect(parked.state, 'rejected');
    expect(parked.lastErrorCode, 'duplicate_barcode');
    expect((await b.copy(bCopy)).syncState, 'rejected');
    // The pull still worked and brought A's copy with the same barcode.
    expect((await (b.db.select(b.db.localBookCopies)..where((c) => c.barcode.equals('DUP-1'))).get()).length, 2);

    await b.engine.replaceBarcode(parked.operationId, 'DUP-2');
    final rb2 = await b.sync(libA);
    expect(rb2.applied, 1, reason: '$rb2');
    expect(await b.queue(), isEmpty);
    expect(await q("select count(*) from public.book_copies where barcode in ('DUP-1','DUP-2')"), 2);
  }, skip: _skip);

  test('concurrent edits: conflict detected, never silently overwritten; both resolutions work', () async {
    final a = device('editor_a');
    final b = device('dual');
    await a.sync(libA);
    await b.sync(libA);
    final copyId = (await a.db.select(a.db.localBookCopies).get()).single.id;
    final locA = (await a.db.select(a.db.localLocations).get()).single.id;

    await b.dao.applyInventoryChange(libA, [copyId], status: CopyStatus.lost);
    expect((await b.sync(libA)).applied, 1);

    await a.dao.applyInventoryChange(libA, [copyId], condition: CopyCondition.poor);
    final ra = await a.sync(libA);
    expect(ra.conflicts, 1, reason: '$ra');
    expect(await q('select status || \':\' || condition from public.book_copies where id = @id', {'id': copyId}),
        'lost:good', reason: 'server unchanged by the stale edit');
    expect((await a.copy(copyId)).syncState, 'conflict');
    expect((await a.copy(copyId)).condition, 'poor', reason: 'local change kept until the user decides');

    // Option 1: keep mine → re-sent on top of server v2.
    final op = (await a.queue()).single;
    await a.engine.keepMyVersion(op.operationId);
    expect((await a.sync(libA)).applied, 1);
    expect(await q('select status || \':\' || condition || \':\' || version from public.book_copies where id = @id',
            {'id': copyId}),
        'lost:poor:3', reason: "keep-mine re-applies only a's field (condition); b's status change survives");
    expect(locA, isNotEmpty);

    // Option 2: keep server → local change discarded.
    await b.sync(libA); // b now at v3
    await b.dao.applyInventoryChange(libA, [copyId], status: CopyStatus.inactive); // based on v3
    await a.dao.applyInventoryChange(libA, [copyId], status: CopyStatus.available);
    expect((await a.sync(libA)).applied, 1, reason: 'a pushes first → v4');
    expect((await b.sync(libA)).conflicts, 1, reason: 'b edited v3, server is v4');
    final bop = (await b.queue()).single;
    await b.engine.keepServerVersion(bop.operationId);
    expect(await b.queue(), isEmpty);
    final bc = await b.copy(copyId);
    expect(bc.status, 'available');
    expect(bc.condition, 'poor');
    expect(bc.serverVersion, 4);
    expect(bc.syncState, 'synced');
    expect(await q('select status from public.book_copies where id = @id', {'id': copyId}), 'available');
  }, skip: _skip);

  test('edit made while the insert is in flight is rebased, not reported as conflict', () async {
    final a = device('editor_a');
    await a.sync(libA);
    final bookId = await a.dao.createBook(libA, const BookInput(title: 'Draf'));
    a.remote.duringPush = () => a.dao.updateBook(libA, bookId, const BookInput(title: 'Tajuk Akhir'));
    final r1 = await a.sync(libA);
    expect(r1.conflicts, 0, reason: '$r1');
    final r2 = await a.sync(libA);
    expect(r2.conflicts, 0, reason: '$r2');
    expect(await a.queue(), isEmpty);
    expect(await q('select title || \':\' || version from public.books where id = @id', {'id': bookId}), 'Tajuk Akhir:2');
    final local = await (a.db.select(a.db.localBooks)..where((b) => b.id.equals(bookId))).getSingle();
    expect(local.title, 'Tajuk Akhir');
    expect(local.syncState, 'synced');
  }, skip: _skip);

  test('removed member: sync stops with access denied and local changes are kept', () async {
    final a = device('staff_a');
    await a.sync(libA);
    await a.dao.createBook(libA, const BookInput(title: 'Selepas Dibuang'));
    await q("update public.library_members set membership_status = 'removed' where user_id = tests.uid('staff_a')");
    final r = await a.sync(libA);
    expect(r.accessDenied, isTrue, reason: '$r');
    expect((await a.queue()).single.state, 'pending', reason: 'not lost, not marked failed');
    expect(await q("select count(*) from public.books where title = 'Selepas Dibuang'"), 0);
  }, skip: _skip);

  test('forbidden change is rejected; keeping the server version reverts it locally', () async {
    final a = device('staff_a');
    await a.sync(libA);
    final book = (await a.db.select(a.db.localBooks).get()).single;
    // Staff may not edit catalogue records (CatalogActions blocks it in the UI;
    // here we bypass it to prove the server enforces it).
    await a.dao.updateBook(libA, book.id, const BookInput(title: 'Diubah oleh Staf'));
    final r = await a.sync(libA);
    expect(r.rejected, 1, reason: '$r');
    final op = (await a.queue()).single;
    expect(op.lastErrorCode, 'forbidden');
    await a.engine.keepServerVersion(op.operationId);
    final reverted = await (a.db.select(a.db.localBooks)..where((b) => b.id.equals(book.id))).getSingle();
    expect(reverted.title, 'Hikayat Hang Tuah');
    expect(reverted.syncState, 'synced');
  }, skip: _skip);

  test('hard delete on the server reaches devices through tombstones', () async {
    final a = device('staff_a');
    final cat = await q("insert into public.categories (library_id, name) values (@l, 'Sementara') returning id",
        {'l': libA});
    await a.sync(libA);
    expect((await a.db.select(a.db.localCategories).get()).length, 2);
    await q('delete from public.categories where id = @id', {'id': cat});
    await a.sync(libA);
    expect((await a.db.select(a.db.localCategories).get()).map((c) => c.name), ['Fiksyen']);
  }, skip: _skip);

  test('incremental pull only fetches changes since the cursor', () async {
    final a = device('staff_a');
    final r1 = await a.sync(libA);
    final r2 = await a.sync(libA);
    expect(r2.pulled, lessThan(r1.pulled));
    await q("update public.books set publisher = 'DBP' where library_id = @l", {'l': libA});
    await a.sync(libA);
    expect((await a.db.select(a.db.localBooks).get()).single.publisher, 'DBP');
  }, skip: _skip);

  test('app closed and reopened before syncing: local records survive and then sync', () async {
    final dir = await Directory.systemTemp.createTemp('slm_restart');
    final file = File('${dir.path}/device.sqlite');
    try {
      final first = Device(pg, 'staff_a', file: file);
      await first.sync(libA);
      first.remote.offline = true;
      final bookId = await first.dao.createBook(libA, const BookInput(title: 'Daftar Tanpa Internet'),
          copies: const [CopyInput(barcode: 'OFF-1')]);
      await first.sync(libA); // fails: offline
      await first.db.close(); // "app closed"

      final reopened = device('staff_a', file: file); // "app reopened"
      final pending = await reopened.queue();
      expect(pending.length, 2, reason: 'outbox survived the restart');
      expect((await (reopened.db.select(reopened.db.localBooks)..where((b) => b.id.equals(bookId))).getSingle()).title,
          'Daftar Tanpa Internet');
      reopened.now = DateTime.now().add(const Duration(hours: 1));
      final r = await reopened.sync(libA);
      expect(r.applied, 2, reason: '$r');
      expect(await q('select count(*) from public.books where id = @id', {'id': bookId}), 1);
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: _skip);
}
