import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/features/barcode/application/label_pdf.dart';

void main() {
  test('builds a multi-page PDF of Code 128 labels', () async {
    final labels = [
      for (var i = 1; i <= 30; i++)
        LabelData(barcode: 'LIBA-7F3K-${i.toString().padLeft(6, '0')}', title: 'Hikayat Hang Tuah jilid $i',
            accessionNumber: 'P$i'),
    ];
    final bytes = await buildLabelsPdf(libraryName: 'Perpustakaan Sekolah A', labels: labels);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final text = String.fromCharCodes(bytes);
    expect(RegExp(r'/Type\s*/Page[^s]').allMatches(text).length, 2, reason: '30 labels / 24 per page');
  });
}
