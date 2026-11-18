/// Form validators. Return `null` when valid, otherwise a Malay message.
/// Server-side CHECK constraints remain the final authority.
abstract final class Validators {
  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  static String? email(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'E-mel diperlukan.';
    if (!_email.hasMatch(v)) return 'Format e-mel tidak sah.';
    return null;
  }

  static String? password(String? value) {
    final v = value ?? '';
    if (v.isEmpty) return 'Kata laluan diperlukan.';
    if (v.length < 8) return 'Kata laluan mesti sekurang-kurangnya 8 aksara.';
    if (!RegExp(r'[A-Za-z]').hasMatch(v) || !RegExp(r'\d').hasMatch(v)) {
      return 'Kata laluan mesti mengandungi huruf dan nombor.';
    }
    return null;
  }

  static String? required(String? value, {String field = 'Medan ini'}) {
    if ((value?.trim() ?? '').isEmpty) return '$field diperlukan.';
    return null;
  }

  /// Library code rule mirrors the DB CHECK: A-Z, 0-9, _ or -, 2-32 chars.
  static String? libraryCode(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Kod perpustakaan diperlukan.';
    if (!RegExp(r'^[A-Z0-9][A-Z0-9_-]{1,31}$').hasMatch(v)) {
      return 'Kod hanya huruf besar, nombor, _ atau - (2–32 aksara).';
    }
    return null;
  }
}
