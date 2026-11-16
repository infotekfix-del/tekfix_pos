import 'package:flutter/foundation.dart';
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
  static Future<void> markManualReviewRequired(String idempotencyKey, String reason) async {
    final raw = Db.rechargeQueue.get(idempotencyKey);
    final journal = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    journal['status'] = statusManualReviewRequired;
    journal['reviewReason'] = reason;
    journal['flaggedAt'] = DateTime.now().toIso8601String();
    await Db.rechargeQueue.put(idempotencyKey, journal);

    await Db.logAction(
      action: 'RECHARGE_MANUAL_REVIEW_REQUIRED',
      entity: 'Recharge',
      entityId: idempotencyKey,
      newValue: reason,
      reason: 'Customer party record missing/deleted; manual debt reassignment required',
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
      if (item is Map && item['note']?.toString().contains('(Txn: $idempotencyKey)') == true) {
        return true;
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
      final idempotencyKey = journal['idempotencyKey']?.toString() ?? key.toString();

      // Skip entries currently held for manual review by shop owner
      if (status == statusManualReviewRequired) {
        debugPrint('[RechargeRecoveryEngine] Skipping $idempotencyKey: HELD FOR MANUAL REVIEW');
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
          debugPrint('[RechargeRecoveryEngine] Interrupted settlement reconciled for $idempotencyKey');
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
          final shopId = journal['shopId']?.toString() ?? Db.setting('shop_id', 'shop_staging_001');
          final sec = DeviceSecurityService.instance;
          final devId = sec.deviceId;

          final ownerUid = journal['ownerUid']?.toString() ?? 'owner_staging_001';

          // Request challenge to safely query or re-verify idempotency
          final challenge = await client.requestChallenge(shopId: shopId, deviceId: devId, ownerUid: ownerUid);
          final debitAmountPaise = ((costPrice > 0 ? costPrice : retailAmount) * 100).round();
          final targetWalletId = 'WALLET_${operator.toUpperCase()}';
          const fundingType = 'ownPrepaid';
          final canonicalData = '$targetWalletId:$idempotencyKey:$debitAmountPaise:$fundingType';
          final canonicalPayload = 'PROCESS_DEBIT:$shopId:${journal['ownerUid'] ?? 'owner'}:$devId:${challenge.nonce}:$canonicalData';
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
            debugPrint('[RechargeRecoveryEngine] In-flight transaction reconciled with server: $idempotencyKey');
          } else {
            // Terminal error from server
            await markFailed(idempotencyKey, res['error']?.toString() ?? 'Server rejected');
          }
        } catch (e) {
          final createdAtStr = journal['createdAt']?.toString();
          if (createdAtStr != null) {
            final dt = DateTime.tryParse(createdAtStr);
            if (dt != null && DateTime.now().difference(dt).inMinutes > 10) {
              await markFailed(idempotencyKey, 'Expired in-flight transaction: $e');
            }
          }
        }
      }
    }

    return reconciledCount;
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
        await Db.moveMoney('Cash', retailAmount, 'Recharge Sale (Recovered): $operator $mobile (Txn: $idempotencyKey)');
      }
    } else if (paymentMode == 'UPI') {
      if (!hasMoneyMoved(idempotencyKey)) {
        await Db.moveMoney('Bank', retailAmount, 'Recharge UPI (Recovered): $operator $mobile (Txn: $idempotencyKey)');
      }
    } else if (paymentMode == 'Credit / Due') {
      if (partyKey == null || !Db.parties.containsKey(partyKey)) {
        // Critical Rule: Never silently redirect customer debt to general receivables
        await markManualReviewRequired(
          idempotencyKey,
          'Customer party record missing/deleted (partyKey: $partyKey, name: $partyName). Debt must be manually reviewed.',
        );
        throw StateError('MANUAL_REVIEW_REQUIRED: Identified customer party record missing/deleted. Debt held for owner review.');
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
