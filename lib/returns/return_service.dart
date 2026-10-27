import 'package:hive/hive.dart';
import '../main.dart' show Db, boxReturns, boxPurchaseBills;
import 'return_models.dart';

class ReturnService {
  ReturnService._();
  static final ReturnService instance = ReturnService._();

  Box get _box => Hive.box(boxReturns);

  // ---------------------------------------------------------------------------
  // ID GENERATION (RET-2026-0001 & VHO-2026-0001)
  // ---------------------------------------------------------------------------

  Future<String> generateReturnId() async {
    final year = DateTime.now().year;
    final key = 'return_counter_$year';
    final current = (Db.settings.get(key) as num?)?.toInt() ?? 0;
    final next = current + 1;
    await Db.settings.put(key, next);
    return 'RET-$year-${next.toString().padLeft(4, '0')}';
  }

  Future<String> generateHandoverId() async {
    final year = DateTime.now().year;
    final key = 'handover_counter_$year';
    final current = (Db.settings.get(key) as num?)?.toInt() ?? 0;
    final next = current + 1;
    await Db.settings.put(key, next);
    return 'VHO-$year-${next.toString().padLeft(4, '0')}';
  }

  // ---------------------------------------------------------------------------
  // WARRANTY CALCULATION HELPERS
  // ---------------------------------------------------------------------------

  DateTime? calculateWarrantyExpiry(DateTime purchaseDate, String warrantyPeriod) {
    final wp = warrantyPeriod.trim().toLowerCase();
    if (wp.isEmpty || wp == 'no warranty' || wp == '0' || wp == 'none') {
      return null;
    }

    final numMatch = RegExp(r'\d+').firstMatch(wp);
    final count = numMatch != null ? int.tryParse(numMatch.group(0)!) ?? 1 : 1;

    if (wp.contains('year') || wp.contains('yr')) {
      return DateTime(purchaseDate.year + count, purchaseDate.month, purchaseDate.day);
    } else if (wp.contains('month') || wp.contains('mo')) {
      return DateTime(purchaseDate.year, purchaseDate.month + count, purchaseDate.day);
    } else if (wp.contains('day')) {
      return purchaseDate.add(Duration(days: count));
    } else {
      // Default fallback: assume months if number only
      return DateTime(purchaseDate.year, purchaseDate.month + count, purchaseDate.day);
    }
  }

  String calculateWarrantyStatus(
    DateTime purchaseDate,
    String warrantyPeriod, {
    bool hasInvoice = true,
    bool hasSerial = true,
  }) {
    if (!hasInvoice) {
      return CustomerWarrantyStatus.verificationRequired;
    }

    final wp = warrantyPeriod.trim().toLowerCase();
    if (wp.isEmpty || wp == 'no warranty' || wp == 'none') {
      return CustomerWarrantyStatus.noWarranty;
    }

    final expiry = calculateWarrantyExpiry(purchaseDate, warrantyPeriod);
    if (expiry == null) {
      return CustomerWarrantyStatus.noWarranty;
    }

    final now = DateTime.now();
    if (now.isBefore(expiry) || now.isAtSameMomentAs(expiry)) {
      return CustomerWarrantyStatus.active;
    } else {
      return CustomerWarrantyStatus.expired;
    }
  }

  // ---------------------------------------------------------------------------
  // CUSTOMER SEARCH & PRODUCT RETRIEVAL
  // ---------------------------------------------------------------------------

  /// Normalizes phone number by removing country code, dashes, spaces
  String normalizePhone(String raw) {
    String p = raw.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
    if (p.startsWith('91') && p.length > 10) {
      p = p.substring(2);
    }
    if (p.startsWith('0') && p.length > 10) {
      p = p.substring(1);
    }
    return p;
  }

  /// Searches for matching customer records from parties and sales
  List<Map<String, dynamic>> searchCustomers(String query) {
    final q = query.trim().toLowerCase();
    final qNorm = normalizePhone(q);
    final results = <Map<String, dynamic>>[];
    final seenPhones = <String>{};

    // 1. Search in Db.parties (Customers)
    for (final key in Db.parties.keys) {
      final val = Db.parties.get(key);
      if (val is! Map) continue;
      final type = val['type']?.toString();
      if (type == 'Supplier') continue;

      final name = val['name']?.toString() ?? '';
      final phone = val['phone']?.toString() ?? '';
      final phoneNorm = normalizePhone(phone);

      bool match = false;
      if (q.isNotEmpty) {
        if (phoneNorm.contains(qNorm) || phone.contains(q)) match = true;
        if (name.toLowerCase().contains(q)) match = true;
      }

      if (match) {
        final custId = val['_id']?.toString() ?? '$key';
        results.add({
          'key': key,
          'id': custId,
          'name': name,
          'phone': phone,
          'balance': val['balance'] ?? 0.0,
          'source': 'parties',
        });
        if (phoneNorm.isNotEmpty) seenPhones.add(phoneNorm);
      }
    }

    // 2. Search in Db.sales for customers not in Db.parties or walk-in purchases
    for (final key in Db.sales.keys) {
      final val = Db.sales.get(key);
      if (val is! Map) continue;

      final phone = val['customerPhone']?.toString() ?? '';
      final phoneNorm = normalizePhone(phone);
      if (phoneNorm.isEmpty || seenPhones.contains(phoneNorm)) continue;

      final name = val['customerName']?.toString() ?? 'Customer';
      bool match = false;
      if (q.isNotEmpty) {
        if (phoneNorm.contains(qNorm) || phone.contains(q)) match = true;
        if (name.toLowerCase().contains(q)) match = true;
      }

      if (match) {
        seenPhones.add(phoneNorm);
        results.add({
          'key': val['partyKey'],
          'id': val['partyId']?.toString() ?? 'WALK-IN',
          'name': name,
          'phone': phone,
          'balance': 0.0,
          'source': 'sales',
        });
      }
    }

    return results;
  }

  /// Finds the original vendor from purchase bills, purchases, or item catalog
  Map<String, dynamic>? findOriginalVendor(dynamic itemKey, String itemName) {
    // 1. Search in Purchase Bills first
    if (Hive.isBoxOpen(boxPurchaseBills)) {
      final billsBox = Hive.box(boxPurchaseBills);
      final bKeys = billsBox.keys.toList().reversed;
      for (final bk in bKeys) {
        final bv = billsBox.get(bk);
        if (bv is! Map) continue;
        final items = bv['items'];
        if (items is List) {
          for (final it in items) {
            if (it is! Map) continue;
            final pItemKey = it['itemKey'];
            final pItemName = it['itemName']?.toString() ?? '';
            if ((itemKey != null && pItemKey == itemKey) ||
                (itemName.isNotEmpty &&
                    pItemName.toLowerCase() == itemName.toLowerCase())) {
              return {
                'vendorKey': bv['vendorKey'],
                'vendorName': bv['vendorName']?.toString() ?? 'Unknown Vendor',
                'vendorPhone': bv['vendorPhone']?.toString() ?? '',
                'purchaseDate': bv['purchaseDate'] != null
                    ? DateTime.tryParse(bv['purchaseDate'].toString())
                    : null,
                'vendorInvoice': bv['vendorInvoiceNumber']?.toString(),
                'purchaseBillNumber': bv['billNumber']?.toString(),
                'purchaseKey': bk,
                'warrantyDuration': it['warrantyDuration']?.toString(),
                'warrantyExpiryDate': it['warrantyExpiryDate'] != null
                    ? DateTime.tryParse(it['warrantyExpiryDate'].toString())
                    : null,
              };
            }
          }
        }
      }
    }

    // 2. Fallback to Db.purchases
    if (Db.purchases.isOpen) {
      // Look in reverse for most recent purchase of this item
      final pKeys = Db.purchases.keys.toList().reversed;
      for (final pk in pKeys) {
        final pv = Db.purchases.get(pk);
        if (pv is! Map) continue;
        final pItemKey = pv['itemKey'];
        final pItemName = pv['itemName']?.toString() ?? '';

        if ((itemKey != null && pItemKey == itemKey) ||
            (itemName.isNotEmpty && pItemName.toLowerCase() == itemName.toLowerCase())) {
          final supKey = pv['supplierKey'];
          final supName = pv['supplierName']?.toString() ?? '';
          String? supPhone;

          if (supKey != null && Db.parties.containsKey(supKey)) {
            final supData = Db.parties.get(supKey);
            if (supData is Map) {
              supPhone = supData['phone']?.toString();
            }
          }

          return {
            'vendorKey': supKey,
            'vendorName': supName.isNotEmpty ? supName : 'Unknown Vendor',
            'vendorPhone': supPhone ?? '',
            'purchaseDate': pv['createdAt'] != null
                ? DateTime.tryParse(pv['createdAt'].toString())
                : null,
            'vendorInvoice': pv['invoiceNumber']?.toString(),
            'purchaseKey': pk,
          };
        }
      }
    }

    return null;
  }

  /// Count previous returns for this invoice or product
  int countPreviousReturns({String? invoiceNumber, String? serialNumber}) {
    if (!_box.isOpen) return 0;
    int count = 0;
    for (final v in _box.values) {
      if (v is! Map) continue;
      final inv = v['originalInvoiceNumber']?.toString();
      final sn = v['serialNumber']?.toString();
      if (invoiceNumber != null && invoiceNumber.isNotEmpty && inv == invoiceNumber) {
        if (serialNumber != null && serialNumber.isNotEmpty) {
          if (sn == serialNumber) count++;
        } else {
          count++;
        }
      }
    }
    return count;
  }

  /// Retrieves all purchased products for a given customer phone number
  List<PurchasedProductItem> getPurchasedProductsByPhone(String phone) {
    final phoneNorm = normalizePhone(phone);
    if (phoneNorm.isEmpty) return [];

    final list = <PurchasedProductItem>[];

    for (final saleKey in Db.sales.keys) {
      final sale = Db.sales.get(saleKey);
      if (sale is! Map) continue;

      final salePhone = sale['customerPhone']?.toString() ?? '';
      final salePhoneNorm = normalizePhone(salePhone);
      if (salePhoneNorm != phoneNorm && !salePhone.contains(phone)) {
        continue;
      }

      final invoice = sale['invoice']?.toString() ?? 'INV-$saleKey';
      final customerName = sale['customerName']?.toString() ?? 'Customer';
      final customerKey = sale['partyKey'];
      final createdAt = DateTime.tryParse(sale['createdAt']?.toString() ?? '') ?? DateTime.now();
      final items = sale['items'];

      if (items is List) {
        for (final it in items) {
          if (it is! Map) continue;
          final productName = it['name']?.toString() ?? 'Unknown Product';
          final brand = it['brand']?.toString() ?? '';
          final model = it['model']?.toString() ?? '';
          final serial = it['imei']?.toString() ?? it['serial']?.toString() ?? '';
          final price = (it['price'] as num?)?.toDouble() ?? 0.0;
          final cost = (it['cost'] as num?)?.toDouble() ?? 0.0;
          final qty = (it['qty'] as num?)?.toInt() ?? 1;
          final warrantyStr = it['warranty']?.toString() ?? '1 Year';
          final itemKey = it['key'] ?? it['itemKey'];
          final itemId = it['itemId']?.toString() ?? it['_id']?.toString() ?? '$itemKey';

          final expiryDate = calculateWarrantyExpiry(createdAt, warrantyStr);
          final warrantyStatus = calculateWarrantyStatus(
            createdAt,
            warrantyStr,
            hasInvoice: invoice.isNotEmpty,
            hasSerial: true,
          );

          // Find original vendor
          final vendorInfo = findOriginalVendor(itemKey, productName);
          final prevReturns = countPreviousReturns(
            invoiceNumber: invoice,
            serialNumber: serial,
          );

          list.add(PurchasedProductItem(
            saleKey: saleKey,
            invoiceNumber: invoice,
            purchaseDate: createdAt,
            customerName: customerName,
            customerPhone: salePhone,
            customerKey: customerKey,
            itemKey: itemKey,
            itemId: itemId,
            productName: productName,
            brand: brand,
            model: model,
            serialNumber: serial,
            price: price,
            cost: cost,
            quantity: qty,
            warrantyPeriod: warrantyStr,
            warrantyExpiryDate: expiryDate,
            calculatedWarrantyStatus: warrantyStatus,
            originalVendorName: vendorInfo?['vendorName'],
            originalVendorKey: vendorInfo?['vendorKey'],
            originalVendorPhone: vendorInfo?['vendorPhone'],
            previousReturnCount: prevReturns,
          ));
        }
      }
    }

    // Sort by purchase date descending (most recent first)
    list.sort((a, b) => b.purchaseDate.compareTo(a.purchaseDate));
    return list;
  }

  // ---------------------------------------------------------------------------
  // RETURN REGISTRATION & CRUD
  // ---------------------------------------------------------------------------

  /// Registers a new customer return
  Future<CustomerReturn> registerReturn({
    required String customerName,
    required String customerPhone,
    dynamic customerKey,
    String? customerId,
    required String originalInvoiceNumber,
    dynamic originalSaleKey,
    dynamic originalItemKey,
    required DateTime originalPurchaseDate,
    required String productName,
    String? productBrand,
    String? productModel,
    String? serialNumber,
    double salePrice = 0.0,
    required String customerWarrantyPeriod,
    DateTime? customerWarrantyExpiryDate,
    required String customerWarrantyStatus,
    String? warrantyInspectionNotes,
    // Original Vendor Information
    dynamic originalVendorKey,
    String? originalVendorName,
    String? originalVendorPhone,
    String? originalVendorInvoice,
    DateTime? originalVendorPurchaseDate,
    String? originalVendorWarrantyPeriod,
    DateTime? originalVendorWarrantyExpiry,
    String? originalVendorReference,
    // Return specifics
    required String returnReason,
    required String customerComplaint,
    required String productCondition,
    required String accessoriesReceived,
    List<String> productPhotos = const [],
    String? assignedStaffId,
    String? assignedStaffName,
    String? internalNotes,
    // Current Actor
    required String actorId,
    required String actorName,
    required String actorRole,
  }) async {
    final returnId = await generateReturnId();
    final now = DateTime.now();

    final initialTimeline = [
      ReturnTimelineEvent(
        id: 'EVT-${now.millisecondsSinceEpoch}-1',
        timestamp: now,
        title: 'Customer Return Received',
        description: 'Return registered with complaint: "$customerComplaint"',
        actorId: actorId,
        actorName: actorName,
        actorRole: actorRole,
        status: CustomerReturnStatus.registered,
        notes: internalNotes,
        metadata: {
          'reason': returnReason,
          'condition': productCondition,
          'accessories': accessoriesReceived,
          'warrantyStatus': customerWarrantyStatus,
        },
      ),
      ReturnTimelineEvent(
        id: 'EVT-${now.millisecondsSinceEpoch}-2',
        timestamp: now.add(const Duration(milliseconds: 10)),
        title: 'Warranty Status Evaluated',
        description: 'Customer Warranty: $customerWarrantyStatus (Period: $customerWarrantyPeriod)',
        actorId: actorId,
        actorName: actorName,
        actorRole: actorRole,
        status: customerWarrantyStatus,
        notes: warrantyInspectionNotes,
      ),
    ];

    final ret = CustomerReturn(
      returnId: returnId,
      createdAt: now,
      customerKey: customerKey,
      customerId: customerId,
      customerName: customerName,
      customerPhone: customerPhone,
      originalInvoiceNumber: originalInvoiceNumber,
      originalSaleKey: originalSaleKey,
      originalItemKey: originalItemKey,
      originalPurchaseDate: originalPurchaseDate,
      productName: productName,
      productBrand: productBrand,
      productModel: productModel,
      serialNumber: serialNumber,
      salePrice: salePrice,
      customerWarrantyPeriod: customerWarrantyPeriod,
      customerWarrantyExpiryDate: customerWarrantyExpiryDate,
      customerWarrantyStatus: customerWarrantyStatus,
      warrantyInspectionNotes: warrantyInspectionNotes,
      warrantyVerifiedById: actorId,
      warrantyVerifiedByName: actorName,
      originalVendorKey: originalVendorKey,
      originalVendorName: originalVendorName,
      originalVendorPhone: originalVendorPhone,
      originalVendorInvoice: originalVendorInvoice,
      originalVendorPurchaseDate: originalVendorPurchaseDate,
      originalVendorWarrantyPeriod: originalVendorWarrantyPeriod,
      originalVendorWarrantyExpiry: originalVendorWarrantyExpiry,
      originalVendorReference: originalVendorReference,
      returnReason: returnReason,
      customerComplaint: customerComplaint,
      productCondition: productCondition,
      accessoriesReceived: accessoriesReceived,
      productPhotos: productPhotos,
      assignedStaffId: assignedStaffId,
      assignedStaffName: assignedStaffName,
      internalNotes: internalNotes,
      customerReturnStatus: CustomerReturnStatus.registered,
      vendorStatus: VendorStatus.notHandedOver,
      timeline: initialTimeline,
      updatedAt: now,
    );

    final hiveKey = await _box.add(ret.toMap());
    final saved = ret.copyWith(key: hiveKey);

    // Audit log
    if (Db.audit.isOpen) {
      await Db.audit.add({
        'action': 'Return Registered',
        'entity': 'Return',
        'entityId': returnId,
        'actorId': actorId,
        'actorName': actorName,
        'timestamp': now.toIso8601String(),
        'details': {
          'customer': customerName,
          'product': productName,
          'reason': returnReason,
        },
      });
    }

    return saved;
  }

  /// Get single return by Hive key
  CustomerReturn? getReturn(dynamic key) {
    if (!_box.isOpen || key == null) return null;
    final val = _box.get(key);
    if (val is! Map) return null;
    return CustomerReturn.fromMap(val, key);
  }

  /// Get single return by returnId (e.g. RET-2026-0001)
  CustomerReturn? getReturnById(String returnId) {
    if (!_box.isOpen) return null;
    for (final key in _box.keys) {
      final val = _box.get(key);
      if (val is Map && val['returnId']?.toString() == returnId) {
        return CustomerReturn.fromMap(val, key);
      }
    }
    return null;
  }

  /// Stream/List of all returns
  List<CustomerReturn> getAllReturns() {
    if (!_box.isOpen) return [];
    final list = <CustomerReturn>[];
    for (final key in _box.keys) {
      final val = _box.get(key);
      if (val is Map) {
        list.add(CustomerReturn.fromMap(val, key));
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  // ---------------------------------------------------------------------------
  // WORKFLOW ACTION 1: VERIFY / OVERRIDE WARRANTY
  // ---------------------------------------------------------------------------

  Future<CustomerReturn> verifyWarranty({
    required dynamic returnKey,
    required String newWarrantyStatus,
    required String reasonNotes,
    required String actorId,
    required String actorName,
    required String actorRole,
  }) async {
    final current = getReturn(returnKey);
    if (current == null) throw Exception('Return record not found');

    final now = DateTime.now();
    final updatedTimeline = List<ReturnTimelineEvent>.from(current.timeline);
    updatedTimeline.add(ReturnTimelineEvent(
      id: 'EVT-${now.millisecondsSinceEpoch}',
      timestamp: now,
      title: 'Warranty Decision: $newWarrantyStatus',
      description: 'Warranty status updated by $actorName ($actorRole). Reason: $reasonNotes',
      actorId: actorId,
      actorName: actorName,
      actorRole: actorRole,
      status: newWarrantyStatus,
      notes: reasonNotes,
    ));

    final updated = current.copyWith(
      customerWarrantyStatus: newWarrantyStatus,
      warrantyInspectionNotes: reasonNotes,
      warrantyVerifiedById: actorId,
      warrantyVerifiedByName: actorName,
      customerReturnStatus: newWarrantyStatus == CustomerWarrantyStatus.claimRejected
          ? CustomerReturnStatus.claimRejected
          : CustomerReturnStatus.warrantyVerified,
      timeline: updatedTimeline,
      updatedAt: now,
    );

    await _box.put(returnKey, updated.toMap());
    return updated;
  }

  // ---------------------------------------------------------------------------
  // WORKFLOW ACTION 2: HAND OVER TO VENDOR
  // ---------------------------------------------------------------------------

  Future<CustomerReturn> handoverToVendor({
    required dynamic returnKey,
    dynamic vendorKey,
    required String vendorName,
    required String vendorPhone,
    required String vendorReferenceNumber,
    required String vendorServiceCentre,
    required String actorId,
    required String actorName,
    required String actorRole,
    required String handoverNotes,
    String? handoverProofUrl,
  }) async {
    final current = getReturn(returnKey);
    if (current == null) throw Exception('Return record not found');

    final vhoRef = await generateHandoverId();
    final now = DateTime.now();

    final handover = VendorHandoverRecord(
      handoverReference: vhoRef,
      handoverDate: now,
      vendorKey: vendorKey,
      vendorName: vendorName,
      vendorPhone: vendorPhone,
      vendorReferenceNumber: vendorReferenceNumber,
      vendorServiceCentre: vendorServiceCentre,
      handedOverById: actorId,
      handedOverByName: actorName,
      handoverNotes: handoverNotes,
      handoverProofUrl: handoverProofUrl,
    );

    final history = List<VendorStatusHistoryItem>.from(current.vendorStatusHistory);
    history.add(VendorStatusHistoryItem(
      previousStatus: current.vendorStatus,
      newStatus: VendorStatus.handedOverToVendor,
      timestamp: now,
      updatedById: actorId,
      updatedByName: actorName,
      vendorReferenceNumber: vendorReferenceNumber,
      notes: handoverNotes,
    ));

    final updatedTimeline = List<ReturnTimelineEvent>.from(current.timeline);
    updatedTimeline.add(ReturnTimelineEvent(
      id: 'EVT-${now.millisecondsSinceEpoch}',
      timestamp: now,
      title: 'Handed Over to Vendor',
      description: 'Handed over to "$vendorName" at "$vendorServiceCentre". Ref: $vhoRef, Vendor Docket: $vendorReferenceNumber',
      actorId: actorId,
      actorName: actorName,
      actorRole: actorRole,
      status: VendorStatus.handedOverToVendor,
      notes: handoverNotes,
    ));

    final updated = current.copyWith(
      originalVendorKey: vendorKey ?? current.originalVendorKey,
      originalVendorName: vendorName,
      originalVendorPhone: vendorPhone,
      originalVendorReference: vendorReferenceNumber,
      customerReturnStatus: CustomerReturnStatus.handedOverToVendor,
      vendorStatus: VendorStatus.handedOverToVendor,
      handoverRecord: handover,
      vendorStatusHistory: history,
      timeline: updatedTimeline,
      updatedAt: now,
    );

    await _box.put(returnKey, updated.toMap());
    return updated;
  }

  // ---------------------------------------------------------------------------
  // WORKFLOW ACTION 3: VENDOR RECEIPT CONFIRMATION
  // ---------------------------------------------------------------------------

  Future<CustomerReturn> confirmVendorReceipt({
    required dynamic returnKey,
    required String actorId,
    required String actorName,
    required String actorRole,
    required String notes,
  }) async {
    final current = getReturn(returnKey);
    if (current == null) throw Exception('Return record not found');
    if (current.handoverRecord == null) {
      throw Exception('Product has not been handed over yet');
    }

    final now = DateTime.now();
    final updatedHandover = current.handoverRecord!.copyWith(
      isReceivedByVendor: true,
      vendorReceivedDate: now,
      vendorReceivedNotes: notes,
    );

    final history = List<VendorStatusHistoryItem>.from(current.vendorStatusHistory);
    history.add(VendorStatusHistoryItem(
      previousStatus: current.vendorStatus,
      newStatus: VendorStatus.receivedByVendor,
      timestamp: now,
      updatedById: actorId,
      updatedByName: actorName,
      vendorReferenceNumber: current.handoverRecord?.vendorReferenceNumber,
      notes: notes,
    ));

    final updatedTimeline = List<ReturnTimelineEvent>.from(current.timeline);
    updatedTimeline.add(ReturnTimelineEvent(
      id: 'EVT-${now.millisecondsSinceEpoch}',
      timestamp: now,
      title: 'Vendor Confirmed Receipt',
      description: 'Vendor confirmed receipt of product at service center.',
      actorId: actorId,
      actorName: actorName,
      actorRole: actorRole,
      status: VendorStatus.receivedByVendor,
      notes: notes,
    ));

    final updated = current.copyWith(
      vendorStatus: VendorStatus.receivedByVendor,
      handoverRecord: updatedHandover,
      vendorStatusHistory: history,
      timeline: updatedTimeline,
      updatedAt: now,
    );

    await _box.put(returnKey, updated.toMap());
    return updated;
  }

  // ---------------------------------------------------------------------------
  // WORKFLOW ACTION 4: UPDATE VENDOR STATUS (14 STATUSES)
  // ---------------------------------------------------------------------------

  Future<CustomerReturn> updateVendorStatus({
    required dynamic returnKey,
    required String newStatus,
    required String actorId,
    required String actorName,
    required String actorRole,
    String? vendorReferenceNumber,
    required String notes,
    List<String> attachments = const [],
  }) async {
    final current = getReturn(returnKey);
    if (current == null) throw Exception('Return record not found');

    final now = DateTime.now();
    final history = List<VendorStatusHistoryItem>.from(current.vendorStatusHistory);
    history.add(VendorStatusHistoryItem(
      previousStatus: current.vendorStatus,
      newStatus: newStatus,
      timestamp: now,
      updatedById: actorId,
      updatedByName: actorName,
      vendorReferenceNumber: vendorReferenceNumber ?? current.originalVendorReference,
      notes: notes,
      attachments: attachments,
    ));

    final updatedTimeline = List<ReturnTimelineEvent>.from(current.timeline);
    updatedTimeline.add(ReturnTimelineEvent(
      id: 'EVT-${now.millisecondsSinceEpoch}',
      timestamp: now,
      title: 'Vendor Status: $newStatus',
      description: notes.isNotEmpty ? notes : 'Status updated to $newStatus',
      actorId: actorId,
      actorName: actorName,
      actorRole: actorRole,
      status: newStatus,
      notes: notes,
      metadata: {
        'vendorRef': vendorReferenceNumber ?? '',
        'attachments': attachments,
      },
    ));

    final updated = current.copyWith(
      vendorStatus: newStatus,
      vendorStatusHistory: history,
      timeline: updatedTimeline,
      updatedAt: now,
    );

    await _box.put(returnKey, updated.toMap());
    return updated;
  }

  // ---------------------------------------------------------------------------
  // WORKFLOW ACTION 5: VENDOR RESOLUTION (REPAIR / REPLACEMENT / REJECTION)
  // ---------------------------------------------------------------------------

  Future<CustomerReturn> resolveVendorClaim({
    required dynamic returnKey,
    required String decision, // VendorResolutionType
    required String actorId,
    required String actorName,
    required String actorRole,
    String? repairDetails,
    bool isReplacement = false,
    String? replacementProduct,
    String? replacementSerialNumber,
    DateTime? replacementReceivedDate,
    double vendorCharges = 0.0,
    double vendorCreditRefund = 0.0,
    String? vendorNotes,
    String? claimRejectionReason,
  }) async {
    final current = getReturn(returnKey);
    if (current == null) throw Exception('Return record not found');

    final now = DateTime.now();

    final resolution = VendorResolution(
      decision: decision,
      decisionDate: now,
      repairDetails: repairDetails,
      isReplacement: isReplacement,
      replacementProduct: replacementProduct,
      replacementSerialNumber: replacementSerialNumber,
      replacementReceivedDate: replacementReceivedDate,
      vendorCharges: vendorCharges,
      vendorCreditRefund: vendorCreditRefund,
      vendorNotes: vendorNotes,
      claimRejectionReason: claimRejectionReason,
      resolvedById: actorId,
      resolvedByName: actorName,
    );

    String newVendorStatus = current.vendorStatus;
    if (decision == VendorResolutionType.repaired) {
      newVendorStatus = VendorStatus.repairedByVendor;
    } else if (decision == VendorResolutionType.replacementApproved) {
      newVendorStatus = VendorStatus.replacementApproved;
    } else if (decision == VendorResolutionType.replacementDispatched) {
      newVendorStatus = VendorStatus.replacementDispatched;
    } else if (decision == VendorResolutionType.replacementReceived) {
      newVendorStatus = VendorStatus.replacementReceivedAtShop;
    } else if (decision == VendorResolutionType.claimRejected) {
      newVendorStatus = VendorStatus.warrantyClaimRejectedByVendor;
    } else if (decision == VendorResolutionType.returnedUnrepaired) {
      newVendorStatus = VendorStatus.returnedUnrepaired;
    }

    final history = List<VendorStatusHistoryItem>.from(current.vendorStatusHistory);
    history.add(VendorStatusHistoryItem(
      previousStatus: current.vendorStatus,
      newStatus: newVendorStatus,
      timestamp: now,
      updatedById: actorId,
      updatedByName: actorName,
      vendorReferenceNumber: current.originalVendorReference,
      notes: vendorNotes ?? repairDetails ?? claimRejectionReason ?? 'Resolution recorded',
    ));

    final updatedTimeline = List<ReturnTimelineEvent>.from(current.timeline);
    String timelineTitle = 'Vendor Resolution: $decision';
    String timelineDesc = '';
    if (isReplacement) {
      timelineTitle = 'Vendor Replacement: $replacementProduct';
      timelineDesc = 'Replacement unit approved/received with New Serial: ${replacementSerialNumber ?? "N/A"}.';
    } else if (decision == VendorResolutionType.repaired) {
      timelineDesc = 'Product repaired by vendor. $repairDetails';
    } else if (decision == VendorResolutionType.claimRejected) {
      timelineDesc = 'Claim rejected by vendor: $claimRejectionReason';
    }

    updatedTimeline.add(ReturnTimelineEvent(
      id: 'EVT-${now.millisecondsSinceEpoch}',
      timestamp: now,
      title: timelineTitle,
      description: timelineDesc,
      actorId: actorId,
      actorName: actorName,
      actorRole: actorRole,
      status: newVendorStatus,
      notes: vendorNotes,
      metadata: {
        'vendorCharges': vendorCharges,
        'vendorCredit': vendorCreditRefund,
        'newSerial': replacementSerialNumber ?? '',
      },
    ));

    final updated = current.copyWith(
      vendorStatus: newVendorStatus,
      vendorResolution: resolution,
      vendorStatusHistory: history,
      timeline: updatedTimeline,
      updatedAt: now,
    );

    await _box.put(returnKey, updated.toMap());
    return updated;
  }

  // ---------------------------------------------------------------------------
  // WORKFLOW ACTION 6: RECEIVE PRODUCT AT SHOP ("RECEIVE FROM VENDOR")
  // ---------------------------------------------------------------------------

  Future<CustomerReturn> receiveAtShop({
    required dynamic returnKey,
    required String actorId,
    required String actorName,
    required String actorRole,
    required String inspectionNotes,
    required bool isReadyForCustomer,
    String? conditionAfterVendor,
  }) async {
    final current = getReturn(returnKey);
    if (current == null) throw Exception('Return record not found');

    final now = DateTime.now();
    final updatedTimeline = List<ReturnTimelineEvent>.from(current.timeline);

    updatedTimeline.add(ReturnTimelineEvent(
      id: 'EVT-${now.millisecondsSinceEpoch}-1',
      timestamp: now,
      title: 'Received at Shop',
      description: 'Product received back at shop from vendor. Inspection: "$inspectionNotes"',
      actorId: actorId,
      actorName: actorName,
      actorRole: actorRole,
      status: CustomerReturnStatus.receivedAtShop,
      notes: inspectionNotes,
    ));

    if (isReadyForCustomer) {
      updatedTimeline.add(ReturnTimelineEvent(
        id: 'EVT-${now.millisecondsSinceEpoch}-2',
        timestamp: now.add(const Duration(milliseconds: 10)),
        title: 'Ready for Customer',
        description: 'Quality check passed. Ready for customer pickup / dispatch.',
        actorId: actorId,
        actorName: actorName,
        actorRole: actorRole,
        status: CustomerReturnStatus.readyForCustomer,
      ));
    }

    final updated = current.copyWith(
      shopReceiptDate: now,
      shopReceivedById: actorId,
      shopReceivedByName: actorName,
      shopInspectionNotes: inspectionNotes,
      isReadyForCustomer: isReadyForCustomer,
      customerReturnStatus: isReadyForCustomer
          ? CustomerReturnStatus.readyForCustomer
          : CustomerReturnStatus.receivedAtShop,
      vendorStatus: (current.vendorResolution?.isReplacement == true)
          ? VendorStatus.replacementReceivedAtShop
          : (current.vendorStatus == VendorStatus.returnedUnrepaired
              ? VendorStatus.returnedUnrepaired
              : VendorStatus.repairedByVendor),
      timeline: updatedTimeline,
      updatedAt: now,
    );

    await _box.put(returnKey, updated.toMap());
    return updated;
  }

  // ---------------------------------------------------------------------------
  // WORKFLOW ACTION 7: RETURN PRODUCT TO CUSTOMER
  // ---------------------------------------------------------------------------

  Future<CustomerReturn> returnToCustomer({
    required dynamic returnKey,
    required String actorId,
    required String actorName,
    required String actorRole,
    required String customerConfirmation,
    String? deliveryNotes,
    String? deliveredProductDetails,
  }) async {
    final current = getReturn(returnKey);
    if (current == null) throw Exception('Return record not found');

    final now = DateTime.now();

    final delivery = CustomerDeliveryRecord(
      deliveryDate: now,
      deliveredById: actorId,
      deliveredByName: actorName,
      customerConfirmation: customerConfirmation,
      deliveryNotes: deliveryNotes,
      deliveredProductDetails: deliveredProductDetails ??
          (current.vendorResolution?.isReplacement == true
              ? 'Replacement: ${current.vendorResolution?.replacementProduct} (IMEI: ${current.vendorResolution?.replacementSerialNumber})'
              : 'Original Product: ${current.productName} (IMEI: ${current.serialNumber})'),
    );

    final updatedTimeline = List<ReturnTimelineEvent>.from(current.timeline);
    updatedTimeline.add(ReturnTimelineEvent(
      id: 'EVT-${now.millisecondsSinceEpoch}',
      timestamp: now,
      title: 'Returned to Customer',
      description: 'Product handed over to customer. Confirmation: "$customerConfirmation"',
      actorId: actorId,
      actorName: actorName,
      actorRole: actorRole,
      status: CustomerReturnStatus.returnedToCustomer,
      notes: deliveryNotes,
    ));

    final updated = current.copyWith(
      customerDeliveryRecord: delivery,
      customerReturnStatus: CustomerReturnStatus.returnedToCustomer,
      isCompleted: true,
      timeline: updatedTimeline,
      updatedAt: now,
    );

    await _box.put(returnKey, updated.toMap());
    return updated;
  }

  // ---------------------------------------------------------------------------
  // VENDOR FOLLOW-UP THRESHOLD & ALERTS
  // ---------------------------------------------------------------------------

  int getFollowupThresholdDays() {
    final val = Db.settings.get('vendor_followup_threshold_days');
    if (val != null) {
      final parsed = int.tryParse(val.toString());
      if (parsed != null && parsed > 0) return parsed;
    }
    return 7; // Default 7 days
  }

  Future<void> setFollowupThresholdDays(int days) async {
    await Db.settings.put('vendor_followup_threshold_days', days.toString());
  }

  // ---------------------------------------------------------------------------
  // OWNER DASHBOARD METRICS & FILTERING
  // ---------------------------------------------------------------------------

  Map<String, int> computeDashboardMetrics() {
    final returns = getAllReturns();
    final threshold = getFollowupThresholdDays();

    int totalReturns = returns.length;
    int pendingInspection = 0;
    int handedOverToVendors = 0;
    int awaitingVendorConfirmation = 0;
    int underRepairAtVendor = 0;
    int replacementAwaited = 0;
    int vendorFollowUpRequired = 0;
    int receivedFromVendor = 0;
    int readyForCustomer = 0;
    int completedReturns = 0;

    for (final r in returns) {
      if (r.isCompleted || r.customerReturnStatus == CustomerReturnStatus.completed || r.customerReturnStatus == CustomerReturnStatus.returnedToCustomer) {
        completedReturns++;
      }

      if (r.customerReturnStatus == CustomerReturnStatus.registered ||
          r.customerReturnStatus == CustomerReturnStatus.underInspection ||
          r.customerWarrantyStatus == CustomerWarrantyStatus.underWarrantyInspection) {
        pendingInspection++;
      }

      if (r.vendorStatus == VendorStatus.handedOverToVendor) {
        handedOverToVendors++;
        awaitingVendorConfirmation++;
      }

      if (r.vendorStatus == VendorStatus.underRepairAtVendor ||
          r.vendorStatus == VendorStatus.waitingForSpareParts ||
          r.vendorStatus == VendorStatus.underInspectionAtVendor) {
        underRepairAtVendor++;
      }

      if (r.vendorStatus == VendorStatus.replacementApproved ||
          r.vendorStatus == VendorStatus.replacementDispatched ||
          r.vendorStatus == VendorStatus.waitingForVendorApproval) {
        replacementAwaited++;
      }

      if (r.isFollowUpOverdue(threshold) || r.vendorStatus == VendorStatus.vendorFollowUpRequired) {
        vendorFollowUpRequired++;
      }

      if (r.customerReturnStatus == CustomerReturnStatus.receivedAtShop) {
        receivedFromVendor++;
      }

      if (r.isReadyForCustomer && !r.isCompleted) {
        readyForCustomer++;
      }
    }

    return {
      'Total Customer Returns': totalReturns,
      'Pending Inspection': pendingInspection,
      'Handed Over to Vendors': handedOverToVendors,
      'Awaiting Vendor Confirmation': awaitingVendorConfirmation,
      'Under Repair at Vendor': underRepairAtVendor,
      'Replacement Awaited': replacementAwaited,
      'Vendor Follow-up Required': vendorFollowUpRequired,
      'Received from Vendor': receivedFromVendor,
      'Ready for Customer': readyForCustomer,
      'Completed Returns': completedReturns,
    };
  }

  /// Multi-criteria search and filter
  List<CustomerReturn> searchAndFilter({
    String query = '',
    String? vendorFilter,
    String? returnStatusFilter,
    String? vendorStatusFilter,
    String? staffFilter,
    DateTime? startDate,
    DateTime? endDate,
    String? cardFilterCategory,
  }) {
    final list = getAllReturns();
    final q = query.trim().toLowerCase();
    final qNorm = normalizePhone(q);
    final threshold = getFollowupThresholdDays();

    return list.where((r) {
      // 1. Text Search matching Return ID, Customer Name, Phone, Product Name, Serial, Invoice, Vendor Name, Vendor Ref
      if (q.isNotEmpty) {
        final matches = r.returnId.toLowerCase().contains(q) ||
            r.customerName.toLowerCase().contains(q) ||
            r.customerPhone.contains(q) ||
            normalizePhone(r.customerPhone).contains(qNorm) ||
            r.productName.toLowerCase().contains(q) ||
            (r.serialNumber?.toLowerCase().contains(q) ?? false) ||
            r.originalInvoiceNumber.toLowerCase().contains(q) ||
            (r.originalVendorName?.toLowerCase().contains(q) ?? false) ||
            (r.originalVendorReference?.toLowerCase().contains(q) ?? false) ||
            (r.handoverRecord?.handoverReference.toLowerCase().contains(q) ?? false);
        if (!matches) return false;
      }

      // 2. Vendor Filter
      if (vendorFilter != null && vendorFilter.isNotEmpty && vendorFilter != 'All Vendors') {
        if (r.originalVendorName != vendorFilter && r.handoverRecord?.vendorName != vendorFilter) {
          return false;
        }
      }

      // 3. Return Status Filter
      if (returnStatusFilter != null && returnStatusFilter.isNotEmpty && returnStatusFilter != 'All Statuses') {
        if (r.customerReturnStatus != returnStatusFilter) return false;
      }

      // 4. Vendor Status Filter
      if (vendorStatusFilter != null && vendorStatusFilter.isNotEmpty && vendorStatusFilter != 'All Vendor Statuses') {
        if (r.vendorStatus != vendorStatusFilter) return false;
      }

      // 5. Staff Filter
      if (staffFilter != null && staffFilter.isNotEmpty && staffFilter != 'All Staff') {
        if (r.assignedStaffName != staffFilter && r.warrantyVerifiedByName != staffFilter) {
          return false;
        }
      }

      // 6. Date Range Filter
      if (startDate != null && r.createdAt.isBefore(startDate)) return false;
      if (endDate != null && r.createdAt.isAfter(endDate.add(const Duration(days: 1)))) return false;

      // 7. Card KPI Filter
      if (cardFilterCategory != null && cardFilterCategory.isNotEmpty) {
        switch (cardFilterCategory) {
          case 'Pending Inspection':
            return r.customerReturnStatus == CustomerReturnStatus.registered ||
                r.customerReturnStatus == CustomerReturnStatus.underInspection;
          case 'Handed Over to Vendors':
            return r.vendorStatus == VendorStatus.handedOverToVendor;
          case 'Awaiting Vendor Confirmation':
            return r.vendorStatus == VendorStatus.handedOverToVendor;
          case 'Under Repair at Vendor':
            return r.vendorStatus == VendorStatus.underRepairAtVendor ||
                r.vendorStatus == VendorStatus.waitingForSpareParts ||
                r.vendorStatus == VendorStatus.underInspectionAtVendor;
          case 'Replacement Awaited':
            return r.vendorStatus == VendorStatus.replacementApproved ||
                r.vendorStatus == VendorStatus.replacementDispatched;
          case 'Vendor Follow-up Required':
            return r.isFollowUpOverdue(threshold) || r.vendorStatus == VendorStatus.vendorFollowUpRequired;
          case 'Received from Vendor':
            return r.customerReturnStatus == CustomerReturnStatus.receivedAtShop;
          case 'Ready for Customer':
            return r.isReadyForCustomer && !r.isCompleted;
          case 'Completed Returns':
            return r.isCompleted || r.customerReturnStatus == CustomerReturnStatus.returnedToCustomer;
          default:
            break;
        }
      }

      return true;
    }).toList();
  }
}
