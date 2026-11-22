// ============================================================================
// TEKFIX ERP - QUICK RECHARGE: PERIOD RECONCILIATION, CUMULATIVE VOLUME AND
// OPERATOR-WISE DISTRIBUTOR SETTLEMENT (pure accounting rules)
// ============================================================================
//
// Pure functions only: no I/O, no Hive, no Firestore. The server (Supabase
// procedures) applies the same rules; these are used for display, for the
// local mock backend and for the tests. Integer paise everywhere.
//
// Three separate dimensions (never mixed):
//   A. Recharge volume      = successful recharge FACE VALUE
//   B. Operator wallet      = wallet ledger movements (actual debit amounts)
//   C. Distributor account  = payable (credit loads) - payments, per operator
// ============================================================================

import 'recharge_models.dart';

/// The four operators this workflow covers.
const List<RechargeOperator> kPeriodOperators = [
  RechargeOperator.airtel,
  RechargeOperator.jio,
  RechargeOperator.vi,
  RechargeOperator.bsnl,
];

// ---------------------------------------------------------------------------
// IST business date helpers (Asia/Kolkata, UTC+05:30, no DST)
// ---------------------------------------------------------------------------

const Duration kIstOffset = Duration(hours: 5, minutes: 30);

/// The IST calendar date (yyyy-MM-dd) of an instant.
/// Cash the counter took for recharges on [dateString] (IST yyyy-MM-dd),
/// minus cash refunds of recharges made on that day. Integer paise. Used by
/// the shop's Daily Register so recharge cash is expected in the drawer and
/// only the real leftover shows as Excess.
int rechargeCashCollectedPaise(Iterable<RechargeEntry> entries, String dateString) {
  var total = 0;
  for (final e in entries) {
    if (e.status == RechargeStatus.corrected) continue; // replaced by a correction
    if (e.paymentMode != RechargePaymentMode.cash || !e.customerPaymentCollected) continue;
    if (e.dateString == dateString) total += e.amountPaise;
    final refund = e.refundAmount;
    if (refund != null && refund > 0 && e.refundMethod == RechargePaymentMode.cash.name &&
        istBusinessDate(e.updatedAt) == dateString) {
      total -= (refund * 100).round();
    }
  }
  return total;
}

String istBusinessDate(DateTime instant) {
  final t = instant.toUtc().add(kIstOffset);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}';
}

/// UTC instant of 00:00 IST on the IST calendar day (y, m, d).
DateTime istMidnightUtc(int y, int m, int d) =>
    DateTime.utc(y, m, d).subtract(kIstOffset);

/// The shop's fresh start for the new recharge accounting (IST date).
/// Volume, cumulative totals and the wallet figures on the dashboard count
/// only from here; older records stay in the database and old reports.
const String kRechargeFreshStartIstDate = '2026-11-20';

/// 00:00 IST on [kRechargeFreshStartIstDate], as UTC.
final DateTime rechargeFreshStartUtc = () {
  final p = kRechargeFreshStartIstDate.split('-').map(int.parse).toList();
  return istMidnightUtc(p[0], p[1], p[2]);
}();

/// [r] limited to the fresh start (nothing earlier is counted).
IstRange clampToFreshStart(IstRange r) {
  final s = r.startUtc;
  if (s != null && !s.isBefore(rechargeFreshStartUtc)) return r;
  return IstRange(rechargeFreshStartUtc, r.endUtc);
}

/// Report date filters. Week starts on MONDAY.
enum RechargePeriodFilter {
  today('Today', 'ഇന്ന്'),
  yesterday('Yesterday', 'ഇന്നലെ'),
  last7Days('Last 7 Days', 'കഴിഞ്ഞ 7 ദിവസം'),
  thisWeek('This Week (Mon–Today)', 'ഈ ആഴ്ച (തിങ്കൾ മുതൽ)'),
  thisMonth('This Month', 'ഈ മാസം'),
  previousMonth('Previous Month', 'കഴിഞ്ഞ മാസം'),
  custom('Custom Range', 'തിരഞ്ഞെടുത്ത തീയതി'),
  allTime('All Time', 'എല്ലാ കാലവും');

  final String label;
  final String malayalam;
  const RechargePeriodFilter(this.label, this.malayalam);
}

/// Half-open UTC range [start, end). `start == null` means from the beginning.
class IstRange {
  final DateTime? startUtc;
  final DateTime endUtc;
  const IstRange(this.startUtc, this.endUtc);

  bool contains(DateTime instant) {
    final u = instant.toUtc();
    if (startUtc != null && u.isBefore(startUtc!)) return false;
    return u.isBefore(endUtc);
  }
}

/// IST boundaries for a filter. [now] is any instant (defaults to now).
/// Custom: [customStart]..[customEnd] are IST calendar days, both inclusive.
IstRange istRangeFor(
  RechargePeriodFilter f, {
  DateTime? now,
  DateTime? customStart,
  DateTime? customEnd,
}) {
  final ist = (now ?? DateTime.now()).toUtc().add(kIstOffset);
  final todayStart = istMidnightUtc(ist.year, ist.month, ist.day);
  final tomorrow = istMidnightUtc(ist.year, ist.month, ist.day + 1);
  switch (f) {
    case RechargePeriodFilter.today:
      return IstRange(todayStart, tomorrow);
    case RechargePeriodFilter.yesterday:
      return IstRange(istMidnightUtc(ist.year, ist.month, ist.day - 1), todayStart);
    case RechargePeriodFilter.last7Days:
      return IstRange(istMidnightUtc(ist.year, ist.month, ist.day - 6), tomorrow);
    case RechargePeriodFilter.thisWeek:
      return IstRange(
          istMidnightUtc(ist.year, ist.month, ist.day - (ist.weekday - 1)), tomorrow);
    case RechargePeriodFilter.thisMonth:
      return IstRange(istMidnightUtc(ist.year, ist.month, 1), tomorrow);
    case RechargePeriodFilter.previousMonth:
      return IstRange(istMidnightUtc(ist.year, ist.month - 1, 1),
          istMidnightUtc(ist.year, ist.month, 1));
    case RechargePeriodFilter.custom:
      final s = customStart ?? ist;
      final e = customEnd ?? ist;
      return IstRange(istMidnightUtc(s.year, s.month, s.day),
          istMidnightUtc(e.year, e.month, e.day + 1));
    case RechargePeriodFilter.allTime:
      return IstRange(null, tomorrow);
  }
}

// ---------------------------------------------------------------------------
// B. Wallet ledger movements and the reconciliation period
// ---------------------------------------------------------------------------

/// Kinds of wallet movement. Sign is fixed per kind, except [adjustment],
/// which carries its own sign.
enum WalletMovementKind {
  topUpOwn, // own-money top-up (incl. prepaid margin top-up: full wallet credit)
  creditLoad, // distributor credit top-up
  commissionCredit,
  refundCredit, // recharge refund / failed-debit reversal returned to wallet
  bonus,
  rechargeDebit, // ACTUAL wallet debit of a recharge
  commissionClawback,
  adjustment; // signed

  bool get isDebit =>
      this == WalletMovementKind.rechargeDebit ||
      this == WalletMovementKind.commissionClawback;
}

class WalletMovement {
  final RechargeOperator operator;
  final WalletMovementKind kind;

  /// Always > 0 except for [WalletMovementKind.adjustment], where the sign
  /// is the direction.
  final int amountPaise;

  /// Server timestamp of the posting.
  final DateTime at;
  final String referenceId;

  /// For recharge debits: is the recharge still pending at the operator?
  final bool pending;

  const WalletMovement({
    required this.operator,
    required this.kind,
    required this.amountPaise,
    required this.at,
    this.referenceId = '',
    this.pending = false,
  });

  /// Signed effect on the wallet.
  int get signedPaise {
    if (kind == WalletMovementKind.adjustment) return amountPaise;
    return kind.isDebit ? -amountPaise : amountPaise;
  }

  /// Maps the existing Firestore/Hive wallet log entry types.
  static WalletMovementKind? kindFromLegacy(String entryType) {
    switch (entryType.toUpperCase()) {
      case 'TOPUP':
      case 'PREPAID_TOPUP_WITH_COMMISSION':
        return WalletMovementKind.topUpOwn;
      case 'CREDIT_LOAD':
        return WalletMovementKind.creditLoad;
      case 'COMMISSION_CREDIT':
        return WalletMovementKind.commissionCredit;
      case 'RECHARGE_DEBIT':
        return WalletMovementKind.rechargeDebit;
      case 'REVERSAL_CREDIT':
      case 'WALLET_REVERSAL':
        return WalletMovementKind.refundCredit;
      case 'COMMISSION_WALLET_REVERSAL':
        return WalletMovementKind.commissionClawback;
      case 'ADJUSTMENT':
        return WalletMovementKind.adjustment;
    }
    return null;
  }
}

/// Verified snapshot that closes a period (or the audited reference balance
/// used when no previous closing exists).
class VerifiedClosing {
  final RechargeOperator operator;
  final int actualPaise;
  final DateTime at;
  final String periodId;
  const VerifiedClosing({
    required this.operator,
    required this.actualPaise,
    required this.at,
    required this.periodId,
  });
}

/// Period id = operator + start instant (the previous verified closing).
String periodIdFor(RechargeOperator op, DateTime? previousClosingAt) =>
    '${op.name}_${previousClosingAt == null ? 'GENESIS' : previousClosingAt.toUtc().toIso8601String()}';

/// The movements belonging to the period that starts after [from]
/// (exclusive) and ends at [to] (inclusive; null = still open).
List<WalletMovement> movementsInPeriod(
  Iterable<WalletMovement> all,
  RechargeOperator op, {
  required DateTime? from,
  DateTime? to,
}) {
  return all.where((m) {
    if (m.operator != op) return false;
    final u = m.at.toUtc();
    if (from != null && !u.isAfter(from.toUtc())) return false;
    if (to != null && u.isAfter(to.toUtc())) return false;
    return true;
  }).toList();
}

// ---------------------------------------------------------------------------
// Morning entry
// ---------------------------------------------------------------------------

enum MorningStatus {
  notEntered('Not Entered', 'രേഖപ്പെടുത്തിയിട്ടില്ല'),
  previousClosingMissing('Previous closing missing', 'മുൻ ക്ലോസിംഗ് ഇല്ല'),
  pendingVerification('Pending Verification', 'സ്ഥിരീകരണം ബാക്കി'),
  verified('Verified', 'സ്ഥിരീകരിച്ചു'),
  discrepancy('Discrepancy', 'പൊരുത്തക്കേട്'),
  adjustmentRequired('Adjustment Required', 'അഡ്ജസ്റ്റ്മെന്റ് വേണം');

  final String label;
  final String malayalam;
  const MorningStatus(this.label, this.malayalam);
}

class MorningCheck {
  final RechargeOperator operator;
  final int? previousClosingPaise;
  final int morningActualPaise;

  /// Morning actual - previous verified closing.
  final int rawDifferencePaise;

  /// Net of ledger entries already recorded since the previous closing.
  final int alreadyRecordedPaise;

  /// Raw - already recorded. Only this may be posted, after classification.
  final int unexplainedPaise;
  final MorningStatus status;

  const MorningCheck({
    required this.operator,
    required this.previousClosingPaise,
    required this.morningActualPaise,
    required this.rawDifferencePaise,
    required this.alreadyRecordedPaise,
    required this.unexplainedPaise,
    required this.status,
  });
}

/// Morning check. [previousClosing] null => no auto-calculation.
MorningCheck computeMorningCheck({
  required RechargeOperator operator,
  required VerifiedClosing? previousClosing,
  required int morningActualPaise,
  required DateTime morningAt,
  required Iterable<WalletMovement> ledger,
}) {
  if (morningActualPaise < 0) {
    throw ArgumentError('Morning balance cannot be negative');
  }
  if (previousClosing == null) {
    return MorningCheck(
      operator: operator,
      previousClosingPaise: null,
      morningActualPaise: morningActualPaise,
      rawDifferencePaise: 0,
      alreadyRecordedPaise: 0,
      unexplainedPaise: 0,
      status: MorningStatus.previousClosingMissing,
    );
  }
  final recorded = movementsInPeriod(ledger, operator,
          from: previousClosing.at, to: morningAt)
      .fold<int>(0, (a, m) => a + m.signedPaise);
  final raw = morningActualPaise - previousClosing.actualPaise;
  final unexplained = raw - recorded;
  return MorningCheck(
    operator: operator,
    previousClosingPaise: previousClosing.actualPaise,
    morningActualPaise: morningActualPaise,
    rawDifferencePaise: raw,
    alreadyRecordedPaise: recorded,
    unexplainedPaise: unexplained,
    status: unexplained == 0
        ? MorningStatus.verified
        : (unexplained > 0
            ? MorningStatus.pendingVerification
            : MorningStatus.discrepancy),
  );
}

/// How the owner classifies an unexplained morning increase.
enum UnexplainedCategory {
  topUpOwn('Top-Up (own money)', 'ടോപ്പ്-അപ്പ് (സ്വന്തം പണം)'),
  topUpDistributorCredit('Top-Up (distributor credit)', 'ടോപ്പ്-അപ്പ് (ഡിസ്ട്രിബ്യൂട്ടർ ക്രെഡിറ്റ്)'),
  /// Extra balance that is neither distributor credit nor own money. Kept
  /// in a separate Excess account (not profit, not own money).
  excess('Excess', 'എക്സസ്'),
  refund('Refund', 'റീഫണ്ട്'),
  bonus('Bonus / Incentive', 'ബോണസ്'),
  commissionCredit('Commission credit', 'കമ്മീഷൻ ക്രെഡിറ്റ്'),
  manualCorrection('Manual correction', 'തിരുത്തൽ'),
  otherAdjustment('Other adjustment', 'മറ്റ് അഡ്ജസ്റ്റ്മെന്റ്');

  final String label;
  final String malayalam;
  const UnexplainedCategory(this.label, this.malayalam);

  WalletMovementKind get movementKind {
    switch (this) {
      case UnexplainedCategory.topUpOwn:
        return WalletMovementKind.topUpOwn;
      case UnexplainedCategory.topUpDistributorCredit:
        return WalletMovementKind.creditLoad;
      case UnexplainedCategory.refund:
        return WalletMovementKind.refundCredit;
      case UnexplainedCategory.bonus:
        return WalletMovementKind.bonus;
      case UnexplainedCategory.commissionCredit:
        return WalletMovementKind.commissionCredit;
      case UnexplainedCategory.excess:
      case UnexplainedCategory.manualCorrection:
      case UnexplainedCategory.otherAdjustment:
        return WalletMovementKind.adjustment;
    }
  }

  /// Signed corrections: may be negative, skip the unexplained cap and the
  /// period lock. Excess is NOT one of them (it is capped like a top-up).
  bool get isAdjustment =>
      this == UnexplainedCategory.manualCorrection || this == UnexplainedCategory.otherAdjustment;

  static UnexplainedCategory fromName(String n) =>
      UnexplainedCategory.values.firstWhere((c) => c.name == n,
          orElse: () => throw ArgumentError('Unknown category: $n'));
}

// ---------------------------------------------------------------------------
// Night closing
// ---------------------------------------------------------------------------

enum VarianceStatus {
  match('Match', 'ശരി'),
  shortage('Shortage', 'കുറവ്'),
  excess('Excess', 'അധികം'),
  investigationRequired('Investigation Required', 'പരിശോധന വേണം');

  final String label;
  final String malayalam;
  const VarianceStatus(this.label, this.malayalam);
}

class ClosingBreakdown {
  final RechargeOperator operator;
  final String periodId;
  final int openingPaise;
  final int topUpsPaise; // own top-ups + distributor credit loads
  final int creditsPaise; // refunds, commission credits, bonus
  final int rechargeDebitsPaise; // settled (non-pending) actual debits
  final int pendingDebitsPaise; // shown separately
  final int clawbacksPaise;
  final int adjustmentsPaise; // signed
  final int expectedClosingPaise;
  final int? actualClosingPaise;

  const ClosingBreakdown({
    required this.operator,
    required this.periodId,
    required this.openingPaise,
    required this.topUpsPaise,
    required this.creditsPaise,
    required this.rechargeDebitsPaise,
    required this.pendingDebitsPaise,
    required this.clawbacksPaise,
    required this.adjustmentsPaise,
    required this.expectedClosingPaise,
    this.actualClosingPaise,
  });

  int? get variancePaise =>
      actualClosingPaise == null ? null : actualClosingPaise! - expectedClosingPaise;

  VarianceStatus? get status {
    final v = variancePaise;
    if (v == null) return null;
    if (pendingDebitsPaise != 0) return VarianceStatus.investigationRequired;
    if (v == 0) return VarianceStatus.match;
    return v < 0 ? VarianceStatus.shortage : VarianceStatus.excess;
  }
}

/// Expected closing for the open period of [operator].
/// A pending recharge whose wallet was already debited still reduces the
/// wallet, but it is reported in [ClosingBreakdown.pendingDebitsPaise] and
/// makes the variance "Investigation Required". Failed recharges have no
/// debit movement, so they are never subtracted.
ClosingBreakdown computeClosing({
  required RechargeOperator operator,
  required VerifiedClosing? previousClosing,
  required Iterable<WalletMovement> ledger,
  DateTime? closingAt,
  int? actualClosingPaise,
}) {
  if (actualClosingPaise != null && actualClosingPaise < 0) {
    throw ArgumentError('Closing balance cannot be negative');
  }
  final ms = movementsInPeriod(ledger, operator,
      from: previousClosing?.at, to: closingAt);
  var topUps = 0, credits = 0, debits = 0, pending = 0, claw = 0, adj = 0;
  for (final m in ms) {
    switch (m.kind) {
      case WalletMovementKind.topUpOwn:
      case WalletMovementKind.creditLoad:
        topUps += m.amountPaise;
        break;
      case WalletMovementKind.commissionCredit:
      case WalletMovementKind.refundCredit:
      case WalletMovementKind.bonus:
        credits += m.amountPaise;
        break;
      case WalletMovementKind.rechargeDebit:
        if (m.pending) {
          pending += m.amountPaise;
        } else {
          debits += m.amountPaise;
        }
        break;
      case WalletMovementKind.commissionClawback:
        claw += m.amountPaise;
        break;
      case WalletMovementKind.adjustment:
        adj += m.amountPaise;
        break;
    }
  }
  final opening = previousClosing?.actualPaise ?? 0;
  final expected = opening + topUps + credits - debits - pending - claw + adj;
  return ClosingBreakdown(
    operator: operator,
    periodId: periodIdFor(operator, previousClosing?.at),
    openingPaise: opening,
    topUpsPaise: topUps,
    creditsPaise: credits,
    rechargeDebitsPaise: debits,
    pendingDebitsPaise: pending,
    clawbacksPaise: claw,
    adjustmentsPaise: adj,
    expectedClosingPaise: expected,
    actualClosingPaise: actualClosingPaise,
  );
}

// ---------------------------------------------------------------------------
// A. Recharge volume (face value)
// ---------------------------------------------------------------------------

/// One recharge as the volume rules need it.
class VolumeTxn {
  final String id;
  final RechargeOperator operator;
  final int faceValuePaise;
  final RechargeStatus status;
  final DateTime at;

  /// Refund/reversal amount and when it happened (null = none).
  final int refundPaise;
  final DateTime? refundAt;

  const VolumeTxn({
    required this.id,
    required this.operator,
    required this.faceValuePaise,
    required this.status,
    required this.at,
    this.refundPaise = 0,
    this.refundAt,
  });

  factory VolumeTxn.fromEntry(RechargeEntry e) => VolumeTxn(
        id: e.rechargeId,
        operator: e.operator,
        faceValuePaise: e.amountPaise,
        status: e.status,
        at: e.createdAt,
        refundPaise: e.status == RechargeStatus.refunded
            ? (((e.refundAmount ?? e.amount) * 100).round())
            : 0,
        refundAt: e.status == RechargeStatus.refunded ? e.updatedAt : null,
      );

  /// Was the recharge successful at the operator? A recharge that later got
  /// refunded was successful first, so its face value stays in Gross and
  /// the refund is shown separately.
  bool get wasSuccessful =>
      status == RechargeStatus.success || status == RechargeStatus.refunded;
}

class OperatorVolume {
  int grossPaise = 0;
  int refundsPaise = 0;
  int successCount = 0;
  int failedCount = 0;
  int pendingCount = 0;
  int get netPaise => grossPaise - refundsPaise;
}

class VolumeSummary {
  final Map<RechargeOperator, OperatorVolume> byOperator;
  VolumeSummary(this.byOperator);

  int get grossPaise => byOperator.values.fold(0, (a, v) => a + v.grossPaise);
  int get refundsPaise => byOperator.values.fold(0, (a, v) => a + v.refundsPaise);
  int get netPaise => grossPaise - refundsPaise;
  int get successCount => byOperator.values.fold(0, (a, v) => a + v.successCount);
  int get failedCount => byOperator.values.fold(0, (a, v) => a + v.failedCount);
  OperatorVolume of(RechargeOperator op) => byOperator[op] ?? OperatorVolume();
}

/// Volume for [range]. Duplicate ids are counted once. Failed, pending and
/// disputed recharges never add to Gross.
VolumeSummary computeVolume(Iterable<VolumeTxn> txns, IstRange range) {
  final map = {for (final op in kPeriodOperators) op: OperatorVolume()};
  final seen = <String>{};
  for (final t in txns) {
    if (!seen.add(t.id)) continue; // duplicate record
    if (t.status == RechargeStatus.corrected) continue; // replaced by a correction
    final v = map[t.operator];
    if (v == null) continue; // utilities / other: not in this tracker
    if (range.contains(t.at)) {
      if (t.wasSuccessful) {
        v.grossPaise += t.faceValuePaise;
        v.successCount++;
      } else if (t.status == RechargeStatus.failed) {
        v.failedCount++;
      } else {
        v.pendingCount++;
      }
    }
    if (t.refundPaise > 0 && t.refundAt != null && range.contains(t.refundAt!)) {
      v.refundsPaise += t.refundPaise;
    }
  }
  return VolumeSummary(map);
}

// ---------------------------------------------------------------------------
// C. Distributor settlement, per distributor and per operator
// ---------------------------------------------------------------------------

enum SettlementEntryKind { openingPayable, creditLoad, payment, adjustment }

class SettlementEntry {
  final String distributorId;
  final String distributorName;
  final RechargeOperator operator;
  final SettlementEntryKind kind;

  /// > 0. Adjustments reduce payable.
  final int amountPaise;
  final DateTime at;
  const SettlementEntry({
    required this.distributorId,
    required this.distributorName,
    required this.operator,
    required this.kind,
    required this.amountPaise,
    required this.at,
  });
}

class SettlementAccount {
  final String distributorId;
  final String distributorName;
  final RechargeOperator operator;
  int payablePaise = 0;
  int paidPaise = 0;
  DateTime? lastPaymentAt;
  SettlementAccount(this.distributorId, this.distributorName, this.operator);

  int get balancePaise => payablePaise - paidPaise;
  int get outstandingPaise => balancePaise > 0 ? balancePaise : 0;
  int get advancePaise => balancePaise < 0 ? -balancePaise : 0;
}

class SettlementSummary {
  final List<SettlementAccount> accounts;
  SettlementSummary(this.accounts);

  /// Never netted: an advance on one account never reduces another.
  int get outstandingPaise => accounts.fold(0, (a, s) => a + s.outstandingPaise);
  int get advancePaise => accounts.fold(0, (a, s) => a + s.advancePaise);

  /// For information only.
  int get netPositionPaise => outstandingPaise - advancePaise;

  SettlementAccount? account(String distributorId, RechargeOperator op) {
    for (final a in accounts) {
      if (a.distributorId == distributorId && a.operator == op) return a;
    }
    return null;
  }
}

SettlementSummary computeSettlement(Iterable<SettlementEntry> entries) {
  final map = <String, SettlementAccount>{};
  for (final e in entries) {
    final acc = map.putIfAbsent('${e.distributorId}|${e.operator.name}',
        () => SettlementAccount(e.distributorId, e.distributorName, e.operator));
    switch (e.kind) {
      case SettlementEntryKind.openingPayable:
      case SettlementEntryKind.creditLoad:
        acc.payablePaise += e.amountPaise;
        break;
      case SettlementEntryKind.adjustment:
        acc.payablePaise -= e.amountPaise;
        break;
      case SettlementEntryKind.payment:
        acc.paidPaise += e.amountPaise;
        if (acc.lastPaymentAt == null || e.at.isAfter(acc.lastPaymentAt!)) {
          acc.lastPaymentAt = e.at;
        }
        break;
    }
  }
  final list = map.values.toList()
    ..sort((a, b) {
      final n = a.distributorName.compareTo(b.distributorName);
      return n != 0 ? n : a.operator.index.compareTo(b.operator.index);
    });
  return SettlementSummary(list);
}

// ---------------------------------------------------------------------------
// Money parsing and the commission rounding rule
// ---------------------------------------------------------------------------

/// Parses a rupee string ("1,500.50") into paise without floating point.
/// Returns null for empty or invalid input or more than 2 decimals.
int? parseRupeesToPaise(String input) {
  final s = input.replaceAll(',', '').replaceAll('₹', '').trim();
  final m = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(s);
  if (m == null) return null;
  final rupees = int.parse(m.group(1)!);
  final frac = (m.group(2) ?? '').padRight(2, '0');
  return rupees * 100 + int.parse(frac);
}

/// Rounding rule for any percentage on money: round HALF UP to the nearest
/// paise, once per transaction. [basisPoints]: 1% = 100.
int percentOfPaise(int amountPaise, int basisPoints) {
  if (amountPaise < 0 || basisPoints < 0) {
    throw ArgumentError('Negative amount or rate');
  }
  return (amountPaise * basisPoints + 5000) ~/ 10000;
}

/// Indian Rupee format from paise without floating point: ₹1,23,456.00
String formatInrPaise(int paise) {
  final neg = paise < 0;
  final abs = paise.abs();
  final rupees = (abs ~/ 100).toString();
  final ps = (abs % 100).toString().padLeft(2, '0');
  String grouped;
  if (rupees.length <= 3) {
    grouped = rupees;
  } else {
    final last3 = rupees.substring(rupees.length - 3);
    var rest = rupees.substring(0, rupees.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    grouped = '${parts.join(',')},$last3';
  }
  return '${neg ? '-' : ''}₹$grouped.$ps';
}

/// Sane per-entry upper limit (₹10,00,000).
const int kMaxPostingPaise = 100000000;

/// Distributor top-up commission (owner, 2026-11-21): a refill of Rs 1,039
/// is Rs 1,000 payable to the agent + Rs 39 commission (3.9%, profit).
const int kDefaultTopUpCommissionBp = 390;

/// Commission inside a received refill: received - received / (1 + rate),
/// half-up to the paise. 1,039.00 at 390 bp -> 39.00.
int topUpCommissionPaise(int receivedPaise, int rateBp) {
  if (receivedPaise <= 0 || rateBp <= 0) return 0;
  final den = 10000 + rateBp;
  final payable = (receivedPaise * 10000 * 2 + den) ~/ (den * 2);
  return receivedPaise - payable;
}
