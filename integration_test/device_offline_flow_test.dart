// ON-DEVICE integration test (Android phone/emulator). NOT run in CI: needs a
// device. Run from the project root with a phone connected:
//
//   flutter test integration_test/device_offline_flow_test.dart
//
// Uses the real on-device SQLite file (drift_flutter), the real router and
// screens, and an in-memory fake server (no Supabase project needed).
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:smartlibrary_manager/app/app.dart';
import 'package:smartlibrary_manager/app/router/app_router.dart';
import 'package:smartlibrary_manager/app/router/routes.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';

import '../test/helpers/fakes.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<ProviderContainer> launch(WidgetTester tester, TestHarness h) async {
    await tester.pumpWidget(ProviderScope(overrides: h.overrides, child: const SmartLibraryApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library.LIBA')));
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(SmartLibraryApp)));
  }

  testWidgets('register a book offline, restart the app, data is still there, then sync', (tester) async {
    // 1st "app run": offline registration into the on-device database file.
    var db = AppDatabase.open();
    await db.delete(db.localBooks).go(); // clean slate for the test
    await db.delete(db.localBookCopies).go();
    await db.delete(db.syncQueue).go();
    var h = TestHarness(database: db, online: false);
    var c = await launch(tester, h);
    c.read(appRouterProvider).go(Routes.bookNew);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('book.title')), 'Ujian Peranti');
    await tester.scrollUntilVisible(find.byKey(const Key('book.save')), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('book.save')));
    await tester.pumpAndSettle();
    expect(find.text('Menunggu sync ke pelayan'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await db.close();

    // 2nd "app run": same file, now online.
    db = AppDatabase.open();
    expect((await db.select(db.localBooks).get()).single.title, 'Ujian Peranti');
    expect((await db.select(db.syncQueue).get()).length, 2, reason: 'book + generated copy still queued');
    h = TestHarness(database: db, autoSync: true);
    c = await launch(tester, h);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(h.sync.pushed.map((o) => o['entity_type']).toList(), ['books', 'book_copies']);
    expect(await db.select(db.syncQueue).get(), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}
