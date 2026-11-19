import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/core/errors/app_failure.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('maps RLS denial to permission message', () {
    final f = AppFailure.from(const PostgrestException(message: 'new row violates row-level security', code: '42501'));
    expect(f.message, contains('kebenaran'));
  });

  test('maps duplicate barcode', () {
    final f = AppFailure.from(const PostgrestException(
        message: 'duplicate key value violates unique constraint "book_copies_library_barcode_key"', code: '23505'));
    expect(f.message, contains('Barcode'));
  });

  test('maps invalid credentials', () {
    final f = AppFailure.from(const AuthException('Invalid login credentials', code: 'invalid_credentials'));
    expect(f.message, 'E-mel atau kata laluan tidak betul.');
  });

  test('unknown errors get a generic message', () {
    expect(AppFailure.from(StateError('x')).message, contains('tidak dijangka'));
  });

  test('network failures (incl. wrapped by supabase auth) get a plain Malay message', () {
    for (final e in [
      AuthRetryableFetchException(
          message: "ClientException with SocketException: Failed host lookup: 'x.supabase.co'"),
      Exception("ClientException with SocketException: Failed host lookup: 'x.supabase.co'"),
    ]) {
      final f = AppFailure.from(e);
      expect(f.code, 'offline');
      expect(f.message, startsWith('Tidak dapat menghubungi pelayan'));
      expect(f.message, isNot(contains('Exception')));
    }
  });
}
