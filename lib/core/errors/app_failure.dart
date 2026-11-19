import 'package:supabase_flutter/supabase_flutter.dart';

/// A user-facing failure with a message in Bahasa Melayu.
class AppFailure implements Exception {
  const AppFailure(this.message, {this.code, this.cause});

  final String message;
  final String? code;
  final Object? cause;

  /// Maps low-level errors to messages non-technical library staff understand.
  factory AppFailure.from(Object error) {
    if (error is AppFailure) return error;
    if (_isNetwork(error)) {
      return AppFailure('Tidak dapat menghubungi pelayan. Semak sambungan internet dan cuba lagi.',
          code: 'offline', cause: error);
    }
    if (error is AuthException) {
      final code = error.code ?? '';
      final msg = switch (code) {
        'invalid_credentials' => 'E-mel atau kata laluan tidak betul.',
        'email_not_confirmed' => 'Sila sahkan e-mel anda terlebih dahulu.',
        'user_already_exists' || 'email_exists' => 'E-mel ini sudah didaftarkan.',
        'weak_password' => 'Kata laluan terlalu lemah.',
        'over_email_send_rate_limit' || 'over_request_rate_limit' =>
          'Terlalu banyak cubaan. Sila cuba sebentar lagi.',
        _ => 'Ralat pengesahan: ${error.message}',
      };
      return AppFailure(msg, code: code, cause: error);
    }
    if (error is PostgrestException) {
      final msg = switch (error.code) {
        '42501' => 'Anda tidak mempunyai kebenaran untuk tindakan ini.',
        '23505' => _uniqueMessage(error.message),
        '23503' => 'Rekod berkaitan tidak wujud atau milik perpustakaan lain.',
        '23514' => 'Data tidak memenuhi peraturan sistem.',
        'PGRST301' || 'PGRST303' => 'Sesi telah tamat. Sila log masuk semula.',
        _ => 'Ralat pelayan (${error.code ?? '-'}).',
      };
      return AppFailure(msg, code: error.code, cause: error);
    }
    return AppFailure('Ralat tidak dijangka. Sila cuba lagi.', cause: error);
  }

  /// Network failures, including those wrapped by supabase as
  /// AuthRetryableFetchException / ClientException.
  static bool _isNetwork(Object error) {
    if (error is AuthRetryableFetchException) return true;
    final text = error.toString();
    return text.contains('SocketException') || text.contains('ClientException') ||
        text.contains('Failed host lookup') || text.contains('Connection refused') ||
        text.contains('Network is unreachable') || text.contains('TimeoutException');
  }

  static String _uniqueMessage(String raw) {
    if (raw.contains('barcode')) return 'Barcode ini sudah digunakan dalam perpustakaan ini.';
    if (raw.contains('libraries_code')) return 'Kod perpustakaan sudah digunakan.';
    if (raw.contains('accession')) return 'Nombor perolehan sudah digunakan.';
    return 'Rekod pendua dikesan.';
  }

  @override
  String toString() => 'AppFailure($code): $message';
}
