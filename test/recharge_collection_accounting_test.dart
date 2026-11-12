import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TEKFIX ERP - Phase 4: Recharge Collection Accounting', () {
    late Directory tempDir;
    const testShopId = 'test_shop_tekfix';
    final service = RechargeService.instance;

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('recharge_coll_test_');
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
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    setUp(() async {
      service.resetLocalCacheForTesting();
      await Db.bank.clear();
      await Db.sales.clear();
      await Db.bank.put('cash_in_hand', 1000.0); // Baseline opening cash float ₹1,000
      await Db.bank.put('bank_balance', 25000.0); // Baseline bank balance ₹25,000
      await Db.bank.put('txn_log', <Map<String, dynamic>>[]);
    });

    // -------------------------------------------------------------------------
    // TEST 1: Customer Cash Recharge ₹299 (Jio)
    // -------------------------------------------------------------------------
    test(
        '1. Customer Cash Recharge ₹299: Physical Cash +₹299, Sales Revenue = ₹0',
        () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();
      final initialSalesCount = Db.sales.length;

      final recharge = RechargeEntry(
        rechargeId: 'REC_JIO_CASH_299',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847012345',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.distributorCredit,
        distributorId: 'DIST_JIO_AGENCY',
        distributorName: 'Kochi Jio Prime Agency',
        paymentMode: RechargePaymentMode.cash,
        referenceNumber: 'JIO_REF_001',
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime(2026, 11, 7, 10, 30),
        updatedAt: DateTime(2026, 11, 7, 10, 30),
        dateString: '2026-11-07',
        notes: 'Unlimited 28 days plan',
      );

      final result = await service.recordCustomerRechargePayment(recharge: recharge);

      // A. Physical Cash Verification: Drawer receives customer money
      final updatedCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final updatedBank = (Db.bank.get('bank_balance') as num).toDouble();

      expect(updatedCash, initialCash + 299.0,
          reason: 'Physical cash in hand must increase by customer recharge cash');
      expect(updatedBank, initialBank,
          reason: 'Bank balance must not change for cash recharge');

      // B. Accounting Isolation: STRICT NON-REVENUE PASS-THROUGH
      expect(Db.sales.length, initialSalesCount,
          reason: 'Recharge principal must NEVER be recorded as retail sales revenue');

      // C. Collection Summary Verification
      expect(result.financiallyPosted, isTrue);
      expect(result.summary.cashCollection, 299.0);
      expect(result.summary.upiCollection, 0.0);
      expect(result.summary.cardCollection, 0.0);
      expect(result.summary.totalCollection, 299.0);
      expect(result.summary.successfulCount, 1);
      expect(result.summary.getOperatorCollection(RechargeOperator.jio), 299.0);
    });

    // -------------------------------------------------------------------------
    // TEST 2: Customer UPI Recharge ₹299 (Airtel)
    // -------------------------------------------------------------------------
    test(
        '2. Customer UPI Recharge ₹299: Bank/UPI Balance +₹299, Cash = ₹0, Sales = ₹0',
        () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      final recharge = RechargeEntry(
        rechargeId: 'REC_AIRTEL_UPI_299',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9447198765',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.upi,
        referenceNumber: 'UPI_TXN_888999',
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime(2026, 11, 7, 11, 15),
        updatedAt: DateTime(2026, 11, 7, 11, 15),
        dateString: '2026-11-07',
        notes: 'Google Pay UPI Collection',
      );

      final result = await service.recordCustomerRechargePayment(recharge: recharge);

      // A. Bank / UPI Balance Verification
      final updatedCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final updatedBank = (Db.bank.get('bank_balance') as num).toDouble();

      expect(updatedBank, initialBank + 299.0,
          reason: 'Bank balance must increase by UPI collection');
      expect(updatedCash, initialCash,
          reason: 'Physical cash must not be touched for UPI recharge');

      // B. Accounting Isolation
      expect(Db.sales.length, 0, reason: 'Sales box must remain 0');

      // C. Collection Summary Verification
      expect(result.summary.upiCollection, 299.0);
      expect(result.summary.cashCollection, 0.0);
      expect(result.summary.totalCollection, 299.0);
      expect(result.summary.getOperatorCollection(RechargeOperator.airtel), 299.0);
    });

    // -------------------------------------------------------------------------
    // TEST 3: Customer Card Recharge ₹599 (Vi)
    // -------------------------------------------------------------------------
    test('3. Customer Card Recharge ₹599: Bank +₹599, Card Collection = ₹599',
        () async {
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      final recharge = RechargeEntry(
        rechargeId: 'REC_VI_CARD_599',
        shopId: testShopId,
        operator: RechargeOperator.vi,
        customerMobile: '9846054321',
        amount: 599.0,
        amountPaise: 59900,
        fundingType: RechargeFundingType.distributorCredit,
        paymentMode: RechargePaymentMode.card,
        referenceNumber: 'POS_SWIPE_1234',
        status: RechargeStatus.success,
        staffId: 'staff_2',
        staffName: 'Rahul',
        createdAt: DateTime(2026, 11, 7, 12, 0),
        updatedAt: DateTime(2026, 11, 7, 12, 0),
        dateString: '2026-11-07',
      );

      final result = await service.recordCustomerRechargePayment(recharge: recharge);

      final updatedBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(updatedBank, initialBank + 599.0);
      expect(result.summary.cardCollection, 599.0);
      expect(result.summary.totalCollection, 599.0);
      expect(result.summary.getOperatorCollection(RechargeOperator.vi), 599.0);
    });

    // -------------------------------------------------------------------------
    // TEST 4: Multiple Operator Collections Aggregation
    // -------------------------------------------------------------------------
    test('4. Aggregate Multiple Operator Collections (Airtel, Jio, Vi, BSNL)',
        () async {
      final entries = [
        RechargeEntry(
          rechargeId: 'REC_AIRTEL_719',
          shopId: testShopId,
          operator: RechargeOperator.airtel,
          amount: 719.0,
          amountPaise: 71900,
          fundingType: RechargeFundingType.distributorCredit,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: DateTime(2026, 11, 7, 13, 0),
          updatedAt: DateTime(2026, 11, 7, 13, 0),
          dateString: '2026-11-07',
        ),
        RechargeEntry(
          rechargeId: 'REC_JIO_299_MULTI',
          shopId: testShopId,
          operator: RechargeOperator.jio,
          amount: 299.0,
          amountPaise: 29900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.upi,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: DateTime(2026, 11, 7, 13, 30),
          updatedAt: DateTime(2026, 11, 7, 13, 30),
          dateString: '2026-11-07',
        ),
        RechargeEntry(
          rechargeId: 'REC_VI_239',
          shopId: testShopId,
          operator: RechargeOperator.vi,
          amount: 239.0,
          amountPaise: 23900,
          fundingType: RechargeFundingType.distributorCredit,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_2',
          staffName: 'Rahul',
          createdAt: DateTime(2026, 11, 7, 14, 0),
          updatedAt: DateTime(2026, 11, 7, 14, 0),
          dateString: '2026-11-07',
        ),
        RechargeEntry(
          rechargeId: 'REC_BSNL_149',
          shopId: testShopId,
          operator: RechargeOperator.bsnl,
          amount: 149.0,
          amountPaise: 14900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: DateTime(2026, 11, 7, 14, 30),
          updatedAt: DateTime(2026, 11, 7, 14, 30),
          dateString: '2026-11-07',
        ),
      ];

      for (final rec in entries) {
        await service.recordCustomerRechargePayment(recharge: rec);
      }

      final summary = await service.getDailyCollectionSummary(
        shopId: testShopId,
        dateString: '2026-11-07',
      );

      // Total Expected = 719 + 299 + 239 + 149 = 1,406.00
      expect(summary.totalCollection, 1406.0);
      expect(summary.totalCollectionPaise, 140600);

      // Cash Expected = 719 + 239 + 149 = 1,107.00
      expect(summary.cashCollection, 1107.0);

      // UPI Expected = 299.00
      expect(summary.upiCollection, 299.0);

      // Operator-wise verification
      expect(summary.getOperatorCollection(RechargeOperator.airtel), 719.0);
      expect(summary.getOperatorCollection(RechargeOperator.jio), 299.0);
      expect(summary.getOperatorCollection(RechargeOperator.vi), 239.0);
      expect(summary.getOperatorCollection(RechargeOperator.bsnl), 149.0);
      expect(summary.getOperatorCollection(RechargeOperator.other), 0.0);
      expect(summary.successfulCount, 4);
    });

    // -------------------------------------------------------------------------
    // TEST 5: Pending Recharge (Zero Financial Movement)
    // -------------------------------------------------------------------------
    test('5. Pending Recharge: Zero Financial Movement, Count = 1', () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      final pendingRecharge = RechargeEntry(
        rechargeId: 'REC_PENDING_199',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 199.0,
        amountPaise: 19900,
        fundingType: RechargeFundingType.distributorCredit,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime(2026, 11, 7, 15, 0),
        updatedAt: DateTime(2026, 11, 7, 15, 0),
        dateString: '2026-11-07',
      );

      final result =
          await service.recordCustomerRechargePayment(recharge: pendingRecharge);

      expect(result.financiallyPosted, isFalse);
      expect((Db.bank.get('cash_in_hand') as num).toDouble(), initialCash);
      expect((Db.bank.get('bank_balance') as num).toDouble(), initialBank);
      expect(result.summary.pendingCount, 1);
      expect(result.summary.successfulCount, 0);
      expect(result.summary.totalCollection, 0.0);
    });

    // -------------------------------------------------------------------------
    // TEST 6: Failed Recharge (Zero Financial Movement)
    // -------------------------------------------------------------------------
    test('6. Failed Recharge: Zero Financial Movement, Count = 1', () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      final failedRecharge = RechargeEntry(
        rechargeId: 'REC_FAILED_299',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.upi,
        status: RechargeStatus.failed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime(2026, 11, 7, 15, 30),
        updatedAt: DateTime(2026, 11, 7, 15, 30),
        dateString: '2026-11-07',
      );

      final result =
          await service.recordCustomerRechargePayment(recharge: failedRecharge);

      expect(result.financiallyPosted, isFalse);
      expect((Db.bank.get('cash_in_hand') as num).toDouble(), initialCash);
      expect((Db.bank.get('bank_balance') as num).toDouble(), initialBank);
      expect(result.summary.failedCount, 1);
      expect(result.summary.successfulCount, 0);
      expect(result.summary.totalCollection, 0.0);
    });

    // -------------------------------------------------------------------------
    // TEST 7: Refund & Reversal of Successful Cash Recharge
    // -------------------------------------------------------------------------
    test('7. Refund & Reversal: Reverses Cash from Drawer and Updates Summary',
        () async {
      final baselineCash = (Db.bank.get('cash_in_hand') as num).toDouble();

      final rec = RechargeEntry(
        rechargeId: 'REC_REFUND_TARGET_349',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 349.0,
        amountPaise: 34900,
        fundingType: RechargeFundingType.distributorCredit,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime(2026, 11, 7, 16, 0),
        updatedAt: DateTime(2026, 11, 7, 16, 0),
        dateString: '2026-11-07',
      );

      // 1. Post original payment
      await service.recordCustomerRechargePayment(recharge: rec);
      expect((Db.bank.get('cash_in_hand') as num).toDouble(), baselineCash + 349.0);

      // 2. Perform Refund & Reversal
      final refundResult = await service.refundOrReverseRecharge(
        shopId: testShopId,
        rechargeId: 'REC_REFUND_TARGET_349',
        staffId: 'staff_admin',
        staffName: 'Admin',
        reason: 'Customer entered wrong number',
      );

      // 3. Physical Cash must be returned to customer
      expect((Db.bank.get('cash_in_hand') as num).toDouble(), baselineCash,
          reason: 'Drawer cash must decrement by ₹349 on refund');

      // 4. Summary adjustments
      expect(refundResult.reversed, isTrue);
      expect(refundResult.recharge.status, RechargeStatus.refunded);
      expect(refundResult.summary.refundedCount, 1);
      expect(refundResult.summary.successfulCount, 0);
      expect(refundResult.summary.cashCollection, 0.0);
      expect(refundResult.summary.totalCollection, 0.0);
      expect(refundResult.summary.getOperatorCollection(RechargeOperator.jio), 0.0);
    });

    // -------------------------------------------------------------------------
    // TEST 8: Duplicate Payment Submission Prevention
    // -------------------------------------------------------------------------
    test('8. Duplicate Submission Prevention: Double-posting is strictly blocked',
        () async {
      final rec = RechargeEntry(
        rechargeId: 'REC_IDEMPOTENT_100',
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 100.0,
        amountPaise: 10000,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime(2026, 11, 7, 17, 0),
        updatedAt: DateTime(2026, 11, 7, 17, 0),
        dateString: '2026-11-07',
      );

      // First submission succeeds
      await service.recordCustomerRechargePayment(recharge: rec);

      // Second submission with same ID must throw an exception
      expect(
        () => service.recordCustomerRechargePayment(recharge: rec),
        throwsA(isA<Exception>()),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 9: EOD Reconciliation Breakdown Separation
    // -------------------------------------------------------------------------
    test('9. EOD Breakdown Separation: Distinct Retail Cash, Service Cash, Recharge Cash',
        () async {
      // Simulate typical retail store day:
      // 1. Retail Sales Cash: ₹4,500
      // 2. Service Repair Cash: ₹1,200
      // 3. Recharge Cash: ₹800 (Airtel ₹500 + Jio ₹300)
      // 4. Recharge UPI: ₹600 (Vi ₹600)

      final rechargeCash1 = RechargeEntry(
        rechargeId: 'EOD_REC_CASH_1',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 500.0,
        amountPaise: 50000,
        fundingType: RechargeFundingType.distributorCredit,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime(2026, 11, 7, 10, 0),
        updatedAt: DateTime(2026, 11, 7, 10, 0),
        dateString: '2026-11-07',
      );

      final rechargeCash2 = RechargeEntry(
        rechargeId: 'EOD_REC_CASH_2',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 300.0,
        amountPaise: 30000,
        fundingType: RechargeFundingType.distributorCredit,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime(2026, 11, 7, 11, 0),
        updatedAt: DateTime(2026, 11, 7, 11, 0),
        dateString: '2026-11-07',
      );

      final rechargeUpi = RechargeEntry(
        rechargeId: 'EOD_REC_UPI_1',
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 600.0,
        amountPaise: 60000,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.upi,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime(2026, 11, 7, 12, 0),
        updatedAt: DateTime(2026, 11, 7, 12, 0),
        dateString: '2026-11-07',
      );

      await service.recordCustomerRechargePayment(recharge: rechargeCash1);
      await service.recordCustomerRechargePayment(recharge: rechargeCash2);
      await service.recordCustomerRechargePayment(recharge: rechargeUpi);

      final summary = await service.getDailyCollectionSummary(
        shopId: testShopId,
        dateString: '2026-11-07',
      );

      // Separate EOD Channels
      const double retailSalesCash = 4500.0;
      const double serviceBillCash = 1200.0;
      final double rechargeCash = summary.cashCollection; // ₹800
      final double rechargeUpiCollected = summary.upiCollection; // ₹600

      expect(rechargeCash, 800.0);
      expect(rechargeUpiCollected, 600.0);

      // Physical Till Expectation:
      // Opening Float (₹1,000) + Retail Cash (₹4,500) + Service Cash (₹1,200) + Recharge Cash (₹800) = ₹7,500
      const double openingFloat = 1000.0;
      final double totalPhysicalCashInDrawer =
          openingFloat + retailSalesCash + serviceBillCash + rechargeCash;

      expect(totalPhysicalCashInDrawer, 7500.0);

      // Verify that retail sales remains untouched by recharge collection
      expect(Db.sales.length, 0);
    });
  });
}

