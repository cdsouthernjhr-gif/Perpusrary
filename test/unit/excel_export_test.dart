import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/core/xlsx/xlsx_reader.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/data/repositories/library_repositories.dart';
import 'package:smartlibrary_manager/features/excel_export/application/excel_export.dart';
import 'package:smartlibrary_manager/shared/models/catalog_models.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('8 worksheets with correct counts; only the selected library', () async {
    final dao = CatalogDao(db);
    final cat = await dao.saveCategory('A', const CategoryInput(name: 'Sejarah'));
    final loc = await dao.saveLocation('A', const LocationInput(building: 'Blok A', rackCode: 'R1'));
    await dao.createBook('A', BookInput(title: 'Sejarah Melayu', isbn: '9789830000099', categoryId: cat), copies: [
      CopyInput(barcode: 'A1', locationId: loc, acquisitionCostCents: 2590, acquisitionDate: DateTime(2026, 3, 7)),
      CopyInput(barcode: 'A2', locationId: loc, status: CopyStatus.damaged),
    ]);
    await dao.createBook('A', const BookInput(title: 'Asas Fizik'));
    await dao.createBook('B', const BookInput(title: 'RAHSIA B'), copies: const [CopyInput(barcode: 'B1')]);

    final bytes = await ExcelExporter(db).build(
      libraryId: 'A',
      libraryName: 'Perpustakaan Sekolah A',
      libraryCode: 'LIBA',
      exportedAt: DateTime(2026, 11, 18, 10),
      exportedBy: 'Pentadbir A',
      activity: [ActivityEntry(action: 'create', createdAt: DateTime(2026, 11, 18), entityType: 'books', userId: 'u1')],
      userNames: const {'u1': 'Siti'},
    );
    final t = {for (final s in XlsxReader.read(bytes)) s.name: s.rows};
    expect(t.keys.toList(), ExcelExporter.sheetNames);

    List<List<Object?>> data(String sheet) => t[sheet]!.skip(1).where((r) => r.isNotEmpty).toList();
    expect(data('02_Katalog_Buku').length, 2);
    expect(data('03_Naskhah').length, 2);
    expect(data('04_Kategori').single, ['Sejarah', null, null, 1, 2]);
    expect(data('05_Lokasi_Rak').single.last, 2);
    expect(data('06_Kemasukan').length, 2, reason: 'two acquisitions');
    expect(data('07_Barcode').map((r) => r.first), ['A1', 'A2']);
    expect(data('08_Aktiviti').single.sublist(1, 3), ['Siti', 'Tambah']);

    final summary = t['01_Ringkasan']!;
    expect(summary[1], ['Nama perpustakaan', 'Perpustakaan Sekolah A']);
    expect(summary[3], ['Tarikh eksport', DateTime(2026, 11, 18, 10)]);
    Object? value(String label) => summary.firstWhere((r) => r.isNotEmpty && r.first == label)[1];
    expect(value('Jumlah judul'), 2);
    expect(value('Jumlah naskhah'), 2);
    expect(value('Naskhah dalam stok (tersedia + dalam proses)'), 1);
    expect(value('Nilai perolehan direkod (RM)'), 25.9);

    final all = t.values.expand((rows) => rows).expand((r) => r).whereType<String>();
    expect(all.any((s) => s.contains('RAHSIA B') || s == 'B1'), isFalse, reason: 'library B never exported');
  });

  test('activity sheet explains when the server log is unavailable (offline)', () async {
    final bytes = await ExcelExporter(db).build(
        libraryId: 'A', libraryName: 'X', libraryCode: 'X1', exportedAt: DateTime(2026), activity: null);
    final act = XlsxReader.read(bytes).last;
    expect(act.rows.first.first, contains('tidak tersedia'));
  });

  test('file name contains the library code and timestamp', () {
    expect(ExcelExporter.fileName('LIBA', DateTime(2026, 11, 18, 9, 5)), 'SmartLibrary_LIBA_20261118_0905.xlsx');
  });
}
