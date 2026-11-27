import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';

import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_recovery_engine.dart';

/// Helper to simulate Firestore cloud balance and SyncEngine's bank flush logic
class MockFirestoreBankState {
  double remoteBalance;
  final List<double> flushedDeltas = [];

  MockFirestoreBankState(this.remoteBalance);

  /// Server-side atomic reservation & commit directly decrements Firestore bank_balance
  void serverDeductTopUp(double amount) {
    remoteBalance = ((remoteBalance - amount) * 100).round() / 100;
  }

  /// Exact replica of SyncEngine's bank delta synchronization (sync_engine.dart:511-526)
  void simulateSyncEngineFlush(Box metaBox, Box bankBox) {
    final cur = (bankBox.get('bank_balance') as num?)?.toDouble() ?? 0.0;
    const lsKey = 'ls:bank|bank_balance';
    final ls = (metaBox.get(lsKey) as num?)?.toDouble() ?? 0.0;
    final delta = ((cur - ls) * 100).round() / 100;
    if (delta != 0) {
      flushedDeltas.add(delta);
      metaBox.put(lsKey, cur);
      remoteBalance = ((remoteBalance + delta) * 100).round() / 100;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  const String testShopId = 'shop_staging_001';

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    tempDir =
        await Directory.systemTemp.createTemp('tekfix_phase16_4_18_test_');
    Hive.init(tempDir.path);

    for (final b in allBoxes) {
      await Hive.openBox(b);
    }
    await Hive.openBox('tek_sync_meta');

    final settingsBox = Hive.box(boxSettings);
    await settingsBox.put('shop_id', testShopId);
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
    await Db.rechargeQueue.clear();
    await Db.rechargeDeadLetter.clear();
    await Db.bank.clear();
    await Db.sales.clear();
    await Db.expenses.clear();

    final metaBox = Hive.box('tek_sync_meta');
    await metaBox.clear();

    // Baseline state: ₹1,000 in bank, fully synced
    await Db.bank.put('bank_balance', 1000.0);
    await Db.bank.put('cash_in_hand', 500.0);
    await Db.bank.put('txn_log', []);
    await metaBox.put('ls:bank|bank_balance', 1000.0);
  });

  group('TEKFIX ERP - PHASE 16.4.18: SYNCENGINE RETAIL DELTA REGRESSION SUITE',
      () {
    test(
        'A-D. Primary Workflow: Pending retail UPI sale (₹500) + Top-Up (₹300) + Recovery + SyncEngine',
        () async {
      final firestore = MockFirestoreBankState(1000.0);
      final metaBox = Hive.box('tek_sync_meta');

      // Step A: Unrelated pending retail UPI sale of ₹500 occurs locally
      await Db.moveMoney('UPI', 500.0, 'Sale INV-UPI-001');
      expect(Db.bank.get('bank_balance'), 1500.0);
      expect(metaBox.get('ls:bank|bank_balance'), 1000.0);

      // Step B: Top-Up of ₹300 executes on server (Firestore decremented to ₹700)
      firestore.serverDeductTopUp(300.0);
      expect(firestore.remoteBalance, 700.0);

      // Step C: Recharge recovery engine settles local bank debit
      await RechargeRecoveryEngine.executeTopUpSettlement(
        idempotencyKey: 'TOPUP_UTR_FLOW_001',
        shopId: testShopId,
        operator: 'Airtel',
        amount: 300.0,
        referenceNo: 'TOPUP_UTR_FLOW_001',
      );

      // Verify local balance is 1500 - 300 = 1200
      expect(Db.bank.get('bank_balance'), 1200.0);
      // Verify SyncEngine baseline was relatively adjusted: 1000 - 300 = 700
      expect(metaBox.get('ls:bank|bank_balance'), 700.0);

      // Step D: SyncEngine flush runs
      firestore.simulateSyncEngineFlush(metaBox, Db.bank);

      // Expected assertions:
      // 1. Retail ₹500 synchronized exactly once
      expect(firestore.flushedDeltas, [500.0]);
      // 2. Recharge ₹300 accounted for exactly once
      // 3. No duplicate debit
      // 4. No lost delta
      // 5. Firestore final balance matches expected accounting balance (1200.0)
      expect(firestore.remoteBalance, 1200.0);
      expect(Db.bank.get('bank_balance'), 1200.0);
      expect(metaBox.get('ls:bank|bank_balance'), 1200.0);
    });

    test('1. Retail transaction before Recharge settlement', () async {
      final firestore = MockFirestoreBankState(2000.0);
      final metaBox = Hive.box('tek_sync_meta');
      await Db.bank.put('bank_balance', 2000.0);
      await metaBox.put('ls:bank|bank_balance', 2000.0);

      // Retail sale of ₹800 before top-up
      await Db.moveMoney('UPI', 800.0, 'Sale INV-PRE-001');
      expect(Db.bank.get('bank_balance'), 2800.0);

      // Top-Up of ₹500
      firestore.serverDeductTopUp(500.0);
      await RechargeRecoveryEngine.executeTopUpSettlement(
        idempotencyKey: 'TOPUP_PRE_001',
        shopId: testShopId,
        operator: 'Jio',
        amount: 500.0,
        referenceNo: 'TOPUP_PRE_001',
      );

      // Flush SyncEngine
      firestore.simulateSyncEngineFlush(metaBox, Db.bank);

      expect(firestore.flushedDeltas, [800.0]);
      expect(firestore.remoteBalance, 2300.0); // 2000 - 500 + 800
      expect(Db.bank.get('bank_balance'), 2300.0);
      expect(metaBox.get('ls:bank|bank_balance'), 2300.0);
    });

    test('2. Retail transaction after Recharge settlement', () async {
      final firestore = MockFirestoreBankState(2000.0);
      final metaBox = Hive.box('tek_sync_meta');
      await Db.bank.put('bank_balance', 2000.0);
      await metaBox.put('ls:bank|bank_balance', 2000.0);

      // Top-Up of ₹500 settles first
      firestore.serverDeductTopUp(500.0);
      await RechargeRecoveryEngine.executeTopUpSettlement(
        idempotencyKey: 'TOPUP_POST_001',
        shopId: testShopId,
        operator: 'VI',
        amount: 500.0,
        referenceNo: 'TOPUP_POST_001',
      );
      expect(Db.bank.get('bank_balance'), 1500.0);
      expect(metaBox.get('ls:bank|bank_balance'), 1500.0);

      // Retail sale of ₹700 occurs after topup settlement
      await Db.moveMoney('UPI', 700.0, 'Sale INV-POST-001');
      expect(Db.bank.get('bank_balance'), 2200.0);

      // Flush SyncEngine
      firestore.simulateSyncEngineFlush(metaBox, Db.bank);

      expect(firestore.flushedDeltas, [700.0]);
      expect(firestore.remoteBalance, 2200.0); // 2000 - 500 + 700
      expect(Db.bank.get('bank_balance'), 2200.0);
      expect(metaBox.get('ls:bank|bank_balance'), 2200.0);
    });

    test('3. Two pending retail transactions', () async {
      final firestore = MockFirestoreBankState(1000.0);
      final metaBox = Hive.box('tek_sync_meta');

      // Retail 1: ₹250
      await Db.moveMoney('UPI', 250.0, 'Sale INV-MULTI-1');
      // Retail 2: ₹350
      await Db.moveMoney('UPI', 350.0, 'Sale INV-MULTI-2');
      expect(Db.bank.get('bank_balance'), 1600.0);

      // Topup of ₹400
      firestore.serverDeductTopUp(400.0);
      await RechargeRecoveryEngine.executeTopUpSettlement(
        idempotencyKey: 'TOPUP_MULTI_001',
        shopId: testShopId,
        operator: 'BSNL',
        amount: 400.0,
        referenceNo: 'TOPUP_MULTI_001',
      );
      expect(Db.bank.get('bank_balance'), 1200.0);
      expect(metaBox.get('ls:bank|bank_balance'), 600.0); // 1000 - 400

      // Flush SyncEngine
      firestore.simulateSyncEngineFlush(metaBox, Db.bank);

      expect(firestore.flushedDeltas, [600.0]); // 250 + 350
      expect(firestore.remoteBalance, 1200.0); // 1000 - 400 + 600
      expect(Db.bank.get('bank_balance'), 1200.0);
    });

    test('4. Repeated Recharge recovery', () async {
      final firestore = MockFirestoreBankState(1000.0);
      final metaBox = Hive.box('tek_sync_meta');

      firestore.serverDeductTopUp(200.0);

      // First recovery call
      await RechargeRecoveryEngine.executeTopUpSettlement(
        idempotencyKey: 'TOPUP_REPEAT_001',
        shopId: testShopId,
        operator: 'Airtel',
        amount: 200.0,
        referenceNo: 'TOPUP_REPEAT_001',
      );
      expect(Db.bank.get('bank_balance'), 800.0);
      expect(metaBox.get('ls:bank|bank_balance'), 800.0);

      // Second recovery call (idempotent replay)
      await RechargeRecoveryEngine.executeTopUpSettlement(
        idempotencyKey: 'TOPUP_REPEAT_001',
        shopId: testShopId,
        operator: 'Airtel',
        amount: 200.0,
        referenceNo: 'TOPUP_REPEAT_001',
      );
      expect(Db.bank.get('bank_balance'), 800.0);
      expect(metaBox.get('ls:bank|bank_balance'), 800.0);

      // Third recovery call
      await RechargeRecoveryEngine.executeTopUpSettlement(
        idempotencyKey: 'TOPUP_REPEAT_001',
        shopId: testShopId,
        operator: 'Airtel',
        amount: 200.0,
        referenceNo: 'TOPUP_REPEAT_001',
      );
      expect(Db.bank.get('bank_balance'), 800.0);
      expect(metaBox.get('ls:bank|bank_balance'), 800.0);

      // SyncEngine flush
      firestore.simulateSyncEngineFlush(metaBox, Db.bank);

      expect(firestore.flushedDeltas,
          isEmpty); // No delta because balance unchanged
      expect(firestore.remoteBalance, 800.0);
      expect(Db.bank.get('bank_balance'), 800.0);
    });

    test('5. SyncEngine flush before recovery', () async {
      final firestore = MockFirestoreBankState(1000.0);
      final metaBox = Hive.box('tek_sync_meta');

      // Retail sale of ₹500
      await Db.moveMoney('UPI', 500.0, 'Sale INV-PREFLUSH-1');
      expect(Db.bank.get('bank_balance'), 1500.0);

      // SyncEngine flushes BEFORE top-up recovery
      firestore.simulateSyncEngineFlush(metaBox, Db.bank);
      expect(firestore.flushedDeltas, [500.0]);
      expect(firestore.remoteBalance, 1500.0);
      expect(metaBox.get('ls:bank|bank_balance'), 1500.0);

      // Now top-up of ₹300 settles
      firestore.serverDeductTopUp(300.0);
      await RechargeRecoveryEngine.executeTopUpSettlement(
        idempotencyKey: 'TOPUP_PREFLUSH_001',
        shopId: testShopId,
        operator: 'Jio',
        amount: 300.0,
        referenceNo: 'TOPUP_PREFLUSH_001',
      );
      expect(Db.bank.get('bank_balance'), 1200.0);
      expect(metaBox.get('ls:bank|bank_balance'), 1200.0); // 1500 - 300

      // SyncEngine flushes AFTER recovery
      firestore.simulateSyncEngineFlush(metaBox, Db.bank);
      expect(firestore.flushedDeltas, [500.0]); // No new delta generated
      expect(firestore.remoteBalance, 1200.0);
      expect(Db.bank.get('bank_balance'), 1200.0);
    });

    test('6. SyncEngine flush after recovery', () async {
      final firestore = MockFirestoreBankState(1500.0);
      final metaBox = Hive.box('tek_sync_meta');
      await Db.bank.put('bank_balance', 1500.0);
      await metaBox.put('ls:bank|bank_balance', 1500.0);

      // Retail UPI sale ₹300
      await Db.moveMoney('UPI', 300.0, 'Sale INV-POSTFLUSH-1');

      // Top-up of ₹400 settles
      firestore.serverDeductTopUp(400.0);
      await RechargeRecoveryEngine.executeTopUpSettlement(
        idempotencyKey: 'TOPUP_POSTFLUSH_001',
        shopId: testShopId,
        operator: 'VI',
        amount: 400.0,
        referenceNo: 'TOPUP_POSTFLUSH_001',
      );

      // Flush after recovery
      firestore.simulateSyncEngineFlush(metaBox, Db.bank);

      expect(firestore.flushedDeltas, [300.0]);
      expect(firestore.remoteBalance, 1400.0); // 1500 - 400 + 300
      expect(Db.bank.get('bank_balance'), 1400.0);
      expect(metaBox.get('ls:bank|bank_balance'), 1400.0);
    });

    test('7. App crash between local settlement and synchronization', () async {
      final firestore = MockFirestoreBankState(1000.0);
      final metaBox = Hive.box('tek_sync_meta');

      // Retail sale of ₹500
      await Db.moveMoney('UPI', 500.0, 'Sale INV-CRASH-1');

      // Top-Up of ₹300 settles locally
      firestore.serverDeductTopUp(300.0);
      await RechargeRecoveryEngine.executeTopUpSettlement(
        idempotencyKey: 'TOPUP_CRASH_SYNC_001',
        shopId: testShopId,
        operator: 'Airtel',
        amount: 300.0,
        referenceNo: 'TOPUP_CRASH_SYNC_001',
      );

      // Simulate crash: App terminates before SyncEngine flushes.
      // On restart, boxes are reopened with their persisted state:
      final persistedBankBalance = Db.bank.get('bank_balance');
      final persistedLs = metaBox.get('ls:bank|bank_balance');
      expect(persistedBankBalance, 1200.0);
      expect(persistedLs, 700.0);

      // Outbox reconciliation runs:
      final count = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(count, 0); // Already settled locally, no orphaned actions

      // SyncEngine resumes and flushes:
      firestore.simulateSyncEngineFlush(metaBox, Db.bank);

      // Assertions:
      expect(firestore.flushedDeltas,
          [500.0]); // Pending retail sale safely synced!
      expect(firestore.remoteBalance, 1200.0);
      expect(Db.bank.get('bank_balance'), 1200.0);
      expect(metaBox.get('ls:bank|bank_balance'), 1200.0);
    });

    test('8. Two concurrent recovery operations', () async {
      final firestore = MockFirestoreBankState(1000.0);
      final metaBox = Hive.box('tek_sync_meta');

      // Retail sale of ₹400
      await Db.moveMoney('UPI', 400.0, 'Sale INV-CONCUR-1');
      firestore.serverDeductTopUp(250.0);

      // Two concurrent recovery calls for the exact same idempotency key
      await Future.wait([
        RechargeRecoveryEngine.executeTopUpSettlement(
          idempotencyKey: 'TOPUP_CONCURRENT_001',
          shopId: testShopId,
          operator: 'Jio',
          amount: 250.0,
          referenceNo: 'TOPUP_CONCURRENT_001',
        ),
        RechargeRecoveryEngine.executeTopUpSettlement(
          idempotencyKey: 'TOPUP_CONCURRENT_001',
          shopId: testShopId,
          operator: 'Jio',
          amount: 250.0,
          referenceNo: 'TOPUP_CONCURRENT_001',
        ),
      ]);

      // Bank balance should only be debited ONCE: 1000 + 400 - 250 = 1150
      expect(Db.bank.get('bank_balance'), 1150.0);
      expect(metaBox.get('ls:bank|bank_balance'), 750.0); // 1000 - 250

      // SyncEngine flush
      firestore.simulateSyncEngineFlush(metaBox, Db.bank);

      expect(firestore.flushedDeltas, [400.0]); // Retail sale synced once
      expect(firestore.remoteBalance, 1150.0); // 1000 - 250 + 400
      expect(Db.bank.get('bank_balance'), 1150.0);
    });
  });
}
