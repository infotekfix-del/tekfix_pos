// ============================================================================
// TEKFIX ERP - QUICK RECHARGE ACCOUNTING SERVICE (period reconciliation,
// cumulative volume, operator-wise distributor settlement)
// ============================================================================
//
// * Picks the backend from the existing RechargeBackendBridge mode:
//     supabaseEdgeFunction -> SupabaseAccountingBackend (server-authoritative)
//     localTestMock        -> LocalAccountingBackend (in-memory)
//     firebaseCloudFunction-> not supported: fails closed.
// * Every posting is owner-only and online-only. When offline the action is
//   blocked before anything is sent; nothing is queued.
// * Each form gets an idempotency key before the first attempt. The key is
//   kept (as a form draft, not a financial record) until the server confirms,
//   so a retry after a network error or an app restart reuses it.
// ============================================================================

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import '../security/device_security_service.dart';
import 'recharge_accounting_backend.dart';
import 'recharge_backend_bridge.dart';
import 'recharge_models.dart';
import 'recharge_period_accounting.dart';
import 'recharge_service.dart';

/// Hive box holding only pending-form idempotency keys (form drafts).
const String boxRechargePendingKeys = 'recharge_pending_posting_keys';

class PendingPostingKeys {
  PendingPostingKeys({Box? box, this.memoryOnly = false}) : _box = box;
  Box? _box;

  /// Tests only: keep keys in memory (no Hive).
  final bool memoryOnly;
  final Map<String, String> _memory = {};
  static const _uuid = Uuid();

  Future<Box?> _open() async {
    if (memoryOnly) return null;
    if (_box != null) return _box;
    try {
      _box = Hive.isBoxOpen(boxRechargePendingKeys)
          ? Hive.box(boxRechargePendingKeys)
          : await Hive.openBox(boxRechargePendingKeys);
    } catch (_) {
      _box = null; // Hive not initialised (tests): memory only
    }
    return _box;
  }

  /// The key for this form. Same form signature -> same key until cleared.
  Future<String> keyFor(String formSignature) async {
    final b = await _open();
    final existing = (b?.get(formSignature) as String?) ?? _memory[formSignature];
    if (existing != null) return existing;
    final k = 'IDK_${_uuid.v4().replaceAll('-', '')}';
    _memory[formSignature] = k;
    await b?.put(formSignature, k);
    return k;
  }

  Future<void> clear(String formSignature) async {
    _memory.remove(formSignature);
    final b = await _open();
    await b?.delete(formSignature);
  }

  Future<bool> has(String formSignature) async {
    final b = await _open();
    return _memory.containsKey(formSignature) || (b?.containsKey(formSignature) ?? false);
  }
}

class RechargeAccountingService {
  RechargeAccountingService._();
  static final RechargeAccountingService instance = RechargeAccountingService._();

  RechargeAccountingBackend? _override;
  LocalAccountingBackend? _local;
  PendingPostingKeys pendingKeys = PendingPostingKeys();

  /// Returns true when there is a network. Replaceable in tests.
  Future<bool> Function() isOnline = _defaultIsOnline;

  static Future<bool> _defaultIsOnline() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.any((c) => c != ConnectivityResult.none);
    } catch (_) {
      return false; // fail closed
    }
  }

  @visibleForTesting
  void useBackendForTesting(RechargeAccountingBackend? b) => _override = b;

  @visibleForTesting
  void resetForTesting() {
    _override = null;
    _local = null;
    isOnline = _defaultIsOnline;
    pendingKeys = PendingPostingKeys();
  }

  RechargeAccountingBackend get backend {
    if (_override != null) return _override!;
    switch (RechargeBackendBridge.mode) {
      case RechargeBackendMode.supabaseEdgeFunction:
        if (RechargeBackendBridge.supabaseClient == null) {
          return _UnavailableBackend();
        }
        return SupabaseAccountingBackend();
      case RechargeBackendMode.localTestMock:
        return _local ??= LocalAccountingBackend(
            externalMovements: () => legacyMovements(RechargeService.instance.getLocalWalletLedger()));
      case RechargeBackendMode.firebaseCloudFunction:
        return _UnavailableBackend();
    }
  }

  /// Converts the existing wallet log entries to movements (read-only).
  static List<WalletMovement> legacyMovements(Iterable<WalletLedgerEntry> logs) {
    final out = <WalletMovement>[];
    for (final e in logs) {
      final k = WalletMovement.kindFromLegacy(e.entryType);
      if (k == null || !kPeriodOperators.contains(e.operator)) continue;
      out.add(WalletMovement(
        operator: e.operator,
        kind: k,
        amountPaise: k == WalletMovementKind.adjustment
            ? e.balanceAfterPaise - e.balanceBeforePaise
            : e.amountPaise,
        at: e.timestamp,
        referenceId: e.referenceId,
      ));
    }
    return out;
  }

  Future<void> _guard(AccountingActor actor) async {
    if (!actor.isOwner) {
      throw AccountingException('PERMISSION_DENIED',
          'ഉടമയ്ക്ക് മാത്രം (Only the owner can do Recharge Accounting)');
    }
    if (!await isOnline()) {
      throw AccountingException('OFFLINE',
          'ഇന്റർനെറ്റ് ഇല്ല. ഇത് ഓൺലൈനിൽ മാത്രം ചെയ്യാം (You are offline. Recharge accounting entries need the internet; nothing was saved.)');
    }
  }

  /// Runs a posting with a persisted idempotency key for [formSignature].
  /// The key is cleared only after the server confirms.
  Future<PostingResult> _post(String formSignature, AccountingActor actor,
      Future<PostingResult> Function(String key) call) async {
    await _guard(actor);
    final key = await pendingKeys.keyFor(formSignature);
    final r = await call(key);
    await pendingKeys.clear(formSignature);
    return r;
  }

  // ------------------------------------------------------------------ reads
  Future<Map<RechargeOperator, OperatorPeriodState>> periodState(String shopId) =>
      backend.periodState(shopId);

  Future<SettlementSummary> settlement(String shopId) => backend.settlement(shopId);

  /// Recharge volume from the authoritative recharge records already held
  /// on this device (no extra history download).
  /// Counted from the shop's fresh start ([kRechargeFreshStartIstDate]) only.
  VolumeSummary volume(String shopId, IstRange range) => computeVolume(
      RechargeService.instance
          .getLocalRecharges(shopId: shopId)
          .map(VolumeTxn.fromEntry),
      clampToFreshStart(range));

  // --------------------------------------------------------------- postings
  Future<PostingResult> verifyMorning({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int morningActualPaise,
    required String periodId,
  }) =>
      _post('morning|$shopId|$periodId|${operator.name}|$morningActualPaise', actor,
          (k) => backend.verifyMorning(
              shopId: shopId, actor: actor, operator: operator,
              morningActualPaise: morningActualPaise, idempotencyKey: k));

  Future<PostingResult> postClassified({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required UnexplainedCategory category,
    required int amountPaise,
    required String reason,
    required DateTime transactionDate,
    String? distributorId,
    required String periodId,
  }) =>
      _post('classify|$shopId|$periodId|${operator.name}|${category.name}|$amountPaise|${distributorId ?? ''}', actor,
          (k) => backend.postClassified(
              shopId: shopId, actor: actor, operator: operator, category: category,
              amountPaise: amountPaise, reason: reason, transactionDate: transactionDate,
              distributorId: distributorId, idempotencyKey: k));

  Future<PostingResult> postReferenceBalance({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int balancePaise,
    required String reason,
  }) =>
      _post('reference|$shopId|${operator.name}|$balancePaise', actor,
          (k) => backend.postReferenceBalance(
              shopId: shopId, actor: actor, operator: operator,
              balancePaise: balancePaise, reason: reason, idempotencyKey: k));

  Future<PostingResult> verifyClosing({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int actualPaise,
    required String periodId,
    String reason = '',
  }) =>
      _post('closing|$shopId|$periodId|${operator.name}|$actualPaise', actor,
          (k) => backend.verifyClosing(
              shopId: shopId, actor: actor, operator: operator,
              actualPaise: actualPaise, reason: reason, idempotencyKey: k));

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
  }) =>
      _post(
          'payment|$shopId|$distributorId|${operator.name}|$amountPaise|$paymentMode|${istBusinessDate(paymentDate)}|$referenceNo',
          actor,
          (k) => backend.distributorPayment(
              shopId: shopId, actor: actor, distributorId: distributorId,
              operator: operator, amountPaise: amountPaise, paymentMode: paymentMode,
              paymentDate: paymentDate, referenceNo: referenceNo, notes: notes,
              idempotencyKey: k));

  /// Re-classifies an already-posted own-money top-up as distributor credit.
  /// Two classified postings with their own idempotency keys:
  ///   1. manualCorrection  -X  (own-money balance down)
  ///   2. topUpDistributorCredit +X for [distributorId] (credit balance and
  ///      distributor dues up)
  /// The wallet total is unchanged. Both keys are kept until step 2 is
  /// confirmed, so a retry of the same form replays step 1 (never posts it
  /// twice) and then posts step 2. If step 2 fails, a RECLASSIFY_INCOMPLETE
  /// error says so explicitly.
  Future<({PostingResult correction, PostingResult credit})> reclassifyOwnTopUpToDistributor({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int amountPaise,
    required String distributorId,
    required String reason,
  }) async {
    await _guard(actor);
    if (amountPaise <= 0) {
      throw AccountingException('INVALID_AMOUNT', 'തുക പോസിറ്റീവ് ആയിരിക്കണം (Amount must be positive)');
    }
    if (distributorId.trim().isEmpty) {
      throw AccountingException('DISTRIBUTOR_REQUIRED',
          'ഡിസ്ട്രിബ്യൂട്ടർ തിരഞ്ഞെടുക്കുക (Select the distributor)');
    }
    if (reason.trim().isEmpty) {
      throw AccountingException('REASON_REQUIRED', 'കാരണം നിർബന്ധം (Reason is required)');
    }
    final sig = 'reclass|$shopId|${operator.name}|$amountPaise|$distributorId';
    final k1 = await pendingKeys.keyFor('$sig|1');
    final k2 = await pendingKeys.keyFor('$sig|2');
    final why = 'Own → Distributor ($distributorId): ${reason.trim()}';
    final now = DateTime.now();
    final correction = await backend.postClassified(
        shopId: shopId, actor: actor, operator: operator,
        category: UnexplainedCategory.manualCorrection, amountPaise: -amountPaise,
        reason: why, transactionDate: now, idempotencyKey: k1);
    final PostingResult credit;
    try {
      credit = await backend.postClassified(
          shopId: shopId, actor: actor, operator: operator,
          category: UnexplainedCategory.topUpDistributorCredit, amountPaise: amountPaise,
          reason: why, transactionDate: now, distributorId: distributorId, idempotencyKey: k2);
    } catch (e) {
      throw AccountingException('RECLASSIFY_INCOMPLETE',
          'പകുതി മാത്രം പൂർത്തിയായി: own-money ൽ നിന്ന് ${formatInrPaise(amountPaise)} കുറച്ചു, പക്ഷേ distributor credit ചേർത്തില്ല. ഇതേ വിവരങ്ങളോടെ വീണ്ടും ശ്രമിക്കുക (Only step 1 of 2 is posted: own money was reduced by ${formatInrPaise(amountPaise)} but the distributor credit was NOT added. Retry with the same operator, amount and distributor to finish; step 1 will not be posted again.) [$e]');
    }
    await pendingKeys.clear('$sig|1');
    await pendingKeys.clear('$sig|2');
    return (correction: correction, credit: credit);
  }

  /// True while a reclassification of this exact form is half done.
  Future<bool> reclassifyPending({
    required String shopId,
    required RechargeOperator operator,
    required int amountPaise,
    required String distributorId,
  }) =>
      pendingKeys.has('reclass|$shopId|${operator.name}|$amountPaise|$distributorId|2');

  // ------------------------------- legacy flows on the server path (v2.1)
  Future<Map<String, int>> agentPendingReturns(String shopId) =>
      backend.agentPendingReturns(shopId);

  Future<ExcessSummary> excessSummary(String shopId) => backend.excessSummary(shopId);

  Future<TopUpCommissionSummary> topUpCommissionSummary(String shopId) =>
      backend.topUpCommissionSummary(shopId);

  Future<int> distributorCashForDate(String shopId, String dateString) =>
      backend.distributorCashForDate(shopId, dateString);

  /// Commission part of a mid-day distributor refill (after the payable part
  /// was saved as a distributor credit load).
  Future<PostingResult> topUpCommission({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    String? distributorId,
    required int commissionPaise,
    required String formTag,
  }) =>
      _post('tucomm|$shopId|${operator.name}|${distributorId ?? ''}|$commissionPaise|$formTag', actor,
          (k) => backend.topUpCommission(
              shopId: shopId, actor: actor, operator: operator, distributorId: distributorId,
              commissionPaise: commissionPaise,
              reason: 'Distributor top-up commission', idempotencyKey: k));

  /// Morning Entry: a refill received as [receivedPaise] that includes
  /// [commissionPaise] -> (received - commission) distributor credit
  /// (payable) + commission credit (profit). Both keys are kept until the
  /// second posting is confirmed, so a retry never posts the first twice.
  Future<({PostingResult credit, PostingResult? commission})> postDistributorCreditWithCommission({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int receivedPaise,
    required int commissionPaise,
    required String distributorId,
    required String reason,
    required String periodId,
  }) async {
    await _guard(actor);
    if (commissionPaise < 0 || commissionPaise >= receivedPaise) {
      throw AccountingException('INVALID_COMMISSION',
          'കമ്മീഷൻ തുക തെറ്റാണ് (Commission must be less than the amount received)');
    }
    final sig = 'credcomm|$shopId|$periodId|${operator.name}|$receivedPaise|$commissionPaise|$distributorId';
    final k1 = await pendingKeys.keyFor('$sig|1');
    final k2 = await pendingKeys.keyFor('$sig|2');
    final now = DateTime.now();
    final credit = await backend.postClassified(
        shopId: shopId, actor: actor, operator: operator,
        category: UnexplainedCategory.topUpDistributorCredit,
        amountPaise: receivedPaise - commissionPaise, reason: reason,
        transactionDate: now, distributorId: distributorId, idempotencyKey: k1);
    PostingResult? commission;
    if (commissionPaise > 0) {
      try {
        commission = await backend.postClassified(
            shopId: shopId, actor: actor, operator: operator,
            category: UnexplainedCategory.commissionCredit, amountPaise: commissionPaise,
            reason: 'Distributor top-up commission', transactionDate: now, idempotencyKey: k2);
      } catch (e) {
        throw AccountingException('COMMISSION_INCOMPLETE',
            'Distributor credit ${formatInrPaise(receivedPaise - commissionPaise)} സേവ് ആയി, പക്ഷേ commission ${formatInrPaise(commissionPaise)} സേവ് ആയില്ല. വീണ്ടും ശ്രമിക്കുക (Distributor credit was saved but the commission was NOT. Post again with the same amounts to finish; the credit will not be posted twice.) [$e]');
      }
    }
    await pendingKeys.clear('$sig|1');
    await pendingKeys.clear('$sig|2');
    return (credit: credit, commission: commission);
  }

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
  }) =>
      _post(
          'agentsettle|$shopId|$distributorId|${operator.name}|$totalPayablePaise|$rechargeAdjustmentPaise|$paymentMode|${istBusinessDate(paymentDate)}|$referenceNo',
          actor,
          (k) => backend.agentSettlement(
              shopId: shopId, actor: actor, distributorId: distributorId, operator: operator,
              totalPayablePaise: totalPayablePaise, rechargeAdjustmentPaise: rechargeAdjustmentPaise,
              paymentMode: paymentMode, paymentDate: paymentDate, referenceNo: referenceNo,
              notes: notes, idempotencyKey: k));

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
  }) =>
      _post(
          'agentreturn|$shopId|$distributorId|${operator.name}|$returnPaise|$returnMode|${istBusinessDate(returnDate)}|$referenceNo',
          actor,
          (k) => backend.agentReturn(
              shopId: shopId, actor: actor, distributorId: distributorId, operator: operator,
              returnPaise: returnPaise, returnMode: returnMode, returnDate: returnDate,
              referenceNo: referenceNo, notes: notes, idempotencyKey: k));

  /// Fresh start: system wallet = verified balance (not a period movement).
  Future<PostingResult> alignWallet({
    required String shopId,
    required AccountingActor actor,
    required RechargeOperator operator,
    required int ownPaise,
    required int creditPaise,
    required String reason,
  }) =>
      _post('align|$shopId|${operator.name}|$ownPaise|$creditPaise', actor,
          (k) => backend.alignWallet(
              shopId: shopId, actor: actor, operator: operator, ownPaise: ownPaise,
              creditPaise: creditPaise, reason: reason, idempotencyKey: k));

  /// Fresh start: dues still owed from before the new start (payable only).
  Future<PostingResult> distributorOpeningDues({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int amountPaise,
    required String reason,
  }) =>
      _post('openingdues|$shopId|$distributorId|${operator.name}|$amountPaise', actor,
          (k) => backend.distributorOpeningDues(
              shopId: shopId, actor: actor, distributorId: distributorId, operator: operator,
              amountPaise: amountPaise, reason: reason, idempotencyKey: k));

  Future<PostingResult> distributorCreditReversal({
    required String shopId,
    required AccountingActor actor,
    required String distributorId,
    required RechargeOperator operator,
    required int amountPaise,
    required String reason,
    String referenceNo = '',
  }) =>
      _post('creditrev|$shopId|$distributorId|${operator.name}|$amountPaise|$referenceNo', actor,
          (k) => backend.distributorCreditReversal(
              shopId: shopId, actor: actor, distributorId: distributorId, operator: operator,
              amountPaise: amountPaise, reason: reason, idempotencyKey: k));

  /// One refund per recharge, so the form signature is the recharge itself.
  Future<PostingResult> customerRefund({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required int refundPaise,
    required String refundMethod,
    required String reason,
  }) =>
      _post('refund|$shopId|$rechargeId', actor,
          (k) => backend.customerRefund(
              shopId: shopId, actor: actor, rechargeId: rechargeId, refundPaise: refundPaise,
              refundMethod: refundMethod, reason: reason, idempotencyKey: k));

  Future<PostingResult> failedRechargeReversal({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required String reason,
  }) =>
      _post('failrev|$shopId|$rechargeId', actor,
          (k) => backend.failedRechargeReversal(
              shopId: shopId, actor: actor, rechargeId: rechargeId, reason: reason,
              idempotencyKey: k));

  Future<PostingResult> correctRecharge({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required String reason,
  }) =>
      _post('correct|$shopId|$rechargeId', actor,
          (k) => backend.correctRecharge(
              shopId: shopId, actor: actor, rechargeId: rechargeId, reason: reason,
              idempotencyKey: k));

  Future<PostingResult> editRechargeDetails({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    String? customerPhone,
    String? paymentMode,
    required String reason,
  }) =>
      _post('editrc|$shopId|$rechargeId|${customerPhone ?? ''}|${paymentMode ?? ''}', actor,
          (k) => backend.editRechargeDetails(
              shopId: shopId, actor: actor, rechargeId: rechargeId,
              customerPhone: customerPhone, paymentMode: paymentMode, reason: reason,
              idempotencyKey: k));

  Future<PostingResult> commissionReversal({
    required String shopId,
    required AccountingActor actor,
    required String rechargeId,
    required bool clawbackFromWallet,
    required String reason,
  }) =>
      _post('commrev|$shopId|$rechargeId', actor,
          (k) => backend.commissionReversal(
              shopId: shopId, actor: actor, rechargeId: rechargeId,
              clawbackFromWallet: clawbackFromWallet, reason: reason, idempotencyKey: k));
}

class _UnavailableBackend implements RechargeAccountingBackend {
  Never _fail() => throw AccountingException('SERVER_UNAVAILABLE',
      'സെർവർ ലഭ്യമല്ല (Recharge accounting server is not configured; nothing was saved)');
  @override
  Future<Map<RechargeOperator, OperatorPeriodState>> periodState(String shopId) async => _fail();
  @override
  Future<SettlementSummary> settlement(String shopId) async => _fail();
  @override
  Future<PostingResult> verifyMorning({required String shopId, required AccountingActor actor, required RechargeOperator operator, required int morningActualPaise, required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> postClassified({required String shopId, required AccountingActor actor, required RechargeOperator operator, required UnexplainedCategory category, required int amountPaise, required String reason, required DateTime transactionDate, String? distributorId, required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> postReferenceBalance({required String shopId, required AccountingActor actor, required RechargeOperator operator, required int balancePaise, required String reason, required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> verifyClosing({required String shopId, required AccountingActor actor, required RechargeOperator operator, required int actualPaise, String reason = '', required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> distributorPayment({required String shopId, required AccountingActor actor, required String distributorId, required RechargeOperator operator, required int amountPaise, required String paymentMode, required DateTime paymentDate, String referenceNo = '', String notes = '', required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> agentSettlement({required String shopId, required AccountingActor actor, required String distributorId, required RechargeOperator operator, required int totalPayablePaise, required int rechargeAdjustmentPaise, required String paymentMode, required DateTime paymentDate, String referenceNo = '', String notes = '', required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> agentReturn({required String shopId, required AccountingActor actor, required String distributorId, required RechargeOperator operator, required int returnPaise, required String returnMode, required DateTime returnDate, String referenceNo = '', String notes = '', required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> distributorCreditReversal({required String shopId, required AccountingActor actor, required String distributorId, required RechargeOperator operator, required int amountPaise, required String reason, required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> distributorOpeningDues({required String shopId, required AccountingActor actor, required String distributorId, required RechargeOperator operator, required int amountPaise, required String reason, required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> alignWallet({required String shopId, required AccountingActor actor, required RechargeOperator operator, required int ownPaise, required int creditPaise, required String reason, required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> customerRefund({required String shopId, required AccountingActor actor, required String rechargeId, required int refundPaise, required String refundMethod, required String reason, required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> failedRechargeReversal({required String shopId, required AccountingActor actor, required String rechargeId, required String reason, required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> correctRecharge({required String shopId, required AccountingActor actor, required String rechargeId, required String reason, required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> editRechargeDetails({required String shopId, required AccountingActor actor, required String rechargeId, String? customerPhone, String? paymentMode, required String reason, required String idempotencyKey}) async => _fail();
  @override
  Future<PostingResult> commissionReversal({required String shopId, required AccountingActor actor, required String rechargeId, required bool clawbackFromWallet, required String reason, required String idempotencyKey}) async => _fail();
  @override
  Future<Map<String, int>> agentPendingReturns(String shopId) async => _fail();
  @override
  Future<ExcessSummary> excessSummary(String shopId) async => _fail();
  @override
  Future<PostingResult> topUpCommission({required String shopId, required AccountingActor actor, required RechargeOperator operator, String? distributorId, required int commissionPaise, required String reason, required String idempotencyKey}) async => _fail();
  @override
  Future<TopUpCommissionSummary> topUpCommissionSummary(String shopId) async => _fail();
  @override
  Future<int> distributorCashForDate(String shopId, String dateString) async => _fail();
}

// ---------------------------------------------------------------------------
// Supabase (production) backend
// ---------------------------------------------------------------------------

class SupabaseAccountingBackend implements RechargeAccountingBackend {
  Future<Map<String, dynamic>> _call(String endpoint, Map<String, dynamic> body) =>
      RechargeBackendBridge.supabaseClient!.accountingCall(endpoint, body);

  /// Signed call: challenge nonce + device signature over
  /// "OPERATION:shopId:uid:deviceId:nonce:canonicalData".
  Future<PostingResult> _signed(String endpoint, String operation, String shopId,
      AccountingActor actor, String canonicalData, Map<String, dynamic> body) async {
    final sec = DeviceSecurityService.instance;
    final dId = sec.deviceId;
    final client = RechargeBackendBridge.supabaseClient!;
    final ch = await client.requestChallenge(shopId: shopId, deviceId: dId, ownerUid: actor.uid);
    final sig = await sec.signRawPayload('$operation:$shopId:${actor.uid}:$dId:${ch.nonce}:$canonicalData');
    final res = await _call(endpoint, {
      ...body,
      'shopId': shopId,
      'staffName': actor.name,
      'deviceId': dId,
      'deviceSignature': sig,
      'nonce': ch.nonce,
    });
    return PostingResult(res['reference_id']?.toString() ?? '',
        replayed: res['replayed'] == true, data: res);
  }

  static int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  static DateTime _dt(dynamic v) => DateTime.parse(v.toString()).toUtc();
  static RechargeOperator _op(dynamic v) => RechargeOperator.fromString(v?.toString());

  @override
  Future<Map<RechargeOperator, OperatorPeriodState>> periodState(String shopId) async {
    final res = await _call('accounting-period-state', {'shopId': shopId});
    final out = <RechargeOperator, OperatorPeriodState>{};
    for (final raw in (res['operators'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(raw as Map);
      final op = _op(m['operator']);
      final pc = m['previous_closing'];
      final prev = pc == null
          ? null
          : VerifiedClosing(
              operator: op,
              actualPaise: _int((pc as Map)['actual_paise']),
              at: _dt(pc['at']),
              periodId: pc['period_id'].toString());
      final moves = <WalletMovement>[
        for (final mv in (m['movements'] as List? ?? const []))
          WalletMovement(
            operator: op,
            kind: WalletMovementKind.values.byName((mv as Map)['kind'].toString()),
            amountPaise: _int(mv['amount_paise']),
            at: _dt(mv['at']),
            referenceId: mv['reference_id']?.toString() ?? '',
            pending: mv['pending'] == true,
          ),
      ];
      MorningSnapshot? morning;
      final ms = m['morning'];
      if (ms is Map) {
        final at = _dt(ms['at']);
        morning = MorningSnapshot(
          morningActualPaise: _int(ms['morning_actual_paise']),
          at: at,
          classifiedPaise: _int(ms['classified_paise']),
          check: computeMorningCheck(
              operator: op, previousClosing: prev,
              morningActualPaise: _int(ms['morning_actual_paise']),
              morningAt: at, ledger: moves),
        );
      }
      out[op] = OperatorPeriodState(
          operator: op, previousClosing: prev, movements: moves, morning: morning);
    }
    return out;
  }

  @override
  Future<SettlementSummary> settlement(String shopId) async {
    final res = await _call('accounting-settlement', {'shopId': shopId});
    final entries = <SettlementEntry>[];
    for (final raw in (res['accounts'] as List? ?? const [])) {
      final a = Map<String, dynamic>.from(raw as Map);
      final id = a['distributor_id'].toString();
      final name = a['distributor_name']?.toString() ?? id;
      final op = _op(a['operator']);
      final payable = _int(a['payable_paise']);
      final paid = _int(a['paid_paise']);
      final last = a['last_payment_at'] == null ? DateTime.utc(1970) : _dt(a['last_payment_at']);
      // Always keep the account (also at ₹0), so its row and actions stay
      // visible after old dues are cleared.
      entries.add(SettlementEntry(distributorId: id, distributorName: name, operator: op,
          kind: payable >= 0 ? SettlementEntryKind.creditLoad : SettlementEntryKind.adjustment,
          amountPaise: payable.abs(), at: last));
      if (paid != 0) {
        entries.add(SettlementEntry(distributorId: id, distributorName: name, operator: op,
            kind: SettlementEntryKind.payment, amountPaise: paid, at: last));
      }
    }
    return computeSettlement(entries);
  }

  @override
  Future<PostingResult> verifyMorning({required String shopId, required AccountingActor actor, required RechargeOperator operator, required int morningActualPaise, required String idempotencyKey}) =>
      _signed('accounting-verify-morning', 'ACCOUNTING_VERIFY_MORNING', shopId, actor,
          '${operator.name}:$morningActualPaise:$idempotencyKey',
          {'operator': operator.name, 'morningActualPaise': morningActualPaise, 'idempotencyKey': idempotencyKey});

  @override
  Future<PostingResult> postClassified({required String shopId, required AccountingActor actor, required RechargeOperator operator, required UnexplainedCategory category, required int amountPaise, required String reason, required DateTime transactionDate, String? distributorId, required String idempotencyKey}) =>
      _signed('accounting-post-classified', 'ACCOUNTING_POST_CLASSIFIED', shopId, actor,
          '${operator.name}:${category.name}:$amountPaise:${distributorId ?? ''}:$idempotencyKey',
          {
            'operator': operator.name,
            'category': category.name,
            'amountPaise': amountPaise,
            'reason': reason,
            'transactionDate': transactionDate.toUtc().toIso8601String(),
            'distributorId': distributorId,
            'idempotencyKey': idempotencyKey,
          });

  @override
  Future<PostingResult> postReferenceBalance({required String shopId, required AccountingActor actor, required RechargeOperator operator, required int balancePaise, required String reason, required String idempotencyKey}) =>
      _signed('accounting-reference-balance', 'ACCOUNTING_REFERENCE_BALANCE', shopId, actor,
          '${operator.name}:$balancePaise:$idempotencyKey',
          {'operator': operator.name, 'balancePaise': balancePaise, 'reason': reason, 'idempotencyKey': idempotencyKey});

  @override
  Future<PostingResult> verifyClosing({required String shopId, required AccountingActor actor, required RechargeOperator operator, required int actualPaise, String reason = '', required String idempotencyKey}) =>
      _signed('accounting-verify-closing', 'ACCOUNTING_VERIFY_CLOSING', shopId, actor,
          '${operator.name}:$actualPaise:$idempotencyKey',
          {'operator': operator.name, 'actualPaise': actualPaise, 'reason': reason, 'idempotencyKey': idempotencyKey});

  @override
  Future<PostingResult> distributorPayment({required String shopId, required AccountingActor actor, required String distributorId, required RechargeOperator operator, required int amountPaise, required String paymentMode, required DateTime paymentDate, String referenceNo = '', String notes = '', required String idempotencyKey}) =>
      _signed('accounting-distributor-payment', 'ACCOUNTING_DISTRIBUTOR_PAYMENT', shopId, actor,
          '$distributorId:${operator.name}:$amountPaise:$idempotencyKey',
          {
            'distributorId': distributorId,
            'operator': operator.name,
            'amountPaise': amountPaise,
            'paymentMode': paymentMode,
            'paymentDate': paymentDate.toUtc().toIso8601String(),
            'referenceNo': referenceNo,
            'notes': notes,
            'idempotencyKey': idempotencyKey,
          });

  // ------------------------------- legacy flows on the server path (v2.1)
  @override
  Future<Map<String, int>> agentPendingReturns(String shopId) async {
    final res = await _call('accounting-agent-returns', {'shopId': shopId});
    final out = <String, int>{};
    for (final raw in (res['accounts'] as List? ?? const [])) {
      final a = Map<String, dynamic>.from(raw as Map);
      out[agentReturnKey(a['distributor_id'].toString(), _op(a['operator']))] =
          _int(a['pending_return_paise']);
    }
    return out;
  }

  @override
  Future<PostingResult> topUpCommission({required String shopId, required AccountingActor actor, required RechargeOperator operator, String? distributorId, required int commissionPaise, required String reason, required String idempotencyKey}) =>
      _signed('accounting-topup-commission', 'ACCOUNTING_TOPUP_COMMISSION', shopId, actor,
          '${operator.name}:${distributorId ?? ''}:$commissionPaise:$idempotencyKey',
          {
            'operator': operator.name,
            'distributorId': distributorId ?? '',
            'commissionPaise': commissionPaise,
            'reason': reason,
            'idempotencyKey': idempotencyKey,
          });

  @override
  Future<int> distributorCashForDate(String shopId, String dateString) async {
    final res = await _call('accounting-distributor-cash', {'shopId': shopId, 'date': dateString});
    var net = 0;
    for (final raw in (res['entries'] as List? ?? const [])) {
      net += _int((raw as Map)['cash_paise']);
    }
    return net;
  }

  @override
  Future<TopUpCommissionSummary> topUpCommissionSummary(String shopId) async {
    final res = await _call('accounting-topup-commission-summary', {'shopId': shopId});
    return TopUpCommissionSummary([
      for (final raw in (res['entries'] as List? ?? const []))
        TopUpCommissionEntry(
          operator: _op((raw as Map)['operator']),
          amountPaise: _int(raw['amount_paise']),
          at: _dt(raw['at']),
          referenceId: raw['reference_id']?.toString() ?? '',
        ),
    ]);
  }

  @override
  Future<ExcessSummary> excessSummary(String shopId) async {
    final res = await _call('accounting-excess', {'shopId': shopId});
    return ExcessSummary([
      for (final raw in (res['entries'] as List? ?? const []))
        ExcessEntry(
          operator: _op((raw as Map)['operator']),
          amountPaise: _int(raw['amount_paise']),
          at: _dt(raw['at']),
          source: raw['source'] == 'closing' ? ExcessSource.closing : ExcessSource.morning,
          referenceId: raw['reference_id']?.toString() ?? '',
        ),
    ]);
  }

  @override
  Future<PostingResult> agentSettlement({required String shopId, required AccountingActor actor, required String distributorId, required RechargeOperator operator, required int totalPayablePaise, required int rechargeAdjustmentPaise, required String paymentMode, required DateTime paymentDate, String referenceNo = '', String notes = '', required String idempotencyKey}) =>
      _signed('accounting-agent-settlement', 'ACCOUNTING_AGENT_SETTLEMENT', shopId, actor,
          '$distributorId:${operator.name}:$totalPayablePaise:$rechargeAdjustmentPaise:$idempotencyKey',
          {
            'distributorId': distributorId,
            'operator': operator.name,
            'totalPayablePaise': totalPayablePaise,
            'rechargeAdjustmentPaise': rechargeAdjustmentPaise,
            'paymentMode': paymentMode,
            'paymentDate': paymentDate.toUtc().toIso8601String(),
            'referenceNo': referenceNo,
            'notes': notes,
            'idempotencyKey': idempotencyKey,
          });

  @override
  Future<PostingResult> agentReturn({required String shopId, required AccountingActor actor, required String distributorId, required RechargeOperator operator, required int returnPaise, required String returnMode, required DateTime returnDate, String referenceNo = '', String notes = '', required String idempotencyKey}) =>
      _signed('accounting-agent-return', 'ACCOUNTING_AGENT_RETURN', shopId, actor,
          '$distributorId:${operator.name}:$returnPaise:$idempotencyKey',
          {
            'distributorId': distributorId,
            'operator': operator.name,
            'returnPaise': returnPaise,
            'returnMode': returnMode,
            'returnDate': returnDate.toUtc().toIso8601String(),
            'referenceNo': referenceNo,
            'notes': notes,
            'idempotencyKey': idempotencyKey,
          });

  @override
  Future<PostingResult> distributorCreditReversal({required String shopId, required AccountingActor actor, required String distributorId, required RechargeOperator operator, required int amountPaise, required String reason, required String idempotencyKey}) =>
      _signed('accounting-credit-reversal', 'ACCOUNTING_CREDIT_REVERSAL', shopId, actor,
          '$distributorId:${operator.name}:$amountPaise:$idempotencyKey',
          {
            'distributorId': distributorId,
            'operator': operator.name,
            'amountPaise': amountPaise,
            'reason': reason,
            'idempotencyKey': idempotencyKey,
          });

  @override
  Future<PostingResult> alignWallet({required String shopId, required AccountingActor actor, required RechargeOperator operator, required int ownPaise, required int creditPaise, required String reason, required String idempotencyKey}) =>
      _signed('accounting-align-wallet', 'ACCOUNTING_ALIGN_WALLET', shopId, actor,
          '${operator.name}:$ownPaise:$creditPaise:$idempotencyKey',
          {
            'operator': operator.name,
            'ownPaise': ownPaise,
            'creditPaise': creditPaise,
            'reason': reason,
            'idempotencyKey': idempotencyKey,
          });

  @override
  Future<PostingResult> distributorOpeningDues({required String shopId, required AccountingActor actor, required String distributorId, required RechargeOperator operator, required int amountPaise, required String reason, required String idempotencyKey}) =>
      _signed('accounting-opening-dues', 'ACCOUNTING_OPENING_DUES', shopId, actor,
          '$distributorId:${operator.name}:$amountPaise:$idempotencyKey',
          {
            'distributorId': distributorId,
            'operator': operator.name,
            'amountPaise': amountPaise,
            'reason': reason,
            'idempotencyKey': idempotencyKey,
          });

  @override
  Future<PostingResult> customerRefund({required String shopId, required AccountingActor actor, required String rechargeId, required int refundPaise, required String refundMethod, required String reason, required String idempotencyKey}) =>
      _signed('accounting-customer-refund', 'ACCOUNTING_CUSTOMER_REFUND', shopId, actor,
          '$rechargeId:$refundPaise:${refundMethod.toLowerCase()}:$idempotencyKey',
          {
            'rechargeId': rechargeId,
            'refundPaise': refundPaise,
            'refundMethod': refundMethod.toLowerCase(),
            'reason': reason,
            'idempotencyKey': idempotencyKey,
          });

  @override
  Future<PostingResult> failedRechargeReversal({required String shopId, required AccountingActor actor, required String rechargeId, required String reason, required String idempotencyKey}) =>
      _signed('accounting-failed-reversal', 'ACCOUNTING_FAILED_REVERSAL', shopId, actor,
          '$rechargeId:$idempotencyKey',
          {'rechargeId': rechargeId, 'reason': reason, 'idempotencyKey': idempotencyKey});

  @override
  Future<PostingResult> correctRecharge({required String shopId, required AccountingActor actor, required String rechargeId, required String reason, required String idempotencyKey}) =>
      _signed('accounting-correct-recharge', 'ACCOUNTING_CORRECT_RECHARGE', shopId, actor,
          '$rechargeId:$idempotencyKey',
          {'rechargeId': rechargeId, 'reason': reason, 'idempotencyKey': idempotencyKey});

  @override
  Future<PostingResult> editRechargeDetails({required String shopId, required AccountingActor actor, required String rechargeId, String? customerPhone, String? paymentMode, required String reason, required String idempotencyKey}) {
    final phone = customerPhone?.trim() ?? '';
    final mode = paymentMode?.trim() ?? '';
    return _signed('accounting-edit-recharge', 'ACCOUNTING_EDIT_RECHARGE', shopId, actor,
        '$rechargeId:$phone:$mode:$idempotencyKey',
        {
          'rechargeId': rechargeId,
          'customerPhone': phone,
          'paymentMode': mode,
          'reason': reason,
          'idempotencyKey': idempotencyKey,
        });
  }

  @override
  Future<PostingResult> commissionReversal({required String shopId, required AccountingActor actor, required String rechargeId, required bool clawbackFromWallet, required String reason, required String idempotencyKey}) =>
      _signed('accounting-commission-reversal', 'ACCOUNTING_COMMISSION_REVERSAL', shopId, actor,
          '$rechargeId:$clawbackFromWallet:$idempotencyKey',
          {
            'rechargeId': rechargeId,
            'clawbackFromWallet': clawbackFromWallet,
            'reason': reason,
            'idempotencyKey': idempotencyKey,
          });
}
