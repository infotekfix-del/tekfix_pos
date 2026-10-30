// =============================================================================
// TEKFIX ERP — PURCHASE CALCULATION ENGINE UNIT TESTS
// Covers: intra/inter-state GST, % & Rs discounts, mixed GST rates,
// charges with/without GST, round-off, no double-counting, mismatch tolerance.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/purchases/purchase_calculation_engine.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

// Helper to create a minimal PurchaseBillItem
PurchaseBillItem _item({
  String id = 'ITEM_1',
  String name = 'Test Product',
  int qty = 1,
  double rate = 100.0,
  double discount = 0.0,
  double taxPercent = 18.0,
  double sellingPrice = 150.0,
}) {
  return PurchaseBillItem(
    id: id,
    name: name,
    quantity: qty,
    purchaseRate: rate,
    discount: discount,
    taxPercent: taxPercent,
    sellingPrice: sellingPrice,
  );
}

void main() {
  group('PurchaseCalculationEngine — Unit Tests', () {
    // -------------------------------------------------------------------------
    // 1. Intra-state: CGST + SGST (half each)
    // -------------------------------------------------------------------------
    group('1. Intra-state GST (CGST + SGST)', () {
      test('1a. Single item 18% GST intra-state', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 1, rate: 1000.0, discount: 0, taxPercent: 18);
        final result = engine.calculate(items: [item]);

        // Gross = 1 × ₹1000 = ₹1000 = 100000 paise
        expect(result.subtotalPaise, equals(100000));
        // Taxable = 100000 (no discount)
        expect(result.taxableValuePaise, equals(100000));
        // GST 18% on 100000 = 18000 paise
        expect(result.totalGstPaise, equals(18000));
        // Intra-state: CGST = SGST = 9000
        expect(result.cgstPaise, equals(9000));
        expect(result.sgstPaise, equals(9000));
        expect(result.igstPaise, equals(0));
        // Grand total raw = 100000 + 18000 = 118000
        // Round-off: 118000 paise = ₹1180.00 → already whole rupee → roundOff = 0
        expect(result.roundOffPaise, equals(0));
        expect(result.grandTotalPaise, equals(118000));
        expect(result.grandTotal, closeTo(1180.0, 0.001));
      });

      test('1b. Multiple items, mixed 5% and 18% GST, intra-state', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final items = [
          _item(id: 'A', qty: 2, rate: 500.0, discount: 0, taxPercent: 18),
          _item(id: 'B', qty: 3, rate: 200.0, discount: 0, taxPercent: 5),
        ];
        final result = engine.calculate(items: items);

        // Item A: gross = 100000 paise, GST 18% = 18000
        // Item B: gross = 60000 paise, GST 5% = 3000
        expect(result.subtotalPaise, equals(160000));
        expect(result.totalGstPaise, equals(21000));

        // Slab breakdown
        expect(result.gstSlabs.length, equals(2));
        final slab5 = result.gstSlabs.firstWhere((s) => s.rate == 5.0);
        final slab18 = result.gstSlabs.firstWhere((s) => s.rate == 18.0);

        expect(slab5.taxablePaise, equals(60000));
        expect(slab5.cgstPaise + slab5.sgstPaise, equals(3000));
        expect(slab5.igstPaise, equals(0));

        expect(slab18.taxablePaise, equals(100000));
        expect(slab18.cgstPaise + slab18.sgstPaise, equals(18000));
        expect(slab18.igstPaise, equals(0));

        // Intra-state: no IGST
        expect(result.igstPaise, equals(0));
      });
    });

    // -------------------------------------------------------------------------
    // 2. Inter-state: IGST only
    // -------------------------------------------------------------------------
    group('2. Inter-state GST (IGST)', () {
      test('2a. Single item 18% GST inter-state', () {
        final engine = PurchaseCalculationEngine(isInterState: true);
        final item = _item(qty: 2, rate: 500.0, discount: 0, taxPercent: 18);
        final result = engine.calculate(items: [item]);

        expect(result.cgstPaise, equals(0));
        expect(result.sgstPaise, equals(0));
        expect(result.igstPaise, equals(18000)); // 18% on 100000 = 18000
        expect(result.totalGstPaise, equals(18000));
      });

      test('2b. Mixed GST rates inter-state', () {
        final engine = PurchaseCalculationEngine(isInterState: true);
        final items = [
          _item(id: 'A', qty: 1, rate: 1000.0, taxPercent: 28),
          _item(id: 'B', qty: 5, rate: 100.0, taxPercent: 12),
        ];
        final result = engine.calculate(items: items);

        // A: gross 100000, GST 28% = 28000
        // B: gross 50000, GST 12% = 6000
        expect(result.igstPaise, equals(34000));
        expect(result.cgstPaise, equals(0));
        expect(result.sgstPaise, equals(0));
      });
    });

    // -------------------------------------------------------------------------
    // 3. Discounts: flat rupee and percentage
    // -------------------------------------------------------------------------
    group('3. Discounts', () {
      test('3a. Flat rupee discount reduces taxable correctly', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        // Item: 10 units × ₹100 = ₹1000 gross, ₹50 flat discount
        final item = _item(qty: 10, rate: 100.0, discount: 50.0, taxPercent: 18);
        final lr = engine.calcLine(item);

        expect(lr.grossPaise, equals(100000));    // 10 × 10000
        expect(lr.discountPaise, equals(5000));   // ₹50 = 5000 paise
        expect(lr.taxablePaise, equals(95000));   // 100000 - 5000
        expect(lr.gstPaise, equals(17100));       // 18% of 95000 = 17100
        expect(lr.lineTotalPaise, equals(112100));
      });

      test('3b. Percentage discount via DiscountType.percent', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        // 10% discount on ₹500 gross = ₹50 discount
        final item = _item(qty: 1, rate: 500.0, discount: 10.0, taxPercent: 18);
        final lr = engine.calcLine(item, discountType: DiscountType.percent);

        expect(lr.grossPaise, equals(50000));
        // 10% of 50000 = 5000, floor = 5000
        expect(lr.discountPaise, equals(5000));
        expect(lr.taxablePaise, equals(45000));
        expect(lr.gstPaise, equals(8100)); // 18% of 45000 = 8100
      });

      test('3c. Discount cannot exceed gross (clamped to gross)', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        // Discount > gross: discount ₹2000 on ₹100 item
        final item = _item(qty: 1, rate: 100.0, discount: 200.0, taxPercent: 18);
        final lr = engine.calcLine(item);

        // Discount clamped to gross (10000 paise)
        expect(lr.discountPaise, equals(10000));
        expect(lr.taxablePaise, equals(0));
        expect(lr.gstPaise, equals(0));
        expect(lr.lineTotalPaise, equals(0));
      });

      test('3d. Mixed discounts in one bill, no double-counting', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final items = [
          _item(id: 'A', qty: 2, rate: 300.0, discount: 20.0, taxPercent: 18), // flat Rs discount
          _item(id: 'B', qty: 5, rate: 100.0, discount: 0.0, taxPercent: 5),   // no discount
        ];
        final result = engine.calculate(items: items);

        // A: gross 60000, discount 2000 (₹20 flat), taxable 58000, GST 18% = 10440
        // B: gross 50000, discount 0, taxable 50000, GST 5% = 2500
        expect(result.subtotalPaise, equals(110000));
        expect(result.totalDiscountPaise, equals(2000));
        expect(result.taxableValuePaise, equals(108000));
        expect(result.totalGstPaise, equals(12940)); // 10440 + 2500
        // No double count: grand = taxable + GST + charges (0 here)
        expect(result.rawGrandTotalPaise, equals(108000 + 12940));
      });
    });

    // -------------------------------------------------------------------------
    // 4. Charges (with and without GST)
    // -------------------------------------------------------------------------
    group('4. Charges with/without GST', () {
      test('4a. Shipping with 18% GST', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 1, rate: 1000.0, discount: 0, taxPercent: 18);
        final shipping = BillCharge(label: 'Shipping', amount: 100.0, gstRate: 18.0);
        final result = engine.calculate(items: [item], charges: [shipping]);

        // Charge: ₹100 = 10000 paise, GST 18% = 1800 paise
        expect(result.chargesGrossPaise, equals(10000));
        expect(result.chargesGstPaise, equals(1800));
        expect(result.chargesTotalPaise, equals(11800));

        // Grand raw = taxableValue(100000) + GST(18000) + charges(11800) = 129800
        expect(result.rawGrandTotalPaise, equals(129800));
      });

      test('4b. Handling charge without GST', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 1, rate: 1000.0, discount: 0, taxPercent: 0);
        final handling = BillCharge(label: 'Handling', amount: 50.0, gstRate: 0.0);
        final result = engine.calculate(items: [item], charges: [handling]);

        expect(result.chargesGrossPaise, equals(5000));
        expect(result.chargesGstPaise, equals(0));
        expect(result.chargesTotalPaise, equals(5000));
        expect(result.rawGrandTotalPaise, equals(100000 + 5000));
      });

      test('4c. Multiple charges, mixed GST rates', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 1, rate: 500.0, discount: 0, taxPercent: 5);
        final charges = [
          BillCharge(label: 'Shipping', amount: 200.0, gstRate: 18.0),
          BillCharge(label: 'Packaging', amount: 50.0, gstRate: 0.0),
        ];
        final result = engine.calculate(items: [item], charges: charges);

        // Item: gross 50000, tax 5% = 2500
        // Ship: 20000 + 3600 = 23600
        // Pack: 5000 + 0 = 5000
        expect(result.chargesGrossPaise, equals(25000));
        expect(result.chargesGstPaise, equals(3600));
        expect(result.chargesTotalPaise, equals(28600));
        expect(result.rawGrandTotalPaise, equals(50000 + 2500 + 28600));
      });
    });

    // -------------------------------------------------------------------------
    // 5. Round-off
    // -------------------------------------------------------------------------
    group('5. Round-off', () {
      test('5a. Round-off applied to nearest rupee', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        // Item ₹100, 18% GST = ₹18 → grand ₹118 → exact rupee → no round-off
        final item = _item(qty: 1, rate: 100.0, discount: 0, taxPercent: 18);
        final result = engine.calculate(items: [item]);
        expect(result.roundOffPaise, equals(0));
        expect(result.grandTotalPaise, equals(result.rawGrandTotalPaise));
      });

      test('5b. Round-off rounds up (positive)', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        // ₹100, 5% GST = ₹5 → raw = ₹105.00 → already whole → roundOff = 0
        // Use rate 101 to create 5% = 5.05 → raw = 101 + 5.05 = 106.05
        // → nearest rupee = 106 → roundOff = -5 paise
        final item = _item(qty: 1, rate: 101.0, discount: 0, taxPercent: 5);
        final lr = engine.calcLine(item);
        expect(lr.grossPaise, equals(10100));
        // gross = 10100, gst 5% of 10100 = 505, raw = 10605
        // round to nearest 100 = 10600 → roundOff = -5 paise
        final result = engine.calculate(items: [item]);
        expect(result.rawGrandTotalPaise, equals(10605));
        expect(result.roundOffPaise, equals(-5)); // floor to nearest rupee
        expect(result.grandTotalPaise, equals(10600));
      });

      test('5c. Round-off disabled', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 1, rate: 101.0, discount: 0, taxPercent: 5);
        final result = engine.calculate(items: [item], applyRoundOff: false);
        expect(result.roundOffPaise, equals(0));
        expect(result.grandTotalPaise, equals(result.rawGrandTotalPaise));
      });
    });

    // -------------------------------------------------------------------------
    // 6. Payment — balance due and status
    // -------------------------------------------------------------------------
    group('6. Payment and balance', () {
      test('6a. Fully paid', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 1, rate: 1000.0, taxPercent: 0);
        final result = engine.calculate(items: [item], paidAmountPaise: 100000);
        expect(result.paidAmountPaise, equals(100000));
        expect(result.balanceDuePaise, equals(0));
        expect(result.paymentStatus, equals(BillPaymentStatus.paid));
      });

      test('6b. Partially paid', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 1, rate: 1000.0, taxPercent: 0);
        final result = engine.calculate(items: [item], paidAmountPaise: 40000);
        expect(result.paidAmountPaise, equals(40000));
        expect(result.balanceDuePaise, equals(60000));
        expect(result.paymentStatus, equals(BillPaymentStatus.partiallyPaid));
      });

      test('6c. Unpaid', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 1, rate: 1000.0, taxPercent: 0);
        final result = engine.calculate(items: [item], paidAmountPaise: 0);
        expect(result.balanceDuePaise, equals(100000));
        expect(result.paymentStatus, equals(BillPaymentStatus.unpaid));
      });

      test('6d. Paid amount clamped to grand total (no negative balance)', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 1, rate: 1000.0, taxPercent: 0);
        // Pay more than grand total — should be clamped
        final result = engine.calculate(items: [item], paidAmountPaise: 200000);
        expect(result.paidAmountPaise, equals(100000)); // clamped
        expect(result.balanceDuePaise, equals(0));
      });
    });

    // -------------------------------------------------------------------------
    // 7. Mismatch with printed bill total
    // -------------------------------------------------------------------------
    group('7. Printed total mismatch', () {
      test('7a. No mismatch when within tolerance (default ₹1 = 100 paise)', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 1, rate: 1000.0, taxPercent: 18);
        // Grand = 1180.00 = 118000 paise. Printed = 118050 paise → diff = 50 < 100
        final result = engine.calculate(items: [item], printedTotalPaise: 118050);
        expect(result.hasMismatch, isFalse);
        expect(result.mismatchPaise, isNull);
      });

      test('7b. Mismatch flagged when beyond tolerance', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 1, rate: 1000.0, taxPercent: 18);
        // Computed = 118000, printed = 119500 → diff 1500 > 100 → mismatch
        final result = engine.calculate(items: [item], printedTotalPaise: 119500);
        expect(result.hasMismatch, isTrue);
        expect(result.mismatchPaise, equals(118000 - 119500)); // negative = computed < printed
      });

      test('7c. Custom tolerance', () {
        final engine = PurchaseCalculationEngine(
          isInterState: false,
          mismatchTolerancePaise: 500, // ₹5
        );
        final item = _item(qty: 1, rate: 1000.0, taxPercent: 18);
        // Diff = 400 paise = ₹4, within ₹5 tolerance → no mismatch
        final result = engine.calculate(items: [item], printedTotalPaise: 118400);
        expect(result.hasMismatch, isFalse);
      });
    });

    // -------------------------------------------------------------------------
    // 8. Zero items / edge cases
    // -------------------------------------------------------------------------
    group('8. Edge cases', () {
      test('8a. Empty items list', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final result = engine.calculate(items: []);
        expect(result.subtotalPaise, equals(0));
        expect(result.grandTotalPaise, equals(0));
        expect(result.paymentStatus, equals(BillPaymentStatus.paid)); // 0 total → paid
      });

      test('8b. Zero tax rate', () {
        final engine = PurchaseCalculationEngine(isInterState: false);
        final item = _item(qty: 5, rate: 200.0, discount: 0, taxPercent: 0);
        final result = engine.calculate(items: [item]);
        expect(result.totalGstPaise, equals(0));
        expect(result.grandTotalPaise, equals(100000));
      });

      test('8c. deriveInterState: same state code → intra-state', () {
        expect(
          PurchaseCalculationEngine.deriveInterState('32AABCT1332L1ZW', '32'),
          isFalse,
        );
      });

      test('8d. deriveInterState: different state code → inter-state', () {
        expect(
          PurchaseCalculationEngine.deriveInterState('07AABCT1332L1ZW', '32'),
          isTrue,
        );
      });

      test('8e. deriveInterState: empty GSTIN → intra-state (safe default)', () {
        expect(
          PurchaseCalculationEngine.deriveInterState('', '32'),
          isFalse,
        );
      });
    });
  });
}

