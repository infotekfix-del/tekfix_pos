class CategorySalesSummary {
  final String category;
  final int units;
  final double totalAmount;

  const CategorySalesSummary({
    required this.category,
    required this.units,
    required this.totalAmount,
  });

  Map<String, dynamic> toMap() => {
        'category': category,
        'units': units,
        'totalAmount': totalAmount,
        'totalAmountPaise': (totalAmount * 100).round(),
      };

  factory CategorySalesSummary.fromMap(Map<String, dynamic> map) {
    return CategorySalesSummary(
      category: map['category']?.toString() ?? 'Others',
      units: (map['units'] as num?)?.toInt() ?? 0,
      totalAmount: (map['totalAmount'] as num?)?.toDouble() ??
          (((map['totalAmountPaise'] as num?)?.toDouble() ?? 0.0) / 100.0),
    );
  }
}

class TopProductSummary {
  final String name;
  final int qty;
  final double totalAmount;

  const TopProductSummary({
    required this.name,
    required this.qty,
    required this.totalAmount,
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'qty': qty,
        'totalAmount': totalAmount,
        'totalAmountPaise': (totalAmount * 100).round(),
      };

  factory TopProductSummary.fromMap(Map<String, dynamic> map) {
    return TopProductSummary(
      name: map['name']?.toString() ?? '',
      qty: (map['qty'] as num?)?.toInt() ?? 0,
      totalAmount: (map['totalAmount'] as num?)?.toDouble() ??
          (((map['totalAmountPaise'] as num?)?.toDouble() ?? 0.0) / 100.0),
    );
  }
}

class DailyRegisterSummary {
  final String dateString;
  final DateTime date;
  final String openingTime;
  final String closingTime;
  final int totalOrdersCount;
  final double grossSales;
  final double totalDiscounts;
  final double netRevenue;
  final double totalCash;
  final double totalUpi;
  final double totalCard;
  final double totalDue;
  final double openingCash;
  final double refunds;
  final double totalCashExpenses;
  final double totalBankExpenses;
  final double cashRentPaid;
  final double bankRentPaid;
  final bool rentPendingWarning;
  final double ownerSalaryDrawnToday;
  final double ownerExcessDrawingsToday;
  final double ownerCashSalaryDrawn;
  final double ownerCashDrawingsDrawn;
  final double ownerBankSalaryDrawn;
  final double ownerBankDrawingsDrawn;
  final double physicalCashCount;
  final double cashDiscrepancy;
  final Map<String, CategorySalesSummary> categoryBreakdown;
  final List<TopProductSummary> topSellingProducts;
  final String closedByStaffId;
  final String closedByStaffName;
  final DateTime? closedAt;
  final bool isClosed;
  final String notes;

  const DailyRegisterSummary({
    required this.dateString,
    required this.date,
    this.openingTime = '08:30 AM',
    this.closingTime = '10:00 PM',
    required this.totalOrdersCount,
    required this.grossSales,
    required this.totalDiscounts,
    required this.netRevenue,
    required this.totalCash,
    required this.totalUpi,
    required this.totalCard,
    required this.totalDue,
    this.openingCash = 0.0,
    this.refunds = 0.0,
    this.totalCashExpenses = 0.0,
    this.totalBankExpenses = 0.0,
    this.cashRentPaid = 0.0,
    this.bankRentPaid = 0.0,
    this.rentPendingWarning = false,
    this.ownerSalaryDrawnToday = 0.0,
    this.ownerExcessDrawingsToday = 0.0,
    this.ownerCashSalaryDrawn = 0.0,
    this.ownerCashDrawingsDrawn = 0.0,
    this.ownerBankSalaryDrawn = 0.0,
    this.ownerBankDrawingsDrawn = 0.0,
    this.physicalCashCount = 0.0,
    this.cashDiscrepancy = 0.0,
    this.categoryBreakdown = const {},
    this.topSellingProducts = const [],
    this.closedByStaffId = '',
    this.closedByStaffName = '',
    this.closedAt,
    this.isClosed = false,
    this.notes = '',
  });

  int get grossSalesPaise => (grossSales * 100).round();
  int get totalDiscountsPaise => (totalDiscounts * 100).round();
  int get netRevenuePaise => (netRevenue * 100).round();
  int get totalCashPaise => (totalCash * 100).round();
  int get totalUpiPaise => (totalUpi * 100).round();
  int get totalCardPaise => (totalCard * 100).round();
  int get totalCreditPaise => (totalDue * 100).round();
  int get totalCashExpensesPaise => (totalCashExpenses * 100).round();
  int get totalBankExpensesPaise => (totalBankExpenses * 100).round();
  int get cashRentPaidPaise => (cashRentPaid * 100).round();
  int get bankRentPaidPaise => (bankRentPaid * 100).round();
  int get ownerSalaryDrawnPaise => (ownerSalaryDrawnToday * 100).round();
  int get ownerExcessDrawingsPaise => (ownerExcessDrawingsToday * 100).round();
  int get physicalCashPaise => (physicalCashCount * 100).round();
  int get cashDiscrepancyPaise => (cashDiscrepancy * 100).round();

  // Convenience metric getters for EOD closing reports
  double get netSales => netRevenue;
  double get cashCollection => totalCash;
  double get upiCollection => totalUpi;
  double get cardCollection => totalCard;
  double get creditSales => totalDue;
  double get actualCashCount => physicalCashCount;
  double get otherCashExpenses =>
      (totalCashExpenses - cashRentPaid - ownerCashSalaryDrawn).clamp(0.0, double.infinity);
  double get totalCashOutflows =>
      cashRentPaid + otherCashExpenses + ownerCashSalaryDrawn + ownerCashDrawingsDrawn + refunds;
  double get expectedClosingCash =>
      (openingCash + totalCash - refunds - totalCashExpenses - ownerCashDrawingsDrawn)
          .clamp(0.0, double.infinity);
  double get cashOverOrShort => physicalCashCount - expectedClosingCash;
  String get closedBy => closedByStaffName.isNotEmpty
      ? closedByStaffName
      : (closedByStaffId.isNotEmpty ? closedByStaffId : 'Staff');

  DailyRegisterSummary copyWith({
    String? openingTime,
    String? closingTime,
    double? openingCash,
    double? refunds,
    double? totalCashExpenses,
    double? totalBankExpenses,
    double? cashRentPaid,
    double? bankRentPaid,
    bool? rentPendingWarning,
    double? ownerSalaryDrawnToday,
    double? ownerExcessDrawingsToday,
    double? ownerCashSalaryDrawn,
    double? ownerCashDrawingsDrawn,
    double? ownerBankSalaryDrawn,
    double? ownerBankDrawingsDrawn,
    double? physicalCashCount,
    double? cashDiscrepancy,
    String? closedByStaffId,
    String? closedByStaffName,
    DateTime? closedAt,
    bool? isClosed,
    String? notes,
  }) {
    return DailyRegisterSummary(
      dateString: dateString,
      date: date,
      openingTime: openingTime ?? this.openingTime,
      closingTime: closingTime ?? this.closingTime,
      totalOrdersCount: totalOrdersCount,
      grossSales: grossSales,
      totalDiscounts: totalDiscounts,
      netRevenue: netRevenue,
      totalCash: totalCash,
      totalUpi: totalUpi,
      totalCard: totalCard,
      totalDue: totalDue,
      openingCash: openingCash ?? this.openingCash,
      refunds: refunds ?? this.refunds,
      totalCashExpenses: totalCashExpenses ?? this.totalCashExpenses,
      totalBankExpenses: totalBankExpenses ?? this.totalBankExpenses,
      cashRentPaid: cashRentPaid ?? this.cashRentPaid,
      bankRentPaid: bankRentPaid ?? this.bankRentPaid,
      rentPendingWarning: rentPendingWarning ?? this.rentPendingWarning,
      ownerSalaryDrawnToday: ownerSalaryDrawnToday ?? this.ownerSalaryDrawnToday,
      ownerExcessDrawingsToday: ownerExcessDrawingsToday ?? this.ownerExcessDrawingsToday,
      ownerCashSalaryDrawn: ownerCashSalaryDrawn ?? this.ownerCashSalaryDrawn,
      ownerCashDrawingsDrawn: ownerCashDrawingsDrawn ?? this.ownerCashDrawingsDrawn,
      ownerBankSalaryDrawn: ownerBankSalaryDrawn ?? this.ownerBankSalaryDrawn,
      ownerBankDrawingsDrawn: ownerBankDrawingsDrawn ?? this.ownerBankDrawingsDrawn,
      physicalCashCount: physicalCashCount ?? this.physicalCashCount,
      cashDiscrepancy: cashDiscrepancy ?? this.cashDiscrepancy,
      categoryBreakdown: categoryBreakdown,
      topSellingProducts: topSellingProducts,
      closedByStaffId: closedByStaffId ?? this.closedByStaffId,
      closedByStaffName: closedByStaffName ?? this.closedByStaffName,
      closedAt: closedAt ?? this.closedAt,
      isClosed: isClosed ?? this.isClosed,
      notes: notes ?? this.notes,
    );
  }

  Map<String, dynamic> toMap() => {
        'dateString': dateString,
        'date': date.toIso8601String(),
        'openingTime': openingTime,
        'closingTime': closingTime,
        'totalOrdersCount': totalOrdersCount,
        'grossSales': grossSales,
        'grossSalesPaise': grossSalesPaise,
        'totalDiscounts': totalDiscounts,
        'totalDiscountsPaise': totalDiscountsPaise,
        'netRevenue': netRevenue,
        'netRevenuePaise': netRevenuePaise,
        'totalCash': totalCash,
        'totalCashPaise': totalCashPaise,
        'totalUpi': totalUpi,
        'totalUpiPaise': totalUpiPaise,
        'totalCard': totalCard,
        'totalCardPaise': totalCardPaise,
        'totalDue': totalDue,
        'totalCreditPaise': totalCreditPaise,
        'openingCash': openingCash,
        'refunds': refunds,
        'totalCashExpenses': totalCashExpenses,
        'totalCashExpensesPaise': totalCashExpensesPaise,
        'totalBankExpenses': totalBankExpenses,
        'totalBankExpensesPaise': totalBankExpensesPaise,
        'cashRentPaid': cashRentPaid,
        'cashRentPaidPaise': cashRentPaidPaise,
        'bankRentPaid': bankRentPaid,
        'bankRentPaidPaise': bankRentPaidPaise,
        'rentPendingWarning': rentPendingWarning,
        'ownerSalaryDrawnToday': ownerSalaryDrawnToday,
        'ownerSalaryDrawnPaise': ownerSalaryDrawnPaise,
        'ownerExcessDrawingsToday': ownerExcessDrawingsToday,
        'ownerExcessDrawingsPaise': ownerExcessDrawingsPaise,
        'ownerCashSalaryDrawn': ownerCashSalaryDrawn,
        'ownerCashDrawingsDrawn': ownerCashDrawingsDrawn,
        'ownerBankSalaryDrawn': ownerBankSalaryDrawn,
        'ownerBankDrawingsDrawn': ownerBankDrawingsDrawn,
        'physicalCashCount': physicalCashCount,
        'physicalCashPaise': physicalCashPaise,
        'cashDiscrepancy': cashDiscrepancy,
        'cashDiscrepancyPaise': cashDiscrepancyPaise,
        'categoryBreakdown': categoryBreakdown.map((k, v) => MapEntry(k, v.toMap())),
        'topSellingProducts': topSellingProducts.map((p) => p.toMap()).toList(),
        'closedByStaffId': closedByStaffId,
        'closedByStaffName': closedByStaffName,
        'closedAt': closedAt?.toIso8601String(),
        'isClosed': isClosed,
        'notes': notes,
      };

  factory DailyRegisterSummary.fromMap(Map<String, dynamic> map) {
    final dStr = map['dateString']?.toString() ?? '';
    final dt = map['date'] != null
        ? DateTime.tryParse(map['date'].toString()) ?? DateTime.now()
        : DateTime.now();

    final cats = <String, CategorySalesSummary>{};
    if (map['categoryBreakdown'] is Map) {
      (map['categoryBreakdown'] as Map).forEach((k, v) {
        if (v is Map) {
          cats[k.toString()] =
              CategorySalesSummary.fromMap(Map<String, dynamic>.from(v));
        }
      });
    }

    final top = <TopProductSummary>[];
    if (map['topSellingProducts'] is List) {
      for (final it in (map['topSellingProducts'] as List)) {
        if (it is Map) {
          top.add(TopProductSummary.fromMap(Map<String, dynamic>.from(it)));
        }
      }
    }

    final double gross = (map['grossSales'] as num?)?.toDouble() ??
        (((map['grossSalesPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double net = (map['netRevenue'] as num?)?.toDouble() ??
        (((map['netRevenuePaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double cash = (map['totalCash'] as num?)?.toDouble() ??
        (((map['totalCashPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double upi = (map['totalUpi'] as num?)?.toDouble() ??
        (((map['totalUpiPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double card = (map['totalCard'] as num?)?.toDouble() ??
        (((map['totalCardPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double due = (map['totalDue'] as num?)?.toDouble() ??
        (((map['totalCreditPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double physical = (map['physicalCashCount'] as num?)?.toDouble() ??
        (((map['physicalCashPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double discrepancy = (map['cashDiscrepancy'] as num?)?.toDouble() ??
        (((map['cashDiscrepancyPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double openCash = (map['openingCash'] as num?)?.toDouble() ?? 0.0;
    final double ref = (map['refunds'] as num?)?.toDouble() ?? 0.0;
    final double cashExp = (map['totalCashExpenses'] as num?)?.toDouble() ??
        (((map['totalCashExpensesPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double bankExp = (map['totalBankExpenses'] as num?)?.toDouble() ??
        (((map['totalBankExpensesPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double cashRent = (map['cashRentPaid'] as num?)?.toDouble() ??
        (((map['cashRentPaidPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double bankRent = (map['bankRentPaid'] as num?)?.toDouble() ??
        (((map['bankRentPaidPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);

    final double ownSal = (map['ownerSalaryDrawnToday'] as num?)?.toDouble() ??
        (((map['ownerSalaryDrawnPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double ownDraw = (map['ownerExcessDrawingsToday'] as num?)?.toDouble() ??
        (((map['ownerExcessDrawingsPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double ownCashSal = (map['ownerCashSalaryDrawn'] as num?)?.toDouble() ?? 0.0;
    final double ownCashDraw = (map['ownerCashDrawingsDrawn'] as num?)?.toDouble() ?? 0.0;
    final double ownBankSal = (map['ownerBankSalaryDrawn'] as num?)?.toDouble() ?? 0.0;
    final double ownBankDraw = (map['ownerBankDrawingsDrawn'] as num?)?.toDouble() ?? 0.0;

    return DailyRegisterSummary(
      dateString: dStr,
      date: dt,
      openingTime: map['openingTime']?.toString() ?? '08:30 AM',
      closingTime: map['closingTime']?.toString() ?? '10:00 PM',
      totalOrdersCount: (map['totalOrdersCount'] as num?)?.toInt() ?? 0,
      grossSales: gross,
      totalDiscounts: (map['totalDiscounts'] as num?)?.toDouble() ??
          (((map['totalDiscountsPaise'] as num?)?.toDouble() ?? 0.0) / 100.0),
      netRevenue: net,
      totalCash: cash,
      totalUpi: upi,
      totalCard: card,
      totalDue: due,
      openingCash: openCash,
      refunds: ref,
      totalCashExpenses: cashExp,
      totalBankExpenses: bankExp,
      cashRentPaid: cashRent,
      bankRentPaid: bankRent,
      rentPendingWarning: map['rentPendingWarning'] == true,
      ownerSalaryDrawnToday: ownSal,
      ownerExcessDrawingsToday: ownDraw,
      ownerCashSalaryDrawn: ownCashSal,
      ownerCashDrawingsDrawn: ownCashDraw,
      ownerBankSalaryDrawn: ownBankSal,
      ownerBankDrawingsDrawn: ownBankDraw,
      physicalCashCount: physical,
      cashDiscrepancy: discrepancy,
      categoryBreakdown: cats,
      topSellingProducts: top,
      closedByStaffId: map['closedByStaffId']?.toString() ?? '',
      closedByStaffName: map['closedByStaffName']?.toString() ?? '',
      closedAt: map['closedAt'] != null
          ? DateTime.tryParse(map['closedAt'].toString())
          : null,
      isClosed: map['isClosed'] == true,
      notes: map['notes']?.toString() ?? '',
    );
  }
}

