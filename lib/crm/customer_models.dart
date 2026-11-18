// Read model for a CRM customer = Party (type Customer) + derived stats.
// Pure Dart (no Flutter) so it is unit-testable.

import 'phone_utils.dart';

/// Names that mean "no real name was typed" on old bills.
bool isPlaceholderName(String? n) {
  final s = (n ?? '').trim().toLowerCase();
  return s.isEmpty ||
      s == 'walk-in customer' ||
      s == 'walk-in' ||
      s == 'walk in' ||
      s == 'walkin' ||
      s == 'cash' ||
      s == 'customer';
}

bool isCustomerParty(Map p) => '${p['type'] ?? 'Customer'}' != 'Supplier';

DateTime? _parseDt(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  return DateTime.tryParse('$v');
}

/// The moment a sale happened (backdated bills carry `saleDate`).
String saleWhen(Map s) =>
    '${s['saleDate'] ?? s['createdAt'] ?? s['date'] ?? ''}';

class CrmCustomer {
  final String id; // uuid `_id` (sync reference)
  final dynamic key; // local Hive key of the party (device-specific!)
  final String name;
  final String phone; // normalised 10 digits ('' if none)
  final DateTime? createdAt;
  final DateTime? firstPurchaseAt;
  final DateTime? lastPurchaseAt;
  final int totalSpentPaise; // derived from sales, never synced
  final int billCount; // derived from sales, never synced
  final int balancePaise; // party balance (receivable), from the party record
  final bool whatsappOptIn;
  final bool doNotMessage;
  final String? birthday; // yyyy-MM-dd
  final String notes;
  final List<String> tags;

  const CrmCustomer({
    required this.id,
    required this.key,
    required this.name,
    required this.phone,
    this.createdAt,
    this.firstPurchaseAt,
    this.lastPurchaseAt,
    this.totalSpentPaise = 0,
    this.billCount = 0,
    this.balancePaise = 0,
    this.whatsappOptIn = false,
    this.doNotMessage = false,
    this.birthday,
    this.notes = '',
    this.tags = const [],
  });

  /// Can receive promotional WhatsApp messages (Phase 5 uses this).
  bool get canMessage => whatsappOptIn && !doNotMessage && phone.isNotEmpty;

  factory CrmCustomer.from(dynamic key, Map party, Map? stats) {
    final st = stats ?? const {};
    return CrmCustomer(
      id: '${party['_id']}',
      key: key,
      name: '${party['name'] ?? ''}',
      phone: normalizePhone('${party['phone'] ?? ''}') ?? '',
      createdAt: _parseDt(party['createdAt']),
      firstPurchaseAt: _parseDt(st['firstPurchaseAt']),
      lastPurchaseAt: _parseDt(st['lastPurchaseAt']),
      totalSpentPaise: (st['totalSpent'] as num?)?.toInt() ?? 0,
      billCount: (st['billCount'] as num?)?.toInt() ?? 0,
      balancePaise: toPaise(party['balance']),
      whatsappOptIn: party['whatsappOptIn'] == true,
      doNotMessage: party['doNotMessage'] == true,
      birthday: party['birthday'] == null ? null : '${party['birthday']}',
      notes: '${party['notes'] ?? ''}',
      tags: [for (final t in (party['tags'] as List?) ?? const []) '$t'],
    );
  }
}

/// Thrown when a phone number already belongs to another customer.
class DuplicatePhoneException implements Exception {
  final CrmCustomer existing;
  DuplicatePhoneException(this.existing);
  String get message =>
      'ഈ നമ്പർ ഇതിനകം "${existing.name}" എന്ന കസ്റ്റമറിനുണ്ട് '
      '(This number already belongs to ${existing.name})';
  @override
  String toString() => message;
}
