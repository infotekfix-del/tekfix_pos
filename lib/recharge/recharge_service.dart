import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:uuid/uuid.dart';

import '../firebase_options.dart';
import '../security/device_security_service.dart';
import '../security/staging_identity_service.dart';
import 'recharge_backend_bridge.dart';
import '../main.dart' show Db, boxRecharges, boxRechargeQueue, boxRechargeDeadLetter, boxRechargeReconciliation, boxRechargeWalletLedger;
import 'recharge_models.dart';

/// Master Service for Operator Wallets, Distributor Credit, and Recharge Accounting
class RechargeService {
  RechargeService._();
  static final RechargeService instance = RechargeService._();

  static const _uuid = Uuid();

  // In-flight locks to prevent double-tap submissions
  final Set<String> _inFlightOperations = {};

  String _resolveActiveUid([String? preferred]) {
    if (preferred != null && preferred.trim().isNotEmpty) return preferred.trim();
    if (DefaultFirebaseOptions.isUatMode) return StagingIdentityService.defaultOwnerUid;
    final authUid = Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser?.uid : null;
    if (authUid != null && authUid.trim().isNotEmpty) return authUid.trim();
    return '';
  }

  // Concurrency lock per wallet to serialize simultaneous debit operations
  final Map<String, Future<void>> _walletOperationLocks = {};

  // Local state caches (Instant offline responsiveness and resilient fallback)
  final Map<String, OperatorWallet> _localWallets = {};
  final Map<String, DistributorProfile> _localDistributors = {};
  final Map<String, RechargeEntry> _localRecharges = {};
  final List<WalletLedgerEntry> _localWalletLedger = [];
  final List<DistributorLedgerEntry> _localDistributorLedger = [];
  final Map<String, DailyRechargeCollectionSummary> _localDailyCollections = {};
  final Set<String> _financiallyPostedRecharges = {};
  final List<FloatDepositRecord> _localFloatDeposits = [];
  final Map<String, RechargeCommissionEntry> _localCommissions = {};
  final Map<String, CustomerRefundRecord> _localRefunds = {};
  final List<ReversalLedgerEntry> _localReversals = [];
  final Map<String, DailyReconciliationRecord> _localDailyReconciliations = {};
  bool enforceDailyOpeningBalance = true;

  void disableOpeningBalanceGateForTesting() {
    enforceDailyOpeningBalance = false;
  }

  void enableOpeningBalanceGateForTesting() {
    enforceDailyOpeningBalance = true;
  }

  /// Centralized business date utility using configured shop timezone (Default: Asia/Kolkata, UTC+5:30)
  static String getBusinessDate({DateTime? utcTime, String timezone = 'Asia/Kolkata'}) {
    final nowUtc = utcTime?.toUtc() ?? DateTime.now().toUtc();
    const Duration kolkataOffset = Duration(hours: 5, minutes: 30);
    final targetTime = nowUtc.add(kolkataOffset);
    return DateFormat('yyyy-MM-dd').format(targetTime);
  }

  /// Current DateTime in shop timezone (Asia/Kolkata)
  static DateTime getShopNow({DateTime? utcTime, String timezone = 'Asia/Kolkata'}) {
    final nowUtc = utcTime?.toUtc() ?? DateTime.now().toUtc();
    const Duration kolkataOffset = Duration(hours: 5, minutes: 30);
    return nowUtc.add(kolkataOffset);
  }

  /// Verify whether a UID is an authoritative shop owner
  Future<bool> isAuthorizedShopOwner({
    required String shopId,
    required String uid,
  }) async {
    if (Firebase.apps.isEmpty || shopId.isEmpty) return true; // Offline / unit test fallback
    try {
      final shopDoc = await FirebaseFirestore.instance.collection('shops').doc(shopId).get();
      if (shopDoc.exists && shopDoc.data()?['ownerUid'] == uid) {
        return true;
      }
      final userDoc = await FirebaseFirestore.instance
          .collection('shops')
          .doc(shopId)
          .collection('users')
          .doc(uid)
          .get();
      if (userDoc.exists) {
        final role = userDoc.data()?['role']?.toString().toLowerCase();
        if (role == 'owner' || role == 'admin') return true;
      }
      return false;
    } catch (e) {
      debugPrint('[RechargeService] isAuthorizedShopOwner check error: $e');
      return false;
    }
  }

  Future<void> _recordWalletLedgerEntry(WalletLedgerEntry entry) async {
    final existsIndex = _localWalletLedger.indexWhere((e) => e.txnId == entry.txnId);
    if (existsIndex >= 0) {
      _localWalletLedger[existsIndex] = entry;
    } else {
      _localWalletLedger.add(entry);
    }
    if (Hive.isBoxOpen(boxRechargeWalletLedger)) {
      try {
        await Hive.box(boxRechargeWalletLedger).put(entry.txnId, entry.toMap(forFirestore: false));
      } catch (e) {
        debugPrint('[RechargeService] Wallet ledger Hive save notice: $e');
      }
    }
  }

  Future<int> rehydrateWalletLedgerFromHive({String? shopId}) async {
    int count = 0;
    if (Hive.isBoxOpen(boxRechargeWalletLedger)) {
      try {
        final box = Hive.box(boxRechargeWalletLedger);
        for (final key in box.keys) {
          final val = box.get(key);
          if (val is Map) {
            final entry = WalletLedgerEntry.fromMap(Map<String, dynamic>.from(val), key.toString());
            if (shopId == null || entry.shopId == shopId) {
              if (!_localWalletLedger.any((e) => e.txnId == entry.txnId)) {
                _localWalletLedger.add(entry);
                count++;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[RechargeService] rehydrateWalletLedgerFromHive notice: $e');
      }
    }
    return count;
  }

  static const List<RechargeOperator> requiredDailyOperators = [
    RechargeOperator.jio,
    RechargeOperator.airtel,
    RechargeOperator.vi,
    RechargeOperator.bsnl,
  ];

  void resetLocalCacheForTesting() {
    _inFlightOperations.clear();
    _walletOperationLocks.clear();
    _localWallets.clear();
    _localDistributors.clear();
    _localRecharges.clear();
    _localWalletLedger.clear();
    _localDistributorLedger.clear();
    _localDailyCollections.clear();
    _financiallyPostedRecharges.clear();
    _localFloatDeposits.clear();
    _localCommissions.clear();
    _localRefunds.clear();
    _localReversals.clear();
    _localDailyReconciliations.clear();
    enforceDailyOpeningBalance = true;
  }

  // ---------------------------------------------------------------------------
  // OFFLINE HIVE PERSISTENCE & RETRY QUEUE
  // ---------------------------------------------------------------------------
  Future<void> _persistRecord(RechargeEntry entry) async {
    try {
      if (Hive.isBoxOpen(boxRecharges)) {
        await Hive.box(boxRecharges)
            .put(entry.rechargeId, entry.toMap(forFirestore: false));
      }
    } catch (e) {
      debugPrint('[RechargeService] _persistRecord notice: $e');
    }
  }

  bool _isFlushingQueue = false;

  Future<void> _queueOfflineOperation(
      String opType, Map<String, dynamic> payload) async {
    try {
      if (Hive.isBoxOpen(boxRechargeQueue)) {
        final queueId = payload['idempotencyKey'] as String? ??
            payload['rechargeId'] as String? ??
            'Q_${opType}_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 6)}';
        await Hive.box(boxRechargeQueue).put(queueId, {
          'queueId': queueId,
          'idempotencyKey': queueId,
          'opType': opType,
          'payload': payload,
          'queuedAt': DateTime.now().toIso8601String(),
          'status': 'pending',
          'retryCount': 0,
        });
      }
    } catch (e) {
      debugPrint('[RechargeService] _queueOfflineOperation notice: $e');
    }
  }

  /// Calculate total paise currently reserved in offline pending operations for a given wallet (FIX A1)
  int getPendingReservationPaise({
    required String shopId,
    required String walletId,
    RechargeFundingType? fundingType,
  }) {
    int totalReservedPaise = 0;
    try {
      if (Hive.isBoxOpen(boxRechargeQueue)) {
        final qBox = Hive.box(boxRechargeQueue);
        for (final key in qBox.keys) {
          final item = qBox.get(key);
          if (item is Map) {
            final qData = Map<String, dynamic>.from(item);
            if (qData['status'] == 'pending' && qData['opType'] == 'RECHARGE_DEBIT') {
              final payload = Map<String, dynamic>.from(qData['payload'] as Map? ?? {});
              final itemShopId = payload['shopId'] as String? ?? '';
              final itemWalletId = payload['walletId'] as String? ?? '';
              final itemFunding = payload['fundingType'] as String? ?? '';

              if (itemShopId == shopId && itemWalletId == walletId) {
                if (fundingType == null || itemFunding == fundingType.name) {
                  final amt = (payload['amountPaise'] as num?)?.toInt() ??
                      ((payload['amount'] as num? ?? 0) * 100).round();
                  totalReservedPaise += amt;
                }
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[RechargeService] getPendingReservationPaise notice: $e');
    }
    return totalReservedPaise;
  }

  /// Rehydrate local recharge cache from durable Hive storage
  Future<int> rehydrateFromHive() async {
    int count = 0;
    try {
      if (Hive.isBoxOpen(boxRecharges)) {
        final box = Hive.box(boxRecharges);
        for (final key in box.keys) {
          final val = box.get(key);
          if (val is Map) {
            try {
              final entry = RechargeEntry.fromMap(
                Map<String, dynamic>.from(val),
                key.toString(),
              );
              _localRecharges[entry.rechargeId] = entry;
              count++;
            } catch (e) {
              debugPrint('[RechargeService] rehydrate error for key $key: $e');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[RechargeService] rehydrateFromHive notice: $e');
    }
    return count;
  }

  /// Flush durable offline operations queue when network connectivity restores
  /// Enforces serialized execution, 24-hour expiration TTL, dead-letter routing,
  /// and updates local wallet balance ONLY upon server confirmation.
  Future<int> flushOfflineQueue() async {
    if (_isFlushingQueue) {
      debugPrint('[RechargeService] flushOfflineQueue already in progress, skipping concurrent run');
      return 0;
    }
    _isFlushingQueue = true;
    int processed = 0;

    try {
      if (!Hive.isBoxOpen(boxRechargeQueue)) return 0;
      final qBox = Hive.box(boxRechargeQueue);
      final keys = List.from(qBox.keys);

      for (final key in keys) {
        final item = qBox.get(key);
        if (item is! Map) continue;

        final qData = Map<String, dynamic>.from(item);
        final opType = qData['opType'] as String?;
        final payload =
            Map<String, dynamic>.from(qData['payload'] as Map? ?? {});
        final recId = payload['rechargeId'] as String? ?? key.toString();

        // 1. 24-HOUR EXPIRATION TTL CHECK
        final queuedAtStr = qData['queuedAt'] as String?;
        if (queuedAtStr != null) {
          final queuedAt = DateTime.tryParse(queuedAtStr);
          if (queuedAt != null && DateTime.now().difference(queuedAt).inHours >= 24) {
            debugPrint('[RechargeService] Queue item $key expired (>24h TTL)');
            await _moveToDeadLetter(
              queueId: key.toString(),
              qData: qData,
              reason: 'EXPIRED_24H_OFFLINE',
            );
            if (_localRecharges.containsKey(recId)) {
              final expired = _localRecharges[recId]!.copyWith(
                status: RechargeStatus.failed,
                notes: 'റീചാർജ് കാലഹരണപ്പെട്ടു (EXPIRED_24H_OFFLINE: Request expired after 24h in offline queue)',
                isOfflinePending: false,
              );
              _localRecharges[recId] = expired;
              await _persistRecord(expired);
            }
            await qBox.delete(key);
            continue;
          }
        }

        // 2. RETRY LIMIT CHECK (Max 5 attempts before dead-lettering)
        final retryCount = (qData['retryCount'] as int? ?? 0);
        if (retryCount >= 5) {
          debugPrint('[RechargeService] Queue item $key exceeded max retries ($retryCount)');
          await _moveToDeadLetter(
            queueId: key.toString(),
            qData: qData,
            reason: 'DEAD_LETTER_MAX_RETRIES',
          );
          if (_localRecharges.containsKey(recId)) {
            final failed = _localRecharges[recId]!.copyWith(
              status: RechargeStatus.failed,
              notes: 'പരാജയപ്പെട്ടു: പരമാവധി ശ്രമങ്ങൾ കഴിഞ്ഞു (DEAD_LETTER_MAX_RETRIES: Exceeded 5 retry attempts)',
              isOfflinePending: false,
            );
            _localRecharges[recId] = failed;
            await _persistRecord(failed);
          }
          await qBox.delete(key);
          continue;
        }

        // 3. EXECUTE SERVER TRANSACTION
        if (Firebase.apps.isNotEmpty) {
          try {
            final shopId = payload['shopId'] as String? ?? '';
            if (shopId.isEmpty) {
              await qBox.delete(key);
              continue;
            }

            if (opType == 'RECHARGE_DEBIT') {
              final sec = DeviceSecurityService.instance;
              final devId = sec.deviceId;
              final amountPaise = (payload['amountPaise'] as num?)?.toInt() ??
                  ((payload['amount'] as num? ?? 0) * 100).round();
              final walletId = payload['walletId'] as String? ??
                  'WALLET_${(payload['operator'] as String? ?? '').toUpperCase()}';
              final op = payload['operator'] as String;
              final funding = payload['fundingType'] as String? ?? 'ownMoney';
              final bDate = payload['dateString'] as String? ??
                  payload['businessDate'] as String? ??
                  '';
              final idempotencyKey = payload['idempotencyKey'] as String? ?? recId;

              int serverBalance = 0;

              if (RechargeBackendBridge.isSupabaseMode) {
                if (RechargeBackendBridge.supabaseClient != null) {
                  final challenge =
                      await RechargeBackendBridge.supabaseClient!.requestChallenge(
                    shopId: shopId,
                    deviceId: devId,
                  );
                  final ownerUid = _resolveActiveUid(payload['staffId'] as String?);
                  final signature = await sec.signChallenge(
                    shopId: shopId,
                    ownerUid: ownerUid,
                    nonce: challenge.nonce,
                  );
                  final res =
                      await RechargeBackendBridge.supabaseClient!.processDebit(
                    shopId: shopId,
                    walletId: walletId,
                    rechargeId: recId,
                    idempotencyKey: idempotencyKey,
                    operator: op,
                    amountPaise: amountPaise,
                    amount: payload['amount'] ?? 0,
                    fundingType: funding,
                    businessDate: bDate,
                    deviceId: devId,
                    deviceSignature: signature,
                    nonce: challenge.nonce,
                    rechargeData: payload,
                  );
                  serverBalance = (res['balanceAfterPaise'] as num?)?.toInt() ??
                      (res['newBalancePaise'] as num?)?.toInt() ??
                      0;
                } else if (Firebase.apps.isNotEmpty) {
                  throw StateError('[RechargeService] Supabase client is not configured for Recharge Accounting.');
                }
              } else {
                final callable = DefaultFirebaseOptions.functionsInstance
                    .httpsCallable('processRechargeDebit');
                final response = await callable.call<Map<String, dynamic>>({
                  'shopId': shopId,
                  'walletId': walletId,
                  'rechargeId': recId,
                  'idempotencyKey': idempotencyKey,
                  'operator': op,
                  'amountPaise': amountPaise,
                  'amount': payload['amount'],
                  'fundingType': funding,
                  'businessDate': bDate,
                  'rechargeData': payload,
                  'deviceId': devId,
                });
                final res = Map<String, dynamic>.from(response.data);
                serverBalance = (res['balanceAfterPaise'] as num?)?.toInt() ??
                    (res['newBalancePaise'] as num?)?.toInt() ??
                    0;
              }

              // Server confirmed debit! Now update local wallet balance
              final opEnum = RechargeOperator.values.firstWhere(
                (e) => e.name.toLowerCase() == op.toLowerCase(),
                orElse: () => RechargeOperator.other,
              );
              final isOwnMoney = funding == 'ownMoney';
              final wallet = await getWallet(shopId: shopId, operator: opEnum);
              final beforeBalance = isOwnMoney
                  ? wallet.ownPrepaidBalancePaise
                  : wallet.distributorCreditBalancePaise;
              final effectiveAfter = serverBalance > 0
                  ? serverBalance
                  : (beforeBalance - amountPaise).clamp(0, 1 << 62);

              final updatedWallet = isOwnMoney
                  ? wallet.copyWith(
                      ownPrepaidBalancePaise: effectiveAfter,
                      updatedAt: DateTime.now(),
                    )
                  : wallet.copyWith(
                      distributorCreditBalancePaise: effectiveAfter,
                      updatedAt: DateTime.now(),
                    );
              _localWallets['${shopId}_${wallet.walletId}'] = updatedWallet;

              // Record confirmed wallet ledger entry
              await _recordWalletLedgerEntry(WalletLedgerEntry(
                txnId: 'TXN_$recId',
                shopId: shopId,
                walletId: wallet.walletId,
                operator: opEnum,
                fundingType: isOwnMoney
                    ? RechargeFundingType.ownMoney
                    : RechargeFundingType.distributorCredit,
                entryType: 'RECHARGE_DEBIT',
                amount: (amountPaise / 100).toDouble(),
                amountPaise: amountPaise,
                balanceBeforePaise: beforeBalance,
                balanceAfterPaise: effectiveAfter,
                referenceId: recId,
                description: 'Recharge ${opEnum.displayName} (Synced)',
                staffId: payload['staffId'] as String? ?? '',
                staffName: payload['staffName'] as String? ?? '',
                timestamp: DateTime.now(),
              ));

              // Mark local recharge as confirmed success
              if (_localRecharges.containsKey(recId)) {
                final confirmed = _localRecharges[recId]!.copyWith(
                  status: RechargeStatus.success,
                  walletDebited: true,
                  isOfflinePending: false,
                );
                _localRecharges[recId] = confirmed;
                await _persistRecord(confirmed);
              }

              await qBox.delete(key);
              processed++;
              continue;
            } else if (opType == 'RECHARGE_RECORD') {
              final firestore = FirebaseFirestore.instance;
              await firestore
                  .collection('shops')
                  .doc(shopId)
                  .collection('recharge_transactions')
                  .doc(recId)
                  .set(payload, SetOptions(merge: true));

              if (_localRecharges.containsKey(recId)) {
                final updated =
                    _localRecharges[recId]!.copyWith(isOfflinePending: false);
                _localRecharges[recId] = updated;
                await _persistRecord(updated);
              }
              await qBox.delete(key);
              processed++;
              continue;
            }
          } catch (e) {
            final errStr = e.toString().toLowerCase();
            final isFatal = errStr.contains('insufficient') ||
                errStr.contains('permission-denied') ||
                errStr.contains('unauthenticated') ||
                errStr.contains('invalid-argument') ||
                errStr.contains('failed-precondition') ||
                errStr.contains('not-found');

            if (isFatal) {
              debugPrint('[RechargeService] Fatal error on queue item $key: $e');
              await _moveToDeadLetter(
                queueId: key.toString(),
                qData: qData,
                reason: 'FATAL_SERVER_REJECTION: $e',
              );
              if (_localRecharges.containsKey(recId)) {
                final failed = _localRecharges[recId]!.copyWith(
                  status: RechargeStatus.failed,
                  notes: 'റീചാർജ് നിരസിച്ചു ($e)',
                  isOfflinePending: false,
                );
                _localRecharges[recId] = failed;
                await _persistRecord(failed);
              }
              await qBox.delete(key);
            } else {
              // Transient network error: increment retry count
              debugPrint('[RechargeService] Transient error on queue item $key: $e');
              qData['retryCount'] = retryCount + 1;
              qData['lastRetryAt'] = DateTime.now().toIso8601String();
              qData['lastError'] = e.toString();
              await qBox.put(key, qData);
            }
            continue;
          }
        } else {
          // In unit test / mock mode without live Firebase initialization:
          if (_localRecharges.containsKey(recId)) {
            final existing = _localRecharges[recId]!;
            if (existing.isOfflinePending) {
              final updated = existing.copyWith(isOfflinePending: false);
              _localRecharges[recId] = updated;
              await _persistRecord(updated);
            }
          }
          await qBox.delete(key);
          processed++;
        }
      }
    } catch (e) {
      debugPrint('[RechargeService] flushOfflineQueue error: $e');
    } finally {
      _isFlushingQueue = false;
    }
    return processed;
  }

  Future<void> _moveToDeadLetter({
    required String queueId,
    required Map<String, dynamic> qData,
    required String reason,
  }) async {
    try {
      if (Hive.isBoxOpen(boxRechargeDeadLetter)) {
        await Hive.box(boxRechargeDeadLetter).put(queueId, {
          ...qData,
          'deadLetterReason': reason,
          'deadLetteredAt': DateTime.now().toIso8601String(),
        });
      }
    } catch (e) {
      debugPrint('[RechargeService] _moveToDeadLetter notice: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 1. WALLET IDENTIFIERS & INITIALIZATION
  // ---------------------------------------------------------------------------
  static String getWalletId(RechargeOperator operator) {
    switch (operator) {
      case RechargeOperator.airtel:
        return 'WALLET_AIRTEL';
      case RechargeOperator.jio:
        return 'WALLET_JIO';
      case RechargeOperator.vi:
        return 'WALLET_VI';
      case RechargeOperator.bsnl:
        return 'WALLET_BSNL';
      case RechargeOperator.other:
        return 'WALLET_OTHER';
    }
  }

  /// Get or initialize an Operator Wallet
  Future<OperatorWallet> getWallet({
    required String shopId,
    required RechargeOperator operator,
  }) async {
    final wId = getWalletId(operator);
    final cacheKey = '${shopId}_$wId';

    if (_localWallets.containsKey(cacheKey)) {
      return _localWallets[cacheKey]!;
    }

    // 1. Supabase Air-Gapped Mode: Authoritative PostgreSQL fetch via Bridge
    if (RechargeBackendBridge.isSupabaseMode && RechargeBackendBridge.supabaseClient != null) {
      try {
        final wData = await RechargeBackendBridge.supabaseClient!.getWallet(
          shopId: shopId,
          walletId: wId,
        );
        if (wData != null) {
          final w = OperatorWallet(
            walletId: wData['wallet_id']?.toString() ?? wId,
            shopId: wData['shop_id']?.toString() ?? shopId,
            operator: operator,
            operatorName: operator.displayName,
            ownPrepaidBalancePaise: (wData['own_prepaid_balance_paise'] as num?)?.toInt() ?? 0,
            distributorCreditBalancePaise: (wData['distributor_credit_balance_paise'] as num?)?.toInt() ?? 0,
            updatedAt: DateTime.tryParse(wData['last_updated_at']?.toString() ?? '') ?? DateTime.now(),
          );
          _localWallets[cacheKey] = w;
          return w;
        }
      } catch (e) {
        debugPrint('[RechargeService] Supabase wallet fetch notice: $e');
      }
    }

    // 2. Legacy Firebase Mode (Fallback / Local emulator only)
    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty && !RechargeBackendBridge.isSupabaseMode) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('recharge_wallets')
            .doc(wId)
            .get();

        if (doc.exists && doc.data() != null) {
          final w = OperatorWallet.fromFirestore(doc);
          _localWallets[cacheKey] = w;
          return w;
        }
      } catch (e) {
        debugPrint('[RechargeService] Wallet remote fetch notice: $e');
      }
    }

    // Default zero wallet
    final defaultWallet = OperatorWallet(
      walletId: wId,
      shopId: shopId,
      operator: operator,
      operatorName: operator.displayName,
      ownPrepaidBalancePaise: 0,
      distributorCreditBalancePaise: 0,
      updatedAt: DateTime.now(),
    );

    _localWallets[cacheKey] = defaultWallet;
    return defaultWallet;
  }

  // ---------------------------------------------------------------------------
  // 2. FUNDING TYPE A: OWN MONEY / PREPAID WALLET TOP-UP
  // ---------------------------------------------------------------------------
  /// Record shop's own bank transfer to operator wallet
  /// Accounting Impact:
  /// - Bank Balance: -amount (Asset decreases)
  /// - Wallet Own Balance: +amount (Asset increases)
  /// - Expenses: ₹0 (Not an expense! Asset-to-asset transfer)
  /// - Distributor Payable: ₹0 (No liability created)
  Future<({OperatorWallet wallet, WalletLedgerEntry entry})>
      recordOwnMoneyTopUp({
    required String shopId,
    required RechargeOperator operator,
    required double amount,
    required String staffId,
    required String staffName,
    String? referenceId,
    String description = 'Own Bank Transfer Top-Up',
  }) async {
    if (amount <= 0) {
      throw ArgumentError('തുക പോസിറ്റീവ് ആയിരിക്കണം (Amount must be positive)');
    }

    final amountPaise = (amount * 100).round();
    final txnId = referenceId?.isNotEmpty == true
        ? referenceId!
        : 'TOP_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 6)}';

    // Idempotency check
    if (_inFlightOperations.contains(txnId)) {
      throw Exception('ഈ ഇടപാട് ഇതിനകം പ്രോസസ്സ് ചെയ്യുന്നു (Duplicate top-up blocked)');
    }
    _inFlightOperations.add(txnId);

    try {
      final currentWallet = await getWallet(shopId: shopId, operator: operator);
      final beforePaise = currentWallet.ownPrepaidBalancePaise;
      final afterPaise = beforePaise + amountPaise;

      final updatedWallet = currentWallet.copyWith(
        ownPrepaidBalancePaise: afterPaise,
        updatedAt: DateTime.now(),
      );

      final ledgerEntry = WalletLedgerEntry(
        txnId: txnId,
        shopId: shopId,
        walletId: currentWallet.walletId,
        operator: operator,
        fundingType: RechargeFundingType.ownMoney,
        entryType: 'TOPUP',
        amount: amount,
        amountPaise: amountPaise,
        balanceBeforePaise: beforePaise,
        balanceAfterPaise: afterPaise,
        referenceId: txnId,
        description: description,
        staffId: staffId,
        staffName: staffName,
        timestamp: DateTime.now(),
      );

      // Remote Atomic Commit: PostgreSQL via Supabase Bridge or Firestore Fallback
      if (RechargeBackendBridge.isSupabaseMode) {
        if (RechargeBackendBridge.supabaseClient != null) {
          final sec = DeviceSecurityService.instance;
          final dId = sec.deviceId;
          final challenge = await RechargeBackendBridge.supabaseClient!.requestChallenge(
            shopId: shopId,
            deviceId: dId,
          );
          final currentUid = _resolveActiveUid(staffId);
          final sig = await sec.signChallenge(
            shopId: shopId,
            ownerUid: currentUid,
            nonce: challenge.nonce,
          );

          await RechargeBackendBridge.supabaseClient!.processTopup(
            shopId: shopId,
            walletId: currentWallet.walletId,
            amountPaise: amountPaise,
            source: 'bank',
            staffId: staffId,
            staffName: staffName,
            referenceId: txnId,
            description: description,
            deviceId: dId,
            deviceSignature: sig,
            nonce: challenge.nonce,
          );
        } else if (Firebase.apps.isNotEmpty) {
          throw StateError('[RechargeService] Supabase client is not configured for Recharge Accounting.');
        }
      } else if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
        try {
          final firestore = FirebaseFirestore.instance;
          final walletRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_wallets')
              .doc(currentWallet.walletId);
          final logRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_wallet_logs')
              .doc(txnId);

          await firestore.runTransaction((transaction) async {
            final snap = await transaction.get(logRef);
            if (snap.exists) {
              throw Exception('Duplicate top-up transaction in Firestore: $txnId');
            }

            transaction.set(walletRef, updatedWallet.toMap(forFirestore: true),
                SetOptions(merge: true));
            transaction.set(logRef, ledgerEntry.toMap(forFirestore: true));
          });
        } catch (e) {
          debugPrint('[RechargeService] Firestore topup notice: $e');
        }
      }

      // Update local bank balance: Asset Transfer (Decreases bank balance)
      try {
        await Db.moveMoney(
            'Bank', -amount, 'Topup ${operator.displayName} ($txnId)');
      } catch (_) {}

      // Cache state locally
      _localWallets['${shopId}_${currentWallet.walletId}'] = updatedWallet;
      await _recordWalletLedgerEntry(ledgerEntry);

      return (wallet: updatedWallet, entry: ledgerEntry);
    } finally {
      _inFlightOperations.remove(txnId);
    }
  }

  // ---------------------------------------------------------------------------
  // 3. FUNDING TYPE B: DISTRIBUTOR CREDIT WALLET LOAD
  // ---------------------------------------------------------------------------
  /// Record credit stock loaded by a telecom distributor
  /// Accounting Impact:
  /// - Wallet Distributor Credit: +amount (Asset increases)
  /// - Distributor Payable: +amount (Liability increases)
  /// - Bank / Cash Balance: ₹0 (No money moved)
  /// - Income / Sales: ₹0 (Not revenue!)
  Future<
      ({
        OperatorWallet wallet,
        DistributorProfile distributor,
        WalletLedgerEntry walletEntry,
        DistributorLedgerEntry distributorEntry
      })> recordDistributorCreditLoad({
    required String shopId,
    required RechargeOperator operator,
    required String distributorId,
    required double amount,
    required String staffId,
    required String staffName,
    String? referenceNumber,
    String notes = 'Distributor Credit Stock Load',
  }) async {
    if (amount <= 0) {
      throw ArgumentError('തുക പോസിറ്റീവ് ആയിരിക്കണം (Amount must be positive)');
    }

    final amountPaise = (amount * 100).round();
    final txnId = referenceNumber?.isNotEmpty == true
        ? referenceNumber!
        : 'CRED_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 6)}';

    if (_inFlightOperations.contains(txnId)) {
      throw Exception('ഈ ക്രെഡിറ്റ് ലോഡ് ഇതിനകം പ്രോസസ്സ് ചെയ്യുന്നു (Duplicate credit blocked)');
    }
    _inFlightOperations.add(txnId);

    try {
      final currentWallet = await getWallet(shopId: shopId, operator: operator);
      final currentDist = await getDistributor(
          shopId: shopId, distributorId: distributorId);

      final walletBeforePaise = currentWallet.distributorCreditBalancePaise;
      final walletAfterPaise = walletBeforePaise + amountPaise;

      final distBeforePaise = currentDist.currentOutstandingPaise;
      final distAfterPaise = distBeforePaise + amountPaise;

      final updatedWallet = currentWallet.copyWith(
        distributorCreditBalancePaise: walletAfterPaise,
        updatedAt: DateTime.now(),
      );

      final updatedDist = currentDist.copyWith(
        totalCreditReceivedPaise:
            currentDist.totalCreditReceivedPaise + amountPaise,
        updatedAt: DateTime.now(),
      );

      final walletEntry = WalletLedgerEntry(
        txnId: txnId,
        shopId: shopId,
        walletId: currentWallet.walletId,
        operator: operator,
        fundingType: RechargeFundingType.distributorCredit,
        entryType: 'CREDIT_LOAD',
        amount: amount,
        amountPaise: amountPaise,
        balanceBeforePaise: walletBeforePaise,
        balanceAfterPaise: walletAfterPaise,
        referenceId: txnId,
        description: 'Distributor Credit from ${currentDist.name}: $notes',
        staffId: staffId,
        staffName: staffName,
        timestamp: DateTime.now(),
      );

      final distEntry = DistributorLedgerEntry(
        entryId: 'DL_$txnId',
        shopId: shopId,
        distributorId: distributorId,
        distributorName: currentDist.name,
        entryType: 'CREDIT_RECEIVED',
        amount: amount,
        amountPaise: amountPaise,
        outstandingBeforePaise: distBeforePaise,
        outstandingAfterPaise: distAfterPaise,
        referenceNumber: txnId,
        description: 'Credit Stock Loaded for ${operator.displayName}',
        staffId: staffId,
        staffName: staffName,
        timestamp: DateTime.now(),
      );

      // Remote Atomic Commit: PostgreSQL via Supabase Bridge or Firestore Fallback
      if (RechargeBackendBridge.isSupabaseMode) {
        if (RechargeBackendBridge.supabaseClient != null) {
          final sec = DeviceSecurityService.instance;
          final dId = sec.deviceId;
          final challenge = await RechargeBackendBridge.supabaseClient!.requestChallenge(
            shopId: shopId,
            deviceId: dId,
          );
          final currentUid = _resolveActiveUid(staffId);
          final sig = await sec.signChallenge(
            shopId: shopId,
            ownerUid: currentUid,
            nonce: challenge.nonce,
          );

          await RechargeBackendBridge.supabaseClient!.processDistributorLoad(
            shopId: shopId,
            walletId: currentWallet.walletId,
            distributorId: distributorId,
            amountPaise: amountPaise,
            staffId: staffId,
            staffName: staffName,
            notes: notes,
            deviceId: dId,
            deviceSignature: sig,
            nonce: challenge.nonce,
          );
        } else if (Firebase.apps.isNotEmpty) {
          throw StateError('[RechargeService] Supabase client is not configured for Recharge Accounting.');
        }
      } else if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
        try {
          final firestore = FirebaseFirestore.instance;
          final walletRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_wallets')
              .doc(currentWallet.walletId);
          final distRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_distributors')
              .doc(distributorId);
          final wLogRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_wallet_logs')
              .doc(txnId);
          final dLogRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_distributor_ledger')
              .doc('DL_$txnId');

          await firestore.runTransaction((transaction) async {
            final snap = await transaction.get(wLogRef);
            if (snap.exists) {
              throw Exception('Duplicate credit load transaction: $txnId');
            }

            transaction.set(walletRef, updatedWallet.toMap(forFirestore: true),
                SetOptions(merge: true));
            transaction.set(distRef, updatedDist.toMap(forFirestore: true),
                SetOptions(merge: true));
            transaction.set(wLogRef, walletEntry.toMap(forFirestore: true));
            transaction.set(dLogRef, distEntry.toMap(forFirestore: true));
          });
        } catch (e) {
          debugPrint('[RechargeService] Firestore credit load notice: $e');
        }
      }

      // Update local state caches
      _localWallets['${shopId}_${currentWallet.walletId}'] = updatedWallet;
      _localDistributors['${shopId}_$distributorId'] = updatedDist;
      await _recordWalletLedgerEntry(walletEntry);
      _localDistributorLedger.add(distEntry);

      return (
        wallet: updatedWallet,
        distributor: updatedDist,
        walletEntry: walletEntry,
        distributorEntry: distEntry,
      );
    } finally {
      _inFlightOperations.remove(txnId);
    }
  }

  // ---------------------------------------------------------------------------
  // 4. RECHARGE EXECUTION & WALLET DEBIT
  // ---------------------------------------------------------------------------
  /// Process customer recharge by debiting the appropriate funding wallet
  Future<({RechargeEntry recharge, OperatorWallet wallet, WalletLedgerEntry entry})>
      processRechargeDebit({
    required RechargeEntry recharge,
  }) async {
    // Phase 12.2: Mandatory daily opening balance enforcement
    if (enforceDailyOpeningBalance) {
      final isComplete = await isOpeningComplete(
        shopId: recharge.shopId,
        businessDate: recharge.dateString,
      );
      if (!isComplete) {
        final incomplete = await getIncompleteOpeningOperators(
          shopId: recharge.shopId,
          businessDate: recharge.dateString,
        );
        final names = incomplete.map((o) => o.displayName).join(', ');
        throw Exception(
          'ദിവസേനയുള്ള ഓപ്പണിംഗ് ബാലൻസ് പൂർത്തിയായിട്ടില്ല (Daily opening balance incomplete for: $names. Please record opening balances before performing recharges.)',
        );
      }
    }

    final amountPaise = recharge.amountPaise;
    final wId = getWalletId(recharge.operator);
    final cacheKey = '${recharge.shopId}_$wId';

    if (_localRecharges.containsKey(recharge.rechargeId) ||
        _inFlightOperations.contains(recharge.rechargeId)) {
      throw Exception('ഈ റീചാർജ് ഇതിനകം സമർപ്പിച്ചുകഴിഞ്ഞു (Duplicate recharge ID: ${recharge.rechargeId})');
    }
    _inFlightOperations.add(recharge.rechargeId);

    // Multi-request concurrency serialization per wallet
    final prevLock = _walletOperationLocks[cacheKey];
    final completer = Completer<void>();
    _walletOperationLocks[cacheKey] = completer.future;
    if (prevLock != null) {
      try {
        await prevLock;
      } catch (_) {}
    }

    try {
      final wallet = await getWallet(
          shopId: recharge.shopId, operator: recharge.operator);

      final isOwnMoney =
          recharge.fundingType == RechargeFundingType.ownMoney;
      int currentBalancePaise = isOwnMoney
          ? wallet.ownPrepaidBalancePaise
          : wallet.distributorCreditBalancePaise;

      // FIX A1: Calculate total active pending reservations for this wallet
      final reservedPaise = getPendingReservationPaise(
        shopId: recharge.shopId,
        walletId: wallet.walletId,
        fundingType: recharge.fundingType,
      );
      final availableBalancePaise = currentBalancePaise - reservedPaise;

      if (availableBalancePaise < amountPaise) {
        final modeName = isOwnMoney ? 'Own Prepaid' : 'Distributor Credit';
        final availRs = ((availableBalancePaise.clamp(0, 1 << 62)) / 100).toStringAsFixed(2);
        throw Exception(
            'വാലറ്റിൽ ആവശ്യത്തിന് തുകയില്ല (പെൻഡിംഗ് ഉൾപ്പെടെ): $modeName (ലഭ്യമായത്: ₹$availRs, ആവശ്യപ്പെട്ടത്: ₹${recharge.amount.toStringAsFixed(2)})');
      }

      int newBalancePaise = currentBalancePaise - amountPaise;
      OperatorWallet updatedWallet = isOwnMoney
          ? wallet.copyWith(
              ownPrepaidBalancePaise: newBalancePaise,
              updatedAt: DateTime.now(),
            )
          : wallet.copyWith(
              distributorCreditBalancePaise: newBalancePaise,
              updatedAt: DateTime.now(),
            );

      WalletLedgerEntry ledgerEntry = WalletLedgerEntry(
        txnId: 'TXN_${recharge.rechargeId}',
        shopId: recharge.shopId,
        walletId: wallet.walletId,
        operator: recharge.operator,
        fundingType: recharge.fundingType,
        entryType: 'RECHARGE_DEBIT',
        amount: recharge.amount,
        amountPaise: amountPaise,
        balanceBeforePaise: currentBalancePaise,
        balanceAfterPaise: newBalancePaise,
        referenceId: recharge.rechargeId,
        description:
            'Recharge ${recharge.operator.displayName}: ${recharge.customerMobile}',
        staffId: recharge.staffId,
        staffName: recharge.staffName,
        timestamp: DateTime.now(),
      );

      RechargeEntry debitedRecharge = recharge.copyWith(
        walletDebited: true,
        isOfflinePending: false,
      );

      // Server-Side Trusted Transaction (Phase 12.6 + Phase 13.3.3 + Phase 13.6 Zero-Cost Backend)
      if (Firebase.apps.isNotEmpty && recharge.shopId.isNotEmpty) {
        bool serverSuccess = false;
        try {
          final sec = DeviceSecurityService.instance;
          final devId = sec.deviceId;

          Map<String, dynamic> resData;

          if (RechargeBackendBridge.isSupabaseMode) {
            if (RechargeBackendBridge.supabaseClient != null) {
              // Phase 13.6 Zero-Cost Supabase Edge Function Route
              // 1. Request single-use challenge nonce from Edge Function
              final challenge = await RechargeBackendBridge.supabaseClient!.requestChallenge(
                shopId: recharge.shopId,
                deviceId: devId,
              );

              // 2. Hardware ECDSA P-256 signature over challenge nonce
              final ownerUid = _resolveActiveUid(recharge.staffId);
              final signature = await sec.signChallenge(
                shopId: recharge.shopId,
                ownerUid: ownerUid,
                nonce: challenge.nonce,
              );

              // 3. Process atomic wallet debit via Edge Function
              resData = await RechargeBackendBridge.supabaseClient!.processDebit(
                shopId: recharge.shopId,
                walletId: wallet.walletId,
                rechargeId: recharge.rechargeId,
                idempotencyKey: recharge.rechargeId,
                operator: recharge.operator.name,
                amountPaise: amountPaise,
                amount: recharge.amount,
                fundingType: recharge.fundingType.name,
                businessDate: recharge.dateString,
                deviceId: devId,
                deviceSignature: signature,
                nonce: challenge.nonce,
                rechargeData: debitedRecharge.toMap(forFirestore: true),
              );
            } else if (Firebase.apps.isNotEmpty) {
              throw StateError('[RechargeService] Supabase client is not configured for Recharge Accounting.');
            } else {
              // Isolated unit testing in-memory simulation (no remote backend configured)
              resData = {
                'success': true,
                'balanceAfterPaise': newBalancePaise,
              };
            }
          } else {
            // Firebase Cloud Function Fallback
            final callable = DefaultFirebaseOptions.functionsInstance.httpsCallable('processRechargeDebit');
            final response = await callable.call<Map<String, dynamic>>({
              'shopId': recharge.shopId,
              'walletId': wallet.walletId,
              'rechargeId': recharge.rechargeId,
              'idempotencyKey': recharge.rechargeId,
              'operator': recharge.operator.name,
              'amountPaise': amountPaise,
              'amount': recharge.amount,
              'fundingType': recharge.fundingType.name,
              'businessDate': recharge.dateString,
              'rechargeData': debitedRecharge.toMap(forFirestore: true),
              'deviceId': devId,
            });
            resData = Map<String, dynamic>.from(response.data);
          }
          final serverNewBalance = (resData['balanceAfterPaise'] as num?)?.toInt() ??
              (resData['newBalancePaise'] as num?)?.toInt() ??
              newBalancePaise;

          updatedWallet = isOwnMoney
              ? wallet.copyWith(
                  ownPrepaidBalancePaise: serverNewBalance,
                  updatedAt: DateTime.now(),
                )
              : wallet.copyWith(
                  distributorCreditBalancePaise: serverNewBalance,
                  updatedAt: DateTime.now(),
                );

          ledgerEntry = ledgerEntry.copyWith(
            balanceBeforePaise: currentBalancePaise,
            balanceAfterPaise: serverNewBalance,
          );
          serverSuccess = true;
        } on FirebaseFunctionsException catch (fe) {
          final code = fe.code.toLowerCase();
          final msg = fe.message ?? '';
          if (code == 'failed-precondition' ||
              code == 'invalid-argument' ||
              code == 'permission-denied' ||
              code == 'unauthenticated' ||
              code == 'not-found' ||
              code == 'already-exists') {
            throw Exception('റീചാർജ് നിരസിച്ചു ($code: $msg)');
          }
          debugPrint('[RechargeService] Cloud Function network notice ($code): $msg');
          debitedRecharge = debitedRecharge.copyWith(
            status: RechargeStatus.pending,
            walletDebited: false,
            isOfflinePending: true,
          );
          await _queueOfflineOperation('RECHARGE_DEBIT', debitedRecharge.toMap(forFirestore: false));
        } catch (e) {
          final errStr = e.toString().toLowerCase();
          if (errStr.contains('insufficient') ||
              errStr.contains('ആവശ്യത്തിന് തുകയില്ല') ||
              errStr.contains('incomplete') ||
              errStr.contains('പൂർത്തിയായിട്ടില്ല') ||
              errStr.contains('permission') ||
              errStr.contains('അനുമതിയില്ല') ||
              errStr.contains('നിരസിച്ചു')) {
            rethrow;
          }
          debugPrint('[RechargeService] Cloud Function recharge debit notice: $e');
          debitedRecharge = debitedRecharge.copyWith(
            status: RechargeStatus.pending,
            walletDebited: false,
            isOfflinePending: true,
          );
          await _queueOfflineOperation('RECHARGE_DEBIT', debitedRecharge.toMap(forFirestore: false));
        }

        if (!serverSuccess) {
          // OFFLINE PENDING:
          // Local wallet balance must NOT be permanently decremented!
          // Ledger entry is deferred until server confirms transaction!
          _localRecharges[recharge.rechargeId] = debitedRecharge;
          await _persistRecord(debitedRecharge);

          final pendingEntry = ledgerEntry.copyWith(
            balanceBeforePaise: currentBalancePaise,
            balanceAfterPaise: currentBalancePaise,
            entryType: 'RECHARGE_DEBIT_PENDING',
          );

          return (
            recharge: debitedRecharge,
            wallet: wallet, // un-decremented local wallet
            entry: pendingEntry,
          );
        }
      }

      _localRecharges[recharge.rechargeId] = debitedRecharge;
      _localWallets[cacheKey] = updatedWallet;
      await _recordWalletLedgerEntry(ledgerEntry);

      await _persistRecord(debitedRecharge);

      return (
        recharge: debitedRecharge,
        wallet: updatedWallet,
        entry: ledgerEntry,
      );
    } finally {
      completer.complete();
      _inFlightOperations.remove(recharge.rechargeId);
    }
  }

  // ---------------------------------------------------------------------------
  // 5. DISTRIBUTOR SETTLEMENT (PARTIAL & FULL PAYOUT)
  // ---------------------------------------------------------------------------
  /// Record payment to distributor settling trade payable debt
  /// Accounting Impact:
  /// - Distributor Payable: -amount (Liability decreases)
  /// - Cash in Drawer or Bank: -amount (Asset decreases)
  /// - Expenses: ₹0 (Paying debt is NEVER an operational expense!)
  Future<
      ({
        DistributorProfile distributor,
        DistributorLedgerEntry entry,
        DistributorPaymentReceipt receipt,
        bool isFullSettlement
      })> recordDistributorPayment({
    required String shopId,
    required String distributorId,
    required double amount,
    required String paymentMode, // CASH, BANK, UPI
    required String staffId,
    required String staffName,
    String? referenceNumber,
    String notes = 'Distributor Payout Settlement',
    String? staffRole,
  }) async {
    if (staffRole != null && staffRole != 'owner' && staffRole != 'admin') {
      throw Exception(
          'അനധികൃത പ്രവർത്തനം: ഡിസ്ട്രിബ്യൂട്ടർ പേയ്‌മെന്റ് നടത്താൻ ഉടമയ്ക്ക് മാത്രമേ അനുവാദമുള്ളൂ (Unauthorized: Only Owner or Admin can execute distributor payment)');
    }

    if (amount <= 0) {
      throw ArgumentError('തുക പോസിറ്റീവ് ആയിരിക്കണം (Amount must be positive)');
    }

    final amountPaise = (amount * 100).round();
    final txnId = referenceNumber?.isNotEmpty == true
        ? referenceNumber!
        : 'PAY_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 6)}';

    if (_inFlightOperations.contains(txnId) ||
        _localDistributorLedger.any((e) =>
            e.referenceNumber == txnId || e.entryId == 'DL_$txnId')) {
      throw Exception('ഈ പേയ്‌മെന്റ് ഇതിനകം പ്രോസസ്സ് ചെയ്തു (Duplicate payment blocked: $txnId)');
    }
    _inFlightOperations.add(txnId);

    try {
      final currentDist = await getDistributor(
          shopId: shopId, distributorId: distributorId);

      final beforePaise = currentDist.currentOutstandingPaise;
      if (amountPaise > beforePaise && beforePaise > 0) {
        debugPrint(
            '[RechargeService] Notice: Payment ₹$amount exceeds current outstanding ₹${currentDist.currentOutstanding}');
      }

      final afterPaise = (beforePaise - amountPaise).clamp(0, 1 << 62);
      final isFullSettlement = afterPaise == 0;

      final updatedDist = currentDist.copyWith(
        totalPaymentsMadePaise:
            currentDist.totalPaymentsMadePaise + amountPaise,
        lastPaymentDate: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final ledgerEntry = DistributorLedgerEntry(
        entryId: 'DL_$txnId',
        shopId: shopId,
        distributorId: distributorId,
        distributorName: currentDist.name,
        entryType: 'PAYMENT_MADE',
        amount: amount,
        amountPaise: amountPaise,
        paymentMode: paymentMode.toUpperCase(),
        outstandingBeforePaise: beforePaise,
        outstandingAfterPaise: afterPaise,
        referenceNumber: txnId,
        description: 'Payment to ${currentDist.name} via $paymentMode: $notes',
        staffId: staffId,
        staffName: staffName,
        timestamp: DateTime.now(),
      );

      // Firestore Atomic Commit
      if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
        try {
          final firestore = FirebaseFirestore.instance;
          final distRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_distributors')
              .doc(distributorId);
          final dLogRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_distributor_ledger')
              .doc('DL_$txnId');

          final voucherRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('accounting_cash_bank')
              .doc('CB_DIST_PAY_$txnId');

          final normMode = paymentMode.toUpperCase() == 'CASH'
              ? 'Cash'
              : (paymentMode.toUpperCase() == 'UPI' ? 'UPI' : 'Bank');

          final voucherData = <String, dynamic>{
            'id': 'CB_DIST_PAY_$txnId',
            'type': 'DEBIT',
            'entryType': 'DEBIT',
            'transactionCategory': 'DISTRIBUTOR_PAYMENT',
            'category': 'DISTRIBUTOR_PAYMENT',
            'isRecharge': true,
            'isExpense': false, // Liability payout, NEVER business expense
            'isSalesRevenue': false,
            'distributorId': distributorId,
            'distributorName': currentDist.name,
            'amount': amount,
            'amountPaise': amountPaise,
            'paymentMode': paymentMode.toUpperCase(),
            'mode': normMode,
            'effectiveDate': Timestamp.fromDate(DateTime.now()),
            'createdByUid': staffId,
            'createdByName': staffName,
            'createdAt': FieldValue.serverTimestamp(),
            'notes': notes,
          };

          await firestore.runTransaction((transaction) async {
            final snap = await transaction.get(dLogRef);
            if (snap.exists) {
              throw Exception('Duplicate payment transaction: $txnId');
            }

            transaction.set(distRef, updatedDist.toMap(forFirestore: true),
                SetOptions(merge: true));
            transaction.set(dLogRef, ledgerEntry.toMap(forFirestore: true));
            transaction.set(voucherRef, voucherData, SetOptions(merge: true));
          });
        } catch (e) {
          debugPrint('[RechargeService] Firestore distributor payment notice: $e');
        }
      }

      // Money Out: Reduce actual Cash in Hand or Bank Balance
      try {
        final mode = paymentMode.toUpperCase() == 'CASH'
            ? 'Cash'
            : (paymentMode.toUpperCase() == 'UPI' ? 'UPI' : 'Bank');
        await Db.moveMoney(
            mode, -amount, 'Distributor Payment: ${currentDist.name} ($txnId)');
      } catch (_) {}

      _localDistributors['${shopId}_$distributorId'] = updatedDist;
      _localDistributorLedger.add(ledgerEntry);

      final receipt = DistributorPaymentReceipt(
        receiptNo: 'REC_PAY_$txnId',
        distributorId: distributorId,
        distributorName: currentDist.name,
        operatorName: currentDist.defaultOperator.displayName,
        paymentDate: DateTime.now(),
        amount: amount,
        amountPaise: amountPaise,
        paymentMode: paymentMode.toUpperCase(),
        previousOutstanding: beforePaise / 100.0,
        remainingOutstanding: afterPaise / 100.0,
        referenceNumber: txnId,
        staffName: staffName,
        notes: notes,
      );

      return (
        distributor: updatedDist,
        entry: ledgerEntry,
        receipt: receipt,
        isFullSettlement: isFullSettlement,
      );
    } finally {
      _inFlightOperations.remove(txnId);
    }
  }

  // ---------------------------------------------------------------------------
  // 6. DISTRIBUTOR PROFILE CRUD & MANAGEMENT
  // ---------------------------------------------------------------------------
  Future<DistributorProfile> getDistributor({
    required String shopId,
    required String distributorId,
  }) async {
    final cacheKey = '${shopId}_$distributorId';
    if (_localDistributors.containsKey(cacheKey)) {
      return _localDistributors[cacheKey]!;
    }

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('recharge_distributors')
            .doc(distributorId)
            .get();

        if (doc.exists && doc.data() != null) {
          final p = DistributorProfile.fromFirestore(doc);
          _localDistributors[cacheKey] = p;
          return p;
        }
      } catch (e) {
        debugPrint('[RechargeService] Distributor fetch notice: $e');
      }
    }

    // Preset lookup
    final preset = DistributorItem.defaultPresets.firstWhere(
      (d) => d.id == distributorId,
      orElse: () => DistributorItem(
        id: distributorId,
        name: 'Distributor $distributorId',
      ),
    );

    final defaultProfile = DistributorProfile(
      id: distributorId,
      shopId: shopId,
      name: preset.name,
      defaultOperator: RechargeOperator.fromString(preset.defaultOperator),
      updatedAt: DateTime.now(),
    );

    _localDistributors[cacheKey] = defaultProfile;
    return defaultProfile;
  }

  Future<DistributorProfile> saveDistributor({
    required String shopId,
    required DistributorProfile distributor,
  }) async {
    _localDistributors['${shopId}_${distributor.id}'] = distributor;

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('recharge_distributors')
            .doc(distributor.id)
            .set(distributor.toMap(forFirestore: true), SetOptions(merge: true));
      } catch (e) {
        debugPrint('[RechargeService] Save distributor error: $e');
      }
    }

    return distributor;
  }

  Future<List<DistributorProfile>> getAllDistributors(String shopId) async {
    final Map<String, DistributorProfile> map = {};

    // 1. Load presets
    for (final item in DistributorItem.defaultPresets) {
      map[item.id] = DistributorProfile(
        id: item.id,
        shopId: shopId,
        name: item.name,
        defaultOperator: RechargeOperator.fromString(item.defaultOperator),
        updatedAt: DateTime.now(),
      );
    }

    // 2. Load from local cache
    for (final k in _localDistributors.keys) {
      if (k.startsWith('${shopId}_')) {
        final d = _localDistributors[k]!;
        map[d.id] = d;
      }
    }

    // 3. Load from remote Firestore
    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('recharge_distributors')
            .get();

        for (final doc in snap.docs) {
          final d = DistributorProfile.fromFirestore(doc);
          map[d.id] = d;
          _localDistributors['${shopId}_${d.id}'] = d;
        }
      } catch (e) {
        debugPrint('[RechargeService] Remote distributors fetch notice: $e');
      }
    }

    return map.values.toList();
  }

  // ---------------------------------------------------------------------------
  // 7. LEDGER QUERIES & AUDIT LOGS
  // ---------------------------------------------------------------------------
  List<WalletLedgerEntry> getLocalWalletLedger({String? walletId}) {
    if (walletId == null) return List.unmodifiable(_localWalletLedger);
    return _localWalletLedger.where((e) => e.walletId == walletId).toList();
  }

  List<DistributorLedgerEntry> getLocalDistributorLedger({String? distributorId}) {
    if (distributorId == null) return List.unmodifiable(_localDistributorLedger);
    return _localDistributorLedger
        .where((e) => e.distributorId == distributorId)
        .toList();
  }

  // ---------------------------------------------------------------------------
  // 8. PHASE 4: RECHARGE COLLECTION ACCOUNTING
  // ---------------------------------------------------------------------------
  /// Check if a recharge has already been financially posted to Cash/Bank ledger
  bool isRechargeFinanciallyPosted(String rechargeId) =>
      _financiallyPostedRecharges.contains(rechargeId);

  /// Retrieve locally cached daily collection summary synchronously
  DailyRechargeCollectionSummary? getLocalDailyCollectionSummary(
      String shopId, String dateString) {
    return _localDailyCollections['${shopId}_$dateString'];
  }

  /// Get daily recharge collection summary (with cache and Firestore fallback)
  Future<DailyRechargeCollectionSummary> getDailyCollectionSummary({
    required String shopId,
    String? dateString,
  }) async {
    final targetDate = (dateString != null && dateString.isNotEmpty)
        ? dateString
        : DateFormat('yyyy-MM-dd').format(DateTime.now());
    final cacheKey = '${shopId}_$targetDate';

    if (_localDailyCollections.containsKey(cacheKey)) {
      return _localDailyCollections[cacheKey]!;
    }

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('daily_recharge_collections')
            .doc(targetDate)
            .get();

        if (doc.exists && doc.data() != null) {
          final summary = DailyRechargeCollectionSummary.fromMap(
              doc.data()!, targetDate, shopId);
          _localDailyCollections[cacheKey] = summary;
          return summary;
        }
      } catch (e) {
        debugPrint('[RechargeService] Remote daily collection fetch notice: $e');
      }
    }

    final emptySummary =
        DailyRechargeCollectionSummary.empty(targetDate, shopId);
    _localDailyCollections[cacheKey] = emptySummary;
    return emptySummary;
  }

  /// Get recharge record from cache or Firestore
  Future<RechargeEntry?> getRecharge({
    required String shopId,
    required String rechargeId,
  }) async {
    if (_localRecharges.containsKey(rechargeId)) {
      return _localRecharges[rechargeId];
    }
    return _fetchRechargeFromFirestore(shopId, rechargeId);
  }

  Future<RechargeEntry?> _fetchRechargeFromFirestore(
      String shopId, String rechargeId) async {
    if (Firebase.apps.isEmpty || shopId.isEmpty) return null;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('shops')
          .doc(shopId)
          .collection('recharge_transactions')
          .doc(rechargeId)
          .get();
      if (doc.exists && doc.data() != null) {
        final rec = RechargeEntry.fromFirestore(doc);
        _localRecharges[rechargeId] = rec;
        return rec;
      }
    } catch (e) {
      debugPrint('[RechargeService] Remote recharge fetch notice: $e');
    }
    return null;
  }

  /// Record Customer Payment Collection for a recharge transaction.
  /// ACCOUNTING ISOLATION RULES:
  /// - Physical Cash / UPI Bank increases by recharge principal amount.
  /// - Retail Sales Revenue is strictly ₹0 (Non-Revenue Pass-Through / Principal vs. Agent).
  /// - Only `RechargeStatus.success` creates financial ledger postings.
  /// - `pending` and `failed` do NOT post financial movements.
  /// - Idempotent submission prevented using in-flight lock and financial posted set.
  Future<({
    RechargeEntry recharge,
    DailyRechargeCollectionSummary summary,
    bool financiallyPosted,
  })> recordCustomerRechargePayment({
    required RechargeEntry recharge,
  }) async {
    final rechargeId = recharge.rechargeId;
    final shopId = recharge.shopId;
    final dateStr = recharge.dateString.isNotEmpty
        ? recharge.dateString
        : DateFormat('yyyy-MM-dd').format(recharge.createdAt);

    if (_inFlightOperations.contains(rechargeId)) {
      throw Exception(
          'ഈ റീചാർജ് പേയ്‌മെന്റ് ഇതിനകം പ്രോസസ്സ് ചെയ്യുന്നു (Duplicate submission in-flight blocked: $rechargeId)');
    }
    _inFlightOperations.add(rechargeId);

    try {
      if (_financiallyPostedRecharges.contains(rechargeId)) {
        throw Exception(
            'ഈ റീചാർജിന്റെ പണം ഇതിനകം വരവ് വെച്ചുകഴിഞ്ഞു (Recharge collection already posted: $rechargeId)');
      }

      final existingSummary = await getDailyCollectionSummary(
        shopId: shopId,
        dateString: dateStr,
      );

      bool posted = false;
      DailyRechargeCollectionSummary updatedSummary;

      final shouldCollectMoney = recharge.status == RechargeStatus.success ||
          (recharge.status == RechargeStatus.pending && recharge.customerPaymentCollected);

      if (shouldCollectMoney) {
        final amount = recharge.amount;
        final amountPaise = recharge.amountPaise;

        final isCash = recharge.paymentMode == RechargePaymentMode.cash;
        final isUpi = recharge.paymentMode == RechargePaymentMode.upi;
        final isCard = recharge.paymentMode == RechargePaymentMode.card;

        final moveMode = isCash ? 'Cash' : (isUpi ? 'UPI' : 'Bank');
        try {
          await Db.moveMoney(
            moveMode,
            amount,
            'Recharge Collection: ${recharge.operator.displayName} ($rechargeId)',
          );
        } catch (e) {
          debugPrint('[RechargeService] Db.moveMoney notice: $e');
        }

        if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
          try {
            final firestore = FirebaseFirestore.instance;
            final ledgerRef = firestore
                .collection('shops')
                .doc(shopId)
                .collection('accounting_cash_bank')
                .doc('CB_REC_$rechargeId');

            final ledgerData = <String, dynamic>{
              'id': 'CB_REC_$rechargeId',
              'type': 'CREDIT',
              'entryType': 'CREDIT',
              'transactionCategory': 'RECHARGE_COLLECTION',
              'category': 'RECHARGE_COLLECTION',
              'isRecharge': true,
              'isSalesRevenue': false,
              'rechargeId': rechargeId,
              'referenceId': rechargeId,
              'operator': recharge.operator.displayName,
              'operatorKey': recharge.operator.name,
              'customerMobile': recharge.customerMobile,
              'amount': amount,
              'amountPaise': amountPaise,
              'paymentMode': recharge.paymentMode.name.toUpperCase(),
              'mode': isCash ? 'Cash' : (isUpi ? 'UPI' : 'Bank'),
              'fundingType': recharge.fundingType.name,
              'effectiveDate': Timestamp.fromDate(recharge.createdAt),
              'dateString': dateStr,
              'createdByUid': recharge.staffId,
              'createdByName': recharge.staffName,
              'createdAt': FieldValue.serverTimestamp(),
              'notes': recharge.notes,
            };

            await ledgerRef.set(ledgerData, SetOptions(merge: true));
          } catch (e) {
            debugPrint('[RechargeService] Firestore accounting voucher notice: $e');
          }
        }

        if (recharge.status == RechargeStatus.success) {
          final opMap = Map<RechargeOperator, int>.from(
              existingSummary.operatorCollectionsPaise);
          opMap[recharge.operator] =
              (opMap[recharge.operator] ?? 0) + amountPaise;

          updatedSummary = existingSummary.copyWith(
            totalCollectionPaise:
                existingSummary.totalCollectionPaise + amountPaise,
            cashCollectionPaise:
                existingSummary.cashCollectionPaise + (isCash ? amountPaise : 0),
            upiCollectionPaise:
                existingSummary.upiCollectionPaise + (isUpi ? amountPaise : 0),
            cardCollectionPaise:
                existingSummary.cardCollectionPaise + (isCard ? amountPaise : 0),
            operatorCollectionsPaise: opMap,
            successfulCount: existingSummary.successfulCount + 1,
          );
        } else {
          updatedSummary = existingSummary.copyWith(
            pendingCount: existingSummary.pendingCount + 1,
          );
        }

        _financiallyPostedRecharges.add(rechargeId);
        posted = true;
      } else if (recharge.status == RechargeStatus.pending) {
        updatedSummary = existingSummary.copyWith(
          pendingCount: existingSummary.pendingCount + 1,
        );
      } else if (recharge.status == RechargeStatus.failed) {
        updatedSummary = existingSummary.copyWith(
          failedCount: existingSummary.failedCount + 1,
        );
      } else {
        updatedSummary = existingSummary;
      }

      if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
        try {
          final firestore = FirebaseFirestore.instance;
          final summaryRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('daily_recharge_collections')
              .doc(dateStr);

          await summaryRef.set(updatedSummary.toMap(), SetOptions(merge: true));
        } catch (e) {
          debugPrint('[RechargeService] Firestore daily collection update notice: $e');
        }
      }

      final existingRecharge = _localRecharges[rechargeId];
      final isWalletDebited =
          (existingRecharge?.walletDebited ?? false) || recharge.walletDebited;
      final savedRecharge = (posted ||
              (existingRecharge?.customerPaymentCollected ?? false) ||
              recharge.customerPaymentCollected)
          ? recharge.copyWith(
              customerPaymentCollected: true,
              walletDebited: isWalletDebited,
            )
          : recharge.copyWith(
              walletDebited: isWalletDebited,
            );

      _localRecharges[rechargeId] = savedRecharge;
      _localDailyCollections['${shopId}_$dateStr'] = updatedSummary;
      await _persistRecord(savedRecharge);

      return (
        recharge: savedRecharge,
        summary: updatedSummary,
        financiallyPosted: posted,
      );
    } finally {
      _inFlightOperations.remove(rechargeId);
    }
  }

  /// Refund or reverse a recharge collection
  /// Reverses physical Cash / Bank if it was previously collected.
  /// Creates reversal voucher in `accounting_cash_bank`.
  /// Adjusts daily collection totals and counts.
  Future<({
    RechargeEntry recharge,
    DailyRechargeCollectionSummary summary,
    bool reversed,
  })> refundOrReverseRecharge({
    required String shopId,
    required String rechargeId,
    required String staffId,
    required String staffName,
    String reason = 'Customer Cancellation / Network Failure',
  }) async {
    if (_inFlightOperations.contains(rechargeId)) {
      throw Exception(
          'ഈ റീചാർജ് പ്രോസസ്സ് ചെയ്തുകൊണ്ടിരിക്കുകയാണ് (In-flight lock: $rechargeId)');
    }
    _inFlightOperations.add(rechargeId);

    try {
      final recharge = _localRecharges[rechargeId] ??
          await _fetchRechargeFromFirestore(shopId, rechargeId);
      if (recharge == null) {
        throw Exception(
            'റീചാർജ് കണ്ടെത്താൻ കഴിഞ്ഞില്ല (Recharge record not found: $rechargeId)');
      }

      if (recharge.status == RechargeStatus.refunded) {
        throw Exception(
            'ഈ റീചാർജ് ഇതിനകം റീഫണ്ട് ചെയ്തുകഴിഞ്ഞു (Recharge already refunded: $rechargeId)');
      }

      final wasSuccess = recharge.status == RechargeStatus.success;
      final dateStr = recharge.dateString.isNotEmpty
          ? recharge.dateString
          : DateFormat('yyyy-MM-dd').format(recharge.createdAt);

      final existingSummary = await getDailyCollectionSummary(
        shopId: shopId,
        dateString: dateStr,
      );

      DailyRechargeCollectionSummary updatedSummary = existingSummary;

      if (wasSuccess) {
        final isCash = recharge.paymentMode == RechargePaymentMode.cash;
        final isUpi = recharge.paymentMode == RechargePaymentMode.upi;
        final moveMode = isCash ? 'Cash' : (isUpi ? 'UPI' : 'Bank');

        try {
          await Db.moveMoney(
            moveMode,
            -recharge.amount,
            'Recharge Reversal / Refund: ${recharge.operator.displayName} ($rechargeId)',
          );
        } catch (e) {
          debugPrint('[RechargeService] Db.moveMoney refund notice: $e');
        }

        if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
          try {
            final firestore = FirebaseFirestore.instance;
            final ledgerRef = firestore
                .collection('shops')
                .doc(shopId)
                .collection('accounting_cash_bank')
                .doc('CB_REC_REFUND_$rechargeId');

            final ledgerData = <String, dynamic>{
              'id': 'CB_REC_REFUND_$rechargeId',
              'type': 'DEBIT',
              'entryType': 'DEBIT',
              'transactionCategory': 'RECHARGE_REFUND',
              'category': 'RECHARGE_REFUND',
              'isRecharge': true,
              'isSalesRevenue': false,
              'rechargeId': rechargeId,
              'referenceId': rechargeId,
              'operator': recharge.operator.displayName,
              'operatorKey': recharge.operator.name,
              'amount': recharge.amount,
              'amountPaise': recharge.amountPaise,
              'paymentMode': recharge.paymentMode.name.toUpperCase(),
              'mode': moveMode,
              'effectiveDate': Timestamp.fromDate(DateTime.now()),
              'dateString': dateStr,
              'createdByUid': staffId,
              'createdByName': staffName,
              'createdAt': FieldValue.serverTimestamp(),
              'notes': 'Refund / Reversal: $reason',
            };

            await ledgerRef.set(ledgerData, SetOptions(merge: true));
          } catch (e) {
            debugPrint('[RechargeService] Firestore refund voucher notice: $e');
          }
        }

        final opMap = Map<RechargeOperator, int>.from(
            existingSummary.operatorCollectionsPaise);
        final currentOp = opMap[recharge.operator] ?? 0;
        opMap[recharge.operator] =
            (currentOp - recharge.amountPaise).clamp(0, 1 << 62);

        updatedSummary = existingSummary.copyWith(
          totalCollectionPaise:
              (existingSummary.totalCollectionPaise - recharge.amountPaise)
                  .clamp(0, 1 << 62),
          cashCollectionPaise: isCash
              ? (existingSummary.cashCollectionPaise - recharge.amountPaise)
                  .clamp(0, 1 << 62)
              : existingSummary.cashCollectionPaise,
          upiCollectionPaise: isUpi
              ? (existingSummary.upiCollectionPaise - recharge.amountPaise)
                  .clamp(0, 1 << 62)
              : existingSummary.upiCollectionPaise,
          cardCollectionPaise: !isCash && !isUpi
              ? (existingSummary.cardCollectionPaise - recharge.amountPaise)
                  .clamp(0, 1 << 62)
              : existingSummary.cardCollectionPaise,
          operatorCollectionsPaise: opMap,
          successfulCount:
              (existingSummary.successfulCount - 1).clamp(0, 1 << 30),
          refundedCount: existingSummary.refundedCount + 1,
        );

        _financiallyPostedRecharges.remove(rechargeId);
      } else {
        if (recharge.status == RechargeStatus.pending) {
          updatedSummary = existingSummary.copyWith(
            pendingCount:
                (existingSummary.pendingCount - 1).clamp(0, 1 << 30),
            refundedCount: existingSummary.refundedCount + 1,
          );
        } else {
          updatedSummary = existingSummary.copyWith(
            failedCount: (existingSummary.failedCount - 1).clamp(0, 1 << 30),
            refundedCount: existingSummary.refundedCount + 1,
          );
        }
      }

      final updatedRecharge = recharge.copyWith(
        status: RechargeStatus.refunded,
        updatedAt: DateTime.now(),
        notes: '${recharge.notes} [REFUNDED: $reason]'.trim(),
      );

      if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
        try {
          final firestore = FirebaseFirestore.instance;
          final recRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_transactions')
              .doc(rechargeId);
          final summaryRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('daily_recharge_collections')
              .doc(dateStr);

          final batch = firestore.batch();
          batch.set(recRef, updatedRecharge.toMap(forFirestore: true),
              SetOptions(merge: true));
          batch.set(summaryRef, updatedSummary.toMap(),
              SetOptions(merge: true));
          await batch.commit();
        } catch (e) {
          debugPrint('[RechargeService] Firestore refund commit notice: $e');
        }
      }

      _localRecharges[rechargeId] = updatedRecharge;
      _localDailyCollections['${shopId}_$dateStr'] = updatedSummary;
      await _persistRecord(updatedRecharge);

      return (
        recharge: updatedRecharge,
        summary: updatedSummary,
        reversed: wasSuccess,
      );
    } finally {
      _inFlightOperations.remove(rechargeId);
    }
  }

  // ---------------------------------------------------------------------------
  // 9. PHASE 5: RECHARGE FLOAT RECOVERY & BANK CASH DEPOSITS
  // ---------------------------------------------------------------------------
  /// Record Recharge Cash Deposit to Bank or UPI Settlement Transfer
  /// STRICT CONTRA ENTRY RULES:
  /// - Physical Cash: -amount (Drawer cash deposited)
  /// - Bank Balance: +amount (Store bank received cash)
  /// - Net business income: ₹0 (Internal transfer / Contra)
  /// - Net business expense: ₹0
  /// - Only confirmed deposits (`isConfirmed == true`) deduct physical cash!
  Future<({
    FloatDepositRecord record,
    RechargeFloatSummary summary,
  })> recordRechargeFloatDeposit({
    required String shopId,
    required FloatDepositType depositType,
    required double amount,
    required String bankAccountId,
    required String bankAccountName,
    required String staffId,
    required String staffName,
    String? dateString,
    String? referenceNumber,
    String notes = 'Recharge cash deposit to bank',
    bool isConfirmed = true,
    String? staffRole,
  }) async {
    if (staffRole != null && staffRole != 'owner' && staffRole != 'admin') {
      throw Exception(
          'അനധികൃത പ്രവർത്തനം: ബാങ്ക് ഡെപ്പോസിറ്റ് രേഖപ്പെടുത്താൻ ഉടമയ്ക്ക് മാത്രമേ അനുവാദമുള്ളൂ (Unauthorized: Only Owner or Admin can execute bank float deposits)');
    }

    if (amount <= 0) {
      throw ArgumentError(
          'ഡെപ്പോസിറ്റ് തുക പോസിറ്റീവ് ആയിരിക്കണം (Amount must be positive)');
    }

    final amountPaise = (amount * 100).round();
    final targetDate = (dateString != null && dateString.isNotEmpty)
        ? dateString
        : DateFormat('yyyy-MM-dd').format(DateTime.now());

    final txnId = referenceNumber?.isNotEmpty == true
        ? referenceNumber!
        : 'DEP_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 6)}';

    if (_inFlightOperations.contains(txnId) ||
        _localFloatDeposits.any((d) =>
            d.depositId == txnId ||
            (d.referenceNumber.isNotEmpty && d.referenceNumber == txnId))) {
      throw Exception(
          'ഈ ഡെപ്പോസിറ്റ് ഇതിനകം പ്രോസസ്സ് ചെയ്തു (Duplicate deposit blocked: $txnId)');
    }
    _inFlightOperations.add(txnId);

    try {
      // 1. If confirmed, execute physical cash to bank contra movement
      if (isConfirmed) {
        if (depositType == FloatDepositType.cashDeposit) {
          // Contra movement: Cash Drawer -> Bank Account
          try {
            await Db.moveMoney(
                'Cash', -amount, 'Recharge Float Cash Deposit to Bank ($txnId)');
            await Db.moveMoney(
                'Bank', amount, 'Recharge Float Cash Deposited from Drawer ($txnId)');
          } catch (e) {
            debugPrint('[RechargeService] Db.moveMoney contra error: $e');
          }
        }

        // Post contra voucher to Firestore accounting_cash_bank
        if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
          try {
            final firestore = FirebaseFirestore.instance;
            final contraRef = firestore
                .collection('shops')
                .doc(shopId)
                .collection('accounting_cash_bank')
                .doc('CB_CONTRA_$txnId');

            final contraData = <String, dynamic>{
              'id': 'CB_CONTRA_$txnId',
              'type': 'CONTRA',
              'entryType': 'CONTRA',
              'transactionCategory': 'FLOAT_RECOVERY_DEPOSIT',
              'category': 'FLOAT_RECOVERY',
              'isRecharge': true,
              'isExpense': false, // Internal transfer, NOT expense
              'isSalesRevenue': false, // NOT revenue
              'amount': amount,
              'amountPaise': amountPaise,
              'depositType': depositType.name,
              'bankAccountId': bankAccountId,
              'bankAccountName': bankAccountName,
              'effectiveDate': Timestamp.fromDate(DateTime.now()),
              'dateString': targetDate,
              'createdByUid': staffId,
              'createdByName': staffName,
              'createdAt': FieldValue.serverTimestamp(),
              'notes': notes,
            };

            await contraRef.set(contraData, SetOptions(merge: true));
          } catch (e) {
            debugPrint('[RechargeService] Firestore contra voucher notice: $e');
          }
        }
      }

      final record = FloatDepositRecord(
        depositId: txnId,
        shopId: shopId,
        depositType: depositType,
        amount: amount,
        amountPaise: amountPaise,
        bankAccountId: bankAccountId,
        bankAccountName: bankAccountName,
        dateString: targetDate,
        referenceNumber: txnId,
        notes: notes,
        staffId: staffId,
        staffName: staffName,
        isConfirmed: isConfirmed,
        createdAt: DateTime.now(),
      );

      // Firestore commit to recharge_float_deposits
      if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
        try {
          final firestore = FirebaseFirestore.instance;
          final depRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_float_deposits')
              .doc(txnId);

          await depRef.set(
              record.toMap(forFirestore: true), SetOptions(merge: true));
        } catch (e) {
          debugPrint('[RechargeService] Firestore float deposit notice: $e');
        }
      }

      _localFloatDeposits.add(record);

      final summary = await getRechargeFloatSummary(
        shopId: shopId,
        dateString: targetDate,
      );

      return (
        record: record,
        summary: summary,
      );
    } finally {
      _inFlightOperations.remove(txnId);
    }
  }

  /// Get comprehensive summary of distributor liabilities and float recovery
  Future<RechargeFloatSummary> getRechargeFloatSummary({
    required String shopId,
    String? dateString,
  }) async {
    final targetDate = (dateString != null && dateString.isNotEmpty)
        ? dateString
        : DateFormat('yyyy-MM-dd').format(DateTime.now());

    // 1. Today's Recharge Cash Collection
    final collectionSummary = await getDailyCollectionSummary(
      shopId: shopId,
      dateString: targetDate,
    );
    final rechargeCashAvailablePaise = collectionSummary.cashCollectionPaise;

    // 2. Sum confirmed cash deposits for today
    int rechargeCashDepositedPaise = 0;
    for (final dep in _localFloatDeposits) {
      if (dep.shopId == shopId &&
          dep.dateString == targetDate &&
          dep.depositType == FloatDepositType.cashDeposit &&
          dep.isConfirmed) {
        rechargeCashDepositedPaise += dep.amountPaise;
      }
    }

    final rechargeCashRemainingPaise =
        (rechargeCashAvailablePaise - rechargeCashDepositedPaise).clamp(0, 1 << 62);

    // 3. Distributor outstanding and paid today
    final distributors = await getAllDistributors(shopId);
    int totalDistributorOutstandingPaise = 0;
    for (final d in distributors) {
      totalDistributorOutstandingPaise += d.currentOutstandingPaise;
    }

    int paidTodayPaise = 0;
    for (final entry in _localDistributorLedger) {
      if (entry.shopId == shopId && entry.entryType == 'PAYMENT_MADE') {
        final entryDate = DateFormat('yyyy-MM-dd').format(entry.timestamp);
        if (entryDate == targetDate) {
          paidTodayPaise += entry.amountPaise;
        }
      }
    }

    return RechargeFloatSummary(
      dateString: targetDate,
      shopId: shopId,
      totalDistributorOutstandingPaise: totalDistributorOutstandingPaise,
      paidTodayPaise: paidTodayPaise,
      pendingPayablePaise: totalDistributorOutstandingPaise,
      rechargeCashAvailablePaise: rechargeCashAvailablePaise,
      rechargeCashDepositedPaise: rechargeCashDepositedPaise,
      rechargeCashRemainingPaise: rechargeCashRemainingPaise,
    );
  }

  List<FloatDepositRecord> getLocalFloatDeposits({String? dateString}) {
    if (dateString == null) return List.unmodifiable(_localFloatDeposits);
    return _localFloatDeposits
        .where((d) => d.dateString == dateString)
        .toList();
  }

  // ---------------------------------------------------------------------------
  // 10. PHASE 6: RECHARGE COMMISSION ACCOUNTING & MARGIN TRACKING
  // ---------------------------------------------------------------------------
  /// Record Prepaid Commission Top-Up (Load Margin)
  /// Example:
  /// - Bank Payment / Debit: ₹1,000 (Asset: Bank Balance decreases by ₹1,000)
  /// - Operator Wallet Credit: ₹1,030 (Asset: Wallet increases by ₹1,030)
  /// - Commission Earned: ₹30 (Income: Recharge Commission Income ₹30)
  /// RULES:
  /// - Physical Cash: ₹0 (Physical cash in hand is NEVER touched!)
  /// - Wallet balance already reflects the ₹1,030 credit; never add ₹30 again!
  /// - Income = ₹30 (Only actual earned margin is recognized as income)
  Future<({
    RechargeCommissionEntry commission,
    OperatorWallet wallet,
    WalletLedgerEntry ledgerEntry,
  })> recordPrepaidTopUpCommission({
    required String shopId,
    required RechargeOperator operator,
    required double bankDebitAmount,
    required double walletCreditAmount,
    required String staffId,
    required String staffName,
    String? distributorId,
    String? referenceNumber,
    String notes = 'Prepaid Load Margin Top-Up',
  }) async {
    if (bankDebitAmount <= 0) {
      throw ArgumentError(
          'ബാങ്ക് പേയ്‌മെന്റ് തുക പോസിറ്റീവ് ആയിരിക്കണം (Bank payment must be positive)');
    }
    if (walletCreditAmount < bankDebitAmount) {
      throw ArgumentError(
          'വാലറ്റ് ക്രെഡിറ്റ് തുക ബാങ്ക് പേയ്‌മെന്റിനേക്കാൾ കുറവായിരിക്കരുത് (Wallet credit must be >= bank debit)');
    }

    final commissionAmount = walletCreditAmount - bankDebitAmount;
    final commissionPaise = (commissionAmount * 100).round();
    final walletCreditPaise = (walletCreditAmount * 100).round();

    final txnId = referenceNumber?.isNotEmpty == true
        ? referenceNumber!
        : 'TOPUP_COMM_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 6)}';

    if (_inFlightOperations.contains(txnId) ||
        _localCommissions.containsKey(txnId) ||
        _localCommissions.values.any((c) => c.referenceNumber == txnId)) {
      throw Exception(
          'ഈ കമ്മീഷൻ ടോപ്പ്-അപ്പ് ഇതിനകം രേഖപ്പെടുത്തിക്കഴിഞ്ഞു (Duplicate top-up commission blocked: $txnId)');
    }
    _inFlightOperations.add(txnId);

    try {
      final currentWallet = await getWallet(shopId: shopId, operator: operator);
      final beforePaise = currentWallet.ownPrepaidBalancePaise;
      final afterPaise = beforePaise + walletCreditPaise;

      final updatedWallet = currentWallet.copyWith(
        ownPrepaidBalancePaise: afterPaise,
        updatedAt: DateTime.now(),
      );

      final walletEntry = WalletLedgerEntry(
        txnId: 'TXN_$txnId',
        shopId: shopId,
        walletId: currentWallet.walletId,
        operator: operator,
        fundingType: RechargeFundingType.ownMoney,
        entryType: 'PREPAID_TOPUP_WITH_COMMISSION',
        amount: walletCreditAmount,
        amountPaise: walletCreditPaise,
        balanceBeforePaise: beforePaise,
        balanceAfterPaise: afterPaise,
        referenceId: txnId,
        description:
            'Bank Paid: ₹$bankDebitAmount, Wallet Got: ₹$walletCreditAmount (Earned Margin: ₹$commissionAmount)',
        staffId: staffId,
        staffName: staffName,
        timestamp: DateTime.now(),
      );

      final commissionEntry = RechargeCommissionEntry(
        commissionId: 'COMM_$txnId',
        shopId: shopId,
        operator: operator,
        distributorId: distributorId,
        amount: commissionAmount,
        amountPaise: commissionPaise,
        commissionType: RechargeCommissionType.prepaid,
        status: CommissionStatus.confirmed,
        settlementMethod: CommissionSettlementMethod.walletCredit,
        receivedDate: DateTime.now(),
        dateString: DateFormat('yyyy-MM-dd').format(DateTime.now()),
        referenceNumber: txnId,
        notes: notes,
        staffId: staffId,
        staffName: staffName,
        createdAt: DateTime.now(),
      );

      // Firestore commit
      if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
        try {
          final firestore = FirebaseFirestore.instance;
          final wRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_wallets')
              .doc(currentWallet.walletId);
          final logRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_wallet_logs')
              .doc('TXN_$txnId');
          final commRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_commissions')
              .doc('COMM_$txnId');
          final voucherRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('accounting_cash_bank')
              .doc('CB_COMM_$txnId');

          final voucherData = <String, dynamic>{
            'id': 'CB_COMM_$txnId',
            'type': 'CREDIT',
            'entryType': 'CREDIT',
            'transactionCategory': 'RECHARGE_COMMISSION',
            'category': 'RECHARGE_COMMISSION',
            'isRecharge': true,
            'isCommissionIncome': true,
            'isSalesRevenue': false,
            'isExpense': false,
            'amount': commissionAmount,
            'amountPaise': commissionPaise,
            'commissionType': RechargeCommissionType.prepaid.name,
            'operator': operator.displayName,
            'operatorKey': operator.name,
            'effectiveDate': Timestamp.fromDate(DateTime.now()),
            'dateString': commissionEntry.dateString,
            'createdByUid': staffId,
            'createdByName': staffName,
            'createdAt': FieldValue.serverTimestamp(),
            'notes': notes,
          };

          final batch = firestore.batch();
          batch.set(wRef, updatedWallet.toMap(forFirestore: true),
              SetOptions(merge: true));
          batch.set(logRef, walletEntry.toMap(forFirestore: true));
          batch.set(commRef, commissionEntry.toMap(forFirestore: true));
          batch.set(voucherRef, voucherData, SetOptions(merge: true));
          await batch.commit();
        } catch (e) {
          debugPrint(
              '[RechargeService] Firestore prepaid commission notice: $e');
        }
      }

      // Bank Debit: Reduce actual bank balance by paid amount
      try {
        await Db.moveMoney('Bank', -bankDebitAmount,
            'Top-Up ${operator.displayName} (Paid: ₹$bankDebitAmount, Load: ₹$walletCreditAmount)');
      } catch (e) {
        debugPrint('[RechargeService] Db.moveMoney notice: $e');
      }

      _localWallets['${shopId}_${currentWallet.walletId}'] = updatedWallet;
      await _recordWalletLedgerEntry(walletEntry);
      _localCommissions[commissionEntry.commissionId] = commissionEntry;

      return (
        commission: commissionEntry,
        wallet: updatedWallet,
        ledgerEntry: walletEntry,
      );
    } finally {
      _inFlightOperations.remove(txnId);
    }
  }

  /// Record Postpaid Backend Commission (Per-Recharge Margin)
  /// Example:
  /// - Recharge Amount: ₹299 (Pass-through)
  /// - Commission Earned: ₹6
  /// - Confirmed income is recognized only when status is confirmed or received!
  Future<RechargeCommissionEntry> recordPostpaidCommission({
    required String shopId,
    required RechargeOperator operator,
    required double amount,
    required CommissionStatus status,
    required String staffId,
    required String staffName,
    String? distributorId,
    String? distributorName,
    String? rechargeId,
    String? referenceNumber,
    CommissionSettlementMethod settlementMethod =
        CommissionSettlementMethod.distributorDiscount,
    String? dateString,
    String notes = 'Postpaid Recharge Commission',
  }) async {
    if (amount <= 0) {
      throw ArgumentError(
          'കമ്മീഷൻ തുക പോസിറ്റീവ് ആയിരിക്കണം (Amount must be positive)');
    }

    final amountPaise = (amount * 100).round();
    final targetDate = (dateString != null && dateString.isNotEmpty)
        ? dateString
        : DateFormat('yyyy-MM-dd').format(DateTime.now());

    final txnId = referenceNumber?.isNotEmpty == true
        ? referenceNumber!
        : 'COMM_POST_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 6)}';

    if (_inFlightOperations.contains(txnId) ||
        _localCommissions.containsKey('COMM_$txnId') ||
        _localCommissions.values.any((c) =>
            c.referenceNumber == txnId ||
            c.commissionId == txnId ||
            c.commissionId == 'COMM_$txnId')) {
      throw Exception(
          'ഈ കമ്മീഷൻ ഇതിനകം രേഖപ്പെടുത്തിക്കഴിഞ്ഞു (Duplicate commission blocked: $txnId)');
    }
    _inFlightOperations.add(txnId);

    try {
      final isConfirmedIncome = status == CommissionStatus.confirmed ||
          status == CommissionStatus.received;

      // Commission Cash Payout: Physical cash only increases if explicitly paid out in cash!
      if (isConfirmedIncome &&
          settlementMethod == CommissionSettlementMethod.cashPayout) {
        try {
          await Db.moveMoney('Cash', amount,
              'Recharge Commission Cash Received: ${operator.displayName} ($txnId)');
        } catch (e) {
          debugPrint(
              '[RechargeService] Db.moveMoney commission cash notice: $e');
        }
      }

      final commission = RechargeCommissionEntry(
        commissionId: 'COMM_$txnId',
        shopId: shopId,
        operator: operator,
        distributorId: distributorId,
        distributorName: distributorName,
        rechargeId: rechargeId,
        amount: amount,
        amountPaise: amountPaise,
        commissionType: RechargeCommissionType.postpaid,
        status: status,
        settlementMethod: settlementMethod,
        receivedDate: DateTime.now(),
        dateString: targetDate,
        referenceNumber: txnId,
        notes: notes,
        staffId: staffId,
        staffName: staffName,
        createdAt: DateTime.now(),
      );

      // Firestore commit
      if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
        try {
          final firestore = FirebaseFirestore.instance;
          final commRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_commissions')
              .doc('COMM_$txnId');

          final batch = firestore.batch();
          batch.set(commRef, commission.toMap(forFirestore: true));

          if (isConfirmedIncome) {
            final voucherRef = firestore
                .collection('shops')
                .doc(shopId)
                .collection('accounting_cash_bank')
                .doc('CB_COMM_$txnId');

            final voucherData = <String, dynamic>{
              'id': 'CB_COMM_$txnId',
              'type': 'CREDIT',
              'entryType': 'CREDIT',
              'transactionCategory': 'RECHARGE_COMMISSION',
              'category': 'RECHARGE_COMMISSION',
              'isRecharge': true,
              'isCommissionIncome': true,
              'isSalesRevenue': false,
              'isExpense': false,
              'amount': amount,
              'amountPaise': amountPaise,
              'commissionType': RechargeCommissionType.postpaid.name,
              'operator': operator.displayName,
              'operatorKey': operator.name,
              'status': status.name,
              'settlementMethod': settlementMethod.name,
              'effectiveDate': Timestamp.fromDate(DateTime.now()),
              'dateString': targetDate,
              'createdByUid': staffId,
              'createdByName': staffName,
              'createdAt': FieldValue.serverTimestamp(),
              'notes': notes,
            };

            batch.set(voucherRef, voucherData, SetOptions(merge: true));
          }

          await batch.commit();
        } catch (e) {
          debugPrint(
              '[RechargeService] Firestore postpaid commission notice: $e');
        }
      }

      _localCommissions[commission.commissionId] = commission;
      return commission;
    } finally {
      _inFlightOperations.remove(txnId);
    }
  }

  /// Confirm a pending postpaid commission
  Future<RechargeCommissionEntry> confirmPendingCommission({
    required String shopId,
    required String commissionId,
    required String staffId,
    required String staffName,
    CommissionSettlementMethod? settlementMethod,
  }) async {
    final existing = _localCommissions[commissionId];
    if (existing == null) {
      throw Exception(
          'കമ്മീഷൻ എൻട്രി കണ്ടെത്താൻ കഴിഞ്ഞില്ല (Commission not found: $commissionId)');
    }
    if (existing.status != CommissionStatus.pending) {
      return existing; // Already confirmed or received
    }

    final method = settlementMethod ?? existing.settlementMethod;

    if (method == CommissionSettlementMethod.cashPayout) {
      try {
        await Db.moveMoney('Cash', existing.amount,
            'Recharge Commission Confirmed Cash: ${existing.operator.displayName}');
      } catch (e) {
        debugPrint('[RechargeService] Db.moveMoney notice: $e');
      }
    }

    final updated = existing.copyWith(
      status: CommissionStatus.confirmed,
      settlementMethod: method,
      notes: '${existing.notes} [CONFIRMED by $staffName]'.trim(),
    );

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final firestore = FirebaseFirestore.instance;
        final commRef = firestore
            .collection('shops')
            .doc(shopId)
            .collection('recharge_commissions')
            .doc(commissionId);

        final voucherRef = firestore
            .collection('shops')
            .doc(shopId)
            .collection('accounting_cash_bank')
            .doc('CB_$commissionId');

        final voucherData = <String, dynamic>{
          'id': 'CB_$commissionId',
          'type': 'CREDIT',
          'entryType': 'CREDIT',
          'transactionCategory': 'RECHARGE_COMMISSION',
          'category': 'RECHARGE_COMMISSION',
          'isRecharge': true,
          'isCommissionIncome': true,
          'isSalesRevenue': false,
          'isExpense': false,
          'amount': updated.amount,
          'amountPaise': updated.amountPaise,
          'commissionType': updated.commissionType.name,
          'operator': updated.operator.displayName,
          'operatorKey': updated.operator.name,
          'effectiveDate': Timestamp.fromDate(DateTime.now()),
          'dateString': updated.dateString,
          'createdByUid': staffId,
          'createdByName': staffName,
          'createdAt': FieldValue.serverTimestamp(),
          'notes': updated.notes,
        };

        final batch = firestore.batch();
        batch.set(commRef, updated.toMap(forFirestore: true),
            SetOptions(merge: true));
        batch.set(voucherRef, voucherData, SetOptions(merge: true));
        await batch.commit();
      } catch (e) {
        debugPrint('[RechargeService] Firestore confirm commission notice: $e');
      }
    }

    _localCommissions[commissionId] = updated;
    return updated;
  }

  /// Get Commission Dashboard Summary
  Future<CommissionDashboardSummary> getCommissionDashboardSummary({
    required String shopId,
    String? dateString,
  }) async {
    final targetDate = (dateString != null && dateString.isNotEmpty)
        ? dateString
        : DateFormat('yyyy-MM-dd').format(DateTime.now());
    final targetMonth = targetDate.substring(0, 7); // yyyy-MM

    int todayConfirmedPaise = 0;
    int monthlyConfirmedPaise = 0;
    int pendingCommissionPaise = 0;
    int confirmedCommissionPaise = 0;
    final Map<RechargeOperator, int> opMap = {
      for (final op in RechargeOperator.values) op: 0,
    };

    for (final c in _localCommissions.values) {
      if (c.shopId != shopId) continue;

      if (c.status == CommissionStatus.pending) {
        pendingCommissionPaise += c.amountPaise;
      } else {
        confirmedCommissionPaise += c.amountPaise;

        if (c.dateString == targetDate) {
          todayConfirmedPaise += c.amountPaise;
        }

        if (c.dateString.startsWith(targetMonth)) {
          monthlyConfirmedPaise += c.amountPaise;
          opMap[c.operator] = (opMap[c.operator] ?? 0) + c.amountPaise;
        }
      }
    }

    return CommissionDashboardSummary(
      dateString: targetDate,
      monthString: targetMonth,
      shopId: shopId,
      todayConfirmedPaise: todayConfirmedPaise,
      monthlyConfirmedPaise: monthlyConfirmedPaise,
      pendingCommissionPaise: pendingCommissionPaise,
      confirmedCommissionPaise: confirmedCommissionPaise,
      operatorConfirmedPaise: opMap,
    );
  }

  /// Get Filtered Commission Report Entries
  Future<List<RechargeCommissionEntry>> getCommissionReport({
    required String shopId,
    DateTime? startDate,
    DateTime? endDate,
    RechargeOperator? operator,
    String? distributorId,
    CommissionStatus? status,
    RechargeCommissionType? commissionType,
  }) async {
    return _localCommissions.values.where((c) {
      if (c.shopId != shopId) return false;
      if (operator != null && c.operator != operator) return false;
      if (distributorId != null && c.distributorId != distributorId) {
        return false;
      }
      if (status != null && c.status != status) return false;
      if (commissionType != null && c.commissionType != commissionType) {
        return false;
      }

      if (startDate != null && c.receivedDate.isBefore(startDate)) return false;
      if (endDate != null && c.receivedDate.isAfter(endDate)) return false;

      return true;
    }).toList()
      ..sort((a, b) => b.receivedDate.compareTo(a.receivedDate));
  }

  // ---------------------------------------------------------------------------
  // 12. PHASE 8: FAILED RECHARGE, CUSTOMER REFUND & TRANSACTION REVERSAL
  // ---------------------------------------------------------------------------

  /// Transitions a recharge from Pending -> Success and posts financial collection.
  /// Enforces idempotency and prevents invalid state transitions.
  Future<({
    RechargeEntry recharge,
    DailyRechargeCollectionSummary summary,
  })> updateRechargeStatusToSuccess({
    required String shopId,
    required String rechargeId,
    required String staffId,
    required String staffName,
    String notes = '',
  }) async {
    final existing = await getRecharge(shopId: shopId, rechargeId: rechargeId);
    if (existing == null) {
      throw Exception('റീചാർജ് ഇടപാട് കണ്ടെത്താനായില്ല (Recharge not found: $rechargeId)');
    }

    if (existing.status == RechargeStatus.success) {
      // Idempotent: already successful
      final summary = await getDailyCollectionSummary(
        shopId: shopId,
        dateString: existing.dateString,
      );
      return (recharge: existing, summary: summary);
    }

    if (existing.status == RechargeStatus.refunded) {
      // Special case: late operator success after customer was already refunded!
      final disputed = await resolveOperatorSuccessAfterRefund(
        shopId: shopId,
        rechargeId: rechargeId,
        staffId: staffId,
        staffName: staffName,
      );
      final summary = await getDailyCollectionSummary(
        shopId: shopId,
        dateString: existing.dateString,
      );
      return (recharge: disputed, summary: summary);
    }

    if (existing.status == RechargeStatus.failed) {
      throw StateError(
          'അസാധുവായ മാറ്റം: പരാജയപ്പെട്ട റീചാർജ് നേരിട്ട് വിജയകരമാക്കാൻ കഴിയില്ല (Invalid status transition: Cannot transition from Failed to Success directly)');
    }

    if (existing.status != RechargeStatus.pending) {
      throw StateError(
          'അസാധുവായ മാറ്റം: പെൻഡിംഗ് അല്ലാത്ത റീചാർജ് മാറ്റാൻ കഴിയില്ല (Invalid status transition)');
    }

    final successRecharge = existing.copyWith(
      status: RechargeStatus.success,
      updatedAt: DateTime.now(),
      notes: notes.isNotEmpty ? notes : existing.notes,
    );

    // If money was already collected while pending, update daily summary counts without double-moving money
    if (_financiallyPostedRecharges.contains(rechargeId)) {
      final summary = await getDailyCollectionSummary(
        shopId: shopId,
        dateString: existing.dateString,
      );
      final opMap = Map<RechargeOperator, int>.from(summary.operatorCollectionsPaise);
      opMap[existing.operator] = (opMap[existing.operator] ?? 0) + existing.amountPaise;

      final updatedSummary = summary.copyWith(
        successfulCount: summary.successfulCount + 1,
        pendingCount: (summary.pendingCount > 0) ? summary.pendingCount - 1 : 0,
        totalCollectionPaise: summary.totalCollectionPaise + existing.amountPaise,
        cashCollectionPaise: summary.cashCollectionPaise +
            (existing.paymentMode == RechargePaymentMode.cash ? existing.amountPaise : 0),
        upiCollectionPaise: summary.upiCollectionPaise +
            (existing.paymentMode == RechargePaymentMode.upi ? existing.amountPaise : 0),
        cardCollectionPaise: summary.cardCollectionPaise +
            (existing.paymentMode == RechargePaymentMode.card ? existing.amountPaise : 0),
        operatorCollectionsPaise: opMap,
      );
      _localDailyCollections['${shopId}_${existing.dateString}'] = updatedSummary;
      _localRecharges[rechargeId] = successRecharge;
      await _persistRecord(successRecharge);
      return (recharge: successRecharge, summary: updatedSummary);
    }

    // Financial collection posting via Phase 4 engine
    final result = await recordCustomerRechargePayment(recharge: successRecharge);
    return (recharge: result.recharge, summary: result.summary);
  }

  /// Marks a pending recharge as Failed.
  /// If the wallet was already debited, automatically reverses the wallet debit.
  Future<({
    RechargeEntry recharge,
    OperatorWallet? wallet,
    WalletLedgerEntry? walletEntry,
  })> markRechargeFailed({
    required String shopId,
    required String rechargeId,
    required String staffId,
    required String staffName,
    String reason = 'Recharge Failed by Operator',
    bool reverseWalletIfDebited = true,
  }) async {
    final existing = await getRecharge(shopId: shopId, rechargeId: rechargeId);
    if (existing == null) {
      throw Exception('റീചാർജ് ഇടപാട് കണ്ടെത്താനായില്ല (Recharge not found: $rechargeId)');
    }

    if (existing.status == RechargeStatus.failed) {
      return (recharge: existing, wallet: null, walletEntry: null);
    }

    if (existing.status == RechargeStatus.success) {
      throw StateError(
          'പൂർത്തിയായ റീചാർജ് നേരിട്ട് പരാജയമായി അടയാളപ്പെടുത്താൻ കഴിയില്ല (Cannot mark completed success recharge as failed directly. Use refund workflow.)');
    }

    OperatorWallet? updatedWallet;
    WalletLedgerEntry? walletEntry;

    // 1. Re-credit Wallet if wallet was actually debited
    if (existing.walletDebited && reverseWalletIfDebited) {
      final currentWallet = await getWallet(shopId: shopId, operator: existing.operator);
      final isOwnMoney = existing.fundingType == RechargeFundingType.ownMoney;
      final beforePaise = isOwnMoney
          ? currentWallet.ownPrepaidBalancePaise
          : currentWallet.distributorCreditBalancePaise;
      final afterPaise = beforePaise + existing.amountPaise;

      updatedWallet = isOwnMoney
          ? currentWallet.copyWith(
              ownPrepaidBalancePaise: afterPaise,
              updatedAt: DateTime.now(),
            )
          : currentWallet.copyWith(
              distributorCreditBalancePaise: afterPaise,
              updatedAt: DateTime.now(),
            );

      final wTxnId = 'REV_W_${existing.rechargeId}_${_uuid.v4().substring(0, 5)}';
      walletEntry = WalletLedgerEntry(
        txnId: wTxnId,
        shopId: shopId,
        walletId: currentWallet.walletId,
        operator: existing.operator,
        fundingType: existing.fundingType,
        entryType: 'WALLET_REVERSAL',
        amount: existing.amount,
        amountPaise: existing.amountPaise,
        balanceBeforePaise: beforePaise,
        balanceAfterPaise: afterPaise,
        referenceId: existing.rechargeId,
        description: 'Wallet Debit Reversal: ${existing.operator.displayName} ($reason)',
        staffId: staffId,
        staffName: staffName,
        timestamp: DateTime.now(),
      );

      final reversalEntry = ReversalLedgerEntry(
        reversalId: wTxnId,
        originalTxnId: existing.rechargeId,
        shopId: shopId,
        reversalType: ReversalType.walletReversal,
        amount: existing.amount,
        amountPaise: existing.amountPaise,
        affectedEntity: 'OperatorWallet',
        entityReferenceId: currentWallet.walletId,
        timestamp: DateTime.now(),
        dateString: existing.dateString,
        staffId: staffId,
        staffName: staffName,
        reason: reason,
        idempotencyKey: wTxnId,
        notes: 'Restored wallet balance for failed recharge',
      );

      // Firestore commit
      if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
        try {
          final firestore = FirebaseFirestore.instance;
          final batch = firestore.batch();
          final wRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_wallets')
              .doc(currentWallet.walletId);
          final logRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_wallet_logs')
              .doc(wTxnId);
          final revRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_reversals')
              .doc(wTxnId);

          batch.set(wRef, updatedWallet.toMap(forFirestore: true), SetOptions(merge: true));
          batch.set(logRef, walletEntry.toMap(forFirestore: true));
          batch.set(revRef, reversalEntry.toMap(forFirestore: true));
          await batch.commit();
        } catch (e) {
          debugPrint('[RechargeService] Firestore wallet reversal notice: $e');
        }
      }

      _localWallets['${shopId}_${currentWallet.walletId}'] = updatedWallet;
      await _recordWalletLedgerEntry(walletEntry);
      _localReversals.add(reversalEntry);
    }

    final failedRecharge = existing.copyWith(
      status: RechargeStatus.failed,
      notes: reason,
      updatedAt: DateTime.now(),
    );

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('recharge_transactions')
            .doc(rechargeId)
            .set(failedRecharge.toMap(forFirestore: true), SetOptions(merge: true));
      } catch (e) {
        debugPrint('[RechargeService] Firestore mark failed notice: $e');
      }
    }

    _localRecharges[rechargeId] = failedRecharge;
    await _persistRecord(failedRecharge);

    return (
      recharge: failedRecharge,
      wallet: updatedWallet,
      walletEntry: walletEntry,
    );
  }

  /// Customer Refund Workflow
  /// - Only refunds if customer payment was actually collected.
  /// - Refund amount cannot exceed customer collection amount.
  /// - Protects against duplicate refunds via idempotency keys.
  /// - Cash refunds reduce physical drawer cash.
  /// - UPI / Bank refunds reduce bank balance, drawer cash untouched.
  /// - Creates linked immutable audit voucher and reversal entry.
  Future<({
    RechargeEntry recharge,
    CustomerRefundRecord refundRecord,
    ReversalLedgerEntry reversalEntry,
  })> processCustomerRefund({
    required String shopId,
    required String rechargeId,
    required double refundAmount,
    required RechargePaymentMode refundMethod,
    required String staffId,
    required String staffName,
    required String reason,
    String? idempotencyKey,
  }) async {
    if (refundAmount <= 0) {
      throw ArgumentError('റീഫണ്ട് തുക പോസിറ്റീവ് ആയിരിക്കണം (Refund amount must be positive)');
    }

    final existing = await getRecharge(shopId: shopId, rechargeId: rechargeId);
    if (existing == null) {
      throw Exception('റീചാർജ് ഇടപാട് കണ്ടെത്താനായില്ല (Recharge not found: $rechargeId)');
    }

    // 1. Verify customer payment was collected
    final paymentWasCollected = existing.customerPaymentCollected ||
        _financiallyPostedRecharges.contains(rechargeId);
    if (!paymentWasCollected) {
      throw Exception(
          'ഈ റീചാർജിന് ഉപഭോക്താവിൽ നിന്ന് പണം ഈടാക്കിയിട്ടില്ല. റീഫണ്ട് നൽകാൻ കഴിയില്ല (Cannot refund: No customer payment was collected for this recharge)');
    }

    // 2. Verify refund amount does not exceed collected amount
    final refundPaise = (refundAmount * 100).round();
    if (refundPaise > existing.amountPaise) {
      throw ArgumentError(
          'റീഫണ്ട് തുക (₹$refundAmount) കളക്ഷൻ തുകയേക്കാൾ (₹${existing.amount}) കൂടുതലാകാൻ പാടില്ല (Refund amount cannot exceed collection amount)');
    }

    // 3. Idempotency & Duplicate prevention
    final refKey = idempotencyKey?.isNotEmpty == true
        ? idempotencyKey!
        : 'REFUND_$rechargeId';

    if (_inFlightOperations.contains(refKey)) {
      throw Exception('റീഫണ്ട് പ്രോസസ്സ് ചെയ്യുന്നു (Duplicate refund in-flight blocked: $refKey)');
    }

    if (_localRefunds.containsKey(refKey) ||
        _localRefunds.values.any((r) => r.idempotencyKey == refKey || r.rechargeId == rechargeId)) {
      throw Exception('ഈ റീചാർജിന് ഇതിനകം റീഫണ്ട് നൽകിക്കഴിഞ്ഞു (Duplicate refund blocked: $rechargeId)');
    }

    _inFlightOperations.add(refKey);

    try {
      final isCash = refundMethod == RechargePaymentMode.cash;
      final isUpi = refundMethod == RechargePaymentMode.upi;
      final moveMode = isCash ? 'Cash' : (isUpi ? 'UPI' : 'Bank');

      // 4. Double-entry Money movement: reduces drawer or bank
      try {
        await Db.moveMoney(
          moveMode,
          -refundAmount,
          'Recharge Customer Refund: ${existing.operator.displayName} ($rechargeId) - $reason',
        );
      } catch (e) {
        debugPrint('[RechargeService] Db.moveMoney refund notice: $e');
      }

      final dateStr = existing.dateString.isNotEmpty
          ? existing.dateString
          : DateFormat('yyyy-MM-dd').format(DateTime.now());
      final refundId = 'REF_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 5)}';
      final voucherId = 'CB_REFUND_$refKey';

      // 5. Create Customer Refund Record
      final refundRecord = CustomerRefundRecord(
        refundId: refundId,
        rechargeId: rechargeId,
        shopId: shopId,
        amount: refundAmount,
        amountPaise: refundPaise,
        refundMethod: refundMethod,
        refundDate: DateTime.now(),
        dateString: dateStr,
        staffId: staffId,
        staffName: staffName,
        reason: reason,
        idempotencyKey: refKey,
        voucherId: voucherId,
        createdAt: DateTime.now(),
      );

      // 6. Create Linked Reversal Ledger Entry
      final reversalEntry = ReversalLedgerEntry(
        reversalId: 'REV_$refundId',
        originalTxnId: rechargeId,
        shopId: shopId,
        reversalType: ReversalType.customerRefund,
        amount: refundAmount,
        amountPaise: refundPaise,
        affectedEntity: isCash ? 'PhysicalCashDrawer' : 'BankUPIBalance',
        entityReferenceId: voucherId,
        timestamp: DateTime.now(),
        dateString: dateStr,
        staffId: staffId,
        staffName: staffName,
        reason: reason,
        idempotencyKey: refKey,
        notes: 'Customer refund via ${refundMethod.label}',
      );

      // 7. Update Recharge Record status to refunded
      final updatedRecharge = existing.copyWith(
        status: RechargeStatus.refunded,
        refundId: refundId,
        refundAmount: refundAmount,
        refundMethod: refundMethod.name,
        updatedAt: DateTime.now(),
      );

      // 8. Firestore Commit
      if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
        try {
          final firestore = FirebaseFirestore.instance;
          final batch = firestore.batch();

          final recRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_transactions')
              .doc(rechargeId);
          final refRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_refunds')
              .doc(refundId);
          final revRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_reversals')
              .doc('REV_$refundId');
          final vRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('accounting_cash_bank')
              .doc(voucherId);

          final voucherData = <String, dynamic>{
            'id': voucherId,
            'type': 'DEBIT',
            'entryType': 'DEBIT',
            'transactionCategory': 'RECHARGE_REFUND',
            'category': 'RECHARGE_REFUND',
            'isRecharge': true,
            'isSalesRevenue': false,
            'isExpense': false,
            'rechargeId': rechargeId,
            'refundId': refundId,
            'referenceId': rechargeId,
            'operator': existing.operator.displayName,
            'amount': refundAmount,
            'amountPaise': refundPaise,
            'paymentMode': refundMethod.name.toUpperCase(),
            'mode': moveMode,
            'effectiveDate': Timestamp.fromDate(DateTime.now()),
            'dateString': dateStr,
            'createdByUid': staffId,
            'createdByName': staffName,
            'createdAt': FieldValue.serverTimestamp(),
            'notes': reason,
          };

          batch.set(recRef, updatedRecharge.toMap(forFirestore: true), SetOptions(merge: true));
          batch.set(refRef, refundRecord.toMap(forFirestore: true));
          batch.set(revRef, reversalEntry.toMap(forFirestore: true));
          batch.set(vRef, voucherData, SetOptions(merge: true));

          await batch.commit();
        } catch (e) {
          debugPrint('[RechargeService] Firestore refund transaction notice: $e');
        }
      }

      _localRefunds[refKey] = refundRecord;
      _localReversals.add(reversalEntry);
      _localRecharges[rechargeId] = updatedRecharge;
      await _persistRecord(updatedRecharge);

      return (
        recharge: updatedRecharge,
        refundRecord: refundRecord,
        reversalEntry: reversalEntry,
      );
    } finally {
      _inFlightOperations.remove(refKey);
    }
  }

  /// Special Case: Operator late success after customer was already refunded.
  /// Rule: NEVER auto-reverse the customer refund.
  /// Sets `requiresOwnerReview: true` and flags status as `RechargeStatus.disputed`.
  Future<RechargeEntry> resolveOperatorSuccessAfterRefund({
    required String shopId,
    required String rechargeId,
    required String staffId,
    required String staffName,
    String disputeNote =
        'Operator confirmed success after customer was already refunded. Manual owner review required.',
  }) async {
    final existing = await getRecharge(shopId: shopId, rechargeId: rechargeId);
    if (existing == null) {
      throw Exception('റീചാർജ് ഇടപാട് കണ്ടെത്താനായില്ല (Recharge not found: $rechargeId)');
    }

    final disputed = existing.copyWith(
      status: RechargeStatus.disputed,
      requiresOwnerReview: true,
      disputeNote: disputeNote,
      updatedAt: DateTime.now(),
    );

    final revId = 'DISPUTE_${existing.rechargeId}_${_uuid.v4().substring(0, 5)}';
    final reversalEntry = ReversalLedgerEntry(
      reversalId: revId,
      originalTxnId: rechargeId,
      shopId: shopId,
      reversalType: ReversalType.customerRefund,
      amount: existing.amount,
      amountPaise: existing.amountPaise,
      affectedEntity: 'DisputeReviewQueue',
      entityReferenceId: existing.refundId,
      timestamp: DateTime.now(),
      dateString: existing.dateString,
      staffId: staffId,
      staffName: staffName,
      reason: disputeNote,
      idempotencyKey: revId,
      notes: 'Customer already received refund. Flagged for Owner Review without auto-reversing cash/bank.',
    );

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final firestore = FirebaseFirestore.instance;
        final batch = firestore.batch();
        final recRef = firestore
            .collection('shops')
            .doc(shopId)
            .collection('recharge_transactions')
            .doc(rechargeId);
        final revRef = firestore
            .collection('shops')
            .doc(shopId)
            .collection('recharge_reversals')
            .doc(revId);

        batch.set(recRef, disputed.toMap(forFirestore: true), SetOptions(merge: true));
        batch.set(revRef, reversalEntry.toMap(forFirestore: true));
        await batch.commit();
      } catch (e) {
        debugPrint('[RechargeService] Firestore dispute review notice: $e');
      }
    }

    _localRecharges[rechargeId] = disputed;
    _localReversals.add(reversalEntry);
    await _persistRecord(disputed);

    return disputed;
  }

  /// Reverses a confirmed commission entry if a recharge transaction is reversed.
  Future<({
    RechargeCommissionEntry reversedCommission,
    ReversalLedgerEntry reversalEntry,
  })> reverseCommissionEntry({
    required String shopId,
    required String commissionId,
    required String staffId,
    required String staffName,
    required String reason,
    String? idempotencyKey,
  }) async {
    final commKey = commissionId.startsWith('COMM_') ? commissionId : 'COMM_$commissionId';
    final existing = _localCommissions[commKey];
    if (existing == null) {
      throw Exception('കമ്മീഷൻ ഇടപാട് കണ്ടെത്താനായില്ല (Commission entry not found: $commissionId)');
    }

    final isConfirmed = existing.status == CommissionStatus.confirmed ||
        existing.status == CommissionStatus.received;

    final key = idempotencyKey?.isNotEmpty == true ? idempotencyKey! : 'REV_$commKey';

    // Prevent duplicate commission reversal
    if (existing.notes.contains('[REVERSED:') ||
        _localReversals.any((r) =>
            r.originalTxnId == commissionId ||
            r.entityReferenceId == commissionId ||
            r.reversalId == key)) {
      throw Exception(
          'ഈ കമ്മീഷൻ ഇതിനകം തിരിച്ചെടുത്തിട്ടുണ്ട് (Commission already reversed: $commissionId)');
    }

    // Reverse cash if it was paid out in cash
    if (isConfirmed &&
        existing.settlementMethod == CommissionSettlementMethod.cashPayout) {
      try {
        await Db.moveMoney(
          'Cash',
          -existing.amount,
          'Recharge Commission Reversal: ${existing.operator.displayName} ($commissionId)',
        );
      } catch (e) {
        debugPrint('[RechargeService] Db.moveMoney commission reversal notice: $e');
      }
    }

    // Reverse wallet credit if the original commission increased the operator wallet
    if (isConfirmed &&
        existing.settlementMethod == CommissionSettlementMethod.walletCredit) {
      final wallet = await getWallet(shopId: shopId, operator: existing.operator);
      final beforePaise = wallet.ownPrepaidBalancePaise;
      final newPaise = (beforePaise >= existing.amountPaise)
          ? (beforePaise - existing.amountPaise)
          : 0;

      final updatedWallet = wallet.copyWith(
        ownPrepaidBalancePaise: newPaise,
        updatedAt: DateTime.now(),
      );

      final walletLogEntry = WalletLedgerEntry(
        txnId: 'LOG_REV_$key',
        shopId: shopId,
        walletId: wallet.walletId,
        operator: existing.operator,
        fundingType: RechargeFundingType.ownMoney,
        entryType: 'COMMISSION_WALLET_REVERSAL',
        amount: existing.amount,
        amountPaise: existing.amountPaise,
        balanceBeforePaise: beforePaise,
        balanceAfterPaise: newPaise,
        referenceId: existing.commissionId,
        description:
            'Reversal of prepaid commission wallet credit (${existing.commissionId})',
        staffId: staffId,
        staffName: staffName,
        timestamp: DateTime.now(),
      );

      final cacheKey = '${shopId}_${wallet.walletId}';
      _localWallets[cacheKey] = updatedWallet;
      await _recordWalletLedgerEntry(walletLogEntry);

      if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
        try {
          final firestore = FirebaseFirestore.instance;
          await firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_wallets')
              .doc(wallet.walletId)
              .set(updatedWallet.toMap(forFirestore: true), SetOptions(merge: true));

          await firestore
              .collection('shops')
              .doc(shopId)
              .collection('recharge_wallet_logs')
              .doc('LOG_REV_$key')
              .set(walletLogEntry.toMap(forFirestore: true));
        } catch (e) {
          debugPrint('[RechargeService] Firestore wallet commission reversal notice: $e');
        }
      }
    }

    final updatedComm = existing.copyWith(
      status: CommissionStatus.pending,
      notes: '${existing.notes} [REVERSED: $reason]',
    );

    final reversalEntry = ReversalLedgerEntry(
      reversalId: key,
      originalTxnId: commissionId,
      shopId: shopId,
      reversalType: ReversalType.commissionReversal,
      amount: existing.amount,
      amountPaise: existing.amountPaise,
      affectedEntity: 'CommissionIncome',
      entityReferenceId: commissionId,
      timestamp: DateTime.now(),
      dateString: existing.dateString,
      staffId: staffId,
      staffName: staffName,
      reason: reason,
      idempotencyKey: key,
      notes: isConfirmed
          ? 'Confirmed commission reversed from income'
          : 'Pending commission cancelled',
    );

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final firestore = FirebaseFirestore.instance;
        final batch = firestore.batch();
        final cRef = firestore
            .collection('shops')
            .doc(shopId)
            .collection('recharge_commissions')
            .doc(commKey);
        final revRef = firestore
            .collection('shops')
            .doc(shopId)
            .collection('recharge_reversals')
            .doc(key);

        batch.set(cRef, updatedComm.toMap(forFirestore: true), SetOptions(merge: true));
        batch.set(revRef, reversalEntry.toMap(forFirestore: true));

        if (isConfirmed) {
          final vRef = firestore
              .collection('shops')
              .doc(shopId)
              .collection('accounting_cash_bank')
              .doc('CB_$key');
          batch.set(
            vRef,
            {
              'id': 'CB_$key',
              'type': 'DEBIT',
              'entryType': 'DEBIT',
              'transactionCategory': 'COMMISSION_REVERSAL',
              'isExpense': false,
              'isRecharge': true,
              'amount': existing.amount,
              'amountPaise': existing.amountPaise,
              'effectiveDate': Timestamp.fromDate(DateTime.now()),
              'createdAt': FieldValue.serverTimestamp(),
              'notes': reason,
            },
            SetOptions(merge: true),
          );
        }

        await batch.commit();
      } catch (e) {
        debugPrint('[RechargeService] Firestore commission reversal notice: $e');
      }
    }

    _localCommissions[commKey] = updatedComm;
    _localReversals.add(reversalEntry);

    return (reversedCommission: updatedComm, reversalEntry: reversalEntry);
  }

  /// Reverses distributor credit/balance liability
  Future<({
    DistributorProfile distributor,
    DistributorLedgerEntry ledgerEntry,
    ReversalLedgerEntry reversalEntry,
  })> reverseDistributorCredit({
    required String shopId,
    required String distributorId,
    required double amount,
    required String staffId,
    required String staffName,
    required String reason,
    String? referenceId,
  }) async {
    if (amount <= 0) {
      throw ArgumentError('Amount must be positive');
    }

    final amountPaise = (amount * 100).round();
    final dist = await getDistributor(shopId: shopId, distributorId: distributorId);

    final beforePaise = dist.currentOutstandingPaise;
    final updatedDist = dist.copyWith(
      totalAdjustmentsPaise: dist.totalAdjustmentsPaise + amountPaise,
      updatedAt: DateTime.now(),
    );
    final afterPaise = updatedDist.currentOutstandingPaise;

    final txnId = referenceId?.isNotEmpty == true
        ? referenceId!
        : 'DIST_REV_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 5)}';

    final distEntry = DistributorLedgerEntry(
      entryId: 'DL_$txnId',
      shopId: shopId,
      distributorId: distributorId,
      distributorName: dist.name,
      entryType: 'CREDIT_REVERSAL',
      amount: amount,
      amountPaise: amountPaise,
      paymentMode: 'REVERSAL',
      outstandingBeforePaise: beforePaise,
      outstandingAfterPaise: afterPaise,
      referenceNumber: txnId,
      description: 'Distributor Payable Reversal ($reason)',
      staffId: staffId,
      staffName: staffName,
      timestamp: DateTime.now(),
    );

    final reversalEntry = ReversalLedgerEntry(
      reversalId: 'REV_$txnId',
      originalTxnId: txnId,
      shopId: shopId,
      reversalType: ReversalType.distributorReversal,
      amount: amount,
      amountPaise: amountPaise,
      affectedEntity: 'DistributorPayable',
      entityReferenceId: distributorId,
      timestamp: DateTime.now(),
      dateString: DateFormat('yyyy-MM-dd').format(DateTime.now()),
      staffId: staffId,
      staffName: staffName,
      reason: reason,
      idempotencyKey: txnId,
      notes: 'Reduced distributor payable due to credit reversal',
    );

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final firestore = FirebaseFirestore.instance;
        final batch = firestore.batch();
        final dRef = firestore
            .collection('shops')
            .doc(shopId)
            .collection('recharge_distributors')
            .doc(distributorId);
        final lRef = firestore
            .collection('shops')
            .doc(shopId)
            .collection('recharge_distributor_ledger')
            .doc('DL_$txnId');
        final revRef = firestore
            .collection('shops')
            .doc(shopId)
            .collection('recharge_reversals')
            .doc('REV_$txnId');

        batch.set(dRef, updatedDist.toMap(forFirestore: true), SetOptions(merge: true));
        batch.set(lRef, distEntry.toMap(forFirestore: true));
        batch.set(revRef, reversalEntry.toMap(forFirestore: true));
        await batch.commit();
      } catch (e) {
        debugPrint('[RechargeService] Firestore distributor reversal notice: $e');
      }
    }

    _localDistributors['${shopId}_$distributorId'] = updatedDist;
    _localDistributorLedger.add(distEntry);
    _localReversals.add(reversalEntry);

    return (
      distributor: updatedDist,
      ledgerEntry: distEntry,
      reversalEntry: reversalEntry,
    );
  }

  /// Full Orchestration: Handles complete failed recharge reversal workflow
  /// Reverses wallet (if debited) and processes customer refund (if collected).
  Future<({
    RechargeEntry recharge,
    OperatorWallet? wallet,
    CustomerRefundRecord? refundRecord,
    List<ReversalLedgerEntry> reversals,
  })> processRechargeFailureAndReversal({
    required String shopId,
    required String rechargeId,
    required String staffId,
    required String staffName,
    required String reason,
    bool refundCustomer = true,
    RechargePaymentMode? refundMethod,
  }) async {
    final existing = await getRecharge(shopId: shopId, rechargeId: rechargeId);
    if (existing == null) {
      throw Exception('റീചാർജ് ഇടപാട് കണ്ടെത്താനായില്ല (Recharge not found: $rechargeId)');
    }

    final List<ReversalLedgerEntry> reversals = [];

    // 1. Mark failed & reverse wallet if debited
    final failResult = await markRechargeFailed(
      shopId: shopId,
      rechargeId: rechargeId,
      staffId: staffId,
      staffName: staffName,
      reason: reason,
      reverseWalletIfDebited: true,
    );

    CustomerRefundRecord? refundRecord;
    RechargeEntry currentRecharge = failResult.recharge;

    // 2. Refund customer if payment was collected
    final paymentWasCollected = existing.customerPaymentCollected ||
        _financiallyPostedRecharges.contains(rechargeId);

    if (paymentWasCollected && refundCustomer) {
      final refundResult = await processCustomerRefund(
        shopId: shopId,
        rechargeId: rechargeId,
        refundAmount: existing.amount,
        refundMethod: refundMethod ?? existing.paymentMode,
        staffId: staffId,
        staffName: staffName,
        reason: reason,
      );
      currentRecharge = refundResult.recharge;
      refundRecord = refundResult.refundRecord;
      reversals.add(refundResult.reversalEntry);
    }

    return (
      recharge: currentRecharge,
      wallet: failResult.wallet,
      refundRecord: refundRecord,
      reversals: reversals,
    );
  }

  /// Dashboard Summary for Statuses, Refunds and Reversals
  Future<RechargeReversalSummary> getRechargeReversalSummary({
    required String shopId,
    String? dateString,
  }) async {
    final targetDate = (dateString != null && dateString.isNotEmpty)
        ? dateString
        : DateFormat('yyyy-MM-dd').format(DateTime.now());

    int succCount = 0;
    int succPaise = 0;
    int pendCount = 0;
    int pendPaise = 0;
    int failCount = 0;
    int failPaise = 0;
    int refCount = 0;
    int refPaise = 0;

    for (final r in _localRecharges.values) {
      if (r.shopId == shopId && r.dateString == targetDate) {
        switch (r.status) {
          case RechargeStatus.success:
            succCount++;
            succPaise += r.amountPaise;
            break;
          case RechargeStatus.pending:
            pendCount++;
            pendPaise += r.amountPaise;
            break;
          case RechargeStatus.failed:
            failCount++;
            failPaise += r.amountPaise;
            break;
          case RechargeStatus.refunded:
          case RechargeStatus.disputed:
            refCount++;
            refPaise += r.amountPaise;
            break;
        }
      }
    }

    int wRevCount = 0;
    int wRevPaise = 0;
    int cRevCount = 0;
    int cRevPaise = 0;

    for (final rev in _localReversals) {
      if (rev.shopId == shopId && rev.dateString == targetDate) {
        if (rev.reversalType == ReversalType.walletReversal) {
          wRevCount++;
          wRevPaise += rev.amountPaise;
        } else if (rev.reversalType == ReversalType.commissionReversal) {
          cRevCount++;
          cRevPaise += rev.amountPaise;
        }
      }
    }

    return RechargeReversalSummary(
      shopId: shopId,
      dateString: targetDate,
      successfulCount: succCount,
      successfulPaise: succPaise,
      pendingCount: pendCount,
      pendingPaise: pendPaise,
      failedCount: failCount,
      failedPaise: failPaise,
      refundedCount: refCount,
      refundedPaise: refPaise,
      walletReversalsCount: wRevCount,
      walletReversalsPaise: wRevPaise,
      commissionReversalsCount: cRevCount,
      commissionReversalsPaise: cRevPaise,
    );
  }

  /// Query local customer refund records
  List<CustomerRefundRecord> getLocalCustomerRefunds({String? rechargeId}) {
    if (rechargeId == null) return List.unmodifiable(_localRefunds.values.toList());
    return _localRefunds.values.where((r) => r.rechargeId == rechargeId).toList();
  }

  /// Query local reversal ledger entries
  List<ReversalLedgerEntry> getLocalReversals({
    String? rechargeId,
    ReversalType? type,
  }) {
    return _localReversals.where((r) {
      if (rechargeId != null && r.originalTxnId != rechargeId) return false;
      if (type != null && r.reversalType != type) return false;
      return true;
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // 13. PHASE 9: FINANCIAL REPORTS, RECONCILIATION & EXPORT ENGINE
  // ---------------------------------------------------------------------------

  /// Master Generator for Phase 9 Recharge Financial Audit & Reconciliation Report
  Future<RechargeFinancialReport> generateFinancialReport({
    required String shopId,
    required RechargeReportFilter filter,
  }) async {
    final start = filter.startDate;
    final end = filter.endDate;

    // 1. Filter Transactions within Date Range & Filters
    final txns = _localRecharges.values.where((r) {
      if (r.shopId != shopId) return false;
      if (r.createdAt.isBefore(start) || r.createdAt.isAfter(end)) return false;
      if (filter.operator != null && r.operator != filter.operator) return false;
      if (filter.distributorId != null && r.distributorId != filter.distributorId) return false;
      if (filter.paymentMode != null && r.paymentMode != filter.paymentMode) return false;
      return true;
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    int totalRechargePaise = 0;
    int succCount = 0;
    int pendCount = 0;
    int pendPaise = 0;
    int failCount = 0;
    int failPaise = 0;
    int refCount = 0;
    int refPaise = 0;

    int totalCustCollPaise = 0;
    int cashCollPaise = 0;
    int upiCollPaise = 0;
    int cardCollPaise = 0;

    final Map<RechargeOperator, ({
      int succCount,
      int succPaise,
      int failCount,
      int failPaise,
      int refCount,
      int refPaise,
      int cashPaise,
      int upiPaise,
      int cardPaise,
    })> opStats = {
      for (final op in RechargeOperator.values)
        op: (
          succCount: 0,
          succPaise: 0,
          failCount: 0,
          failPaise: 0,
          refCount: 0,
          refPaise: 0,
          cashPaise: 0,
          upiPaise: 0,
          cardPaise: 0,
        ),
    };

    for (final r in txns) {
      final prev = opStats[r.operator]!;
      if (r.status == RechargeStatus.success) {
        succCount++;
        totalRechargePaise += r.amountPaise;
        totalCustCollPaise += r.amountPaise;

        int c = prev.cashPaise;
        int u = prev.upiPaise;
        int crd = prev.cardPaise;

        if (r.paymentMode == RechargePaymentMode.cash) {
          cashCollPaise += r.amountPaise;
          c += r.amountPaise;
        } else if (r.paymentMode == RechargePaymentMode.upi) {
          upiCollPaise += r.amountPaise;
          u += r.amountPaise;
        } else if (r.paymentMode == RechargePaymentMode.card) {
          cardCollPaise += r.amountPaise;
          crd += r.amountPaise;
        }

        opStats[r.operator] = (
          succCount: prev.succCount + 1,
          succPaise: prev.succPaise + r.amountPaise,
          failCount: prev.failCount,
          failPaise: prev.failPaise,
          refCount: prev.refCount,
          refPaise: prev.refPaise,
          cashPaise: c,
          upiPaise: u,
          cardPaise: crd,
        );
      } else if (r.status == RechargeStatus.pending) {
        pendCount++;
        pendPaise += r.amountPaise;
      } else if (r.status == RechargeStatus.failed) {
        failCount++;
        failPaise += r.amountPaise;
        opStats[r.operator] = (
          succCount: prev.succCount,
          succPaise: prev.succPaise,
          failCount: prev.failCount + 1,
          failPaise: prev.failPaise + r.amountPaise,
          refCount: prev.refCount,
          refPaise: prev.refPaise,
          cashPaise: prev.cashPaise,
          upiPaise: prev.upiPaise,
          cardPaise: prev.cardPaise,
        );
      } else if (r.status == RechargeStatus.refunded || r.status == RechargeStatus.disputed) {
        refCount++;
        final rfAmt = r.refundAmount != null ? (r.refundAmount! * 100).round() : r.amountPaise;
        refPaise += rfAmt;

        // Gross customer collection did occur prior to the refund
        totalCustCollPaise += r.amountPaise;
        int c = prev.cashPaise;
        int u = prev.upiPaise;
        int crd = prev.cardPaise;
        if (r.paymentMode == RechargePaymentMode.cash) {
          cashCollPaise += r.amountPaise;
          c += r.amountPaise;
        } else if (r.paymentMode == RechargePaymentMode.upi) {
          upiCollPaise += r.amountPaise;
          u += r.amountPaise;
        } else if (r.paymentMode == RechargePaymentMode.card) {
          cardCollPaise += r.amountPaise;
          crd += r.amountPaise;
        }

        opStats[r.operator] = (
          succCount: prev.succCount,
          succPaise: prev.succPaise,
          failCount: prev.failCount,
          failPaise: prev.failPaise,
          refCount: prev.refCount + 1,
          refPaise: prev.refPaise + rfAmt,
          cashPaise: c,
          upiPaise: u,
          cardPaise: crd,
        );
      }
    }

    // 2. Commissions & Net Profit
    int confirmedCommEarnedPaise = 0;
    final Map<RechargeOperator, int> opCommEarned = {
      for (final op in RechargeOperator.values) op: 0,
    };

    for (final c in _localCommissions.values) {
      if (c.shopId == shopId &&
          !c.receivedDate.isBefore(start) &&
          !c.receivedDate.isAfter(end)) {
        bool wasConfirmedEarned = (c.status == CommissionStatus.confirmed || c.status == CommissionStatus.received);
        if (!wasConfirmedEarned) {
          // Check if this was a confirmed commission that was later reversed
          final hasReversal = _localReversals.any((rev) =>
              rev.shopId == shopId &&
              rev.reversalType == ReversalType.commissionReversal &&
              (rev.originalTxnId == c.commissionId ||
                  rev.originalTxnId == c.referenceNumber ||
                  c.commissionId.endsWith(rev.originalTxnId)));
          if (hasReversal) {
            wasConfirmedEarned = true;
          }
        }

        if (wasConfirmedEarned) {
          confirmedCommEarnedPaise += c.amountPaise;
          opCommEarned[c.operator] = (opCommEarned[c.operator] ?? 0) + c.amountPaise;
        }
      }
    }

    int confirmedCommReversedPaise = 0;
    for (final rev in _localReversals) {
      if (rev.shopId == shopId &&
          !rev.timestamp.isBefore(start) &&
          !rev.timestamp.isAfter(end) &&
          rev.reversalType == ReversalType.commissionReversal) {
        confirmedCommReversedPaise += rev.amountPaise;
      }
    }

    final netCommissionIncomePaise = confirmedCommEarnedPaise - confirmedCommReversedPaise;

    final Map<RechargeOperator, OperatorReportItem> operatorReports = {};
    for (final op in RechargeOperator.values) {
      final s = opStats[op]!;
      operatorReports[op] = OperatorReportItem(
        operator: op,
        successfulCount: s.succCount,
        successfulPaise: s.succPaise,
        failedCount: s.failCount,
        failedPaise: s.failPaise,
        refundedCount: s.refCount,
        refundedPaise: s.refPaise,
        cashCollectionPaise: s.cashPaise,
        upiCollectionPaise: s.upiPaise,
        cardCollectionPaise: s.cardPaise,
        actualCommissionEarnedPaise: opCommEarned[op] ?? 0,
      );
    }

    // 3. Customer Refunds Breakdown
    int custCashRefundsPaise = 0;
    int custUpiRefundsPaise = 0;
    int custCardRefundsPaise = 0;

    for (final ref in _localRefunds.values) {
      if (ref.shopId == shopId &&
          !ref.refundDate.isBefore(start) &&
          !ref.refundDate.isAfter(end)) {
        if (ref.refundMethod == RechargePaymentMode.cash) {
          custCashRefundsPaise += ref.amountPaise;
        } else if (ref.refundMethod == RechargePaymentMode.upi) {
          custUpiRefundsPaise += ref.amountPaise;
        } else {
          custCardRefundsPaise += ref.amountPaise;
        }
      }
    }

    // 4. Distributor Payments Breakdown & Outstandings
    int distCashPayPaise = 0;
    int distUpiPayPaise = 0;
    int distBankPayPaise = 0;

    final Map<String, ({
      int creditReceivedPaise,
      int paymentsMadePaise,
      int adjustmentsPaise,
      int cashPaise,
      int upiPaise,
      int bankPaise,
    })> distActivity = {};

    for (final dLog in _localDistributorLedger) {
      if (dLog.shopId == shopId &&
          !dLog.timestamp.isBefore(start) &&
          !dLog.timestamp.isAfter(end)) {
        final current = distActivity[dLog.distributorId] ?? (
          creditReceivedPaise: 0,
          paymentsMadePaise: 0,
          adjustmentsPaise: 0,
          cashPaise: 0,
          upiPaise: 0,
          bankPaise: 0,
        );

        if (dLog.entryType == 'CREDIT_LOAD' || dLog.entryType == 'CREDIT_RECEIVED') {
          distActivity[dLog.distributorId] = (
            creditReceivedPaise: current.creditReceivedPaise + dLog.amountPaise,
            paymentsMadePaise: current.paymentsMadePaise,
            adjustmentsPaise: current.adjustmentsPaise,
            cashPaise: current.cashPaise,
            upiPaise: current.upiPaise,
            bankPaise: current.bankPaise,
          );
        } else if (dLog.entryType == 'PAYMENT_MADE') {
          final isCash = dLog.paymentMode?.toUpperCase() == 'CASH';
          final isUpi = dLog.paymentMode?.toUpperCase() == 'UPI';
          final c = current.cashPaise + (isCash ? dLog.amountPaise : 0);
          final u = current.upiPaise + (isUpi ? dLog.amountPaise : 0);
          final b = current.bankPaise + (!isCash && !isUpi ? dLog.amountPaise : 0);

          if (isCash) {
            distCashPayPaise += dLog.amountPaise;
          } else if (isUpi) {
            distUpiPayPaise += dLog.amountPaise;
          } else {
            distBankPayPaise += dLog.amountPaise;
          }

          distActivity[dLog.distributorId] = (
            creditReceivedPaise: current.creditReceivedPaise,
            paymentsMadePaise: current.paymentsMadePaise + dLog.amountPaise,
            adjustmentsPaise: current.adjustmentsPaise,
            cashPaise: c,
            upiPaise: u,
            bankPaise: b,
          );
        } else if (dLog.entryType == 'CREDIT_REVERSAL') {
          distActivity[dLog.distributorId] = (
            creditReceivedPaise: current.creditReceivedPaise,
            paymentsMadePaise: current.paymentsMadePaise,
            adjustmentsPaise: current.adjustmentsPaise + dLog.amountPaise,
            cashPaise: current.cashPaise,
            upiPaise: current.upiPaise,
            bankPaise: current.bankPaise,
          );
        }
      }
    }

    final List<DistributorOutstandingReportItem> distReports = [];
    final knownDistributors = await getAllDistributors(shopId);
    for (final d in knownDistributors) {
      final act = distActivity[d.id];
      final creditRec = act?.creditReceivedPaise ?? 0;
      final payMade = act?.paymentsMadePaise ?? 0;
      final adj = act?.adjustmentsPaise ?? 0;
      final cashP = act?.cashPaise ?? 0;
      final upiP = act?.upiPaise ?? 0;
      final bankP = act?.bankPaise ?? 0;

      final closingOutstanding = d.currentOutstandingPaise;
      final openingPayable = closingOutstanding - creditRec + payMade + adj;

      distReports.add(DistributorOutstandingReportItem(
        distributorId: d.id,
        distributorName: d.name,
        defaultOperator: d.defaultOperator,
        openingPayablePaise: openingPayable,
        creditReceivedPaise: creditRec,
        paymentsMadePaise: payMade,
        adjustmentsPaise: adj,
        closingOutstandingPaise: closingOutstanding,
        cashPaymentsPaise: cashP,
        upiPaymentsPaise: upiP,
        bankPaymentsPaise: bankP,
      ));
    }

    // 5. Float Bank Deposits (Contra)
    int actualCashDepositedToBankPaise = 0;
    for (final dep in _localFloatDeposits) {
      if (dep.shopId == shopId &&
          !dep.createdAt.isBefore(start) &&
          !dep.createdAt.isAfter(end)) {
        actualCashDepositedToBankPaise += dep.amountPaise;
      }
    }

    // 6. Wallet Balance Reports per Operator
    final Map<RechargeOperator, WalletBalanceReportItem> walletReports = {};
    for (final op in RechargeOperator.values) {
      final currentWallet = await getWallet(shopId: shopId, operator: op);

      int ownTopUpPaise = 0;
      int distCreditPaise = 0;
      int rechargeDebitsPaise = 0;
      int reversalsPaise = 0;
      int commissionCreditsPaise = 0;

      for (final wLog in _localWalletLedger) {
        if (wLog.shopId == shopId &&
            wLog.operator == op &&
            !wLog.timestamp.isBefore(start) &&
            !wLog.timestamp.isAfter(end)) {
          if (wLog.entryType == 'TOPUP' || wLog.entryType == 'OWN_MONEY_TOPUP') {
            ownTopUpPaise += wLog.amountPaise;
          } else if (wLog.entryType == 'CREDIT_LOAD' || wLog.entryType == 'CREDIT_RECEIVED') {
            distCreditPaise += wLog.amountPaise;
          } else if (wLog.entryType == 'RECHARGE_DEBIT') {
            rechargeDebitsPaise += wLog.amountPaise;
          } else if (wLog.entryType == 'WALLET_REVERSAL') {
            reversalsPaise += wLog.amountPaise;
          } else if (wLog.entryType == 'COMMISSION_CREDIT') {
            commissionCreditsPaise += wLog.amountPaise;
          }
        }
      }

      final closingTotal = currentWallet.totalBalancePaise;
      final closingOwn = currentWallet.ownPrepaidBalancePaise;
      final closingCredit = currentWallet.distributorCreditBalancePaise;

      final netChange = ownTopUpPaise + distCreditPaise - rechargeDebitsPaise + reversalsPaise + commissionCreditsPaise;
      final openingTotal = closingTotal - netChange;

      walletReports[op] = WalletBalanceReportItem(
        operator: op,
        openingBalancePaise: openingTotal,
        openingOwnPaise: closingOwn - (ownTopUpPaise - rechargeDebitsPaise + reversalsPaise),
        openingCreditPaise: closingCredit - distCreditPaise,
        ownTopUpPaise: ownTopUpPaise,
        distributorCreditPaise: distCreditPaise,
        rechargeDebitsPaise: rechargeDebitsPaise,
        reversalsPaise: reversalsPaise,
        commissionCreditsPaise: commissionCreditsPaise,
        closingBalancePaise: closingTotal,
        closingOwnPaise: closingOwn,
        closingCreditPaise: closingCredit,
      );
    }

    final recon = CashBankReconciliationReport(
      rechargeCashCollectedPaise: cashCollPaise,
      rechargeUpiCollectedPaise: upiCollPaise,
      rechargeCardCollectedPaise: cardCollPaise,
      customerCashRefundsPaise: custCashRefundsPaise,
      customerUpiRefundsPaise: custUpiRefundsPaise,
      customerCardRefundsPaise: custCardRefundsPaise,
      distributorCashPaymentsPaise: distCashPayPaise,
      distributorUpiPaymentsPaise: distUpiPayPaise,
      distributorBankPaymentsPaise: distBankPayPaise,
      actualCashDepositedToBankPaise: actualCashDepositedToBankPaise,
    );

    return RechargeFinancialReport(
      shopId: shopId,
      filter: filter,
      generatedAt: DateTime.now(),
      totalRechargePaise: totalRechargePaise,
      successfulCount: succCount,
      pendingCount: pendCount,
      pendingPaise: pendPaise,
      failedCount: failCount,
      failedPaise: failPaise,
      refundedCount: refCount,
      refundedPaise: refPaise,
      totalCustomerCollectionPaise: totalCustCollPaise,
      cashCollectionPaise: cashCollPaise,
      upiCollectionPaise: upiCollPaise,
      cardCollectionPaise: cardCollPaise,
      confirmedCommissionEarnedPaise: confirmedCommEarnedPaise,
      confirmedCommissionReversedPaise: confirmedCommReversedPaise,
      netCommissionIncomePaise: netCommissionIncomePaise,
      operatorReports: operatorReports,
      walletReports: walletReports,
      distributorReports: distReports,
      reconciliation: recon,
      transactions: txns,
    );
  }

  /// Exports financial report to RFC 4180 CSV format
  String generateReportCsv(RechargeFinancialReport report, {required String shopName}) {
    final buffer = StringBuffer();
    final fmt = DateFormat('yyyy-MM-dd HH:mm:ss');
    final curFmt = NumberFormat('0.00');

    buffer.writeln('TEKFIX ERP - RECHARGE & FINANCIAL RECONCILIATION REPORT');
    buffer.writeln('Shop:,"$shopName"');
    buffer.writeln('Date Range:,"${report.filter.dateRangeDisplay}"');
    buffer.writeln('Generated At:,"${fmt.format(report.generatedAt)}"');
    buffer.writeln('');

    buffer.writeln('--- FINANCIAL SUMMARY ---');
    buffer.writeln('Metric,Amount (INR),Count');
    buffer.writeln('Total Successful Recharges,${curFmt.format(report.totalRechargeAmount)},${report.successfulCount}');
    buffer.writeln('Pending Recharges,${curFmt.format(report.pendingAmount)},${report.pendingCount}');
    buffer.writeln('Failed Recharges,${curFmt.format(report.failedAmount)},${report.failedCount}');
    buffer.writeln('Customer Refunds,${curFmt.format(report.refundedAmount)},${report.refundedCount}');
    buffer.writeln('Total Customer Collections,${curFmt.format(report.totalCustomerCollection)},-');
    buffer.writeln('  Cash Collections,${curFmt.format(report.cashCollection)},-');
    buffer.writeln('  UPI Collections,${curFmt.format(report.upiCollection)},-');
    buffer.writeln('  Card Collections,${curFmt.format(report.cardCollection)},-');
    buffer.writeln('Confirmed Commission Earned,${curFmt.format(report.confirmedCommissionEarned)},-');
    buffer.writeln('Confirmed Commission Reversed,${curFmt.format(report.confirmedCommissionReversed)},-');
    buffer.writeln('Net Commission Income,${curFmt.format(report.netCommissionIncome)},-');
    buffer.writeln('');

    buffer.writeln('--- OPERATOR-WISE PERFORMANCE ---');
    buffer.writeln('Operator,Successful Amount,Txn Count,Cash,UPI,Card,Commission Earned,Refunds,Failed Amount');
    for (final op in RechargeOperator.values) {
      final s = report.operatorReports[op];
      if (s != null) {
        buffer.writeln('${op.displayName},${curFmt.format(s.successfulAmount)},${s.successfulCount},${curFmt.format(s.cashCollection)},${curFmt.format(s.upiCollection)},${curFmt.format(s.cardCollection)},${curFmt.format(s.actualCommissionEarned)},${curFmt.format(s.refundedAmount)},${curFmt.format(s.failedAmount)}');
      }
    }
    buffer.writeln('');

    buffer.writeln('--- WALLET BALANCES ---');
    buffer.writeln('Operator,Opening Balance,Own Top-Ups,Distributor Credit,Recharge Debits,Reversals,Closing Balance');
    for (final op in RechargeOperator.values) {
      final w = report.walletReports[op];
      if (w != null) {
        buffer.writeln('${op.displayName},${curFmt.format(w.openingBalance)},${curFmt.format(w.ownTopUp)},${curFmt.format(w.distributorCredit)},${curFmt.format(w.rechargeDebits)},${curFmt.format(w.reversals)},${curFmt.format(w.closingBalance)}');
      }
    }
    buffer.writeln('');

    buffer.writeln('--- DISTRIBUTOR OUTSTANDINGS ---');
    buffer.writeln('Distributor,Operator,Opening Payable,Credit Received,Payments Made,Adjustments,Closing Outstanding,Cash Paid,UPI Paid,Bank Paid');
    for (final d in report.distributorReports) {
      buffer.writeln('"${d.distributorName}",${d.defaultOperator.displayName},${curFmt.format(d.openingPayable)},${curFmt.format(d.creditReceived)},${curFmt.format(d.paymentsMade)},${curFmt.format(d.adjustments)},${curFmt.format(d.closingOutstanding)},${curFmt.format(d.cashPayments)},${curFmt.format(d.upiPayments)},${curFmt.format(d.bankPayments)}');
    }
    buffer.writeln('');

    buffer.writeln('--- CASH & BANK RECONCILIATION ---');
    buffer.writeln('Recharge Cash Collected,${curFmt.format(report.reconciliation.rechargeCashCollected)}');
    buffer.writeln('Recharge UPI Collected,${curFmt.format(report.reconciliation.rechargeUpiCollected)}');
    buffer.writeln('Recharge Card Collected,${curFmt.format(report.reconciliation.rechargeCardCollected)}');
    buffer.writeln('Customer Cash Refunds,${curFmt.format(report.reconciliation.customerCashRefunds)}');
    buffer.writeln('Distributor Cash Payments,${curFmt.format(report.reconciliation.distributorCashPayments)}');
    buffer.writeln('Distributor UPI Payments,${curFmt.format(report.reconciliation.distributorUpiPayments)}');
    buffer.writeln('Cash Float Deposited to Bank,${curFmt.format(report.reconciliation.actualCashDepositedToBank)}');
    buffer.writeln('Net Physical Cash Movement,${curFmt.format(report.reconciliation.netPhysicalCashFlow)}');
    buffer.writeln('');

    buffer.writeln('--- DETAILED TRANSACTIONS ---');
    buffer.writeln('ID,Date,Operator,Mobile,Amount,Funding Type,Payment Mode,Status,Staff,Notes');
    for (final t in report.transactions) {
      buffer.writeln('${t.rechargeId},${fmt.format(t.createdAt)},${t.operator.displayName},${t.customerMobile},${curFmt.format(t.amount)},${t.fundingType.name},${t.paymentMode.label},${t.status.name},"${t.staffName}","${t.notes}"');
    }

    return buffer.toString();
  }

  /// Exports financial report to Excel-compatible CSV with UTF-8 BOM
  String generateReportExcelCsv(RechargeFinancialReport report, {required String shopName}) {
    return '\uFEFF${generateReportCsv(report, shopName: shopName)}';
  }

  /// Generates printable accounting PDF audit document
  Future<Uint8List> generateReportPdf(
    RechargeFinancialReport report, {
    required String shopName,
    String shopAddress = '',
    String shopPhone = '',
  }) async {
    final pdf = pw.Document();
    final fmt = DateFormat('dd/MM/yyyy hh:mm a');
    final curFmt = NumberFormat('0.00');

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (pw.Context ctx) {
          return [
            // Header
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      shopName.toUpperCase(),
                      style: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16),
                    ),
                    if (shopAddress.isNotEmpty)
                      pw.Text(shopAddress, style: const pw.TextStyle(fontSize: 9)),
                    if (shopPhone.isNotEmpty)
                      pw.Text('Tel: $shopPhone', style: const pw.TextStyle(fontSize: 9)),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(
                      'RECHARGE FINANCIAL AUDIT REPORT',
                      style: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13, color: PdfColors.blue800),
                    ),
                    pw.Text('Period: ${report.filter.dateRangeDisplay}', style: const pw.TextStyle(fontSize: 9)),
                    pw.Text('Generated: ${fmt.format(report.generatedAt)}', style: const pw.TextStyle(fontSize: 8)),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 12),
            pw.Divider(thickness: 1.5, color: PdfColors.blue800),
            pw.SizedBox(height: 10),

            // Summary Table
            pw.Text('1. EXECUTIVE SUMMARY', style: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: const ['Metric', 'Amount (Rs.)', 'Count / Details'],
              data: [
                ['Total Successful Recharges', 'Rs. ${curFmt.format(report.totalRechargeAmount)}', '${report.successfulCount} transactions'],
                ['Pending Recharges', 'Rs. ${curFmt.format(report.pendingAmount)}', '${report.pendingCount} pending'],
                ['Failed Recharges', 'Rs. ${curFmt.format(report.failedAmount)}', '${report.failedCount} failed'],
                ['Customer Refunds', 'Rs. ${curFmt.format(report.refundedAmount)}', '${report.refundedCount} refunds'],
                ['Cash Collections', 'Rs. ${curFmt.format(report.cashCollection)}', 'Drawer Cash Inflow'],
                ['UPI Collections', 'Rs. ${curFmt.format(report.upiCollection)}', 'Bank UPI Inflow'],
                ['Card Collections', 'Rs. ${curFmt.format(report.cardCollection)}', 'Card Gateway Inflow'],
                ['Confirmed Commission Earned', 'Rs. ${curFmt.format(report.confirmedCommissionEarned)}', 'Recognized Gross Margin'],
                ['Confirmed Commission Reversed', '-Rs. ${curFmt.format(report.confirmedCommissionReversed)}', 'Commission Clawbacks'],
                ['NET COMMISSION INCOME', 'Rs. ${curFmt.format(report.netCommissionIncome)}', 'NET RETAIL PROFIT'],
              ],
              headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blue900),
              cellStyle: const pw.TextStyle(fontSize: 8.5),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 3.5),
            ),
            pw.SizedBox(height: 14),

            // Operator-wise Table
            pw.Text('2. OPERATOR-WISE PERFORMANCE', style: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: const ['Operator', 'Success Vol', 'Txns', 'Cash', 'UPI', 'Card', 'Commission', 'Refunds', 'Failed'],
              data: [
                for (final op in RechargeOperator.values)
                  if (report.operatorReports.containsKey(op))
                    [
                      op.displayName,
                      'Rs. ${curFmt.format(report.operatorReports[op]!.successfulAmount)}',
                      '${report.operatorReports[op]!.successfulCount}',
                      'Rs. ${curFmt.format(report.operatorReports[op]!.cashCollection)}',
                      'Rs. ${curFmt.format(report.operatorReports[op]!.upiCollection)}',
                      'Rs. ${curFmt.format(report.operatorReports[op]!.cardCollection)}',
                      'Rs. ${curFmt.format(report.operatorReports[op]!.actualCommissionEarned)}',
                      'Rs. ${curFmt.format(report.operatorReports[op]!.refundedAmount)}',
                      'Rs. ${curFmt.format(report.operatorReports[op]!.failedAmount)}',
                    ],
              ],
              headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.grey800),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            ),
            pw.SizedBox(height: 14),

            // Wallet Balances
            pw.Text('3. OPERATOR WALLET AUDIT & BALANCES', style: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: const ['Operator', 'Opening', 'Own Top-Up', 'Dist. Credit', 'Debits', 'Reversals', 'Closing'],
              data: [
                for (final op in RechargeOperator.values)
                  if (report.walletReports.containsKey(op))
                    [
                      op.displayName,
                      'Rs. ${curFmt.format(report.walletReports[op]!.openingBalance)}',
                      'Rs. ${curFmt.format(report.walletReports[op]!.ownTopUp)}',
                      'Rs. ${curFmt.format(report.walletReports[op]!.distributorCredit)}',
                      'Rs. ${curFmt.format(report.walletReports[op]!.rechargeDebits)}',
                      'Rs. ${curFmt.format(report.walletReports[op]!.reversals)}',
                      'Rs. ${curFmt.format(report.walletReports[op]!.closingBalance)}',
                    ],
              ],
              headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.indigo900),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            ),
            pw.SizedBox(height: 14),

            // Distributor Outstandings
            pw.Text('4. DISTRIBUTOR TRADE PAYABLE AUDIT', style: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: const ['Distributor', 'Operator', 'Opening', 'Credit Loaded', 'Paid', 'Adj', 'Closing Debt'],
              data: [
                for (final d in report.distributorReports)
                  [
                    d.distributorName,
                    d.defaultOperator.displayName,
                    'Rs. ${curFmt.format(d.openingPayable)}',
                    'Rs. ${curFmt.format(d.creditReceived)}',
                    'Rs. ${curFmt.format(d.paymentsMade)}',
                    'Rs. ${curFmt.format(d.adjustments)}',
                    'Rs. ${curFmt.format(d.closingOutstanding)}',
                  ],
              ],
              headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.orange900),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            ),
            pw.SizedBox(height: 14),

            // Cash & Bank Reconciliation
            pw.Text('5. CASH / UPI / BANK RECONCILIATION', style: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: const ['Reconciliation Parameter', 'Amount (Rs.)', 'Accounting Impact'],
              data: [
                ['Recharge Physical Cash Inflow', '+Rs. ${curFmt.format(report.reconciliation.rechargeCashCollected)}', 'Added to physical drawer'],
                ['Customer Cash Refunds Outflow', '-Rs. ${curFmt.format(report.reconciliation.customerCashRefunds)}', 'Deducted from drawer'],
                ['Distributor Cash Payments Outflow', '-Rs. ${curFmt.format(report.reconciliation.distributorCashPayments)}', 'Settled from drawer cash'],
                ['Contra Bank Cash Deposits (Float Recovery)', '-Rs. ${curFmt.format(report.reconciliation.actualCashDepositedToBank)}', 'Deposited to bank'],
                ['NET PHYSICAL CASH DRAWER FLOW', 'Rs. ${curFmt.format(report.reconciliation.netPhysicalCashFlow)}', 'Reconciled with Cash Ledger'],
                ['Recharge UPI Collections', 'Rs. ${curFmt.format(report.reconciliation.rechargeUpiCollected)}', 'Direct Bank Ledger Inflow'],
                ['Distributor UPI Payments', '-Rs. ${curFmt.format(report.reconciliation.distributorUpiPayments)}', 'Direct Bank Ledger Outflow'],
              ],
              headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.teal900),
              cellStyle: const pw.TextStyle(fontSize: 8.5),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }

  // ===========================================================================
  // PHASE 12: DAILY OPERATOR OPENING & CLOSING BALANCE RECONCILIATION
  // ===========================================================================

  /// Get or initialize the daily reconciliation document for a given shop & date
  Future<DailyReconciliationRecord> getOrCreateDailyReconciliation({
    required String shopId,
    required String businessDate,
  }) async {
    final cacheKey = '${shopId}_$businessDate';
    if (_localDailyReconciliations.containsKey(cacheKey)) {
      return _localDailyReconciliations[cacheKey]!;
    }

    // 1. Check local Hive box
    if (Hive.isBoxOpen(boxRechargeReconciliation)) {
      final raw = Hive.box(boxRechargeReconciliation).get(cacheKey);
      if (raw is Map) {
        final r = DailyReconciliationRecord.fromMap(Map<String, dynamic>.from(raw));
        _localDailyReconciliations[cacheKey] = r;
        return r;
      }
    }

    // 2. Check remote Firestore
    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('recharge_daily_reconciliation')
            .doc(businessDate)
            .get();
        if (doc.exists && doc.data() != null) {
          final r = DailyReconciliationRecord.fromMap(doc.data()!);
          _localDailyReconciliations[cacheKey] = r;
          if (Hive.isBoxOpen(boxRechargeReconciliation)) {
            await Hive.box(boxRechargeReconciliation).put(cacheKey, r.toMap(forFirestore: false));
          }
          return r;
        }
      } catch (e) {
        debugPrint('[RechargeService] Daily reconciliation remote fetch notice: $e');
      }
    }

    // 3. Initialize default blank record with 4 required operators
    final initialOps = <String, DailyOperatorBalanceEntry>{};
    for (final op in requiredDailyOperators) {
      initialOps[op.name] = DailyOperatorBalanceEntry(operator: op);
    }

    final newRecord = DailyReconciliationRecord(
      businessDate: businessDate,
      shopId: shopId,
      operators: initialOps,
      openingStatus: 'pending',
      closingStatus: 'pending',
      reconciliationStatus: 'pending',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    _localDailyReconciliations[cacheKey] = newRecord;
    return newRecord;
  }

  /// Record Morning Opening Balance for all 4 required operators
  /// NOTE: This is purely a reconciliation voucher and does NOT modify live wallet balances.
  Future<DailyReconciliationRecord> recordMorningOpeningBalance({
    required String shopId,
    required String businessDate,
    required Map<RechargeOperator, double> openingBalances,
    required String staffId,
    required String staffName,
  }) async {
    // 1. Validate all 4 required operators are provided
    final missing = <RechargeOperator>[];
    for (final reqOp in requiredDailyOperators) {
      if (!openingBalances.containsKey(reqOp)) {
        missing.add(reqOp);
      }
    }
    if (missing.isNotEmpty) {
      final missingNames = missing.map((o) => o.displayName).join(', ');
      throw Exception(
        'നാല് ഓപ്പറേറ്റർമാരുടെയും ഓപ്പണിംഗ് ബാലൻസ് നിർബന്ധമാണ് (All 4 operators required: Jio, Airtel, Vi, BSNL. Missing: $missingNames)',
      );
    }

    // 2. Validate non-negative balances
    for (final entry in openingBalances.entries) {
      if (entry.value < 0) {
        throw Exception(
          'ഓപ്പണിംഗ് ബാലൻസ് നെഗറ്റീവ് ആകാൻ പാടില്ല (Opening balance cannot be negative for ${entry.key.displayName}: ₹${entry.value})',
        );
      }
    }

    // 3. Check duplicate submission
    final existing = await getOrCreateDailyReconciliation(
      shopId: shopId,
      businessDate: businessDate,
    );

    if (existing.isOpeningComplete) {
      throw Exception(
        'ഇന്നത്തെ ഓപ്പണിംഗ് ബാലൻസ് ഇതിനകം രേഖപ്പെടുത്തിയിട്ടുണ്ട് (Duplicate opening balance entry blocked for date: $businessDate)',
      );
    }

    // 4. Update operator records with integer paise
    final now = DateTime.now();
    final updatedOps = Map<String, DailyOperatorBalanceEntry>.from(existing.operators);

    for (final reqOp in requiredDailyOperators) {
      final balanceRs = openingBalances[reqOp]!;
      final balancePaise = (balanceRs * 100).round();
      final prev = updatedOps[reqOp.name] ?? DailyOperatorBalanceEntry(operator: reqOp);

      updatedOps[reqOp.name] = prev.copyWith(
        openingBalancePaise: balancePaise,
        openingEnteredAt: now,
        openingEnteredBy: '$staffName ($staffId)'.trim(),
        isOpeningCompleted: true,
      );
    }

    final updatedRecord = existing.copyWith(
      operators: updatedOps,
      openingStatus: 'completed',
      updatedAt: now,
      createdBy: existing.createdBy.isEmpty ? '$staffName ($staffId)'.trim() : existing.createdBy,
      auditNotes: [
        ...existing.auditNotes,
        'Morning opening recorded at ${now.toIso8601String()} by $staffName ($staffId)',
      ],
    );

    // 5. Persist to cache, Hive, and Firestore (with concurrency & conflict check)
    final cacheKey = '${shopId}_$businessDate';
    _localDailyReconciliations[cacheKey] = updatedRecord;

    if (Hive.isBoxOpen(boxRechargeReconciliation)) {
      await Hive.box(boxRechargeReconciliation).put(cacheKey, updatedRecord.toMap(forFirestore: false));
    }

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final docRef = FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('recharge_daily_reconciliation')
            .doc(businessDate);

        await FirebaseFirestore.instance.runTransaction((transaction) async {
          final snap = await transaction.get(docRef);
          if (snap.exists) {
            final data = snap.data() ?? {};
            if (data['isImmutable'] == true) {
              throw Exception('റീകൺസിലിയേഷൻ റെക്കോർഡ് ലോക്ക് ചെയ്തതാണ് (Record is locked and immutable for $businessDate)');
            }
            if (data['openingStatus'] == 'completed') {
              throw Exception(
                'ഇന്നത്തെ ഓപ്പണിംഗ് ബാലൻസ് ഇതിനകം സെർവറിൽ രേഖപ്പെടുത്തിയിട്ടുണ്ട് (Server already has confirmed opening balance for $businessDate)',
              );
            }
          }
          transaction.set(docRef, updatedRecord.toMap(forFirestore: true), SetOptions(merge: true));
        });
      } catch (e) {
        debugPrint('[RechargeService] Firestore opening balance save notice: $e');
        if (e.toString().contains('Server already has confirmed opening balance')) {
          rethrow;
        }
      }
    }

    return updatedRecord;
  }

  /// Check whether morning opening balance is complete for all 4 required operators
  Future<bool> isOpeningComplete({
    required String shopId,
    required String businessDate,
  }) async {
    final record = await getOrCreateDailyReconciliation(
      shopId: shopId,
      businessDate: businessDate,
    );
    if (record.openingStatus == 'completed') return true;
    for (final op in requiredDailyOperators) {
      final entry = record.operators[op.name];
      if (entry == null || !entry.isOpeningCompleted) return false;
    }
    return true;
  }

  /// List operators whose opening balance has not yet been recorded
  Future<List<RechargeOperator>> getIncompleteOpeningOperators({
    required String shopId,
    required String businessDate,
  }) async {
    final record = await getOrCreateDailyReconciliation(
      shopId: shopId,
      businessDate: businessDate,
    );
    final incomplete = <RechargeOperator>[];
    for (final op in requiredDailyOperators) {
      final entry = record.operators[op.name];
      if (entry == null || !entry.isOpeningCompleted) {
        incomplete.add(op);
      }
    }
    return incomplete;
  }

  /// Automatically calculate expected closing balance and reconciliation difference
  /// Expected Closing = Opening + Topups + Credits - Debits + DebitReversals - CreditReversals
  Future<DailyReconciliationRecord> calculateAutomaticReconciliation({
    required String shopId,
    required String businessDate,
    Map<RechargeOperator, double>? actualClosingBalances,
    bool simulateUnverifiedLedger = false,
  }) async {
    final record = await getOrCreateDailyReconciliation(
      shopId: shopId,
      businessDate: businessDate,
    );

    // 1. Rehydrate persisted ledger from Hive
    await rehydrateWalletLedgerFromHive(shopId: shopId);

    // 2. Sync from authoritative Firestore wallet logs if online
    bool ledgerFetchFailed = false;
    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final logsSnap = await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('recharge_wallet_logs')
            .get();
        for (final doc in logsSnap.docs) {
          final logEntry = WalletLedgerEntry.fromFirestore(doc);
          await _recordWalletLedgerEntry(logEntry);
        }
      } catch (e) {
        debugPrint('[RechargeService] Firestore wallet logs sync notice: $e');
        ledgerFetchFailed = true;
      }
    }

    if (simulateUnverifiedLedger) {
      ledgerFetchFailed = true;
    }

    // 3. Match ledger entries strictly using centralized shop timezone (Asia/Kolkata)
    final dateLogs = _localWalletLedger.where((e) {
      if (e.shopId != shopId) return false;
      final logDate = getBusinessDate(utcTime: e.timestamp.toUtc());
      return logDate == businessDate;
    }).toList();

    // Check if ledger data could not be verified (Requirement 3: Fail-Closed)
    final isIncompleteLedger = ledgerFetchFailed || simulateUnverifiedLedger;

    final updatedOps = Map<String, DailyOperatorBalanceEntry>.from(record.operators);

    for (final op in requiredDailyOperators) {
      final opWalletId = getWalletId(op);
      final prev = updatedOps[op.name] ?? DailyOperatorBalanceEntry(operator: op);

      int topupsPaise = 0;
      int creditsPaise = 0;
      int debitsPaise = 0;
      int debitReversalsPaise = 0;
      int creditReversalsPaise = 0;

      for (final log in dateLogs) {
        if (log.walletId != opWalletId) continue;
        switch (log.entryType) {
          case 'TOPUP':
          case 'PREPAID_TOPUP_WITH_COMMISSION':
            topupsPaise += log.amountPaise;
            break;
          case 'CREDIT_LOAD':
          case 'COMMISSION_CREDIT':
            creditsPaise += log.amountPaise;
            break;
          case 'RECHARGE_DEBIT':
            debitsPaise += log.amountPaise;
            break;
          case 'REVERSAL_CREDIT':
          case 'WALLET_REVERSAL':
            debitReversalsPaise += log.amountPaise;
            break;
          case 'COMMISSION_WALLET_REVERSAL':
            creditReversalsPaise += log.amountPaise;
            break;
        }
      }

      // Expected Closing Balance formula:
      final expectedPaise = prev.openingBalancePaise +
          topupsPaise +
          creditsPaise -
          debitsPaise +
          debitReversalsPaise -
          creditReversalsPaise;

      int actualPaise = prev.actualClosingBalancePaise;
      if (actualClosingBalances != null && actualClosingBalances.containsKey(op)) {
        actualPaise = (actualClosingBalances[op]! * 100).round();
      }

      final diffPaise = actualPaise - expectedPaise;
      final isMismatch = (actualPaise != 0 || prev.isClosingCompleted) && (diffPaise != 0);

      updatedOps[op.name] = prev.copyWith(
        totalTopupsPaise: topupsPaise,
        totalCreditsPaise: creditsPaise,
        totalDebitsPaise: debitsPaise,
        totalDebitReversalsPaise: debitReversalsPaise,
        totalCreditReversalsPaise: creditReversalsPaise,
        expectedClosingBalancePaise: expectedPaise,
        actualClosingBalancePaise: actualPaise,
        differencePaise: diffPaise,
        isMismatch: isMismatch,
      );
    }

    final hasAnyMismatch = updatedOps.values.any((o) => o.isMismatch);
    final isClosed = updatedOps.values.every((o) => o.isClosingCompleted);

    String calculatedStatus = record.reconciliationStatus;
    if (isIncompleteLedger) {
      calculatedStatus = 'incomplete';
    } else if (isClosed) {
      calculatedStatus = hasAnyMismatch ? 'mismatch' : 'balanced';
    }

    final updatedRecord = record.copyWith(
      operators: updatedOps,
      closingStatus: isClosed ? 'completed' : record.closingStatus,
      reconciliationStatus: calculatedStatus,
      hasIncompleteLedger: isIncompleteLedger,
      updatedAt: DateTime.now(),
    );

    final cacheKey = '${shopId}_$businessDate';
    _localDailyReconciliations[cacheKey] = updatedRecord;

    return updatedRecord;
  }

  /// Record Night Closing Balance for all 4 required operators
  /// NOTE: This is purely a reconciliation voucher and does NOT modify live wallet balances or EOD cash.
  Future<DailyReconciliationRecord> recordNightClosingBalance({
    required String shopId,
    required String businessDate,
    required Map<RechargeOperator, double> actualClosingBalances,
    Map<RechargeOperator, String>? mismatchReasons,
    Map<RechargeOperator, String>? remarks,
    required String staffId,
    required String staffName,
  }) async {
    // 1. Validate all 4 required operators are provided
    final missing = <RechargeOperator>[];
    for (final reqOp in requiredDailyOperators) {
      if (!actualClosingBalances.containsKey(reqOp)) {
        missing.add(reqOp);
      }
    }
    if (missing.isNotEmpty) {
      final missingNames = missing.map((o) => o.displayName).join(', ');
      throw Exception(
        'നാല് ഓപ്പറേറ്റർമാരുടെയും ക്ലോസിംഗ് ബാലൻസ് നിർബന്ധമാണ് (All 4 operators required: Jio, Airtel, Vi, BSNL. Missing: $missingNames)',
      );
    }

    // 2. Validate non-negative balances
    for (final entry in actualClosingBalances.entries) {
      if (entry.value < 0) {
        throw Exception(
          'ക്ലോസിംഗ് ബാലൻസ് നെഗറ്റീവ് ആകാൻ പാടില്ല (Closing balance cannot be negative for ${entry.key.displayName}: ₹${entry.value})',
        );
      }
    }

    // 3. Check immutability if previously closed and locked
    final existing = await getOrCreateDailyReconciliation(
      shopId: shopId,
      businessDate: businessDate,
    );
    if (existing.isImmutable) {
      throw Exception(
        'ഈ ദിവസത്തെ റീകൺസിലിയേഷൻ റെക്കോർഡ് സ്ഥിരീകരിച്ചതാണ് (Previous-day reconciliation record is locked and immutable: $businessDate)',
      );
    }

    if (existing.isClosingComplete) {
      throw Exception(
        'ഇന്നത്തെ ക്ലോസിംഗ് ബാലൻസ് ഇതിനകം രേഖപ്പെടുത്തിയിട്ടുണ്ട് (Duplicate closing balance entry blocked for date: $businessDate)',
      );
    }

    // 4. Calculate automated reconciliation with actual balances
    final reconciled = await calculateAutomaticReconciliation(
      shopId: shopId,
      businessDate: businessDate,
      actualClosingBalances: actualClosingBalances,
    );

    final now = DateTime.now();
    final updatedOps = Map<String, DailyOperatorBalanceEntry>.from(reconciled.operators);

    for (final op in requiredDailyOperators) {
      final prev = updatedOps[op.name]!;
      final actualRs = actualClosingBalances[op]!;
      final actualPaise = (actualRs * 100).round();
      final diffPaise = actualPaise - prev.expectedClosingBalancePaise;
      final isMismatch = diffPaise != 0;

      final reason = mismatchReasons?[op] ?? prev.mismatchReason;
      final remark = remarks?[op] ?? prev.remarks;

      updatedOps[op.name] = prev.copyWith(
        actualClosingBalancePaise: actualPaise,
        closingEnteredAt: now,
        closingEnteredBy: '$staffName ($staffId)'.trim(),
        isClosingCompleted: true,
        differencePaise: diffPaise,
        isMismatch: isMismatch,
        mismatchReason: reason,
        remarks: remark,
      );
    }

    final hasAnyMismatch = updatedOps.values.any((o) => o.isMismatch);

    final finalRecord = reconciled.copyWith(
      operators: updatedOps,
      closingStatus: 'completed',
      reconciliationStatus: reconciled.hasIncompleteLedger
          ? 'incomplete'
          : (hasAnyMismatch ? 'mismatch' : 'balanced'),
      closedAt: now,
      closedBy: '$staffName ($staffId)'.trim(),
      updatedAt: now,
      auditNotes: [
        ...reconciled.auditNotes,
        'Night closing recorded at ${now.toIso8601String()} by $staffName ($staffId). Status: ${reconciled.hasIncompleteLedger ? "INCOMPLETE" : (hasAnyMismatch ? "MISMATCH" : "BALANCED")}',
      ],
    );

    // 5. Persist to cache, Hive, and Firestore (with concurrency & conflict check)
    final cacheKey = '${shopId}_$businessDate';
    _localDailyReconciliations[cacheKey] = finalRecord;

    if (Hive.isBoxOpen(boxRechargeReconciliation)) {
      await Hive.box(boxRechargeReconciliation).put(cacheKey, finalRecord.toMap(forFirestore: false));
    }

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final docRef = FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('recharge_daily_reconciliation')
            .doc(businessDate);

        await FirebaseFirestore.instance.runTransaction((transaction) async {
          final snap = await transaction.get(docRef);
          if (snap.exists) {
            final data = snap.data() ?? {};
            if (data['isImmutable'] == true) {
              throw Exception('റീകൺസിലിയേഷൻ റെക്കോർഡ് ലോക്ക് ചെയ്തതാണ് (Record is locked and immutable for $businessDate)');
            }
            if (data['closingStatus'] == 'completed') {
              throw Exception('സെർവറിൽ ഇതിനകം ക്ലോസിംഗ് പൂർത്തിയായിട്ടുണ്ട് (Server already has confirmed closing balance for $businessDate)');
            }
          }
          transaction.set(docRef, finalRecord.toMap(forFirestore: true), SetOptions(merge: true));
        });
      } catch (e) {
        debugPrint('[RechargeService] Firestore closing balance save notice: $e');
        if (e.toString().contains('Server already has confirmed closing balance')) {
          rethrow;
        }
      }
    }

    return finalRecord;
  }

  /// Review reconciliation mismatch by shop owner (with optional audit lock)
  Future<DailyReconciliationRecord> reviewReconciliationMismatch({
    required String shopId,
    required String businessDate,
    required String ownerId,
    required String ownerName,
    required String reviewNotes,
    bool markImmutable = false,
  }) async {
    // Phase 12.2: Verify authoritative owner role
    final isOwner = await isAuthorizedShopOwner(shopId: shopId, uid: ownerId);
    if (!isOwner) {
      throw Exception(
        'അനധികൃത പ്രവർത്തനം: കടയുടെ ഉടമയ്ക്ക് മാത്രമേ റീകൺസിലിയേഷൻ അംഗീകരിക്കാൻ അനുവാദമുള്ളൂ (Unauthorized: Only the verified shop owner can approve reconciliation mismatches)',
      );
    }

    final record = await getOrCreateDailyReconciliation(
      shopId: shopId,
      businessDate: businessDate,
    );

    final now = DateTime.now();
    final updatedOps = <String, DailyOperatorBalanceEntry>{};
    for (final entry in record.operators.entries) {
      updatedOps[entry.key] = entry.value.copyWith(
        isReviewedByOwner: true,
        reviewedBy: '$ownerName ($ownerId)'.trim(),
        reviewedAt: now,
        remarks: entry.value.remarks != null
            ? '${entry.value.remarks}\n[OWNER REVIEW: $reviewNotes]'
            : '[OWNER REVIEW: $reviewNotes]',
      );
    }

    final updated = record.copyWith(
      operators: updatedOps,
      reconciliationStatus: 'reviewed',
      isImmutable: markImmutable ? true : record.isImmutable,
      updatedAt: now,
      auditNotes: [
        ...record.auditNotes,
        'Owner reviewed reconciliation at ${now.toIso8601String()} by $ownerName ($ownerId): $reviewNotes',
      ],
    );

    final cacheKey = '${shopId}_$businessDate';
    _localDailyReconciliations[cacheKey] = updated;

    if (Hive.isBoxOpen(boxRechargeReconciliation)) {
      await Hive.box(boxRechargeReconciliation).put(cacheKey, updated.toMap(forFirestore: false));
    }

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('recharge_daily_reconciliation')
            .doc(businessDate)
            .set(updated.toMap(forFirestore: true), SetOptions(merge: true));
      } catch (e) {
        debugPrint('[RechargeService] Firestore owner review notice: $e');
      }
    }

    return updated;
  }

  /// Authorize audited correction of an entered opening or closing balance (Owner only)
  Future<DailyReconciliationRecord> authorizeReconciliationCorrection({
    required String shopId,
    required String businessDate,
    required RechargeOperator operator,
    required String balanceType, // 'opening' or 'closing'
    required double correctedAmount,
    required String reason,
    required String requestedBy,
    required String ownerId,
    required String ownerName,
  }) async {
    final isOwner = await isAuthorizedShopOwner(shopId: shopId, uid: ownerId);
    if (!isOwner) {
      throw Exception(
        'അനധികൃത പ്രവർത്തനം: കടയുടെ ഉടമയ്ക്ക് മാത്രമേ തിരുത്തലുകൾ അംഗീകരിക്കാൻ അനുവാദമുള്ളൂ (Unauthorized: Only the verified shop owner can authorize balance corrections)',
      );
    }
    if (correctedAmount < 0) {
      throw ArgumentError('Corrected amount cannot be negative');
    }

    final record = await getOrCreateDailyReconciliation(shopId: shopId, businessDate: businessDate);
    final prevOp = record.operators[operator.name];
    if (prevOp == null) {
      throw Exception('Operator not found in reconciliation: ${operator.displayName}');
    }

    final correctedPaise = (correctedAmount * 100).round();
    final originalPaise = balanceType == 'opening' ? prevOp.openingBalancePaise : prevOp.actualClosingBalancePaise;

    final correction = ReconciliationCorrectionEntry(
      correctionId: 'CORR_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 5)}',
      operator: operator,
      balanceType: balanceType,
      originalValuePaise: originalPaise,
      correctedValuePaise: correctedPaise,
      reason: reason,
      requestedBy: requestedBy,
      approvedBy: '$ownerName ($ownerId)'.trim(),
      timestamp: DateTime.now(),
    );

    final updatedOp = balanceType == 'opening'
        ? prevOp.copyWith(
            openingBalancePaise: correctedPaise,
            differencePaise: prevOp.actualClosingBalancePaise - (correctedPaise + prevOp.totalTopupsPaise + prevOp.totalCreditsPaise - prevOp.totalDebitsPaise + prevOp.totalDebitReversalsPaise - prevOp.totalCreditReversalsPaise),
            isMismatch: (prevOp.actualClosingBalancePaise - (correctedPaise + prevOp.totalTopupsPaise + prevOp.totalCreditsPaise - prevOp.totalDebitsPaise + prevOp.totalDebitReversalsPaise - prevOp.totalCreditReversalsPaise)) != 0,
            remarks: '${prevOp.remarks ?? ""}\n[CORRECTION: Opening changed from ₹${originalPaise / 100} to ₹$correctedAmount by $ownerName. Reason: $reason]',
          )
        : prevOp.copyWith(
            actualClosingBalancePaise: correctedPaise,
            differencePaise: correctedPaise - prevOp.expectedClosingBalancePaise,
            isMismatch: (correctedPaise - prevOp.expectedClosingBalancePaise) != 0,
            remarks: '${prevOp.remarks ?? ""}\n[CORRECTION: Closing changed from ₹${originalPaise / 100} to ₹$correctedAmount by $ownerName. Reason: $reason]',
          );

    final updatedOps = Map<String, DailyOperatorBalanceEntry>.from(record.operators);
    updatedOps[operator.name] = updatedOp;
    final hasAnyMismatch = updatedOps.values.any((o) => o.isMismatch);

    final updatedRecord = record.copyWith(
      operators: updatedOps,
      reconciliationStatus: hasAnyMismatch ? 'mismatch' : 'balanced',
      corrections: [...record.corrections, correction],
      auditNotes: [
        ...record.auditNotes,
        'Owner $ownerName ($ownerId) authorized $balanceType correction for ${operator.displayName} from ₹${originalPaise / 100} to ₹$correctedAmount. Reason: $reason',
      ],
      updatedAt: DateTime.now(),
    );

    final cacheKey = '${shopId}_$businessDate';
    _localDailyReconciliations[cacheKey] = updatedRecord;

    if (Hive.isBoxOpen(boxRechargeReconciliation)) {
      await Hive.box(boxRechargeReconciliation).put(cacheKey, updatedRecord.toMap(forFirestore: false));
    }

    if (Firebase.apps.isNotEmpty && shopId.isNotEmpty) {
      try {
        final docRef = FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('recharge_daily_reconciliation')
            .doc(businessDate);

        // 1. Save immutable correction record to dedicated subcollection
        await docRef
            .collection('corrections')
            .doc(correction.correctionId)
            .set(correction.toMap(forFirestore: true));

        // 2. Append audit note to parent record (without modifying immutable opening/closing balances)
        await docRef.set({
          'auditNotes': FieldValue.arrayUnion([
            'Owner $ownerName ($ownerId) authorized $balanceType correction for ${operator.displayName} from ₹${originalPaise / 100} to ₹$correctedAmount. Reason: $reason',
          ]),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('[RechargeService] Correction save notice: $e');
      }
    }

    return updatedRecord;
  }

  /// Retrieve daily reconciliation history across a date range
  Future<List<DailyReconciliationRecord>> getDailyReconciliationHistory({
    required String shopId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final results = <DailyReconciliationRecord>[];

    // 1. From local cache
    for (final r in _localDailyReconciliations.values) {
      if (r.shopId == shopId) {
        if (r.openingStatus == 'pending' && r.closingStatus == 'pending') continue;
        final d = DateTime.tryParse(r.businessDate);
        if (d != null) {
          if (startDate != null && d.isBefore(startDate)) continue;
          if (endDate != null && d.isAfter(endDate)) continue;
        }
        results.add(r);
      }
    }

    // 2. From Hive box if available
    if (Hive.isBoxOpen(boxRechargeReconciliation)) {
      final box = Hive.box(boxRechargeReconciliation);
      for (final key in box.keys) {
        if (key.toString().startsWith('${shopId}_')) {
          final raw = box.get(key);
          if (raw is Map) {
            final r = DailyReconciliationRecord.fromMap(Map<String, dynamic>.from(raw));
            if (r.openingStatus == 'pending' && r.closingStatus == 'pending') continue;
            if (!results.any((e) => e.businessDate == r.businessDate)) {
              final d = DateTime.tryParse(r.businessDate);
              if (d != null) {
                if (startDate != null && d.isBefore(startDate)) continue;
                if (endDate != null && d.isAfter(endDate)) continue;
              }
              results.add(r);
            }
          }
        }
      }
    }

    results.sort((a, b) => b.businessDate.compareTo(a.businessDate));
    return results;
  }
}
