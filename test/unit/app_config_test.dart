import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlibrary_manager/core/config/app_config.dart';

String _jwt(Map<String, Object> claims) {
  String enc(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${enc({'alg': 'HS256', 'typ': 'JWT'})}.${enc(claims)}.signature';
}

void main() {
  group('AppConfig', () {
    test('accepts https URL and anon JWT key', () {
      final c = AppConfig(supabaseUrl: 'https://abc.supabase.co', supabaseAnonKey: _jwt({'role': 'anon'}));
      expect(c.validate(), isEmpty);
    });

    test('accepts new-style publishable key', () {
      const c = AppConfig(supabaseUrl: 'https://abc.supabase.co', supabaseAnonKey: 'sb_publishable_xyz');
      expect(c.isValid, isTrue);
    });

    test('rejects legacy service_role JWT', () {
      final c = AppConfig(supabaseUrl: 'https://abc.supabase.co', supabaseAnonKey: _jwt({'role': 'service_role'}));
      expect(c.isValid, isFalse);
      expect(c.validate().single, contains('service_role'));
    });

    test('rejects new-style secret key', () {
      expect(AppConfig.isPrivilegedKey('sb_secret_abc'), isTrue);
    });

    test('rejects missing values and plain http (non-local)', () {
      expect(const AppConfig(supabaseUrl: '', supabaseAnonKey: '').validate(), hasLength(2));
      expect(const AppConfig(supabaseUrl: 'http://abc.supabase.co', supabaseAnonKey: 'sb_publishable_x').isValid,
          isFalse);
      expect(const AppConfig(supabaseUrl: 'http://10.0.2.2:54321', supabaseAnonKey: 'sb_publishable_x').isValid,
          isTrue);
    });

    test('garbage key is not treated as privileged', () {
      expect(AppConfig.isPrivilegedKey('a.b.c'), isFalse);
    });

    test('example/placeholder config (CI build-check APK) is refused with a clear message', () {
      const example = AppConfig(
          supabaseUrl: 'https://YOUR-PROJECT-REF.supabase.co', supabaseAnonKey: 'sb_publishable_REPLACE_ME');
      expect(example.isPlaceholder, isTrue);
      expect(example.validate(), [AppConfig.placeholderMessage]);
      const real = AppConfig(
          supabaseUrl: 'https://ifzsuoxegomisfxkjcmk.supabase.co', supabaseAnonKey: 'sb_publishable_abc');
      expect(real.isValid, isTrue);
    });
  });
}
