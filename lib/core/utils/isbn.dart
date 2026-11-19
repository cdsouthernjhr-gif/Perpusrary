/// ISBN helpers. An ISBN identifies a title/edition — never a physical copy.
abstract final class Isbn {
  /// Strips spaces/hyphens and upper-cases a trailing x. Returns null for
  /// empty input. Does not validate.
  static String? normalize(String? raw) {
    if (raw == null) return null;
    final s = raw.replaceAll(RegExp(r'[\s\-]'), '').toUpperCase();
    return s.isEmpty ? null : s;
  }

  static bool isValid10(String s) {
    if (!RegExp(r'^\d{9}[\dX]$').hasMatch(s)) return false;
    var sum = 0;
    for (var i = 0; i < 10; i++) {
      final v = s[i] == 'X' ? 10 : int.parse(s[i]);
      sum += v * (10 - i);
    }
    return sum % 11 == 0;
  }

  static bool isValid13(String s) {
    if (!RegExp(r'^\d{13}$').hasMatch(s)) return false;
    var sum = 0;
    for (var i = 0; i < 13; i++) {
      sum += int.parse(s[i]) * (i.isEven ? 1 : 3);
    }
    return sum % 10 == 0;
  }

  /// True for a checksum-valid ISBN-10 or ISBN-13 (978/979 prefix).
  static bool isValid(String? raw) {
    final s = normalize(raw);
    if (s == null) return false;
    if (s.length == 10) return isValid10(s);
    if (s.length == 13) return (s.startsWith('978') || s.startsWith('979')) && isValid13(s);
    return false;
  }

  /// Matches the database CHECK (format only, no checksum).
  static bool matchesDbFormat(String s) => RegExp(r'^(\d{9}[\dX]|\d{13})$').hasMatch(s);

  /// ISBN-10 → ISBN-13 (978 prefix). Returns null if [isbn10] is invalid.
  static String? to13(String isbn10) {
    final s = normalize(isbn10);
    if (s == null || !isValid10(s)) return null;
    final core = '978${s.substring(0, 9)}';
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      sum += int.parse(core[i]) * (i.isEven ? 1 : 3);
    }
    return '$core${(10 - sum % 10) % 10}';
  }

  /// ISBN-13 (978 prefix only) → ISBN-10. 979 ISBNs have no ISBN-10 form.
  /// Returns null if [isbn13] is not a valid 978 ISBN-13.
  static String? to10(String isbn13) {
    final s = normalize(isbn13);
    if (s == null || !s.startsWith('978') || !isValid13(s)) return null;
    final core = s.substring(3, 12);
    var sum = 0;
    for (var i = 0; i < 9; i++) {
      sum += int.parse(core[i]) * (10 - i);
    }
    final check = (11 - sum % 11) % 11;
    return '$core${check == 10 ? 'X' : check}';
  }

  /// Canonical form used for storage and duplicate checks: ISBN-13 when
  /// possible, otherwise the normalized input.
  static String? canonical(String? raw) {
    final s = normalize(raw);
    if (s == null) return null;
    if (s.length == 10 && isValid10(s)) return to13(s);
    return s;
  }

  /// Form validator (Malay). ISBN is optional; when present it must be
  /// well-formed. A failing checksum is only a warning (see [checksumWarning]).
  static String? validate(String? raw) {
    final s = normalize(raw);
    if (s == null) return null;
    if (!matchesDbFormat(s)) return 'ISBN mesti 10 atau 13 digit.';
    return null;
  }

  static String? checksumWarning(String? raw) {
    final s = normalize(raw);
    if (s == null || !matchesDbFormat(s)) return null;
    return isValid(s) ? null : 'Digit semak ISBN tidak sah — sila semak semula.';
  }
}
