import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = RechargeService.instance;
  const testShopId = 'SHOP_AGENT_SETTLEMENT_TEST';
  late Directory tempDir;

  setUpAll(() async {
    // v2.1: the old client-side postings run only in localTestMock.
    RechargeBackendBridge.configure(mode: RechargeBackendMode.localTestMock);
    tempDir = await Directory.systemTemp.createTemp('tekfix_agent_settle_');
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
    // Baseline Store Cash & Bank Balances
    await Db.bank.put('cash_in_hand', 10000.0);
    await Db.bank.put('bank_balance', 50000.0);
  });

  group('TEKFIX ERP – Operator Agent Settlement & Return Workflow Tests', () {
    // -------------------------------------------------------------------------
    // TEST 1: Agent Settlement (Payable ₹1,000; Adj ₹500; Actual Cash Outflow ₹500)
    // -------------------------------------------------------------------------
    test('1. Agent Settlement: Total payable ₹1,000; recharge adjustment ₹500; actual Cash payment ₹500', () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      // Setup distributor with ₹1,000 credit stock delivered
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_AIRTEL_KERALA',
        amount: 1000.0,
        staffId: 'owner_1',
        staffName: 'Owner Shahal',
        notes: 'Stock delivery ₹1,000',
      );

      final distBefore = await service.getDistributor(
        shopId: testShopId,
        distributorId: 'DIST_AIRTEL_KERALA',
      );
      expect(distBefore.currentOutstanding, 1000.0);
      expect(distBefore.pendingReturn, 0.0);

      // Execute Agent Settlement:
      // Total Payable = ₹1,000
      // Recharge Adjustment = ₹500
      // Actual Cash Paid = ₹500
      final result = await service.recordAgentSettlement(
        shopId: testShopId,
        distributorId: 'DIST_AIRTEL_KERALA',
        totalPayable: 1000.0,
        rechargeAdjustment: 500.0,
        paymentMode: 'CASH',
        staffId: 'owner_1',
        staffName: 'Owner Shahal',
        staffRole: 'owner',
        notes: 'Monthly settlement with Airtel distributor',
      );

      // A. Verify Settlement Return Values
      expect(result.actualPayment, 500.0);
      expect(result.rechargeAdjustment, 500.0);
      expect(result.pendingReturn, 500.0);
      expect(result.isFullSettlement, isTrue);

      // B. Verify Store Cash in Hand: ONLY actual payment ₹500 deducted (NOT ₹1,000)
      final currentCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final currentBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(currentCash, initialCash - 500.0,
          reason: 'Cash in Hand must decrease strictly by actual payment ₹500, not total ₹1,000');
      expect(currentBank, initialBank,
          reason: 'Bank balance must remain completely untouched for cash settlement');

      // C. Verify Distributor State
      final distAfter = await service.getDistributor(
        shopId: testShopId,
        distributorId: 'DIST_AIRTEL_KERALA',
      );
      expect(distAfter.currentOutstanding, 0.0,
          reason: 'Distributor outstanding payable is fully cleared (₹1,000 settled)');
      expect(distAfter.totalPaymentsMade, 500.0);
      expect(distAfter.totalAdjustmentsPaise, 50000);
      expect(distAfter.pendingReturn, 500.0,
          reason: 'Pending recharge return from agent must record ₹500');

      // D. Verify Immutable Ledger Entry
      expect(result.entry.entryType, 'AGENT_SETTLEMENT');
      expect(result.entry.amount, 1000.0);
      expect(result.entry.rechargeAdjustment, 500.0);
      expect(result.entry.actualPayment, 500.0);
      expect(result.entry.pendingReturnAfter, 500.0);
    });

    // -------------------------------------------------------------------------
    // TEST 2: Recharge Amount Return (Agent returns ₹500 -> Credited to Cash in Hand)
    // -------------------------------------------------------------------------
    test('2. Recharge Amount Return: Credit ₹500 back to Cash in Hand and clear pending return', () async {
      // 1. Setup distributor and execute initial settlement creating ₹500 pending return
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_AIRTEL_KERALA',
        amount: 1000.0,
        staffId: 'owner_1',
        staffName: 'Owner Shahal',
      );

      await service.recordAgentSettlement(
        shopId: testShopId,
        distributorId: 'DIST_AIRTEL_KERALA',
        totalPayable: 1000.0,
        rechargeAdjustment: 500.0,
        paymentMode: 'CASH',
        staffId: 'owner_1',
        staffName: 'Owner Shahal',
        staffRole: 'owner',
      );

      final cashBeforeReturn = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(cashBeforeReturn, 9500.0);

      // 2. Agent returns ₹500 in Cash
      final returnResult = await service.recordRechargeAmountReturn(
        shopId: testShopId,
        distributorId: 'DIST_AIRTEL_KERALA',
        returnAmount: 500.0,
        returnMode: 'CASH',
        staffId: 'owner_1',
        staffName: 'Owner Shahal',
        staffRole: 'owner',
        notes: 'Airtel agent returned ₹500 recharge adjustment',
      );

      // A. Verify Return Results
      expect(returnResult.returnedAmount, 500.0);
      expect(returnResult.remainingPendingReturn, 0.0);

      // B. Verify Cash in Hand is credited back by ₹500
      final cashAfterReturn = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(cashAfterReturn, 10000.0,
          reason: 'Cash in Hand must increase by ₹500 returning to initial ₹10,000');

      // C. Verify Distributor Pending Return is cleared to ₹0
      final distAfterReturn = await service.getDistributor(
        shopId: testShopId,
        distributorId: 'DIST_AIRTEL_KERALA',
      );
      expect(distAfterReturn.pendingReturn, 0.0,
          reason: 'Pending return must be completely cleared');

      // D. Verify Immutable Ledger Entry
      expect(returnResult.entry.entryType, 'RECHARGE_AMOUNT_RETURN');
      expect(returnResult.entry.amount, 500.0);
      expect(returnResult.entry.pendingReturnBefore, 500.0);
      expect(returnResult.entry.pendingReturnAfter, 0.0);
    });

    // -------------------------------------------------------------------------
    // TEST 3: Recharge Amount Return to Bank Account
    // -------------------------------------------------------------------------
    test('3. Recharge Amount Return: Credit ₹500 back to Bank Account', () async {
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        distributorId: 'DIST_SPEED_JIO',
        amount: 2000.0,
        staffId: 'owner_1',
        staffName: 'Owner Shahal',
      );

      // Settle ₹2000 with ₹500 recharge adjustment via Bank
      await service.recordAgentSettlement(
        shopId: testShopId,
        distributorId: 'DIST_SPEED_JIO',
        totalPayable: 2000.0,
        rechargeAdjustment: 500.0,
        paymentMode: 'BANK',
        staffId: 'owner_1',
        staffName: 'Owner Shahal',
        staffRole: 'owner',
      );

      final bankBeforeReturn = (Db.bank.get('bank_balance') as num).toDouble();
      expect(bankBeforeReturn, 48500.0); // 50000 - 1500 actual payment

      // Agent returns ₹500 to Bank Account via UPI/NEFT
      await service.recordRechargeAmountReturn(
        shopId: testShopId,
        distributorId: 'DIST_SPEED_JIO',
        returnAmount: 500.0,
        returnMode: 'BANK',
        staffId: 'owner_1',
        staffName: 'Owner Shahal',
        staffRole: 'owner',
        selectedBankAccountId: 'PRIMARY_STORE_BANK',
      );

      final bankAfterReturn = (Db.bank.get('bank_balance') as num).toDouble();
      expect(bankAfterReturn, 49000.0, // 48500 + 500 credited back
          reason: 'Bank balance must increase by ₹500 returned by agent');

      final distJio = await service.getDistributor(
        shopId: testShopId,
        distributorId: 'DIST_SPEED_JIO',
      );
      expect(distJio.pendingReturn, 0.0);
    });

    // -------------------------------------------------------------------------
    // TEST 4: Pending Return Tracking Across All Four Operators / Agents
    // -------------------------------------------------------------------------
    test('4. Pending Return: Show remaining recharge amount pending from each operator/agent', () async {
      // 1. Create settlements with adjustments across operators:
      // Airtel: ₹500 adjustment
      // Jio: ₹300 adjustment
      // Vi: ₹200 adjustment
      // BSNL: ₹150 adjustment

      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 1500.0,
        staffId: 'owner_1',
        staffName: 'Owner',
      );
      await service.recordAgentSettlement(
        shopId: testShopId,
        distributorId: 'DIST_APEX_AIRTEL',
        totalPayable: 1000.0,
        rechargeAdjustment: 500.0,
        paymentMode: 'CASH',
        staffId: 'owner_1',
        staffName: 'Owner',
        staffRole: 'owner',
      );

      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        distributorId: 'DIST_SPEED_JIO',
        amount: 1000.0,
        staffId: 'owner_1',
        staffName: 'Owner',
      );
      await service.recordAgentSettlement(
        shopId: testShopId,
        distributorId: 'DIST_SPEED_JIO',
        totalPayable: 800.0,
        rechargeAdjustment: 300.0,
        paymentMode: 'CASH',
        staffId: 'owner_1',
        staffName: 'Owner',
        staffRole: 'owner',
      );

      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        distributorId: 'DIST_SMART_VI',
        amount: 500.0,
        staffId: 'owner_1',
        staffName: 'Owner',
      );
      await service.recordAgentSettlement(
        shopId: testShopId,
        distributorId: 'DIST_SMART_VI',
        totalPayable: 500.0,
        rechargeAdjustment: 200.0,
        paymentMode: 'CASH',
        staffId: 'owner_1',
        staffName: 'Owner',
        staffRole: 'owner',
      );

      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.bsnl,
        distributorId: 'DIST_METRO_BSNL',
        amount: 300.0,
        staffId: 'owner_1',
        staffName: 'Owner',
      );
      await service.recordAgentSettlement(
        shopId: testShopId,
        distributorId: 'DIST_METRO_BSNL',
        totalPayable: 300.0,
        rechargeAdjustment: 150.0,
        paymentMode: 'CASH',
        staffId: 'owner_1',
        staffName: 'Owner',
        staffRole: 'owner',
      );

      // 2. Fetch pending return summary across all agents
      final summary = await service.getAgentPendingReturnsSummary(shopId: testShopId);

      // Verify Operator-wise Pending Returns:
      // Airtel: ₹500
      // Jio: ₹300
      // Vi: ₹200
      // BSNL: ₹150
      expect(summary.getOperatorPendingReturn(RechargeOperator.airtel), 500.0);
      expect(summary.getOperatorPendingReturn(RechargeOperator.jio), 300.0);
      expect(summary.getOperatorPendingReturn(RechargeOperator.vi), 200.0);
      expect(summary.getOperatorPendingReturn(RechargeOperator.bsnl), 150.0);

      // Total Pending Return = 500 + 300 + 200 + 150 = 1,150.00
      expect(summary.totalPendingReturn, 1150.0);
      expect(summary.totalPendingReturnPaise, 115000);

      // 3. Partial return from Airtel agent (₹300 returned out of ₹500)
      await service.recordRechargeAmountReturn(
        shopId: testShopId,
        distributorId: 'DIST_APEX_AIRTEL',
        returnAmount: 300.0,
        returnMode: 'CASH',
        staffId: 'owner_1',
        staffName: 'Owner',
        staffRole: 'owner',
      );

      final updatedSummary = await service.getAgentPendingReturnsSummary(shopId: testShopId);
      expect(updatedSummary.getOperatorPendingReturn(RechargeOperator.airtel), 200.0,
          reason: 'Airtel agent pending return should reduce from ₹500 to ₹200');
      expect(updatedSummary.totalPendingReturn, 850.0,
          reason: 'Total pending return should reduce from ₹1,150 to ₹850');
    });

    // -------------------------------------------------------------------------
    // TEST 5: Validation Rules & Security Enforcement
    // -------------------------------------------------------------------------
    test('5. Security & Validation: Invalid adjustments, negative values, and staff restrictions blocked', () async {
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 500.0,
        staffId: 'owner_1',
        staffName: 'Owner',
      );

      // A. Recharge adjustment exceeds total payable -> throws ArgumentError
      expect(
        () => service.recordAgentSettlement(
          shopId: testShopId,
          distributorId: 'DIST_APEX_AIRTEL',
          totalPayable: 500.0,
          rechargeAdjustment: 600.0,
          paymentMode: 'CASH',
          staffId: 'owner_1',
          staffName: 'Owner',
          staffRole: 'owner',
        ),
        throwsArgumentError,
      );

      // B. Negative total payable -> throws ArgumentError
      expect(
        () => service.recordAgentSettlement(
          shopId: testShopId,
          distributorId: 'DIST_APEX_AIRTEL',
          totalPayable: -100.0,
          rechargeAdjustment: 50.0,
          paymentMode: 'CASH',
          staffId: 'owner_1',
          staffName: 'Owner',
          staffRole: 'owner',
        ),
        throwsArgumentError,
      );

      // C. Negative return amount -> throws ArgumentError
      expect(
        () => service.recordRechargeAmountReturn(
          shopId: testShopId,
          distributorId: 'DIST_APEX_AIRTEL',
          returnAmount: -50.0,
          returnMode: 'CASH',
          staffId: 'owner_1',
          staffName: 'Owner',
          staffRole: 'owner',
        ),
        throwsArgumentError,
      );

      // D. Unauthorized staff role -> throws Exception
      expect(
        () => service.recordAgentSettlement(
          shopId: testShopId,
          distributorId: 'DIST_APEX_AIRTEL',
          totalPayable: 500.0,
          rechargeAdjustment: 200.0,
          paymentMode: 'CASH',
          staffId: 'staff_1',
          staffName: 'Staff Shahal',
          staffRole: 'staff',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
