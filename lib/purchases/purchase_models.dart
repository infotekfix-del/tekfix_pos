import 'package:flutter/material.dart';

/// Payment Status for a Purchase Bill.
class BillPaymentStatus {
  static const String paid = 'Paid';
  static const String partiallyPaid = 'Partially Paid';
  static const String unpaid = 'Unpaid';
  static const String draft = 'Draft';

  static const List<String> all = [paid, partiallyPaid, unpaid, draft];

  static Color getColor(String status) {
    switch (status) {
      case paid:
        return const Color(0xFF10B981); // Emerald Green
      case partiallyPaid:
        return const Color(0xFFF59E0B); // Amber / Orange
      case unpaid:
        return const Color(0xFFEF4444); // Red
      case draft:
        return const Color(0xFFF97316); // Orange
      default:
        return const Color(0xFF94A3B8);
    }
  }

  static IconData getIcon(String status) {
    switch (status) {
      case paid:
        return Icons.check_circle_rounded;
      case partiallyPaid:
        return Icons.timelapse_rounded;
      case unpaid:
        return Icons.pending_actions_rounded;
      case draft:
        return Icons.drafts_rounded;
      default:
        return Icons.help_outline_rounded;
    }
  }
}

/// Item Warranty Duration Options
class ItemWarrantyDuration {
  static const String threeMonths = '3 Months';
  static const String sixMonths = '6 Months';
  static const String twelveMonths = '12 Months';
  static const String twentyFourMonths = '24 Months';
  static const String custom = 'Custom Duration';
  static const String noWarranty = 'No Warranty';

  static const String months3 = threeMonths;
  static const String months6 = sixMonths;
  static const String months12 = twelveMonths;
  static const String months24 = twentyFourMonths;

  static const List<String> presets = [
    threeMonths,
    sixMonths,
    twelveMonths,
    twentyFourMonths,
    custom,
    noWarranty,
  ];
}

/// Individual item line in a Purchase Bill
class PurchaseBillItem {
  final String id;
  final dynamic itemKey;
  final String itemId;
  final String name;
  final String category;
  final String brand;
  final String model;
  final String sku;
  final String imeiOrSerial;
  final List<String> serialNumbers;
  final int quantity;
  final double purchaseRate;
  final double discount;
  final double taxPercent;
  final double taxAmount;
  final double lineTotal;
  final bool warrantyAvailable;
  final String warrantyDuration;
  final int? customWarrantyDays;
  final DateTime? warrantyExpiryDate;

  String get itemName => name;
  String get productCode => sku;
  bool get hasWarranty => warrantyAvailable;

  PurchaseBillItem({
    String? id,
    this.itemKey,
    String? itemId,
    String? name,
    String? itemName,
    this.category = '',
    this.brand = '',
    this.model = '',
    String? sku,
    String? productCode,
    String? imeiOrSerial,
    this.serialNumbers = const [],
    required this.quantity,
    required this.purchaseRate,
    this.discount = 0.0,
    this.taxPercent = 0.0,
    double? taxAmount,
    double? lineTotal,
    bool? warrantyAvailable,
    bool? hasWarranty,
    this.warrantyDuration = ItemWarrantyDuration.noWarranty,
    this.customWarrantyDays,
    this.warrantyExpiryDate,
  })  : id = id ?? 'ITEM_${DateTime.now().microsecondsSinceEpoch}',
        itemId = itemId ?? (itemKey != null ? '$itemKey' : 'ITEM_${DateTime.now().microsecondsSinceEpoch}'),
        name = name ?? itemName ?? 'Unknown Item',
        sku = sku ?? productCode ?? '',
        imeiOrSerial = imeiOrSerial ?? '',
        warrantyAvailable = warrantyAvailable ?? hasWarranty ?? false,
        taxAmount = taxAmount ??
            (((quantity * purchaseRate) - discount) > 0
                ? (((quantity * purchaseRate) - discount) * taxPercent / 100)
                : 0.0),
        lineTotal = lineTotal ??
            ((((quantity * purchaseRate) - discount) +
                    (((quantity * purchaseRate) - discount) > 0
                        ? (((quantity * purchaseRate) - discount) * taxPercent / 100)
                        : 0.0))
                .clamp(0.0, double.infinity));

  Map<String, dynamic> toMap() => {
        'id': id,
        'itemKey': itemKey,
        'itemId': itemId,
        'name': name,
        'category': category,
        'brand': brand,
        'model': model,
        'sku': sku,
        'imeiOrSerial': imeiOrSerial,
        'serialNumbers': serialNumbers,
        'quantity': quantity,
        'purchaseRate': purchaseRate,
        'discount': discount,
        'taxPercent': taxPercent,
        'taxAmount': taxAmount,
        'lineTotal': lineTotal,
        'warrantyAvailable': warrantyAvailable,
        'warrantyDuration': warrantyDuration,
        'warrantyExpiryDate': warrantyExpiryDate?.toIso8601String(),
      };

  factory PurchaseBillItem.fromMap(Map<dynamic, dynamic> m) {
    return PurchaseBillItem(
      id: m['id']?.toString() ?? '',
      itemKey: m['itemKey'],
      itemId: m['itemId']?.toString() ?? '',
      name: m['name']?.toString() ?? '',
      category: m['category']?.toString() ?? '',
      brand: m['brand']?.toString() ?? '',
      model: m['model']?.toString() ?? '',
      sku: m['sku']?.toString() ?? '',
      imeiOrSerial: m['imeiOrSerial']?.toString() ?? '',
      serialNumbers: (m['serialNumbers'] is List)
          ? (m['serialNumbers'] as List).map((e) => e.toString()).toList()
          : [],
      quantity: (m['quantity'] as num?)?.toInt() ?? 1,
      purchaseRate: (m['purchaseRate'] as num?)?.toDouble() ?? 0.0,
      discount: (m['discount'] as num?)?.toDouble() ?? 0.0,
      taxPercent: (m['taxPercent'] as num?)?.toDouble() ?? 0.0,
      taxAmount: (m['taxAmount'] as num?)?.toDouble() ?? 0.0,
      lineTotal: (m['lineTotal'] as num?)?.toDouble() ?? 0.0,
      warrantyAvailable: m['warrantyAvailable'] == true,
      warrantyDuration: m['warrantyDuration']?.toString() ?? ItemWarrantyDuration.noWarranty,
      warrantyExpiryDate: m['warrantyExpiryDate'] != null
          ? DateTime.tryParse(m['warrantyExpiryDate'].toString())
          : null,
    );
  }

  PurchaseBillItem copyWith({
    int? quantity,
    double? purchaseRate,
    double? discount,
    double? taxPercent,
    double? taxAmount,
    double? lineTotal,
    bool? warrantyAvailable,
    String? warrantyDuration,
    DateTime? warrantyExpiryDate,
    String? imeiOrSerial,
    List<String>? serialNumbers,
  }) {
    return PurchaseBillItem(
      id: id,
      itemKey: itemKey,
      itemId: itemId,
      name: name,
      category: category,
      brand: brand,
      model: model,
      sku: sku,
      imeiOrSerial: imeiOrSerial ?? this.imeiOrSerial,
      serialNumbers: serialNumbers ?? this.serialNumbers,
      quantity: quantity ?? this.quantity,
      purchaseRate: purchaseRate ?? this.purchaseRate,
      discount: discount ?? this.discount,
      taxPercent: taxPercent ?? this.taxPercent,
      taxAmount: taxAmount ?? this.taxAmount,
      lineTotal: lineTotal ?? this.lineTotal,
      warrantyAvailable: warrantyAvailable ?? this.warrantyAvailable,
      warrantyDuration: warrantyDuration ?? this.warrantyDuration,
      warrantyExpiryDate: warrantyExpiryDate ?? this.warrantyExpiryDate,
    );
  }
}

/// Uploaded Bill Document Attachment (Image or PDF)
class BillAttachment {
  final String id;
  final String fileName;
  final String fileType; // 'image' or 'pdf'
  final String? filePath;
  final String? bytesBase64;
  final int fileSizeBytes;
  final DateTime uploadedAt;

  bool get isPdf =>
      fileType.toLowerCase().contains('pdf') ||
      fileName.toLowerCase().endsWith('.pdf');

  int get fileSize => fileSizeBytes;
  String? get fileBytesBase64 => bytesBase64;

  String get formattedSize {
    if (fileSizeBytes > 1024 * 1024) {
      return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (fileSizeBytes > 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$fileSizeBytes B';
  }

  BillAttachment({
    String? id,
    required this.fileName,
    required this.fileType,
    this.filePath,
    String? bytesBase64,
    String? fileBytesBase64,
    int? fileSizeBytes,
    int? fileSize,
    DateTime? uploadedAt,
  })  : id = id ?? 'ATT_${DateTime.now().microsecondsSinceEpoch}',
        bytesBase64 = bytesBase64 ?? fileBytesBase64,
        fileSizeBytes = fileSizeBytes ?? fileSize ?? 0,
        uploadedAt = uploadedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'fileName': fileName,
        'fileType': fileType,
        'filePath': filePath,
        'bytesBase64': bytesBase64,
        'fileSizeBytes': fileSizeBytes,
        'uploadedAt': uploadedAt.toIso8601String(),
      };

  factory BillAttachment.fromMap(Map<dynamic, dynamic> m) {
    return BillAttachment(
      id: m['id']?.toString() ?? '',
      fileName: m['fileName']?.toString() ?? '',
      fileType: m['fileType']?.toString() ?? 'image',
      filePath: m['filePath']?.toString(),
      bytesBase64: m['bytesBase64']?.toString(),
      fileSizeBytes: (m['fileSizeBytes'] as num?)?.toInt() ?? 0,
      uploadedAt: DateTime.tryParse(m['uploadedAt']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

/// Vendor Payment Record
class VendorPaymentRecord {
  final String paymentId;
  final dynamic billKey;
  final String billNumber;
  final dynamic vendorKey;
  final String vendorName;
  final double amount;
  final DateTime paymentDate;
  final String paymentMethod; // Cash, UPI, Bank Transfer, Card, Cheque, Other
  final String transactionReference;
  final String? notes;
  final String recordedById;
  final String recordedByName;
  final bool isAdvance;

  const VendorPaymentRecord({
    required this.paymentId,
    this.billKey,
    required this.billNumber,
    this.vendorKey,
    required this.vendorName,
    required this.amount,
    required this.paymentDate,
    required this.paymentMethod,
    required this.transactionReference,
    this.notes,
    required this.recordedById,
    required this.recordedByName,
    this.isAdvance = false,
  });

  Map<String, dynamic> toMap() => {
        'paymentId': paymentId,
        'billKey': billKey,
        'billNumber': billNumber,
        'vendorKey': vendorKey,
        'vendorName': vendorName,
        'amount': amount,
        'paymentDate': paymentDate.toIso8601String(),
        'paymentMethod': paymentMethod,
        'transactionReference': transactionReference,
        'notes': notes,
        'recordedById': recordedById,
        'recordedByName': recordedByName,
        'isAdvance': isAdvance,
      };

  factory VendorPaymentRecord.fromMap(Map<dynamic, dynamic> m) {
    return VendorPaymentRecord(
      paymentId: m['paymentId']?.toString() ?? '',
      billKey: m['billKey'],
      billNumber: m['billNumber']?.toString() ?? '',
      vendorKey: m['vendorKey'],
      vendorName: m['vendorName']?.toString() ?? '',
      amount: (m['amount'] as num?)?.toDouble() ?? 0.0,
      paymentDate: DateTime.tryParse(m['paymentDate']?.toString() ?? '') ?? DateTime.now(),
      paymentMethod: m['paymentMethod']?.toString() ?? 'Cash',
      transactionReference: m['transactionReference']?.toString() ?? '',
      notes: m['notes']?.toString(),
      recordedById: m['recordedById']?.toString() ?? '',
      recordedByName: m['recordedByName']?.toString() ?? 'Staff',
      isAdvance: m['isAdvance'] == true,
    );
  }
}

/// Complete Purchase Bill Record
class PurchaseBill {
  final dynamic key;
  final String billNumber; // e.g. PB-2026-0001
  final String vendorInvoiceNumber;
  final dynamic vendorKey;
  final String vendorName;
  final String vendorPhone;
  final String? vendorGst;
  final String? vendorAddress;
  final DateTime purchaseDate;
  final DateTime uploadTimestamp;
  final List<PurchaseBillItem> items;
  final double subtotal;
  final int totalQuantity;
  final double totalDiscount;
  final double totalTax;
  final double otherCharges;
  final double grandTotal;
  final double paidAmount;
  final double balanceDue;
  final String paymentStatus; // BillPaymentStatus
  final List<VendorPaymentRecord> payments;
  final BillAttachment? attachment;
  final String createdById;
  final String createdByName;
  final String? lastUpdatedById;
  final String? lastUpdatedByName;
  final String? notes;
  final bool isDraft;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PurchaseBill({
    this.key,
    required this.billNumber,
    required this.vendorInvoiceNumber,
    this.vendorKey,
    required this.vendorName,
    required this.vendorPhone,
    this.vendorGst,
    this.vendorAddress,
    required this.purchaseDate,
    required this.uploadTimestamp,
    this.items = const [],
    required this.subtotal,
    required this.totalQuantity,
    this.totalDiscount = 0.0,
    this.totalTax = 0.0,
    this.otherCharges = 0.0,
    required this.grandTotal,
    this.paidAmount = 0.0,
    required this.balanceDue,
    required this.paymentStatus,
    this.payments = const [],
    this.attachment,
    required this.createdById,
    required this.createdByName,
    this.lastUpdatedById,
    this.lastUpdatedByName,
    this.notes,
    this.isDraft = false,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'billNumber': billNumber,
        'vendorInvoiceNumber': vendorInvoiceNumber,
        'vendorKey': vendorKey,
        'vendorName': vendorName,
        'vendorPhone': vendorPhone,
        'vendorGst': vendorGst,
        'vendorAddress': vendorAddress,
        'purchaseDate': purchaseDate.toIso8601String(),
        'uploadTimestamp': uploadTimestamp.toIso8601String(),
        'items': items.map((e) => e.toMap()).toList(),
        'subtotal': subtotal,
        'totalQuantity': totalQuantity,
        'totalDiscount': totalDiscount,
        'totalTax': totalTax,
        'otherCharges': otherCharges,
        'grandTotal': grandTotal,
        'paidAmount': paidAmount,
        'balanceDue': balanceDue,
        'paymentStatus': paymentStatus,
        'payments': payments.map((e) => e.toMap()).toList(),
        'attachment': attachment?.toMap(),
        'createdById': createdById,
        'createdByName': createdByName,
        'lastUpdatedById': lastUpdatedById,
        'lastUpdatedByName': lastUpdatedByName,
        'notes': notes,
        'isDraft': isDraft,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory PurchaseBill.fromMap(Map<dynamic, dynamic> m, [dynamic key]) {
    return PurchaseBill(
      key: key ?? m['key'],
      billNumber: m['billNumber']?.toString() ?? '',
      vendorInvoiceNumber: m['vendorInvoiceNumber']?.toString() ?? '',
      vendorKey: m['vendorKey'],
      vendorName: m['vendorName']?.toString() ?? '',
      vendorPhone: m['vendorPhone']?.toString() ?? '',
      vendorGst: m['vendorGst']?.toString(),
      vendorAddress: m['vendorAddress']?.toString(),
      purchaseDate: DateTime.tryParse(m['purchaseDate']?.toString() ?? '') ?? DateTime.now(),
      uploadTimestamp: DateTime.tryParse(m['uploadTimestamp']?.toString() ?? '') ?? DateTime.now(),
      items: (m['items'] is List)
          ? (m['items'] as List).map((e) => PurchaseBillItem.fromMap(e as Map)).toList()
          : [],
      subtotal: (m['subtotal'] as num?)?.toDouble() ?? 0.0,
      totalQuantity: (m['totalQuantity'] as num?)?.toInt() ?? 0,
      totalDiscount: (m['totalDiscount'] as num?)?.toDouble() ?? 0.0,
      totalTax: (m['totalTax'] as num?)?.toDouble() ?? 0.0,
      otherCharges: (m['otherCharges'] as num?)?.toDouble() ?? 0.0,
      grandTotal: (m['grandTotal'] as num?)?.toDouble() ?? 0.0,
      paidAmount: (m['paidAmount'] as num?)?.toDouble() ?? 0.0,
      balanceDue: (m['balanceDue'] as num?)?.toDouble() ?? 0.0,
      paymentStatus: m['paymentStatus']?.toString() ?? BillPaymentStatus.unpaid,
      payments: (m['payments'] is List)
          ? (m['payments'] as List).map((e) => VendorPaymentRecord.fromMap(e as Map)).toList()
          : [],
      attachment: (m['attachment'] is Map)
          ? BillAttachment.fromMap(m['attachment'])
          : null,
      createdById: m['createdById']?.toString() ?? '',
      createdByName: m['createdByName']?.toString() ?? 'Staff',
      lastUpdatedById: m['lastUpdatedById']?.toString(),
      lastUpdatedByName: m['lastUpdatedByName']?.toString(),
      notes: m['notes']?.toString(),
      isDraft: m['isDraft'] == true,
      createdAt: DateTime.tryParse(m['createdAt']?.toString() ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(m['updatedAt']?.toString() ?? '') ?? DateTime.now(),
    );
  }

  PurchaseBill copyWith({
    dynamic key,
    double? paidAmount,
    double? balanceDue,
    String? paymentStatus,
    List<VendorPaymentRecord>? payments,
    BillAttachment? attachment,
    String? lastUpdatedById,
    String? lastUpdatedByName,
    String? notes,
    bool? isDraft,
    DateTime? updatedAt,
  }) {
    return PurchaseBill(
      key: key ?? this.key,
      billNumber: billNumber,
      vendorInvoiceNumber: vendorInvoiceNumber,
      vendorKey: vendorKey,
      vendorName: vendorName,
      vendorPhone: vendorPhone,
      vendorGst: vendorGst,
      vendorAddress: vendorAddress,
      purchaseDate: purchaseDate,
      uploadTimestamp: uploadTimestamp,
      items: items,
      subtotal: subtotal,
      totalQuantity: totalQuantity,
      totalDiscount: totalDiscount,
      totalTax: totalTax,
      otherCharges: otherCharges,
      grandTotal: grandTotal,
      paidAmount: paidAmount ?? this.paidAmount,
      balanceDue: balanceDue ?? this.balanceDue,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      payments: payments ?? this.payments,
      attachment: attachment ?? this.attachment,
      createdById: createdById,
      createdByName: createdByName,
      lastUpdatedById: lastUpdatedById ?? this.lastUpdatedById,
      lastUpdatedByName: lastUpdatedByName ?? this.lastUpdatedByName,
      notes: notes ?? this.notes,
      isDraft: isDraft ?? this.isDraft,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }
}

/// Vendor Ledger Statement Entry
class VendorLedgerEntry {
  final String id;
  final DateTime date;
  final String type; // 'Purchase Bill', 'Payment', 'Advance'
  final String reference;
  final String? vendorInvoiceNumber;
  final double debit; // Bill amount (increases what we owe)
  final double credit; // Payment amount (reduces what we owe)
  final double runningBalance;
  final String? notes;

  const VendorLedgerEntry({
    required this.id,
    required this.date,
    required this.type,
    required this.reference,
    this.vendorInvoiceNumber,
    required this.debit,
    required this.credit,
    required this.runningBalance,
    this.notes,
  });
}
