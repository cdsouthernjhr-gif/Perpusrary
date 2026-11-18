import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:smartlibrary_manager/app/router/app_router.dart';
import 'package:smartlibrary_manager/app/router/routes.dart';
import 'package:smartlibrary_manager/app/theme/app_theme.dart';

import '../helpers/fakes.dart';

class _App extends ConsumerWidget {
  const _App();
  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      MaterialApp.router(theme: AppTheme.light(), routerConfig: ref.watch(appRouterProvider));
}

void main() {
  late TestHarness h;
  setUp(() => h = TestHarness());

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides: h.overrides, child: const _App()));
    await tester.pumpAndSettle();
  }

  /// Drift stream queries schedule a zero-length timer when cancelled, and
  /// the database must be closed inside the test zone.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(() => h.db.close());
  }

  testWidgets('switcher lists only server-confirmed libraries with counts and roles', (tester) async {
    await pumpApp(tester);
    expect(find.text('Pilih Perpustakaan'), findsOneWidget);
    expect(find.byKey(const Key('library.LIBA')), findsOneWidget);
    expect(find.byKey(const Key('library.LIBB')), findsOneWidget);
    expect(find.textContaining('11 judul', findRichText: true), findsOneWidget);
    expect(find.textContaining('Pentadbir Perpustakaan'), findsOneWidget);
    expect(find.byKey(const Key('switcher.add')), findsNothing, reason: 'not a super admin');
    await finish(tester);
  });

  testWidgets('selecting a library shows its dashboard; switching shows the other library', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('library.LIBA')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dashboard.libraryName')), findsOneWidget);
    expect(find.text('Perpustakaan Sekolah A'), findsWidgets);
    expect(find.text('110'), findsOneWidget, reason: 'copy count of library A');
    expect(find.text('Pengguna aktif'), findsOneWidget, reason: 'admin-only tile in A');

    await tester.tap(find.byKey(const Key('dashboard.switch')));
    await tester.pumpAndSettle();
    expect(find.text('Pilih Perpustakaan'), findsOneWidget);

    await tester.tap(find.byKey(const Key('library.LIBB')));
    await tester.pumpAndSettle();
    expect(find.text('Perpustakaan Daerah B'), findsWidgets);
    expect(find.text('220'), findsOneWidget, reason: 'copy count of library B');
    expect(find.text('110'), findsNothing, reason: 'no stale data from library A');
    expect(find.text('Pengguna aktif'), findsNothing, reason: 'staff in B');
    expect(h.dashboard.requested, ['lib-a', 'lib-b']);
    await finish(tester);
  });

  testWidgets('library-scoped route without active library redirects to switcher', (tester) async {
    await pumpApp(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(_App)));
    container.read(appRouterProvider).go(Routes.members);
    await tester.pumpAndSettle();
    expect(find.text('Pilih Perpustakaan'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('super admin sees the add-library button even with no libraries', (tester) async {
    h.libraries.superAdmin = true;
    h.libraries.serverLibraries = [];
    await pumpApp(tester);
    expect(find.byKey(const Key('switcher.add')), findsOneWidget);
    expect(find.textContaining('Belum ada perpustakaan'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('sync indicator shows synced state on the dashboard', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('library.LIBA')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sync.synced')), findsOneWidget);
    await finish(tester);
  });
}
