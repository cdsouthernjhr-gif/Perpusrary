import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:smartlibrary_manager/core/xlsx/xlsx_writer.dart';
import 'package:smartlibrary_manager/data/local/dao/catalog_dao.dart';
import 'package:smartlibrary_manager/data/local/database/app_database.dart';
import 'package:smartlibrary_manager/features/excel_export/application/excel_export.dart';
import 'package:smartlibrary_manager/features/excel_import/application/excel_import.dart';
import 'package:smartlibrary_manager/shared/models/catalog_models.dart';

/// Writes a sample workbook to $XLSX_OUT (when set) so it can be checked with
/// external tools (openpyxl / LibreOffice) — see docs/testing.md.
void main() {
  final out = Platform.environment['XLSX_OUT'];
  test('write sample workbook for external validation', () async {
    final s1 = XlsxSheet('01_Ringkasan', header: ['Perkara', 'Nilai'], rows: [
      ['Jumlah judul', 12],
      ['Nilai', 1234.5],
    ])
      ..preamble.addAll([
        ['Perpustakaan Sekolah A'],
        ['Tarikh eksport', DateTime(2026, 11, 18, 9, 30)],
      ]);
    final s2 = XlsxSheet('02_Katalog_Buku', header: ['Tajuk', 'Tahun', 'Tarikh'], rows: [
      ['Hikayat Hang Tuah & <Jebat>', 1997, DateTime(2026, 3, 7)],
    ]);
    await File(out!).writeAsBytes((XlsxWriter()..addSheet(s1)..addSheet(s2)).build());
  }, skip: out == null ? 'XLSX_OUT not set' : null);

  test('write full export + import template for external validation', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dao = CatalogDao(db);
    final loc = await dao.saveLocation('A', const LocationInput(building: 'Blok A', rackCode: 'R1'));
    await dao.createBook('A', const BookInput(title: 'Hikayat Hang Tuah', isbn: '9789836261234'), copies: [
      CopyInput(barcode: 'A1', locationId: loc, acquisitionCostCents: 2590, acquisitionDate: DateTime(2026, 3, 7)),
    ]);
    final bytes = await ExcelExporter(db).build(
        libraryId: 'A', libraryName: 'Perpustakaan Sekolah A', libraryCode: 'LIBA', exportedAt: DateTime(2026, 11, 18, 10));
    await File(out!.replaceAll('.xlsx', '_export.xlsx')).writeAsBytes(bytes);
    await File(out.replaceAll('.xlsx', '_template.xlsx')).writeAsBytes(buildImportTemplate());
    await db.close();
  }, skip: out == null ? 'XLSX_OUT not set' : null);

  final input = Platform.environment['XLSX_IN'];
  test('import a template re-saved by LibreOffice/Excel', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final plan = await ImportPlanner(db, 'A').plan(await File(input!).readAsBytes(), 'lo.xlsx', const ImportOptions());
    expect(plan.errorRows, 0, reason: plan.rows.expand((r) => r.errors).join('; '));
    expect(plan.newCopies, 2);
    expect(plan.rows.first.copy!.acquisitionDate, DateTime(2026, 1, 15));
    expect(plan.rows.first.copy!.acquisitionCostCents, 3500);
    await db.close();
  }, skip: input == null ? 'XLSX_IN not set' : null);
}
