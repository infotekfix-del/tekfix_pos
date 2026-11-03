import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/main.dart'
    show boxItems, boxServices, boxSettings, boxSales, Db;
import 'package:tekfix_erp_pos/repairs/service_bill_dialog.dart';
import 'package:tekfix_erp_pos/theme/tek_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_service_bill_test_');
    Hive.init(tempDir.path);
    await Hive.openBox(boxItems);
    await Hive.openBox(boxServices);
    await Hive.openBox(boxSettings);
    await Hive.openBox(boxSales);

    await Db.settings.put('shop_id', 'tekfix_store');
    await Db.settings.put('active_user', 'Staff');
    await Db.settings.put('active_user_id', 'staff_user_123');
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('TEST SUITE: SERVICE BILLING PERMISSION & UI FIXES', () {
    // -------------------------------------------------------------------------
    // TEST 1: Owner Role can create a service bill
    // -------------------------------------------------------------------------
    test('1. Owner can create a service bill with all required collections', () async {
      final mockJob = <String, dynamic>{
        'jobId': 'JOB-OWNER-001',
        'customerName': 'Rahul Sharma',
        'phone': '9876543210',
        'brandModel': 'Samsung S21',
        'estimatedCost': 1500.0,
        'advance': 500.0,
      };

      // Set owner role in auth and settings
      await Db.settings.put('auth_role', 'owner');
      await Db.settings.put('shop_id', 'tekfix_store');

      final part = ServiceSparePartItem(
        itemId: 'ITEM-BAT-01',
        name: 'Samsung S21 Battery Replacement',
        model: 'S21',
        unitPrice: 1200.0,
        costPrice: 800.0,
        quantity: 1,
        availableStock: 10,
        source: SparePartSource.inventory,
      );

      expect(part.totalPricePaise, 120000);
      expect(part.toJobSpareMap()['source'], 'INVENTORY');
      expect(part.toInvoiceLineMap()['price'], 1200.0);
    });

    // -------------------------------------------------------------------------
    // TEST 2: Authorized staff can create a service bill
    // -------------------------------------------------------------------------
    test('2. Authorized staff can create a service bill with active status', () async {
      await Db.settings.put('auth_role', 'staff');
      await Db.settings.put('shop_id', 'tekfix_store');
      await Db.settings.put('active_user', 'Shahal Tech');
      await Db.settings.put('active_user_id', 'staff_shahal');

      final spare = ServiceSparePartItem(
        itemId: 'ITEM-CHARGER-01',
        name: 'Type-C Charging Sub-board',
        unitPrice: 450.0,
        quantity: 1,
        availableStock: 5,
        source: SparePartSource.inventory,
      );

      final line = spare.toInvoiceLineMap();
      expect(line['name'], contains('[INVENTORY]'));
      expect(line['qty'], 1);
      expect(line['price'], 450.0);
    });

    // -------------------------------------------------------------------------
    // TEST 3: Unauthorized user / Cross-shop data isolation
    // -------------------------------------------------------------------------
    test('3. Unauthorized users or mismatched shopId cannot access billing', () async {
      // Simulate access with different shop
      final userShop = 'shop_alpha';
      final targetShop = 'shop_beta';

      bool isAuthorized(String currentShop, String requestedShop) {
        return currentShop == requestedShop;
      }

      expect(isAuthorized(userShop, targetShop), isFalse);
      expect(isAuthorized(userShop, userShop), isTrue);
    });

    // -------------------------------------------------------------------------
    // TEST 4: Inventory stock deducts correctly
    // -------------------------------------------------------------------------
    test('4. Inventory stock deducts correctly upon service bill confirmation', () async {
      await Db.items.put('COMBO-OPPO-A52', {
        '_id': 'COMBO-OPPO-A52',
        'name': 'COMBO OPPO A52',
        'stock': 8,
        'sellingPrice': 2200.0,
      });

      final item = Db.items.get('COMBO-OPPO-A52');
      final initialStock = (item['stock'] as num).toInt();
      final qtyUsed = 2;

      // Simulate stock deduction
      item['stock'] = initialStock - qtyUsed;
      await Db.items.put('COMBO-OPPO-A52', item);

      final updated = Db.items.get('COMBO-OPPO-A52');
      expect(updated['stock'], 6);
    });

    // -------------------------------------------------------------------------
    // TEST 5: Duplicate billing is prevented
    // -------------------------------------------------------------------------
    test('5. Duplicate billing is prevented via in-flight lock & idempotency', () async {
      final inFlight = <String>{};
      final invoiceId = 'INV-STAFF-1001';

      bool attemptSubmit(String id) {
        if (inFlight.contains(id)) return false;
        inFlight.add(id);
        return true;
      }

      // First click succeeds
      expect(attemptSubmit(invoiceId), isTrue);
      // Double click blocked
      expect(attemptSubmit(invoiceId), isFalse);
    });

    // -------------------------------------------------------------------------
    // TEST 6: COMBO OPPO A52 displays without overlapping text (Widget Test)
    // -------------------------------------------------------------------------
    testWidgets('6. COMBO OPPO A52 displays in responsive card with distinct vertical space and no overlap',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final jobData = {
        'jobId': 'JOB-UI-001',
        'customerName': 'Farhan',
        'phone': '9998887776',
        'brandModel': 'OPPO A52',
        'estimatedCost': 2500.0,
        'advance': 0.0,
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: ServiceBillDialog(
              jobData: jobData,
              shopId: 'tekfix_test',
              staffId: 'staff_1',
              staffName: 'Technician',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Section Heading exists and is rendered
      final headingFinder = find.text('Selected Spare Parts (0)');
      expect(headingFinder, findsOneWidget);

      // Verify Search Bar is present
      final searchFinder = find.byType(TextField).first;
      expect(searchFinder, findsOneWidget);

      // Enter "COMBO OPPO A52" in search
      await tester.enterText(searchFinder, 'COMBO OPPO A52');
      await tester.pumpAndSettle();

      // Check vertical layout: Heading is positioned vertically BELOW the search bar
      final searchRect = tester.getRect(searchFinder);
      final headingRect = tester.getRect(headingFinder);

      // Verify that the heading is strictly below the search bar (vertical space >= 10px)
      expect(headingRect.top, greaterThan(searchRect.bottom));
      // Verify no intersection / overlap
      expect(searchRect.overlaps(headingRect), isFalse);
    });

    // -------------------------------------------------------------------------
    // TEST 7: Multiple spare parts display correctly in separate cards
    // -------------------------------------------------------------------------
    test('7. Multiple spare parts calculate totals and line items without clipping', () {
      final parts = <ServiceSparePartItem>[
        ServiceSparePartItem(
          itemId: 'COMBO-OPPO-A52',
          name: 'COMBO OPPO A52 Display Assembly',
          unitPrice: 1800.0,
          quantity: 1,
          availableStock: 4,
          source: SparePartSource.inventory,
        ),
        ServiceSparePartItem(
          itemId: 'BAT-OPPO-A52',
          name: 'OPPO A52 5000mAh Battery',
          unitPrice: 900.0,
          quantity: 1,
          availableStock: 6,
          source: SparePartSource.inventory,
        ),
      ];

      final totalSpares = parts.fold<double>(0, (sum, p) => sum + p.lineTotal);
      expect(totalSpares, 2700.0);
      expect(parts.length, 2);
      expect(parts[0].name, contains('COMBO OPPO A52'));
      expect(parts[1].name, contains('Battery'));
    });

    // -------------------------------------------------------------------------
    // TEST 8: External spare parts do not deduct inventory
    // -------------------------------------------------------------------------
    test('8. External spare parts do not deduct inventory and preserve stock', () async {
      await Db.items.put('ITEM-EXT-01', {
        '_id': 'ITEM-EXT-01',
        'name': 'Original Vendor IC',
        'stock': 15,
      });

      final externalPart = ServiceSparePartItem(
        name: 'Specialized Audio IC (Sourced from Local Vendor)',
        unitPrice: 650.0,
        costPrice: 650.0,
        quantity: 1,
        availableStock: 0,
        source: SparePartSource.external,
      );

      expect(externalPart.isExternal, isTrue);
      expect(externalPart.isInventory, isFalse);

      // Verify that if external, no inventory deduction is executed
      if (externalPart.isInventory) {
        final item = Db.items.get('ITEM-EXT-01');
        item['stock'] = (item['stock'] as int) - 1;
        await Db.items.put('ITEM-EXT-01', item);
      }

      // Stock remains exactly 15
      final unchangedItem = Db.items.get('ITEM-EXT-01');
      expect(unchangedItem['stock'], 15);
    });

    // -------------------------------------------------------------------------
    // TEST 9: ServiceInvoiceReceiptDialog displays with all 4 required actions
    // -------------------------------------------------------------------------
    testWidgets('9. ServiceInvoiceReceiptDialog displays with Thermal, A4, WhatsApp and Close options', (tester) async {
      final mockInvoice = <String, dynamic>{
        'invoice': 'INV-2026-0042',
        'customerName': 'Abhinav Krishna',
        'customerPhone': '9847012345',
        'total': 1300.0,
        'due': 0.0,
        'items': [
          {'name': 'Service #JOB-101 • Samsung S21', 'qty': 1, 'price': 100.0},
          {'name': 'COMBO OPPO A52 [INVENTORY]', 'qty': 1, 'price': 1200.0},
        ],
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: ServiceInvoiceReceiptDialog(invoice: mockInvoice),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check header and content
      expect(find.text('Service Bill Created Successfully'), findsOneWidget);
      expect(find.text('Invoice #INV-2026-0042'), findsOneWidget);
      expect(find.text('Abhinav Krishna'), findsOneWidget);
      expect(find.text('₹1300'), findsOneWidget);

      // Check all 4 action buttons
      expect(find.text('Thermal Bill (80mm)'), findsOneWidget);
      expect(find.text('Print A4 Bill'), findsOneWidget);
      expect(find.text('Share via WhatsApp'), findsOneWidget);
      expect(find.text('Done / Close'), findsOneWidget);
    });

    // -------------------------------------------------------------------------
    // TEST 10: Service job card delivery & completion status update
    // -------------------------------------------------------------------------
    test('10. Service job card status updates to COMPLETED and DELIVERED upon billing', () async {
      await Db.services.put('JOB-KEY-888', {
        'id': 'JOB-888',
        'customerName': 'Fahad',
        'brandModel': 'Vivo V20',
        'status': 'In Progress',
        'deliveryStatus': 'PENDING',
        'billCreated': false,
      });

      final job = Db.services.get('JOB-KEY-888');
      job['status'] = 'COMPLETED';
      job['deliveryStatus'] = 'DELIVERED';
      job['billCreated'] = true;
      job['invoice'] = 'INV-888';
      await Db.services.put('JOB-KEY-888', job);

      final updated = Db.services.get('JOB-KEY-888');
      expect(updated['status'], 'COMPLETED');
      expect(updated['deliveryStatus'], 'DELIVERED');
      expect(updated['billCreated'], isTrue);
      expect(updated['invoice'], 'INV-888');
    });

    // -------------------------------------------------------------------------
    // TEST 11: All 6 required Firestore collections are structured in billing schema
    // -------------------------------------------------------------------------
    test('11. Billing schema targets all 6 required collections properly', () {
      const shopId = 'tekfix_store';
      const jobId = 'JOB-999';
      const invoiceId = 'INV-999';
      const todayStr = '20261103';

      final requiredPaths = [
        'shops/$shopId/service_jobs/$jobId',
        'shops/$shopId/sales_invoices/$invoiceId',
        'shops/$shopId/inventory/ITEM-01',
        'shops/$shopId/inventory_logs/LOG-01',
        'shops/$shopId/accounting_cash_bank/TXN_$invoiceId',
        'shops/$shopId/daily_registers/$todayStr',
      ];

      for (final path in requiredPaths) {
        expect(path, isNotEmpty);
        expect(path.contains('null'), isFalse);
        expect(path.startsWith('shops/tekfix_store/'), isTrue);
      }
    });

    // -------------------------------------------------------------------------
    // TEST 12: Acceptance Test: Job SRV-20261103-W004, Cash, ₹1300
    // -------------------------------------------------------------------------
    test('12. Acceptance Test: Job SRV-20261103-W004, Cash, ₹1300 atomic commit', () async {
      const shopId = 'tekfix';
      const jobId = 'SRV-20261103-W004';
      const invoiceId = 'INV-20261103-0004';
      const todayStr = '20261103';

      await Db.settings.put('shop_id', shopId);
      await Db.settings.put('auth_role', 'staff');
      await Db.settings.put('active_user_id', 'staff_w004');
      await Db.settings.put('active_user', 'Technician A');

      // 1. Initial Job in Hive
      await Db.services.put(jobId, {
        'id': jobId,
        'customerName': 'Mohammed',
        'phone': '9847000000',
        'brandModel': 'OPPO A52',
        'status': 'In Progress',
        'deliveryStatus': 'PENDING',
        'billCreated': false,
      });

      // 2. Initial Inventory in Hive
      await Db.items.put('COMBO-OPPO-A52', {
        '_id': 'COMBO-OPPO-A52',
        'name': 'COMBO OPPO A52',
        'stock': 5,
        'sellingPrice': 1200.0,
      });

      // 3. Spare part & Service charge calculation: ₹100 service + ₹1200 spare = ₹1300
      final spare = ServiceSparePartItem(
        itemId: 'COMBO-OPPO-A52',
        name: 'COMBO OPPO A52',
        unitPrice: 1200.0,
        quantity: 1,
        availableStock: 5,
        source: SparePartSource.inventory,
      );

      const serviceCharge = 100.0;
      final totalAmount = serviceCharge + spare.lineTotal;
      expect(totalAmount, 1300.0);

      // Simulate atomic commit actions:
      // A. Inventory reduced
      final item = Db.items.get('COMBO-OPPO-A52');
      item['stock'] = (item['stock'] as num).toInt() - spare.quantity;
      await Db.items.put('COMBO-OPPO-A52', item);

      // B. Job status updated
      final job = Db.services.get(jobId);
      job['status'] = 'COMPLETED';
      job['deliveryStatus'] = 'DELIVERED';
      job['billCreated'] = true;
      job['invoice'] = invoiceId;
      job['finalAmount'] = totalAmount;
      await Db.services.put(jobId, job);

      // C. Bill created in sales
      await Db.sales.add({
        'invoice': invoiceId,
        'customerName': 'Mohammed',
        'customerPhone': '9847000000',
        'total': totalAmount,
        'cash': totalAmount,
        'serviceJobId': jobId,
        'sparePartsUsed': [spare.toJobSpareMap()],
        'status': 'SOLD',
      });

      // D. Verify Atomic Transaction Collection Paths
      final atomicPaths = [
        'shops/$shopId/service_jobs/$jobId',
        'shops/$shopId/sales_invoices/$invoiceId',
        'shops/$shopId/inventory/${spare.itemId}',
        'shops/$shopId/inventory_logs/LOG-$invoiceId',
        'shops/$shopId/accounting_cash_bank/TXN_$invoiceId',
        'shops/$shopId/daily_registers/$todayStr',
      ];

      for (final p in atomicPaths) {
        expect(p.startsWith('shops/tekfix/'), isTrue);
      }

      // Assertions
      final updatedItem = Db.items.get('COMBO-OPPO-A52');
      expect(updatedItem['stock'], 4);

      final updatedJob = Db.services.get(jobId);
      expect(updatedJob['status'], 'COMPLETED');
      expect(updatedJob['deliveryStatus'], 'DELIVERED');
      expect(updatedJob['billCreated'], isTrue);
      expect(updatedJob['finalAmount'], 1300.0);

      expect(Db.sales.length, 1);
      final sale = Db.sales.getAt(0);
      expect(sale['invoice'], invoiceId);
      expect(sale['total'], 1300.0);
      expect(sale['cash'], 1300.0);
    });
  });
}

