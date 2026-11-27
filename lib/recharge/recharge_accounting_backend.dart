// ============================================================================
// TEKFIX ERP - QUICK RECHARGE ACCOUNTING BACKENDS
// ============================================================================
//
// Financial postings for the period workflow (morning verification,
// classified adjustments, reference balance, night closing, distributor
// payment) are ONLINE-ONLY and server-authoritative:
//
//  * SupabaseAccountingBackend  - production path. Calls the
//    `recharge-bridge` Edge Function (owner token + device signature), which
//    runs row-locked, idempotent Postgres procedures. Nothing is written to
//    Hive, the sync queue or the Firestore offline cache.
//  * LocalAccountingBackend     - in-memory backend for tests and the
//    `localTestMock` bridge mode. Applies the same rules as the server.
//
// The client never computes the amount that gets posted: the server derives
// the unexplained morning difference and the expected closing itself.
// ============================================================================

import 'dart:async';

import 'recharge_models.dart';
import 'recharge_period_accounting.dart';

class AccountingException implements Exception {
  final String code;
  final String message;
  AccountingException(this.code, this.message);
  @override
  String toString() => message;
}

/// Result of a posting. [replayed] = same idempotency key seen before; the
/// original result is returned and nothing new is posted.
class PostingResult {
  final String referenceId;
  final bool replayed;
  final Map<String, dynamic> data;
  const PostingResult(this.referenceId, {this.replayed = false, this.data = const {}});
}

/// Recorded morning entry for the open period.
class MorningSnapshot {
  final int morningActualPaise;
  final DateTime at;
  final MorningCheck check;
  final int classifiedPaise; // posted so far from the unexplained amount
  const MorningSnapshot({
    required this.morningActualPaise,
    required this.at,
    required this.check,
    this.classifiedPaise = 0,
  });

  int get remainingPaise => check.unexplainedPaise - classifiedPaise;

  MorningStatus get status {
    final s = check.status;
    if (s == MorningStatus.verified || s == MorningStatus.previousClosingMissing) {
      return s;
    }
    if (remainingPaise == 0) return MorningStatus.verified;
    if (classifiedPaise != 0) return MorningStatus.adjustmentRequired;
    return s;
  }
}

class OperatorPeriodState {
  final RechargeOperator operator;
  final VerifiedClosing? previousClosing;
  final List<WalletMovement> movements; // open period only
  final MorningSnapshot? morning;
  const OperatorPeriodState({
    required this.operator,
    required this.previousClosing,
    required this.movements,
    this.morning,
  });

  String get periodId => periodIdFor(operator, previousClosing?.at);

  ClosingBreakdown closing({int? actualPaise, DateTime? at}) => computeClosing(
        operator: operator,
        previousClosing: previousClosing,
        ledger: movements,
        closingAt: at,
        actualClosingPaise: actualPaise,
      );
}

/// Who is posting. The server re-checks all of it.
class AccountingActor {
  final String uid;
  final String name;
  final bool isOwner;
  const AccountingActor({required this.uid, required this.name, required this.isOwner});
}

abstract class RechargeAccountingBackend {
  Future<Map<RechargeOperator, OperatorPeriodState>> periodState(String shopId);

  Future<PostingResult> verifyMorning({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int morningActualPaise,
    required String idempotencyKey,
  });

  Future<PostingResult> postClassified({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required UnexplainedCategory category,
    required int amountPaise, // signed only for corrections/adjustments
    required String reason,
    required DateTime transactionDate,
    String? distributorId,
    required String idempotencyKey,
  });

  Future<PostingResult> postReferenceBalance({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int balancePaise,
    required String reason,
    required String idempotencyKey,
  });

  Future<PostingResult> verifyClosing({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int actualPaise,
    String reason = '',
    required String idempotencyKey,
  });

  Future<PostingResult> distributorPayment({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int amountPaise,
    required String paymentMode,
    required DateTime paymentDate,
    String referenceNo = '',
    String notes = '',
    required String idempotencyKey,
  });

  Future<SettlementSummary> settlement(String shopId);

  // ----- Legacy flows moved to the server path (v2.1) ----------------------

  /// Operator Agent Settlement: the distributor x operator payable is reduced
  /// by [totalPayablePaise]; only (total - adjustment) leaves cash/bank; the
  /// recharge adjustment becomes a pending return owed by the agent.
  Future<PostingResult> agentSettlement({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int totalPayablePaise,
    required int rechargeAdjustmentPaise,
    required String paymentMode,
    required DateTime paymentDate,
    String referenceNo = '',
    String notes = '',
    required String idempotencyKey,
  });

  /// Agent returns (part of) a pending recharge adjustment. Never more than
  /// the pending return of that distributor x operator.
  Future<PostingResult> agentReturn({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int returnPaise,
    required String returnMode,
    required DateTime returnDate,
    String referenceNo = '',
    String notes = '',
    required String idempotencyKey,
  });

  /// Reduces the payable of one distributor x operator (credit reversed).
  Future<PostingResult> distributorCreditReversal({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int amountPaise,
    required String reason,
    required String idempotencyKey,
  });

  /// Fresh start: sets the system wallet (own money + distributor credit) to
  /// the verified balance of the open period. Audited, but not a period
  /// movement: expected closing, volume and settlement do not change.
  Future<PostingResult> alignWallet({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int ownPaise,
    required int creditPaise,
    required String reason,
    required String idempotencyKey,
  });

  /// Fresh start: dues still owed to a distributor from before the new start.
  /// Raises that operator account's payable only; the wallet credit is
  /// already part of the verified opening balance, so no wallet change.
  Future<PostingResult> distributorOpeningDues({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int amountPaise,
    required String reason,
    required String idempotencyKey,
  });

  /// Money handed back to the customer. Once per recharge, never more than
  /// its face value. Does not touch the wallet and never lowers cumulative
  /// volume (the refund is reported on its own date).
  Future<PostingResult> customerRefund({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required int refundPaise,
    required String refundMethod,
    required String reason,
    required String idempotencyKey,
  });

  /// Marks a not-yet-successful recharge failed and, if its wallet was
  /// debited, credits the debit back to that operator wallet. Once.
  Future<PostingResult> failedRechargeReversal({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required String reason,
    required String idempotencyKey,
  });

  /// Owner correction of a wrong amount / operator: the recharge becomes
  /// 'reversed' (shown as Corrected), its wallet debit is credited back and
  /// its commission is reversed. Once per recharge. Refused after that
  /// operator's next closing is verified (LOCKED_PERIOD).
  Future<PostingResult> correctRecharge({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required String reason,
    required String idempotencyKey,
  });

  /// Owner edit of the mobile number and/or Cash <-> UPI. No money moves.
  /// [paymentMode] is 'Cash' or 'UPI' (null = unchanged).
  Future<PostingResult> editRechargeDetails({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    String? customerPhone,
    String? paymentMode,
    required String reason,
    required String idempotencyKey,
  });

  /// Reverses the commission of one recharge. The amount comes from the
  /// server's commission record, never from the client. Once.
  Future<PostingResult> commissionReversal({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required bool clawbackFromWallet,
    required String reason,
    required String idempotencyKey,
  });

  /// Pending recharge-adjustment returns, keyed "distributorId|operator".
  Future<Map<String, int>> agentPendingReturns(String shopId);

  /// The separate Excess account (morning excess + closing excess).
  Future<ExcessSummary> excessSummary(String shopId);

  /// Commission part of a distributor refill (e.g. Rs 39 of Rs 1,039) as a
  /// wallet credit. Never payable to the distributor; it is profit.
  Future<PostingResult> topUpCommission({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    String? distributorId,
    required int commissionPaise,
    required String reason,
    required String idempotencyKey,
  });

  /// Top-up commission earned (mid-day refills + morning classifications).
  Future<TopUpCommissionSummary> topUpCommissionSummary(String shopId);

  /// Net drawer cash of distributor dealings on one IST date (yyyy-MM-dd):
  /// cash paid to distributors/agents (-) and agent cash returns (+).
  Future<int> distributorCashForDate(String shopId, String dateString);
}

class TopUpCommissionEntry {
  final RechargeOperator operator;
  final int amountPaise;
  final DateTime at;
  final String referenceId;
  const TopUpCommissionEntry(
      {required this.operator, required this.amountPaise, required this.at, this.referenceId = ''});
}

class TopUpCommissionSummary {
  final List<TopUpCommissionEntry> entries;
  TopUpCommissionSummary(this.entries);
  int get totalPaise => entries.fold(0, (a, e) => a + e.amountPaise);
  int byOperator(RechargeOperator op) =>
      entries.where((e) => e.operator == op).fold(0, (a, e) => a + e.amountPaise);
  int inRange(IstRange r) => entries
      .where((e) =>
          (r.startUtc == null || !e.at.toUtc().isBefore(r.startUtc!)) &&
          e.at.toUtc().isBefore(r.endUtc))
      .fold(0, (a, e) => a + e.amountPaise);
}

enum ExcessSource { morning, closing }

class ExcessEntry {
  final RechargeOperator operator;
  final int amountPaise;
  final DateTime at;
  final ExcessSource source;
  final String referenceId;
  const ExcessEntry({
    required this.operator,
    required this.amountPaise,
    required this.at,
    required this.source,
    this.referenceId = '',
  });
}

/// Excess is never profit and never own money: it is reported on its own.
class ExcessSummary {
  final List<ExcessEntry> entries;
  ExcessSummary(this.entries);
  int get totalPaise => entries.fold(0, (a, e) => a + e.amountPaise);
  int bySource(ExcessSource s) =>
      entries.where((e) => e.source == s).fold(0, (a, e) => a + e.amountPaise);
  int byOperator(RechargeOperator op) =>
      entries.where((e) => e.operator == op).fold(0, (a, e) => a + e.amountPaise);
  int inRange(IstRange r) => entries
      .where((e) =>
          (r.startUtc == null || !e.at.toUtc().isBefore(r.startUtc!)) &&
          e.at.toUtc().isBefore(r.endUtc))
      .fold(0, (a, e) => a + e.amountPaise);
}

String agentReturnKey(String distributorId, RechargeOperator op) => '$distributorId|${op.name}';

/// Server-side copy of a recharge as the accounting backend sees it.
class LocalRechargeRecord {
  final String rechargeId;
  final RechargeOperator operator;
  final int amountPaise;
  String status; // pending | completed | failed | refunded | reversed
  final bool walletDebited;
  final bool paymentCollected;
  final DateTime? createdAt;
  String customerPhone;
  String paymentMode; // Cash | UPI | Credit / Due
  LocalRechargeRecord({
    required this.rechargeId,
    required this.operator,
    required this.amountPaise,
    this.status = 'completed',
    this.walletDebited = true,
    this.paymentCollected = true,
    this.createdAt,
    this.customerPhone = '9999999999',
    this.paymentMode = 'Cash',
  });
}

// ---------------------------------------------------------------------------
// Shared server-side style validation (mirrors the SQL procedures)
// ---------------------------------------------------------------------------

void validatePostingCommon({
  required AccountingActor actor,
  required RechargeOperator operator,
  required String idempotencyKey,
  DateTime? date,
  DateTime? now,
}) {
  if (!actor.isOwner) {
    throw AccountingException('PERMISSION_DENIED',
        'ഉടമയ്ക്ക് മാത്രം (Only the owner can post recharge accounting entries)');
  }
  if (!kPeriodOperators.contains(operator)) {
    throw AccountingException('INVALID_OPERATOR', 'Invalid operator: ${operator.name}');
  }
  if (!RegExp(r'^[A-Za-z0-9_\-:.]{8,120}$').hasMatch(idempotencyKey)) {
    throw AccountingException('INVALID_KEY', 'Invalid idempotency key');
  }
  final n = now ?? DateTime.now();
  if (date != null && date.toUtc().isAfter(n.toUtc().add(const Duration(minutes: 5)))) {
    throw AccountingException('FUTURE_DATE',
        'ഭാവിയിലെ തീയതി പാടില്ല (Date cannot be in the future)');
  }
}

/// Owner + idempotency key only (flows whose operator comes from the record).
void validateActorAndKey(AccountingActor actor, String idempotencyKey) {
  if (!actor.isOwner) {
    throw AccountingException('PERMISSION_DENIED',
        'ഉടമയ്ക്ക് മാത്രം (Only the owner can post recharge accounting entries)');
  }
  if (!RegExp(r'^[A-Za-z0-9_\-:.]{8,120}$').hasMatch(idempotencyKey)) {
    throw AccountingException('INVALID_KEY', 'Invalid idempotency key');
  }
}

void validateReason(String reason) {
  if (reason.trim().isEmpty) {
    throw AccountingException('REASON_REQUIRED', 'കാരണം നിർബന്ധം (Reason is required)');
  }
}

/// Same mapping as the SQL procedures. Returns null for an unknown mode.
String? normalizePaymentMode(String mode) {
  switch (mode.trim().toLowerCase()) {
    case 'cash':
      return 'cash';
    case 'upi':
      return 'upi';
    case 'cheque':
      return 'cheque';
    case 'bank':
    case 'bank transfer':
    case 'bank_transfer':
      return 'bank_transfer';
  }
  return null;
}

String normalizeModeOrThrow(String mode) {
  final m = normalizePaymentMode(mode);
  if (m == null) {
    throw AccountingException('INVALID_PAYMENT_MODE',
        'പണമടവ് രീതി തെറ്റാണ് (Invalid payment mode: $mode)');
  }
  return m;
}

/// Customer refund methods (RechargePaymentMode names + bank).
String normalizeRefundMethodOrThrow(String method) {
  final m = method.trim().toLowerCase();
  if (const ['cash', 'upi', 'card', 'bank'].contains(m)) return m;
  throw AccountingException('INVALID_REFUND_METHOD',
      'റീഫണ്ട് രീതി തെറ്റാണ് (Invalid refund method: $method)');
}

void validateAmount(int paise, {bool allowNegative = false, bool allowZero = false}) {
  if (paise.abs() > kMaxPostingPaise) {
    throw AccountingException('AMOUNT_LIMIT', 'Amount exceeds ₹10,00,000 limit');
  }
  if (paise == 0 && !allowZero) {
    throw AccountingException('INVALID_AMOUNT', 'തുക പൂജ്യം ആകരുത് (Amount cannot be zero)');
  }
  if (paise < 0 && !allowNegative) {
    throw AccountingException('INVALID_AMOUNT', 'തുക പോസിറ്റീവ് ആയിരിക്കണം (Amount must be positive)');
  }
}

// ---------------------------------------------------------------------------
// Local in-memory backend (tests / localTestMock)
// ---------------------------------------------------------------------------

class _LocalDistributor {
  final String id;
  final String name;
  final RechargeOperator? defaultOperator;
  _LocalDistributor(this.id, this.name, this.defaultOperator);
}

class LocalAccountingBackend implements RechargeAccountingBackend {
  LocalAccountingBackend({
    DateTime Function()? clock,
    this.externalMovements,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// Wallet movements recorded by the rest of the recharge module
  /// (recharges, top-ups, credit loads) - read-only here.
  final Iterable<WalletMovement> Function()? externalMovements;

  final List<WalletMovement> _posted = [];
  final Map<RechargeOperator, List<VerifiedClosing>> _closings = {};
  final Map<String, MorningSnapshot> _morning = {}; // key: periodId
  final List<SettlementEntry> _settlement = [];
  final Map<String, _LocalDistributor> _distributors = {};
  final Map<String, Future<PostingResult>> _idem = {};
  final List<Map<String, dynamic>> auditLog = [];
  final Map<String, LocalRechargeRecord> _recharges = {};
  final Map<String, int> _commissions = {}; // rechargeId -> commission paise
  final Map<String, int> _pendingReturns = {}; // agentReturnKey -> paise
  final Set<String> _onceDone = {}; // "kind|rechargeId"

  /// Cash/bank movements the server recorded (+ in, - out), for tests.
  final List<Map<String, dynamic>> cashBankVouchers = [];

  /// Excess account: morning excess classifications + closing excess.
  final List<ExcessEntry> excessEntries = [];

  /// Distributor top-up commission (profit).
  final List<TopUpCommissionEntry> commissionEntries = [];

  /// Test hook: fails the next posting after validation, before any write.
  bool failNextPosting = false;

  // --- seeding helpers (tests / mock mode) ---------------------------------
  void seedMovement(WalletMovement m) => _posted.add(m);
  void seedClosing(VerifiedClosing c) =>
      (_closings[c.operator] ??= []).add(c);
  void seedDistributor(String id, String name, {RechargeOperator? defaultOperator}) =>
      _distributors[id] = _LocalDistributor(id, name, defaultOperator);
  void seedSettlement(SettlementEntry e) {
    _distributors.putIfAbsent(e.distributorId,
        () => _LocalDistributor(e.distributorId, e.distributorName, e.operator));
    _settlement.add(e);
  }

  void seedRecharge(LocalRechargeRecord r) => _recharges[r.rechargeId] = r;
  void seedCommission(String rechargeId, int paise) => _commissions[rechargeId] = paise;
  LocalRechargeRecord? recharge(String id) => _recharges[id];

  int get postedCount => _posted.length;
  List<WalletMovement> get postedMovements => List.unmodifiable(_posted);
  List<SettlementEntry> get settlementEntries => List.unmodifiable(_settlement);

  Iterable<WalletMovement> get _allMovements sync* {
    yield* _posted;
    final ext = externalMovements?.call();
    if (ext != null) yield* ext;
  }

  VerifiedClosing? _lastClosing(RechargeOperator op) {
    final l = _closings[op];
    if (l == null || l.isEmpty) return null;
    return l.reduce((a, b) => a.at.isAfter(b.at) ? a : b);
  }

  /// Idempotent wrapper: the same key returns the same (first) result, also
  /// while the first call is still in flight. A failed attempt releases the
  /// key so a retry with the same key can succeed.
  Future<PostingResult> _once(String key, Future<PostingResult> Function() body) {
    final existing = _idem[key];
    if (existing != null) {
      return existing.then((r) => PostingResult(r.referenceId, replayed: true, data: r.data));
    }
    final f = Future<PostingResult>(() async {
      await Future<void>.delayed(Duration.zero); // like a network hop
      if (failNextPosting) {
        failNextPosting = false;
        throw AccountingException('NETWORK', 'Simulated network failure');
      }
      return body();
    });
    _idem[key] = f;
    f.catchError((Object _) {
      _idem.remove(key);
      return const PostingResult('');
    });
    return f;
  }

  void _audit(String action, AccountingActor actor, Map<String, dynamic> data) {
    auditLog.add({'action': action, 'by': actor.uid, 'at': _clock().toIso8601String(), ...data});
  }

  @override
  Future<Map<RechargeOperator, OperatorPeriodState>> periodState(String shopId) async {
    final out = <RechargeOperator, OperatorPeriodState>{};
    for (final op in kPeriodOperators) {
      final prev = _lastClosing(op);
      final pid = periodIdFor(op, prev?.at);
      out[op] = OperatorPeriodState(
        operator: op,
        previousClosing: prev,
        movements: movementsInPeriod(_allMovements, op, from: prev?.at),
        morning: _morning[pid],
      );
    }
    return out;
  }

  @override
  Future<PostingResult> verifyMorning({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int morningActualPaise,
    required String idempotencyKey,
  }) {
    validatePostingCommon(actor: actor, operator: operator, idempotencyKey: idempotencyKey);
    validateAmount(morningActualPaise, allowZero: true);
    return _once(idempotencyKey, () async {
      final prev = _lastClosing(operator);
      final pid = periodIdFor(operator, prev?.at);
      if (_morning.containsKey(pid)) {
        throw AccountingException('DUPLICATE_MORNING',
            'ഈ കാലയളവിലെ രാവിലെ ബാലൻസ് ഇതിനകം രേഖപ്പെടുത്തി (Morning balance already entered for this period)');
      }
      if (prev == null) {
        throw AccountingException('PREVIOUS_CLOSING_MISSING',
            'മുൻ ക്ലോസിംഗ് ഇല്ല (Previous closing missing: enter a verified reference balance first)');
      }
      final now = _clock();
      final check = computeMorningCheck(
        operator: operator,
        previousClosing: prev,
        morningActualPaise: morningActualPaise,
        morningAt: now,
        ledger: _allMovements,
      );
      _morning[pid] = MorningSnapshot(morningActualPaise: morningActualPaise, at: now, check: check);
      _audit('MORNING_VERIFY', actor, {'operator': operator.name, 'periodId': pid, 'unexplainedPaise': check.unexplainedPaise});
      return PostingResult('MORNING_$pid', data: {
        'periodId': pid,
        'rawDifferencePaise': check.rawDifferencePaise,
        'alreadyRecordedPaise': check.alreadyRecordedPaise,
        'unexplainedPaise': check.unexplainedPaise,
        'status': check.status.name,
      });
    });
  }

  @override
  Future<PostingResult> postClassified({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required UnexplainedCategory category,
    required int amountPaise,
    required String reason,
    required DateTime transactionDate,
    String? distributorId,
    required String idempotencyKey,
  }) {
    validatePostingCommon(
        actor: actor, operator: operator, idempotencyKey: idempotencyKey,
        date: transactionDate, now: _clock());
    final isAdjustment = category.isAdjustment;
    validateAmount(amountPaise, allowNegative: isAdjustment);
    if (reason.trim().isEmpty) {
      throw AccountingException('REASON_REQUIRED', 'കാരണം നിർബന്ധം (Reason is required)');
    }
    if (category == UnexplainedCategory.topUpDistributorCredit &&
        (distributorId == null || distributorId.isEmpty)) {
      throw AccountingException('DISTRIBUTOR_REQUIRED',
          'ഡിസ്ട്രിബ്യൂട്ടർ തിരഞ്ഞെടുക്കുക (Select the distributor for a credit top-up)');
    }
    return _once(idempotencyKey, () async {
      final prev = _lastClosing(operator);
      if (prev != null && !transactionDate.toUtc().isAfter(prev.at.toUtc()) && !isAdjustment) {
        throw AccountingException('LOCKED_PERIOD',
            'ഈ കാലയളവ് ലോക്ക് ചെയ്തതാണ് (That period is locked. Use a correction adjustment.)');
      }
      final pid = periodIdFor(operator, prev?.at);
      final morning = _morning[pid];
      if (morning != null && !isAdjustment) {
        // A classification can never post more than what is unexplained.
        if (amountPaise > morning.remainingPaise) {
          throw AccountingException('EXCEEDS_UNEXPLAINED',
              'വിശദീകരിക്കാത്ത തുകയേക്കാൾ കൂടുതൽ (Amount is more than the unexplained difference ₹${morning.remainingPaise / 100})');
        }
      }
      if (distributorId != null && !_distributors.containsKey(distributorId) &&
          category == UnexplainedCategory.topUpDistributorCredit) {
        throw AccountingException('UNKNOWN_DISTRIBUTOR', 'Distributor not found');
      }
      final now = _clock();
      final ref = 'ADJ_$idempotencyKey';
      _posted.add(WalletMovement(
          operator: operator, kind: category.movementKind, amountPaise: amountPaise,
          at: now, referenceId: ref));
      if (category == UnexplainedCategory.topUpDistributorCredit) {
        final d = _distributors[distributorId]!;
        _settlement.add(SettlementEntry(
            distributorId: d.id, distributorName: d.name, operator: operator,
            kind: SettlementEntryKind.creditLoad, amountPaise: amountPaise, at: now));
      }
      if (category == UnexplainedCategory.commissionCredit) {
        commissionEntries.add(TopUpCommissionEntry(
            operator: operator, amountPaise: amountPaise, at: now, referenceId: ref));
      }
      if (category == UnexplainedCategory.excess) {
        excessEntries.add(ExcessEntry(
            operator: operator, amountPaise: amountPaise, at: now,
            source: ExcessSource.morning, referenceId: ref));
      }
      if (morning != null) {
        _morning[pid] = MorningSnapshot(
            morningActualPaise: morning.morningActualPaise, at: morning.at,
            check: morning.check, classifiedPaise: morning.classifiedPaise + amountPaise);
      }
      _audit('CLASSIFIED_POSTING', actor, {
        'operator': operator.name, 'category': category.name, 'amountPaise': amountPaise,
        'reason': reason, 'distributorId': distributorId, 'periodId': pid,
        'transactionDate': transactionDate.toIso8601String(),
      });
      return PostingResult(ref, data: {'periodId': pid});
    });
  }

  @override
  Future<PostingResult> postReferenceBalance({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int balancePaise,
    required String reason,
    required String idempotencyKey,
  }) {
    validatePostingCommon(actor: actor, operator: operator, idempotencyKey: idempotencyKey);
    validateAmount(balancePaise, allowZero: true);
    if (reason.trim().isEmpty) {
      throw AccountingException('REASON_REQUIRED', 'കാരണം നിർബന്ധം (Reason is required)');
    }
    return _once(idempotencyKey, () async {
      if (_lastClosing(operator) != null) {
        throw AccountingException('REFERENCE_NOT_ALLOWED',
            'A verified closing already exists; use a correction adjustment instead');
      }
      final now = _clock();
      final c = VerifiedClosing(
          operator: operator, actualPaise: balancePaise, at: now,
          periodId: periodIdFor(operator, null));
      seedClosing(c);
      _audit('REFERENCE_BALANCE', actor, {'operator': operator.name, 'balancePaise': balancePaise, 'reason': reason});
      return PostingResult('REF_${operator.name}', data: {'periodId': c.periodId});
    });
  }

  @override
  Future<PostingResult> verifyClosing({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int actualPaise,
    String reason = '',
    required String idempotencyKey,
  }) {
    validatePostingCommon(actor: actor, operator: operator, idempotencyKey: idempotencyKey);
    validateAmount(actualPaise, allowZero: true);
    return _once(idempotencyKey, () async {
      final prev = _lastClosing(operator);
      if (prev == null) {
        throw AccountingException('PREVIOUS_CLOSING_MISSING',
            'മുൻ ക്ലോസിംഗ് ഇല്ല (Previous closing missing: enter a verified reference balance first)');
      }
      final now = _clock();
      final b = computeClosing(
          operator: operator, previousClosing: prev, ledger: _allMovements,
          closingAt: now, actualClosingPaise: actualPaise);
      if (b.variancePaise != 0 && reason.trim().isEmpty) {
        throw AccountingException('REASON_REQUIRED',
            'വ്യത്യാസത്തിന് കാരണം വേണം (A reason is required when there is a variance)');
      }
      seedClosing(VerifiedClosing(
          operator: operator, actualPaise: actualPaise, at: now, periodId: b.periodId));
      final v = b.variancePaise ?? 0;
      if (v > 0) {
        excessEntries.add(ExcessEntry(
            operator: operator, amountPaise: v, at: now,
            source: ExcessSource.closing, referenceId: 'CLOSE_${b.periodId}'));
      }
      _audit('CLOSING_VERIFY', actor, {
        'operator': operator.name, 'periodId': b.periodId,
        'expectedPaise': b.expectedClosingPaise, 'actualPaise': actualPaise,
        'variancePaise': b.variancePaise, 'status': b.status?.name, 'reason': reason,
      });
      return PostingResult('CLOSE_${b.periodId}', data: {
        'periodId': b.periodId,
        'expectedPaise': b.expectedClosingPaise,
        'variancePaise': b.variancePaise,
        'status': b.status?.name,
      });
    });
  }

  @override
  Future<PostingResult> distributorPayment({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int amountPaise,
    required String paymentMode,
    required DateTime paymentDate,
    String referenceNo = '',
    String notes = '',
    required String idempotencyKey,
  }) {
    validatePostingCommon(
        actor: actor, operator: operator, idempotencyKey: idempotencyKey,
        date: paymentDate, now: _clock());
    validateAmount(amountPaise);
    return _once(idempotencyKey, () async {
      final d = _distributors[distributorId];
      if (d == null) throw AccountingException('UNKNOWN_DISTRIBUTOR', 'Distributor not found');
      final before = computeSettlement(_settlement).account(distributorId, operator);
      final beforeBal = before?.balancePaise ?? 0;
      _settlement.add(SettlementEntry(
          distributorId: d.id, distributorName: d.name, operator: operator,
          kind: SettlementEntryKind.payment, amountPaise: amountPaise, at: paymentDate));
      cashBankVouchers.add({
        'id': 'CB_PAY_$idempotencyKey', 'mode': normalizePaymentMode(paymentMode) ?? paymentMode,
        'paise': -amountPaise, 'category': 'DISTRIBUTOR_PAYMENT',
        'date': istBusinessDate(paymentDate),
      });
      final after = beforeBal - amountPaise;
      _audit('DISTRIBUTOR_PAYMENT', actor, {
        'distributorId': distributorId, 'operator': operator.name, 'amountPaise': amountPaise,
        'mode': paymentMode, 'referenceNo': referenceNo, 'balanceBeforePaise': beforeBal,
        'balanceAfterPaise': after,
      });
      return PostingResult('PAY_$idempotencyKey', data: {
        'balanceBeforePaise': beforeBal,
        'balanceAfterPaise': after,
        'outstandingPaise': after > 0 ? after : 0,
        'advancePaise': after < 0 ? -after : 0,
      });
    });
  }

  @override
  Future<SettlementSummary> settlement(String shopId) async => computeSettlement(_settlement);

  // ----- Legacy flows moved to the server path (v2.1) ----------------------

  _LocalDistributor _distributor(String id) {
    final d = _distributors[id];
    if (d == null) throw AccountingException('UNKNOWN_DISTRIBUTOR', 'Distributor not found');
    return d;
  }

  LocalRechargeRecord _rechargeOrThrow(String id) {
    final r = _recharges[id];
    if (r == null) {
      throw AccountingException('UNKNOWN_RECHARGE',
          'റീചാർജ് ഇടപാട് കണ്ടെത്താനായില്ല (Recharge not found on the server: $id)');
    }
    return r;
  }

  @override
  Future<PostingResult> agentSettlement({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int totalPayablePaise,
    required int rechargeAdjustmentPaise,
    required String paymentMode,
    required DateTime paymentDate,
    String referenceNo = '',
    String notes = '',
    required String idempotencyKey,
  }) {
    validatePostingCommon(
        actor: actor, operator: operator, idempotencyKey: idempotencyKey,
        date: paymentDate, now: _clock());
    validateAmount(totalPayablePaise);
    validateAmount(rechargeAdjustmentPaise, allowZero: true);
    if (rechargeAdjustmentPaise > totalPayablePaise) {
      throw AccountingException('ADJUSTMENT_EXCEEDS_TOTAL',
          'റീചാർജ് അഡ്ജസ്റ്റ്മെന്റ് ആകെ തുകയേക്കാൾ കൂടരുത് (Recharge adjustment cannot exceed total payable)');
    }
    final mode = normalizeModeOrThrow(paymentMode);
    return _once(idempotencyKey, () async {
      final d = _distributor(distributorId);
      final before = computeSettlement(_settlement).account(distributorId, operator)?.balancePaise ?? 0;
      final actual = totalPayablePaise - rechargeAdjustmentPaise;
      _settlement.add(SettlementEntry(
          distributorId: d.id, distributorName: d.name, operator: operator,
          kind: SettlementEntryKind.payment, amountPaise: totalPayablePaise, at: paymentDate));
      final rk = agentReturnKey(distributorId, operator);
      final pendingAfter = (_pendingReturns[rk] ?? 0) + rechargeAdjustmentPaise;
      _pendingReturns[rk] = pendingAfter;
      final ref = 'SETTLE_$idempotencyKey';
      if (actual > 0) {
        cashBankVouchers.add({'id': 'CB_$ref', 'mode': mode, 'paise': -actual, 'category': 'AGENT_SETTLEMENT',
            'date': istBusinessDate(paymentDate)});
      }
      final after = before - totalPayablePaise;
      _audit('AGENT_SETTLEMENT', actor, {
        'distributorId': distributorId, 'operator': operator.name, 'totalPaise': totalPayablePaise,
        'adjustmentPaise': rechargeAdjustmentPaise, 'actualPaise': actual, 'mode': mode,
        'referenceNo': referenceNo, 'balanceBeforePaise': before, 'balanceAfterPaise': after,
      });
      return PostingResult(ref, data: {
        'balanceBeforePaise': before,
        'balanceAfterPaise': after,
        'outstandingPaise': after > 0 ? after : 0,
        'advancePaise': after < 0 ? -after : 0,
        'actualPaymentPaise': actual,
        'pendingReturnPaise': pendingAfter,
      });
    });
  }

  @override
  Future<PostingResult> agentReturn({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int returnPaise,
    required String returnMode,
    required DateTime returnDate,
    String referenceNo = '',
    String notes = '',
    required String idempotencyKey,
  }) {
    validatePostingCommon(
        actor: actor, operator: operator, idempotencyKey: idempotencyKey,
        date: returnDate, now: _clock());
    validateAmount(returnPaise);
    final mode = normalizeModeOrThrow(returnMode);
    return _once(idempotencyKey, () async {
      _distributor(distributorId);
      final rk = agentReturnKey(distributorId, operator);
      final pending = _pendingReturns[rk] ?? 0;
      if (returnPaise > pending) {
        throw AccountingException('EXCEEDS_PENDING_RETURN',
            'തിരികെ ലഭിക്കേണ്ട തുകയേക്കാൾ കൂടുതൽ (Return is more than the pending return ₹${pending / 100})');
      }
      _pendingReturns[rk] = pending - returnPaise;
      final ref = 'RET_$idempotencyKey';
      cashBankVouchers.add({'id': 'CB_$ref', 'mode': mode, 'paise': returnPaise, 'category': 'RECHARGE_AMOUNT_RETURN',
            'date': istBusinessDate(returnDate)});
      _audit('AGENT_RETURN', actor, {
        'distributorId': distributorId, 'operator': operator.name, 'returnPaise': returnPaise,
        'mode': mode, 'pendingBeforePaise': pending, 'pendingAfterPaise': pending - returnPaise,
      });
      return PostingResult(ref, data: {
        'pendingBeforePaise': pending,
        'pendingReturnPaise': pending - returnPaise,
      });
    });
  }

  @override
  Future<PostingResult> alignWallet({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int ownPaise,
    required int creditPaise,
    required String reason,
    required String idempotencyKey,
  }) {
    validatePostingCommon(actor: actor, operator: operator, idempotencyKey: idempotencyKey);
    if (ownPaise < 0 || creditPaise < 0) {
      throw AccountingException('INVALID_AMOUNT', 'Own and credit must be zero or more');
    }
    validateAmount(ownPaise + creditPaise, allowZero: true);
    validateReason(reason);
    return _once(idempotencyKey, () async {
      final st = (await periodState(shopId))[operator]!;
      if (st.previousClosing == null) {
        throw AccountingException('PREVIOUS_CLOSING_MISSING',
            'മുൻ ക്ലോസിംഗ് ഇല്ല (Previous closing missing: enter a verified reference balance first)');
      }
      final expected = st.closing(at: _clock()).expectedClosingPaise;
      if (ownPaise + creditPaise != expected) {
        throw AccountingException('ALIGNMENT_MISMATCH',
            'Own + credit must equal the current verified balance ₹${expected / 100}');
      }
      _audit('WALLET_OPENING_ALIGNMENT', actor, {
        'operator': operator.name, 'ownPaise': ownPaise, 'creditPaise': creditPaise, 'reason': reason,
      });
      return PostingResult('ALIGN_$idempotencyKey', data: {'balanceAfterPaise': ownPaise + creditPaise});
    });
  }

  @override
  Future<PostingResult> distributorOpeningDues({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int amountPaise,
    required String reason,
    required String idempotencyKey,
  }) {
    validatePostingCommon(actor: actor, operator: operator, idempotencyKey: idempotencyKey);
    validateAmount(amountPaise);
    validateReason(reason);
    return _once(idempotencyKey, () async {
      final d = _distributor(distributorId);
      final before = computeSettlement(_settlement).account(distributorId, operator)?.balancePaise ?? 0;
      final postedBefore = postedCount;
      _settlement.add(SettlementEntry(
          distributorId: d.id, distributorName: d.name, operator: operator,
          kind: SettlementEntryKind.openingPayable, amountPaise: amountPaise, at: _clock()));
      assert(postedCount == postedBefore); // no wallet movement
      _audit('DISTRIBUTOR_OPENING_DUES', actor, {
        'distributorId': distributorId, 'operator': operator.name, 'amountPaise': amountPaise, 'reason': reason,
      });
      return PostingResult('ODUE_$idempotencyKey', data: {
        'balanceBeforePaise': before,
        'balanceAfterPaise': before + amountPaise,
      });
    });
  }

  @override
  Future<PostingResult> distributorCreditReversal({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int amountPaise,
    required String reason,
    required String idempotencyKey,
  }) {
    validatePostingCommon(actor: actor, operator: operator, idempotencyKey: idempotencyKey);
    validateAmount(amountPaise);
    validateReason(reason);
    return _once(idempotencyKey, () async {
      final d = _distributor(distributorId);
      final acc = computeSettlement(_settlement).account(distributorId, operator);
      final payable = acc?.payablePaise ?? 0;
      if (amountPaise > payable) {
        throw AccountingException('EXCEEDS_PAYABLE',
            'ക്രെഡിറ്റിനേക്കാൾ കൂടുതൽ തിരിച്ചെടുക്കാനാവില്ല (Cannot reverse more than the credit payable ₹${payable / 100})');
      }
      final before = acc?.balancePaise ?? 0;
      _settlement.add(SettlementEntry(
          distributorId: d.id, distributorName: d.name, operator: operator,
          kind: SettlementEntryKind.adjustment, amountPaise: amountPaise, at: _clock()));
      _audit('DISTRIBUTOR_CREDIT_REVERSAL', actor, {
        'distributorId': distributorId, 'operator': operator.name, 'amountPaise': amountPaise, 'reason': reason,
      });
      return PostingResult('DREV_$idempotencyKey', data: {
        'balanceBeforePaise': before,
        'balanceAfterPaise': before - amountPaise,
      });
    });
  }

  @override
  Future<PostingResult> customerRefund({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required int refundPaise,
    required String refundMethod,
    required String reason,
    required String idempotencyKey,
  }) {
    validateActorAndKey(actor, idempotencyKey);
    validateAmount(refundPaise);
    validateReason(reason);
    final method = normalizeRefundMethodOrThrow(refundMethod);
    return _once(idempotencyKey, () async {
      final r = _rechargeOrThrow(rechargeId);
      if (!r.paymentCollected) {
        throw AccountingException('PAYMENT_NOT_COLLECTED',
            'ഉപഭോക്താവിൽ നിന്ന് പണം ഈടാക്കിയിട്ടില്ല (Cannot refund: no customer payment was collected)');
      }
      if (_onceDone.contains('refund|$rechargeId') || r.status == 'refunded') {
        throw AccountingException('ALREADY_REFUNDED',
            'ഈ റീചാർജിന് ഇതിനകം റീഫണ്ട് നൽകി (This recharge was already refunded)');
      }
      if (refundPaise > r.amountPaise) {
        throw AccountingException('EXCEEDS_RECHARGE',
            'റീഫണ്ട് തുക റീചാർജ് തുകയേക്കാൾ കൂടരുത് (Refund cannot exceed the recharge amount)');
      }
      _onceDone.add('refund|$rechargeId');
      r.status = 'refunded';
      final ref = 'REFUND_$idempotencyKey';
      _audit('CUSTOMER_REFUND', actor, {
        'rechargeId': rechargeId, 'operator': r.operator.name, 'refundPaise': refundPaise,
        'method': method, 'reason': reason,
      });
      return PostingResult(ref, data: {
        'rechargeId': rechargeId,
        'refundPaise': refundPaise,
        'refundMethod': method,
        'status': 'refunded',
      });
    });
  }

  @override
  Future<PostingResult> failedRechargeReversal({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required String reason,
    required String idempotencyKey,
  }) {
    validateActorAndKey(actor, idempotencyKey);
    validateReason(reason);
    return _once(idempotencyKey, () async {
      final r = _rechargeOrThrow(rechargeId);
      if (r.status == 'failed' || _onceDone.contains('failed|$rechargeId')) {
        return PostingResult('FAILREV_$rechargeId',
            data: {'alreadyFailed': true, 'walletCreditPaise': 0, 'status': 'failed'});
      }
      if (r.status != 'pending' && r.status != 'completed') {
        throw AccountingException('INVALID_STATUS',
            'ഈ നിലയിലുള്ള റീചാർജ് റദ്ദാക്കാനാവില്ല (A ${r.status} recharge cannot be marked failed)');
      }
      _onceDone.add('failed|$rechargeId');
      r.status = 'failed';
      var credit = 0;
      if (r.walletDebited) {
        credit = r.amountPaise;
        _posted.add(WalletMovement(
            operator: r.operator, kind: WalletMovementKind.refundCredit,
            amountPaise: credit, at: _clock(), referenceId: 'FAILREV_$rechargeId'));
      }
      _audit('FAILED_RECHARGE_REVERSAL', actor, {
        'rechargeId': rechargeId, 'operator': r.operator.name, 'walletCreditPaise': credit, 'reason': reason,
      });
      return PostingResult('FAILREV_$rechargeId',
          data: {'alreadyFailed': false, 'walletCreditPaise': credit, 'status': 'failed'});
    });
  }

  void _requireUnlockedRecharge(LocalRechargeRecord r) {
    final prev = _lastClosing(r.operator);
    final at = r.createdAt;
    if (prev != null && at != null && !at.toUtc().isAfter(prev.at.toUtc())) {
      throw AccountingException('LOCKED_PERIOD',
          'ഈ ദിവസത്തെ ക്ലോസിങ് കഴിഞ്ഞു, തിരുത്താനാവില്ല (The closing after this recharge is verified; it cannot be changed.)');
    }
  }

  @override
  Future<PostingResult> correctRecharge({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required String reason,
    required String idempotencyKey,
  }) {
    validateActorAndKey(actor, idempotencyKey);
    validateReason(reason);
    return _once(idempotencyKey, () async {
      final r = _rechargeOrThrow(rechargeId);
      if (_onceDone.contains('correct|$rechargeId')) {
        return PostingResult('CORR_$rechargeId', replayed: true,
            data: {'walletCreditPaise': r.walletDebited ? r.amountPaise : 0, 'status': 'reversed'});
      }
      if (r.status != 'completed') {
        throw AccountingException('INVALID_STATUS',
            'ഈ നിലയിലുള്ള റീചാർജ് തിരുത്താനാവില്ല (A ${r.status} recharge cannot be corrected)');
      }
      _requireUnlockedRecharge(r);
      _onceDone.add('correct|$rechargeId');
      r.status = 'reversed';
      var credit = 0;
      if (r.walletDebited) {
        credit = r.amountPaise;
        _posted.add(WalletMovement(
            operator: r.operator, kind: WalletMovementKind.refundCredit,
            amountPaise: credit, at: _clock(), referenceId: 'CORR_$rechargeId'));
      }
      _audit('RECHARGE_CORRECTION', actor, {
        'rechargeId': rechargeId, 'operator': r.operator.name, 'walletCreditPaise': credit, 'reason': reason,
      });
      return PostingResult('CORR_$rechargeId',
          data: {'walletCreditPaise': credit, 'status': 'reversed'});
    });
  }

  @override
  Future<PostingResult> editRechargeDetails({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    String? customerPhone,
    String? paymentMode,
    required String reason,
    required String idempotencyKey,
  }) {
    validateActorAndKey(actor, idempotencyKey);
    validateReason(reason);
    final phone = customerPhone?.trim() ?? '';
    final mode = paymentMode?.trim() ?? '';
    if (phone.isEmpty && mode.isEmpty) {
      throw AccountingException('NOTHING_TO_CHANGE', 'മാറ്റമൊന്നുമില്ല (Nothing to change)');
    }
    if (phone.isNotEmpty && !RegExp(r'^[0-9]{10}$').hasMatch(phone)) {
      throw AccountingException('INVALID_PHONE', 'മൊബൈൽ നമ്പർ 10 അക്കം (Mobile number must be 10 digits)');
    }
    if (mode.isNotEmpty && mode != 'Cash' && mode != 'UPI') {
      throw AccountingException('INVALID_PAYMENT_MODE', 'Cash or UPI only');
    }
    return _once(idempotencyKey, () async {
      final r = _rechargeOrThrow(rechargeId);
      if (r.status != 'completed') {
        throw AccountingException('INVALID_STATUS',
            'ഈ നിലയിലുള്ള റീചാർജ് മാറ്റാനാവില്ല (A ${r.status} recharge cannot be edited)');
      }
      if (mode.isNotEmpty && r.paymentMode != 'Cash' && r.paymentMode != 'UPI') {
        throw AccountingException('INVALID_PAYMENT_MODE',
            'Credit / Due റീചാർജിന് "Correct" ഉപയോഗിക്കുക (Use a correction for a Credit / Due recharge)');
      }
      _requireUnlockedRecharge(r);
      final old = {'phone': r.customerPhone, 'mode': r.paymentMode};
      if (phone.isNotEmpty) r.customerPhone = phone;
      if (mode.isNotEmpty) r.paymentMode = mode;
      _audit('RECHARGE_DETAIL_EDIT', actor, {
        'rechargeId': rechargeId, 'old': old, 'phone': r.customerPhone, 'mode': r.paymentMode, 'reason': reason,
      });
      return PostingResult('EDIT_$idempotencyKey',
          data: {'customerPhone': r.customerPhone, 'paymentMode': r.paymentMode});
    });
  }

  @override
  Future<PostingResult> commissionReversal({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required bool clawbackFromWallet,
    required String reason,
    required String idempotencyKey,
  }) {
    validateActorAndKey(actor, idempotencyKey);
    validateReason(reason);
    return _once(idempotencyKey, () async {
      final r = _rechargeOrThrow(rechargeId);
      final comm = _commissions[rechargeId];
      if (comm == null || comm <= 0) {
        throw AccountingException('UNKNOWN_COMMISSION',
            'കമ്മീഷൻ രേഖ കണ്ടെത്താനായില്ല (No server commission for this recharge)');
      }
      if (_onceDone.contains('commission|$rechargeId')) {
        throw AccountingException('ALREADY_REVERSED',
            'ഈ കമ്മീഷൻ ഇതിനകം തിരിച്ചെടുത്തു (Commission already reversed)');
      }
      _onceDone.add('commission|$rechargeId');
      if (clawbackFromWallet) {
        _posted.add(WalletMovement(
            operator: r.operator, kind: WalletMovementKind.commissionClawback,
            amountPaise: comm, at: _clock(), referenceId: 'COMMREV_$rechargeId'));
      }
      _audit('COMMISSION_REVERSAL', actor, {
        'rechargeId': rechargeId, 'operator': r.operator.name, 'commissionPaise': comm,
        'clawback': clawbackFromWallet, 'reason': reason,
      });
      return PostingResult('COMMREV_$rechargeId', data: {
        'commissionPaise': comm,
        'walletClawbackPaise': clawbackFromWallet ? comm : 0,
      });
    });
  }

  @override
  Future<Map<String, int>> agentPendingReturns(String shopId) async =>
      Map.unmodifiable(_pendingReturns);

  @override
  Future<ExcessSummary> excessSummary(String shopId) async => ExcessSummary(excessEntries);

  @override
  Future<PostingResult> topUpCommission({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    String? distributorId,
    required int commissionPaise,
    required String reason,
    required String idempotencyKey,
  }) {
    validatePostingCommon(actor: actor, operator: operator, idempotencyKey: idempotencyKey);
    validateAmount(commissionPaise);
    validateReason(reason);
    return _once(idempotencyKey, () async {
      if (distributorId != null && distributorId.isNotEmpty) _distributor(distributorId);
      final now = _clock();
      final ref = 'TUC_$idempotencyKey';
      // Not a classification: never touches the morning remainder.
      _posted.add(WalletMovement(
          operator: operator, kind: WalletMovementKind.commissionCredit,
          amountPaise: commissionPaise, at: now, referenceId: ref));
      commissionEntries.add(TopUpCommissionEntry(
          operator: operator, amountPaise: commissionPaise, at: now, referenceId: ref));
      _audit('TOPUP_COMMISSION', actor, {
        'operator': operator.name, 'distributorId': distributorId,
        'commissionPaise': commissionPaise, 'reason': reason,
      });
      return PostingResult(ref, data: {'commissionPaise': commissionPaise});
    });
  }

  @override
  Future<TopUpCommissionSummary> topUpCommissionSummary(String shopId) async =>
      TopUpCommissionSummary(commissionEntries);

  @override
  Future<int> distributorCashForDate(String shopId, String dateString) async =>
      cashBankVouchers
          .where((v) => v['mode'] == 'cash' && v['date'] == dateString)
          .fold<int>(0, (a, v) => a + (v['paise'] as int));
}
