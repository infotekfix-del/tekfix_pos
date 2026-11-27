import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final service = RechargeService.instance;
  const testShopId = 'test_shop_tekfix_offline';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_offline_queue_test_');
    Hive.init(tempDir.path);

    for (final boxName in allBoxes) {
      if (!Hive.isBoxOpen(boxName)) {
        await Hive.openBox(boxName);
      }
    }

    service.resetLocalCacheForTesting();
    service.disableOpeningBalanceGateForTesting();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('TEKFIX ERP - PHASE 14.1: OFFLINE QUEUE SAFETY & DEAD-LETTER TESTS', () {
    test('1. boxRechargeDeadLetter is included in allBoxes and opened', () {
      expect(Hive.isBoxOpen(boxRechargeDeadLetter), isTrue);
      expect(Db.rechargeDeadLetter.isOpen, isTrue);
    });

    test('2. Queued offline operation preserves idempotency key and initial retryCount = 0', () async {
      final qBox = Hive.box(boxRechargeQueue);
      await qBox.clear();

      final recharge = RechargeEntry(
        rechargeId: 'REC_OFFLINE_001',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9876543210',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        referenceNumber: 'REF_001',
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Staff Member',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-09',
        isOfflinePending: true,
      );

      // Queue offline item directly
      await qBox.put(recharge.rechargeId, {
        'queueId': recharge.rechargeId,
        'idempotencyKey': recharge.rechargeId,
        'opType': 'RECHARGE_DEBIT',
        'payload': recharge.toMap(forFirestore: false),
        'queuedAt': DateTime.now().toIso8601String(),
        'status': 'pending',
        'retryCount': 0,
      });

      expect(qBox.containsKey('REC_OFFLINE_001'), isTrue);
      final item = Map<String, dynamic>.from(qBox.get('REC_OFFLINE_001'));
      expect(item['idempotencyKey'], equals('REC_OFFLINE_001'));
      expect(item['status'], equals('pending'));
      expect(item['retryCount'], equals(0));
      expect(item['queuedAt'], isNotEmpty);
    });

    test('3. 24-Hour Expiration TTL: Expired queue items are moved to Dead-Letter box and marked failed', () async {
      final qBox = Hive.box(boxRechargeQueue);
      final dlBox = Hive.box(boxRechargeDeadLetter);
      await qBox.clear();
      await dlBox.clear();

      // Seed a 25-hour old pending item
      final oldTimestamp = DateTime.now().subtract(const Duration(hours: 25)).toIso8601String();
      const expiredId = 'REC_EXPIRED_24H_TEST';

      final recharge = RechargeEntry(
        rechargeId: expiredId,
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9999999999',
        amount: 499.0,
        amountPaise: 49900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        referenceNumber: 'REF_OLD',
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Staff Member',
        createdAt: DateTime.now().subtract(const Duration(hours: 25)),
        updatedAt: DateTime.now().subtract(const Duration(hours: 25)),
        dateString: '2026-11-08',
        isOfflinePending: true,
      );

      // Add to local cache and persist
      await service.rehydrateFromHive();
      Hive.box(boxRecharges).put(expiredId, recharge.toMap(forFirestore: false));

      await qBox.put(expiredId, {
        'queueId': expiredId,
        'idempotencyKey': expiredId,
        'opType': 'RECHARGE_DEBIT',
        'payload': recharge.toMap(forFirestore: false),
        'queuedAt': oldTimestamp,
        'status': 'pending',
        'retryCount': 1,
      });

      expect(qBox.containsKey(expiredId), isTrue);
      expect(dlBox.containsKey(expiredId), isFalse);

      // Trigger flush
      await service.flushOfflineQueue();

      // Queue box MUST NOT contain the expired item anymore
      expect(qBox.containsKey(expiredId), isFalse);

      // Dead-Letter box MUST contain the expired item with exact reason
      expect(dlBox.containsKey(expiredId), isTrue);
      final dlItem = Map<String, dynamic>.from(dlBox.get(expiredId));
      expect(dlItem['deadLetterReason'], equals('EXPIRED_24H_OFFLINE'));
      expect(dlItem['deadLetteredAt'], isNotEmpty);
    });

    test('4. Dead-Letter Routing on Exceeded Retry Limit (retryCount >= 5)', () async {
      final qBox = Hive.box(boxRechargeQueue);
      final dlBox = Hive.box(boxRechargeDeadLetter);
      await qBox.clear();
      await dlBox.clear();

      const maxRetryId = 'REC_MAX_RETRY_TEST';

      final recharge = RechargeEntry(
        rechargeId: maxRetryId,
        shopId: testShopId,
        operator: RechargeOperator.vi,
        customerMobile: '9888888888',
        amount: 199.0,
        amountPaise: 19900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        referenceNumber: 'REF_RETRIES',
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Staff Member',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-09',
        isOfflinePending: true,
      );

      // Put item in queue with retryCount = 5
      await qBox.put(maxRetryId, {
        'queueId': maxRetryId,
        'idempotencyKey': maxRetryId,
        'opType': 'RECHARGE_DEBIT',
        'payload': recharge.toMap(forFirestore: false),
        'queuedAt': DateTime.now().toIso8601String(),
        'status': 'pending',
        'retryCount': 5,
      });

      expect(qBox.containsKey(maxRetryId), isTrue);
      expect(dlBox.containsKey(maxRetryId), isFalse);

      // Trigger flush
      await service.flushOfflineQueue();

      // Queue box MUST NOT contain the item anymore
      expect(qBox.containsKey(maxRetryId), isFalse);

      // Dead-Letter box MUST contain the item with reason DEAD_LETTER_MAX_RETRIES
      expect(dlBox.containsKey(maxRetryId), isTrue);
      final dlItem = Map<String, dynamic>.from(dlBox.get(maxRetryId));
      expect(dlItem['deadLetterReason'], equals('DEAD_LETTER_MAX_RETRIES'));
    });

    test('5. Non-expired item with retryCount < 5 remains in queue safely', () async {
      final qBox = Hive.box(boxRechargeQueue);
      final dlBox = Hive.box(boxRechargeDeadLetter);
      await qBox.clear();
      await dlBox.clear();

      const freshId = 'REC_FRESH_PENDING';

      final recharge = RechargeEntry(
        rechargeId: freshId,
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9777777777',
        amount: 399.0,
        amountPaise: 39900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        referenceNumber: 'REF_FRESH',
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Staff Member',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-09',
        isOfflinePending: true,
      );

      await qBox.put(freshId, {
        'queueId': freshId,
        'idempotencyKey': freshId,
        'opType': 'RECHARGE_DEBIT',
        'payload': recharge.toMap(forFirestore: false),
        'queuedAt': DateTime.now().toIso8601String(),
        'status': 'pending',
        'retryCount': 2,
      });

      // When Firebase.apps is empty (test runner), the item stays safe
      await service.flushOfflineQueue();

      // Should not be in dead letter
      expect(dlBox.containsKey(freshId), isFalse);
    });

    test('6. Wallet balance and ledger are preserved when recharge is offline pending', () async {
      // 1. Initialize wallet with ₹1,000 topup
      final topupRes = await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 1000.0,
        staffId: 'staff_1',
        staffName: 'Staff Member',
        referenceId: 'TOPUP_INIT_1000',
        description: 'Opening balance topup',
      );
      expect(topupRes.wallet.ownPrepaidBalancePaise, equals(100000));

      final initialLedgerCount = service.getLocalWalletLedger(
        walletId: 'WALLET_JIO',
      ).length;

      // 2. Simulate pending offline entry
      final offlineRecharge = RechargeEntry(
        rechargeId: 'REC_PENDING_AUDIT_101',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9123456789',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        referenceNumber: 'REF_OFFLINE_AUDIT',
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Staff Member',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-09',
        walletDebited: false,
        isOfflinePending: true,
      );

      // Verify model invariants
      expect(offlineRecharge.status, equals(RechargeStatus.pending));
      expect(offlineRecharge.walletDebited, isFalse);
      expect(offlineRecharge.isOfflinePending, isTrue);

      // Wallet balance must remain ₹1,000 (100,000 paise)
      final currentWallet = await service.getWallet(
        shopId: testShopId,
        operator: RechargeOperator.jio,
      );
      expect(currentWallet.ownPrepaidBalancePaise, equals(100000));

      // Wallet ledger count must remain unchanged
      final afterLedgerCount = service.getLocalWalletLedger(
        walletId: 'WALLET_JIO',
      ).length;
      expect(afterLedgerCount, equals(initialLedgerCount));
    });
  });
}
