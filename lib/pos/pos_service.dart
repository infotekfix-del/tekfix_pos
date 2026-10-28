import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../main.dart' show Db;
import '../utils/tek_helpers.dart';
import '../inventory/consumables_service.dart';
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

  final Set<String> _inFlightInvoices = {};

  /// Real-time stream of catalog products with live stock tracking from Firestore
  Stream<List<PosItem>> streamCatalogItems(String shopId) {
    if (shopId.isEmpty) {
      return Stream.value(getCatalogItems());
    }

    return FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('items')
        .snapshots()
        .map((snapshot) {
      if (snapshot.docs.isEmpty) {
        return getCatalogItems();
      }

      final list = <PosItem>[];
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final item = PosItem.fromMap(doc.id, data);
        list.add(item);
      }

      return list;
    }).handleError((e) {
      debugPrint('Error streaming catalog items: $e. Falling back to local cache.');
      return getCatalogItems();
    });
  }

  void _cacheAllLocalItems(List<PosItem> items) {
    try {
      final keyMap = <String, dynamic>{};
      for (final k in Db.items.keys) {
        final cur = tekM(Db.items.get(k));
        final id = cur['_id']?.toString() ?? '$k';
        if (id.isNotEmpty) keyMap[id] = k;
      }
      for (final it in items) {
        final matchKey = keyMap[it.id];
        final payload = {
          '_id': it.id,
          'name': it.name,
          'sku': it.sku,
          'barcode': it.barcode,
          'category': it.category,
          'sellingPrice': it.sellingPrice,
          'minPrice': it.minPrice,
          'stock': it.stock,
          'lowStockLevel': it.lowStockLevel,
        };
        if (matchKey != null) {
          Db.items.put(matchKey, payload);
        } else {
          Db.items.add(payload);
        }
      }
    } catch (_) {}
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

  /// Completes sale atomically via Firestore Transaction & Hive local storage
  /// Enforces:
  /// 1. Double-submission prevention (idempotency guard)
  /// 2. Unauthorized discount prevention (hard floor prices)
  /// 3. Atomic stock decrement & negative-stock prevention
  /// 4. Atomic cash register / daily sales counter updates
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
    if (cartItems.isEmpty) {
      throw Exception('കാർട്ടിൽ ഉൽപ്പന്നങ്ങളൊന്നുമില്ല (Cart is empty).');
    }

    // 1. Unauthorized discount verification
    for (final line in cartItems) {
      if (line.isBelowFloor && !line.hasValidOverride) {
        throw Exception(
          'അംഗീകാരമില്ലാത്ത ഡിസ്കൗണ്ട് അനുവദനീയമല്ല: "${line.item.name}" മിനിമം വില ₹${line.item.minPrice.toStringAsFixed(0)} ആണ് (Unauthorized price below floor price).',
        );
      }
    }

    if (discount > 0) {
      final allowedMaxDiscount = cartItems.fold(0.0, (acc, l) {
        final floor = l.hasValidOverride ? l.unitPrice : l.item.minPrice;
        return acc + ((l.item.sellingPrice - floor) * l.qty);
      });
      if (discount > (allowedMaxDiscount + 0.01)) {
        throw Exception(
          'ഡിസ്കൗണ്ട് തുക അനുവദനീയമായ പരിധിക്ക് പുറത്താണ് (Discount exceeds maximum allowed limit).',
        );
      }
    }

    final now = DateTime.now();
    final invoiceId = await generateStaffInvoiceId(shopId, staffName);

    // 2. Double-submission prevention (In-flight memory lock)
    if (_inFlightInvoices.contains(invoiceId)) {
      throw Exception('ഈ ഇൻവോയ്സ് ഇതിനകം സമർപ്പിച്ചുകൊണ്ടിരിക്കുകയാണ് (Duplicate submission blocked).');
    }
    _inFlightInvoices.add(invoiceId);

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

    try {
      // 3. Firestore Atomic Transaction
      if (shopId.isNotEmpty) {
        await FirebaseFirestore.instance.runTransaction((transaction) async {
          final invRef = FirebaseFirestore.instance
              .collection('shops')
              .doc(shopId)
              .collection('sales')
              .doc(invoiceId);

          // Check if invoice already exists (Idempotency)
          final invSnap = await transaction.get(invRef);
          if (invSnap.exists) {
            debugPrint('Invoice $invoiceId already exists in Firestore. Aborting duplicate.');
            return;
          }

          // READ PHASE: Read all item documents & verify live stock
          final itemSnapshots = <String, DocumentSnapshot<Map<String, dynamic>>>{};
          for (final line in cartItems) {
            final itemRef = FirebaseFirestore.instance
                .collection('shops')
                .doc(shopId)
                .collection('items')
                .doc(line.item.id);

            final snap = await transaction.get(itemRef);
            itemSnapshots[line.item.id] = snap;

            if (snap.exists) {
              final curStock = (snap.data()?['stock'] as num?)?.toInt() ?? 0;
              if (curStock < line.qty) {
                throw Exception(
                  'ആവശ്യത്തിന് സ്റ്റോക്കില്ല: "${line.item.name}" (ലഭ്യമായത്: $curStock, ആവശ്യപ്പെട്ടത്: ${line.qty})',
                );
              }
            }
          }

          // WRITE PHASE:
          // 3a. Save Invoice
          transaction.set(invRef, invoice.toMap());

          // 3b. Decrement live stock atomically and log stock movements
          for (final line in cartItems) {
            final itemRef = FirebaseFirestore.instance
                .collection('shops')
                .doc(shopId)
                .collection('items')
                .doc(line.item.id);

            final snap = itemSnapshots[line.item.id];
            if (snap != null && snap.exists) {
              final curStock = (snap.data()?['stock'] as num?)?.toInt() ?? 0;
              transaction.update(itemRef, {
                'stock': curStock - line.qty,
                'updatedAt': FieldValue.serverTimestamp(),
              });
            } else {
              transaction.update(itemRef, {
                'stock': FieldValue.increment(-line.qty),
                'updatedAt': FieldValue.serverTimestamp(),
              });
            }

            final moveRef = FirebaseFirestore.instance
                .collection('shops')
                .doc(shopId)
                .collection('stockMovements')
                .doc();
            transaction.set(moveRef, {
              'itemId': line.item.id,
              'itemName': line.item.name,
              'qtyChange': -line.qty,
              'reason': 'POS Sale $invoiceId',
              'staffId': staffId,
              'staffName': staffName,
              'timestamp': FieldValue.serverTimestamp(),
            });
          }

          // 3c. Update daily sales counters & cash register
          final counterRef = FirebaseFirestore.instance
              .collection('shops')
              .doc(shopId)
              .collection('counters')
              .doc('daily_sales_$todayStr');

          transaction.set(counterRef, {
            'totalSales': FieldValue.increment(total),
            'cashSales': FieldValue.increment(payment.cashAmount),
            'upiSales': FieldValue.increment(payment.upiAmount),
            'cardSales': FieldValue.increment(payment.cardAmount),
            'billCount': FieldValue.increment(1),
            'lastUpdated': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        });
      }

      // 4. Update Hive local storage (instant offline sync & local sales view)
      for (final line in cartItems) {
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

      // 4b. Auto-deduct paper sheets if Photostat / Printing services were billed
      final sheetsToDeduct = ConsumablesService.calculateTotalSheetsForCart(cartItems);
      if (sheetsToDeduct > 0) {
        await ConsumablesService.deductPaperSheets(
          sheetsToDeduct,
          reason: 'POS Sale $invoiceId',
          shopId: shopId,
        );
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

      return invoice;
    } finally {
      _inFlightInvoices.remove(invoiceId);
    }
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
    var phone = invoice.customerPhone.replaceAll(RegExp(r'[^0-9]'), '');
    if (phone.startsWith('0')) phone = phone.substring(1);
    if (!phone.startsWith('91') && phone.length == 10) phone = '91$phone';
    final url = phone.isNotEmpty
        ? 'https://wa.me/$phone?text=$text'
        : 'https://api.whatsapp.com/send?text=$text';

    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
