import 'package:cloud_firestore/cloud_firestore.dart';
import '../expenses/expense_models.dart';

enum RentScheduleType {
  everyDay,
  operatingDaysOnly;

  String get code {
    switch (this) {
      case RentScheduleType.everyDay:
        return 'EVERY_DAY';
      case RentScheduleType.operatingDaysOnly:
        return 'OPERATING_DAYS_ONLY';
    }
  }

  String get label {
    switch (this) {
      case RentScheduleType.everyDay:
        return 'Every Calendar Day (എല്ലാ ദിവസവും)';
      case RentScheduleType.operatingDaysOnly:
        return 'Operating Days Only (പ്രവർത്തി ദിവസങ്ങളിൽ മാത്രം)';
    }
  }

  static RentScheduleType fromCode(dynamic code) {
    if (code?.toString().toUpperCase() == 'OPERATING_DAYS_ONLY') {
      return RentScheduleType.operatingDaysOnly;
    }
    return RentScheduleType.everyDay;
  }
}

class RentRateHistoryItem {
  final DateTime effectiveDate;
  final double amount;
  final int amountPaise;
  final String changedByUid;
  final String changedByName;
  final DateTime changedAt;

  const RentRateHistoryItem({
    required this.effectiveDate,
    required this.amount,
    required this.amountPaise,
    required this.changedByUid,
    this.changedByName = '',
    required this.changedAt,
  });

  Map<String, dynamic> toMap() => {
        'effectiveDate': effectiveDate.toIso8601String(),
        'amount': amount,
        'amountPaise': amountPaise,
        'changedByUid': changedByUid,
        'changedByName': changedByName,
        'changedAt': changedAt.toIso8601String(),
      };

  factory RentRateHistoryItem.fromMap(Map<String, dynamic> map) {
    DateTime parseDt(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v) ?? DateTime.now();
      return DateTime.now();
    }

    final amt = (map['amount'] as num?)?.toDouble() ??
        (((map['amountPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final paise = (map['amountPaise'] as num?)?.toInt() ?? (amt * 100).round();

    return RentRateHistoryItem(
      effectiveDate: parseDt(map['effectiveDate']),
      amount: amt,
      amountPaise: paise,
      changedByUid: map['changedByUid']?.toString() ?? '',
      changedByName: map['changedByName']?.toString() ?? '',
      changedAt: parseDt(map['changedAt']),
    );
  }
}

class DailyRentSettings {
  final double dailyRentAmount;
  final int dailyRentAmountPaise;
  final String currency;
  final String landlordName;
  final String defaultPaymentMode; // CASH or BANK
  final DateTime effectiveDate;
  final RentScheduleType scheduleType;
  final bool isActive;
  final List<int> operatingDays; // 1 = Mon ... 7 = Sun
  final String notes;
  final List<RentRateHistoryItem> rateHistory;

  const DailyRentSettings({
    this.dailyRentAmount = 300.0,
    this.dailyRentAmountPaise = 30000,
    this.currency = 'INR',
    this.landlordName = '',
    this.defaultPaymentMode = ExpensePaymentMode.cash,
    required this.effectiveDate,
    this.scheduleType = RentScheduleType.everyDay,
    this.isActive = true,
    this.operatingDays = const [1, 2, 3, 4, 5, 6, 7],
    this.notes = '',
    this.rateHistory = const [],
  });

  /// Derives the effective rent rate applicable for any specific date
  /// by evaluating rate history entries in chronological order.
  double getRentForDate(DateTime date) {
    if (!isActive) return 0.0;
    final target = DateTime(date.year, date.month, date.day);
    final eff =
        DateTime(effectiveDate.year, effectiveDate.month, effectiveDate.day);

    // If on or after the current effective date, use the current active rate
    if (!target.isBefore(eff)) {
      return dailyRentAmount;
    }

    // Target is prior to current effective date: look through chronological rate history
    final sorted = List<RentRateHistoryItem>.from(rateHistory)
      ..sort((a, b) => b.effectiveDate.compareTo(a.effectiveDate));

    for (final h in sorted) {
      final hDate = DateTime(
          h.effectiveDate.year, h.effectiveDate.month, h.effectiveDate.day);
      if (!target.isBefore(hDate)) {
        return h.amount;
      }
    }

    return 0.0;
  }

  /// Determines if rent is scheduled/expected for the given business date
  bool isScheduledForDate(DateTime date) {
    if (!isActive) return false;
    final target = DateTime(date.year, date.month, date.day);
    final eff =
        DateTime(effectiveDate.year, effectiveDate.month, effectiveDate.day);
    if (target.isBefore(eff)) return false;

    if (scheduleType == RentScheduleType.operatingDaysOnly) {
      return operatingDays.contains(date.weekday);
    }
    return true;
  }

  DailyRentSettings copyWith({
    double? dailyRentAmount,
    int? dailyRentAmountPaise,
    String? currency,
    String? landlordName,
    String? defaultPaymentMode,
    DateTime? effectiveDate,
    RentScheduleType? scheduleType,
    bool? isActive,
    List<int>? operatingDays,
    String? notes,
    List<RentRateHistoryItem>? rateHistory,
  }) {
    return DailyRentSettings(
      dailyRentAmount: dailyRentAmount ?? this.dailyRentAmount,
      dailyRentAmountPaise: dailyRentAmountPaise ?? this.dailyRentAmountPaise,
      currency: currency ?? this.currency,
      landlordName: landlordName ?? this.landlordName,
      defaultPaymentMode: defaultPaymentMode ?? this.defaultPaymentMode,
      effectiveDate: effectiveDate ?? this.effectiveDate,
      scheduleType: scheduleType ?? this.scheduleType,
      isActive: isActive ?? this.isActive,
      operatingDays: operatingDays ?? this.operatingDays,
      notes: notes ?? this.notes,
      rateHistory: rateHistory ?? this.rateHistory,
    );
  }

  Map<String, dynamic> toMap() => {
        'dailyRentAmount': dailyRentAmount,
        'dailyRentAmountPaise': dailyRentAmountPaise,
        'currency': currency,
        'landlordName': landlordName,
        'defaultPaymentMode': defaultPaymentMode,
        'effectiveDate': effectiveDate.toIso8601String(),
        'scheduleType': scheduleType.code,
        'isActive': isActive,
        'operatingDays': operatingDays,
        'notes': notes,
        'rateHistory': rateHistory.map((h) => h.toMap()).toList(),
      };

  factory DailyRentSettings.fromMap(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) {
      return DailyRentSettings(effectiveDate: DateTime(2026, 1, 1));
    }

    DateTime parseDt(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v) ?? DateTime(2026, 1, 1);
      return DateTime(2026, 1, 1);
    }

    final double amt = (map['dailyRentAmount'] as num?)?.toDouble() ??
        (((map['dailyRentAmountPaise'] as num?)?.toDouble() ?? 30000.0) /
            100.0);
    final int paise =
        (map['dailyRentAmountPaise'] as num?)?.toInt() ?? (amt * 100).round();

    final List<RentRateHistoryItem> hist = [];
    if (map['rateHistory'] is List) {
      for (final it in (map['rateHistory'] as List)) {
        if (it is Map) {
          hist.add(RentRateHistoryItem.fromMap(Map<String, dynamic>.from(it)));
        }
      }
    }

    final List<int> opDays = (map['operatingDays'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        [1, 2, 3, 4, 5, 6, 7];

    return DailyRentSettings(
      dailyRentAmount: amt,
      dailyRentAmountPaise: paise,
      currency: map['currency']?.toString() ?? 'INR',
      landlordName: map['landlordName']?.toString() ?? '',
      defaultPaymentMode:
          map['defaultPaymentMode']?.toString() ?? ExpensePaymentMode.cash,
      effectiveDate: parseDt(map['effectiveDate']),
      scheduleType: RentScheduleType.fromCode(map['scheduleType']),
      isActive: map['isActive'] != false,
      operatingDays: opDays,
      notes: map['notes']?.toString() ?? '',
      rateHistory: hist,
    );
  }
}

class DailyRentRecord {
  final String dateKey; // YYYY-MM-DD (Deterministic key per shop date)
  final String shopId;
  final DateTime date;
  final double expectedRent;
  final int expectedRentPaise;
  final double paidAmount;
  final int paidAmountPaise;
  final String paymentMode; // CASH or BANK
  final String status; // PAID, PENDING, VOIDED, SKIPPED, NOT_SCHEDULED
  final String landlordName;
  final String paymentReference; // UPI ID or Ref No
  final String? receiptUrl;
  final String notes;
  final String recordedByUid;
  final String recordedByName;
  final DateTime? recordedAt;
  final String? expenseId; // Linked document in shops/{shopId}/expenses/
  final String?
      accountingTransactionId; // Linked document in shops/{shopId}/accounting_cash_bank/
  final bool isVoided;
  final DateTime? voidedAt;
  final String? voidedByUid;
  final String? voidedByName;
  final String? voidReason;
  final List<Map<String, dynamic>> auditHistory;

  const DailyRentRecord({
    required this.dateKey,
    required this.shopId,
    required this.date,
    required this.expectedRent,
    required this.expectedRentPaise,
    required this.paidAmount,
    required this.paidAmountPaise,
    required this.paymentMode,
    required this.status,
    this.landlordName = '',
    this.paymentReference = '',
    this.receiptUrl,
    this.notes = '',
    required this.recordedByUid,
    required this.recordedByName,
    this.recordedAt,
    this.expenseId,
    this.accountingTransactionId,
    this.isVoided = false,
    this.voidedAt,
    this.voidedByUid,
    this.voidedByName,
    this.voidReason,
    this.auditHistory = const [],
  });

  bool get isPaid => status == 'PAID' && !isVoided;
  bool get isCash => paymentMode.toUpperCase() == ExpensePaymentMode.cash;
  bool get isBank => paymentMode.toUpperCase() == ExpensePaymentMode.bank;

  DailyRentRecord copyWith({
    String? status,
    double? paidAmount,
    int? paidAmountPaise,
    String? paymentMode,
    String? landlordName,
    String? paymentReference,
    String? receiptUrl,
    String? notes,
    String? recordedByUid,
    String? recordedByName,
    DateTime? recordedAt,
    String? expenseId,
    String? accountingTransactionId,
    bool? isVoided,
    DateTime? voidedAt,
    String? voidedByUid,
    String? voidedByName,
    String? voidReason,
    List<Map<String, dynamic>>? auditHistory,
  }) {
    return DailyRentRecord(
      dateKey: dateKey,
      shopId: shopId,
      date: date,
      expectedRent: expectedRent,
      expectedRentPaise: expectedRentPaise,
      paidAmount: paidAmount ?? this.paidAmount,
      paidAmountPaise: paidAmountPaise ?? this.paidAmountPaise,
      paymentMode: paymentMode ?? this.paymentMode,
      status: status ?? this.status,
      landlordName: landlordName ?? this.landlordName,
      paymentReference: paymentReference ?? this.paymentReference,
      receiptUrl: receiptUrl ?? this.receiptUrl,
      notes: notes ?? this.notes,
      recordedByUid: recordedByUid ?? this.recordedByUid,
      recordedByName: recordedByName ?? this.recordedByName,
      recordedAt: recordedAt ?? this.recordedAt,
      expenseId: expenseId ?? this.expenseId,
      accountingTransactionId:
          accountingTransactionId ?? this.accountingTransactionId,
      isVoided: isVoided ?? this.isVoided,
      voidedAt: voidedAt ?? this.voidedAt,
      voidedByUid: voidedByUid ?? this.voidedByUid,
      voidedByName: voidedByName ?? this.voidedByName,
      voidReason: voidReason ?? this.voidReason,
      auditHistory: auditHistory ?? this.auditHistory,
    );
  }

  Map<String, dynamic> toMap({bool forFirestore = false}) => {
        'dateKey': dateKey,
        'shopId': shopId,
        'date':
            forFirestore ? Timestamp.fromDate(date) : date.toIso8601String(),
        'expectedRent': expectedRent,
        'expectedRentPaise': expectedRentPaise,
        'paidAmount': paidAmount,
        'paidAmountPaise': paidAmountPaise,
        'paymentMode': paymentMode,
        'status': status,
        'landlordName': landlordName,
        'paymentReference': paymentReference,
        'receiptUrl': receiptUrl,
        'notes': notes,
        'recordedByUid': recordedByUid,
        'recordedByName': recordedByName,
        'recordedAt': recordedAt != null
            ? (forFirestore
                ? Timestamp.fromDate(recordedAt!)
                : recordedAt!.toIso8601String())
            : (forFirestore
                ? FieldValue.serverTimestamp()
                : DateTime.now().toIso8601String()),
        'expenseId': expenseId,
        'accountingTransactionId': accountingTransactionId,
        'isVoided': isVoided,
        'voidedAt': voidedAt != null
            ? (forFirestore
                ? Timestamp.fromDate(voidedAt!)
                : voidedAt!.toIso8601String())
            : null,
        'voidedByUid': voidedByUid,
        'voidedByName': voidedByName,
        'voidReason': voidReason,
        'auditHistory': auditHistory,
        'isDailyRent': true,
        'category': 'DAILY_RENT',
      };

  factory DailyRentRecord.fromMap(Map<String, dynamic> map, String key) {
    DateTime parseDt(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v) ?? DateTime.now();
      return DateTime.now();
    }

    final double expected = (map['expectedRent'] as num?)?.toDouble() ??
        (((map['expectedRentPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final int expPaise =
        (map['expectedRentPaise'] as num?)?.toInt() ?? (expected * 100).round();

    final double paid = (map['paidAmount'] as num?)?.toDouble() ??
        (((map['paidAmountPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final int pdPaise =
        (map['paidAmountPaise'] as num?)?.toInt() ?? (paid * 100).round();

    List<Map<String, dynamic>> hist = [];
    if (map['auditHistory'] is List) {
      for (final h in (map['auditHistory'] as List)) {
        if (h is Map) hist.add(Map<String, dynamic>.from(h));
      }
    }

    return DailyRentRecord(
      dateKey: map['dateKey']?.toString() ?? key,
      shopId: map['shopId']?.toString() ?? '',
      date: parseDt(map['date']),
      expectedRent: expected,
      expectedRentPaise: expPaise,
      paidAmount: paid,
      paidAmountPaise: pdPaise,
      paymentMode: map['paymentMode']?.toString() ?? ExpensePaymentMode.cash,
      status: map['status']?.toString() ?? (paid > 0 ? 'PAID' : 'PENDING'),
      landlordName: map['landlordName']?.toString() ?? '',
      paymentReference: map['paymentReference']?.toString() ?? '',
      receiptUrl: map['receiptUrl']?.toString(),
      notes: map['notes']?.toString() ?? '',
      recordedByUid: map['recordedByUid']?.toString() ?? '',
      recordedByName: map['recordedByName']?.toString() ?? '',
      recordedAt: map['recordedAt'] != null ? parseDt(map['recordedAt']) : null,
      expenseId: map['expenseId']?.toString(),
      accountingTransactionId: map['accountingTransactionId']?.toString(),
      isVoided: map['isVoided'] == true,
      voidedAt: map['voidedAt'] != null ? parseDt(map['voidedAt']) : null,
      voidedByUid: map['voidedByUid']?.toString(),
      voidedByName: map['voidedByName']?.toString(),
      voidReason: map['voidReason']?.toString(),
      auditHistory: hist,
    );
  }
}

class DailyRentMetrics {
  final double todayExpected;
  final double todayPaid;
  final String todayStatus;
  final String todayPaymentMode;
  final double monthTotalPaid;
  final int monthPaidDays;
  final int monthUnpaidDays;
  final double monthTotalOutstanding;

  const DailyRentMetrics({
    required this.todayExpected,
    required this.todayPaid,
    required this.todayStatus,
    required this.todayPaymentMode,
    required this.monthTotalPaid,
    required this.monthPaidDays,
    required this.monthUnpaidDays,
    required this.monthTotalOutstanding,
  });

  factory DailyRentMetrics.empty() => const DailyRentMetrics(
        todayExpected: 0.0,
        todayPaid: 0.0,
        todayStatus: 'PENDING',
        todayPaymentMode: ExpensePaymentMode.cash,
        monthTotalPaid: 0.0,
        monthPaidDays: 0,
        monthUnpaidDays: 0,
        monthTotalOutstanding: 0.0,
      );
}
