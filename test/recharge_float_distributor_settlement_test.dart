import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TEKFIX ERP - Phase 5: Distributor Settlement & Float Recovery', () {
    late Directory tempDir;
    const testShopId = 'test_shop_tekfix';
    final service = RechargeService.instance;

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('float_settle_test_');
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
      await Db.expenses.clear();

      // Establish standard retail float baseline
      await Db.bank.put('cash_in_hand', 5000.0); // Baseline cash drawer: ₹5,000
      await Db.bank.put('bank_balance', 20000.0); // Baseline bank balance: ₹20,000
      await Db.bank.put('txn_log', <Map<String, dynamic>>[]);
    });

    // -------------------------------------------------------------------------
    // TEST 1: Distributor payable ₹5,000 -> Pay ₹1,000 Cash -> Remaining ₹4,000
    // -------------------------------------------------------------------------
    test(
        'TEST 1: Distributor payable ₹5,000. Pay ₹1,000 cash. Remaining payable must be ₹4,000.',
        () async {
      const distId = 'DIST_APEX_AIRTEL';
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();

      // Setup initial credit liability of ₹5,000
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: distId,
        amount: 5000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      final distBefore = await service.getDistributor(
        shopId: testShopId,
        distributorId: distId,
      );
      expect(distBefore.currentOutstanding, 5000.0);

      // Execute ₹1,000 Cash Payment
      final result = await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: distId,
        amount: 1000.0,
        paymentMode: 'CASH',
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'PAY_CASH_1000',
        notes: 'Partial settlement to Apex agent in cash',
      );

      // Verify Distributor Liability Reduced
      expect(result.distributor.currentOutstanding, 4000.0);
      expect(result.distributor.currentOutstandingPaise, 400000);
      expect(result.distributor.totalPaymentsMade, 1000.0);
      expect(result.isFullSettlement, isFalse);

      // Verify Physical Cash Drawer Deducted
      final updatedCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(updatedCash, initialCash - 1000.0,
          reason: 'Physical cash drawer must decrease by ₹1,000');

      // Verify Receipt Details
      expect(result.receipt.amount, 1000.0);
      expect(result.receipt.previousOutstanding, 5000.0);
      expect(result.receipt.remainingOutstanding, 4000.0);
      expect(result.receipt.paymentMode, 'CASH');
    });

    // -------------------------------------------------------------------------
    // TEST 2: Pay remaining ₹4,000 through UPI -> Outstanding must become zero
    // -------------------------------------------------------------------------
    test(
        'TEST 2: Pay remaining ₹4,000 through UPI. Outstanding must become zero.',
        () async {
      const distId = 'DIST_APEX_AIRTEL';

      // Setup ₹5,000 liability and pay ₹1,000 partial
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: distId,
        amount: 5000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );
      await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: distId,
        amount: 1000.0,
        paymentMode: 'CASH',
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      // Pay remaining ₹4,000 via UPI
      final fullResult = await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: distId,
        amount: 4000.0,
        paymentMode: 'UPI',
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'PAY_UPI_4000',
        notes: 'Full settlement via Google Pay UPI',
      );

      // Verify Outstanding Becomes Exactly Zero
      expect(fullResult.isFullSettlement, isTrue);
      expect(fullResult.distributor.currentOutstanding, 0.0);
      expect(fullResult.distributor.currentOutstandingPaise, 0);
      expect(fullResult.distributor.totalPaymentsMade, 5000.0);

      // Verify UPI / Bank Balance Deducted
      final updatedBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(updatedBank, initialBank - 4000.0,
          reason: 'Bank balance must decrease by UPI payment of ₹4,000');

      expect(fullResult.receipt.remainingOutstanding, 0.0);
    });

    // -------------------------------------------------------------------------
    // TEST 3: Recharge cash ₹3,000. Deposit ₹2,000 to bank. Remaining = ₹1,000
    // -------------------------------------------------------------------------
    test(
        'TEST 3: Recharge cash ₹3,000. Deposit ₹2,000 into bank. Remaining recharge cash must be ₹1,000.',
        () async {
      // 1. Simulate ₹3,000 Customer Cash Recharge Collection
      final cashRecharge = RechargeEntry(
        rechargeId: 'REC_COLL_3000',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 3000.0,
        amountPaise: 300000,
        fundingType: RechargeFundingType.distributorCredit,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime(2026, 11, 7, 10, 0),
        updatedAt: DateTime(2026, 11, 7, 10, 0),
        dateString: '2026-11-07',
      );

      await service.recordCustomerRechargePayment(recharge: cashRecharge);

      final cashBeforeDeposit = (Db.bank.get('cash_in_hand') as num).toDouble();
      final bankBeforeDeposit = (Db.bank.get('bank_balance') as num).toDouble();

      // 2. Deposit ₹2,000 of Recharge Cash into Bank (Contra Entry)
      final depositResult = await service.recordRechargeFloatDeposit(
        shopId: testShopId,
        depositType: FloatDepositType.cashDeposit,
        amount: 2000.0,
        bankAccountId: 'PRIMARY_STORE_BANK',
        bankAccountName: 'State Bank of India (Shop Current A/C)',
        staffId: 'staff_1',
        staffName: 'Shahal',
        dateString: '2026-11-07',
        referenceNumber: 'SLIP_SBI_2000',
        notes: 'Cash collected from recharges deposited to SBI',
        isConfirmed: true,
      );

      // A. Physical Cash: -₹2,000
      final cashAfterDeposit = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(cashAfterDeposit, cashBeforeDeposit - 2000.0,
          reason: 'Physical drawer cash must reduce by ₹2,000 deposited to bank');

      // B. Bank Balance: +₹2,000
      final bankAfterDeposit = (Db.bank.get('bank_balance') as num).toDouble();
      expect(bankAfterDeposit, bankBeforeDeposit + 2000.0,
          reason: 'Bank account must receive ₹2,000 cash deposit');

      // C. Float Summary Metrics
      expect(depositResult.summary.rechargeCashAvailable, 3000.0);
      expect(depositResult.summary.rechargeCashDeposited, 2000.0);
      expect(depositResult.summary.rechargeCashRemaining, 1000.0);
    });

    // -------------------------------------------------------------------------
    // TEST 4: Distributor payment does NOT appear as business expense
    // -------------------------------------------------------------------------
    test(
        'TEST 4: Verify distributor payment does not appear as normal business expense.',
        () async {
      final initialExpensesCount = Db.expenses.length;

      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        distributorId: 'DIST_MURUGAN_VI',
        amount: 3000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: 'DIST_MURUGAN_VI',
        amount: 1500.0,
        paymentMode: 'CASH',
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Db.expenses must remain strictly 0
      expect(Db.expenses.length, initialExpensesCount,
          reason:
              'Paying trade debt to distributor is an asset/liability movement, NEVER an operational business expense');
    });

    // -------------------------------------------------------------------------
    // TEST 5: Bank deposit does NOT appear as business income
    // -------------------------------------------------------------------------
    test(
        'TEST 5: Verify bank deposit does not appear as business income.',
        () async {
      final initialSalesCount = Db.sales.length;

      await service.recordRechargeFloatDeposit(
        shopId: testShopId,
        depositType: FloatDepositType.cashDeposit,
        amount: 1000.0,
        bankAccountId: 'PRIMARY_STORE_BANK',
        bankAccountName: 'Store Bank',
        staffId: 'staff_1',
        staffName: 'Shahal',
        isConfirmed: true,
      );

      // Db.sales must remain strictly 0
      expect(Db.sales.length, initialSalesCount,
          reason:
              'Bank cash deposit is an internal fund transfer (Contra Entry), NEVER retail sales revenue');
    });

    // -------------------------------------------------------------------------
    // TEST 6: Prevent duplicate cash deductions
    // -------------------------------------------------------------------------
    test('TEST 6: Verify no duplicate cash deductions.', () async {
      final baselineCash = (Db.bank.get('cash_in_hand') as num).toDouble();

      // A. Planned / unconfirmed deposit must NOT reduce physical cash
      await service.recordRechargeFloatDeposit(
        shopId: testShopId,
        depositType: FloatDepositType.cashDeposit,
        amount: 1500.0,
        bankAccountId: 'PRIMARY_STORE_BANK',
        bankAccountName: 'Store Bank',
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'DEP_PLANNED_1500',
        isConfirmed: false, // Planned only!
      );

      expect((Db.bank.get('cash_in_hand') as num).toDouble(), baselineCash,
          reason: 'Unconfirmed planned deposits must NEVER deduct cash');

      // B. Duplicate deposit submission is blocked
      expect(
        () => service.recordRechargeFloatDeposit(
          shopId: testShopId,
          depositType: FloatDepositType.cashDeposit,
          amount: 1500.0,
          bankAccountId: 'PRIMARY_STORE_BANK',
          bankAccountName: 'Store Bank',
          staffId: 'staff_1',
          staffName: 'Shahal',
          referenceNumber: 'DEP_PLANNED_1500', // duplicate reference
          isConfirmed: true,
        ),
        throwsA(isA<Exception>()),
      );

      // C. Duplicate distributor payment submission is blocked
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 2000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 500.0,
        paymentMode: 'CASH',
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'PAY_IDEMPOTENT_001',
      );

      // Attempting exact same payment ID again
      expect(
        () => service.recordDistributorPayment(
          shopId: testShopId,
          distributorId: 'DIST_APEX_AIRTEL',
          amount: 500.0,
          paymentMode: 'CASH',
          staffId: 'staff_1',
          staffName: 'Shahal',
          referenceNumber: 'PAY_IDEMPOTENT_001',
        ),
        throwsA(isA<Exception>()),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 7: Role Security & Authorization Enforcement
    // -------------------------------------------------------------------------
    test('TEST 7: Security: Unauthorized staff blocked from financial settlement',
        () async {
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 2000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Staff role without owner permissions is rejected
      expect(
        () => service.recordDistributorPayment(
          shopId: testShopId,
          distributorId: 'DIST_APEX_AIRTEL',
          amount: 500.0,
          paymentMode: 'CASH',
          staffId: 'unauthorized_staff',
          staffName: 'Trainee',
          staffRole: 'trainee_staff',
        ),
        throwsA(isA<Exception>()),
      );

      expect(
        () => service.recordRechargeFloatDeposit(
          shopId: testShopId,
          depositType: FloatDepositType.cashDeposit,
          amount: 500.0,
          bankAccountId: 'PRIMARY_STORE_BANK',
          bankAccountName: 'Store Bank',
          staffId: 'unauthorized_staff',
          staffName: 'Trainee',
          staffRole: 'trainee_staff',
        ),
        throwsA(isA<Exception>()),
      );

      // Owner role succeeds
      final ownerRes = await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 500.0,
        paymentMode: 'CASH',
        staffId: 'owner_user',
        staffName: 'Shop Owner',
        staffRole: 'owner',
      );
      expect(ownerRes.distributor.currentOutstanding, 1500.0);
    });
  });
}

