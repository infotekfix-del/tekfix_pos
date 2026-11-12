import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_recovery_engine.dart';
import 'package:tekfix_erp_pos/security/device_security_service.dart';
import 'package:tekfix_erp_pos/security/staging_identity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase16_4_1_evidence_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      if (!Hive.isBoxOpen(b)) await Hive.openBox(b);
    }
  });

  tearDownAll(() async {
    try {
      await Hive.close().timeout(const Duration(seconds: 2), onTimeout: () => null);
    } catch (_) {}
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  setUp(() async {
    for (final b in allBoxes) {
      if (Hive.isBoxOpen(b)) await Hive.box(b).clear();
    }
    final auth = AuthController.instance;
    await auth.signIn(
      StagingIdentityService.defaultShopId,
      'staging-owner@tekfix.internal',
      AuthController.defaultStagingPassword,
    );
    final sec = DeviceSecurityService.instance;
    await sec.init();
    await sec.setEnrolledLocally(true);
  });

  group('Phase 16.4.1 Evidence Verification Suite', () {
    // ------------------------------------------------------------------------
    // 1. Isolated Staging Backup & Restore Test
    // ------------------------------------------------------------------------
    test('1. Isolated Staging Backup & Restore Test verifies Cash, Bank, Receivables, History, and Recovery Journal', () async {
      print('\n--- BACKUP & RESTORE VERIFICATION START ---');

      // Seed 1: Cash and Bank
      await Db.bank.put('cash_in_hand', 18450.50);
      await Db.bank.put('bank_balance', 92300.75);
      await Db.bank.put('txn_log', [
        {
          'date': '2026-11-11T12:00:00.000',
          'account': 'Cash',
          'amount': 500.0,
          'note': 'Test Cash Opening (Txn: TXN_INIT_CASH)',
        },
        {
          'date': '2026-11-11T12:05:00.000',
          'account': 'Bank',
          'amount': 1000.0,
          'note': 'Test Bank Opening (Txn: TXN_INIT_BANK)',
        }
      ]);

      // Seed 2: Customer Receivables
      final custKey = await Db.parties.add({
        'name': 'Fathima Electronics',
        'phone': '9847123456',
        'balance': 1420.00,
        'type': 'customer',
      });

      // Seed 3: Recharge History
      const histTxnKey = 'TXN_RECHARGE_HIST_9981';
      await Db.recharges.put(histTxnKey, {
        'txnKey': histTxnKey,
        'mobile': '9847998877',
        'operator': 'Jio',
        'amount': 299.0,
        'costPrice': 290.03,
        'commission': 8.97,
        'paymentMode': 'Cash',
        'timestamp': '2026-11-11T15:30:00.000',
        'status': 'SUCCESS',
      });

      // Seed 4: Pending Recovery Journal
      const pendingKey = 'TXN_PENDING_QUEUE_4412';
      await Db.rechargeQueue.put(pendingKey, {
        'idempotencyKey': pendingKey,
        'shopId': StagingIdentityService.defaultShopId,
        'ownerUid': 'owner_staging_001',
        'deviceId': 'DEV_TEST_001',
        'mobile': '9995112233',
        'operator': 'Airtel',
        'serviceType': 'Prepaid',
        'retailAmount': 479.0,
        'costPrice': 465.0,
        'paymentMode': 'UPI',
        'status': RechargeRecoveryEngine.statusServerConfirmed,
        'upstreamTxnId': 'UPSTREAM_REF_4412',
        'timestamp': DateTime.now().toIso8601String(),
      });

      print('[PRE-BACKUP STATE]');
      print('  Cash in Hand: ₹${Db.cash}');
      print('  Bank Balance: ₹${Db.bankBalance}');
      print('  Customer Receivable: ${Db.parties.get(custKey)['name']} -> ₹${Db.parties.get(custKey)['balance']}');
      print('  Recharge History Keys: ${Db.recharges.keys.toList()}');
      print('  Pending Journal Keys: ${Db.rechargeQueue.keys.toList()}');

      // Execute Export
      final backupJson = Db.exportAll();
      expect(backupJson.isNotEmpty, isTrue);
      print('  Generated Backup Size: ${backupJson.length} bytes');

      // Wipe all boxes to simulate a blank machine or destroyed storage
      for (final b in allBoxes) {
        if (Hive.isBoxOpen(b) && b != boxSyncQueue) await Hive.box(b).clear();
      }

      print('\n[POST-WIPE BLANK STATE]');
      print('  Cash in Hand: ₹${Db.cash}');
      print('  Bank Balance: ₹${Db.bankBalance}');
      print('  Customer Records: ${Db.parties.length}');
      print('  Recharge History Records: ${Db.recharges.length}');
      print('  Pending Queue Records: ${Db.rechargeQueue.length}');

      expect(Db.cash, equals(0.0));
      expect(Db.bankBalance, equals(0.0));
      expect(Db.parties.isEmpty, isTrue);
      expect(Db.recharges.isEmpty, isTrue);
      expect(Db.rechargeQueue.isEmpty, isTrue);

      // Execute Restore
      final recordCount = await Db.importAll(backupJson);
      print('\n[POST-RESTORE VERIFICATION]');
      print('  Restored Records Count: $recordCount');
      print('  Restored Cash: ₹${Db.cash}');
      print('  Restored Bank Balance: ₹${Db.bankBalance}');
      print('  Restored Customer: ${Db.parties.get(custKey)['name']} -> ₹${Db.parties.get(custKey)['balance']}');
      print('  Restored Recharge History: ${Db.recharges.get(histTxnKey)['mobile']} (₹${Db.recharges.get(histTxnKey)['amount']})');
      print('  Restored Pending Queue: ${Db.rechargeQueue.get(pendingKey)['mobile']} (Status: ${Db.rechargeQueue.get(pendingKey)['status']})');

      // Assertions
      expect(Db.cash, equals(18450.50));
      expect(Db.bankBalance, equals(92300.75));
      expect(Db.parties.get(custKey)['name'], equals('Fathima Electronics'));
      expect(Db.parties.get(custKey)['balance'], equals(1420.00));
      expect(Db.recharges.get(histTxnKey)['status'], equals('SUCCESS'));
      expect(Db.rechargeQueue.get(pendingKey)['status'], equals(RechargeRecoveryEngine.statusServerConfirmed));
      print('--- BACKUP & RESTORE VERIFICATION COMPLETE: ALL 5 ENTITIES RESTORED WITH 100% FIDELITY ---\n');
    });

    // ------------------------------------------------------------------------
    // 2. Financial Recovery: 5 Crash Tests with Before/After Ledgers & Txn IDs
    // ------------------------------------------------------------------------
    test('2. Financial Recovery: 5 Crash Scenarios with Exact Before/After Balances & Transaction IDs', () async {
      print('\n--- 5 FINANCIAL RECOVERY CRASH DRILLS START ---');

      // SCENARIO 1: Server Confirmed, Cash Not Moved, Interrupted before Settlement
      print('\n[CRASH DRILL 1] Server Confirmed Debit, Crash Before Local Settlement');
      const txn1 = 'TXN_CRASH_DRILL_01';
      await Db.bank.put('cash_in_hand', 5000.0);
      print('  Before Recovery Cash: ₹${Db.bank.get('cash_in_hand')}');
      print('  Before Recovery Db.recharges: ${Db.recharges.containsKey(txn1)}');

      await RechargeRecoveryEngine.recordPendingIntent(
        idempotencyKey: txn1,
        shopId: StagingIdentityService.defaultShopId,
        ownerUid: 'owner_staging_001',
        deviceId: 'DEV_WIN_001',
        mobile: '9847111001',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Cash',
      );
      await RechargeRecoveryEngine.markServerConfirmed(txn1, 'UPSTREAM_DEBIT_01');

      final rec1 = await RechargeRecoveryEngine.reconcilePendingSettlements();
      print('  Reconciliation Count: $rec1');
      print('  After Recovery Cash: ₹${Db.bank.get('cash_in_hand')} (Expected: 5299.0)');
      print('  After Recovery Db.recharges: ${Db.recharges.containsKey(txn1)}');
      print('  After Recovery Outbox Cleared: ${!Db.rechargeQueue.containsKey(txn1)}');
      expect(Db.bank.get('cash_in_hand'), equals(5299.0));
      expect(Db.recharges.containsKey(txn1), isTrue);

      // SCENARIO 2: Cash Moved, Crash Before Db.recharges Write
      print('\n[CRASH DRILL 2] Cash Already Moved, Crash Before History Log');
      const txn2 = 'TXN_CRASH_DRILL_02';
      final cashBefore2 = Db.bank.get('cash_in_hand') as double;
      print('  Before Drill Cash: ₹$cashBefore2');

      await RechargeRecoveryEngine.recordPendingIntent(
        idempotencyKey: txn2,
        shopId: StagingIdentityService.defaultShopId,
        ownerUid: 'owner_staging_001',
        deviceId: 'DEV_WIN_001',
        mobile: '9847111002',
        operator: 'Airtel',
        serviceType: 'Prepaid',
        retailAmount: 199.0,
        costPrice: 193.0,
        paymentMode: 'Cash',
      );
      await RechargeRecoveryEngine.markServerConfirmed(txn2, 'UPSTREAM_DEBIT_02');
      // Simulate partial write where cash was already moved
      await Db.moveMoney('Cash', 199.0, 'Recharge Sale: Airtel 9847111002 (Txn: $txn2)');
      await RechargeRecoveryEngine.markMoneySettled(txn2);
      final cashMid2 = Db.bank.get('cash_in_hand') as double;
      print('  Mid-Crash Cash (Moved Once): ₹$cashMid2');

      final rec2 = await RechargeRecoveryEngine.reconcilePendingSettlements();
      final cashAfter2 = Db.bank.get('cash_in_hand') as double;
      print('  Reconciliation Count: $rec2');
      print('  After Recovery Cash: ₹$cashAfter2 (Must NOT double-credit to ${cashMid2 + 199.0})');
      expect(cashAfter2, equals(cashMid2)); // STRICT ZERO DOUBLE-MOVE
      expect(Db.recharges.containsKey(txn2), isTrue);

      // SCENARIO 3: Bank Moved, Crash Before Db.recharges Write
      print('\n[CRASH DRILL 3] UPI Bank Already Moved, Crash Before History Log');
      const txn3 = 'TXN_CRASH_DRILL_03';
      await Db.bank.put('bank_balance', 10000.0);
      print('  Before Drill Bank: ₹${Db.bank.get('bank_balance')}');

      await RechargeRecoveryEngine.recordPendingIntent(
        idempotencyKey: txn3,
        shopId: StagingIdentityService.defaultShopId,
        ownerUid: 'owner_staging_001',
        deviceId: 'DEV_WIN_001',
        mobile: '9847111003',
        operator: 'Vi',
        serviceType: 'Prepaid',
        retailAmount: 666.0,
        costPrice: 647.35,
        paymentMode: 'UPI',
      );
      await RechargeRecoveryEngine.markServerConfirmed(txn3, 'UPSTREAM_DEBIT_03');
      await Db.moveMoney('Bank', 666.0, 'Recharge UPI: Vi 9847111003 (Txn: $txn3)');
      await RechargeRecoveryEngine.markMoneySettled(txn3);
      final bankMid3 = Db.bank.get('bank_balance') as double;
      print('  Mid-Crash Bank (Moved Once): ₹$bankMid3');

      final rec3 = await RechargeRecoveryEngine.reconcilePendingSettlements();
      final bankAfter3 = Db.bank.get('bank_balance') as double;
      print('  Reconciliation Count: $rec3');
      print('  After Recovery Bank: ₹$bankAfter3 (Must NOT double-credit to ${bankMid3 + 666.0})');
      expect(bankAfter3, equals(bankMid3)); // STRICT ZERO DOUBLE-MOVE
      expect(Db.recharges.containsKey(txn3), isTrue);

      // SCENARIO 4: Party Receivable Moved, Crash Before Db.recharges Write
      print('\n[CRASH DRILL 4] Credit Party Balance Already Moved, Crash Before History Log');
      const txn4 = 'TXN_CRASH_DRILL_04';
      final partyKey4 = await Db.parties.add({
        'name': 'Khadija Store',
        'phone': '9847111004',
        'balance': 300.0,
      });
      print('  Before Drill Party Balance: ₹${Db.parties.get(partyKey4)['balance']}');

      await RechargeRecoveryEngine.recordPendingIntent(
        idempotencyKey: txn4,
        shopId: StagingIdentityService.defaultShopId,
        ownerUid: 'owner_staging_001',
        deviceId: 'DEV_WIN_001',
        mobile: '9847111004',
        operator: 'BSNL',
        serviceType: 'Prepaid',
        retailAmount: 153.0,
        costPrice: 147.0,
        paymentMode: 'Credit / Due',
        partyKey: partyKey4,
        partyName: 'Khadija Store',
      );
      await RechargeRecoveryEngine.markServerConfirmed(txn4, 'UPSTREAM_DEBIT_04');
      // Party was already moved
      final p4 = Map<String, dynamic>.from(Db.parties.get(partyKey4) as Map);
      p4['balance'] = (p4['balance'] as double) + 153.0;
      await Db.parties.put(partyKey4, p4);
      await RechargeRecoveryEngine.markPartySettled(txn4);
      print('  Mid-Crash Party Balance: ₹${Db.parties.get(partyKey4)['balance']}');

      final rec4 = await RechargeRecoveryEngine.reconcilePendingSettlements();
      print('  Reconciliation Count: $rec4');
      print('  After Recovery Party Balance: ₹${Db.parties.get(partyKey4)['balance']} (Must NOT be double debited)');
      expect(Db.parties.get(partyKey4)['balance'], equals(453.0));
      expect(Db.recharges.containsKey(txn4), isTrue);

      // SCENARIO 5: Missing / Deleted Party Record During Recovery
      print('\n[CRASH DRILL 5] Missing / Deleted Party During Recovery -> MANUAL_REVIEW_REQUIRED');
      const txn5 = 'TXN_CRASH_DRILL_05';

      await RechargeRecoveryEngine.recordPendingIntent(
        idempotencyKey: txn5,
        shopId: StagingIdentityService.defaultShopId,
        ownerUid: 'owner_staging_001',
        deviceId: 'DEV_WIN_001',
        mobile: '9847111005',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 719.0,
        costPrice: 698.0,
        paymentMode: 'Credit / Due',
        partyKey: 'DELETED_PARTY_GHOST_KEY',
        partyName: 'Ghost Customer',
      );
      await RechargeRecoveryEngine.markServerConfirmed(txn5, 'UPSTREAM_DEBIT_05');

      final rec5 = await RechargeRecoveryEngine.reconcilePendingSettlements();
      print('  Reconciliation Count: $rec5 (0 auto-reconciled, held for manual review)');
      final entry5 = Db.rechargeQueue.get(txn5) as Map;
      print('  After Recovery Entry Status: ${entry5['status']}');
      print('  After Recovery Entry Reason: ${entry5['reviewReason']}');
      expect(rec5, equals(0));
      expect(entry5['status'], equals(RechargeRecoveryEngine.statusManualReviewRequired));

      print('--- 5 FINANCIAL RECOVERY CRASH DRILLS COMPLETE: ALL LEDGERS VERIFIED ---\n');
    });
  });
}
