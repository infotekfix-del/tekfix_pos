import 'package:cloud_firestore/cloud_firestore.dart';

class OwnerSalarySettings {
  final double monthlySalaryLimit;
  final int monthlySalaryLimitPaise;
  final String ownerName;
  final String ownerUid;
  final DateTime effectiveDate;
  final bool isActive;
  final List<OwnerSalaryRateHistoryItem> rateHistory;

  const OwnerSalarySettings({
    this.monthlySalaryLimit = 20000.0,
    this.monthlySalaryLimitPaise = 2000000,
    this.ownerName = 'Shop Owner',
    this.ownerUid = '',
    required this.effectiveDate,
    this.isActive = true,
    this.rateHistory = const [],
  });

  OwnerSalarySettings copyWith({
    double? monthlySalaryLimit,
    int? monthlySalaryLimitPaise,
    String? ownerName,
    String? ownerUid,
    DateTime? effectiveDate,
    bool? isActive,
    List<OwnerSalaryRateHistoryItem>? rateHistory,
  }) {
    return OwnerSalarySettings(
      monthlySalaryLimit: monthlySalaryLimit ?? this.monthlySalaryLimit,
      monthlySalaryLimitPaise: monthlySalaryLimitPaise ?? this.monthlySalaryLimitPaise,
      ownerName: ownerName ?? this.ownerName,
      ownerUid: ownerUid ?? this.ownerUid,
      effectiveDate: effectiveDate ?? this.effectiveDate,
      isActive: isActive ?? this.isActive,
      rateHistory: rateHistory ?? this.rateHistory,
    );
  }

  Map<String, dynamic> toMap() => {
        'monthlySalaryLimit': monthlySalaryLimit,
        'monthlySalaryLimitPaise': monthlySalaryLimitPaise,
        'ownerName': ownerName,
        'ownerUid': ownerUid,
        'effectiveDate': effectiveDate.toIso8601String(),
        'isActive': isActive,
        'rateHistory': rateHistory.map((h) => h.toMap()).toList(),
      };

  factory OwnerSalarySettings.fromMap(Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) {
      return OwnerSalarySettings(effectiveDate: DateTime(2026, 1, 1));
    }

    DateTime parseDt(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v) ?? DateTime(2026, 1, 1);
      return DateTime(2026, 1, 1);
    }

    final amt = (map['monthlySalaryLimit'] as num?)?.toDouble() ??
        (((map['monthlySalaryLimitPaise'] as num?)?.toDouble() ?? 2000000.0) / 100.0);
    final paise = (map['monthlySalaryLimitPaise'] as num?)?.toInt() ?? (amt * 100).round();

    final List<OwnerSalaryRateHistoryItem> hist = [];
    if (map['rateHistory'] is List) {
      for (final it in (map['rateHistory'] as List)) {
        if (it is Map) {
          hist.add(OwnerSalaryRateHistoryItem.fromMap(Map<String, dynamic>.from(it)));
        }
      }
    }

    return OwnerSalarySettings(
      monthlySalaryLimit: amt,
      monthlySalaryLimitPaise: paise,
      ownerName: map['ownerName']?.toString() ?? 'Shop Owner',
      ownerUid: map['ownerUid']?.toString() ?? '',
      effectiveDate: parseDt(map['effectiveDate']),
      isActive: map['isActive'] != false,
      rateHistory: hist,
    );
  }
}

class OwnerSalaryRateHistoryItem {
  final DateTime effectiveDate;
  final double limitAmount;
  final int limitAmountPaise;
  final String changedByUid;
  final String changedByName;
  final DateTime changedAt;

  const OwnerSalaryRateHistoryItem({
    required this.effectiveDate,
    required this.limitAmount,
    required this.limitAmountPaise,
    required this.changedByUid,
    this.changedByName = '',
    required this.changedAt,
  });

  Map<String, dynamic> toMap() => {
        'effectiveDate': effectiveDate.toIso8601String(),
        'limitAmount': limitAmount,
        'limitAmountPaise': limitAmountPaise,
        'changedByUid': changedByUid,
        'changedByName': changedByName,
        'changedAt': changedAt.toIso8601String(),
      };

  factory OwnerSalaryRateHistoryItem.fromMap(Map<String, dynamic> map) {
    DateTime parseDt(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v) ?? DateTime.now();
      return DateTime.now();
    }

    final amt = (map['limitAmount'] as num?)?.toDouble() ?? 0.0;
    final paise = (map['limitAmountPaise'] as num?)?.toInt() ?? (amt * 100).round();

    return OwnerSalaryRateHistoryItem(
      effectiveDate: parseDt(map['effectiveDate']),
      limitAmount: amt,
      limitAmountPaise: paise,
      changedByUid: map['changedByUid']?.toString() ?? '',
      changedByName: map['changedByName']?.toString() ?? '',
      changedAt: parseDt(map['changedAt']),
    );
  }
}

class OwnerWithdrawalItem {
  final String id;
  final String shopId;
  final DateTime date;
  final String dateKey; // YYYY-MM-DD
  final double totalAmount;
  final int totalAmountPaise;
  final double salaryPortion;
  final int salaryPortionPaise;
  final double drawingsPortion;
  final int drawingsPortionPaise;
  final String paymentMode; // CASH or BANK
  final String recordedByUid;
  final String recordedByName;
  final String notes;
  final bool isVoided;
  final DateTime? voidedAt;
  final String? voidedByUid;
  final String? voidedByName;
  final String? voidReason;
  final String? expenseId; // Linked OPEX expense ID for salary portion
  final String? ledgerTxId;
  final DateTime createdAt;

  const OwnerWithdrawalItem({
    required this.id,
    required this.shopId,
    required this.date,
    required this.dateKey,
    required this.totalAmount,
    required this.totalAmountPaise,
    required this.salaryPortion,
    required this.salaryPortionPaise,
    required this.drawingsPortion,
    required this.drawingsPortionPaise,
    required this.paymentMode,
    required this.recordedByUid,
    this.recordedByName = 'Owner',
    this.notes = '',
    this.isVoided = false,
    this.voidedAt,
    this.voidedByUid,
    this.voidedByName,
    this.voidReason,
    this.expenseId,
    this.ledgerTxId,
    required this.createdAt,
  });

  bool get isCash => paymentMode.toUpperCase() == 'CASH';
  bool get isBank => paymentMode.toUpperCase() == 'BANK';
  bool get isSplit => salaryPortion > 0 && drawingsPortion > 0;
  bool get hasSalary => salaryPortion > 0;
  bool get hasDrawings => drawingsPortion > 0;

  OwnerWithdrawalItem copyWith({
    bool? isVoided,
    DateTime? voidedAt,
    String? voidedByUid,
    String? voidedByName,
    String? voidReason,
    String? notes,
  }) {
    return OwnerWithdrawalItem(
      id: id,
      shopId: shopId,
      date: date,
      dateKey: dateKey,
      totalAmount: totalAmount,
      totalAmountPaise: totalAmountPaise,
      salaryPortion: salaryPortion,
      salaryPortionPaise: salaryPortionPaise,
      drawingsPortion: drawingsPortion,
      drawingsPortionPaise: drawingsPortionPaise,
      paymentMode: paymentMode,
      recordedByUid: recordedByUid,
      recordedByName: recordedByName,
      notes: notes ?? this.notes,
      isVoided: isVoided ?? this.isVoided,
      voidedAt: voidedAt ?? this.voidedAt,
      voidedByUid: voidedByUid ?? this.voidedByUid,
      voidedByName: voidedByName ?? this.voidedByName,
      voidReason: voidReason ?? this.voidReason,
      expenseId: expenseId,
      ledgerTxId: ledgerTxId,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toMap({bool forFirestore = false}) => {
        'id': id,
        'shopId': shopId,
        'date': forFirestore ? Timestamp.fromDate(date) : date.toIso8601String(),
        'dateKey': dateKey,
        'totalAmount': totalAmount,
        'totalAmountPaise': totalAmountPaise,
        'salaryPortion': salaryPortion,
        'salaryPortionPaise': salaryPortionPaise,
        'drawingsPortion': drawingsPortion,
        'drawingsPortionPaise': drawingsPortionPaise,
        'paymentMode': paymentMode,
        'recordedByUid': recordedByUid,
        'recordedByName': recordedByName,
        'notes': notes,
        'isVoided': isVoided,
        'voidedAt': voidedAt != null
            ? (forFirestore ? Timestamp.fromDate(voidedAt!) : voidedAt!.toIso8601String())
            : null,
        'voidedByUid': voidedByUid,
        'voidedByName': voidedByName,
        'voidReason': voidReason,
        'expenseId': expenseId,
        'ledgerTxId': ledgerTxId,
        'createdAt': forFirestore ? Timestamp.fromDate(createdAt) : createdAt.toIso8601String(),
      };

  factory OwnerWithdrawalItem.fromMap(Map<String, dynamic> map, String fallbackId) {
    DateTime parseDt(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v) ?? DateTime.now();
      return DateTime.now();
    }

    final totAmt = (map['totalAmount'] as num?)?.toDouble() ??
        (((map['totalAmountPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final totPaise = (map['totalAmountPaise'] as num?)?.toInt() ?? (totAmt * 100).round();

    final salAmt = (map['salaryPortion'] as num?)?.toDouble() ??
        (((map['salaryPortionPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final salPaise = (map['salaryPortionPaise'] as num?)?.toInt() ?? (salAmt * 100).round();

    final drawAmt = (map['drawingsPortion'] as num?)?.toDouble() ??
        (((map['drawingsPortionPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final drawPaise = (map['drawingsPortionPaise'] as num?)?.toInt() ?? (drawAmt * 100).round();

    final dt = parseDt(map['date'] ?? map['createdAt']);
    final dKey = map['dateKey']?.toString() ??
        "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";

    return OwnerWithdrawalItem(
      id: map['id']?.toString() ?? fallbackId,
      shopId: map['shopId']?.toString() ?? '',
      date: dt,
      dateKey: dKey,
      totalAmount: totAmt,
      totalAmountPaise: totPaise,
      salaryPortion: salAmt,
      salaryPortionPaise: salPaise,
      drawingsPortion: drawAmt,
      drawingsPortionPaise: drawPaise,
      paymentMode: (map['paymentMode']?.toString() ?? 'CASH').toUpperCase(),
      recordedByUid: map['recordedByUid']?.toString() ?? '',
      recordedByName: map['recordedByName']?.toString() ?? 'Owner',
      notes: map['notes']?.toString() ?? '',
      isVoided: map['isVoided'] == true,
      voidedAt: map['voidedAt'] != null ? parseDt(map['voidedAt']) : null,
      voidedByUid: map['voidedByUid']?.toString(),
      voidedByName: map['voidedByName']?.toString(),
      voidReason: map['voidReason']?.toString(),
      expenseId: map['expenseId']?.toString(),
      ledgerTxId: map['ledgerTxId']?.toString(),
      createdAt: parseDt(map['createdAt']),
    );
  }
}

class OwnerMonthlyQuotaMetrics {
  final DateTime month;
  final double monthlyLimit;
  final double usedSalaryThisMonth;
  final double remainingSalaryThisMonth;
  final double excessDrawingsThisMonth;
  final double totalWithdrawnThisMonth;
  final int totalWithdrawalsCount;

  const OwnerMonthlyQuotaMetrics({
    required this.month,
    this.monthlyLimit = 20000.0,
    this.usedSalaryThisMonth = 0.0,
    this.remainingSalaryThisMonth = 20000.0,
    this.excessDrawingsThisMonth = 0.0,
    this.totalWithdrawnThisMonth = 0.0,
    this.totalWithdrawalsCount = 0,
  });

  double get quotaPercentage =>
      monthlyLimit > 0 ? (usedSalaryThisMonth / monthlyLimit).clamp(0.0, 1.0) : 1.0;

  bool get isQuotaFull => remainingSalaryThisMonth <= 0;

  factory OwnerMonthlyQuotaMetrics.empty(DateTime month, [double limit = 20000.0]) {
    return OwnerMonthlyQuotaMetrics(
      month: month,
      monthlyLimit: limit,
      usedSalaryThisMonth: 0.0,
      remainingSalaryThisMonth: limit,
      excessDrawingsThisMonth: 0.0,
      totalWithdrawnThisMonth: 0.0,
      totalWithdrawalsCount: 0,
    );
  }
}

class DailyOwnerWithdrawalBreakdown {
  final double cashSalary;
  final double bankSalary;
  final double cashDrawings;
  final double bankDrawings;

  const DailyOwnerWithdrawalBreakdown({
    this.cashSalary = 0.0,
    this.bankSalary = 0.0,
    this.cashDrawings = 0.0,
    this.bankDrawings = 0.0,
  });

  double get totalCash => cashSalary + cashDrawings;
  double get totalBank => bankSalary + bankDrawings;
  double get totalSalary => cashSalary + bankSalary;
  double get totalDrawings => cashDrawings + bankDrawings;
  double get grandTotal => totalCash + totalBank;
}

