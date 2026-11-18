import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class LabelData {
  const LabelData({required this.barcode, required this.title, this.accessionNumber, this.callNumber});
  final String barcode;
  final String title;
  final String? accessionNumber;
  final String? callNumber;
}

/// A4 sheet of barcode labels (3 × 8 = 24 per page, ~70 × 37 mm — common
/// sticker sheets). Each label: library name, short title, Code 128 barcode
/// with human-readable text, accession / call number.
Future<Uint8List> buildLabelsPdf({
  required String libraryName,
  required List<LabelData> labels,
  int columns = 3,
  int rows = 8,
}) async {
  final doc = pw.Document(title: 'Label barcode – $libraryName', creator: 'SmartLibrary Manager');
  final perPage = columns * rows;
  String short(String s, int n) => s.length <= n ? s : '${s.substring(0, n - 1)}…';

  for (var start = 0; start < labels.length; start += perPage) {
    final page = labels.sublist(start, (start + perPage).clamp(0, labels.length));
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.symmetric(horizontal: 6 * PdfPageFormat.mm, vertical: 10 * PdfPageFormat.mm),
      build: (ctx) => pw.GridView(
        crossAxisCount: columns,
        childAspectRatio: 37 / 66,
        children: [
          for (final l in page)
            pw.Container(
              padding: const pw.EdgeInsets.all(4),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: 0.3)),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(short(libraryName, 40), style: const pw.TextStyle(fontSize: 6, color: PdfColors.grey700)),
                  pw.Text(short(l.title, 38), style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 2),
                  pw.Expanded(
                    child: pw.BarcodeWidget(
                      barcode: pw.Barcode.code128(),
                      data: l.barcode,
                      textStyle: const pw.TextStyle(fontSize: 7),
                    ),
                  ),
                  pw.SizedBox(height: 1),
                  pw.Text(
                    [
                      if (l.accessionNumber != null) 'No. perolehan: ${l.accessionNumber}',
                      if (l.callNumber != null) l.callNumber!,
                    ].join('  •  '),
                    style: const pw.TextStyle(fontSize: 6),
                  ),
                ],
              ),
            ),
        ],
      ),
    ));
  }
  return doc.save();
}
