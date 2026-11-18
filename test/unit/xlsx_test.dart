import 'dart:typed_data';

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/core/xlsx/xlsx_reader.dart';
import 'package:smartlibrary_manager/core/xlsx/xlsx_writer.dart';

void main() {
  test('column names', () {
    expect(XlsxWriter.colName(0), 'A');
    expect(XlsxWriter.colName(25), 'Z');
    expect(XlsxWriter.colName(26), 'AA');
    expect(XlsxWriter.colName(701), 'ZZ');
  });

  test('write → read roundtrip keeps types (string, int, double, bool, date)', () {
    final w = XlsxWriter()
      ..addSheet(XlsxSheet('01_Data', header: ['Tajuk', 'Tahun', 'Kos', 'Aktif', 'Tarikh'], rows: [
        ['Hikayat <Hang> Tuah & "Jebat"', 1997, 25.9, true, DateTime(2026, 3, 7)],
        ['Kosong', null, null, false, null],
      ]));
    final tables = XlsxReader.read(w.build());
    final t = tables.single;
    expect(t.name, '01_Data');
    expect(t.rows[0], ['Tajuk', 'Tahun', 'Kos', 'Aktif', 'Tarikh']);
    expect(t.rows[1], ['Hikayat <Hang> Tuah & "Jebat"', 1997, 25.9, true, DateTime(2026, 3, 7)]);
    expect(t.rows[2], ['Kosong', null, null, false]);
  });

  test('is a real xlsx with frozen header, auto filter and column widths', () {
    final w = XlsxWriter()..addSheet(XlsxSheet('S', header: ['A', 'B'], rows: [
          ['panjang sekali nilai ini', 1]
        ]));
    final bytes = w.build();
    expect(bytes.sublist(0, 2), [0x50, 0x4B], reason: 'zip container');
    final a = ZipDecoder().decodeBytes(bytes);
    final sheet = utf8.decode(a.find('xl/worksheets/sheet1.xml')!.content);
    expect(sheet, contains('state="frozen"'));
    expect(sheet, contains('<autoFilter ref="A1:B2"/>'));
    expect(sheet, contains('customWidth="1"'));
    expect(utf8.decode(a.find('xl/workbook.xml')!.content), contains('_xlnm._FilterDatabase'));
    expect(a.find('[Content_Types].xml'), isNotNull);
  });

  test('preamble rows shift the header (and the frozen pane / filter)', () {
    final s = XlsxSheet('S', header: ['A'], rows: [
      ['x']
    ])
      ..preamble.addAll([
        ['Laporan'],
        ['Tarikh: 18/11/2026'],
      ]);
    final a = ZipDecoder().decodeBytes((XlsxWriter()..addSheet(s)).build());
    final sheet = utf8.decode(a.find('xl/worksheets/sheet1.xml')!.content);
    expect(sheet, contains('ySplit="3"'));
    expect(sheet, contains('<autoFilter ref="A3:A4"/>'));
  });

  test('reads shared strings and Excel-style date formats (file made by Excel)', () {
    final a = Archive();
    void add(String n, String x) => a.addFile(ArchiveFile.bytes(n, utf8.encode(x)));
    add('xl/workbook.xml',
        '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Buku" sheetId="1" r:id="rId1"/></sheets></workbook>');
    add('xl/_rels/workbook.xml.rels',
        '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>');
    add('xl/sharedStrings.xml', '<sst><si><t>Tajuk</t></si><si><r><t>Asas </t></r><r><t>Fizik</t></r></si></sst>');
    add('xl/styles.xml', '<styleSheet><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>');
    add('xl/worksheets/sheet1.xml',
        '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row><row r="3"><c r="A3" t="s"><v>1</v></c><c r="C3" s="1"><v>46088</v></c></row></sheetData></worksheet>');
    final t = XlsxReader.read(ZipEncoder().encodeBytes(a)).single;
    expect(t.rows[0], ['Tajuk']);
    expect(t.rows[1], isEmpty);
    expect(t.rows[2], ['Asas Fizik', null, DateTime(2026, 3, 7)]);
  });

  test('rejects non-xlsx input with a clear message', () {
    expect(() => XlsxReader.read(utf8.encode('Tajuk,ISBN\nA,1')), throwsA(isA<XlsxFormatException>()));
    expect(() => XlsxReader.read(Uint8List.fromList([0x50, 0x4B, 1, 2, 3])), throwsA(isA<XlsxFormatException>()));
  });
}
