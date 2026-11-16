import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart';
import '../main.dart';
import 'recharge_backend_bridge.dart';
import '../security/device_security_service.dart';

/// ============================================================================
/// TEKFIX ERP — RECHARGE SETTLEMENT RECOVERY ENGINE
/// PHASE 16.4: Adversarial Financial Integrity & Outbox Atomicity
/// ============================================================================
/// Ensures eventual consistency between remote Supabase distributor wallet
/// debits and local Hive customer accounting ledgers (Cash/Bank/Receivables).
///
/// Implements Write-Ahead Outbox Journaling in [Db.rechargeQueue] and
/// automated startup reconciliation to prevent orphan/unmatched debits.
/// ============================================================================
class RechargeRecoveryEngine {
  static const String statusInitiated = 'INITIATED';
  static const String statusServerConfirmed = 'SERVER_CONFIRMED';
  static const String statusSettled = 'SETTLED';
  static const String statusAborted = 'ABORTED';
  static const String statusManualReviewRequired = 'MANUAL_REVIEW_REQUIRED';
  static const String statusCompensationRequired = 'COMPENSATION_REQUIRED';

  /// Concurrency lock to prevent duplicate concurrent settlement executions
  static final Set<String> _inFlightTopUpSettlements = <String>{};

  /// Step 1: Pre-commit write-ahead journal entry before network dispatch
  static Future<void> recordPendingIntent({
    required String idempotencyKey,
    required String shopId,
    required String ownerUid,
    required String deviceId,
    required String mobile,
    required String operator,
    required String serviceType,
    required double retailAmount,
    required double costPrice,
    required String paymentMode,
    dynamic partyKey,
    String partyName = '',
    String notes = '',
  }) async {
    final entry = {
      'idempotencyKey': idempotencyKey,
      'status': statusInitiated,
      'shopId': shopId,
      'ownerUid': ownerUid,
      'deviceId': deviceId,
      'mobile': mobile,
      'operator': operator,
      'serviceType': serviceType,
      'retailAmount': retailAmount,
      'costPrice': costPrice,
      'paymentMode': paymentMode,
      'partyKey': partyKey,
      'partyName': partyName,
      'notes': notes,
      'createdAt': DateTime.now().toIso8601String(),
      'serverTxnKey': null,
      'settledMoney': false,
      'settledParty': false,
      'settledReadModel': false,
    };
    await Db.rechargeQueue.put(idempotencyKey, entry);
  }

  /// Durable Write-Ahead Top-Up Outbox Intent (Phase 16.4.13)
  /// Validates pre-flight bank balance before recording outbox entry
  static Future<void> recordPendingTopUpIntent({
    required String idempotencyKey,
    required String shopId,
    required String ownerUid,
    required String deviceId,
    required String walletId,
    required String operator,
    required double amount,
    required int amountPaise,
    required String referenceNo,
    required String source,
    required String staffId,
    required String staffName,
    String description = '',
    bool checkBankBalance = true,
  }) async {
    if (checkBankBalance && Db.bankBalance < amount) {
      throw StateError(
          'Insufficient bank balance: Available ₹${Db.bankBalance.toStringAsFixed(2)}, Required ₹${amount.toStringAsFixed(2)}');
    }

    final entry = {
      'idempotencyKey': idempotencyKey,
      'type': 'TOPUP',
      'status': statusInitiated,
      'shopId': shopId,
      'ownerUid': ownerUid,
      'deviceId': deviceId,
      'walletId': walletId,
      'operator': operator,
      'amount': amount,
      'amountPaise': amountPaise,
      'referenceNo': referenceNo,
      'source': source,
      'staffId': staffId,
      'staffName': staffName,
      'description': description,
      'createdAt': DateTime.now().toIso8601String(),
      'serverDepositId': null,
      'confirmedAt': null,
      'settledBank': false,
      'settledVoucher': false,
      'voucherId': 'CB_TOPUP_$idempotencyKey',
    };
    await Db.rechargeQueue.put(idempotencyKey, entry);
  }

  /// Mark top-up server credit confirmed by Supabase Edge Function
  static Future<void> markTopUpServerConfirmed(
    String idempotencyKey, {
    required String serverDepositId,
    int? balanceAfterPaise,
  }) async {
    final raw = Db.rechargeQueue.get(idempotencyKey);
    if (raw is Map) {
      final updated = Map<String, dynamic>.from(raw);
      updated['status'] = statusServerConfirmed;
      updated['serverDepositId'] = serverDepositId;
      if (balanceAfterPaise != null) {
        updated['balanceAfterPaise'] = balanceAfterPaise;
      }
      updated['confirmedAt'] = DateTime.now().toIso8601String();
      await Db.rechargeQueue.put(idempotencyKey, updated);
    }
  }

  /// Execute Post-Confirmation Bank Settlement for Top-Up (Phase 16.4.13)
  /// Creates deterministic Firestore voucher in `accounting_cash_bank` and debits local bank balance
  static Future<void> executeTopUpSettlement({
    required String idempotencyKey,
    required String shopId,
    required String operator,
    required double amount,
    required String referenceNo,
    String? staffId,
    String? staffName,
    Map<String, dynamic>? journal,
  }) async {
    // Concurrency protection: serialize concurrent settlement execution for same key
    while (_inFlightTopUpSettlements.contains(idempotencyKey)) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    if (hasMoneyMoved(idempotencyKey)) {
      await Db.rechargeQueue.delete(idempotencyKey);
      return;
    }
    _inFlightTopUpSettlements.add(idempotencyKey);
    try {
      final voucherId = 'CB_TOPUP_$idempotencyKey';
      final amountPaise = (amount * 100).round();

      // 1. Authoritative Cloud Accounting: Create Double-Entry Voucher in Firestore
      final bool voucherAlreadySettled = journal?['settledVoucher'] == true;
      if (!voucherAlreadySettled &&
          Firebase.apps.isNotEmpty &&
          shopId.isNotEmpty) {
        try {
          final voucherRef = FirebaseFirestore.instance
              .collection('shops')
              .doc(shopId)
              .collection('accounting_cash_bank')
              .doc(voucherId);

          final voucherData = <String, dynamic>{
            'id': voucherId,
            'type': 'DEBIT',
            'entryType': 'DEBIT',
            'transactionCategory': 'RECHARGE_FLOAT_TOPUP',
            'category': 'ASSET_TRANSFER',
            'isRecharge': true,
            'isExpense': false, // Asset transfer, NEVER a business expense
            'isSalesRevenue': false, // NEVER sales revenue
            'walletId': 'WALLET_${operator.toUpperCase()}',
            'operator': operator,
            'amount': amount,
            'amountPaise': amountPaise,
            'paymentMode': 'BANK',
            'mode': 'Bank',
            'referenceNo': referenceNo,
            'supabaseDepositId': idempotencyKey,
            'effectiveDate': FieldValue.serverTimestamp(),
            'createdByUid': staffId ?? 'OWNER',
            'createdByName': staffName ?? 'Shop Owner',
            'createdAt': FieldValue.serverTimestamp(),
          };

          await voucherRef.set(voucherData, SetOptions(merge: true));
          if (journal != null) {
            journal['settledVoucher'] = true;
            await Db.rechargeQueue.put(idempotencyKey, journal);
          }
        } catch (e) {
          debugPrint(
              '[RechargeRecoveryEngine] Firestore voucher creation error: $e');
          throw StateError('FIRESTORE_VOUCHER_FAILED: $e');
        }
      }

      // 2. Local Bank Settlement: Asset Transfer (Decreases bank balance)
      if (!hasMoneyMoved(idempotencyKey)) {
        try {
          await Db.moveMoney(
            'Bank',
            -amount,
            'Topup $operator (Ref: $referenceNo, Txn: $idempotencyKey)',
          );
          // Phase 16.4.18: Synchronize SyncEngine last-synced bank balance relatively.
          // Adjusts the baseline by subtracting the settled top-up amount, preserving
          // any unrelated pending retail deltas (e.g. UPI sales, cash deposits).
          if (Hive.isBoxOpen('tek_sync_meta')) {
            final metaBox = Hive.box('tek_sync_meta');
            if (metaBox.containsKey('ls:bank|bank_balance')) {
              final oldLs =
                  (metaBox.get('ls:bank|bank_balance') as num?)?.toDouble() ??
                      0.0;
              final double newLs = ((oldLs - amount) * 100).round() / 100;
              await metaBox.put('ls:bank|bank_balance', newLs);
            } else {
              await metaBox.put(
                  'ls:bank|bank_balance', Db.bank.get('bank_balance'));
            }
          }
          if (journal != null) {
            journal['settledBank'] = true;
            await Db.rechargeQueue.put(idempotencyKey, journal);
          }
        } catch (e) {
          debugPrint('[RechargeRecoveryEngine] Local bank debit error: $e');
          throw StateError('LOCAL_BANK_DEBIT_FAILED: $e');
        }
      }

      // 3. Mark Outbox Settled & Remove from Active Queue
      await Db.rechargeQueue.delete(idempotencyKey);
    } finally {
      _inFlightTopUpSettlements.remove(idempotencyKey);
    }
  }

  /// Returns all journal entries currently held for manual review
  static List<Map<String, dynamic>> getPendingManualReviewItems() {
    if (!Db.rechargeQueue.isOpen) return [];
    final items = <Map<String, dynamic>>[];
    for (final key in Db.rechargeQueue.keys) {
      final val = Db.rechargeQueue.get(key);
      if (val is Map && val['status'] == statusManualReviewRequired) {
        items.add(Map<String, dynamic>.from(val));
      }
    }
    return items;
  }

  /// Step 2: Mark server debit confirmed by Supabase Edge Function
  static Future<void> markServerConfirmed(
    String idempotencyKey,
    String serverTxnKey,
  ) async {
    final raw = Db.rechargeQueue.get(idempotencyKey);
    if (raw is Map) {
      final updated = Map<String, dynamic>.from(raw);
      updated['status'] = statusServerConfirmed;
      updated['serverTxnKey'] = serverTxnKey;
      updated['confirmedAt'] = DateTime.now().toIso8601String();
      await Db.rechargeQueue.put(idempotencyKey, updated);
    }
  }

  /// Mark money movement step completed in journal
  static Future<void> markMoneySettled(String idempotencyKey) async {
    final raw = Db.rechargeQueue.get(idempotencyKey);
    if (raw is Map) {
      final updated = Map<String, dynamic>.from(raw);
      updated['settledMoney'] = true;
      await Db.rechargeQueue.put(idempotencyKey, updated);
    }
  }

  /// Mark party receivable step completed in journal
  static Future<void> markPartySettled(String idempotencyKey) async {
    final raw = Db.rechargeQueue.get(idempotencyKey);
    if (raw is Map) {
      final updated = Map<String, dynamic>.from(raw);
      updated['settledParty'] = true;
      await Db.rechargeQueue.put(idempotencyKey, updated);
    }
  }

  /// Step 3: Mark complete settlement finished and purge from active queue
  static Future<void> markSettled(String idempotencyKey) async {
    await Db.rechargeQueue.delete(idempotencyKey);
  }

  /// Mark transaction as requiring manual owner review
  /// Rule: NEVER silently redirect identified customer debt to general receivables
  static Future<void> markManualReviewRequired(
      String idempotencyKey, String reason) async {
    final raw = Db.rechargeQueue.get(idempotencyKey);
    final journal =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    journal['status'] = statusManualReviewRequired;
    journal['reviewReason'] = reason;
    journal['flaggedAt'] = DateTime.now().toIso8601String();
    await Db.rechargeQueue.put(idempotencyKey, journal);

    await Db.logAction(
      action: 'RECHARGE_MANUAL_REVIEW_REQUIRED',
      entity: 'Recharge',
      entityId: idempotencyKey,
      newValue: reason,
      reason:
          'Customer party record missing/deleted; manual debt reassignment required',
    );
  }

  /// Step 4: Mark transaction permanently failed or aborted and move to dead-letter box
  static Future<void> markFailed(String idempotencyKey, String reason) async {
    final raw = Db.rechargeQueue.get(idempotencyKey);
    if (raw is Map) {
      final deadLetter = Map<String, dynamic>.from(raw);
      deadLetter['status'] = statusAborted;
      deadLetter['failureReason'] = reason;
      deadLetter['abortedAt'] = DateTime.now().toIso8601String();
      await Db.rechargeDeadLetter.put(idempotencyKey, deadLetter);
    }
    await Db.rechargeQueue.delete(idempotencyKey);
  }

  /// Check if Cash or Bank was already debited/credited for this transaction ID
  static bool hasMoneyMoved(String idempotencyKey) {
    if (!Db.bank.isOpen) return false;
    final txnLog = (Db.bank.get('txn_log') as List?) ?? [];
    for (final item in txnLog) {
      if (item is Map) {
        final note = item['note']?.toString() ?? '';
        if (note.contains('(Txn: $idempotencyKey)') ||
            note.contains('Txn: $idempotencyKey') ||
            note.contains(idempotencyKey)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Execute startup reconciliation of all pending journal entries in [Db.rechargeQueue]
  /// Guarantees that any server debit interrupted by an app crash or network timeout
  /// is cleanly settled into Cash/Bank/Due and cached into [Db.recharges].
  static Future<int> reconcilePendingSettlements() async {
    if (!Db.rechargeQueue.isOpen) return 0;

    int reconciledCount = 0;
    final keys = List.from(Db.rechargeQueue.keys);

    for (final key in keys) {
      final raw = Db.rechargeQueue.get(key);
      if (raw is! Map) continue;

      final journal = Map<String, dynamic>.from(raw);
      final status = journal['status']?.toString() ?? '';
      final idempotencyKey =
          journal['idempotencyKey']?.toString() ?? key.toString();

      // Skip entries currently held for manual review by shop owner
      if (status == statusManualReviewRequired) {
        debugPrint(
            '[RechargeRecoveryEngine] Skipping $idempotencyKey: HELD FOR MANUAL REVIEW');
        continue;
      }

      // Phase 16.4.13: Route Top-Up Outbox items to dedicated recovery flow
      if (journal['type'] == 'TOPUP') {
        final recovered = await _reconcilePendingTopUp(journal, key);
        if (recovered) reconciledCount++;
        continue;
      }

      final paymentMode = journal['paymentMode']?.toString() ?? 'Cash';
      final retailAmount = (journal['retailAmount'] as num?)?.toDouble() ?? 0.0;
      final costPrice = (journal['costPrice'] as num?)?.toDouble() ?? 0.0;
      final partyKey = journal['partyKey'];
      final partyName = journal['partyName']?.toString() ?? '';
      final mobile = journal['mobile']?.toString() ?? '';
      final operator = journal['operator']?.toString() ?? '';
      final serviceType = journal['serviceType']?.toString() ?? 'Prepaid';
      final notes = journal['notes']?.toString() ?? '';

      // Case A: Server debit was already confirmed, but local settlement was interrupted
      if (status == statusServerConfirmed) {
        try {
          await _executeLocalSettlement(
            idempotencyKey: idempotencyKey,
            paymentMode: paymentMode,
            retailAmount: retailAmount,
            costPrice: costPrice,
            partyKey: partyKey,
            partyName: partyName,
            mobile: mobile,
            operator: operator,
            serviceType: serviceType,
            notes: notes,
            serverTxnKey: journal['serverTxnKey']?.toString() ?? idempotencyKey,
            journal: journal,
          );
          await Db.rechargeQueue.delete(key);
          reconciledCount++;
          debugPrint(
              '[RechargeRecoveryEngine] Interrupted settlement reconciled for $idempotencyKey');
        } catch (e) {
          debugPrint('[RechargeRecoveryEngine] Settlement paused: $e');
        }
        continue;
      }

      // Case B: Transaction was initiated, but client died before receiving HTTP response
      if (status == statusInitiated) {
        final client = RechargeBackendBridge.supabaseClient;
        if (client == null) continue; // Cannot verify without backend bridge

        try {
          final shopId = journal['shopId']?.toString() ??
              Db.setting('shop_id', 'shop_staging_001');
          final sec = DeviceSecurityService.instance;
          final devId = sec.deviceId;

          final ownerUid =
              journal['ownerUid']?.toString() ?? 'owner_staging_001';

          // Request challenge to safely query or re-verify idempotency
          final challenge = await client.requestChallenge(
              shopId: shopId, deviceId: devId, ownerUid: ownerUid);
          final debitAmountPaise =
              ((costPrice > 0 ? costPrice : retailAmount) * 100).round();
          final targetWalletId = 'WALLET_${operator.toUpperCase()}';
          const fundingType = 'ownPrepaid';
          final canonicalData =
              '$targetWalletId:$idempotencyKey:$debitAmountPaise:$fundingType';
          final canonicalPayload =
              'PROCESS_DEBIT:$shopId:${journal['ownerUid'] ?? 'owner'}:$devId:${challenge.nonce}:$canonicalData';
          final signature = await sec.signRawPayload(canonicalPayload);

          final res = await client.processDebit(
            shopId: shopId,
            walletId: targetWalletId,
            rechargeId: idempotencyKey,
            idempotencyKey: idempotencyKey,
            customerPhone: mobile,
            operator: operator,
            serviceType: serviceType,
            amountPaise: debitAmountPaise,
            amount: retailAmount,
            fundingType: fundingType,
            commissionEarnedPaise: ((retailAmount - costPrice) * 100).round(),
            businessDate: DateFormat('yyyy-MM-dd').format(DateTime.now()),
            deviceId: devId,
            deviceSignature: signature,
            nonce: challenge.nonce,
            paymentMode: paymentMode,
            retailAmountPaise: (retailAmount * 100).round(),
            costPricePaise: (costPrice * 100).round(),
            partyKey: partyKey,
            partyName: partyName,
            notes: notes,
          );

          if (res['success'] == true) {
            // Server has confirmed debit (either fresh or idempotent replay)
            await _executeLocalSettlement(
              idempotencyKey: idempotencyKey,
              paymentMode: paymentMode,
              retailAmount: retailAmount,
              costPrice: costPrice,
              partyKey: partyKey,
              partyName: partyName,
              mobile: mobile,
              operator: operator,
              serviceType: serviceType,
              notes: notes,
              serverTxnKey: res['txn_key'] ?? idempotencyKey,
              journal: journal,
            );
            await Db.rechargeQueue.delete(key);
            reconciledCount++;
            debugPrint(
                '[RechargeRecoveryEngine] In-flight transaction reconciled with server: $idempotencyKey');
          } else {
            // Terminal error from server
            await markFailed(
                idempotencyKey, res['error']?.toString() ?? 'Server rejected');
          }
        } catch (e) {
          final createdAtStr = journal['createdAt']?.toString();
          if (createdAtStr != null) {
            final dt = DateTime.tryParse(createdAtStr);
            if (dt != null && DateTime.now().difference(dt).inMinutes > 10) {
              await markFailed(
                  idempotencyKey, 'Expired in-flight transaction: $e');
            }
          }
        }
      }
    }

    return reconciledCount;
  }

  /// Reconcile an interrupted or in-flight Top-Up outbox item (Phase 16.4.13)
  static Future<bool> _reconcilePendingTopUp(
    Map<String, dynamic> journal,
    dynamic key,
  ) async {
    final status = journal['status']?.toString() ?? '';
    final idempotencyKey =
        journal['idempotencyKey']?.toString() ?? key.toString();
    final shopId =
        journal['shopId']?.toString() ?? Db.setting('shop_id', 'tekfix');
    final operator = journal['operator']?.toString() ?? '';
    final amount = (journal['amount'] as num?)?.toDouble() ?? 0.0;
    final referenceNo = journal['referenceNo']?.toString() ?? idempotencyKey;
    final staffId = journal['staffId']?.toString();
    final staffName = journal['staffName']?.toString();

    // Case 1: Server debit confirmed, but bank settlement was interrupted by crash
    if (status == statusServerConfirmed) {
      try {
        await executeTopUpSettlement(
          idempotencyKey: idempotencyKey,
          shopId: shopId,
          operator: operator,
          amount: amount,
          referenceNo: referenceNo,
          staffId: staffId,
          staffName: staffName,
          journal: journal,
        );
        debugPrint(
            '[RechargeRecoveryEngine] Interrupted TopUp settled for $idempotencyKey');
        return true;
      } catch (e) {
        debugPrint(
            '[RechargeRecoveryEngine] TopUp settlement recovery error: $e');
        await markManualReviewRequired(
          idempotencyKey,
          'Bank settlement failed during recovery: $e',
        );
        return false;
      }
    }

    // Case 2: In-flight top-up when app crashed or timed out before receiving server response
    if (status == statusInitiated) {
      final client = RechargeBackendBridge.supabaseClient;
      if (client == null) return false;

      try {
        final sec = DeviceSecurityService.instance;
        final devId = sec.deviceId;
        final ownerUid = journal['ownerUid']?.toString() ?? 'owner';
        final walletId = journal['walletId']?.toString() ??
            'WALLET_${operator.toUpperCase()}';
        final amountPaise =
            (journal['amountPaise'] as num?)?.toInt() ?? (amount * 100).round();
        const source = 'bank';

        final challenge = await client.requestChallenge(
          shopId: shopId,
          deviceId: devId,
          ownerUid: ownerUid,
        );

        final canonicalData = '$walletId:$amountPaise:$referenceNo:$source';
        final canonicalPayload =
            'PROCESS_TOPUP:$shopId:$ownerUid:$devId:${challenge.nonce}:$canonicalData';
        final sig = await sec.signRawPayload(canonicalPayload);

        final res = await client.processTopup(
          shopId: shopId,
          walletId: walletId,
          amountPaise: amountPaise,
          source: source,
          staffId: staffId,
          staffName: staffName,
          referenceId: referenceNo,
          description: journal['description']?.toString(),
          deviceId: devId,
          deviceSignature: sig,
          nonce: challenge.nonce,
        );

        if (res['success'] == true) {
          await markTopUpServerConfirmed(
            idempotencyKey,
            serverDepositId: res['reference_id']?.toString() ?? idempotencyKey,
            balanceAfterPaise: res['total_balance_paise'] as int?,
          );

          await executeTopUpSettlement(
            idempotencyKey: idempotencyKey,
            shopId: shopId,
            operator: operator,
            amount: amount,
            referenceNo: referenceNo,
            staffId: staffId,
            staffName: staffName,
            journal: journal,
          );
          debugPrint(
              '[RechargeRecoveryEngine] Initiated TopUp reconciled with server: $idempotencyKey');
          return true;
        } else {
          await markFailed(idempotencyKey,
              res['error']?.toString() ?? 'Server rejected top-up');
          return false;
        }
      } catch (e) {
        debugPrint(
            '[RechargeRecoveryEngine] Error recovering initiated top-up $idempotencyKey: $e');
        final createdAtStr = journal['createdAt']?.toString();
        if (createdAtStr != null) {
          final dt = DateTime.tryParse(createdAtStr);
          if (dt != null && DateTime.now().difference(dt).inMinutes > 1440) {
            await markFailed(
                idempotencyKey, 'Expired in-flight top-up (>24h): $e');
          }
        }
        return false;
      }
    }

    return false;
  }

  static Future<void> _executeLocalSettlement({
    required String idempotencyKey,
    required String paymentMode,
    required double retailAmount,
    required double costPrice,
    dynamic partyKey,
    required String partyName,
    required String mobile,
    required String operator,
    required String serviceType,
    required String notes,
    required String serverTxnKey,
    Map<String, dynamic>? journal,
  }) async {
    // 1. Post-confirmation Customer Settlement
    // Only credit ledger if this transaction was not already committed locally
    if (paymentMode == 'Cash') {
      if (!hasMoneyMoved(idempotencyKey)) {
        await Db.moveMoney('Cash', retailAmount,
            'Recharge Sale (Recovered): $operator $mobile (Txn: $idempotencyKey)');
      }
    } else if (paymentMode == 'UPI') {
      if (!hasMoneyMoved(idempotencyKey)) {
        await Db.moveMoney('Bank', retailAmount,
            'Recharge UPI (Recovered): $operator $mobile (Txn: $idempotencyKey)');
      }
    } else if (paymentMode == 'Credit / Due') {
      if (partyKey == null || !Db.parties.containsKey(partyKey)) {
        // Critical Rule: Never silently redirect customer debt to general receivables
        await markManualReviewRequired(
          idempotencyKey,
          'Customer party record missing/deleted (partyKey: $partyKey, name: $partyName). Debt must be manually reviewed.',
        );
        throw StateError(
            'MANUAL_REVIEW_REQUIRED: Identified customer party record missing/deleted. Debt held for owner review.');
      }
      final bool alreadySettledParty = journal?['settledParty'] == true;
      if (!alreadySettledParty) {
        await Db.adjustParty(partyKey, retailAmount);
        await markPartySettled(idempotencyKey);
      }
    }

    // 2. Cache Non-Authoritative Read-Model in Db.recharges
    final now = DateTime.now();
    final profit = retailAmount - costPrice;
    final entry = {
      'id': idempotencyKey,
      'rechargeId': idempotencyKey,
      'serverTxnKey': serverTxnKey,
      'date': now.toIso8601String(),
      'createdAt': now.toIso8601String(),
      'mobile': mobile,
      'customerMobile': mobile,
      'operator': operator,
      'operatorName': operator,
      'serviceType': serviceType,
      'retailAmount': retailAmount,
      'amount': retailAmount,
      'amountPaise': (retailAmount * 100).round(),
      'costPrice': costPrice,
      'costPricePaise': (costPrice * 100).round(),
      'commission': profit,
      'commissionEarnedPaise': (profit * 100).round(),
      'paymentMode': paymentMode,
      'partyKey': partyKey,
      'partyName': partyName,
      'notes': notes,
      'status': 'SUCCESS',
      'serverConfirmed': true,
      'recoveredPostCrash': true,
    };
    await Db.recharges.put(idempotencyKey, entry);

    await Db.logAction(
      action: 'RECHARGE_CRASH_RECONCILED',
      entity: 'recharge',
      entityId: idempotencyKey,
      newValue: 'Recovered $operator recharge ₹$retailAmount for $mobile',
      reason: 'Automated post-crash financial reconciliation completed',
    );
  }
}
