// =============================================================================
// TEKFIX ERP — PURCHASE CALCULATION ENGINE (SHARED)
// Pure Dart class used by BOTH Upload Bill mode AND Manual Purchase Entry mode.
// Uses integer paise arithmetic — never double math for money totals.
// All rounding is documented at the point it occurs.
// =============================================================================

import 'purchase_models.dart';

/// Discount expressed either as a flat rupee amount or as a percentage of
/// the line's gross amount (qty × rate).
enum DiscountType { rupees, percent }

/// Additional charge (shipping, handling, etc.) with an optional GST rate.
class BillCharge {
  final String label;
  /// Gross charge amount before any GST on the charge itself.
  final double amount;
  /// GST rate on this charge (0 if not taxable).
  final double gstRate;

  const BillCharge({
    required this.label,
    required this.amount,
    this.gstRate = 0.0,
  });

  /// Charge amount in paise (rounded to nearest paisa).
  int get amountPaise => (amount * 100).round();

  /// GST on charge in paise.
  int get gstOnChargePaise =>
      gstRate > 0 ? ((amountPaise * gstRate / 100).round()) : 0;

  /// Total paise including any GST on the charge.
  int get totalPaise => amountPaise + gstOnChargePaise;
}

/// Per-line calculation result (immutable).
class LineCalcResult {
  final String itemId;
  final int quantity;
  /// Gross paise: qty × purchaseRate (rounded per unit, accumulated).
  final int grossPaise;
  /// Discount paise applied to this line.
  final int discountPaise;
  /// Taxable paise = gross − discount.
  final int taxablePaise;
  /// GST rate applied.
  final double gstRate;
  /// Total GST paise on this line = taxable × gstRate / 100, rounded.
  final int gstPaise;
  /// Line total paise = taxable + GST.
  final int lineTotalPaise;

  const LineCalcResult({
    required this.itemId,
    required this.quantity,
    required this.grossPaise,
    required this.discountPaise,
    required this.taxablePaise,
    required this.gstRate,
    required this.gstPaise,
    required this.lineTotalPaise,
  });

  double get gross => grossPaise / 100.0;
  double get discount => discountPaise / 100.0;
  double get taxable => taxablePaise / 100.0;
  double get gst => gstPaise / 100.0;
  double get lineTotal => lineTotalPaise / 100.0;
}

/// Aggregated GST summary for a single GST rate slab.
class GstSlabSummary {
  final double rate;
  final int taxablePaise;
  final int cgstPaise;  // 0 when inter-state
  final int sgstPaise;  // 0 when inter-state
  final int igstPaise;  // 0 when intra-state

  const GstSlabSummary({
    required this.rate,
    required this.taxablePaise,
    required this.cgstPaise,
    required this.sgstPaise,
    required this.igstPaise,
  });

  int get totalGstPaise => cgstPaise + sgstPaise + igstPaise;

  double get taxable => taxablePaise / 100.0;
  double get cgst => cgstPaise / 100.0;
  double get sgst => sgstPaise / 100.0;
  double get igst => igstPaise / 100.0;
  double get totalGst => totalGstPaise / 100.0;
}

/// Full bill calculation output (immutable).
class BillCalcResult {
  final List<LineCalcResult> lines;
  final List<GstSlabSummary> gstSlabs;

  // Integer paise totals
  final int subtotalPaise;        // sum of all line gross
  final int totalDiscountPaise;   // sum of all line discounts
  final int taxableValuePaise;    // subtotal − totalDiscount
  final int totalGstPaise;        // sum of all line GST
  final int cgstPaise;            // intra-state half
  final int sgstPaise;            // intra-state half
  final int igstPaise;            // inter-state full
  final int chargesGrossPaise;    // sum of charge amounts (excl charge GST)
  final int chargesGstPaise;      // GST on charges
  final int chargesTotalPaise;    // charges + charge GST
  final int rawGrandTotalPaise;   // taxableValue + totalGST + chargesTotal
  /// Round-off applied to reach grandTotal (may be negative).
  /// Rule: nearest rupee, i.e. round rawGrandTotal to nearest 100 paise.
  final int roundOffPaise;
  final int grandTotalPaise;      // rawGrandTotal + roundOff

  // Payment derived
  final int paidAmountPaise;
  final int balanceDuePaise;

  // Printed-bill mismatch (nullable — only set when user provides a printed total)
  final int? printedTotalPaise;
  final int? mismatchPaise;

  const BillCalcResult({
    required this.lines,
    required this.gstSlabs,
    required this.subtotalPaise,
    required this.totalDiscountPaise,
    required this.taxableValuePaise,
    required this.totalGstPaise,
    required this.cgstPaise,
    required this.sgstPaise,
    required this.igstPaise,
    required this.chargesGrossPaise,
    required this.chargesGstPaise,
    required this.chargesTotalPaise,
    required this.rawGrandTotalPaise,
    required this.roundOffPaise,
    required this.grandTotalPaise,
    required this.paidAmountPaise,
    required this.balanceDuePaise,
    this.printedTotalPaise,
    this.mismatchPaise,
  });

  // Double convenience getters for UI display
  double get subtotal => subtotalPaise / 100.0;
  double get totalDiscount => totalDiscountPaise / 100.0;
  double get taxableValue => taxableValuePaise / 100.0;
  double get totalGst => totalGstPaise / 100.0;
  double get cgst => cgstPaise / 100.0;
  double get sgst => sgstPaise / 100.0;
  double get igst => igstPaise / 100.0;
  double get chargesGross => chargesGrossPaise / 100.0;
  double get chargesGst => chargesGstPaise / 100.0;
  double get chargesTotal => chargesTotalPaise / 100.0;
  double get rawGrandTotal => rawGrandTotalPaise / 100.0;
  double get roundOff => roundOffPaise / 100.0;
  double get grandTotal => grandTotalPaise / 100.0;
  double get paidAmount => paidAmountPaise / 100.0;
  double get balanceDue => balanceDuePaise / 100.0;

  /// True when a printed-bill mismatch exists beyond the tolerance.
  bool get hasMismatch => mismatchPaise != null && mismatchPaise!.abs() > 0;

  String get paymentStatus {
    if (grandTotalPaise == 0) return BillPaymentStatus.paid;
    if (paidAmountPaise >= grandTotalPaise) return BillPaymentStatus.paid;
    if (paidAmountPaise > 0) return BillPaymentStatus.partiallyPaid;
    return BillPaymentStatus.unpaid;
  }
}

/// ============================================================================
/// PurchaseCalculationEngine
/// Shared, pure, unit-tested. No Flutter / Hive / Firestore dependencies.
/// ============================================================================
class PurchaseCalculationEngine {
  /// Inter-state flag controls whether IGST or CGST+SGST is used.
  ///
  /// Derive by comparing the first 2 digits of supplier GSTIN against the
  /// store state code. Store state defaults to '32' (Kerala) but the caller
  /// should read it from Db.setting('store_state_code', '32').
  final bool isInterState;

  /// Tolerance in paise for printed-bill mismatch warning (default 100 = ₹1).
  final int mismatchTolerancePaise;

  const PurchaseCalculationEngine({
    required this.isInterState,
    this.mismatchTolerancePaise = 100,
  });

  // ---------------------------------------------------------------------------
  // STATIC HELPERS
  // ---------------------------------------------------------------------------

  /// Determine inter-state flag from supplier GSTIN and store state code.
  static bool deriveInterState(String supplierGstin, String storeStateCode) {
    final cleaned = supplierGstin.trim().toUpperCase();
    if (cleaned.length < 2 || storeStateCode.isEmpty) return false;
    final supplierState = cleaned.substring(0, 2);
    return supplierState != storeStateCode.toUpperCase();
  }

  // ---------------------------------------------------------------------------
  // PER-LINE CALCULATION
  // ---------------------------------------------------------------------------

  /// Computes a single [LineCalcResult] for the given [item].
  ///
  /// [discountType] controls whether [item.discount] is treated as a flat
  /// rupee amount (DiscountType.rupees, default) or as a percentage of gross.
  LineCalcResult calcLine(
    PurchaseBillItem item, {
    DiscountType discountType = DiscountType.rupees,
  }) {
    // Gross = qty × rate (each rate rounded to nearest paisa before multiplying)
    final int ratePaise = (item.purchaseRate * 100).round();
    final int grossPaise = item.quantity * ratePaise;

    // Discount
    int discountPaise;
    if (discountType == DiscountType.percent) {
      // percentage discount: floor to paisa
      discountPaise = (grossPaise * item.discount / 100).floor();
    } else {
      // flat rupee discount stored in item.discount
      discountPaise = (item.discount * 100).round();
    }
    // Clamp so discount never exceeds gross
    discountPaise = discountPaise.clamp(0, grossPaise);

    // Taxable
    final int taxablePaise = grossPaise - discountPaise;

    // GST on taxable — rounded to nearest paisa
    final int gstPaise =
        ((taxablePaise * item.taxPercent / 100).round()).clamp(0, taxablePaise);

    // Line total
    final int lineTotalPaise = taxablePaise + gstPaise;

    return LineCalcResult(
      itemId: item.id,
      quantity: item.quantity,
      grossPaise: grossPaise,
      discountPaise: discountPaise,
      taxablePaise: taxablePaise,
      gstRate: item.taxPercent,
      gstPaise: gstPaise,
      lineTotalPaise: lineTotalPaise,
    );
  }

  // ---------------------------------------------------------------------------
  // FULL BILL CALCULATION
  // ---------------------------------------------------------------------------

  /// Computes [BillCalcResult] for the full bill.
  ///
  /// [paidAmountPaise] — amount paid against this bill in paise.
  /// [charges] — additional charges (shipping, handling, etc.).
  /// [applyRoundOff] — whether to round grand total to nearest rupee.
  /// [printedTotalPaise] — optional: user-entered printed bill total for mismatch check.
  BillCalcResult calculate({
    required List<PurchaseBillItem> items,
    int paidAmountPaise = 0,
    List<BillCharge> charges = const [],
    bool applyRoundOff = true,
    int? printedTotalPaise,
    DiscountType discountType = DiscountType.rupees,
  }) {
    // ---- Per-line calculations ----
    final lineResults = <LineCalcResult>[];
    int subtotalPaise = 0;
    int totalDiscountPaise = 0;
    int taxableValuePaise = 0;
    int totalGstPaise = 0;

    // GST slab accumulator: rate -> {taxable, gst}
    final slabTaxable = <double, int>{};
    final slabGst = <double, int>{};

    for (final item in items) {
      final lr = calcLine(item, discountType: discountType);
      lineResults.add(lr);

      subtotalPaise += lr.grossPaise;
      totalDiscountPaise += lr.discountPaise;
      taxableValuePaise += lr.taxablePaise;
      totalGstPaise += lr.gstPaise;

      // Accumulate per-slab
      slabTaxable[lr.gstRate] = (slabTaxable[lr.gstRate] ?? 0) + lr.taxablePaise;
      slabGst[lr.gstRate] = (slabGst[lr.gstRate] ?? 0) + lr.gstPaise;
    }

    // ---- Build GST slabs ----
    final gstSlabs = <GstSlabSummary>[];
    for (final rate in slabTaxable.keys.toList()..sort()) {
      final taxable = slabTaxable[rate]!;
      final gst = slabGst[rate]!;

      int cgst = 0, sgst = 0, igst = 0;
      if (isInterState) {
        igst = gst;
      } else {
        // Half-each; any odd paisa goes to cgst
        sgst = gst ~/ 2;
        cgst = gst - sgst;
      }

      gstSlabs.add(GstSlabSummary(
        rate: rate,
        taxablePaise: taxable,
        cgstPaise: cgst,
        sgstPaise: sgst,
        igstPaise: igst,
      ));
    }

    // ---- Bill-level GST split ----
    int cgstPaise = 0, sgstPaise = 0, igstPaise = 0;
    if (isInterState) {
      igstPaise = totalGstPaise;
    } else {
      sgstPaise = totalGstPaise ~/ 2;
      cgstPaise = totalGstPaise - sgstPaise;
    }

    // ---- Charges ----
    int chargesGrossPaise = 0;
    int chargesGstPaise = 0;
    for (final c in charges) {
      chargesGrossPaise += c.amountPaise;
      chargesGstPaise += c.gstOnChargePaise;
    }
    final int chargesTotalPaise = chargesGrossPaise + chargesGstPaise;

    // ---- Grand total ----
    final int rawGrandTotalPaise =
        taxableValuePaise + totalGstPaise + chargesTotalPaise;

    // Round-off: nearest rupee = nearest 100 paise.
    // roundOff = round(raw/100)*100 - raw
    int roundOffPaise = 0;
    if (applyRoundOff) {
      final int roundedPaise =
          ((rawGrandTotalPaise / 100).round()) * 100;
      roundOffPaise = roundedPaise - rawGrandTotalPaise;
    }

    final int grandTotalPaise = rawGrandTotalPaise + roundOffPaise;

    // ---- Payment ----
    final int safePaidPaise = paidAmountPaise.clamp(0, grandTotalPaise);
    final int balanceDuePaise = (grandTotalPaise - safePaidPaise).clamp(0, grandTotalPaise);

    // ---- Printed total mismatch ----
    int? mismatchPaise;
    if (printedTotalPaise != null) {
      final diff = (grandTotalPaise - printedTotalPaise).abs();
      if (diff > mismatchTolerancePaise) {
        mismatchPaise = grandTotalPaise - printedTotalPaise;
      }
    }

    return BillCalcResult(
      lines: lineResults,
      gstSlabs: gstSlabs,
      subtotalPaise: subtotalPaise,
      totalDiscountPaise: totalDiscountPaise,
      taxableValuePaise: taxableValuePaise,
      totalGstPaise: totalGstPaise,
      cgstPaise: cgstPaise,
      sgstPaise: sgstPaise,
      igstPaise: igstPaise,
      chargesGrossPaise: chargesGrossPaise,
      chargesGstPaise: chargesGstPaise,
      chargesTotalPaise: chargesTotalPaise,
      rawGrandTotalPaise: rawGrandTotalPaise,
      roundOffPaise: roundOffPaise,
      grandTotalPaise: grandTotalPaise,
      paidAmountPaise: safePaidPaise,
      balanceDuePaise: balanceDuePaise,
      printedTotalPaise: printedTotalPaise,
      mismatchPaise: mismatchPaise,
    );
  }
}

