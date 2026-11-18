import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:smartlibrary_manager/app/router/app_router.dart';
import 'package:smartlibrary_manager/app/router/routes.dart';
import 'package:smartlibrary_manager/app/theme/app_theme.dart';
import 'package:smartlibrary_manager/core/xlsx/xlsx_reader.dart';
import 'package:smartlibrary_manager/core/xlsx/xlsx_writer.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
import 'package:smartlibrary_manager/data/local/dao/local_dao.dart';
import 'package:smartlibrary_manager/features/backup/application/backup_service.dart';
import 'package:smartlibrary_manager/features/excel_export/application/excel_export.dart';
import 'package:smartlibrary_manager/features/excel_import/application/excel_import.dart';
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

  Future<void> settleImpl(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pumpAndSettle();
    }
  }

  Future<ProviderContainer> start(WidgetTester tester, String route,
      {Size size = const Size(1080, 2400), double dpr = 2.5}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides: h.overrides, child: const _App()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library.LIBA')));
    await tester.pumpAndSettle();
    final c = ProviderScope.containerOf(tester.element(find.byType(_App)));
    c.read(appRouterProvider).go(route);
    await settleImpl(tester);
    return c;
  }

  Future<void> tap(WidgetTester tester, Key key) async {
    await tester.scrollUntilVisible(find.byKey(key), 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.byKey(key)); // built (cache extent) is not the same as on screen
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await settleImpl(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(() => h.db.close());
  }

  testWidgets('import: template → preview → import → result, then synced', (tester) async {
    h = TestHarness();
    h.files.nextPick = ('templat.xlsx', buildImportTemplate());
    await start(tester, Routes.importExcel);
    await tap(tester, const Key('import.pick'));
    expect(find.byKey(const Key('import.summary')), findsOneWidget);
    expect(find.text('Sah: 2'), findsOneWidget);
    expect(find.text('Judul baharu: 1'), findsOneWidget);
    expect(find.text('Naskhah baharu: 2'), findsOneWidget);

    await tap(tester, const Key('import.run'));
    await tester.tap(find.byKey(const Key('import.confirm')));
    await settleImpl(tester);
    expect(find.byKey(const Key('import.result')), findsOneWidget);
    expect((await tester.runAsync(() => h.db.select(h.db.localBookCopies).get()))!.length, 2);
    expect(h.importJobs.events, ['start:templat.xlsx:2', 'finish:completed:3:0']);
    expect(h.sync.pushed.map((o) => o['entity_type']).toSet(), {'categories', 'locations', 'books', 'book_copies'});
    await finish(tester);
  });

  testWidgets('import: invalid rows are listed and excluded', (tester) async {
    h = TestHarness();
    h.files.nextPick = (
      'buruk.xlsx',
      (XlsxWriter()
            ..addSheet(XlsxSheet('Buku', header: ['Tajuk', 'Tahun', 'Barcode'], rows: [
              ['Baik', 2020, 'K1'],
              [null, 2020, 'K2'],
              ['Tahun Salah', 'abc', 'K3'],
            ])))
          .build()
    );
    await start(tester, Routes.importExcel);
    await tap(tester, const Key('import.pick'));
    expect(find.text('Ralat: 2'), findsOneWidget);
    expect(find.byKey(const Key('import.row.3')), findsOneWidget);
    expect(find.textContaining('Tajuk diperlukan'), findsOneWidget);
    expect(find.text('Import 1 baris'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('import is not available to staff', (tester) async {
    h = TestHarness(server: [libA(role: LibraryRole.staff)]);
    await start(tester, Routes.importExcel);
    expect(find.textContaining('memerlukan peranan Editor'), findsOneWidget);
    expect(find.byKey(const Key('import.pick')), findsNothing);
    await finish(tester);
  });

  testWidgets('export: real .xlsx with 8 worksheets saved via the file picker', (tester) async {
    h = TestHarness(server: [libA(role: LibraryRole.viewer)]);
    await tester.runAsync(() => CatalogDao(h.db).createBook('lib-a', const BookInput(title: 'Buku Eksport'),
        copies: const [CopyInput(barcode: 'E1')]));
    await start(tester, Routes.exportExcel);
    await tap(tester, const Key('export.run'));
    expect(find.byKey(const Key('export.done')), findsOneWidget);
    final file = h.files.saved.entries.single;
    expect(file.key, startsWith('SmartLibrary_LIBA_'));
    final sheets = XlsxReader.read(file.value);
    expect(sheets.map((s) => s.name), ExcelExporter.sheetNames);
    expect(sheets[1].rows[1][1], 'Buku Eksport');
    await finish(tester);
  });

  testWidgets('backup: create, refuse another library\'s file, restore with code confirmation', (tester) async {
    h = TestHarness();
    await tester.runAsync(() => KeyValueDao(h.db).put(LocalKeys.deviceId, '3f2a9c10-0000-4000-8000-000000000001'));
    await start(tester, Routes.backup);
    await tap(tester, const Key('backup.now'));
    expect(h.backups.records.single.status, 'completed');

    // A backup of another library is refused before anything is sent.
    final foreign = BackupService.encode({
      'format': 'smartlibrary-backup',
      'version': 1,
      'library': {'id': 'lib-b', 'code': 'LIBB'},
      'data': {'categories': [], 'locations': [], 'books': [], 'book_copies': []},
    });
    h.files.nextPick = ('lain.json.gz', foreign);
    await tap(tester, const Key('backup.restoreFile'));
    expect(find.textContaining('milik perpustakaan lain'), findsOneWidget);
    expect(h.backups.restores, isEmpty);

    // Restore our own backup: confirm stays disabled until the code is typed.
    final rec = h.backups.records.single;
    await tap(tester, Key('backup.restore.${rec.id}'));
    expect(find.byKey(const Key('restore.dialog')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('restore.confirm'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('restore.code')), 'liba');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore.confirm')));
    await settleImpl(tester);
    expect(h.backups.restores, [('lib-a', false)]);
    expect(h.backups.records.where((r) => r.backupType == 'pre_restore' && r.status == 'completed'), hasLength(1),
        reason: 'automatic backup of the current state before restoring');
    await finish(tester);
  });

  testWidgets('backup is admin-only', (tester) async {
    h = TestHarness(server: [libA(role: LibraryRole.editor)]);
    await start(tester, Routes.backup);
    expect(find.textContaining('Hanya Pentadbir Perpustakaan'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('small phone (360dp): import preview, export, backup, reports render without overflow', (tester) async {
    h = TestHarness();
    h.files.nextPick = ('templat-dengan-nama-yang-sangat-panjang-sekali.xlsx', buildImportTemplate());
    final c = await start(tester, Routes.importExcel, size: const Size(1080, 2220), dpr: 3.0);
    await tap(tester, const Key('import.pick'));
    expect(tester.takeException(), isNull);
    for (final r in [Routes.exportExcel, Routes.backup, Routes.reports]) {
      c.read(appRouterProvider).go(r);
      await settleImpl(tester);
      expect(tester.takeException(), isNull, reason: r);
    }
    await finish(tester);
  });
}

