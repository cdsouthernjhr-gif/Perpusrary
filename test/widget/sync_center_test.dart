import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:smartlibrary_manager/app/app.dart';
import 'package:smartlibrary_manager/app/router/app_router.dart';
import 'package:smartlibrary_manager/app/router/routes.dart';
import 'package:smartlibrary_manager/app/theme/app_theme.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
import 'package:smartlibrary_manager/data/local/dao/local_dao.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/data/sync/sync_remote.dart';
import 'package:smartlibrary_manager/shared/models/catalog_models.dart';
import 'package:smartlibrary_manager/shared/models/library_models.dart';

import '../helpers/fakes.dart';

class _App extends ConsumerWidget {
  const _App();
  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      MaterialApp.router(theme: AppTheme.light(), routerConfig: ref.watch(appRouterProvider));
}

void main() {
  late TestHarness h;

  Future<ProviderContainer> start(WidgetTester tester, {Size size = const Size(1080, 2400), double dpr = 2.5}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides: h.overrides, child: const _App()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library.LIBA')));
    await tester.pumpAndSettle();
    final c = ProviderScope.containerOf(tester.element(find.byType(_App)));
    c.read(appRouterProvider).go(Routes.syncCenter);
    await tester.pumpAndSettle();
    return c;
  }

  /// Engine work is real async DB I/O: let it finish outside FakeAsync.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pumpAndSettle();
    }
  }

  Future<void> tap(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.tap(find.byKey(key));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(() => h.db.close());
  }

  Future<String> newBook(WidgetTester tester, {List<CopyInput> copies = const []}) async =>
      (await tester.runAsync(() => CatalogDao(h.db).createBook('lib-a', const BookInput(title: 'Buku Sync'), copies: copies)))!;

  testWidgets('"Sync sekarang" pushes pending changes and marks them synced', (tester) async {
    h = TestHarness();
    final bookId = await newBook(tester, copies: const [CopyInput(barcode: 'S1')]);
    await start(tester);
    expect(find.textContaining('Menunggu: 2'), findsOneWidget);
    await tap(tester, const Key('sync.now'));
    expect(find.textContaining('Menunggu: 0'), findsOneWidget);
    expect(find.textContaining('2 diterima'), findsOneWidget);
    expect(h.sync.pushed.map((o) => o['entity_type']), ['books', 'book_copies']);
    final book = await tester.runAsync(
        () => (h.db.select(h.db.localBooks)..where((b) => b.id.equals(bookId))).getSingle());
    expect(book!.syncState, 'synced');
    expect(book.serverVersion, 1);
    await finish(tester);
  });

  testWidgets('offline: clear message, changes stay queued', (tester) async {
    h = TestHarness();
    await newBook(tester);
    h.sync.offline = true;
    await start(tester);
    await tap(tester, const Key('sync.now'));
    expect(find.textContaining('Tiada sambungan'), findsWidgets);
    final q = await tester.runAsync(() => h.db.select(h.db.syncQueue).get());
    expect(q!.single.state, 'failed');
    expect(q.single.lastErrorCode, 'network');
    await finish(tester);
  });

  testWidgets('conflict: shown with actions; "Guna versi pelayan" restores server data', (tester) async {
    h = TestHarness();
    final bookId = await newBook(tester);
    await tester.runAsync(() async {
      await h.db.update(h.db.syncQueue).write(const SyncQueueCompanion(state: Value('applied')));
      await h.db.customStatement("UPDATE local_books SET server_version = 1, sync_state = 'synced'");
      await CatalogDao(h.db).updateBook('lib-a', bookId, const BookInput(title: 'Tajuk Saya'));
    });
    h.sync.onPush = (op) => PushResult(
          operationId: op['operation_id'] as String,
          status: 'conflict',
          errorCode: 'version_mismatch',
          serverRow: {
            ...FakeSyncRemote.serverRowFor('lib-a', op, version: 2),
            'title': 'Tajuk Pengguna Lain',
          },
        );
    await start(tester);
    await tap(tester, const Key('sync.now'));
    expect(find.text('Konflik data'), findsNWidgets(2), reason: 'problem card + status chip');
    expect(find.textContaining('diubah oleh pengguna lain'), findsOneWidget);
    expect(find.text('Kekalkan perubahan saya'), findsOneWidget, reason: 'library admin may override');

    h.sync.onPush = null;
    final op = (await tester.runAsync(() => h.db.select(h.db.syncQueue).get()))!
        .firstWhere((o) => o.state == 'conflict');
    await tap(tester, Key('problem.keepServer.${op.operationId}'));
    final book = await tester.runAsync(
        () => (h.db.select(h.db.localBooks)..where((b) => b.id.equals(bookId))).getSingle());
    expect(book!.title, 'Tajuk Pengguna Lain');
    expect(book.syncState, 'synced');
    expect(find.text('Tiada masalah sync.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('staff cannot override a catalogue conflict (only discard)', (tester) async {
    h = TestHarness(server: [libA(role: LibraryRole.staff)]);
    await newBook(tester);
    h.sync.onPush = (op) => PushResult(
        operationId: op['operation_id'] as String,
        status: 'conflict',
        errorCode: 'version_mismatch',
        serverRow: FakeSyncRemote.serverRowFor('lib-a', op, version: 2));
    await start(tester);
    await tap(tester, const Key('sync.now'));
    expect(find.text('Konflik data'), findsNWidgets(2), reason: 'problem card + status chip');
    expect(find.text('Kekalkan perubahan saya'), findsNothing);
    expect(find.text('Guna versi pelayan'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('duplicate barcode rejected: "Jana barcode baharu" re-sends with a new barcode', (tester) async {
    h = TestHarness();
    await newBook(tester, copies: const [CopyInput(barcode: 'DUP-1')]);
    h.sync.onPush = (op) => op['entity_type'] == 'book_copies'
        ? PushResult(operationId: op['operation_id'] as String, status: 'rejected', errorCode: 'duplicate_barcode')
        : PushResult(
            operationId: op['operation_id'] as String,
            status: 'applied',
            serverRow: FakeSyncRemote.serverRowFor('lib-a', op));
    await start(tester);
    await tester.runAsync(() => KeyValueDao(h.db).put(LocalKeys.deviceId, '3f2a9c10-0000-4000-8000-000000000001'));
    await tap(tester, const Key('sync.now'));
    expect(find.text('Ditolak oleh pelayan'), findsOneWidget);
    expect(find.textContaining('Barcode sudah digunakan'), findsOneWidget);

    h.sync.onPush = null;
    final op = (await tester.runAsync(() => h.db.select(h.db.syncQueue).get()))!.single;
    await tap(tester, Key('problem.newBarcode.${op.operationId}'));
    final copy = (await tester.runAsync(() => h.db.select(h.db.localBookCopies).get()))!.single;
    expect(copy.barcode, isNot('DUP-1'));
    expect(copy.syncState, 'synced');
    expect((h.sync.pushed.last['payload'] as Map<String, dynamic>)['barcode'], copy.barcode);
    expect(find.text('Tiada masalah sync.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('small phone (360dp): Sync Center with problems renders without overflow', (tester) async {
    h = TestHarness();
    await newBook(tester, copies: const [CopyInput(barcode: 'DUP-LONG-BARCODE-000000000001')]);
    h.sync.onPush = (op) => PushResult(
        operationId: op['operation_id'] as String, status: 'rejected', errorCode: 'duplicate_barcode');
    await start(tester, size: const Size(1080, 2220), dpr: 3.0);
    await tap(tester, const Key('sync.now'));
    expect(tester.takeException(), isNull);
    expect(find.text('Ditolak oleh pelayan'), findsWidgets);
    await finish(tester);
  });

  testWidgets('auto sync: choosing a library triggers a sync without user action', (tester) async {
    h = TestHarness(autoSync: true);
    await newBook(tester);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides: h.overrides, child: const SmartLibraryApp()));
    await tester.pumpAndSettle();
    expect(h.sync.pushed, isEmpty);
    await tester.tap(find.byKey(const Key('library.LIBA')));
    await settle(tester);
    expect(h.sync.pushed.map((o) => o['entity_type']), ['books']);
    final q = await tester.runAsync(() => h.db.select(h.db.syncQueue).get());
    expect(q, isEmpty);
    await finish(tester);
  });
}
