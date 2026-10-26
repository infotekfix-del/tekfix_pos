import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../main.dart' show Db;
import '../utils/tek_helpers.dart';
import 'pos_models.dart';

class PosService {
  PosService._();
  static final PosService instance = PosService._();

  final _uuid = const Uuid();

  // Rate-limiting for Owner PIN entry
  int _failedPinAttempts = 0;
  DateTime? _pinLockoutUntil;

  int get failedPinAttempts => _failedPinAttempts;
  bool get isPinLocked {
    if (_pinLockoutUntil == null) return false;
    if (DateTime.now().isAfter(_pinLockoutUntil!)) {
      _pinLockoutUntil = null;
      _failedPinAttempts = 0;
      return false;
    }
    return true;
  }

  int get pinLockoutSecondsRemaining {
    if (!isPinLocked) return 0;
    return _pinLockoutUntil!.difference(DateTime.now()).inSeconds;
  }

  /// Verifies Owner PIN for price floor overrides with 3-attempt lockout.
  Future<({bool success, String? approvalId, String? error})> verifyOwnerPinAndApprove({
    required String shopId,
    required String enteredPin,
    required PosItem item,
    required double requestedPrice,
    required String staffId,
    required String staffName,
  }) async {
    if (isPinLocked) {
      return (
        success: false,
        approvalId: null,
        error: '3 തവണ തെറ്റായ പിൻ നൽകി. കുറച്ചു സമയം കഴിഞ്ഞ് ശ്രമിക്കുക (PIN Locked).'
      );
    }

    final realPin = Db.setting('admin_pass', '1234');
    if (enteredPin.trim() != realPin.trim()) {
      _failedPinAttempts++;
      if (_failedPinAttempts >= 3) {
        _pinLockoutUntil = DateTime.now().add(const Duration(minutes: 15));
        return (
          success: false,
          approvalId: null,
          error: '3 തവണ തെറ്റായ പിൻ നൽകി. 15 മിനിറ്റ് കാത്തിരിക്കുക (PIN Locked for 15 mins).'
        );
      }
      final left = 3 - _failedPinAttempts;
      return (
        success: false,
        approvalId: null,
        error: 'തെറ്റായ പിൻ ($left അവസരങ്ങൾ ബാക്കി)'
      );
    }

    // PIN is correct! Reset attempts and log approval
    _failedPinAttempts = 0;
    _pinLockoutUntil = null;
    final approvalId = _uuid.v4();

    try {
      await FirebaseFirestore.instance
          .collection('shops')
          .doc(shopId)
          .collection('priceApprovals')
          .doc(approvalId)
          .set({
        'approvalId': approvalId,
        'itemId': item.id,
        'itemName': item.name,
        'mrp': item.sellingPrice,
        'floorPrice': item.minPrice,
        'approvedPrice': requestedPrice,
        'staffId': staffId,
        'staffName': staffName,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Price approval audit log write failed: $e');
    }

    return (success: true, approvalId: approvalId, error: null);
  }

  /// Generates offline-safe invoice ID: ShopCode-StaffID-Sequence (e.g. TF-SHAHAL-1001)
  Future<String> generateStaffInvoiceId(String shopId, String staffName) async {
    final prefix = Db.setting('invoice_prefix', 'INV');
    final cleanStaff = staffName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    final staffTag = cleanStaff.length > 5 ? cleanStaff.substring(0, 5) : cleanStaff;

    final seqKey = 'seq_pos_${staffTag.toLowerCase()}';
    int seq = (Db.settings.get(seqKey) as int?) ?? 1000;
    seq++;
    await Db.settings.put(seqKey, seq);

    return '$prefix-$staffTag-$seq';
  }

  /// Loads products from Hive / Firestore (Cost price is NEVER exposed).
  List<PosItem> getCatalogItems() {
    final List<PosItem> list = [];
    for (final k in Db.items.keys) {
      final m = tekM(Db.items.get(k));
      final id = '${m['_id'] ?? k}';
      list.add(PosItem.fromMap(id, m));
    }
    return list;
  }

  /// Completes sale atomically via Firestore batch & Hive local storage
  Future<PosInvoice> completeSale({
    required String shopId,
    required String staffId,
    required String staffName,
    required List<PosCartItem> cartItems,
    required PosPayment payment,
    required double subtotal,
    required double discount,
    required double total,
    String customerName = 'Walk-in Customer',
    String customerPhone = '',
  }) async {
    final now = DateTime.now();
    final invoiceId = await generateStaffInvoiceId(shopId, staffName);

    final lineMaps = cartItems.map((c) => {
      'itemId': c.item.id,
      'name': c.item.name,
      'sku': c.item.sku,
      'qty': c.qty,
      'mrp': c.item.sellingPrice,
      'unitPrice': c.unitPrice,
      'lineTotal': c.lineTotal,
      'approvalId': c.approvalId,
    }).toList();

    final todayStr =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final attendanceDocId = '${staffId}_$todayStr';

    final invoice = PosInvoice(
      invoiceId: invoiceId,
      shopId: shopId,
      staffId: staffId,
      staffName: staffName,
      attendanceDocId: attendanceDocId,
      date: todayStr,
      customerName: customerName.trim().isEmpty ? 'Walk-in Customer' : customerName.trim(),
      customerPhone: customerPhone.trim(),
      items: lineMaps,
      subtotal: subtotal,
      discount: discount,
      total: total,
      payment: payment,
      createdAt: now,
      status: 'completed',
    );

    // 1. Update Hive local storage immediately
    for (final line in cartItems) {
      // Find item key in Db.items
      for (final k in Db.items.keys) {
        final cur = tekM(Db.items.get(k));
        if (cur['_id'] == line.item.id || '$k' == line.item.id || cur['name'] == line.item.name) {
          final curStock = (cur['stock'] as num?)?.toInt() ?? 0;
          cur['stock'] = curStock - line.qty;
          await Db.items.put(k, cur);
          await Db.stockMove(k, line.item.name, -line.qty, 'POS Sale $invoiceId');
          break;
        }
      }
    }

    final billData = <String, dynamic>{
      'invoice': invoiceId,
      'createdAt': now.toIso8601String(),
      'customerName': invoice.customerName,
      'customerPhone': invoice.customerPhone,
      'items': lineMaps,
      'subtotal': subtotal,
      'discount': discount,
      'total': total,
      'cash': payment.cashAmount,
      'upi': payment.upiAmount,
      'card': payment.cardAmount,
      'due': 0.0,
      'status': 'SOLD',
      'staffId': staffId,
      'staffName': staffName,
    };

    await Db.sales.add(billData);

    if (payment.cashAmount > 0) {
      await Db.moveMoney('Cash', payment.cashAmount, 'Sale $invoiceId');
    }
    if (payment.upiAmount > 0) {
      await Db.moveMoney('UPI', payment.upiAmount, 'Sale $invoiceId');
    }

    // 2. Synchronize to Firestore atomically
    try {
      final batch = FirebaseFirestore.instance.batch();

      // Write invoice
      final invRef = FirebaseFirestore.instance
          .collection('shops')
          .doc(shopId)
          .collection('sales')
          .doc(invoiceId);
      batch.set(invRef, invoice.toMap());

      // Deduct inventory stock
      for (final line in cartItems) {
        final itemRef = FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('items')
            .doc(line.item.id);
        batch.update(itemRef, {
          'stock': FieldValue.increment(-line.qty),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        // Stock movement record
        final moveRef = FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('stockMovements')
            .doc();
        batch.set(moveRef, {
          'itemId': line.item.id,
          'itemName': line.item.name,
          'qtyChange': -line.qty,
          'reason': 'POS Sale $invoiceId',
          'staffId': staffId,
          'timestamp': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();
    } catch (e) {
      debugPrint('Firestore atomic sale batch failed (will sync later): $e');
    }

    return invoice;
  }

  /// Formats UPI Pay URI
  String generateUpiPaymentUri({
    required double amount,
    String? upiId,
    String? shopName,
    required String invoiceId,
  }) {
    final upi = upiId ?? Db.setting('shop_upi', '7034093101@okbizaxis');
    final name = shopName ?? Db.setting('shop_name', 'TEKFIX MOBILE HUB');
    final am = amount.toStringAsFixed(2);
    final encodedName = Uri.encodeComponent(name);
    return 'upi://pay?pa=$upi&pn=$encodedName&am=$am&cu=INR&tn=Invoice%20$invoiceId';
  }

  /// Generates formatted receipt text and opens WhatsApp
  Future<void> shareReceiptWhatsApp({
    required PosInvoice invoice,
    required String shopName,
    required String shopPhone,
  }) async {
    final df = DateFormat('dd-MM-yyyy hh:mm a');
    final buf = StringBuffer();
    buf.writeln('===========================');
    buf.writeln('*$shopName*');
    buf.writeln('Phone: $shopPhone');
    buf.writeln('===========================');
    buf.writeln('Invoice: *#${invoice.invoiceId}*');
    buf.writeln('Date: ${df.format(invoice.createdAt)}');
    buf.writeln('Staff: ${invoice.staffName}');
    buf.writeln('Customer: ${invoice.customerName}');
    buf.writeln('---------------------------');
    for (final it in invoice.items) {
      final name = it['name'];
      final qty = it['qty'];
      final price = (it['unitPrice'] as num).toStringAsFixed(2);
      final line = (it['lineTotal'] as num).toStringAsFixed(2);
      buf.writeln('$name x $qty @ ₹$price = ₹$line');
    }
    buf.writeln('---------------------------');
    buf.writeln('Subtotal: ₹${invoice.subtotal.toStringAsFixed(2)}');
    if (invoice.discount > 0) {
      buf.writeln('Discount: -₹${invoice.discount.toStringAsFixed(2)}');
    }
    buf.writeln('*Total: ₹${invoice.total.toStringAsFixed(2)}*');
    buf.writeln('Payment: ${invoice.payment.mode}');
    buf.writeln('===========================');
    buf.writeln('Thank you for choosing $shopName!');

    final text = Uri.encodeComponent(buf.toString());
    final phone = invoice.customerPhone.replaceAll(RegExp(r'[^0-9]'), '');
    final url = phone.isNotEmpty
        ? 'https://wa.me/91$phone?text=$text'
        : 'https://api.whatsapp.com/send?text=$text';

    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
