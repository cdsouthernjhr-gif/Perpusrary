import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:smartlibrary_manager/app/router/app_router.dart';
import 'package:smartlibrary_manager/app/router/routes.dart';
import 'package:smartlibrary_manager/app/theme/app_theme.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
import 'package:smartlibrary_manager/data/repositories/library_repositories.dart';
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
  late String l1;
  late String l2;

  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(() async {
      final dao = CatalogDao(h.db);
      l1 = await dao.saveLocation('lib-a', const LocationInput(rackCode: 'R1'));
      l2 = await dao.saveLocation('lib-a', const LocationInput(rackCode: 'R2'));
      await dao.createBook('lib-a', const BookInput(title: 'Asas Fizik'), copies: [
        CopyInput(barcode: 'C1', locationId: l1),
        CopyInput(barcode: 'C2', locationId: l1),
        CopyInput(barcode: 'C3', locationId: l1),
      ]);
    });
  }

  Future<ProviderContainer> start(WidgetTester tester, {Size size = const Size(1080, 2400), double dpr = 2.5}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides: h.overrides, child: const _App()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library.LIBA')));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(_App)));
  }

  Future<void> go(WidgetTester tester, ProviderContainer c, String route) async {
    c.read(appRouterProvider).go(route);
    await tester.pumpAndSettle();
  }

  Future<void> scan(WidgetTester tester, String field, String code) async {
    await tester.enterText(find.byKey(Key(field)), code);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.scrollUntilVisible(find.byKey(Key(key)), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(() => h.db.close());
  }

  testWidgets('bulk status change via keyboard-wedge scans: unknown and duplicates rejected', (tester) async {
    h = TestHarness(server: [libA(role: LibraryRole.staff)]);
    await seed(tester);
    final c = await start(tester);
    await go(tester, c, Routes.inventoryStatus);

    await scan(tester, 'bulk.scan', 'C1');
    await scan(tester, 'bulk.scan', 'C2');
    await scan(tester, 'bulk.scan', 'C2');
    expect(find.textContaining('sudah ada dalam senarai'), findsOneWidget);
    await scan(tester, 'bulk.scan', 'ZZZ');
    expect(find.textContaining('tidak dijumpai'), findsOneWidget);
    expect(find.text('Naskhah dipilih: 2'), findsOneWidget);

    await tapKey(tester, 'bulk.apply');
    await tester.tap(find.byKey(const Key('bulk.confirm')));
    await tester.pumpAndSettle();

    final copies = await tester.runAsync(() => h.db.select(h.db.localBookCopies).get());
    expect({for (final x in copies!) x.barcode: x.status}, {'C1': 'damaged', 'C2': 'damaged', 'C3': 'available'});
    final moves = await tester.runAsync(() => h.db.select(h.db.localStockMovements).get());
    expect(moves!.where((m) => m.movementType == 'status_change' && m.quantity == -1).length, 2);
    await finish(tester);
  });

  testWidgets('stocktake: scan shelf, finish marks missing copies lost', (tester) async {
    h = TestHarness(server: [libA(role: LibraryRole.staff)]);
    await seed(tester);
    final c = await start(tester);
    await go(tester, c, Routes.stocktake);

    await tester.tap(find.byKey(const Key('stocktake.location')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rak R1').last);
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    await scan(tester, 'stocktake.scan', 'C1');
    expect(find.text('Dijumpai 1 / 3  •  Rak salah 0'), findsOneWidget);
    await scan(tester, 'stocktake.scan', 'NOPE');
    expect(find.textContaining('Tidak dikenali'), findsOneWidget);

    await tapKey(tester, 'stocktake.finish');
    expect(find.byKey(const Key('stocktake.markLost')), findsOneWidget);
    await tester.tap(find.byKey(const Key('stocktake.confirm')));
    await tester.pumpAndSettle();

    final copies = await tester.runAsync(() => h.db.select(h.db.localBookCopies).get());
    expect({for (final x in copies!) x.barcode: x.status}, {'C1': 'available', 'C2': 'lost', 'C3': 'lost'});
    await finish(tester);
  });

  testWidgets('viewer sees inventory report and history but no change actions', (tester) async {
    h = TestHarness(server: [libA(role: LibraryRole.viewer)]);
    await seed(tester);
    final c = await start(tester);
    await go(tester, c, Routes.inventory);
    expect(find.text('Jumlah naskhah'), findsOneWidget);
    expect(find.byKey(const Key('inventory.status')), findsNothing);
    expect(find.byKey(const Key('inventory.stocktake')), findsNothing);
    expect(find.byKey(const Key('inventory.movements')), findsOneWidget);

    await go(tester, c, Routes.movements);
    expect(find.textContaining('Perolehan • C1'), findsOneWidget);
    expect(find.text('belum disahkan'), findsNWidgets(3));
    await finish(tester);
  });

  testWidgets('activity log: server entries with user names; offline shows clear message', (tester) async {
    h = TestHarness();
    h.activity.entries.add(ActivityEntry(
        action: 'update',
        entityType: 'book_copies',
        userId: 'u1',
        createdAt: DateTime(2026, 11, 18, 9),
        details: const {
          'changes': {'status': {}}
        }));
    final c = await start(tester);
    await go(tester, c, Routes.activity);
    expect(find.text('Kemas kini naskhah'), findsOneWidget);
    expect(find.textContaining('Pengguna u1'), findsOneWidget);
    expect(find.textContaining('Medan: status'), findsOneWidget);

    h.activity.offline = true;
    await go(tester, c, Routes.dashboard);
    await go(tester, c, Routes.activity);
    expect(find.textContaining('Sambung ke internet'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('small phone (360dp): inventory screens render without overflow', (tester) async {
    h = TestHarness();
    await seed(tester);
    final c = await start(tester, size: const Size(1080, 2220), dpr: 3.0);
    for (final r in [Routes.inventory, Routes.inventoryStatus, Routes.inventoryRelocate, Routes.stocktake, Routes.movements,
        Routes.activity]) {
      await go(tester, c, r);
      expect(tester.takeException(), isNull, reason: 'overflow/exception on $r');
    }
    expect(l2, isNotEmpty);
    await finish(tester);
  });
}
