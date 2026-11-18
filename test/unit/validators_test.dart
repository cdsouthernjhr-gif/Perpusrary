import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/core/utils/validators.dart';

void main() {
  test('email', () {
    expect(Validators.email(''), isNotNull);
    expect(Validators.email('abc'), isNotNull);
    expect(Validators.email(' staf@sekolah.edu.my '), isNull);
  });

  test('password needs 8+ chars with letters and digits', () {
    expect(Validators.password('abc'), isNotNull);
    expect(Validators.password('abcdefgh'), isNotNull);
    expect(Validators.password('12345678'), isNotNull);
    expect(Validators.password('perpus2026'), isNull);
  });

  test('library code mirrors DB check constraint', () {
    expect(Validators.libraryCode('LIBA'), isNull);
    expect(Validators.libraryCode('SK-01_A'), isNull);
    expect(Validators.libraryCode('liba'), isNotNull);
    expect(Validators.libraryCode('A'), isNotNull);
    expect(Validators.libraryCode('-ABC'), isNotNull);
  });
}
