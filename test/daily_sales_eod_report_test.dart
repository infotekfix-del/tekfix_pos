import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/pos/daily_register_models.dart';
import 'package:tekfix_erp_pos/pos/daily_register_service.dart';
import 'package:tekfix_erp_pos/pos/daily_sales_ledger_view.dart';

void main() {
  group('Daily Sales Dashboard, Shift Reconciliation & EOD Closing Report Tests', () {
    late Directory tempDir;

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('daily_sales_eod_test_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('store_state_code', '32');
      await settingsBox.put('shop_id', 'shop_test_eod');
      await settingsBox.put('shop_name', 'TEKFIX DIGITAL HUB');
      await settingsBox.put('admin_pass', '1234');
    });

    tearDownAll(() async {
      try {
        await Hive.close();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('1. computeDailySummary computes gross, net, payment modes, and cash discrepancy', () {
      final today = DateTime(2026, 11, 2, 14, 30);
      final testSales = [
        // Sale 1: Cash sale for Gadgets
        {
          'invoice': 'INV-2026-001',
          'createdAt': '2026-11-02T09:15:00',
          'customerName': 'Anoop Kumar',
          'customerPhone': '9847001122',
          'subtotal': 1500.0,
          'discount': 100.0,
          'total': 1400.0,
          'cash': 1400.0,
          'upi': 0.0,
          'card': 0.0,
          'due': 0.0,
          'status': 'SOLD',
          'staffName': 'Shahal',
          'items': [
            {
              'name': 'Boat Airdopes 141',
              'category': 'Earbuds & Audio',
              'qty': 1,
              'price': 1500.0,
              'lineTotal': 1500.0,
            }
          ],
        },
        // Sale 2: Split payment sale for Display service & cover
        {
          'invoice': 'INV-2026-002',
          'createdAt': '2026-11-02T11:45:00',
          'customerName': 'Priya Varma',
          'customerPhone': '9447112233',
          'subtotal': 4500.0,
          'discount': 0.0,
          'total': 4500.0,
          'cash': 1500.0,
          'upi': 3000.0,
          'card': 0.0,
          'due': 0.0,
          'status': 'SOLD',
          'serviceBill': true,
          'staffName': 'Vikram',
          'items': [
            {
              'name': 'Screen Replacement - iPhone 11',
              'category': 'Displays & Screens',
              'qty': 1,
              'price': 4000.0,
              'lineTotal': 4000.0,
            },
            {
              'name': 'iPhone 11 Silicone Case',
              'category': 'Cases & Covers',
              'qty': 1,
              'price': 500.0,
              'lineTotal': 500.0,
            }
          ],
        },
        // Sale 3: Photostat service via UPI
        {
          'invoice': 'INV-2026-003',
          'createdAt': '2026-11-02T15:20:00',
          'customerName': 'Walk-in Customer',
          'customerPhone': '',
          'subtotal': 100.0,
          'discount': 0.0,
          'total': 100.0,
          'cash': 0.0,
          'upi': 100.0,
          'card': 0.0,
          'due': 0.0,
          'status': 'SOLD',
          'staffName': 'Shahal',
          'items': [
            {
              'name': 'A4 B/W Document Printing',
              'category': 'Photostat / Printing',
              'qty': 50,
              'price': 2.0,
              'lineTotal': 100.0,
            }
          ],
        },
        // Sale 4: Credit / Due sale
        {
          'invoice': 'INV-2026-004',
          'createdAt': '2026-11-02T17:10:00',
          'customerName': 'Binu John',
          'customerPhone': '9895000000',
          'subtotal': 1200.0,
          'discount': 0.0,
          'total': 1200.0,
          'cash': 200.0,
          'upi': 0.0,
          'card': 0.0,
          'due': 1000.0,
          'status': 'SOLD',
          'staffName': 'Vikram',
          'items': [
            {
              'name': 'Samsung 25W Fast Charger',
              'category': 'Chargers',
              'qty': 1,
              'price': 1200.0,
              'lineTotal': 1200.0,
            }
          ],
        },
      ];

      // Physical cash counted: 3100 (System cash: 1400 + 1500 + 0 + 200 = 3100 -> exact match)
      final summaryExact = DailyRegisterService.instance.computeDailySummary(
        sales: testSales,
        date: today,
        physicalCashCount: 3100.0,
      );

      expect(summaryExact.totalOrdersCount, 4);
      expect(summaryExact.grossSales, 7300.0);
      expect(summaryExact.totalDiscounts, 100.0);
      expect(summaryExact.netRevenue, 7200.0);
      expect(summaryExact.totalCash, 3100.0);
      expect(summaryExact.totalUpi, 3100.0);
      expect(summaryExact.totalDue, 1000.0);
      expect(summaryExact.physicalCashCount, 3100.0);
      expect(summaryExact.cashDiscrepancy, 0.0);
      expect(summaryExact.cashDiscrepancyPaise, 0);

      // Verify Category Breakdown
      expect(summaryExact.categoryBreakdown.containsKey('Phone / Hardware Service'), isTrue);
      expect(summaryExact.categoryBreakdown['Phone / Hardware Service']!.totalAmount, 4000.0);
      expect(summaryExact.categoryBreakdown.containsKey('Photostat / Printing'), isTrue);
      expect(summaryExact.categoryBreakdown['Photostat / Printing']!.units, 50);

      // Verify Cash Shortage detection
      final summaryShort = DailyRegisterService.instance.computeDailySummary(
        sales: testSales,
        date: today,
        physicalCashCount: 3000.0, // ₹100 short
      );
      expect(summaryShort.cashDiscrepancy, -100.0);
      expect(summaryShort.cashDiscrepancyPaise, -10000);

      // Verify Cash Overage detection
      final summaryOver = DailyRegisterService.instance.computeDailySummary(
        sales: testSales,
        date: today,
        physicalCashCount: 3150.0, // ₹50 over
      );
      expect(summaryOver.cashDiscrepancy, 50.0);
      expect(summaryOver.cashDiscrepancyPaise, 5000);
    });

    test('2. getSalesForDate properly filters sales by date boundary (00:00 to 23:59:59)', () async {
      await Db.sales.clear();

      const todayStr = '2026-11-02T10:30:00';
      const yesterdayStr = '2026-11-01T18:00:00';
      const tomorrowStr = '2026-11-03T09:00:00';

      await Db.sales.add({
        'invoice': 'INV-TODAY-1',
        'createdAt': todayStr,
        'customerName': 'Today Customer 1',
        'total': 500.0,
        'cash': 500.0,
      });

      await Db.sales.add({
        'invoice': 'INV-TODAY-2',
        'createdAt': '2026-11-02T22:15:00',
        'customerName': 'Today Customer 2',
        'total': 850.0,
        'upi': 850.0,
      });

      await Db.sales.add({
        'invoice': 'INV-YEST-1',
        'createdAt': yesterdayStr,
        'customerName': 'Yesterday Customer',
        'total': 300.0,
        'cash': 300.0,
      });

      await Db.sales.add({
        'invoice': 'INV-TOMO-1',
        'createdAt': tomorrowStr,
        'customerName': 'Tomorrow Customer',
        'total': 700.0,
        'card': 700.0,
      });

      final queryDate = DateTime(2026, 11, 2);
      final todaySales = await DailyRegisterService.instance.getSalesForDate(queryDate);

      expect(todaySales.length, 2);
      expect(todaySales.any((s) => s['invoice'] == 'INV-TODAY-1'), isTrue);
      expect(todaySales.any((s) => s['invoice'] == 'INV-TODAY-2'), isTrue);
      expect(todaySales.any((s) => s['invoice'] == 'INV-YEST-1'), isFalse);
      expect(todaySales.any((s) => s['invoice'] == 'INV-TOMO-1'), isFalse);
    });

    test('3. closeDailyRegister and getClosedRegister persist and retrieve immutable summary', () async {
      final date = DateTime(2026, 11, 2);
      final summary = DailyRegisterSummary(
        dateString: '2026_11_02',
        date: date,
        openingTime: '08:30 AM',
        closingTime: '10:00 PM',
        totalOrdersCount: 25,
        grossSales: 35000.0,
        totalDiscounts: 500.0,
        netRevenue: 34500.0,
        totalCash: 15000.0,
        totalUpi: 18000.0,
        totalCard: 1500.0,
        totalDue: 0.0,
        physicalCashCount: 15000.0,
        cashDiscrepancy: 0.0,
        closedByStaffId: 'STAFF-01',
        closedByStaffName: 'Shahal',
      );

      await DailyRegisterService.instance.closeDailyRegister(
        summary: summary,
        shopId: 'shop_test_eod',
        staffId: 'STAFF-01',
        staffName: 'Shahal',
      );

      final retrieved = await DailyRegisterService.instance.getClosedRegister('2026_11_02', shopId: 'shop_test_eod');
      expect(retrieved, isNotNull);
      expect(retrieved!.isClosed, isTrue);
      expect(retrieved.netRevenue, 34500.0);
      expect(retrieved.netRevenuePaise, 3450000);
      expect(retrieved.totalOrdersCount, 25);
      expect(retrieved.closedByStaffName, 'Shahal');
    });

    testWidgets('4. DailySalesLedgerView renders title, date chips, metrics and search', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DailySalesLedgerView(shopId: 'shop_test_eod'),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Daily Sales Ledger & Orders'), findsOneWidget);
      expect(find.text('ഇന്ന് (Today)'), findsOneWidget);
      expect(find.text('ഇന്നലെ (Yesterday)'), findsOneWidget);
      expect(find.textContaining('EOD'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });
  });
}

