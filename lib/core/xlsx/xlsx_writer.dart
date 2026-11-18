import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Cell value for [XlsxSheet]. Supported: String, int, double, bool,
/// DateTime (written as a real Excel date with dd/mm/yyyy[ hh:mm] format),
/// null (empty).
typedef XlsxRow = List<Object?>;

class XlsxSheet {
  XlsxSheet(this.name, {this.header, List<XlsxRow>? rows, this.freezeHeader = true, this.autoFilter = true})
      : rows = rows ?? [];

  /// Worksheet name (max 31 chars, no []:*?/\).
  final String name;

  /// Bold, shaded header row (row 1). When null there is no header styling.
  final List<String>? header;
  final List<XlsxRow> rows;
  final bool freezeHeader;
  final bool autoFilter;

  /// Rows written above the header (e.g. title, export date). When present,
  /// the header row moves below them.
  final List<XlsxRow> preamble = [];
}

/// Minimal, dependency-light XLSX (Office Open XML SpreadsheetML) writer.
///
/// Produces a real .xlsx (not CSV) that opens in Excel, LibreOffice and
/// Google Sheets, with: inline strings, numbers, booleans, true date cells,
/// bold header, frozen header row, auto filter and content-based column
/// widths.
class XlsxWriter {
  XlsxWriter({this.creator = 'SmartLibrary Manager'});

  final String creator;
  final _sheets = <XlsxSheet>[];

  XlsxSheet addSheet(XlsxSheet s) {
    if (s.name.length > 31 || RegExp(r'[\[\]:*?/\\]').hasMatch(s.name)) {
      throw ArgumentError('Invalid sheet name: ${s.name}');
    }
    _sheets.add(s);
    return s;
  }

  // Style ids (see _styles): 0 default, 1 header, 2 date, 3 datetime, 4 bold, 5 money
  static const _sHeader = 1;
  static const _sDate = 2;
  static const _sDateTime = 3;
  static const _sBold = 4;

  Uint8List build() {
    if (_sheets.isEmpty) throw StateError('Workbook needs at least one sheet');
    final a = Archive();
    void add(String name, String xml) => a.addFile(ArchiveFile.bytes(name, utf8.encode(xml)));

    add('[Content_Types].xml', _contentTypes());
    add('_rels/.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>''');
    add('docProps/core.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>${_esc(creator)}</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">${DateTime.now().toUtc().toIso8601String().split('.').first}Z</dcterms:created></cp:coreProperties>''');
    add('xl/workbook.xml', _workbook());
    add('xl/_rels/workbook.xml.rels', _workbookRels());
    add('xl/styles.xml', _styles);
    for (var i = 0; i < _sheets.length; i++) {
      add('xl/worksheets/sheet${i + 1}.xml', _sheet(_sheets[i]));
    }
    return ZipEncoder().encodeBytes(a);
  }

  String _contentTypes() {
    final sheets = [
      for (var i = 1; i <= _sheets.length; i++)
        '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
    ].join();
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>$sheets</Types>''';
  }

  String _workbook() {
    final sheets = [
      for (var i = 0; i < _sheets.length; i++)
        '<sheet name="${_esc(_sheets[i].name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>',
    ].join();
    final names = [
      for (var i = 0; i < _sheets.length; i++)
        if (_filterRef(_sheets[i]) != null)
          '<definedName name="_xlnm._FilterDatabase" localSheetId="$i" hidden="1">\'${_sheets[i].name.replaceAll("'", "''")}\'!${_absRef(_filterRef(_sheets[i])!)}</definedName>',
    ].join();
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>$sheets</sheets>${names.isEmpty ? '' : '<definedNames>$names</definedNames>'}</workbook>''';
  }

  String _workbookRels() {
    final rels = [
      for (var i = 1; i <= _sheets.length; i++)
        '<Relationship Id="rId$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet$i.xml"/>',
    ].join();
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$rels<Relationship Id="rId${_sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>''';
  }

  static const _styles = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="3"><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/><numFmt numFmtId="165" formatCode="dd/mm/yyyy hh:mm"/><numFmt numFmtId="166" formatCode="#,##0.00"/></numFmts><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFD9E7EE"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border/><border><bottom style="thin"><color rgb="FF1B5E7A"/></bottom></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>''';

  int get _headerRowIndex => 0; // relative to after-preamble

  int _headerRow(XlsxSheet s) => s.preamble.length + 1 + _headerRowIndex; // 1-based

  String? _filterRef(XlsxSheet s) {
    if (!s.autoFilter || s.header == null) return null;
    final h = _headerRow(s);
    return '${colName(0)}$h:${colName(s.header!.length - 1)}${h + s.rows.length}';
  }

  static String _absRef(String ref) => ref.split(':').map((r) {
        final m = RegExp(r'^([A-Z]+)(\d+)$').firstMatch(r)!;
        return '\$${m[1]}\$${m[2]}';
      }).join(':');

  String _sheet(XlsxSheet s) {
    final rowsXml = StringBuffer();
    final widths = <int, int>{};
    var r = 0;
    void writeRow(List<Object?> cells, {int? style}) {
      r++;
      rowsXml.write('<row r="$r">');
      for (var c = 0; c < cells.length; c++) {
        final v = cells[c];
        if (v == null) continue;
        final ref = '${colName(c)}$r';
        final (xml, len) = _cell(ref, v, style);
        rowsXml.write(xml);
        widths[c] = (widths[c] ?? 0) < len ? len : widths[c]!;
      }
      rowsXml.write('</row>');
    }

    for (final p in s.preamble) {
      writeRow(p, style: r == 0 ? _sBold : null);
    }
    if (s.header != null) writeRow(s.header!, style: _sHeader);
    for (final row in s.rows) {
      writeRow(row);
    }

    final cols = StringBuffer();
    if (widths.isNotEmpty) {
      cols.write('<cols>');
      for (final e in (widths.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) {
        final w = (e.value + 2).clamp(8, 60);
        cols.write('<col min="${e.key + 1}" max="${e.key + 1}" width="$w" customWidth="1"/>');
      }
      cols.write('</cols>');
    }
    final h = _headerRow(s);
    final views = s.freezeHeader && s.header != null
        ? '<sheetViews><sheetView workbookViewId="0"><pane ySplit="$h" topLeftCell="A${h + 1}" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A${h + 1}" sqref="A${h + 1}"/></sheetView></sheetViews>'
        : '<sheetViews><sheetView workbookViewId="0"/></sheetViews>';
    final filter = _filterRef(s);
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">$views<sheetFormatPr defaultRowHeight="15"/>$cols<sheetData>$rowsXml</sheetData>${filter == null ? '' : '<autoFilter ref="$filter"/>'}</worksheet>''';
  }

  (String, int) _cell(String ref, Object v, int? style) {
    final st = style == null ? '' : ' s="$style"';
    if (v is bool) return ('<c r="$ref" t="b"$st><v>${v ? 1 : 0}</v></c>', 5);
    if (v is int) return ('<c r="$ref"$st><v>$v</v></c>', '$v'.length);
    if (v is double) {
      final s = style ?? 5;
      return ('<c r="$ref" s="$s"><v>$v</v></c>', v.toStringAsFixed(2).length + 2);
    }
    if (v is DateTime) {
      final hasTime = v.hour != 0 || v.minute != 0;
      return ('<c r="$ref" s="${style ?? (hasTime ? _sDateTime : _sDate)}"><v>${excelSerial(v)}</v></c>', hasTime ? 16 : 10);
    }
    final text = '$v';
    return ('<c r="$ref" t="inlineStr"$st><is><t xml:space="preserve">${_esc(text)}</t></is></c>', text.length);
  }

  /// Excel serial date (1900 system).
  static double excelSerial(DateTime d) {
    final local = DateTime(d.year, d.month, d.day, d.hour, d.minute, d.second);
    // Whole seconds, 10 decimals: exact to the second when read back.
    final days = local.difference(DateTime(1899, 12, 30)).inSeconds / 86400;
    return double.parse(days.toStringAsFixed(10));
  }

  static String colName(int index) {
    var n = index + 1;
    var s = '';
    while (n > 0) {
      final m = (n - 1) % 26;
      s = String.fromCharCode(65 + m) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      // XML 1.0 forbids most control characters.
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
}
