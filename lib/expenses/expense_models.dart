import 'package:cloud_firestore/cloud_firestore.dart';

class ExpenseCategory {
  static const stationeryAndPacking = 'Stationery & Packing';
  static const refreshmentsAndFood = 'Refreshments & Food';
  static const electricityAndUtility = 'Electricity & Utility Bills';
  static const rentAndMaintenance = 'Rent & Maintenance';
  static const transportationAndTravel = 'Transportation & Travel';
  static const miscellaneousOther = 'Miscellaneous / Other';

  // Aliases for compatibility
  static const foodBeverages = refreshmentsAndFood;
  static const shopSupplies = stationeryAndPacking;
  static const utilities = electricityAndUtility;
  static const repairsMaintenance = rentAndMaintenance;
  static const rentProperty = rentAndMaintenance;
  static const deliveryFreight = transportationAndTravel;
  static const dailyRent = 'Daily Shop Rent';
  static const ownerSalary = 'Shop Owner Salary';

  static const List<String> all = [
    stationeryAndPacking,
    refreshmentsAndFood,
    electricityAndUtility,
    rentAndMaintenance,
    transportationAndTravel,
    miscellaneousOther,
  ];

  static String toMalayalam(String category) {
    switch (category) {
      case stationeryAndPacking:
        return 'സ്റ്റേഷനറി & പാക്കിംഗ്';
      case refreshmentsAndFood:
        return 'ഭക്ഷണം & ചായ ചിലവുകൾ';
      case electricityAndUtility:
        return 'കറന്റ് & മറ്റ് ബില്ലുകൾ';
      case rentAndMaintenance:
        return 'വാടക & മെയിന്റനൻസ്';
      case transportationAndTravel:
        return 'യാത്ര & ട്രാൻസ്പോർട്ട്';
      case dailyRent:
        return 'കട വാടക';
      case ownerSalary:
        return 'ഉടമയുടെ ശമ്പളം (Owner Salary)';
      case miscellaneousOther:
      default:
        return 'മറ്റ് ചിലവുകൾ';
    }
  }
}

class ExpensePaymentMode {
  static const cash = 'CASH';
  static const bank = 'BANK';

  static const List<String> all = [cash, bank];

  static String toDisplay(String mode) {
    switch (mode.toUpperCase()) {
      case cash:
        return 'Cash in Hand (ക്യാഷ്)';
      case bank:
        return 'Bank / UPI (ബാങ്ക്)';
      default:
        return mode;
    }
  }

  static String toLedgerMode(String mode) {
    return mode.toUpperCase() == cash ? 'Cash' : 'Bank';
  }
}

class ExpenseItem {
  final String id;
  final String shopId;
  final String title;
  final String category;
  final double amount;
  final int amountPaise;
  final String paymentMode; // CASH or BANK
  final DateTime expenseDate;
  final String recordedByUid;
  final String recordedByName;
  final String notes;
  final String? receiptUrl;
  final bool isVoided;
  final DateTime? voidedAt;
  final String? voidedByUid;
  final String? voidReason;
  final bool isDailyRent;
  final String? rentRecordId;
  final bool isOwnerWithdrawal;
  final String? withdrawalId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const ExpenseItem({
    required this.id,
    this.shopId = '',
    required this.title,
    required this.category,
    required this.amount,
    required this.amountPaise,
    required this.paymentMode,
    required this.expenseDate,
    required this.recordedByUid,
    required this.recordedByName,
    this.notes = '',
    this.receiptUrl,
    this.isVoided = false,
    this.voidedAt,
    this.voidedByUid,
    this.voidReason,
    this.isDailyRent = false,
    this.rentRecordId,
    this.isOwnerWithdrawal = false,
    this.withdrawalId,
    this.createdAt,
    this.updatedAt,
  });

  bool get isCash => paymentMode.toUpperCase() == ExpensePaymentMode.cash;
  bool get isBank => paymentMode.toUpperCase() == ExpensePaymentMode.bank;

  Map<String, dynamic> toMap({bool forFirestore = false}) {
    return {
      'id': id,
      'shopId': shopId,
      'title': title,
      'category': category,
      'amount': amount,
      'amountPaise': amountPaise,
      'paymentMode': paymentMode,
      'expenseDate': forFirestore
          ? Timestamp.fromDate(expenseDate)
          : expenseDate.toIso8601String(),
      'recordedByUid': recordedByUid,
      'recordedByName': recordedByName,
      'notes': notes,
      'receiptUrl': receiptUrl,
      'isVoided': isVoided,
      'voidedAt': voidedAt != null
          ? (forFirestore ? Timestamp.fromDate(voidedAt!) : voidedAt!.toIso8601String())
          : null,
      'voidedByUid': voidedByUid,
      'voidReason': voidReason,
      'isDailyRent': isDailyRent,
      'rentRecordId': rentRecordId,
      'isOwnerWithdrawal': isOwnerWithdrawal,
      'withdrawalId': withdrawalId,
      'createdAt': forFirestore
          ? FieldValue.serverTimestamp()
          : (createdAt?.toIso8601String() ?? DateTime.now().toIso8601String()),
      'updatedAt': forFirestore
          ? FieldValue.serverTimestamp()
          : (updatedAt?.toIso8601String() ?? DateTime.now().toIso8601String()),
    };
  }

  factory ExpenseItem.fromMap(Map<String, dynamic> map, [String docId = '']) {
    DateTime parseDate(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
      if (v is String) return DateTime.tryParse(v) ?? DateTime.now();
      return DateTime.now();
    }

    final double amt = (map['amount'] as num?)?.toDouble() ??
        (((map['amountPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final int paise = (map['amountPaise'] as num?)?.toInt() ?? (amt * 100).round();
    final resolvedId = docId.isNotEmpty ? docId : (map['id']?.toString() ?? '');

    return ExpenseItem(
      id: resolvedId,
      shopId: map['shopId']?.toString() ?? '',
      title: map['title']?.toString() ?? 'Expense',
      category: map['category']?.toString() ?? ExpenseCategory.miscellaneousOther,
      amount: amt,
      amountPaise: paise,
      paymentMode: (map['paymentMode']?.toString() ?? 'CASH').toUpperCase(),
      expenseDate: parseDate(map['expenseDate'] ?? map['createdAt']),
      recordedByUid: map['recordedByUid']?.toString() ?? '',
      recordedByName: map['recordedByName']?.toString() ?? 'Staff',
      notes: map['notes']?.toString() ?? '',
      receiptUrl: map['receiptUrl']?.toString(),
      isVoided: map['isVoided'] == true,
      voidedAt: map['voidedAt'] != null ? parseDate(map['voidedAt']) : null,
      voidedByUid: map['voidedByUid']?.toString(),
      voidReason: map['voidReason']?.toString(),
      isDailyRent: map['isDailyRent'] == true,
      rentRecordId: map['rentRecordId']?.toString(),
      isOwnerWithdrawal: map['isOwnerWithdrawal'] == true,
      withdrawalId: map['withdrawalId']?.toString(),
      createdAt: map['createdAt'] != null ? parseDate(map['createdAt']) : null,
      updatedAt: map['updatedAt'] != null ? parseDate(map['updatedAt']) : null,
    );
  }

  ExpenseItem copyWith({
    String? title,
    String? category,
    double? amount,
    int? amountPaise,
    String? paymentMode,
    DateTime? expenseDate,
    String? notes,
    String? receiptUrl,
    bool? isVoided,
    DateTime? voidedAt,
    String? voidedByUid,
    String? voidReason,
  }) {
    return ExpenseItem(
      id: id,
      shopId: shopId,
      title: title ?? this.title,
      category: category ?? this.category,
      amount: amount ?? this.amount,
      amountPaise: amountPaise ?? this.amountPaise,
      paymentMode: paymentMode ?? this.paymentMode,
      expenseDate: expenseDate ?? this.expenseDate,
      recordedByUid: recordedByUid,
      recordedByName: recordedByName,
      notes: notes ?? this.notes,
      receiptUrl: receiptUrl ?? this.receiptUrl,
      isVoided: isVoided ?? this.isVoided,
      voidedAt: voidedAt ?? this.voidedAt,
      voidedByUid: voidedByUid ?? this.voidedByUid,
      voidReason: voidReason ?? this.voidReason,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

