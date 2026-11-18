import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:smartlibrary_manager/app/app.dart';
import 'package:smartlibrary_manager/app/router/app_router.dart';
import 'package:smartlibrary_manager/app/router/routes.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
import 'package:smartlibrary_manager/shared/models/catalog_models.dart';

import '../helpers/fakes.dart';

/// Every screen, in the configurations library staff actually use:
/// small phone with large accessibility text, dark mode, tablet landscape.
/// Fails on any overflow / exception (spec §15: easy to use, responsive).
void main() {
  late TestHarness h;
  late String bookId;
  late String copyId;

  List<String> routes() => [
        Routes.libraries, Routes.invitations, Routes.settings, Routes.dashboard, Routes.libraryEdit,
        Routes.books, Routes.book(bookId), Routes.bookNew, Routes.bookEdit(bookId), Routes.copyNew(bookId),
        Routes.copyEdit(bookId, copyId), Routes.copies, Routes.barcode, Routes.categories, Routes.locations,
        Routes.inventory, Routes.inventoryStatus, Routes.inventoryRelocate, Routes.stocktake, Routes.movements,
        Routes.activity, Routes.syncCenter, Routes.importExcel, Routes.exportExcel, Routes.backup, Routes.reports,
        Routes.members,
      ];

  Future<void> runAll(WidgetTester tester, {required Size size, required double dpr, double text = 1.0, bool dark = false}) async {
    h = TestHarness();
    (bookId, copyId) = (await tester.runAsync(() async {
      final dao = CatalogDao(h.db);
      final loc = await dao.saveLocation('lib-a',
          const LocationInput(building: 'Bangunan Pentadbiran Utama', room: 'Bilik Rujukan', section: 'Sejarah', rackCode: 'R-12', shelfCode: 'P-3'));
      final cat = await dao.saveCategory('lib-a', const CategoryInput(name: 'Kesusasteraan Melayu Tradisional'));
      final b = await dao.createBook('lib-a',
          BookInput(title: 'Hikayat Hang Tuah: Edisi Beranotasi Lengkap Untuk Pelajar Sekolah Menengah', author: 'Kassim Ahmad',
              isbn: '9789836261234', categoryId: cat),
          copies: [CopyInput(barcode: 'LIBA-7F3K-000001', accessionNumber: 'P2026-000123', locationId: loc)]);
      final c = (await dao.watchCopies('lib-a', b).first).single.copy.id;
      return (b, c);
    }))!;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = dpr;
    tester.platformDispatcher.textScaleFactorTestValue = text;
    tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearAllTestValues();
    });
    await tester.pumpWidget(ProviderScope(overrides: h.overrides, child: const SmartLibraryApp()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'switcher');
    await tester.tap(find.byKey(const Key('library.LIBA')));
    await tester.pumpAndSettle();
    final c = ProviderScope.containerOf(tester.element(find.byType(SmartLibraryApp)));
    final failures = <String>[];
    for (final r in routes()) {
      c.read(appRouterProvider).go(r);
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pumpAndSettle();
      }
      final e = tester.takeException();
      if (e != null) failures.add('$r: ${'$e'.split('\n').first}');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(() => h.db.close());
    expect(failures, isEmpty, reason: failures.join('\n'));
  }

  testWidgets('phone 360dp, text 1.5×', (t) => runAll(t, size: const Size(1080, 2220), dpr: 3, text: 1.5));
  testWidgets('phone 360dp, text 2.0× (Android largest accessibility size)',
      (t) => runAll(t, size: const Size(1080, 2220), dpr: 3, text: 2.0));
  testWidgets('phone 360dp, dark mode', (t) => runAll(t, size: const Size(1080, 2220), dpr: 3, dark: true));
  testWidgets('tablet landscape 1280×800', (t) => runAll(t, size: const Size(2560, 1600), dpr: 2));
}
