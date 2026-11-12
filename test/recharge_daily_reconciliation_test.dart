import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = RechargeService.instance;
  const testShopId = 'SHOP_RECON_TEST_01';
  final businessDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase12_test_');
    Hive.init(tempDir.path);

    for (final b in allBoxes) {
      await Hive.openBox(b);
    }

    final settingsBox = Hive.box(boxSettings);
    await settingsBox.put('shop_id', testShopId);
    await settingsBox.put('shop_name', 'TEKFIX DIGITAL HUB');
  });

  tearDownAll(() async {
    try {
      await Hive.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  setUp(() async {
    service.resetLocalCacheForTesting();
    for (final b in allBoxes) {
      if (Hive.isBoxOpen(b)) {
        await Hive.box(b).clear();
      }
    }
  });

  group('TEKFIX ERP - Phase 12: Daily Operator Balance & Reconciliation Tests', () {
    // -------------------------------------------------------------------------
    // 1. MORNING OPENING BALANCE SAVE
    // -------------------------------------------------------------------------
    test('TEST 1: Morning opening balance successfully saves all four operators with integer paise', () async {
      final openingMap = {
        RechargeOperator.jio: 5000.0,
        RechargeOperator.airtel: 3000.0,
        RechargeOperator.vi: 2000.0,
        RechargeOperator.bsnl: 1000.0,
      };

      // Ensure initial operator wallet balances exist and are completely independent
      final jioWalletBefore = await service.getWallet(shopId: testShopId, operator: RechargeOperator.jio);
      final initialJioPaise = jioWalletBefore.totalBalancePaise;

      final record = await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: openingMap,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      expect(record.openingStatus, equals('completed'));
      expect(record.isOpeningComplete, isTrue);

      // Verify exact integer paise for each operator
      expect(record.operators[RechargeOperator.jio.name]!.openingBalancePaise, equals(500000));
      expect(record.operators[RechargeOperator.airtel.name]!.openingBalancePaise, equals(300000));
      expect(record.operators[RechargeOperator.vi.name]!.openingBalancePaise, equals(200000));
      expect(record.operators[RechargeOperator.bsnl.name]!.openingBalancePaise, equals(100000));

      // CRITICAL SAFETY CHECK: Existing wallet balance MUST NOT be modified by opening entry
      final jioWalletAfter = await service.getWallet(shopId: testShopId, operator: RechargeOperator.jio);
      expect(jioWalletAfter.totalBalancePaise, equals(initialJioPaise));
    });

    // -------------------------------------------------------------------------
    // 2. ALL FOUR OPERATORS REQUIRED
    // -------------------------------------------------------------------------
    test('TEST 2: Attempting morning opening with missing operator throws explicit exception', () async {
      // Missing BSNL
      final incompleteMap = {
        RechargeOperator.jio: 5000.0,
        RechargeOperator.airtel: 3000.0,
        RechargeOperator.vi: 2000.0,
      };

      expect(
        () async => await service.recordMorningOpeningBalance(
          shopId: testShopId,
          businessDate: businessDate,
          openingBalances: incompleteMap,
          staffId: 'staff_1',
          staffName: 'Shahal',
        ),
        throwsA(predicate((e) =>
            e is Exception &&
            e.toString().contains('നാല് ഓപ്പറേറ്റർമാരുടെയും ഓപ്പണിംഗ് ബാലൻസ് നിർബന്ധമാണ്') &&
            e.toString().contains('BSNL Mobile'))),
      );
    });

    // -------------------------------------------------------------------------
    // 3. DUPLICATE OPENING PREVENTION
    // -------------------------------------------------------------------------
    test('TEST 3: Duplicate morning opening balance submission for same business date is blocked', () async {
      final openingMap = {
        RechargeOperator.jio: 5000.0,
        RechargeOperator.airtel: 3000.0,
        RechargeOperator.vi: 2000.0,
        RechargeOperator.bsnl: 1000.0,
      };

      // First submission succeeds
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: openingMap,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Second duplicate submission must throw exception
      expect(
        () async => await service.recordMorningOpeningBalance(
          shopId: testShopId,
          businessDate: businessDate,
          openingBalances: openingMap,
          staffId: 'staff_1',
          staffName: 'Shahal',
        ),
        throwsA(predicate((e) =>
            e is Exception &&
            e.toString().contains('ഇന്നത്തെ ഓപ്പണിംഗ് ബാലൻസ് ഇതിനകം രേഖപ്പെടുത്തിയിട്ടുണ്ട്'))),
      );
    });

    // -------------------------------------------------------------------------
    // 4. RECHARGE BLOCKED WITHOUT OPENING
    // -------------------------------------------------------------------------
    test('TEST 4: Recharge debit is strictly blocked when opening balance is incomplete', () async {
      service.enforceDailyOpeningBalance = true;

      // Seed wallet balance with ₹1,000 for Airtel
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 1000.0,
        staffId: 'admin_1',
        staffName: 'Admin',
        referenceId: 'TOPUP_TEST_01',
      );

      final recharge = RechargeEntry(
        rechargeId: 'REC_BLOCKED_TEST_01',
        shopId: testShopId,
        customerMobile: '9847012345',
        operator: RechargeOperator.airtel,
        amount: 199.0,
        amountPaise: 19900,
        paymentMode: RechargePaymentMode.cash,
        fundingType: RechargeFundingType.ownMoney,
        staffId: 'staff_1',
        staffName: 'Shahal',
        status: RechargeStatus.pending,
        dateString: businessDate,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Attempt recharge before opening balance is completed
      expect(
        () async => await service.processRechargeDebit(recharge: recharge),
        throwsA(predicate((e) =>
            e is Exception &&
            e.toString().contains('ദിവസേനയുള്ള ഓപ്പണിംഗ് ബാലൻസ് പൂർത്തിയായിട്ടില്ല'))),
      );

      // Reset enforcement flag
      service.enforceDailyOpeningBalance = false;
    });

    // -------------------------------------------------------------------------
    // 5. NIGHT CLOSING SAVE
    // -------------------------------------------------------------------------
    test('TEST 5: Night closing balance successfully saves actual entered amounts', () async {
      // 1. Save opening first
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // 2. Save closing
      final closingMap = {
        RechargeOperator.jio: 5000.0,
        RechargeOperator.airtel: 3000.0,
        RechargeOperator.vi: 2000.0,
        RechargeOperator.bsnl: 1000.0,
      };

      final record = await service.recordNightClosingBalance(
        shopId: testShopId,
        businessDate: businessDate,
        actualClosingBalances: closingMap,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      expect(record.closingStatus, equals('completed'));
      expect(record.isClosingComplete, isTrue);
      expect(record.operators[RechargeOperator.jio.name]!.actualClosingBalancePaise, equals(500000));
      expect(record.operators[RechargeOperator.jio.name]!.isClosingCompleted, isTrue);
    });

    // -------------------------------------------------------------------------
    // 6. EXPECTED CLOSING CALCULATION
    // -------------------------------------------------------------------------
    test('TEST 6: Expected closing balance calculates: Opening + Topups + Credits - Debits + DebitReversals - CreditReversals', () async {
      // 1. Record morning opening balance (Jio: ₹5,000 = 500,000 paise)
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // 2. Wallet Top-up: +₹4,000 (400,000 paise)
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 4000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'TOPUP_CALC_01',
      );

      // 3. Distributor credit load: +₹50 (5,000 paise)
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        distributorId: 'DIST_JIO_AGENCY',
        amount: 50.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'CREDIT_CALC_01',
      );

      // 4. Successful recharge debit: -₹3,000 (300,000 paise)
      final rechargeEntry = RechargeEntry(
        rechargeId: 'REC_CALC_01',
        shopId: testShopId,
        customerMobile: '9847011111',
        operator: RechargeOperator.jio,
        amount: 3000.0,
        amountPaise: 300000,
        paymentMode: RechargePaymentMode.cash,
        fundingType: RechargeFundingType.ownMoney,
        staffId: 'staff_1',
        staffName: 'Shahal',
        status: RechargeStatus.pending,
        dateString: businessDate,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await service.processRechargeDebit(recharge: rechargeEntry);

      // 5. Calculate automatic reconciliation
      final reconciled = await service.calculateAutomaticReconciliation(
        shopId: testShopId,
        businessDate: businessDate,
      );

      final jioRecon = reconciled.operators[RechargeOperator.jio.name]!;
      // Expected = 500,000 (opening) + 400,000 (topup) + 5,000 (dist credit) - 300,000 (debit) = 605,000 paise (₹6,050.00)
      expect(jioRecon.openingBalancePaise, equals(500000));
      expect(jioRecon.totalTopupsPaise, equals(400000));
      expect(jioRecon.totalCreditsPaise, equals(5000));
      expect(jioRecon.totalDebitsPaise, equals(300000));
      expect(jioRecon.expectedClosingBalancePaise, equals(605000));
      expect(jioRecon.expectedClosingBalance, equals(6050.0));
    });

    // -------------------------------------------------------------------------
    // 7. ACTUAL VS EXPECTED DIFFERENCE
    // -------------------------------------------------------------------------
    test('TEST 7: Actual closing vs expected closing calculates precise difference in integer paise', () async {
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 4100.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Actual entered closing: Jio = ₹4,000 (Expected = ₹4,100, Diff = -₹100)
      final record = await service.recordNightClosingBalance(
        shopId: testShopId,
        businessDate: businessDate,
        actualClosingBalances: {
          RechargeOperator.jio: 4000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        mismatchReasons: {
          RechargeOperator.jio: 'Operator app balance showed ₹100 less due to delayed topup credit',
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      final jioEntry = record.operators[RechargeOperator.jio.name]!;
      expect(jioEntry.expectedClosingBalancePaise, equals(410000));
      expect(jioEntry.actualClosingBalancePaise, equals(400000));
      expect(jioEntry.differencePaise, equals(-10000));
      expect(jioEntry.difference, equals(-100.0));
      expect(jioEntry.isMismatch, isTrue);
    });

    // -------------------------------------------------------------------------
    // 8. MISMATCH ALERT
    // -------------------------------------------------------------------------
    test('TEST 8: Mismatch flag is raised and remains pending until reviewed by owner', () async {
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Night closing with mismatch
      final closingRecord = await service.recordNightClosingBalance(
        shopId: testShopId,
        businessDate: businessDate,
        actualClosingBalances: {
          RechargeOperator.jio: 4800.0, // -₹200 diff
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        mismatchReasons: {
          RechargeOperator.jio: 'Late recharge debit in operator portal',
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      expect(closingRecord.reconciliationStatus, equals('mismatch'));
      expect(closingRecord.hasMismatch, isTrue);
      expect(closingRecord.operators[RechargeOperator.jio.name]!.isReviewedByOwner, isFalse);

      // Owner reviews the mismatch
      final reviewedRecord = await service.reviewReconciliationMismatch(
        shopId: testShopId,
        businessDate: businessDate,
        ownerId: 'owner_1',
        ownerName: 'Shop Owner',
        reviewNotes: 'Verified late debit of ₹200 from operator portal logs.',
      );

      expect(reviewedRecord.reconciliationStatus, equals('reviewed'));
      expect(reviewedRecord.operators[RechargeOperator.jio.name]!.isReviewedByOwner, isTrue);
      expect(reviewedRecord.operators[RechargeOperator.jio.name]!.reviewedBy, contains('Shop Owner'));
    });

    // -------------------------------------------------------------------------
    // 9. FAILED RECHARGE EXCLUSION
    // -------------------------------------------------------------------------
    test('TEST 9: Failed recharges without financial posting are strictly excluded from debits calculation', () async {
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Record a failed recharge directly (never debited from wallet)
      final pendingRecharge = RechargeEntry(
        rechargeId: 'REC_FAILED_01',
        shopId: testShopId,
        customerMobile: '9847022222',
        operator: RechargeOperator.jio,
        amount: 500.0,
        amountPaise: 50000,
        paymentMode: RechargePaymentMode.cash,
        fundingType: RechargeFundingType.ownMoney,
        staffId: 'staff_1',
        staffName: 'Shahal',
        status: RechargeStatus.pending,
        dateString: businessDate,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await service.recordCustomerRechargePayment(recharge: pendingRecharge);
      await service.markRechargeFailed(
        shopId: testShopId,
        rechargeId: pendingRecharge.rechargeId,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Network timeout',
      );

      final reconciled = await service.calculateAutomaticReconciliation(
        shopId: testShopId,
        businessDate: businessDate,
      );

      final jioRecon = reconciled.operators[RechargeOperator.jio.name]!;
      expect(jioRecon.totalDebitsPaise, equals(0));
      expect(jioRecon.expectedClosingBalancePaise, equals(500000));
    });

    // -------------------------------------------------------------------------
    // 10. PENDING RECHARGE EXCLUSION
    // -------------------------------------------------------------------------
    test('TEST 10: Pending recharges are strictly excluded from confirmed debits', () async {
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      final reconciled = await service.calculateAutomaticReconciliation(
        shopId: testShopId,
        businessDate: businessDate,
      );

      final jioRecon = reconciled.operators[RechargeOperator.jio.name]!;
      expect(jioRecon.totalDebitsPaise, equals(0));
    });

    // -------------------------------------------------------------------------
    // 11. DUPLICATE LEDGER PREVENTION
    // -------------------------------------------------------------------------
    test('TEST 11: Reconciliation uses idempotent ledger queries preventing duplicate postings', () async {
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Calculate multiple times consecutively
      final recon1 = await service.calculateAutomaticReconciliation(shopId: testShopId, businessDate: businessDate);
      final recon2 = await service.calculateAutomaticReconciliation(shopId: testShopId, businessDate: businessDate);

      expect(recon1.operators[RechargeOperator.jio.name]!.expectedClosingBalancePaise,
          equals(recon2.operators[RechargeOperator.jio.name]!.expectedClosingBalancePaise));
    });

    // -------------------------------------------------------------------------
    // 12. PREVIOUS-DAY RECORD PROTECTION
    // -------------------------------------------------------------------------
    test('TEST 12: Previous-day record marked immutable strictly rejects closing overwrites', () async {
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: '2026-11-07',
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      await service.recordNightClosingBalance(
        shopId: testShopId,
        businessDate: '2026-11-07',
        actualClosingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Lock record as immutable
      await service.reviewReconciliationMismatch(
        shopId: testShopId,
        businessDate: '2026-11-07',
        ownerId: 'owner_1',
        ownerName: 'Owner',
        reviewNotes: 'Finalized day closing',
        markImmutable: true,
      );

      // Subsequent attempt to mutate immutable record must throw exception
      expect(
        () async => await service.recordNightClosingBalance(
          shopId: testShopId,
          businessDate: '2026-11-07',
          actualClosingBalances: {
            RechargeOperator.jio: 9999.0,
            RechargeOperator.airtel: 9999.0,
            RechargeOperator.vi: 9999.0,
            RechargeOperator.bsnl: 9999.0,
          },
          staffId: 'staff_1',
          staffName: 'Shahal',
        ),
        throwsA(predicate((e) =>
            e is Exception &&
            e.toString().contains('റീകൺസിലിയേഷൻ റെക്കോർഡ് സ്ഥിരീകരിച്ചതാണ്'))),
      );
    });

    // -------------------------------------------------------------------------
    // 13. CROSS-SHOP ACCESS PROTECTION
    // -------------------------------------------------------------------------
    test('TEST 13: Daily reconciliation data is strictly isolated per shopId', () async {
      const shopA = 'SHOP_ISOLATED_A';
      const shopB = 'SHOP_ISOLATED_B';

      await service.recordMorningOpeningBalance(
        shopId: shopA,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_a',
        staffName: 'Staff A',
      );

      // Querying shopB returns uninitialized blank record
      final shopBRecord = await service.getOrCreateDailyReconciliation(
        shopId: shopB,
        businessDate: businessDate,
      );
      expect(shopBRecord.isOpeningComplete, isFalse);
      expect(shopBRecord.operators[RechargeOperator.jio.name]!.openingBalancePaise, equals(0));

      final historyA = await service.getDailyReconciliationHistory(shopId: shopA);
      final historyB = await service.getDailyReconciliationHistory(shopId: shopB);

      expect(historyA.length, equals(1));
      expect(historyB, isEmpty);
    });

    // -------------------------------------------------------------------------
    // 14. OFFLINE PERSISTENCE & SAFE SYNCHRONIZATION
    // -------------------------------------------------------------------------
    test('TEST 14: Daily reconciliation records persist durably in Hive box and survive restarts', () async {
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Verify stored in Hive box
      final hiveBox = Hive.box(boxRechargeReconciliation);
      final cacheKey = '${testShopId}_$businessDate';
      expect(hiveBox.containsKey(cacheKey), isTrue);

      // Simulate app restart by clearing local memory cache
      service.resetLocalCacheForTesting();

      // Fetch again -> should rehydrate from Hive
      final rehydrated = await service.getOrCreateDailyReconciliation(
        shopId: testShopId,
        businessDate: businessDate,
      );

      expect(rehydrated.isOpeningComplete, isTrue);
      expect(rehydrated.operators[RechargeOperator.jio.name]!.openingBalancePaise, equals(500000));
    });

    // -------------------------------------------------------------------------
    // 15. PERSISTENT WALLET LEDGER ACROSS APP RESTARTS (PHASE 12.2)
    // -------------------------------------------------------------------------
    test('TEST 15: Wallet ledger entries persist to Hive box and recalculation succeeds after memory wipe', () async {
      // 1. Record opening balance
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // 2. Add Top-up (+₹2,000)
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 2000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'TOPUP_PERSIST_01',
      );

      // 3. Process Recharge Debit (-₹1,000)
      final rec = RechargeEntry(
        rechargeId: 'REC_PERSIST_01',
        shopId: testShopId,
        customerMobile: '9847012345',
        operator: RechargeOperator.jio,
        amount: 1000.0,
        amountPaise: 100000,
        paymentMode: RechargePaymentMode.cash,
        fundingType: RechargeFundingType.ownMoney,
        staffId: 'staff_1',
        staffName: 'Shahal',
        status: RechargeStatus.pending,
        dateString: businessDate,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await service.processRechargeDebit(recharge: rec);

      // 4. Simulate complete app restart / memory wipe
      service.resetLocalCacheForTesting();

      // 5. Automatic recalculation should rehydrate wallet ledger from Hive box
      final recalculated = await service.calculateAutomaticReconciliation(
        shopId: testShopId,
        businessDate: businessDate,
      );

      final jio = recalculated.operators[RechargeOperator.jio.name]!;
      // Expected = 5,000 (opening) + 2,000 (topup) - 1,000 (debit) = ₹6,000 (600,000 paise)
      expect(jio.openingBalancePaise, equals(500000));
      expect(jio.totalTopupsPaise, equals(200000));
      expect(jio.totalDebitsPaise, equals(100000));
      expect(jio.expectedClosingBalancePaise, equals(600000));
      expect(jio.expectedClosingBalance, equals(6000.0));
    });

    // -------------------------------------------------------------------------
    // 16. MANDATORY OPENING GATE BLOCKS DIRECT SERVICE CALLS (PHASE 12.2)
    // -------------------------------------------------------------------------
    test('TEST 16: Mandatory opening gate blocks direct service calls unconditionally', () async {
      // Opening balance NOT recorded for today
      expect(service.enforceDailyOpeningBalance, isTrue);

      final rechargeEntry = RechargeEntry(
        rechargeId: 'REC_GATE_DIRECT',
        shopId: testShopId,
        customerMobile: '9847099999',
        operator: RechargeOperator.jio,
        amount: 299.0,
        amountPaise: 29900,
        paymentMode: RechargePaymentMode.cash,
        fundingType: RechargeFundingType.ownMoney,
        staffId: 'staff_1',
        staffName: 'Shahal',
        status: RechargeStatus.pending,
        dateString: businessDate,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Direct service call without any optional parameters MUST be rejected
      expect(
        () async => await service.processRechargeDebit(recharge: rechargeEntry),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('ദിവസേനയുള്ള ഓപ്പണിംഗ് ബാലൻസ് പൂർത്തിയായിട്ടില്ല'),
        )),
      );
    });

    // -------------------------------------------------------------------------
    // 17. CENTRALIZED BUSINESS DATE AND ASIA/KOLKATA TIMEZONE (PHASE 12.2)
    // -------------------------------------------------------------------------
    test('TEST 17: Centralized business date calculation remains accurate in Asia/Kolkata timezone', () {
      // When UTC is 2026-11-07 20:00:00 (which is 2026-11-08 01:30:00 IST)
      final utcNight = DateTime.utc(2026, 11, 7, 20, 0, 0);
      final bDate = RechargeService.getBusinessDate(utcTime: utcNight);
      expect(bDate, equals('2026-11-08'));

      // Normal afternoon
      final utcAft = DateTime.utc(2026, 11, 8, 8, 30, 0); // 14:00 IST
      expect(RechargeService.getBusinessDate(utcTime: utcAft), equals('2026-11-08'));
    });

    // -------------------------------------------------------------------------
    // 18. DUPLICATE NIGHT CLOSING SUBMISSION IS BLOCKED (PHASE 12.2)
    // -------------------------------------------------------------------------
    test('TEST 18: Duplicate night closing submission for same business date is blocked', () async {
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // First closing submission
      await service.recordNightClosingBalance(
        shopId: testShopId,
        businessDate: businessDate,
        actualClosingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Second closing submission for same date must be rejected
      expect(
        () async => await service.recordNightClosingBalance(
          shopId: testShopId,
          businessDate: businessDate,
          actualClosingBalances: {
            RechargeOperator.jio: 5500.0,
            RechargeOperator.airtel: 3000.0,
            RechargeOperator.vi: 2000.0,
            RechargeOperator.bsnl: 1000.0,
          },
          staffId: 'staff_1',
          staffName: 'Shahal',
        ),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('ഇന്നത്തെ ക്ലോസിംഗ് ബാലൻസ് ഇതിനകം രേഖപ്പെടുത്തിയിട്ടുണ്ട്'),
        )),
      );
    });

    // -------------------------------------------------------------------------
    // 19. MISSING/UNVERIFIED LEDGER NEVER PRODUCES FALSE BALANCED STATUS (PHASE 12.2)
    // -------------------------------------------------------------------------
    test('TEST 19: Missing/unverified ledger data marks reconciliation incomplete, never false BALANCED', () async {
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Simulate unverified / missing ledger query
      final result = await service.calculateAutomaticReconciliation(
        shopId: testShopId,
        businessDate: businessDate,
        actualClosingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        simulateUnverifiedLedger: true,
      );

      expect(result.hasIncompleteLedger, isTrue);
      expect(result.reconciliationStatus, equals('incomplete'));
      expect(result.reconciliationStatus, isNot(equals('balanced')));
    });

    // -------------------------------------------------------------------------
    // 20. AUTHORIZED OWNER CORRECTION WORKFLOW (PHASE 12.2)
    // -------------------------------------------------------------------------
    test('TEST 20: Authorized owner correction creates distinct audit record and updates difference', () async {
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      await service.recordNightClosingBalance(
        shopId: testShopId,
        businessDate: businessDate,
        actualClosingBalances: {
          RechargeOperator.jio: 4900.0, // Entered 4900 by mistake (Mismatch ₹100)
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        mismatchReasons: {RechargeOperator.jio: 'Typo in manual entry'},
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      final before = await service.getOrCreateDailyReconciliation(shopId: testShopId, businessDate: businessDate);
      expect(before.reconciliationStatus, equals('mismatch'));
      expect(before.operators[RechargeOperator.jio.name]!.differencePaise, equals(-10000));

      // Owner authorizes correction with reason
      final corrected = await service.authorizeReconciliationCorrection(
        shopId: testShopId,
        businessDate: businessDate,
        operator: RechargeOperator.jio,
        balanceType: 'closing',
        correctedAmount: 5000.0,
        reason: 'Verified operator app screen: balance was ₹5,000',
        requestedBy: 'staff_1',
        ownerId: 'owner_1',
        ownerName: 'Shop Owner',
      );

      expect(corrected.corrections.length, equals(1));
      expect(corrected.corrections.first.originalValuePaise, equals(490000));
      expect(corrected.corrections.first.correctedValuePaise, equals(500000));
      expect(corrected.corrections.first.reason, contains('Verified operator app screen'));
      expect(corrected.operators[RechargeOperator.jio.name]!.differencePaise, equals(0));
      expect(corrected.reconciliationStatus, equals('balanced'));
    });

    // -------------------------------------------------------------------------
    // 21. PARTIAL HIVE CACHE + UNVERIFIED REMOTE LEDGER STRICTLY FAILS CLOSED (PHASE 12.4)
    // -------------------------------------------------------------------------
    test('TEST 21: Local Hive cache with records strictly fails closed to incomplete when remote ledger is unverified', () async {
      // 1. Record morning opening
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 5000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // 2. Perform a real topup locally so Hive box and local cache have entries
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 1000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'TOPUP_CACHE_01',
      );

      // 3. Calculate reconciliation with matching balance (5000 + 1000 = 6000)
      // BUT with simulateUnverifiedLedger: true (simulating server query failure/offline unverified state)
      final result = await service.calculateAutomaticReconciliation(
        shopId: testShopId,
        businessDate: businessDate,
        actualClosingBalances: {
          RechargeOperator.jio: 6000.0,
          RechargeOperator.airtel: 3000.0,
          RechargeOperator.vi: 2000.0,
          RechargeOperator.bsnl: 1000.0,
        },
        simulateUnverifiedLedger: true,
      );

      // Must FAIL-CLOSED: Despite matching local math, incomplete ledger MUST NOT be marked 'balanced'
      expect(result.hasIncompleteLedger, isTrue);
      expect(result.reconciliationStatus, equals('incomplete'));
      expect(result.reconciliationStatus, isNot(equals('balanced')));
    });
  });
}
