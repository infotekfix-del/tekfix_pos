
// ---------------------------------------------------------------------------
// Drawer cash moved outside sales / expenses / recharge (owner rule 2026-11-22)
// ---------------------------------------------------------------------------
const String kCashCatVendor = 'vendor';
const String kCashCatCustomerDue = 'customer_due';
const String kCashCatServiceAdvance = 'service_advance';
const String kCashCatManual = 'manual';
const String kCashCatCommission = 'commission';

/// Category of one cash-log entry (Db.bank 'txn_log'), or null when the
/// Daily Register already counts it elsewhere (sales, expenses, rent, owner
/// drawings, recharge) or it is unknown. Entries saved before categories
/// existed are recognised from their note.
String? cashFlowCategory(Map<dynamic, dynamic> e) {
  final c = e['category'];
  if (c is String && c.isNotEmpty) return c;
  final n = (e['note'] ?? '').toString();
  if (n.startsWith('Purchase Bill ') && n.endsWith(' payment')) return kCashCatVendor;
  if (n.startsWith('Vendor Payment ') || n.startsWith('Vendor Advance Payment')) {
    return kCashCatVendor;
  }
  if (n.startsWith('Purchase Return ') && n.contains(' cash from ')) return kCashCatVendor;
  if (n == 'Purchase removed' || (n.startsWith('Purchase ') && !n.startsWith('Purchase Return'))) {
    return kCashCatVendor;
  }
  if (n.startsWith('Received from ')) return kCashCatCustomerDue;
  if (n.startsWith('Service advance')) return kCashCatServiceAdvance;
  if (n.startsWith('Recharge Commission')) return kCashCatCommission;
  if (n == 'Money received' || n == 'Money paid') return kCashCatManual;
  return null;
}

/// One day's drawer cash from the categories above (rupees, paise-exact).
class OtherCashFlows {
  /// Cash paid to vendors, net of cash refunds received from vendors.
  final double vendorPaid;
  final double customerDuesReceived;
  final double serviceAdvanceReceived;

  /// Manual Money In minus Money Out (can be negative).
  final double manualNet;
  final double commissionCashIn;

  const OtherCashFlows({
    this.vendorPaid = 0.0,
    this.customerDuesReceived = 0.0,
    this.serviceAdvanceReceived = 0.0,
    this.manualNet = 0.0,
    this.commissionCashIn = 0.0,
  });

  static const OtherCashFlows zero = OtherCashFlows();

  /// Net effect on the drawer (+ in, - out).
  double get net =>
      customerDuesReceived + serviceAdvanceReceived + manualNet + commissionCashIn - vendorPaid;

  /// Money that left the drawer.
  double get outflows => (vendorPaid > 0 ? vendorPaid : 0.0) + (manualNet < 0 ? -manualNet : 0.0);

  bool get isEmpty =>
      vendorPaid == 0 &&
      customerDuesReceived == 0 &&
      serviceAdvanceReceived == 0 &&
      manualNet == 0 &&
      commissionCashIn == 0;

  /// Adds up the cash entries of [log] whose date starts with [dateKey]
  /// (yyyy-MM-dd). Bank / UPI entries are ignored.
  static OtherCashFlows fromLog(Iterable<dynamic> log, String dateKey) {
    var vendor = 0, customer = 0, service = 0, manual = 0, commission = 0;
    for (final raw in log) {
      if (raw is! Map) continue;
      if ((raw['account'] ?? '').toString() != 'Cash') continue;
      if (!(raw['date'] ?? '').toString().startsWith(dateKey)) continue;
      final paise = (((raw['amount'] as num?) ?? 0) * 100).round();
      switch (cashFlowCategory(raw)) {
        case kCashCatVendor:
          vendor -= paise; // payments are negative in the log
          break;
        case kCashCatCustomerDue:
          customer += paise;
          break;
        case kCashCatServiceAdvance:
          service += paise;
          break;
        case kCashCatManual:
          manual += paise;
          break;
        case kCashCatCommission:
          commission += paise;
          break;
      }
    }
    return OtherCashFlows(
      vendorPaid: vendor / 100.0,
      customerDuesReceived: customer / 100.0,
      serviceAdvanceReceived: service / 100.0,
      manualNet: manual / 100.0,
      commissionCashIn: commission / 100.0,
    );
  }

  Map<String, dynamic> toMap() => {
        'vendorPaid': vendorPaid,
        'customerDuesReceived': customerDuesReceived,
        'serviceAdvanceReceived': serviceAdvanceReceived,
        'manualNet': manualNet,
        'commissionCashIn': commissionCashIn,
      };

  factory OtherCashFlows.fromMap(dynamic m) {
    if (m is! Map) return zero;
    double d(String k) => (m[k] as num?)?.toDouble() ?? 0.0;
    return OtherCashFlows(
      vendorPaid: d('vendorPaid'),
      customerDuesReceived: d('customerDuesReceived'),
      serviceAdvanceReceived: d('serviceAdvanceReceived'),
      manualNet: d('manualNet'),
      commissionCashIn: d('commissionCashIn'),
    );
  }
}

class CashDenominations {
  final int count500;
  final int count200;
  final int count100;
  final int count50;
  final int count20;
  final int count10;
  final int count5;
  final double coinsValue;

  const CashDenominations({
    this.count500 = 0,
    this.count200 = 0,
    this.count100 = 0,
    this.count50 = 0,
    this.count20 = 0,
    this.count10 = 0,
    this.count5 = 0,
    this.coinsValue = 0.0,
  });

  double get subtotal500 => count500 * 500.0;
  double get subtotal200 => count200 * 200.0;
  double get subtotal100 => count100 * 100.0;
  double get subtotal50 => count50 * 50.0;
  double get subtotal20 => count20 * 20.0;
  double get subtotal10 => count10 * 10.0;
  double get subtotal5 => count5 * 5.0;

  double get totalCash =>
      subtotal500 +
      subtotal200 +
      subtotal100 +
      subtotal50 +
      subtotal20 +
      subtotal10 +
      subtotal5 +
      coinsValue;

  int get totalCashPaise => (totalCash * 100).round();

  bool get isEmpty =>
      count500 == 0 &&
      count200 == 0 &&
      count100 == 0 &&
      count50 == 0 &&
      count20 == 0 &&
      count10 == 0 &&
      count5 == 0 &&
      coinsValue == 0.0;

  CashDenominations copyWith({
    int? count500,
    int? count200,
    int? count100,
    int? count50,
    int? count20,
    int? count10,
    int? count5,
    double? coinsValue,
  }) {
    return CashDenominations(
      count500: count500 ?? this.count500,
      count200: count200 ?? this.count200,
      count100: count100 ?? this.count100,
      count50: count50 ?? this.count50,
      count20: count20 ?? this.count20,
      count10: count10 ?? this.count10,
      count5: count5 ?? this.count5,
      coinsValue: coinsValue ?? this.coinsValue,
    );
  }

  Map<String, dynamic> toMap() => {
        'count500': count500,
        'count200': count200,
        'count100': count100,
        'count50': count50,
        'count20': count20,
        'count10': count10,
        'count5': count5,
        'coinsValue': coinsValue,
        'coinsValuePaise': (coinsValue * 100).round(),
        'subtotal500': subtotal500,
        'subtotal200': subtotal200,
        'subtotal100': subtotal100,
        'subtotal50': subtotal50,
        'subtotal20': subtotal20,
        'subtotal10': subtotal10,
        'subtotal5': subtotal5,
        'totalCash': totalCash,
        'totalCashPaise': totalCashPaise,
      };

  factory CashDenominations.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const CashDenominations();
    return CashDenominations(
      count500: (map['count500'] as num?)?.toInt() ?? 0,
      count200: (map['count200'] as num?)?.toInt() ?? 0,
      count100: (map['count100'] as num?)?.toInt() ?? 0,
      count50: (map['count50'] as num?)?.toInt() ?? 0,
      count20: (map['count20'] as num?)?.toInt() ?? 0,
      count10: (map['count10'] as num?)?.toInt() ?? 0,
      count5: (map['count5'] as num?)?.toInt() ?? 0,
      coinsValue: (map['coinsValue'] as num?)?.toDouble() ??
          (((map['coinsValuePaise'] as num?)?.toDouble() ?? 0.0) / 100.0),
    );
  }
}

class CashHandoverSplit {
  final double ownerCash;
  final double bankDeposit;
  final double otherHandover;
  final String otherRecipientName;
  final String handoverNotes;

  const CashHandoverSplit({
    this.ownerCash = 0.0,
    this.bankDeposit = 0.0,
    this.otherHandover = 0.0,
    this.otherRecipientName = '',
    this.handoverNotes = '',
  });

  double get totalHandover => ownerCash + bankDeposit + otherHandover;
  int get totalHandoverPaise => (totalHandover * 100).round();
  int get ownerCashPaise => (ownerCash * 100).round();
  int get bankDepositPaise => (bankDeposit * 100).round();
  int get otherHandoverPaise => (otherHandover * 100).round();

  CashHandoverSplit copyWith({
    double? ownerCash,
    double? bankDeposit,
    double? otherHandover,
    String? otherRecipientName,
    String? handoverNotes,
  }) {
    return CashHandoverSplit(
      ownerCash: ownerCash ?? this.ownerCash,
      bankDeposit: bankDeposit ?? this.bankDeposit,
      otherHandover: otherHandover ?? this.otherHandover,
      otherRecipientName: otherRecipientName ?? this.otherRecipientName,
      handoverNotes: handoverNotes ?? this.handoverNotes,
    );
  }

  Map<String, dynamic> toMap() => {
        'ownerCash': ownerCash,
        'ownerCashPaise': ownerCashPaise,
        'bankDeposit': bankDeposit,
        'bankDepositPaise': bankDepositPaise,
        'otherHandover': otherHandover,
        'otherHandoverPaise': otherHandoverPaise,
        'otherRecipientName': otherRecipientName,
        'handoverNotes': handoverNotes,
        'totalHandover': totalHandover,
        'totalHandoverPaise': totalHandoverPaise,
      };

  factory CashHandoverSplit.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const CashHandoverSplit();
    return CashHandoverSplit(
      ownerCash: (map['ownerCash'] as num?)?.toDouble() ??
          (((map['ownerCashPaise'] as num?)?.toDouble() ?? 0.0) / 100.0),
      bankDeposit: (map['bankDeposit'] as num?)?.toDouble() ??
          (((map['bankDepositPaise'] as num?)?.toDouble() ?? 0.0) / 100.0),
      otherHandover: (map['otherHandover'] as num?)?.toDouble() ??
          (((map['otherHandoverPaise'] as num?)?.toDouble() ?? 0.0) / 100.0),
      otherRecipientName: map['otherRecipientName']?.toString() ??
          map['otherHandoverRecipient']?.toString() ??
          '',
      handoverNotes: map['handoverNotes']?.toString() ?? '',
    );
  }
}

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

  /// Cash taken at the counter for Quick Recharge today (net of cash
  /// refunds). Part of the expected drawer cash, so only the real leftover
  /// shows as Excess (എക്സസ്).
  final double rechargeCashCollection;

  /// Cash the recharge agent/distributor took from the drawer today, net of
  /// agent cash returns. Expected drawer cash is reduced by it, so an
  /// evening agent collection is not a false shortage.
  final double distributorCashPaid;

  /// Vendor payments, customer dues, service advances, manual Money In/Out
  /// and commission cash taken through the drawer that day.
  final OtherCashFlows otherCash;
  final double retainedCashFloat;
  final CashDenominations denominations;
  final CashHandoverSplit handoverSplit;
  final bool isBackdated;
  final String closingStatus;
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
    this.rechargeCashCollection = 0.0,
    this.distributorCashPaid = 0.0,
    this.otherCash = OtherCashFlows.zero,
    this.retainedCashFloat = 1000.0,
    this.denominations = const CashDenominations(),
    this.handoverSplit = const CashHandoverSplit(),
    this.isBackdated = false,
    this.closingStatus = '',
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
  int get physicalCashCountPaise => physicalCashPaise;
  int get cashDiscrepancyPaise => (cashDiscrepancy * 100).round();
  int get retainedCashFloatPaise => (retainedCashFloat * 100).round();
  double get netCashHandover =>
      (physicalCashCount - retainedCashFloat).clamp(0.0, double.infinity);
  int get netCashHandoverPaise => (netCashHandover * 100).round();
  double get nextDayOpeningCash => retainedCashFloat;
  int get nextDayOpeningCashPaise => retainedCashFloatPaise;

  String get resolvedClosingStatus {
    if (closingStatus.isNotEmpty) return closingStatus;
    if (!isClosed) return 'PENDING';
    if (cashDiscrepancy.abs() > 0.5) return 'DISCREPANCY';
    if (isBackdated) return 'BACKDATED';
    return 'CLOSED';
  }

  // Convenience metric getters for EOD closing reports
  double get netSales => netRevenue;
  double get cashCollection => totalCash;
  double get upiCollection => totalUpi;
  double get cardCollection => totalCard;
  double get creditSales => totalDue;
  double get actualCashCount => physicalCashCount;
  double get otherCashExpenses =>
      (totalCashExpenses - cashRentPaid - ownerCashSalaryDrawn)
          .clamp(0.0, double.infinity);
  double get totalCashOutflows =>
      cashRentPaid +
      otherCashExpenses +
      ownerCashSalaryDrawn +
      ownerCashDrawingsDrawn +
      distributorCashPaid +
      otherCash.outflows +
      refunds;
  double get expectedClosingCash => (openingCash +
          totalCash +
          rechargeCashCollection -
          distributorCashPaid +
          otherCash.net -
          refunds -
          totalCashExpenses -
          ownerCashDrawingsDrawn)
      .clamp(0.0, double.infinity);
  double get expectedCashInRegister => expectedClosingCash;
  double get cashOverOrShort => physicalCashCount - expectedClosingCash;

  /// Positive difference = Excess (kept as Excess), negative = Shortage (only shown).
  double get cashExcess => cashDiscrepancy > 0 ? cashDiscrepancy : 0.0;
  double get cashShortage => cashDiscrepancy < 0 ? -cashDiscrepancy : 0.0;
  int get rechargeCashCollectionPaise => (rechargeCashCollection * 100).round();
  int get distributorCashPaidPaise => (distributorCashPaid * 100).round();
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
    double? retainedCashFloat,
    double? rechargeCashCollection,
    double? distributorCashPaid,
    OtherCashFlows? otherCash,
    CashDenominations? denominations,
    CashHandoverSplit? handoverSplit,
    bool? isBackdated,
    String? closingStatus,
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
      ownerSalaryDrawnToday:
          ownerSalaryDrawnToday ?? this.ownerSalaryDrawnToday,
      ownerExcessDrawingsToday:
          ownerExcessDrawingsToday ?? this.ownerExcessDrawingsToday,
      ownerCashSalaryDrawn: ownerCashSalaryDrawn ?? this.ownerCashSalaryDrawn,
      ownerCashDrawingsDrawn:
          ownerCashDrawingsDrawn ?? this.ownerCashDrawingsDrawn,
      ownerBankSalaryDrawn: ownerBankSalaryDrawn ?? this.ownerBankSalaryDrawn,
      ownerBankDrawingsDrawn:
          ownerBankDrawingsDrawn ?? this.ownerBankDrawingsDrawn,
      physicalCashCount: physicalCashCount ?? this.physicalCashCount,
      cashDiscrepancy: cashDiscrepancy ?? this.cashDiscrepancy,
      retainedCashFloat: retainedCashFloat ?? this.retainedCashFloat,
      rechargeCashCollection: rechargeCashCollection ?? this.rechargeCashCollection,
      distributorCashPaid: distributorCashPaid ?? this.distributorCashPaid,
      otherCash: otherCash ?? this.otherCash,
      denominations: denominations ?? this.denominations,
      handoverSplit: handoverSplit ?? this.handoverSplit,
      isBackdated: isBackdated ?? this.isBackdated,
      closingStatus: closingStatus ?? this.closingStatus,
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
        'businessDate': dateString,
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
        'openingCashPaise': (openingCash * 100).round(),
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
        'actualCashCount': physicalCashCount,
        'actualCashCountPaise': physicalCashPaise,
        'cashDiscrepancy': cashDiscrepancy,
        'cashDiscrepancyPaise': cashDiscrepancyPaise,
        'retainedCashFloat': retainedCashFloat,
        'rechargeCashCollection': rechargeCashCollection,
        'rechargeCashCollectionPaise': rechargeCashCollectionPaise,
        'distributorCashPaid': distributorCashPaid,
        'distributorCashPaidPaise': distributorCashPaidPaise,
        'otherCash': otherCash.toMap(),
        'retainedCashFloatPaise': retainedCashFloatPaise,
        'netCashHandover': netCashHandover,
        'netCashHandoverPaise': netCashHandoverPaise,
        'nextDayOpeningCash': nextDayOpeningCash,
        'nextDayOpeningCashPaise': nextDayOpeningCashPaise,
        'denominations': denominations.toMap(),
        'denominationBreakdown': denominations.toMap(),
        'handoverSplit': handoverSplit.toMap(),
        'ownerCash': handoverSplit.ownerCash,
        'ownerCashPaise': handoverSplit.ownerCashPaise,
        'bankDeposit': handoverSplit.bankDeposit,
        'bankDepositPaise': handoverSplit.bankDepositPaise,
        'otherHandover': handoverSplit.otherHandover,
        'otherHandoverPaise': handoverSplit.otherHandoverPaise,
        'otherHandoverRecipient': handoverSplit.otherRecipientName,
        'isBackdated': isBackdated,
        'closingStatus': resolvedClosingStatus,
        'categoryBreakdown':
            categoryBreakdown.map((k, v) => MapEntry(k, v.toMap())),
        'topSellingProducts': topSellingProducts.map((p) => p.toMap()).toList(),
        'closedByStaffId': closedByStaffId,
        'closedByStaffName': closedByStaffName,
        'closedBy': closedBy,
        'closedAt': closedAt?.toIso8601String(),
        'isClosed': isClosed,
        'notes': notes,
      };

  factory DailyRegisterSummary.fromMap(Map<String, dynamic> map) {
    final dStr = map['dateString']?.toString() ??
        map['businessDate']?.toString() ??
        '';
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
        (map['actualCashCount'] as num?)?.toDouble() ??
        (((map['physicalCashPaise'] as num?)?.toDouble() ??
                ((map['actualCashCountPaise'] as num?)?.toDouble() ?? 0.0)) /
            100.0);
    final double discrepancy = (map['cashDiscrepancy'] as num?)?.toDouble() ??
        (((map['cashDiscrepancyPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final double openCash = (map['openingCash'] as num?)?.toDouble() ??
        (((map['openingCashPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
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
    final double ownDraw =
        (map['ownerExcessDrawingsToday'] as num?)?.toDouble() ??
            (((map['ownerExcessDrawingsPaise'] as num?)?.toDouble() ?? 0.0) /
                100.0);
    final double ownCashSal =
        (map['ownerCashSalaryDrawn'] as num?)?.toDouble() ?? 0.0;
    final double ownCashDraw =
        (map['ownerCashDrawingsDrawn'] as num?)?.toDouble() ?? 0.0;
    final double ownBankSal =
        (map['ownerBankSalaryDrawn'] as num?)?.toDouble() ?? 0.0;
    final double ownBankDraw =
        (map['ownerBankDrawingsDrawn'] as num?)?.toDouble() ?? 0.0;

    final double retainedFloat =
        (map['retainedCashFloat'] as num?)?.toDouble() ??
            (((map['retainedCashFloatPaise'] as num?)?.toDouble() ?? 100000.0) /
                100.0);
    final denoms = CashDenominations.fromMap(map['denominations'] is Map
        ? Map<String, dynamic>.from(map['denominations'])
        : (map['denominationBreakdown'] is Map
            ? Map<String, dynamic>.from(map['denominationBreakdown'])
            : null));
    final handover = CashHandoverSplit.fromMap(map['handoverSplit'] is Map
        ? Map<String, dynamic>.from(map['handoverSplit'])
        : map);
    final isBack = map['isBackdated'] == true;
    final cStatus = map['closingStatus']?.toString() ?? '';

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
      retainedCashFloat: retainedFloat,
      rechargeCashCollection: (map['rechargeCashCollection'] as num?)?.toDouble() ??
          (((map['rechargeCashCollectionPaise'] as num?)?.toDouble() ?? 0.0) / 100.0),
      distributorCashPaid: (map['distributorCashPaid'] as num?)?.toDouble() ??
          (((map['distributorCashPaidPaise'] as num?)?.toDouble() ?? 0.0) / 100.0),
      otherCash: OtherCashFlows.fromMap(map['otherCash']),
      denominations: denoms,
      handoverSplit: handover,
      isBackdated: isBack,
      closingStatus: cStatus,
      categoryBreakdown: cats,
      topSellingProducts: top,
      closedByStaffId: map['closedByStaffId']?.toString() ?? '',
      closedByStaffName: map['closedByStaffName']?.toString() ??
          map['closedBy']?.toString() ??
          '',
      closedAt: map['closedAt'] != null
          ? DateTime.tryParse(map['closedAt'].toString())
          : null,
      isClosed: map['isClosed'] == true,
      notes: map['notes']?.toString() ?? '',
    );
  }
}
