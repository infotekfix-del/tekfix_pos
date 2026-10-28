import 'package:hive/hive.dart';
import '../main.dart'
    show
        Db,
        boxPurchaseBills,
        boxVendorPayments,
        boxPurchases,
        boxParties,
        boxItems,
        boxSettings,
        boxAudit;
import '../inventory/consumables_service.dart';
import 'purchase_models.dart';

class PurchaseBillService {
  PurchaseBillService._();
  static final PurchaseBillService instance = PurchaseBillService._();

  Box get _billsBox => Hive.box(boxPurchaseBills);
  Box get _paymentsBox => Hive.box(boxVendorPayments);

  // ---------------------------------------------------------------------------
  // 1. SEQUENTIAL ID GENERATION
  // ---------------------------------------------------------------------------

  Future<String> generateBillNumber() async {
    final year = DateTime.now().year;
    final key = 'purchase_bill_counter_$year';
    final current = (Db.settings.get(key) as num?)?.toInt() ?? 0;
    final next = current + 1;
    await Db.settings.put(key, next);
    return 'PB-$year-${next.toString().padLeft(4, '0')}';
  }

  Future<String> generatePaymentId() async {
    final year = DateTime.now().year;
    final key = 'vendor_payment_counter_$year';
    final current = (Db.settings.get(key) as num?)?.toInt() ?? 0;
    final next = current + 1;
    await Db.settings.put(key, next);
    return 'PAY-$year-${next.toString().padLeft(4, '0')}';
  }

  // ---------------------------------------------------------------------------
  // 2. VENDOR MANAGEMENT & DUPLICATE CHECK
  // ---------------------------------------------------------------------------

  /// Retrieves all vendors/suppliers from Db.parties
  List<Map<String, dynamic>> getVendors() {
    final list = <Map<String, dynamic>>[];
    for (final key in Db.parties.keys) {
      final raw = Db.parties.get(key);
      if (raw is! Map) continue;
      final type = raw['type']?.toString();
      if (type == 'Supplier') {
        list.add({
          'key': key,
          'id': raw['_id']?.toString() ?? '$key',
          'name': raw['name']?.toString() ?? '',
          'phone': raw['phone']?.toString() ?? '',
          'address': raw['address']?.toString() ?? '',
          'gst': raw['gst']?.toString() ?? '',
          'balance': (raw['balance'] as num?)?.toDouble() ?? 0.0,
          'notes': raw['notes']?.toString() ?? '',
        });
      }
    }
    list.sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
    return list;
  }

  /// Calculates outstanding balance for a vendor (positive value indicates debt owed to vendor)
  double getVendorOutstandingBalance(dynamic vendorKey) {
    if (vendorKey == null) return 0.0;
    final raw = Db.parties.get(vendorKey);
    if (raw is Map) {
      final bal = (raw['balance'] as num?)?.toDouble() ?? 0.0;
      // In TekFix, supplier balance is negative when we owe money
      return bal < 0 ? -bal : 0.0;
    }
    return 0.0;
  }

  /// Adds a new vendor to Db.parties, preventing duplicate names or phones
  Future<Map<String, dynamic>> addNewVendor({
    required String name,
    required String phone,
    String? address,
    String? gst,
    String? notes,
  }) async {
    final trimmedName = name.trim();
    final trimmedPhone = phone.trim();

    if (trimmedName.isEmpty) {
      throw Exception('Vendor name cannot be empty');
    }

    // Check for existing vendor with same name or phone
    for (final key in Db.parties.keys) {
      final raw = Db.parties.get(key);
      if (raw is Map && raw['type'] == 'Supplier') {
        final existingName = raw['name']?.toString().toLowerCase().trim();
        final existingPhone = raw['phone']?.toString().trim();
        if (existingName == trimmedName.toLowerCase()) {
          throw Exception('A vendor with the name "$trimmedName" already exists');
        }
        if (trimmedPhone.isNotEmpty && existingPhone == trimmedPhone) {
          throw Exception('A vendor with phone number "$trimmedPhone" already exists (${raw['name']})');
        }
      }
    }

    final newParty = <String, dynamic>{
      'name': trimmedName,
      'phone': trimmedPhone,
      'address': address?.trim() ?? '',
      'gst': gst?.trim() ?? '',
      'notes': notes?.trim() ?? '',
      'type': 'Supplier',
      'balance': 0.0,
      'createdAt': DateTime.now().toIso8601String(),
    };

    final key = await Db.parties.add(newParty);
    if (Db.audit.isOpen) {
      await Db.audit.add({
        'action': 'Vendor Created',
        'entity': 'Supplier',
        'entityId': '$key',
        'timestamp': DateTime.now().toIso8601String(),
        'details': newParty,
      });
    }

    return {
      'key': key,
      'id': '$key',
      ...newParty,
    };
  }

  /// Checks if a vendor invoice number already exists for this vendor
  PurchaseBill? checkDuplicateInvoice(String vendorInvoiceNumber, dynamic vendorKey) {
    if (vendorInvoiceNumber.trim().isEmpty || vendorKey == null) return null;
    final queryInv = vendorInvoiceNumber.trim().toLowerCase();

    for (final k in _billsBox.keys) {
      final raw = _billsBox.get(k);
      if (raw is Map) {
        final inv = raw['vendorInvoiceNumber']?.toString().trim().toLowerCase();
        final vKey = raw['vendorKey'];
        if (inv == queryInv && (vKey == vendorKey || '$vKey' == '$vendorKey')) {
          return PurchaseBill.fromMap(raw, k);
        }
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 3. WARRANTY DURATION CALCULATOR
  // ---------------------------------------------------------------------------

  DateTime? calculateItemWarrantyExpiry(
    DateTime purchaseDate,
    String duration, {
    int? customDays,
    int? customMonths,
  }) {
    final d = duration.trim().toLowerCase();
    if (d == ItemWarrantyDuration.noWarranty.toLowerCase() || d.isEmpty || d == 'none') {
      return null;
    }

    if (d.contains('3 month') || d == '3m') {
      return DateTime(purchaseDate.year, purchaseDate.month + 3, purchaseDate.day);
    } else if (d.contains('6 month') || d == '6m') {
      return DateTime(purchaseDate.year, purchaseDate.month + 6, purchaseDate.day);
    } else if (d.contains('12 month') || d.contains('1 year') || d == '1y') {
      return DateTime(purchaseDate.year + 1, purchaseDate.month, purchaseDate.day);
    } else if (d.contains('24 month') || d.contains('2 year') || d == '2y') {
      return DateTime(purchaseDate.year + 2, purchaseDate.month, purchaseDate.day);
    } else if (customMonths != null && customMonths > 0) {
      return DateTime(purchaseDate.year, purchaseDate.month + customMonths, purchaseDate.day);
    } else if (customDays != null && customDays > 0) {
      return purchaseDate.add(Duration(days: customDays));
    } else {
      // Fallback: extract digits
      final match = RegExp(r'\d+').firstMatch(d);
      final count = match != null ? int.tryParse(match.group(0)!) ?? 0 : 0;
      if (count > 0) {
        if (d.contains('year') || d.contains('yr')) {
          return DateTime(purchaseDate.year + count, purchaseDate.month, purchaseDate.day);
        }
        return DateTime(purchaseDate.year, purchaseDate.month + count, purchaseDate.day);
      }
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 4. SAVE PURCHASE BILL (WITH INVENTORY & FINANCIAL INTEGRATION)
  // ---------------------------------------------------------------------------

  Future<PurchaseBill> savePurchaseBill({
    dynamic key,
    String? billNumber,
    required String vendorInvoiceNumber,
    required dynamic vendorKey,
    required String vendorName,
    required String vendorPhone,
    String? vendorGst,
    String? vendorAddress,
    required DateTime purchaseDate,
    required List<PurchaseBillItem> items,
    double otherCharges = 0.0,
    double initialPaidAmount = 0.0,
    String initialPaymentMethod = 'Cash',
    String? initialPaymentReference,
    BillAttachment? attachment,
    required String staffId,
    required String staffName,
    String? notes,
    bool isDraft = false,
  }) async {
    if (vendorKey == null && vendorName.trim().isEmpty) {
      throw Exception('Please select or create a vendor');
    }
    if (items.isEmpty) {
      throw Exception('Purchase bill must have at least one item');
    }

    final now = DateTime.now();
    final finalBillNum = billNumber ?? await generateBillNumber();

    // 1. Calculate totals accurately
    double subtotal = 0.0;
    int totalQty = 0;
    double totalDiscount = 0.0;
    double totalTax = 0.0;

    for (final it in items) {
      subtotal += (it.quantity * it.purchaseRate);
      totalQty += it.quantity;
      totalDiscount += it.discount;
      totalTax += it.taxAmount;
    }

    final double grandTotal = (subtotal - totalDiscount + totalTax + otherCharges);
    final double safePaid = initialPaidAmount.clamp(0.0, grandTotal);
    final double balanceDue = (grandTotal - safePaid).clamp(0.0, grandTotal);

    String paymentStatus;
    if (isDraft) {
      paymentStatus = BillPaymentStatus.draft;
    } else if (balanceDue <= 0.001) {
      paymentStatus = BillPaymentStatus.paid;
    } else if (safePaid > 0.001) {
      paymentStatus = BillPaymentStatus.partiallyPaid;
    } else {
      paymentStatus = BillPaymentStatus.unpaid;
    }

    final paymentsList = <VendorPaymentRecord>[];
    if (safePaid > 0) {
      final payId = await generatePaymentId();
      final payRecord = VendorPaymentRecord(
        paymentId: payId,
        billNumber: finalBillNum,
        vendorKey: vendorKey,
        vendorName: vendorName,
        amount: safePaid,
        paymentDate: purchaseDate,
        paymentMethod: initialPaymentMethod,
        transactionReference: initialPaymentReference?.trim().isNotEmpty == true
            ? initialPaymentReference!.trim()
            : 'Initial Payment for $finalBillNum',
        notes: 'Initial payment recorded during purchase bill entry',
        recordedById: staffId,
        recordedByName: staffName,
      );
      paymentsList.add(payRecord);
    }

    final bill = PurchaseBill(
      key: key,
      billNumber: finalBillNum,
      vendorInvoiceNumber: vendorInvoiceNumber.trim(),
      vendorKey: vendorKey,
      vendorName: vendorName.trim(),
      vendorPhone: vendorPhone.trim(),
      vendorGst: vendorGst?.trim(),
      vendorAddress: vendorAddress?.trim(),
      purchaseDate: purchaseDate,
      uploadTimestamp: now,
      items: items,
      subtotal: subtotal,
      totalQuantity: totalQty,
      totalDiscount: totalDiscount,
      totalTax: totalTax,
      otherCharges: otherCharges,
      grandTotal: grandTotal,
      paidAmount: safePaid,
      balanceDue: balanceDue,
      paymentStatus: paymentStatus,
      payments: paymentsList,
      attachment: attachment,
      createdById: staffId,
      createdByName: staffName,
      notes: notes?.trim(),
      isDraft: isDraft,
      createdAt: now,
      updatedAt: now,
    );

    // Save to Hive purchaseBills box
    dynamic savedKey;
    if (key != null) {
      await _billsBox.put(key, bill.toMap());
      savedKey = key;
    } else {
      savedKey = await _billsBox.add(bill.toMap());
    }

    // Save initial payment to vendorPayments box if any
    for (final p in paymentsList) {
      await _paymentsBox.add(p.toMap()..['billKey'] = savedKey);
    }

    // 2. If NOT draft, execute inventory stock increments & financial mutations atomically
    if (!isDraft) {
      // 2a. Update Inventory in Db.items & log stock movement
      for (final line in items) {
        dynamic targetKey = line.itemKey;
        if (targetKey == null) {
          // Attempt match by item name
          for (final k in Db.items.keys) {
            final existing = Db.items.get(k);
            if (existing is Map &&
                (existing['name']?.toString().toLowerCase() == line.name.toLowerCase())) {
              targetKey = k;
              break;
            }
          }
        }

        if (targetKey != null && Db.items.containsKey(targetKey)) {
          final cur = Db.items.get(targetKey);
          if (cur is Map) {
            final curMap = Map<String, dynamic>.from(cur);
            final oldStock = (curMap['stock'] as num?)?.toInt() ?? 0;
            final isMultiUnit = line.isMultiUnit || (curMap['isMultiUnit'] == true);
            if (isMultiUnit) {
              final factor = line.conversionFactor > 0
                  ? line.conversionFactor
                  : ((curMap['conversionFactor'] as num?)?.toInt() ?? 500);
              final addBaseQty = line.quantity * factor;
              final oldCost = (curMap['costPrice'] as num?)?.toDouble() ?? 0.0;

              // Dynamic Weighted Average Cost (WAC) per base unit for multi-unit consumables
              final newWacCost = ConsumablesService.calculateWAC(
                oldStockBase: oldStock,
                oldUnitCostBase: oldCost,
                newQuantityPurchase: line.quantity,
                newRatePurchase: line.purchaseRate,
                conversionFactor: factor,
              );

              curMap['stock'] = oldStock + addBaseQty;
              curMap['costPrice'] = newWacCost;
              curMap['isMultiUnit'] = true;
              curMap['itemType'] = 'Consumable / Raw Material';
              curMap['purchaseUnit'] = line.purchaseUnit;
              curMap['baseUnit'] = line.baseUnit;
              curMap['conversionFactor'] = factor;
              curMap['purchaseRate'] = line.purchaseRate;
              curMap['warranty'] = line.warrantyDuration;
              if (line.brand.isNotEmpty) curMap['brand'] = line.brand;
              if (line.model.isNotEmpty) curMap['model'] = line.model;
              await Db.items.put(targetKey, curMap);

              final moveDesc =
                  'Purchase Bill $finalBillNum (+${line.quantity} ${line.purchaseUnit} = +$addBaseQty ${line.baseUnit} @ ₹$newWacCost/${line.baseUnit})';
              await Db.stockMove(targetKey, line.name, addBaseQty, moveDesc);
            } else {
              // Standard retail product: update stock and latest purchase rate
              curMap['stock'] = oldStock + line.quantity;
              curMap['costPrice'] = line.purchaseRate;
              curMap['warranty'] = line.warrantyDuration;
              if (line.brand.isNotEmpty) curMap['brand'] = line.brand;
              if (line.model.isNotEmpty) curMap['model'] = line.model;
              await Db.items.put(targetKey, curMap);
              await Db.stockMove(targetKey, line.name, line.quantity, 'Purchase Bill $finalBillNum');
            }
          }
        } else {
          // Create new item in Db.items if not present
          final isMulti = line.isMultiUnit;
          if (isMulti) {
            final factor = line.conversionFactor > 0 ? line.conversionFactor : 500;
            final baseQty = line.quantity * factor;
            final effCost = line.purchaseRate / factor;

            final newItem = <String, dynamic>{
              'name': line.name,
              'category': line.category.isNotEmpty
                  ? line.category
                  : 'Consumable / Raw Material',
              'brand': line.brand,
              'model': line.model,
              'sku': line.sku,
              'stock': baseQty,
              'costPrice': double.parse(effCost.toStringAsFixed(4)),
              'sellingPrice': 0.0,
              'minStock': 200,
              'warranty': line.warrantyDuration,
              'isMultiUnit': true,
              'itemType': 'Consumable / Raw Material',
              'purchaseUnit': line.purchaseUnit,
              'baseUnit': line.baseUnit,
              'conversionFactor': factor,
              'purchaseRate': line.purchaseRate,
            };
            final newKey = await Db.items.add(newItem);
            final moveDesc =
                'Purchase Bill $finalBillNum (+${line.quantity} ${line.purchaseUnit} = +$baseQty ${line.baseUnit})';
            await Db.stockMove(newKey, line.name, baseQty, moveDesc);
          } else {
            final newItem = <String, dynamic>{
              'name': line.name,
              'category': line.category.isNotEmpty ? line.category : 'General',
              'brand': line.brand,
              'model': line.model,
              'sku': line.sku,
              'stock': line.quantity,
              'costPrice': line.purchaseRate,
              'sellingPrice': 0.0,
              'minStock': 3,
              'warranty': line.warrantyDuration,
              'isMultiUnit': false,
            };
            final newKey = await Db.items.add(newItem);
            await Db.stockMove(newKey, line.name, line.quantity, 'Purchase Bill $finalBillNum');
          }
        }
      }

      // 2b. Financial adjustments
      // In TekFix, supplier balance is negative when we owe money:
      // When bill is created, unpaid balance increases debt: delta = -balanceDue
      if (vendorKey != null && balanceDue > 0) {
        await Db.adjustParty(vendorKey, -balanceDue);
      }

      // 2c. Bank/Cash movement for amount paid
      if (safePaid > 0) {
        await Db.moveMoney(initialPaymentMethod, -safePaid, 'Purchase Bill $finalBillNum payment');
      }

      // 2d. Mirror in legacy Db.purchases for 100% backward compatibility
      if (Db.purchases.isOpen) {
        for (final line in items) {
          await Db.purchases.add({
            'createdAt': purchaseDate.toIso8601String(),
            'supplierKey': vendorKey,
            'supplierName': vendorName,
            'supplierPhone': vendorPhone,
            'itemKey': line.itemKey,
            'itemName': line.name,
            'qty': line.quantity,
            'unitCost': line.purchaseRate,
            'total': line.lineTotal,
            'mode': initialPaymentMethod,
            'invoiceNumber': vendorInvoiceNumber.trim(),
            'purchaseBillNumber': finalBillNum,
            'warranty': line.warrantyDuration,
            'warrantyExpiry': line.warrantyExpiryDate?.toIso8601String(),
            'imei': line.imeiOrSerial,
          });
        }
      }

      // 2e. Audit log
      if (Db.audit.isOpen) {
        await Db.audit.add({
          'action': 'Purchase Bill Confirmed',
          'entity': 'PurchaseBill',
          'entityId': finalBillNum,
          'actorId': staffId,
          'actorName': staffName,
          'timestamp': now.toIso8601String(),
          'details': {
            'vendor': vendorName,
            'total': grandTotal,
            'paid': safePaid,
            'balance': balanceDue,
            'itemCount': items.length,
          },
        });
      }
    }

    return bill.copyWith(key: savedKey);
  }

  // ---------------------------------------------------------------------------
  // 5. RECORD VENDOR PAYMENT ON A BILL
  // ---------------------------------------------------------------------------

  Future<PurchaseBill> recordBillPayment({
    required dynamic billKey,
    required double amount,
    required DateTime paymentDate,
    required String paymentMethod,
    required String transactionReference,
    String? notes,
    required String staffId,
    required String staffName,
  }) async {
    final raw = _billsBox.get(billKey);
    if (raw is! Map) throw Exception('Purchase bill not found');
    final bill = PurchaseBill.fromMap(raw, billKey);

    if (amount <= 0) {
      throw Exception('Payment amount must be greater than zero');
    }

    if (amount > bill.balanceDue + 0.01) {
      throw Exception('Payment (₹${amount.toStringAsFixed(2)}) exceeds bill balance due (₹${bill.balanceDue.toStringAsFixed(2)}). Use Advance Payment for excess amounts.');
    }

    final payId = await generatePaymentId();
    final payment = VendorPaymentRecord(
      paymentId: payId,
      billKey: billKey,
      billNumber: bill.billNumber,
      vendorKey: bill.vendorKey,
      vendorName: bill.vendorName,
      amount: amount,
      paymentDate: paymentDate,
      paymentMethod: paymentMethod,
      transactionReference: transactionReference.trim(),
      notes: notes?.trim(),
      recordedById: staffId,
      recordedByName: staffName,
    );

    final updatedPayments = List<VendorPaymentRecord>.from(bill.payments)..add(payment);
    final newPaid = (bill.paidAmount + amount).clamp(0.0, bill.grandTotal);
    final newBalance = (bill.grandTotal - newPaid).clamp(0.0, bill.grandTotal);

    String newStatus;
    if (newBalance <= 0.001) {
      newStatus = BillPaymentStatus.paid;
    } else {
      newStatus = BillPaymentStatus.partiallyPaid;
    }

    final updatedBill = bill.copyWith(
      paidAmount: newPaid,
      balanceDue: newBalance,
      paymentStatus: newStatus,
      payments: updatedPayments,
      lastUpdatedById: staffId,
      lastUpdatedByName: staffName,
      updatedAt: DateTime.now(),
    );

    await _billsBox.put(billKey, updatedBill.toMap());
    await _paymentsBox.add(payment.toMap()..['billKey'] = billKey);

    // Financial adjustments:
    // Paying reduces debt owed to supplier (moves balance towards 0)
    if (bill.vendorKey != null) {
      await Db.adjustParty(bill.vendorKey, amount);
    }
    // Moves money out of cash/bank
    await Db.moveMoney(paymentMethod, -amount, 'Vendor Payment ${bill.billNumber}');

    // Audit log
    if (Db.audit.isOpen) {
      await Db.audit.add({
        'action': 'Vendor Payment Recorded',
        'entity': 'Payment',
        'entityId': payId,
        'actorId': staffId,
        'actorName': staffName,
        'timestamp': DateTime.now().toIso8601String(),
        'details': {
          'billNumber': bill.billNumber,
          'vendor': bill.vendorName,
          'amount': amount,
          'method': paymentMethod,
          'ref': transactionReference,
        },
      });
    }

    return updatedBill;
  }

  // ---------------------------------------------------------------------------
  // 6. RECORD VENDOR ADVANCE PAYMENT
  // ---------------------------------------------------------------------------

  Future<VendorPaymentRecord> recordAdvancePayment({
    required dynamic vendorKey,
    required String vendorName,
    required double amount,
    DateTime? paymentDate,
    required String paymentMethod,
    required String transactionReference,
    String? notes,
    required String staffId,
    required String staffName,
  }) async {
    if (amount <= 0) throw Exception('Advance amount must be greater than zero');
    if (vendorKey == null) throw Exception('Please select a vendor for advance payment');

    final effectiveDate = paymentDate ?? DateTime.now();
    final payId = await generatePaymentId();
    final payment = VendorPaymentRecord(
      paymentId: payId,
      billNumber: 'ADVANCE',
      vendorKey: vendorKey,
      vendorName: vendorName,
      amount: amount,
      paymentDate: effectiveDate,
      paymentMethod: paymentMethod,
      transactionReference: transactionReference.trim(),
      notes: notes?.trim() ?? 'Advance payment to vendor',
      recordedById: staffId,
      recordedByName: staffName,
      isAdvance: true,
    );

    await _paymentsBox.add(payment.toMap());

    // Advance payment gives us credit with the supplier:
    await Db.adjustParty(vendorKey, amount);
    await Db.moveMoney(paymentMethod, -amount, 'Vendor Advance Payment: $vendorName');

    if (Db.audit.isOpen) {
      await Db.audit.add({
        'action': 'Vendor Advance Recorded',
        'entity': 'Payment',
        'entityId': payId,
        'actorId': staffId,
        'actorName': staffName,
        'timestamp': DateTime.now().toIso8601String(),
        'details': {
          'vendor': vendorName,
          'amount': amount,
          'method': paymentMethod,
        },
      });
    }

    return payment;
  }

  // ---------------------------------------------------------------------------
  // 7. VENDOR ACCOUNT LEDGER
  // ---------------------------------------------------------------------------

  List<VendorLedgerEntry> getVendorLedger(dynamic vendorKey) {
    if (vendorKey == null) return [];
    final entries = <VendorLedgerEntry>[];

    // 1. Collect all purchase bills for this vendor
    for (final k in _billsBox.keys) {
      final raw = _billsBox.get(k);
      if (raw is Map) {
        final bVendor = raw['vendorKey'];
        if (bVendor == vendorKey || '$bVendor' == '$vendorKey') {
          final bill = PurchaseBill.fromMap(raw, k);
          if (!bill.isDraft) {
            entries.add(VendorLedgerEntry(
              id: 'BILL_${bill.billNumber}',
              date: bill.purchaseDate,
              type: 'Purchase Bill',
              reference: bill.billNumber,
              vendorInvoiceNumber: bill.vendorInvoiceNumber,
              debit: bill.grandTotal, // What we owe for this purchase
              credit: 0.0,
              runningBalance: 0.0,
              notes: 'Purchase Bill: ${bill.items.length} items',
            ));
          }
        }
      }
    }

    // 2. Collect all payments for this vendor
    for (final pk in _paymentsBox.keys) {
      final raw = _paymentsBox.get(pk);
      if (raw is Map) {
        final pVendor = raw['vendorKey'];
        if (pVendor == vendorKey || '$pVendor' == '$vendorKey') {
          final pay = VendorPaymentRecord.fromMap(raw);
          entries.add(VendorLedgerEntry(
            id: 'PAY_${pay.paymentId}',
            date: pay.paymentDate,
            type: pay.isAdvance ? 'Advance Payment' : 'Bill Payment',
            reference: pay.paymentId,
            vendorInvoiceNumber: null,
            debit: 0.0,
            credit: pay.amount, // Payments reduce what we owe
            runningBalance: 0.0,
            notes: '${pay.paymentMethod} (Ref: ${pay.transactionReference}) - ${pay.billNumber}',
          ));
        }
      }
    }

    // Sort chronologically ascending
    entries.sort((a, b) => a.date.compareTo(b.date));

    // Calculate running balance (Debit increases balance, Credit reduces balance)
    double running = 0.0;
    final calculated = <VendorLedgerEntry>[];
    for (final e in entries) {
      running += (e.debit - e.credit);
      calculated.add(VendorLedgerEntry(
        id: e.id,
        date: e.date,
        type: e.type,
        reference: e.reference,
        vendorInvoiceNumber: e.vendorInvoiceNumber,
        debit: e.debit,
        credit: e.credit,
        runningBalance: running,
        notes: e.notes,
      ));
    }

    return calculated.reversed.toList(); // Most recent first for display
  }

  // ---------------------------------------------------------------------------
  // 8. DASHBOARD METRICS & FILTERING
  // ---------------------------------------------------------------------------

  List<PurchaseBill> getAllPurchaseBills() {
    final list = <PurchaseBill>[];
    for (final k in _billsBox.keys) {
      final raw = _billsBox.get(k);
      if (raw is Map) {
        list.add(PurchaseBill.fromMap(raw, k));
      }
    }
    list.sort((a, b) => b.purchaseDate.compareTo(a.purchaseDate));
    return list;
  }

  PurchaseBill? getPurchaseBill(dynamic key) {
    if (key == null || !_billsBox.isOpen) return null;
    final raw = _billsBox.get(key);
    if (raw is Map) return PurchaseBill.fromMap(raw, key);
    return null;
  }

  Map<String, dynamic> computeDashboardMetrics() {
    final bills = getAllPurchaseBills().where((b) => !b.isDraft).toList();
    final now = DateTime.now();

    int totalBills = bills.length;
    double totalPurchaseValue = 0.0;
    double totalPaid = 0.0;
    double totalOutstanding = 0.0;
    int fullyPaidCount = 0;
    int partiallyPaidCount = 0;
    int unpaidCount = 0;
    int uploadedToday = 0;
    double purchasesThisMonth = 0.0;

    for (final b in bills) {
      totalPurchaseValue += b.grandTotal;
      totalPaid += b.paidAmount;
      totalOutstanding += b.balanceDue;

      if (b.paymentStatus == BillPaymentStatus.paid) {
        fullyPaidCount++;
      } else if (b.paymentStatus == BillPaymentStatus.partiallyPaid) {
        partiallyPaidCount++;
      } else {
        unpaidCount++;
      }

      if (b.uploadTimestamp.year == now.year &&
          b.uploadTimestamp.month == now.month &&
          b.uploadTimestamp.day == now.day) {
        uploadedToday++;
      }

      if (b.purchaseDate.year == now.year && b.purchaseDate.month == now.month) {
        purchasesThisMonth += b.grandTotal;
      }
    }

    return {
      'totalBills': totalBills,
      'totalPurchaseValue': totalPurchaseValue,
      'totalPaid': totalPaid,
      'totalOutstanding': totalOutstanding,
      'fullyPaidBills': fullyPaidCount,
      'partiallyPaidBills': partiallyPaidCount,
      'unpaidBills': unpaidCount,
      'fullyPaidCount': fullyPaidCount,
      'partiallyPaidCount': partiallyPaidCount,
      'unpaidCount': unpaidCount,
      'billsUploadedToday': uploadedToday,
      'uploadedToday': uploadedToday,
      'purchasesThisMonth': purchasesThisMonth,
    };
  }

  Map<String, dynamic> getDashboardMetrics() => computeDashboardMetrics();

  List<PurchaseBill> searchPurchaseBills({
    String query = '',
    dynamic vendorKey,
    String? status,
    DateTime? startDate,
    DateTime? endDate,
  }) {
    String? vendorName;
    if (vendorKey != null) {
      final v = Db.parties.get(vendorKey);
      if (v is Map) vendorName = v['name']?.toString();
    }
    return searchAndFilter(
      query: query,
      vendorFilter: vendorName,
      paymentStatusFilter: (status == null || status == 'All') ? null : status,
      startDate: startDate,
      endDate: endDate,
    );
  }

  List<PurchaseBill> searchAndFilter({
    String query = '',
    String? vendorFilter,
    String? paymentStatusFilter,
    String? staffFilter,
    DateTime? startDate,
    DateTime? endDate,
  }) {
    final all = getAllPurchaseBills();
    final q = query.trim().toLowerCase();

    return all.where((b) {
      if (q.isNotEmpty) {
        final matches = b.billNumber.toLowerCase().contains(q) ||
            b.vendorInvoiceNumber.toLowerCase().contains(q) ||
            b.vendorName.toLowerCase().contains(q) ||
            b.vendorPhone.contains(q) ||
            b.createdByName.toLowerCase().contains(q) ||
            b.items.any((it) =>
                it.name.toLowerCase().contains(q) ||
                it.brand.toLowerCase().contains(q) ||
                it.imeiOrSerial.toLowerCase().contains(q));
        if (!matches) return false;
      }

      if (vendorFilter != null && vendorFilter != 'All Vendors' && vendorFilter.isNotEmpty) {
        if (b.vendorName != vendorFilter) return false;
      }

      if (paymentStatusFilter != null && paymentStatusFilter != 'All Statuses' && paymentStatusFilter.isNotEmpty) {
        if (b.paymentStatus != paymentStatusFilter) return false;
      }

      if (staffFilter != null && staffFilter != 'All Staff' && staffFilter.isNotEmpty) {
        if (b.createdByName != staffFilter) return false;
      }

      if (startDate != null && b.purchaseDate.isBefore(startDate)) return false;
      if (endDate != null && b.purchaseDate.isAfter(endDate.add(const Duration(days: 1)))) return false;

      return true;
    }).toList();
  }
}
