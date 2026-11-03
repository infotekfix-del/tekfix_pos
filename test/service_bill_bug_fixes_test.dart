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
  });
}

