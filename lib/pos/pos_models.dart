import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a retail product visible to staff (Cost price is intentionally excluded).
class PosItem {
  final String id;
  final String name;
  final String sku;
  final String barcode;
  final String category;
  final double sellingPrice; // MRP
  final double minPrice; // Floor Price (Hard minimum)
  final int stock;
  final int lowStockLevel;

  const PosItem({
    required this.id,
    required this.name,
    this.sku = '',
    this.barcode = '',
    this.category = 'Others',
    required this.sellingPrice,
    required this.minPrice,
    this.stock = 0,
    this.lowStockLevel = 5,
  });

  factory PosItem.fromMap(String id, Map<String, dynamic> m) {
    final double mrp = (m['sellingPrice'] as num?)?.toDouble() ??
        (m['price'] as num?)?.toDouble() ??
        0.0;
    // Floor price defaults to selling price if not explicitly set
    final double floor = (m['minPrice'] as num?)?.toDouble() ?? (mrp * 0.9);

    return PosItem(
      id: id,
      name: '${m['name'] ?? 'Item'}',
      sku: '${m['sku'] ?? ''}',
      barcode: '${m['barcode'] ?? m['imei'] ?? ''}',
      category: '${m['category'] ?? 'Others'}',
      sellingPrice: mrp,
      minPrice: floor,
      stock: (m['stock'] as num?)?.toInt() ?? 0,
      lowStockLevel: (m['lowStockLevel'] as num?)?.toInt() ?? 5,
    );
  }

  bool get isOutOfStock => stock <= 0;
  bool get isLowStock => stock > 0 && stock <= lowStockLevel;
}

/// Represents a line item in the POS shopping cart.
class PosCartItem {
  final PosItem item;
  int qty;
  double unitPrice;
  String? approvalId; // Present if owner approved price below floor

  PosCartItem({
    required this.item,
    this.qty = 1,
    required this.unitPrice,
    this.approvalId,
  });

  double get lineTotal => unitPrice * qty;
  bool get isBelowFloor => unitPrice < item.minPrice;
  bool get hasValidOverride => isBelowFloor && approvalId != null && approvalId!.isNotEmpty;
}

/// Payment breakdown for an invoice.
class PosPayment {
  final String mode; // "Cash", "UPI", "Card", "Split"
  final double totalAmount;
  final double cashAmount;
  final double upiAmount;
  final double cardAmount;
  final double cashReceived;
  final double changeDue;

  const PosPayment({
    required this.mode,
    required this.totalAmount,
    this.cashAmount = 0.0,
    this.upiAmount = 0.0,
    this.cardAmount = 0.0,
    this.cashReceived = 0.0,
    this.changeDue = 0.0,
  });

  Map<String, dynamic> toMap() => {
        'mode': mode,
        'totalAmount': totalAmount,
        'cashAmount': cashAmount,
        'upiAmount': upiAmount,
        'cardAmount': cardAmount,
        'cashReceived': cashReceived,
        'changeDue': changeDue,
      };
}

/// Completed POS Invoice.
class PosInvoice {
  final String invoiceId;
  final String shopId;
  final String staffId;
  final String staffName;
  final String? attendanceDocId;
  final String? date;
  final String customerName;
  final String customerPhone;
  final List<Map<String, dynamic>> items;
  final double subtotal;
  final double discount;
  final double total;
  final PosPayment payment;
  final DateTime createdAt;
  final String status; // "completed", "needs_review", "voided"

  const PosInvoice({
    required this.invoiceId,
    required this.shopId,
    required this.staffId,
    required this.staffName,
    this.attendanceDocId,
    this.date,
    this.customerName = 'Walk-in Customer',
    this.customerPhone = '',
    required this.items,
    required this.subtotal,
    this.discount = 0.0,
    required this.total,
    required this.payment,
    required this.createdAt,
    this.status = 'completed',
  });

  Map<String, dynamic> toMap() => {
        'invoiceId': invoiceId,
        'shopId': shopId,
        'staffId': staffId,
        'staffName': staffName,
        'attendanceDocId': attendanceDocId,
        'date': date,
        'customerName': customerName,
        'customerPhone': customerPhone,
        'items': items,
        'subtotal': subtotal,
        'discount': discount,
        'total': total,
        'payment': payment.toMap(),
        'cash': payment.cashAmount,
        'upi': payment.upiAmount,
        'card': payment.cardAmount,
        'createdAt': FieldValue.serverTimestamp(),
        'status': status,
      };
}
