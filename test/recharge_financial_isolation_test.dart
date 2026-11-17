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
  const testShopId = 'SHOP_ISOLATION_TEST_01';
  final businessDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_fin_isolation_');
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
    // Initialize baseline ERP balances
    await Db.bank.put('cash_in_hand', 10000.0);
    await Db.bank.put('bank_balance', 50000.0);
  });

  group('TEKFIX ERP – Strict Financial Separation & Recharge Accounting Isolation', () {
    // -------------------------------------------------------------------------
    // FLOW 1: Customer Recharge using existing wallet balance
    // -------------------------------------------------------------------------
    test('Flow 1: Customer Recharge using existing wallet balance - Zero Cash/Bank/Sales delta', () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();
      final initialSalesCount = Db.sales.length;

      // Seed initial operator opening balance
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: businessDate,
        openingBalances: {
          RechargeOperator.jio: 2000.0,
          RechargeOperator.airtel: 1500.0,
          RechargeOperator.vi: 1000.0,
          RechargeOperator.bsnl: 500.0,
        },
        staffId: 'owner_1',
        staffName: 'Owner',
      );

      // Perform a customer cash recharge of ₹299 for Jio
      final recharge = RechargeEntry(
        rechargeId: 'REC_JIO_FLOW1_299',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9876543210',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.distributorCredit,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Staff Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: businessDate,
      );

      final result = await service.recordCustomerRechargePayment(recharge: recharge);

      // Record wallet debit in separate Recharge Accounting ledger
      await service.recordWalletLedgerEntryDirect(WalletLedgerEntry(
        txnId: 'LEDGER_DEBIT_REC_JIO_FLOW1_299',
        shopId: testShopId,
        walletId: 'WAL_JIO',
        operator: RechargeOperator.jio,
        fundingType: RechargeFundingType.distributorCredit,
        entryType: 'RECHARGE_DEBIT',
        amount: 299.0,
        amountPaise: 29900,
        balanceBeforePaise: 200000,
        balanceAfterPaise: 170100,
        referenceId: recharge.rechargeId,
        description: 'Customer recharge ₹299 Jio',
        staffId: 'staff_1',
        staffName: 'Staff Shahal',
        timestamp: DateTime.now(),
      ));

      // 1. Strict Isolation: Normal Cash and Bank balances MUST NOT increase
      final currentCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final currentBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(currentCash, initialCash,
          reason: 'Recharge transaction amount must NEVER be added to normal Cash in Hand');
      expect(currentBank, initialBank,
          reason: 'Recharge transaction amount must NEVER be added to normal Bank Balance');

      // 2. Strict Isolation: Normal POS sales MUST NOT increase
      expect(Db.sales.length, initialSalesCount,
          reason: 'Recharge principal must NEVER be recorded as normal retail sales');

      // 3. Recharge Accounting ledger maintains the transaction
      expect(result.financiallyPosted, isTrue);
      expect(result.summary.totalCollection, 299.0);
      expect(result.summary.getOperatorCollection(RechargeOperator.jio), 299.0);
    });

    // -------------------------------------------------------------------------
    // FLOW 2: Adding Lapu balance via distributor credit
    // -------------------------------------------------------------------------
    test('Flow 2: Adding Lapu balance (Credit) - Increases wallet float & payable, Zero Cash/Bank delta', () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      // Distributor provides ₹5,000 Lapu credit to Airtel wallet
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_AIRTEL_KERALA',
        amount: 5000.0,
        staffId: 'owner_1',
        staffName: 'Owner',
        notes: 'Stock top-up on credit',
      );

      // Normal Cash in Hand and Bank Balance MUST NOT change
      final currentCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final currentBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(currentCash, initialCash, reason: 'Lapu credit does not affect normal Cash in Hand');
      expect(currentBank, initialBank, reason: 'Lapu credit does not affect normal Bank Balance');

      // Distributor payable is tracked in separate distributor profiles
      final dist = await service.getDistributor(
        shopId: testShopId,
        distributorId: 'DIST_AIRTEL_KERALA',
      );
      expect(dist.totalCreditReceivedPaise, 500000);
      expect(dist.currentOutstanding, 5000.0);
    });

    // -------------------------------------------------------------------------
    // FLOW 3: Commission earned - Recognized as Recharge Income, not principal
    // -------------------------------------------------------------------------
    test('Flow 3: Commission earned - Recognized as pure commission income in integer paise', () async {
      // Record a commission entry of ₹8.97 (3.0% on ₹299)
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 8.97,
        status: CommissionStatus.received,
        settlementMethod: CommissionSettlementMethod.walletCredit,
        staffId: 'owner_1',
        staffName: 'Owner',
        dateString: businessDate,
      );

      final totals = await service.getRechargeAccountingTotals(
        shopId: testShopId,
        businessDate: businessDate,
      );

      // Verify Total Commission is recognized accurately
      expect(totals['totalRechargeCommission'], 8.97);
    });

    // -------------------------------------------------------------------------
    // FLOW 4: Failed recharge and refund
    // -------------------------------------------------------------------------
    test('Flow 4: Failed recharge & refund - Reverses wallet ledger without touching normal Cash/Bank', () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      final rec = RechargeEntry(
        rechargeId: 'REC_FAIL_FLOW4_499',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9846012345',
        amount: 499.0,
        amountPaise: 49900,
        fundingType: RechargeFundingType.distributorCredit,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Staff Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: businessDate,
      );

      await service.recordCustomerRechargePayment(recharge: rec);

      // Refund the recharge
      final refundResult = await service.refundOrReverseRecharge(
        shopId: testShopId,
        rechargeId: 'REC_FAIL_FLOW4_499',
        staffId: 'owner_1',
        staffName: 'Owner',
        reason: 'Operator failed, refunded',
      );

      expect(refundResult.reversed, isTrue);

      // Cash and Bank MUST remain strictly at initial values
      final currentCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final currentBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(currentCash, initialCash, reason: 'Normal Cash in Hand untouched by recharge/refund');
      expect(currentBank, initialBank, reason: 'Normal Bank Balance untouched by recharge/refund');
    });

    // -------------------------------------------------------------------------
    // FLOW 5: Distributor settlement
    // -------------------------------------------------------------------------
    test('Flow 5: Distributor settlement - Real payment reduces Bank/Cash and reduces distributor liability', () async {
      // First give distributor ₹5,000 credit
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_AIRTEL_KERALA',
        amount: 5000.0,
        staffId: 'owner_1',
        staffName: 'Owner',
      );

      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      // Pay distributor ₹4,000 via Bank
      const paymentAmount = 4000.0;
      await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: 'DIST_AIRTEL_KERALA',
        amount: paymentAmount,
        paymentMode: 'Bank',
        staffId: 'owner_1',
        staffName: 'Owner',
        staffRole: 'owner',
        notes: 'Partial settlement for Lapu credit',
      );

      // Normal Bank balance decreases by actual physical settlement payout
      final currentBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(currentBank, initialBank - paymentAmount,
          reason: 'Bank balance must reduce when physical money is transferred to distributor');

      // Distributor outstanding due reduces
      final dist = await service.getDistributor(
        shopId: testShopId,
        distributorId: 'DIST_AIRTEL_KERALA',
      );
      expect(dist.totalPaymentsMadePaise, 400000);
      expect(dist.currentOutstanding, 1000.0); // 5000 credit - 4000 paid = 1000 due
    });

    // -------------------------------------------------------------------------
    // REQUIREMENTS 3 & 4: Operator-Wise Columns & 3 Totals
    // -------------------------------------------------------------------------
    test('Requirements 3 & 4: Operator-wise columns & 3 distinct totals', () async {
      final testDate = businessDate;

      // Seed opening balances
      await service.recordMorningOpeningBalance(
        shopId: testShopId,
        businessDate: testDate,
        openingBalances: {
          RechargeOperator.airtel: 1000.0,
          RechargeOperator.jio: 2000.0,
          RechargeOperator.vi: 1500.0,
          RechargeOperator.bsnl: 800.0,
        },
        staffId: 'owner_1',
        staffName: 'Owner',
      );

      // Simulate recharges for each operator
      final recharges = [
        RechargeEntry(
          rechargeId: 'REC_OP_AIRTEL_199',
          shopId: testShopId,
          operator: RechargeOperator.airtel,
          amount: 199.0,
          amountPaise: 19900,
          fundingType: RechargeFundingType.distributorCredit,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          dateString: testDate,
        ),
        RechargeEntry(
          rechargeId: 'REC_OP_JIO_299',
          shopId: testShopId,
          operator: RechargeOperator.jio,
          amount: 299.0,
          amountPaise: 29900,
          fundingType: RechargeFundingType.distributorCredit,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          dateString: testDate,
        ),
        RechargeEntry(
          rechargeId: 'REC_OP_VI_149',
          shopId: testShopId,
          operator: RechargeOperator.vi,
          amount: 149.0,
          amountPaise: 14900,
          fundingType: RechargeFundingType.distributorCredit,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          dateString: testDate,
        ),
        RechargeEntry(
          rechargeId: 'REC_OP_BSNL_99',
          shopId: testShopId,
          operator: RechargeOperator.bsnl,
          amount: 99.0,
          amountPaise: 9900,
          fundingType: RechargeFundingType.distributorCredit,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          dateString: testDate,
        ),
      ];

      for (final r in recharges) {
        await service.recordCustomerRechargePayment(recharge: r);
        // Record ledger debits
        await service.recordWalletLedgerEntryDirect(WalletLedgerEntry(
          txnId: 'LEDGER_${r.rechargeId}',
          shopId: testShopId,
          walletId: RechargeService.getWalletId(r.operator),
          operator: r.operator,
          fundingType: r.fundingType,
          entryType: 'RECHARGE_DEBIT',
          amount: r.amount,
          amountPaise: r.amountPaise,
          balanceBeforePaise: 100000,
          balanceAfterPaise: 100000 - r.amountPaise,
          referenceId: r.rechargeId,
          description: 'Recharge ${r.operator.name}',
          staffId: 'staff_1',
          staffName: 'Shahal',
          timestamp: DateTime.now(),
        ));
      }

      // Record commission for Airtel
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 5.0,
        status: CommissionStatus.received,
        settlementMethod: CommissionSettlementMethod.walletCredit,
        staffId: 'owner_1',
        staffName: 'Owner',
        dateString: testDate,
      );

      // Fetch Reconciliation Record
      final rec = await service.calculateAutomaticReconciliation(
        shopId: testShopId,
        businessDate: testDate,
      );

      // Verify 4 Operator-wise Recharge Amount columns
      expect(rec.airtelRechargeAmount, 199.0);
      expect(rec.jioRechargeAmount, 299.0);
      expect(rec.viRechargeAmount, 149.0);
      expect(rec.bsnlRechargeAmount, 99.0);

      // Verify the 3 Separate Totals
      // 1. Total Recharge Amount = 199 + 299 + 149 + 99 = 746.00
      expect(rec.totalRechargeAmount, 746.0);
      // 2. Total Recharge Wallet Balance = Expected closing balances of the 4 operators
      // Airtel: 1000 - 199 = 801
      // Jio: 2000 - 299 = 1701
      // Vi: 1500 - 149 = 1351
      // BSNL: 800 - 99 = 701
      // Total = 801 + 1701 + 1351 + 701 = 4554.00
      expect(rec.totalRechargeWalletBalance, 4554.0);
      // 3. Total Recharge Commission (Actual Income Only) = 5.00
      expect(rec.totalRechargeCommission, 5.0);

      // Verify helper method getOperatorRechargeAmounts
      final opAmounts = await service.getOperatorRechargeAmounts(
        shopId: testShopId,
        businessDate: testDate,
      );
      expect(opAmounts['Airtel'], 199.0);
      expect(opAmounts['Jio'], 299.0);
      expect(opAmounts['Vi'], 149.0);
      expect(opAmounts['BSNL'], 99.0);
    });
  });
}
