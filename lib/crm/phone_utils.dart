// Phone normalisation for the Customer CRM layer.
//
// Every phone number that is saved, searched or looked up goes through
// [normalizePhone] so "+91 98470-12345", "098470 12345" and "9847012345" are
// the same customer. Pure Dart: no Flutter imports (unit-testable).

/// Strips spaces, dashes, brackets, `+91` / `0091` / `91` country prefix and a
/// leading trunk `0`. Returns exactly 10 digits, or `null` when the input is
/// not a valid Indian mobile number (must start with 6, 7, 8 or 9).
String? normalizePhone(String? raw) {
  if (raw == null) return null;
  var d = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.isEmpty) return null;
  // 0091XXXXXXXXXX / 0XXXXXXXXXX -> drop leading zeros (trunk / intl prefix)
  if (d.length > 10) d = d.replaceFirst(RegExp(r'^0+'), '');
  // 91XXXXXXXXXX -> drop country code
  if (d.length == 12 && d.startsWith('91')) d = d.substring(2);
  if (d.length != 10) return null;
  if (!RegExp(r'^[6-9]').hasMatch(d)) return null;
  return d;
}

/// True when [raw] normalises to a valid 10-digit mobile number.
bool isValidPhone(String? raw) => normalizePhone(raw) != null;

/// Digits only, for partial (e.g. last-4) searches. Never validates.
String phoneDigits(String? raw) =>
    (raw ?? '').replaceAll(RegExp(r'[^0-9]'), '');

/// User-facing validation message (bilingual) or `null` when OK.
/// An empty value is allowed (walk-in customer, phone is optional).
String? phoneError(String? raw) {
  if (phoneDigits(raw).isEmpty) return null;
  if (normalizePhone(raw) != null) return null;
  return 'ശരിയായ 10 അക്ക മൊബൈൽ നമ്പർ നൽകുക (Enter a valid 10-digit mobile number)';
}

/// Integer paise from a rupee amount stored as num/String (legacy records
/// store rupees as double). Rounds half away from zero.
int toPaise(dynamic rupees) {
  final v = rupees is num
      ? rupees.toDouble()
      : (double.tryParse('${rupees ?? ''}') ?? 0.0);
  return (v * 100).round();
}
