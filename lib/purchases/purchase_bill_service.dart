import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
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

  /// Fetches real-time vendor outstanding balance in integer paise from Cloud Firestore (with local fallback).
  Future<int> fetchVendorBalancePaise(dynamic vendorKey, {String? shopId}) async {
    if (vendorKey == null) return 0;
    final sId = (shopId != null && shopId.isNotEmpty) ? shopId : Db.setting('shop_id', 'tekfix');
    try {
      final docSnap = await FirebaseFirestore.instance
          .collection('shops')
          .doc(sId)
          .collection('parties')
          .doc('$vendorKey')
          .get();

      if (docSnap.exists) {
        final d = docSnap.data();
        if (d != null) {
          final paise = (d['currentBalancePaise'] as num?)?.toInt();
          if (paise != null) return paise;
          final bal = (d['balance'] as num?)?.toDouble();
          if (bal != null) return (bal < 0 ? -bal * 100 : bal * 100).round();
        }
      }
    } catch (e) {
      debugPrint('[PurchaseBillService] fetchVendorBalancePaise error: $e');
    }
    // Fallback to local parties
    return (getVendorOutstandingBalance(vendorKey) * 100).round();
  }

  /// Normalizes product name for robust case-insensitive, symbol-agnostic matching.
  static String normalizeProductName(String name) {
    return name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '').trim();
  }

  /// Searches Cloud Firestore products collection by Barcode, SKU, or Normalized Name.
  /// Falls back to local catalog for instant offline responsiveness.
  Future<Map<String, dynamic>?> matchProductInFirestore({
    String? barcode,
    String? sku,
    required String name,
    String? shopId,
  }) async {
    final sId = (shopId != null && shopId.isNotEmpty) ? shopId : Db.setting('shop_id', 'tekfix');
    final fs = FirebaseFirestore.instance;
    final normName = normalizeProductName(name);

    try {
      // 1. Try Barcode match in products collection
      if (barcode != null && barcode.trim().isNotEmpty) {
        final bSnap = await fs
            .collection('shops')
            .doc(sId)
            .collection('products')
            .where('barcode', isEqualTo: barcode.trim())
            .limit(1)
            .get();
        if (bSnap.docs.isNotEmpty) {
          final d = bSnap.docs.first;
          return {'id': d.id, 'name': d.data()['name'] ?? name, 'data': d.data()};
        }
      }

      // 2. Try SKU match
      if (sku != null && sku.trim().isNotEmpty) {
        final sSnap = await fs
            .collection('shops')
            .doc(sId)
            .collection('products')
            .where('sku', isEqualTo: sku.trim())
            .limit(1)
            .get();
        if (sSnap.docs.isNotEmpty) {
          final d = sSnap.docs.first;
          return {'id': d.id, 'name': d.data()['name'] ?? name, 'data': d.data()};
        }
      }

      // 3. Try Normalized Name match
      if (normName.isNotEmpty) {
        final nSnap = await fs
            .collection('shops')
            .doc(sId)
            .collection('products')
            .where('normalizedName', isEqualTo: normName)
            .limit(1)
            .get();
        if (nSnap.docs.isNotEmpty) {
          final d = nSnap.docs.first;
          return {'id': d.id, 'name': d.data()['name'] ?? name, 'data': d.data()};
        }
      }

      // Also check root products collection
      if (barcode != null && barcode.trim().isNotEmpty) {
        final rootSnap = await fs
            .collection('products')
            .where('barcode', isEqualTo: barcode.trim())
            .limit(1)
            .get();
        if (rootSnap.docs.isNotEmpty) {
          final d = rootSnap.docs.first;
          return {'id': d.id, 'name': d.data()['name'] ?? name, 'data': d.data()};
        }
      }
    } catch (e) {
      debugPrint('[PurchaseBillService] Firestore product search error: $e');
    }

    // 4. Local Catalog fallback: Search Db.items
    for (final k in Db.items.keys) {
      final raw = Db.items.get(k);
      if (raw is! Map) continue;
      final existingBarcode = raw['barcode']?.toString().trim();
      final existingCode = raw['code']?.toString().trim();
      final existingSku = raw['sku']?.toString().trim();
      final existingName = raw['name']?.toString() ?? '';
      final existingNorm = normalizeProductName(existingName);

      if ((barcode != null && barcode.trim().isNotEmpty && (existingBarcode == barcode.trim() || existingCode == barcode.trim())) ||
          (sku != null && sku.trim().isNotEmpty && existingSku == sku.trim()) ||
          (normName.isNotEmpty && existingNorm == normName)) {
        return {
          'id': raw['_id']?.toString() ?? '$k',
          'itemKey': k,
          'name': existingName,
          'data': raw,
        };
      }
    }

    return null;
  }

  /// Verifies whether any of the given IMEIs are already IN_STOCK in Cloud Firestore stock_units.
  Future<List<String>> checkDuplicateImeisInStock(List<String> imeis, {String? shopId}) async {
    final duplicates = <String>[];
    if (imeis.isEmpty) return duplicates;
    final sId = (shopId != null && shopId.isNotEmpty) ? shopId : Db.setting('shop_id', 'tekfix');
    final fs = FirebaseFirestore.instance;

    for (final imei in imeis) {
      final cleanImei = imei.trim().toUpperCase();
      if (cleanImei.isEmpty) continue;
      try {
        final snap = await fs
            .collection('shops')
            .doc(sId)
            .collection('stock_units')
            .doc(cleanImei)
            .get();
        if (snap.exists && snap.data()?['status'] == 'IN_STOCK') {
          duplicates.add(cleanImei);
        }
      } catch (_) {}
    }
    return duplicates;
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
  // 4. ATOMIC CONFIRMATION & STOCK SYNC (Strict Reads-Before-Writes on Firestore)
  // ---------------------------------------------------------------------------

  Future<PurchaseBill> confirmPurchaseBill({
    required String billNumber,
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
    Uint8List? attachmentBytes,
    required String staffId,
    required String staffName,
    String? notes,
    double? invoiceExtractedTotal,
    String? shopId,
  }) async {
    // 1. Pre-validation checks
    if (items.isEmpty) {
      throw Exception('Purchase bill must have at least one item');
    }

    for (int i = 0; i < items.length; i++) {
      final it = items[i];
      if (it.isNewProduct && !it.isStagedReady) {
        throw Exception('Item "${it.name}" (Row ${i + 1}) is marked as new and must be registered first.');
      }
      if (it.imeiRequired) {
        if (it.serialNumbers.length != it.quantity) {
          throw Exception(
            'Item "${it.name}" requires exactly ${it.quantity} IMEIs, but ${it.serialNumbers.length} were entered.',
          );
        }
        final uniqueCheck = it.serialNumbers.map((s) => s.trim().toUpperCase()).toSet();
        if (uniqueCheck.length != it.serialNumbers.length) {
          throw Exception('Item "${it.name}" contains duplicate IMEIs in the entered list.');
        }
      }
    }

    final sId = (shopId != null && shopId.isNotEmpty) ? shopId : Db.setting('shop_id', 'tekfix');
    final now = DateTime.now();
    final billId = billNumber.replaceAll('/', '_');

    // 2. Heavy work OUTSIDE transaction: Upload bill document to Firebase Storage
    String? storagePath;
    String? downloadUrl;
    if (attachment != null) {
      storagePath = attachment.filePath;
      if (attachmentBytes != null || (attachment.bytesBase64 != null && attachment.bytesBase64!.isNotEmpty)) {
        try {
          final bytes = attachmentBytes ?? base64Decode(attachment.bytesBase64!);
          final storageRef = FirebaseStorage.instance
              .ref()
              .child('shops/$sId/purchase_invoices/${billId}_${attachment.fileName}');
          final uploadTask = await storageRef.putData(
            bytes,
            SettableMetadata(contentType: attachment.fileType),
          );
          storagePath = uploadTask.ref.fullPath;
          downloadUrl = await uploadTask.ref.getDownloadURL();
        } catch (e) {
          debugPrint('[PurchaseBillService] Firebase Storage upload notice: $e');
        }
      }
    }

    // Integer paise calculations
    int subtotalPaise = 0;
    int totalQty = 0;
    int totalDiscountPaise = 0;
    int totalTaxPaise = 0;
    final int otherChargesPaise = (otherCharges * 100).round();

    for (final it in items) {
      subtotalPaise += (it.quantity * it.purchaseRatePaise);
      totalQty += it.quantity;
      totalDiscountPaise += it.discountPaise;
      totalTaxPaise += it.taxAmountPaise;
    }

    final int grandTotalPaise =
        (subtotalPaise - totalDiscountPaise + totalTaxPaise + otherChargesPaise).clamp(0, 1 << 62);
    final int paidAmountPaise = (initialPaidAmount * 100).round().clamp(0, grandTotalPaise);
    final int balanceDuePaise = (grandTotalPaise - paidAmountPaise).clamp(0, grandTotalPaise);

    String paymentStatus;
    if (balanceDuePaise == 0) {
      paymentStatus = BillPaymentStatus.paid;
    } else if (paidAmountPaise > 0) {
      paymentStatus = BillPaymentStatus.partiallyPaid;
    } else {
      paymentStatus = BillPaymentStatus.unpaid;
    }

    // 3. Firestore Atomic Transaction (Strict Reads-Before-Writes)
    final firestore = FirebaseFirestore.instance;

    final billRef = firestore.collection('shops').doc(sId).collection('purchase_bills').doc(billId);
    final rootBillRef = firestore.collection('purchase_bills').doc(billId);

    final vDocId = vendorKey?.toString() ?? 'VENDOR_${now.millisecondsSinceEpoch}';
    final vendorRef = firestore.collection('shops').doc(sId).collection('parties').doc(vDocId);

    // Collect all unique IMEIs across items:
    final allImeis = <String, PurchaseBillItem>{};
    for (final it in items) {
      for (final sn in it.serialNumbers) {
        final cleanSn = sn.trim().toUpperCase();
        if (cleanSn.isNotEmpty) {
          allImeis[cleanSn] = it;
        }
      }
    }

    // Prepare product doc refs for reading
    final existingProductRefs = <String, DocumentReference<Map<String, dynamic>>>{};
    for (final it in items) {
      if (!it.isNewProduct && it.matchedProductId != null && it.matchedProductId!.isNotEmpty) {
        final pRef = firestore.collection('shops').doc(sId).collection('products').doc(it.matchedProductId);
        existingProductRefs[it.matchedProductId!] = pRef;
      }
    }

    // Prepare stock_units doc refs for all IMEIs
    final stockUnitRefs = <String, DocumentReference<Map<String, dynamic>>>{};
    for (final imei in allImeis.keys) {
      stockUnitRefs[imei] = firestore.collection('shops').doc(sId).collection('stock_units').doc(imei);
    }

    await firestore.runTransaction((transaction) async {
      // -----------------------------------------------------------------------
      // READ PHASE (Strictly before any write calls)
      // -----------------------------------------------------------------------

      // 1. Read purchase_bills/{billId} to guarantee idempotency
      final billSnap = await transaction.get(billRef);
      if (billSnap.exists && billSnap.data()?['status'] == 'CONFIRMED') {
        throw Exception('Purchase bill $billNumber has already been confirmed. Duplicate rejected.');
      }

      // 2. Read vendor document to get real-time currentBalancePaise
      int vendorBalancePaise = 0;
      final vendorSnap = await transaction.get(vendorRef);
      if (vendorSnap.exists) {
        final vData = vendorSnap.data()!;
        vendorBalancePaise = (vData['currentBalancePaise'] as num?)?.toInt() ??
            (((vData['balance'] as num?)?.toDouble() ?? 0.0) * 100).round();
      } else {
        vendorBalancePaise = (getVendorOutstandingBalance(vendorKey) * 100).round();
      }

      // 3. Read all referenced products/{productId} documents
      final productSnapshots = <String, DocumentSnapshot<Map<String, dynamic>>>{};
      for (final entry in existingProductRefs.entries) {
        final snap = await transaction.get(entry.value);
        productSnapshots[entry.key] = snap;
      }

      // 4. Check stock_units/{imei} to ensure no entered IMEI already exists in stock
      for (final entry in stockUnitRefs.entries) {
        final imeiSnap = await transaction.get(entry.value);
        if (imeiSnap.exists) {
          final data = imeiSnap.data();
          if (data?['status'] == 'IN_STOCK') {
            throw Exception('IMEI/Serial "${entry.key}" is already IN_STOCK in inventory!');
          }
        }
      }

      // -----------------------------------------------------------------------
      // WRITE PHASE (All writes executed now)
      // -----------------------------------------------------------------------

      // A. Create or update products
      final resolvedItemMap = <PurchaseBillItem, String>{};

      for (final it in items) {
        if (it.isNewProduct || it.matchedProductId == null || it.matchedProductId!.isEmpty) {
          final newProdRef = firestore.collection('shops').doc(sId).collection('products').doc();
          final newProdId = newProdRef.id;
          resolvedItemMap[it] = newProdId;

          final prodPayload = <String, dynamic>{
            'id': newProdId,
            'name': it.name,
            'normalizedName': normalizeProductName(it.name),
            'brand': it.brand,
            'model': it.model,
            'category': it.category.isNotEmpty ? it.category : 'General',
            'sku': it.sku.isNotEmpty ? it.sku : newProdId,
            'barcode': it.sku.isNotEmpty ? it.sku : newProdId,
            'currentStock': it.quantity,
            'lastPurchaseRatePaise': it.purchaseRatePaise,
            'sellingPricePaise': it.sellingPricePaise,
            'costPrice': it.purchaseRate,
            'sellingPrice': it.sellingPrice,
            'warrantyDuration': it.warrantyDuration,
            'hasWarranty': it.hasWarranty,
            'imeiRequired': it.imeiRequired,
            'isMultiUnit': it.isMultiUnit,
            'purchaseUnit': it.purchaseUnit,
            'baseUnit': it.baseUnit,
            'conversionFactor': it.conversionFactor,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          };

          transaction.set(newProdRef, prodPayload);
          transaction.set(firestore.collection('products').doc(newProdId), prodPayload);
        } else {
          final pId = it.matchedProductId!;
          resolvedItemMap[it] = pId;
          final pRef = existingProductRefs[pId]!;
          final snap = productSnapshots[pId];

          final int oldStock = (snap?.data()?['currentStock'] as num?)?.toInt() ??
              ((snap?.data()?['stock'] as num?)?.toInt() ?? 0);

          transaction.update(pRef, {
            'currentStock': oldStock + it.quantity,
            'stock': oldStock + it.quantity,
            'lastPurchaseRatePaise': it.purchaseRatePaise,
            'costPrice': it.purchaseRate,
            if (it.sellingPrice > 0) 'sellingPricePaise': it.sellingPricePaise,
            if (it.sellingPrice > 0) 'sellingPrice': it.sellingPrice,
            'updatedAt': FieldValue.serverTimestamp(),
          });

          transaction.set(firestore.collection('products').doc(pId), {
            'currentStock': oldStock + it.quantity,
            'lastPurchaseRatePaise': it.purchaseRatePaise,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      }

      // B. Insert stock_units documents for each serial/IMEI (status: IN_STOCK)
      for (final entry in allImeis.entries) {
        final imei = entry.key;
        final it = entry.value;
        final pId = resolvedItemMap[it] ?? it.matchedProductId ?? 'PROD';
        final suRef = stockUnitRefs[imei]!;

        final suData = <String, dynamic>{
          'imei': imei,
          'productId': pId,
          'productName': it.name,
          'billId': billId,
          'billNumber': billNumber,
          'vendorId': vDocId,
          'vendorName': vendorName,
          'purchaseRatePaise': it.purchaseRatePaise,
          'status': 'IN_STOCK',
          'purchaseDate': purchaseDate.toIso8601String(),
          'warrantyDuration': it.warrantyDuration,
          'warrantyExpiryDate': it.warrantyExpiryDate?.toIso8601String(),
          'createdAt': FieldValue.serverTimestamp(),
        };

        transaction.set(suRef, suData);
        transaction.set(firestore.collection('stock_units').doc(imei), suData);
      }

      // C. Save purchase_bills/{billId} with status CONFIRMED
      final billPayload = <String, dynamic>{
        'billId': billId,
        'billNumber': billNumber,
        'vendorInvoiceNumber': vendorInvoiceNumber.trim(),
        'vendorKey': vDocId,
        'vendorId': vDocId,
        'vendorName': vendorName.trim(),
        'vendorPhone': vendorPhone.trim(),
        'vendorGst': vendorGst?.trim(),
        'vendorAddress': vendorAddress?.trim(),
        'purchaseDate': purchaseDate.toIso8601String(),
        'uploadTimestamp': now.toIso8601String(),
        'subtotalPaise': subtotalPaise,
        'subtotal': subtotalPaise / 100.0,
        'totalQuantity': totalQty,
        'totalDiscountPaise': totalDiscountPaise,
        'totalDiscount': totalDiscountPaise / 100.0,
        'totalTaxPaise': totalTaxPaise,
        'totalTax': totalTaxPaise / 100.0,
        'otherChargesPaise': otherChargesPaise,
        'otherCharges': otherChargesPaise / 100.0,
        'grandTotalPaise': grandTotalPaise,
        'grandTotal': grandTotalPaise / 100.0,
        'paidAmountPaise': paidAmountPaise,
        'paidAmount': paidAmountPaise / 100.0,
        'balanceDuePaise': balanceDuePaise,
        'balanceDue': balanceDuePaise / 100.0,
        'paymentStatus': paymentStatus,
        'paymentMethod': initialPaymentMethod,
        'paymentRef': initialPaymentReference?.trim(),
        'status': 'CONFIRMED',
        'isDraft': false,
        'storagePath': storagePath,
        'downloadUrl': downloadUrl,
        'invoiceExtractedTotal': invoiceExtractedTotal,
        'createdById': staffId,
        'createdByName': staffName,
        'notes': notes?.trim(),
        'createdAt': FieldValue.serverTimestamp(),
        'confirmedAt': FieldValue.serverTimestamp(),
      };

      transaction.set(billRef, billPayload);
      transaction.set(rootBillRef, billPayload);

      // Save items subcollection in purchase_bills/{billId}/items/{itemId}
      for (final it in items) {
        final pId = resolvedItemMap[it] ?? it.id;
        final itemDocRef = billRef.collection('items').doc(pId);
        final itemMap = it.toMap()
          ..['productId'] = pId
          ..['purchaseRatePaise'] = it.purchaseRatePaise
          ..['lineTotalPaise'] = it.lineTotalPaise;
        transaction.set(itemDocRef, itemMap);
      }

      // D. Update vendor balance & append entries to vendor_ledger
      final int newVendorBalancePaise = vendorBalancePaise + balanceDuePaise;

      transaction.set(vendorRef, {
        'name': vendorName,
        'phone': vendorPhone,
        if (vendorGst != null && vendorGst.isNotEmpty) 'gst': vendorGst,
        if (vendorAddress != null && vendorAddress.isNotEmpty) 'address': vendorAddress,
        'type': 'Supplier',
        'currentBalancePaise': newVendorBalancePaise,
        'balance': newVendorBalancePaise / 100.0,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Append bill debit entry to vendor_ledger
      final ledgerBillRef = firestore.collection('shops').doc(sId).collection('vendor_ledger').doc('VL_${billId}_BILL');
      final ledgerBillData = <String, dynamic>{
        'id': 'VL_${billId}_BILL',
        'vendorId': vDocId,
        'vendorName': vendorName,
        'date': purchaseDate.toIso8601String(),
        'type': 'Purchase Bill',
        'reference': billNumber,
        'vendorInvoiceNumber': vendorInvoiceNumber,
        'debitPaise': grandTotalPaise,
        'debit': grandTotalPaise / 100.0,
        'creditPaise': 0,
        'credit': 0.0,
        'runningBalancePaise': vendorBalancePaise + grandTotalPaise,
        'runningBalance': (vendorBalancePaise + grandTotalPaise) / 100.0,
        'notes': 'Purchase Bill ($totalQty items)',
        'createdAt': FieldValue.serverTimestamp(),
      };
      transaction.set(ledgerBillRef, ledgerBillData);
      transaction.set(firestore.collection('vendor_ledger').doc('VL_${billId}_BILL'), ledgerBillData);

      // E. If payment was made, append payment credit entry to vendor_ledger and accounting_cash_bank
      if (paidAmountPaise > 0) {
        final ledgerPayRef = firestore.collection('shops').doc(sId).collection('vendor_ledger').doc('VL_${billId}_PAY');
        final ledgerPayData = <String, dynamic>{
          'id': 'VL_${billId}_PAY',
          'vendorId': vDocId,
          'vendorName': vendorName,
          'date': purchaseDate.toIso8601String(),
          'type': 'Bill Payment',
          'reference': initialPaymentReference?.isNotEmpty == true ? initialPaymentReference : billNumber,
          'vendorInvoiceNumber': vendorInvoiceNumber,
          'debitPaise': 0,
          'debit': 0.0,
          'creditPaise': paidAmountPaise,
          'credit': paidAmountPaise / 100.0,
          'runningBalancePaise': newVendorBalancePaise,
          'runningBalance': newVendorBalancePaise / 100.0,
          'notes': 'Payment via $initialPaymentMethod ($billNumber)',
          'createdAt': FieldValue.serverTimestamp(),
        };
        transaction.set(ledgerPayRef, ledgerPayData);
        transaction.set(firestore.collection('vendor_ledger').doc('VL_${billId}_PAY'), ledgerPayData);

        // Record accounting_cash_bank entry
        final cashBankRef = firestore.collection('shops').doc(sId).collection('accounting_cash_bank').doc('CB_${billId}');
        final cashBankData = <String, dynamic>{
          'id': 'CB_${billId}',
          'entryType': 'CREDIT', // Cash out / outflow
          'mode': initialPaymentMethod,
          'amountPaise': paidAmountPaise,
          'amount': paidAmountPaise / 100.0,
          'category': 'PURCHASE_BILL_PAYMENT',
          'referenceId': billId,
          'billNumber': billNumber,
          'vendorId': vDocId,
          'vendorName': vendorName,
          'staffId': staffId,
          'staffName': staffName,
          'date': purchaseDate.toIso8601String(),
          'createdAt': FieldValue.serverTimestamp(),
        };
        transaction.set(cashBankRef, cashBankData);
        transaction.set(firestore.collection('accounting_cash_bank').doc('CB_${billId}'), cashBankData);
      }
    });

    // Mirror to local Hive for smooth offline experience
    try {
      final paymentsList = <VendorPaymentRecord>[];
      if (paidAmountPaise > 0) {
        paymentsList.add(VendorPaymentRecord(
          paymentId: 'PAY_${DateTime.now().millisecondsSinceEpoch}',
          billNumber: billNumber,
          vendorKey: vendorKey,
          vendorName: vendorName,
          amount: paidAmountPaise / 100.0,
          paymentDate: purchaseDate,
          paymentMethod: initialPaymentMethod,
          transactionReference: initialPaymentReference ?? 'Payment for $billNumber',
          notes: 'Payment recorded during purchase bill entry',
          recordedById: staffId,
          recordedByName: staffName,
        ));
      }

      final confirmedBill = PurchaseBill(
        key: billId,
        billNumber: billNumber,
        vendorInvoiceNumber: vendorInvoiceNumber.trim(),
        vendorKey: vendorKey,
        vendorName: vendorName,
        vendorPhone: vendorPhone,
        vendorGst: vendorGst,
        vendorAddress: vendorAddress,
        purchaseDate: purchaseDate,
        uploadTimestamp: now,
        items: items,
        subtotal: subtotalPaise / 100.0,
        totalQuantity: totalQty,
        totalDiscount: totalDiscountPaise / 100.0,
        totalTax: totalTaxPaise / 100.0,
        otherCharges: otherChargesPaise / 100.0,
        grandTotal: grandTotalPaise / 100.0,
        paidAmount: paidAmountPaise / 100.0,
        balanceDue: balanceDuePaise / 100.0,
        paymentStatus: paymentStatus,
        payments: paymentsList,
        attachment: attachment,
        storagePath: storagePath,
        invoiceExtractedTotal: invoiceExtractedTotal,
        createdById: staffId,
        createdByName: staffName,
        notes: notes,
        isDraft: false,
        createdAt: now,
        updatedAt: now,
      );

      if (_billsBox.isOpen) {
        await _billsBox.put(billId, confirmedBill.toMap());
      }
      for (final p in paymentsList) {
        if (_paymentsBox.isOpen) {
          await _paymentsBox.add(p.toMap()..['billKey'] = billId);
        }
      }
      if (vendorKey != null && balanceDuePaise > 0) {
        await Db.adjustParty(vendorKey, -(balanceDuePaise / 100.0));
      }
      if (paidAmountPaise > 0) {
        await Db.moveMoney(initialPaymentMethod, -(paidAmountPaise / 100.0), 'Purchase Bill $billNumber payment');
      }

      return confirmedBill;
    } catch (e) {
      debugPrint('[PurchaseBillService] Local sync note: $e');
    }

    return PurchaseBill(
      billNumber: billNumber,
      vendorInvoiceNumber: vendorInvoiceNumber,
      vendorKey: vendorKey,
      vendorName: vendorName,
      vendorPhone: vendorPhone,
      vendorGst: vendorGst,
      vendorAddress: vendorAddress,
      purchaseDate: purchaseDate,
      uploadTimestamp: now,
      items: items,
      subtotal: subtotalPaise / 100.0,
      totalQuantity: totalQty,
      totalDiscount: totalDiscountPaise / 100.0,
      totalTax: totalTaxPaise / 100.0,
      otherCharges: otherChargesPaise / 100.0,
      grandTotal: grandTotalPaise / 100.0,
      paidAmount: paidAmountPaise / 100.0,
      balanceDue: balanceDuePaise / 100.0,
      paymentStatus: paymentStatus,
      attachment: attachment,
      storagePath: storagePath,
      invoiceExtractedTotal: invoiceExtractedTotal,
      createdById: staffId,
      createdByName: staffName,
      notes: notes,
      isDraft: false,
      createdAt: now,
      updatedAt: now,
    );
  }

  // ---------------------------------------------------------------------------
  // 5. SAVE DRAFT PURCHASE BILL
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
