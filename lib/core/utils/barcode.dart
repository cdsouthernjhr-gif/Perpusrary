/// Barcode rules for PHYSICAL COPIES (not ISBN).
abstract final class CopyBarcode {
  /// Same rule as the database CHECK: printable ASCII without spaces,
  /// 1–64 chars — every such string is encodable as Code 128.
  static final _pattern = RegExp(r'^[!-~]{1,64}$');

  static String normalize(String raw) => raw.trim();

  static String? validate(String? raw) {
    final v = raw?.trim() ?? '';
    if (v.isEmpty) return 'Barcode diperlukan.';
    if (v.length > 64) return 'Barcode maksimum 64 aksara.';
    if (!_pattern.hasMatch(v)) return 'Barcode hanya boleh mengandungi aksara ASCII tanpa ruang.';
    return null;
  }

  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford base32

  /// Device tag: 4 base32 chars derived from the device UUID.
  static String deviceTag(String deviceId) {
    final hex = deviceId.replaceAll('-', '');
    final n = int.parse(hex.substring(0, 5), radix: 16); // 20 bits
    final b = StringBuffer();
    var x = n;
    for (var i = 0; i < 4; i++) {
      b.write(_alphabet[x & 31]);
      x >>= 5;
    }
    return b.toString();
  }

  /// System-generated barcode: `<LIBCODE>-<DEVICETAG>-<SEQ>`, e.g.
  /// `LIBA-7F3K-000123`. Device tag + per-device counter make collisions
  /// between offline devices very unlikely, but NOT impossible — the server
  /// UNIQUE (library_id, barcode) constraint remains the final authority and
  /// a rejected copy can simply get a new barcode.
  static String generate({required String libraryCode, required String deviceId, required int sequence}) {
    final code = libraryCode.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final prefix = code.length > 12 ? code.substring(0, 12) : code;
    return '$prefix-${deviceTag(deviceId)}-${sequence.toString().padLeft(6, '0')}';
  }
}
