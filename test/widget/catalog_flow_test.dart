import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:smartlibrary_manager/app/router/app_router.dart';
import 'package:smartlibrary_manager/app/router/routes.dart';
import 'package:smartlibrary_manager/app/theme/app_theme.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
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

  Future<ProviderContainer> start(WidgetTester tester, {String library = 'LIBA'}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides: h.overrides, child: const _App()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('library.$library')));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(_App)));
  }

  Future<void> go(WidgetTester tester, ProviderContainer c, String route) async {
    c.read(appRouterProvider).go(route);
    await tester.pumpAndSettle();
  }

  Future<void> tapSave(WidgetTester tester, String key) async {
    await tester.scrollUntilVisible(find.byKey(Key(key)), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(Key(key)));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(() => h.db.close());
  }

  testWidgets('staff registers a book offline: local rows + outbox, generated barcode', (tester) async {
    h = TestHarness(server: [libA(role: LibraryRole.staff), libB()]);
    final c = await start(tester);
    await go(tester, c, Routes.books);
    expect(find.textContaining('Belum ada buku'), findsOneWidget);

    await tester.tap(find.byKey(const Key('books.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('book.title')), 'Sejarah Melayu');
    await tapSave(tester, 'book.save');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('bookDetail.title')), findsOneWidget);
    expect(find.text('Naskhah (1)'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^LIBA-[0-9A-Z]{4}-000001$')), findsOneWidget);
    expect(find.text('Menunggu sync ke pelayan'), findsOneWidget);

    final ops = await tester.runAsync(() => h.db.select(h.db.syncQueue).get());
    expect(ops!.map((o) => '${o.entityType}:${o.operationType}'), ['books:insert', 'book_copies:insert']);
    expect(ops.every((o) => o.libraryId == 'lib-a'), isTrue);
    expect((jsonDecode(ops.first.payload) as Map<String, dynamic>)['title'], 'Sejarah Melayu');
    await finish(tester);
  });

  testWidgets('possible duplicate is suggested before saving; user may still save a new edition', (tester) async {
    h = TestHarness();
    await tester.runAsync(() => CatalogDao(h.db).createBook('lib-a',
        const BookInput(title: 'Hikayat Hang Tuah', isbn: '9789836261234', edition: '1')));
    final c = await start(tester);
    await go(tester, c, Routes.bookNew);
    await tester.enterText(find.byKey(const Key('book.isbn')), '9789836261234');
    await tester.enterText(find.byKey(const Key('book.title')), 'Hikayat Hang Tuah');
    await tapSave(tester, 'book.save');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('duplicates.dialog')), findsOneWidget);
    expect(find.textContaining('ISBN sama'), findsOneWidget);
    await tester.tap(find.byKey(const Key('duplicates.saveAnyway')));
    await tester.pumpAndSettle();

    final books = await tester.runAsync(() => h.db.select(h.db.localBooks).get());
    expect(books!.length, 2, reason: 'never merged automatically');
    await finish(tester);
  });

  testWidgets('viewer can browse but has no add buttons', (tester) async {
    h = TestHarness(server: [libA(role: LibraryRole.viewer)]);
    final c = await start(tester);
    await go(tester, c, Routes.books);
    expect(find.byKey(const Key('books.add')), findsNothing);
    await go(tester, c, Routes.categories);
    expect(find.byKey(const Key('categories.add')), findsNothing);
    await finish(tester);
  });

  testWidgets('keyboard-wedge scanner: barcode + Enter finds the copy; unknown code reported', (tester) async {
    h = TestHarness();
    await tester.runAsync(() => CatalogDao(h.db)
        .createBook('lib-a', const BookInput(title: 'Asas Fizik'), copies: const [CopyInput(barcode: 'A0001')]));
    final c = await start(tester);
    await go(tester, c, Routes.barcode);

    await tester.enterText(find.byKey(const Key('lookup.field')), 'A0001');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lookup.result')), findsOneWidget);
    expect(find.text('Asas Fizik'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('lookup.field')), 'ZZZ9');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lookup.notFound')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('duplicate barcode on a new copy is refused with an explanatory dialog', (tester) async {
    h = TestHarness();
    final bookId = await tester.runAsync(() => CatalogDao(h.db)
        .createBook('lib-a', const BookInput(title: 'Asas Fizik'), copies: const [CopyInput(barcode: 'A0001')]));
    final c = await start(tester);
    await go(tester, c, Routes.copyNew(bookId!));
    await tester.enterText(find.byKey(const Key('copy.barcode')), 'A0001');
    await tapSave(tester, 'copy.save');
    await tester.pumpAndSettle();
    expect(find.text('Barcode sudah digunakan'), findsOneWidget);
    expect(find.text('Jana barcode baharu'), findsOneWidget);
    final copies = await tester.runAsync(() => h.db.select(h.db.localBookCopies).get());
    expect(copies!.length, 1);
    await finish(tester);
  });

  testWidgets('books of library A are not shown in library B', (tester) async {
    h = TestHarness();
    await tester.runAsync(() => CatalogDao(h.db).createBook('lib-a', const BookInput(title: 'Buku Rahsia A')));
    final c = await start(tester, library: 'LIBB');
    await go(tester, c, Routes.books);
    expect(find.text('Buku Rahsia A'), findsNothing);
    expect(find.textContaining('Belum ada buku'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('small phone (360dp): key catalog screens render without overflow', (tester) async {
    h = TestHarness();
    final bookId = await tester.runAsync(() async {
      final dao = CatalogDao(h.db);
      final loc = await dao.saveLocation('lib-a',
          const LocationInput(building: 'Bangunan Utama Sekolah', room: 'Bilik Bacaan', section: 'Fiksyen', rackCode: 'R12', shelfCode: 'S3'));
      final cat = await dao.saveCategory('lib-a', const CategoryInput(name: 'Kesusasteraan Melayu Klasik'));
      return dao.createBook(
          'lib-a',
          BookInput(
              title: 'Hikayat Hang Tuah: Edisi Lengkap Dengan Anotasi Dan Glosari Yang Sangat Panjang',
              author: 'Kassim Ahmad dan rakan-rakan penyunting',
              isbn: '9789836261234',
              categoryId: cat),
          copies: [
            CopyInput(barcode: 'LIBA-7F3K-000001', accessionNumber: 'P2026-000123', locationId: loc, status: CopyStatus.inProcessing),
            const CopyInput(barcode: 'LIBA-7F3K-000002', status: CopyStatus.damaged),
          ]);
    });
    await tester.runAsync(() => h.db.customStatement("UPDATE local_books SET sync_state = 'conflict'"));
    tester.view.physicalSize = const Size(1080, 2220);
    tester.view.devicePixelRatio = 3.0; // 360 x 740 dp
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides: h.overrides, child: const _App()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library.LIBA')));
    await tester.pumpAndSettle();
    final c = ProviderScope.containerOf(tester.element(find.byType(_App)));
    for (final route in [Routes.dashboard, Routes.books, Routes.book(bookId!), Routes.bookNew, Routes.copies,
        Routes.categories, Routes.locations, Routes.barcode, Routes.copyNew(bookId)]) {
      await go(tester, c, route);
      expect(tester.takeException(), isNull, reason: 'overflow/exception on $route');
    }
    await finish(tester);
  });
}
