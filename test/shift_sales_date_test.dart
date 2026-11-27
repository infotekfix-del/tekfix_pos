import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/pos/daily_register_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_shift_sales_test_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      await Hive.openBox(b);
    }
  });

  tearDownAll(() async {
    try {
      await Hive.close();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('Shift Sales Date Tests', () {
    test('Moving today sales to yesterday updates DailyRegisterService query correctly', () async {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));

      // 1. Create a cash sale today
      final saleToday = {
        'invoice': 'INV-TEST-SHIFT-001',
        'saleDate': now.toUtc().toIso8601String(),
        'createdAt': now.toUtc().toIso8601String(),
        'total': 500.0,
        'cash': 500.0,
        'upi': 0.0,
        'status': 'SOLD',
        'customerName': 'Walk-in',
      };
      final saleKey = await Db.sales.add(saleToday);

      // Verify sale appears in today's query
      final salesTodayBefore =
          await DailyRegisterService.instance.getSalesForDate(now);
      expect(salesTodayBefore.any((s) => s['invoice'] == 'INV-TEST-SHIFT-001'),
          isTrue);

      final salesYesterdayBefore =
          await DailyRegisterService.instance.getSalesForDate(yesterday);
      expect(
          salesYesterdayBefore.any((s) => s['invoice'] == 'INV-TEST-SHIFT-001'),
          isFalse);

      // 2. Perform the shift logic to yesterday
      final raw = Db.sales.get(saleKey) as Map;
      final m = Map<String, dynamic>.from(raw);
      final shiftedDt = DateTime(
        yesterday.year,
        yesterday.month,
        yesterday.day,
        now.hour,
        now.minute,
        now.second,
      );
      m['saleDate'] = shiftedDt.toUtc().toIso8601String();
      m['isBackdated'] = true;
      await Db.sales.put(saleKey, m);

      // 3. Verify sale has left today and joined yesterday
      final salesTodayAfter =
          await DailyRegisterService.instance.getSalesForDate(now);
      expect(salesTodayAfter.any((s) => s['invoice'] == 'INV-TEST-SHIFT-001'),
          isFalse);

      final salesYesterdayAfter =
          await DailyRegisterService.instance.getSalesForDate(yesterday);
      expect(
          salesYesterdayAfter.any((s) => s['invoice'] == 'INV-TEST-SHIFT-001'),
          isTrue);
      expect(
          salesYesterdayAfter
              .firstWhere((s) => s['invoice'] == 'INV-TEST-SHIFT-001')['cash'],
          500.0);
    });
  });
}
