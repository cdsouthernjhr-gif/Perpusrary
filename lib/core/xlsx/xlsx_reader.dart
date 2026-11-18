import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

class XlsxFormatException implements Exception {
  const XlsxFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One worksheet as a dense grid of cell values: String, num, bool or null.
/// Dates are numbers (Excel serials) unless the cell has a date style, in
/// which case they are returned as DateTime.
class XlsxTable {
  const XlsxTable(this.name, this.rows);
  final String name;
  final List<List<Object?>> rows;
}

/// Reads .xlsx files produced by Excel, LibreOffice, Google Sheets or
/// [XlsxWriter]. Supports shared strings, inline strings, numbers, booleans
/// and date-formatted cells. Formulas yield their cached value.
abstract final class XlsxReader {
  static const maxBytes = 30 * 1024 * 1024;

  static List<XlsxTable> read(Uint8List bytes) {
    if (bytes.length > maxBytes) throw const XlsxFormatException('Fail terlalu besar (maksimum 30 MB).');
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      throw const XlsxFormatException('Bukan fail .xlsx yang sah (format CSV/XLS lama tidak disokong).');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const XlsxFormatException('Fail .xlsx rosak atau tidak dapat dibaca.');
    }
    String? text(String name) {
      final f = archive.find(name);
      return f == null ? null : utf8.decode(f.content, allowMalformed: true);
    }

    final workbookXml = text('xl/workbook.xml');
    if (workbookXml == null) throw const XlsxFormatException('Fail ini bukan buku kerja Excel.');
    final relsXml = text('xl/_rels/workbook.xml.rels') ?? '';
    final rels = <String, String>{
      for (final r in XmlDocument.parse(relsXml).findAllElements('Relationship'))
        r.getAttribute('Id')!: r.getAttribute('Target')!,
    };

    final shared = <String>[];
    final ss = text('xl/sharedStrings.xml');
    if (ss != null) {
      for (final si in XmlDocument.parse(ss).findAllElements('si')) {
        shared.add(si.findAllElements('t').map((t) => t.innerText).join());
      }
    }
    final dateStyles = _dateStyleIndexes(text('xl/styles.xml'));

    final out = <XlsxTable>[];
    for (final sheet in XmlDocument.parse(workbookXml).findAllElements('sheet')) {
      final rid = sheet.getAttribute('r:id') ??
          sheet.attributes.where((a) => a.name.local == 'id').map((a) => a.value).firstOrNull;
      var target = rels[rid] ?? '';
      target = target.startsWith('/') ? target.substring(1) : 'xl/$target';
      final xml = text(target);
      if (xml == null) continue;
      out.add(XlsxTable(sheet.getAttribute('name') ?? '', _rows(xml, shared, dateStyles)));
    }
    if (out.isEmpty) throw const XlsxFormatException('Tiada worksheet dijumpai.');
    return out;
  }

  static Set<int> _dateStyleIndexes(String? stylesXml) {
    if (stylesXml == null) return const {};
    final doc = XmlDocument.parse(stylesXml);
    final custom = <int, String>{
      for (final f in doc.findAllElements('numFmt'))
        int.parse(f.getAttribute('numFmtId')!): f.getAttribute('formatCode') ?? '',
    };
    bool isDateFmt(int id) {
      if ((id >= 14 && id <= 22) || (id >= 45 && id <= 47)) return true;
      final code = custom[id];
      if (code == null) return false;
      final stripped = code.replaceAll(RegExp(r'"[^"]*"|\[[^\]]*\]'), '').toLowerCase();
      return RegExp('[dmy]').hasMatch(stripped) && !stripped.contains('#') && !stripped.contains('0.0');
    }

    final xfs = doc.findAllElements('cellXfs').expand((e) => e.findElements('xf')).toList();
    return {
      for (var i = 0; i < xfs.length; i++)
        if (isDateFmt(int.tryParse(xfs[i].getAttribute('numFmtId') ?? '0') ?? 0)) i,
    };
  }

  static int _colIndex(String ref) {
    final letters = RegExp(r'^[A-Z]+').stringMatch(ref) ?? 'A';
    var n = 0;
    for (final c in letters.codeUnits) {
      n = n * 26 + (c - 64);
    }
    return n - 1;
  }

  static DateTime fromSerial(num serial) {
    final ms = (serial * 86400).round() * 1000; // to the second
    final d = DateTime.utc(1899, 12, 30).add(Duration(milliseconds: ms));
    return DateTime(d.year, d.month, d.day, d.hour, d.minute, d.second);
  }

  static List<List<Object?>> _rows(String xml, List<String> shared, Set<int> dateStyles) {
    final rows = <List<Object?>>[];
    for (final row in XmlDocument.parse(xml).findAllElements('row')) {
      final rIndex = (int.tryParse(row.getAttribute('r') ?? '') ?? rows.length + 1) - 1;
      while (rows.length < rIndex) {
        rows.add([]);
      }
      final cells = <Object?>[];
      var next = 0;
      for (final c in row.findElements('c')) {
        final ref = c.getAttribute('r');
        final col = ref == null ? next : _colIndex(ref);
        next = col + 1;
        final type = c.getAttribute('t');
        final style = int.tryParse(c.getAttribute('s') ?? '');
        final raw = c.getElement('v')?.innerText;
        Object? value;
        switch (type) {
          case 's':
            final i = int.tryParse(raw ?? '');
            value = (i != null && i < shared.length) ? shared[i] : null;
          case 'inlineStr':
            value = c.findAllElements('t').map((t) => t.innerText).join();
          case 'str':
            value = raw;
          case 'b':
            value = raw == '1';
          case 'e':
            value = null;
          default:
            final n = raw == null ? null : num.tryParse(raw);
            value = (n != null && style != null && dateStyles.contains(style)) ? fromSerial(n) : n;
        }
        while (cells.length < col) {
          cells.add(null);
        }
        cells.add(value);
      }
      rows.add(cells);
    }
    return rows;
  }
}
