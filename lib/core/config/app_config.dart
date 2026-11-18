import 'dart:convert';

/// Runtime configuration injected at build time with `--dart-define`
/// (or `--dart-define-from-file=env/dev.json`).
///
/// Only the project URL and the PUBLIC anon/publishable key belong in the app.
/// A `service_role` key bypasses RLS and must NEVER be shipped in an APK, so
/// [AppConfig.validate] refuses to start with one.
class AppConfig {
  const AppConfig({required this.supabaseUrl, required this.supabaseAnonKey});

  factory AppConfig.fromEnvironment() => const AppConfig(
        supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
        supabaseAnonKey: String.fromEnvironment('SUPABASE_ANON_KEY'),
      );

  final String supabaseUrl;
  final String supabaseAnonKey;

  /// Returns a list of human-readable problems (empty when valid).
  List<String> validate() {
    final problems = <String>[];
    final uri = Uri.tryParse(supabaseUrl);
    if (supabaseUrl.isEmpty) {
      problems.add('SUPABASE_URL tidak ditetapkan.');
    } else if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      problems.add('SUPABASE_URL tidak sah.');
    } else if (uri.scheme != 'https' && !_isLocalHost(uri.host)) {
      problems.add('SUPABASE_URL mesti menggunakan https.');
    }

    if (supabaseAnonKey.isEmpty) {
      problems.add('SUPABASE_ANON_KEY tidak ditetapkan.');
    } else if (isPrivilegedKey(supabaseAnonKey)) {
      problems.add(
        'Kunci yang diberikan ialah kunci service_role/secret. Kunci ini '
        'memintas RLS dan TIDAK BOLEH dimasukkan ke dalam aplikasi. '
        'Gunakan anon / publishable key sahaja.',
      );
    }
    return problems;
  }

  bool get isValid => validate().isEmpty;

  static bool _isLocalHost(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host == '10.0.2.2';

  /// Detects keys that must never be embedded in a client:
  ///  * new-style secret keys (`sb_secret_...`)
  ///  * legacy JWT keys whose `role` claim is `service_role`.
  static bool isPrivilegedKey(String key) {
    if (key.startsWith('sb_secret_')) return true;
    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final claims = jsonDecode(payload);
      return claims is Map && claims['role'] == 'service_role';
    } on FormatException {
      return false;
    }
  }
}
