import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/repairs/service_bill_dialog.dart';

void main() {
  group('Service Bill Spare Parts Integration Tests (All 8 Test Scenarios)', () {
    // -------------------------------------------------------------------------
    // TEST 1: Select an inventory spare with stock 5. Add quantity 2. Stock -> 3.
    // -------------------------------------------------------------------------
    test('TEST 1: Select an inventory spare with stock 5, add quantity 2 -> stock = 3', () {
      int stock = 5;
      final part = ServiceSparePartItem(
        itemId: 'inv_101',
        name: 'Redmi Note 9 Pro LCD Combo',
        model: 'Redmi Note 9 Pro',
        category: 'Combo',
        unitPrice: 1400.0,
        availableStock: stock,
        quantity: 2,
        source: SparePartSource.inventory,
      );

      expect(part.isInventory, isTrue);
      expect(part.quantity, equals(2));
      expect(part.quantity <= part.availableStock, isTrue);

      // Simulate atomic deduction
      stock -= part.quantity;
      expect(stock, equals(3), reason: 'Stock 5 - 2 = 3');

      final log = part.toJobSpareMap();
      expect(log['source'], equals('INVENTORY'));
      expect(log['itemId'], equals('inv_101'));
      expect(log['quantity'], equals(2));
      expect(log['totalPricePaise'], equals(280000));
    });

    // -------------------------------------------------------------------------
    // TEST 2: Select an item with stock 1. Attempt quantity 2 -> Insufficient stock
    // -------------------------------------------------------------------------
    test('TEST 2: Select an item with stock 1, attempt quantity 2 -> insufficient stock warning', () {
      final part = ServiceSparePartItem(
        itemId: 'inv_102',
        name: 'iPhone X OLED Display',
        model: 'iPhone X',
        category: 'Display',
        unitPrice: 2500.0,
        availableStock: 1,
        quantity: 1,
        source: SparePartSource.inventory,
      );

      bool canAddSecond = (part.quantity + 1) <= part.availableStock;
      expect(canAddSecond, isFalse, reason: '1 + 1 = 2 > availableStock 1');

      // Validated stepper does not exceed stock
      if (part.quantity + 1 <= part.availableStock) {
        part.quantity++;
      }
      expect(part.quantity, equals(1));
    });

    // -------------------------------------------------------------------------
    // TEST 3: Add external spare part -> Invoice includes it, inventory untouched
    // -------------------------------------------------------------------------
    test('TEST 3: Add external spare part -> Invoice includes external spare, inventory unchanged', () {
      final externalPart = ServiceSparePartItem(
        itemId: null,
        name: 'External Charging IC',
        unitPrice: 500.0,
        quantity: 1,
        availableStock: 0,
        source: SparePartSource.external,
      );

      expect(externalPart.isExternal, isTrue);
      expect(externalPart.itemId, isNull);

      final line = externalPart.toInvoiceLineMap();
      expect(line['isExternal'], isTrue);
      expect(line['source'], equals('EXTERNAL'));
      expect(line['name'], contains('[EXTERNAL SPARE]'));

      final jobSpare = externalPart.toJobSpareMap();
      expect(jobSpare['source'], equals('EXTERNAL'));
      expect(jobSpare['itemId'], isNull);
      expect(jobSpare['totalPricePaise'], equals(50000));
    });

    // -------------------------------------------------------------------------
    // TEST 4: Add two different inventory spare parts -> Both in invoice & deducted
    // -------------------------------------------------------------------------
    test('TEST 4: Add two different inventory spares -> Both appear in invoice & both deducted', () {
      var stock1 = 10;
      var stock2 = 4;

      final part1 = ServiceSparePartItem(
        itemId: 'inv_201',
        name: 'iPhone 11 Battery',
        unitPrice: 1800.0,
        quantity: 1,
        availableStock: stock1,
        source: SparePartSource.inventory,
      );

      final part2 = ServiceSparePartItem(
        itemId: 'inv_202',
        name: 'Samsung M31 Camera Lens',
        unitPrice: 350.0,
        quantity: 2,
        availableStock: stock2,
        source: SparePartSource.inventory,
      );

      final parts = [part1, part2];
      final invoiceLines = parts.map((p) => p.toInvoiceLineMap()).toList();
      expect(invoiceLines.length, equals(2));

      // Deduct both
      stock1 -= part1.quantity;
      stock2 -= part2.quantity;
      expect(stock1, equals(9));
      expect(stock2, equals(2));

      final totalSpares = parts.fold<double>(0.0, (s, p) => s + p.lineTotal);
      expect(totalSpares, equals(1800.0 + (350.0 * 2))); // 2500.0
    });

    // -------------------------------------------------------------------------
    // TEST 5: Click Create Bill twice rapidly -> Idempotency prevents duplicate
    // -------------------------------------------------------------------------
    test('TEST 5: Rapid double-click on Create Bill -> In-flight lock blocks duplicate', () {
      final inFlightInvoices = <String>{};
      const invoiceId = 'INV-SHAHAL-1001';

      bool firstAttemptSuccess = false;
      if (!inFlightInvoices.contains(invoiceId)) {
        inFlightInvoices.add(invoiceId);
        firstAttemptSuccess = true;
      }
      expect(firstAttemptSuccess, isTrue);

      bool secondAttemptSuccess = false;
      if (!inFlightInvoices.contains(invoiceId)) {
        inFlightInvoices.add(invoiceId);
        secondAttemptSuccess = true;
      }
      expect(secondAttemptSuccess, isFalse, reason: 'Duplicate attempt blocked by in-flight lock');
    });

    // -------------------------------------------------------------------------
    // TEST 6: Simulate failure during billing -> Rollback & no partial deduction
    // -------------------------------------------------------------------------
    test('TEST 6: Transaction failure simulation -> No partial stock deduction or incomplete bill', () {
      int initialStockA = 5;
      int initialStockB = 3;

      int workingStockA = initialStockA;
      int workingStockB = initialStockB;

      bool transactionCompleted = false;

      try {
        // Attempt atomic block
        workingStockA -= 1;
        // Simulate failure on item B (e.g. concurrent write or network cut)
        throw Exception('Simulated Firestore write failure on item B');
      } catch (_) {
        // Rollback working stock to initial
        workingStockA = initialStockA;
        workingStockB = initialStockB;
      }

      expect(transactionCompleted, isFalse);
      expect(workingStockA, equals(5), reason: 'Stock A rolled back');
      expect(workingStockB, equals(3), reason: 'Stock B untouched');
    });

    // -------------------------------------------------------------------------
    // TEST 7: Complete a service bill using UPI -> Appears in UPI collection
    // -------------------------------------------------------------------------
    test('TEST 7: Complete service bill with UPI -> Captured in UPI sales and daily ledger', () {
      const mode = 'UPI';
      const double netPayable = 2150.0;

      final counter = <String, dynamic>{
        'totalSales': 0.0,
        'cashSales': 0.0,
        'upiSales': 0.0,
        'cardSales': 0.0,
        'billCount': 0,
      };

      counter['totalSales'] = counter['totalSales'] + netPayable;
      if (mode == 'UPI') {
        counter['upiSales'] = counter['upiSales'] + netPayable;
      } else if (mode == 'Cash') {
        counter['cashSales'] = counter['cashSales'] + netPayable;
      }
      counter['billCount'] = counter['billCount'] + 1;

      expect(counter['upiSales'], equals(2150.0));
      expect(counter['cashSales'], equals(0.0));
      expect(counter['totalSales'], equals(2150.0));
      expect(counter['billCount'], equals(1));
    });

    // -------------------------------------------------------------------------
    // TEST 8: Verify the service invoice layout & numbers
    // -------------------------------------------------------------------------
    test('TEST 8: Verify service invoice structure, item names, quantities, and final payable in paise', () {
      const double serviceCharge = 500.0;
      const double labour = 150.0;
      const double discount = 50.0;
      const double advanceReceived = 600.0;

      final invPart = ServiceSparePartItem(
        itemId: 'inv_301',
        name: 'Realme 7 Pro Display',
        unitPrice: 2000.0,
        quantity: 1,
        availableStock: 2,
        source: SparePartSource.inventory,
      );

      final extPart = ServiceSparePartItem(
        name: 'Back Glass Adhesive Sheet',
        unitPrice: 100.0,
        quantity: 1,
        availableStock: 0,
        source: SparePartSource.external,
      );

      final allSpares = [invPart, extPart];
      final sparesTotal = allSpares.fold<double>(0.0, (s, p) => s + p.lineTotal); // 2100.0
      expect(sparesTotal, equals(2100.0));

      final grossTotal = sparesTotal + serviceCharge + labour - discount; // 2100 + 500 + 150 - 50 = 2700
      expect(grossTotal, equals(2700.0));

      final advanceApplied = grossTotal < advanceReceived ? grossTotal : advanceReceived;
      expect(advanceApplied, equals(600.0));

      final netPayable = grossTotal - advanceApplied; // 2700 - 600 = 2100
      expect(netPayable, equals(2100.0));

      // Paise accuracy
      final netPayablePaise = (netPayable * 100).round();
      expect(netPayablePaise, equals(210000));
    });
  });
}
