import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/migration/feature_upgrade_migration.dart';
import 'package:tekfix_erp_pos/pos/daily_register_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase1_test_');
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
    await Db.settings.clear();
    await Db.bank.clear();
    await Db.parties.clear();
    await Db.sales.clear();
    await Db.items.clear();
    await Db.stockMoves.clear();
    await Db.audit.clear();

    // Default setup
    await Db.settings.put('shop_id', 'shop_test_001');
    await Db.settings.put('invoice_prefix', 'INV');
    await Db.settings.put('invoice_seq', 100);
    await Db.settings.put('backdate_days_limit', '1');
  });

  group('TEKFIX ERP — Phase 1: Backdated Sales Entry Tests', () {
    // -------------------------------------------------------------------------
    // TEST 1: Dual Date Storage (saleDate vs createdAt) & Backdated Flag
    // -------------------------------------------------------------------------
    test('1. Dual date storage: saleDate records chosen date while createdAt preserves real entry time', () async {
      final nowUtc = DateTime.now().toUtc();
      final threeDaysAgo = nowUtc.subtract(const Duration(days: 3));

      final invoice = await Db.nextInvoice();
      final bill = <String, dynamic>{
        'invoice': invoice,
        'saleDate': threeDaysAgo.toIso8601String(),
        'createdAt': nowUtc.toIso8601String(),
        'isBackdated': true,
        'customerName': 'Rahul Test',
        'customerPhone': '9876543210',
        'items': [
          {'name': 'Tempered Glass', 'price': 150.0, 'qty': 1, 'cost': 50.0}
        ],
        'total': 150.0,
        'cash': 150.0,
        'upi': 0.0,
        'due': 0.0,
        'status': 'SOLD',
      };

      await Db.sales.add(bill);

      // Verify stored record
      final stored = Db.sales.values.first as Map;
      expect(stored['invoice'], equals(invoice));
      expect(stored['isBackdated'], isTrue);
      expect(DateTime.parse(stored['saleDate'] as String).day, equals(threeDaysAgo.day));
      expect(DateTime.parse(stored['createdAt'] as String).day, equals(nowUtc.day));
      expect(stored['saleDate'], isNot(equals(stored['createdAt'])));
    });

    // -------------------------------------------------------------------------
    // TEST 2: Stock Movement & Cash Ledger inherit chosen saleDate
    // -------------------------------------------------------------------------
    test('2. Stock movements and cash transactions inherit the chosen saleDate', () async {
      final threeDaysAgo = DateTime.now().toUtc().subtract(const Duration(days: 3));
      final dateIso = threeDaysAgo.toIso8601String();

      // Seed item
      final itemKey = await Db.items.add({
        'name': 'USB-C Cable',
        'stock': 20,
        'sellingPrice': 250.0,
      });

      // Move stock with date
      await Db.stockMove(itemKey, 'USB-C Cable', -2, 'Sale INV-TF0101', date: dateIso);

      // Move money with date
      await Db.moveMoney('Cash', 500.0, 'Sale INV-TF0101', date: dateIso);

      // Verify stock movement date
      final move = Db.stockMoves.values.first as Map;
      expect(move['date'], equals(dateIso));
      expect(move['delta'], equals(-2));

      // Verify cash transaction log date
      final txnLog = Db.bank.get('txn_log') as List;
      expect(txnLog.last['date'], equals(dateIso));
      expect(txnLog.last['amount'], equals(500.0));
      expect(txnLog.last['note'], equals('Sale INV-TF0101'));
    });

    // -------------------------------------------------------------------------
    // TEST 3: Report Isolation (3 Days Ago vs Today)
    // -------------------------------------------------------------------------
    test('3. Backdated sale shows in that day’s report, NOT in today’s report', () async {
      final now = DateTime.now();
      final threeDaysAgo = now.subtract(const Duration(days: 3));

      // 1. Backdated bill from 3 days ago
      await Db.sales.add({
        'invoice': 'INV-TF0102',
        'saleDate': threeDaysAgo.toUtc().toIso8601String(),
        'createdAt': now.toUtc().toIso8601String(),
        'isBackdated': true,
        'total': 1200.0,
        'cash': 1200.0,
        'upi': 0.0,
        'due': 0.0,
        'status': 'SOLD',
      });

      // 2. Normal bill from today
      await Db.sales.add({
        'invoice': 'INV-TF0103',
        'saleDate': now.toUtc().toIso8601String(),
        'createdAt': now.toUtc().toIso8601String(),
        'isBackdated': false,
        'total': 450.0,
        'cash': 450.0,
        'upi': 0.0,
        'due': 0.0,
        'status': 'SOLD',
      });

      // Query DailyRegisterService for 3 days ago
      final pastSales = await DailyRegisterService.instance.getSalesForDate(threeDaysAgo);
      expect(pastSales.length, equals(1));
      expect(pastSales.first['invoice'], equals('INV-TF0102'));
      expect(pastSales.first['total'], equals(1200.0));

      // Query DailyRegisterService for Today
      final todaySales = await DailyRegisterService.instance.getSalesForDate(now);
      expect(todaySales.length, equals(1));
      expect(todaySales.first['invoice'], equals('INV-TF0103'));
      expect(todaySales.first['total'], equals(450.0));
      // INV-TF0102 must NOT appear in today's sales!
      expect(todaySales.any((s) => s['invoice'] == 'INV-TF0102'), isFalse);
    });

    // -------------------------------------------------------------------------
    // TEST 4: Running Invoice Sequence Preserved & Sorted by saleDate
    // -------------------------------------------------------------------------
    test('4. Running invoice sequence is strictly monotonic, lists sort by saleDate desc', () async {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final twoDaysAgo = now.subtract(const Duration(days: 2));

      // Next invoice sequence
      final inv1 = await Db.nextInvoice();
      final inv2 = await Db.nextInvoice();
      final inv3 = await Db.nextInvoice();

      expect(inv1, contains('101'));
      expect(inv2, contains('102'));
      expect(inv3, contains('103'));

      // Add with mixed backdates
      await Db.sales.add({
        'invoice': inv1,
        'saleDate': yesterday.toUtc().toIso8601String(),
        'createdAt': now.toUtc().toIso8601String(),
        'status': 'SOLD',
      });
      await Db.sales.add({
        'invoice': inv2,
        'saleDate': now.toUtc().toIso8601String(),
        'createdAt': now.toUtc().toIso8601String(),
        'status': 'SOLD',
      });
      await Db.sales.add({
        'invoice': inv3,
        'saleDate': twoDaysAgo.toUtc().toIso8601String(),
        'createdAt': now.toUtc().toIso8601String(),
        'status': 'SOLD',
      });

      // Query all sales across range and verify sort order: Today (inv2), Yesterday (inv1), 2 Days Ago (inv3)
      final allSales = entriesOf(Db.sales).map((e) => e.value as Map).toList();
      allSales.sort((a, b) {
        final dtA = DateTime.parse((a['saleDate'] ?? a['createdAt']) as String);
        final dtB = DateTime.parse((b['saleDate'] ?? b['createdAt']) as String);
        final cmp = dtB.compareTo(dtA);
        if (cmp != 0) return cmp;
        return (b['invoice'] ?? '').toString().compareTo((a['invoice'] ?? '').toString());
      });

      expect(allSales[0]['invoice'], equals(inv2)); // Today
      expect(allSales[1]['invoice'], equals(inv1)); // Yesterday
      expect(allSales[2]['invoice'], equals(inv3)); // 2 Days Ago
    });

    // -------------------------------------------------------------------------
    // TEST 5: Activity Log recorded for backdated sale
    // -------------------------------------------------------------------------
    test('5. Backdated sale writes explicit audit activity log entry', () async {
      final nowUtc = DateTime.now().toUtc();
      final pastDate = nowUtc.subtract(const Duration(days: 4));

      await Db.logAction(
        action: 'Backdated Sale Created',
        entity: 'Invoice',
        entityId: 'INV-TF0105',
        reason: 'Backdated to 14 Nov 2026 (Real Time: 18 Nov 2026)',
        newValue: {
          'invoice': 'INV-TF0105',
          'saleDate': pastDate.toIso8601String(),
          'createdAt': nowUtc.toIso8601String(),
          'total': 899.0,
        },
      );

      final logs = Db.audit.values.toList();
      expect(logs.isNotEmpty, isTrue);
      final log = logs.last as Map;
      expect(log['action'], equals('Backdated Sale Created'));
      expect(log['entityId'], equals('INV-TF0105'));
      expect(log['reason'], contains('Backdated to'));
    });

    // -------------------------------------------------------------------------
    // TEST 6: One-Time Migration with Hive Safety Backup
    // -------------------------------------------------------------------------
    test('6. Feature upgrade migration takes safety backup and populates saleDate on legacy sales', () async {
      // Seed legacy sales without saleDate
      final legacySaleKey = await Db.sales.add({
        'invoice': 'LEGACY-001',
        'createdAt': '2026-10-15T10:00:00.000Z',
        'total': 500.0,
      });

      expect(Db.settings.get('migration_backdated_sales_v1_done'), isNull);

      // Run migration
      await FeatureUpgradeMigration.runIfNeeded();

      // Check migration status & safety backup
      expect(Db.settings.get('migration_backdated_sales_v1_done'), equals('true'));
      expect(Db.settings.get('pre_feature_upgrade_backup_v1'), isNotNull);

      // Check legacy sale record was updated
      final updated = Db.sales.get(legacySaleKey) as Map;
      expect(updated['saleDate'], equals('2026-10-15T10:00:00.000Z'));
      expect(updated['isBackdated'], isFalse);
    });
  });
}
