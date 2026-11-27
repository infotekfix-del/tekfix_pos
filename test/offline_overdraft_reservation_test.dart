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
  const testShopId = 'test_shop_reservation_audit';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_reservation_test_');
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

  group('TEKFIX ERP - PHASE 14.3: OFFLINE OVERDRAFT RESERVATION TESTS (FIX A1)', () {
    test('1. Initial reservation calculation on empty queue returns 0 paise', () async {
      final reserved = service.getPendingReservationPaise(
        shopId: testShopId,
        walletId: 'WALLET_JIO',
      );
      expect(reserved, equals(0));
    });

    test('2. Queued offline items accurately accumulate in getPendingReservationPaise', () async {
      final qBox = Hive.box(boxRechargeQueue);
      await qBox.clear();

      // Put two pending debits of ₹300 (30,000 paise) and ₹250 (25,000 paise)
      await qBox.put('Q_1', {
        'status': 'pending',
        'opType': 'RECHARGE_DEBIT',
        'payload': {
          'shopId': testShopId,
          'walletId': 'WALLET_JIO',
          'fundingType': 'ownMoney',
          'amountPaise': 30000,
        },
      });

      await qBox.put('Q_2', {
        'status': 'pending',
        'opType': 'RECHARGE_DEBIT',
        'payload': {
          'shopId': testShopId,
          'walletId': 'WALLET_JIO',
          'fundingType': 'ownMoney',
          'amountPaise': 25000,
        },
      });

      final reserved = service.getPendingReservationPaise(
        shopId: testShopId,
        walletId: 'WALLET_JIO',
        fundingType: RechargeFundingType.ownMoney,
      );
      expect(reserved, equals(55000)); // ₹550
    });

    test('3. Cumulative offline overdraft prevention: Rejects 3rd transaction exceeding wallet balance', () async {
      // 1. Topup wallet with ₹1,000 (100,000 paise)
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 1000.0,
        staffId: 'staff_1',
        staffName: 'Staff Member',
        referenceId: 'TOPUP_1000',
      );

      final wallet = await service.getWallet(shopId: testShopId, operator: RechargeOperator.jio);
      expect(wallet.ownPrepaidBalancePaise, equals(100000));

      final qBox = Hive.box(boxRechargeQueue);
      await qBox.clear();

      // 2. First offline recharge: ₹400 (40,000 paise)
      await qBox.put('Q_REC_01', {
        'status': 'pending',
        'opType': 'RECHARGE_DEBIT',
        'payload': {
          'shopId': testShopId,
          'walletId': 'WALLET_JIO',
          'fundingType': 'ownMoney',
          'amountPaise': 40000,
        },
      });

      // 3. Second offline recharge: ₹400 (40,000 paise)
      await qBox.put('Q_REC_02', {
        'status': 'pending',
        'opType': 'RECHARGE_DEBIT',
        'payload': {
          'shopId': testShopId,
          'walletId': 'WALLET_JIO',
          'fundingType': 'ownMoney',
          'amountPaise': 40000,
        },
      });

      expect(service.getPendingReservationPaise(shopId: testShopId, walletId: 'WALLET_JIO'), equals(80000));

      // 4. Third recharge: ₹400 (40,000 paise). Available balance is only 100,000 - 80,000 = 20,000 (₹200).
      // Attempting to process ₹400 must throw an exception immediately!
      final thirdRecharge = RechargeEntry(
        rechargeId: 'REC_OVERDRAFT_TEST_03',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9876543210',
        amount: 400.0,
        amountPaise: 40000,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        referenceNumber: 'REF_03',
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Staff Member',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-09',
      );

      expect(
        () async => await service.processRechargeDebit(recharge: thirdRecharge),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('പെൻഡിംഗ് ഉൾപ്പെടെ'),
        )),
      );

      // Verify that a valid smaller recharge within remaining ₹200 (e.g. ₹150) is permitted
      final allowedRecharge = RechargeEntry(
        rechargeId: 'REC_ALLOWED_TEST_04',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9876543210',
        amount: 150.0,
        amountPaise: 15000,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        referenceNumber: 'REF_04',
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Staff Member',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-09',
      );

      final res = await service.processRechargeDebit(recharge: allowedRecharge);
      expect(res.recharge.rechargeId, equals('REC_ALLOWED_TEST_04'));
    });

    test('4. Releasing pending reservations upon flush / dead-letter eviction restores available balance', () async {
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 500.0,
        staffId: 'staff_1',
        staffName: 'Staff Member',
        referenceId: 'TOPUP_AIRTEL_500',
      );

      final qBox = Hive.box(boxRechargeQueue);
      await qBox.clear();

      // Put a 25-hour expired item of ₹400 in queue
      final oldTimestamp = DateTime.now().subtract(const Duration(hours: 25)).toIso8601String();
      await qBox.put('Q_EXPIRED_AIRTEL', {
        'status': 'pending',
        'opType': 'RECHARGE_DEBIT',
        'queuedAt': oldTimestamp,
        'retryCount': 0,
        'payload': {
          'shopId': testShopId,
          'walletId': 'WALLET_AIRTEL',
          'rechargeId': 'REC_EXP_AIRTEL',
          'fundingType': 'ownMoney',
          'amountPaise': 40000,
        },
      });

      expect(service.getPendingReservationPaise(shopId: testShopId, walletId: 'WALLET_AIRTEL'), equals(40000));

      // Trigger flush: Expired item is evicted to dead-letter
      await service.flushOfflineQueue();

      // Reservation must now be 0, restoring full ₹500 available balance
      expect(service.getPendingReservationPaise(shopId: testShopId, walletId: 'WALLET_AIRTEL'), equals(0));
    });
  });
}

