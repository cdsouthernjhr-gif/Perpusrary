// Live check against the real catalogues. Network required; skipped unless
// LIVE=1:  LIVE=1 flutter test test/live/isbn_live_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/data/remote/book_metadata_service.dart';

const isbns = [
  // Malaysian (978-967 / 978-983), mix of ITBM, DBP, university presses
  '9789672417934', '9789674608194', '9789674608323', '9789674608422', '9789674881245',
  '9789674881610', '9789675780523', '9789834916732', '9789834916800', '9789834916961',
  '9789834923129', '9789836213426', '9789834600938', '9789836255235', '9789674608644',
  // International
  '9780140328721', '9780367473884', '9781848994089', '0306406152',
];

void main() {
  test('live ISBN lookup', () async {
    final svc = BookMetadataService(timeout: const Duration(seconds: 20));
    var found = 0;
    for (final i in isbns) {
      final r = await svc.search(i);
      if (r.found) found++;
      final b = r.book;
      stdout.writeln('${i.padRight(13)} ${r.found ? 'FOUND' : '-----'} '
          '[${b?.sources.join('+') ?? ''}] ${b?.title ?? ''} | ${b?.author ?? ''} | ${b?.publisher ?? ''} | '
          '${b?.publicationYear ?? ''} | ddc=${b?.callNumber ?? ''}'
          '${r.unreachable.isEmpty ? '' : '  (unreachable: ${r.unreachable.join(',')})'}');
    }
    stdout.writeln('FOUND $found / ${isbns.length}');
  }, timeout: const Timeout(Duration(minutes: 10)), skip: Platform.environment['LIVE'] != '1');
}
