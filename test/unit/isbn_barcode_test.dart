import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/core/utils/barcode.dart';
import 'package:smartlibrary_manager/core/utils/isbn.dart';

void main() {
  group('Isbn', () {
    test('normalize strips hyphens/spaces', () {
      expect(Isbn.normalize(' 978-983-62-6123-4 '), '9789836261234');
      expect(Isbn.normalize('0-306-40615-x'), '030640615X');
      expect(Isbn.normalize('  '), isNull);
    });

    test('checksums', () {
      expect(Isbn.isValid('0306406152'), isTrue);
      expect(Isbn.isValid('0306406153'), isFalse);
      expect(Isbn.isValid('9780306406157'), isTrue);
      expect(Isbn.isValid('9780306406158'), isFalse);
      expect(Isbn.isValid('080442957X'), isTrue);
      expect(Isbn.isValid('1234567890123'), isFalse, reason: 'needs 978/979 prefix');
    });

    test('ISBN-10 converts to ISBN-13 for canonical storage', () {
      expect(Isbn.to13('0306406152'), '9780306406157');
      expect(Isbn.canonical('0-306-40615-2'), '9780306406157');
      expect(Isbn.canonical('9780306406157'), '9780306406157');
    });

    test('validator: format is an error, checksum only a warning', () {
      expect(Isbn.validate(null), isNull);
      expect(Isbn.validate('12345'), isNotNull);
      expect(Isbn.validate('9780306406158'), isNull);
      expect(Isbn.checksumWarning('9780306406158'), isNotNull);
      expect(Isbn.checksumWarning('9780306406157'), isNull);
    });
  });

  group('CopyBarcode', () {
    test('validation mirrors the DB CHECK (printable ASCII, no spaces, <=64)', () {
      expect(CopyBarcode.validate('A0001'), isNull);
      expect(CopyBarcode.validate('LIB-A/01#2'), isNull);
      expect(CopyBarcode.validate(''), isNotNull);
      expect(CopyBarcode.validate('A 1'), isNotNull);
      expect(CopyBarcode.validate('Ä1'), isNotNull);
      expect(CopyBarcode.validate('X' * 65), isNotNull);
    });

    test('generated barcodes are valid, deterministic and device-specific', () {
      const d1 = '3f2a9c10-0000-4000-8000-000000000001';
      const d2 = '7b11e4d2-0000-4000-8000-000000000002';
      final a = CopyBarcode.generate(libraryCode: 'LIB-A', deviceId: d1, sequence: 12);
      expect(a, matches(RegExp(r'^LIBA-[0-9A-Z]{4}-000012$')));
      expect(CopyBarcode.validate(a), isNull);
      expect(CopyBarcode.generate(libraryCode: 'LIB-A', deviceId: d1, sequence: 12), a);
      expect(CopyBarcode.generate(libraryCode: 'LIB-A', deviceId: d2, sequence: 12), isNot(a));
    });
  });
}
