/// Utility class for IMEI/Serial validation, Luhn checksum calculation,
/// Dual-IMEI handling, and duplicate stock verification.
class ImeiValidator {
  ImeiValidator._();

  /// Validates a standard 15-digit numeric IMEI using the 3GPP Luhn checksum algorithm (Mod 10).
  /// Returns `true` if the 15-digit number passes the Luhn check.
  /// Non-15 digit strings or non-numeric strings return `false`.
  static bool isValidLuhn(String imei) {
    final clean = imei.trim();
    if (clean.length != 15 || !RegExp(r'^\d{15}$').hasMatch(clean)) {
      return false;
    }

    int sum = 0;
    for (int i = 0; i < 15; i++) {
      int digit = int.parse(clean[i]);
      // Double every second digit from the right (indices 1, 3, 5, 7, 9, 11, 13)
      if (i % 2 == 1) {
        digit *= 2;
        if (digit > 9) {
          digit -= 9;
        }
      }
      sum += digit;
    }

    return sum % 10 == 0;
  }

  /// Calculates the expected 15th check digit for a 14-digit TAC+SNR IMEI prefix.
  static int? calculateCheckDigit(String prefix14) {
    final clean = prefix14.trim();
    if (clean.length != 14 || !RegExp(r'^\d{14}$').hasMatch(clean)) {
      return null;
    }

    int sum = 0;
    for (int i = 0; i < 14; i++) {
      int digit = int.parse(clean[i]);
      if (i % 2 == 1) {
        digit *= 2;
        if (digit > 9) {
          digit -= 9;
        }
      }
      sum += digit;
    }

    return (10 - (sum % 10)) % 10;
  }

  /// Categorizes an identifier:
  /// - 'VALID_IMEI': 15 digits with valid Luhn checksum
  /// - 'INVALID_LUHN_IMEI': 15 digits but invalid Luhn checksum (potential typo)
  /// - 'DEVICE_SERIAL': Alphanumeric serial number (e.g. Apple or non-standard device)
  /// - 'EMPTY': Empty string
  static String categorizeIdentifier(String input) {
    final clean = input.trim().toUpperCase();
    if (clean.isEmpty) return 'EMPTY';
    if (clean.length == 15 && RegExp(r'^\d{15}$').hasMatch(clean)) {
      return isValidLuhn(clean) ? 'VALID_IMEI' : 'INVALID_LUHN_IMEI';
    }
    return 'DEVICE_SERIAL';
  }

  /// Extracts individual IMEIs from a serialized unit string.
  /// Handles dual-IMEI formats like "IMEI1 / IMEI2" or "IMEI1, IMEI2".
  static List<String> extractImeisFromUnit(String unitString) {
    final clean = unitString.trim();
    if (clean.isEmpty) return [];
    if (clean.contains('/') || clean.contains(',')) {
      return clean
          .split(RegExp(r'[/,]+'))
          .map((s) => s.trim().toUpperCase())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return [clean.toUpperCase()];
  }

  /// Formats a Primary and optional Secondary IMEI into a single serialized unit string.
  static String formatDualImei(String imei1, [String? imei2]) {
    final p1 = imei1.trim().toUpperCase();
    final p2 = imei2?.trim().toUpperCase();
    if (p2 != null && p2.isNotEmpty && p2 != p1) {
      return '$p1 / $p2';
    }
    return p1;
  }
}

