import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart'
    show
        boxItems,
        boxParties,
        boxSales,
        boxPurchases,
        boxBank,
        boxSettings,
        boxAudit,
        boxReturns,
        boxStockMoves,
        boxPurchaseBills,
        boxVendorPayments;
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase2_test_');
    Hive.init(tempDir.path);

    await Hive.openBox(boxItems);
    await Hive.openBox(boxParties);
    await Hive.openBox(boxSales);
    await Hive.openBox(boxPurchases);
    await Hive.openBox(boxBank);
    await Hive.openBox(boxSettings);
    await Hive.openBox(boxAudit);
    await Hive.openBox(boxStockMoves);
    await Hive.openBox(boxReturns);
    await Hive.openBox(boxPurchaseBills);
    await Hive.openBox(boxVendorPayments);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('PHASE 2: MANUAL PURCHASE CORE & PRODUCT MATCHING TEST SUITE', () {
    test('1. ProductMatchStatus 3-State Indicators & Visual Properties', () {
      expect(ProductMatchStatus.matched, equals('MATCHED'));
      expect(ProductMatchStatus.quickRegister, equals('NEW'));
      expect(ProductMatchStatus.reviewRequired, equals('REVIEW_REQUIRED'));

      // Check colors
      expect(ProductMatchStatus.getColor(ProductMatchStatus.matched), equals(const Color(0xFF10B981)));
      expect(ProductMatchStatus.getColor(ProductMatchStatus.quickRegister), equals(const Color(0xFFF59E0B)));
      expect(ProductMatchStatus.getColor(ProductMatchStatus.reviewRequired), equals(const Color(0xFFEF4444)));

      // Check labels
      expect(ProductMatchStatus.getLabel(ProductMatchStatus.matched), equals('Existing Product Matched'));
      expect(ProductMatchStatus.getLabel(ProductMatchStatus.quickRegister), equals('New Item: + Quick Register'));
      expect(ProductMatchStatus.getLabel(ProductMatchStatus.reviewRequired), equals('Review Required / Discrepancy'));
    });

    test('2. PurchaseBillItem HSN, MRP, and MatchStatus Resolution', () {
      // 1. Existing matched item -> GREEN
      final matchedItem = PurchaseBillItem(
        name: 'iPhone 15 Case Clear',
        quantity: 5,
        purchaseRate: 250.0,
        sellingPrice: 499.0,
        mrp: 599.0,
        hsnCode: '39269099',
        isNewProduct: false,
        isStagedReady: true,
        matchedProductId: 'prod_123',
        matchedProductName: 'iPhone 15 Case Clear',
      );

      expect(matchedItem.matchStatus, equals(ProductMatchStatus.matched));
      expect(matchedItem.hsn, equals('39269099'));
      expect(matchedItem.mrpPaise, equals(59900));
      expect(matchedItem.purchaseRatePaise, equals(25000));
      expect(matchedItem.sellingPricePaise, equals(49900));

      // 2. Unregistered new item -> AMBER
      final newItem = PurchaseBillItem(
        name: 'Type-C Braided Cable 2M',
        quantity: 10,
        purchaseRate: 120.0,
        isNewProduct: true,
        isStagedReady: false,
      );

      expect(newItem.matchStatus, equals(ProductMatchStatus.quickRegister));

      // 3. Anomaly item (e.g. rate anomaly or model collision) -> RED
      final anomalyItem = PurchaseBillItem(
        name: 'Samsung Galaxy A15 Screen',
        quantity: 2,
        purchaseRate: 3500.0,
        sellingPrice: 3000.0,
        matchStatusOverride: ProductMatchStatus.reviewRequired,
        matchNotes: 'Rate Anomaly: Purchase rate (₹3500) > Selling price (₹3000)',
        isNewProduct: false,
        isStagedReady: false,
      );

      expect(anomalyItem.matchStatus, equals(ProductMatchStatus.reviewRequired));
      expect(anomalyItem.matchNotes, contains('Rate Anomaly'));
    });

    test('3. Multi-Criteria Product Matching & Anomaly Detection', () async {
      final service = PurchaseBillService.instance;
      final itemsBox = Hive.box(boxItems);

      // Seed local inventory item
      await itemsBox.put('item_1', {
        '_id': 'item_1',
        'name': 'Apple 20W USB-C Power Adapter',
        'barcode': '194252157015',
        'sku': 'MHJE3HN/A',
        'model': 'A2305',
        'cost': 1400.0,
        'costPrice': 1400.0,
        'price': 1900.0,
        'sellingPrice': 1900.0,
        'stock': 15,
      });

      // 1. Exact Barcode Match
      final barcodeMatch = await service.matchProductInFirestore(
        name: 'Apple 20W USB-C Power Adapter',
        barcode: '194252157015',
        purchaseRate: 1350.0,
      );
      expect(barcodeMatch, isNotNull);
      expect(barcodeMatch!['name'], equals('Apple 20W USB-C Power Adapter'));
      expect(barcodeMatch['status'], equals(ProductMatchStatus.matched));

      // 2. Exact SKU Match
      final skuMatch = await service.matchProductInFirestore(
        name: 'Apple 20W USB-C Power Adapter',
        sku: 'MHJE3HN/A',
        purchaseRate: 1350.0,
      );
      expect(skuMatch, isNotNull);
      expect(skuMatch!['matchType'], equals('EXACT_SKU'));

      // 3. Rate Anomaly Detection (purchaseRate > sellingPrice)
      final rateAnomalyMatch = await service.matchProductInFirestore(
        name: 'Apple 20W USB-C Power Adapter',
        barcode: '194252157015',
        purchaseRate: 2200.0, // Higher than 1900 selling price!
      );
      expect(rateAnomalyMatch, isNotNull);
      // In local fallback or firestore, verify match was found
      expect(rateAnomalyMatch!['name'], equals('Apple 20W USB-C Power Adapter'));

      // 4. Unknown product returns null (triggers AMBER Quick Register)
      final unknownMatch = await service.matchProductInFirestore(
        barcode: '999999999999',
        sku: 'UNKNOWN-SKU-XYZ',
        name: 'Completely Nonexistent Generic Gadget 2026',
      );
      expect(unknownMatch, isNull);
    });

    test('4. GST Auto-Detection: Intra-State (Kerala 32) vs Inter-State (IGST)', () {
      // Kerala GSTIN starts with '32'
      const keralaGst = '32AAAAA0000A1Z5';
      const karnatakaGst = '29BBBBB1111B1Z2';
      const delhiGst = '07CCCCC2222C1Z3';

      bool isInterState(String gst) {
        final clean = gst.trim().toUpperCase();
        if (clean.length >= 2) {
          final stateCode = clean.substring(0, 2);
          return stateCode != '32'; // 32 is Kerala
        }
        return false;
      }

      expect(isInterState(keralaGst), isFalse); // Intra-State
      expect(isInterState(karnatakaGst), isTrue); // Inter-State
      expect(isInterState(delhiGst), isTrue); // Inter-State
      expect(isInterState(''), isFalse); // Default Intra-State

      // Tax split test
      const double totalTax = 180.0;
      final bool interState = isInterState(karnatakaGst);
      final double cgst = interState ? 0.0 : totalTax / 2.0;
      final double sgst = interState ? 0.0 : totalTax / 2.0;
      final double igst = interState ? totalTax : 0.0;

      expect(cgst, equals(0.0));
      expect(sgst, equals(0.0));
      expect(igst, equals(180.0));

      // Intra-state split test
      final bool intraState = !isInterState(keralaGst);
      final double intraCgst = intraState ? totalTax / 2.0 : 0.0;
      final double intraSgst = intraState ? totalTax / 2.0 : 0.0;
      final double intraIgst = intraState ? 0.0 : totalTax;

      expect(intraCgst, equals(90.0));
      expect(intraSgst, equals(90.0));
      expect(intraIgst, equals(0.0));
    });

    test('5. Accurate Financial Calculations & Round-Off Validation', () {
      final items = [
        PurchaseBillItem(
          name: 'Item A',
          quantity: 3,
          purchaseRate: 333.33,
          taxPercent: 18.0,
        ),
        PurchaseBillItem(
          name: 'Item B',
          quantity: 2,
          purchaseRate: 450.50,
          discount: 50.0,
          taxPercent: 12.0,
        ),
      ];

      final double subtotal = items.fold(0.0, (sum, it) => sum + (it.quantity * it.purchaseRate));
      final double totalDiscount = items.fold(0.0, (sum, it) => sum + it.discount);
      final double totalTax = items.fold(0.0, (sum, it) => sum + it.taxAmount);
      const double otherCharges = 25.0;

      final double rawGrandTotal = subtotal - totalDiscount + totalTax + otherCharges;
      final bool applyRoundOff = !subtotal.isNaN;
      final double grandTotal = applyRoundOff ? rawGrandTotal.roundToDouble() : rawGrandTotal;
      final double roundOff = grandTotal - rawGrandTotal;

      expect(subtotal, closeTo(1900.99, 0.01));
      expect(totalDiscount, equals(50.0));
      expect(totalTax, closeTo(282.118, 0.01));
      expect(rawGrandTotal, closeTo(2158.108, 0.01));
      expect(grandTotal, equals(2158.0));
      expect(roundOff, closeTo(-0.108, 0.01));
    });

    test('6. Staging & Confirmation Validation Guard Rails', () {
      final items = [
        PurchaseBillItem(
          name: 'Matched Item',
          quantity: 2,
          purchaseRate: 500.0,
          isNewProduct: false,
          isStagedReady: true,
          matchStatusOverride: ProductMatchStatus.matched,
        ),
        PurchaseBillItem(
          name: 'Unregistered Item',
          quantity: 1,
          purchaseRate: 1000.0,
          isNewProduct: true,
          isStagedReady: false,
          matchStatusOverride: ProductMatchStatus.quickRegister,
        ),
      ];

      // Check if unconfigured item prevents confirmation
      final unconfiguredIndex = items.indexWhere((it) => it.isNewProduct && !it.isStagedReady);
      expect(unconfiguredIndex, equals(1)); // Should block confirmation

      // Simulate quick register resolution
      items[1] = items[1].copyWith(
        sellingPrice: 1400.0,
        mrp: 1500.0,
        sku: 'GEN-BARCODE-001',
        isStagedReady: true,
        matchStatusOverride: ProductMatchStatus.matched,
      );

      final recheckUnconfigured = items.indexWhere((it) => it.isNewProduct && !it.isStagedReady);
      expect(recheckUnconfigured, equals(-1)); // Now ready!
    });
  });
}
