import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../staff/activity_log.dart';
import 'order_models.dart';

class OrderService {
  OrderService._();
  static final OrderService instance = OrderService._();

  final _db = FirebaseFirestore.instance;

  /// Generates a non-duplicable sequential order ID in format: TF-YYYYMMDD-0001
  Future<String> generateOrderId(String shopId) async {
    final dateStr = DateFormat('yyyyMMdd').format(DateTime.now());
    final counterRef = _db
        .collection('shops')
        .doc(shopId)
        .collection('counters')
        .doc('orders_$dateStr');

    try {
      final sequence = await _db.runTransaction((tx) async {
        final snap = await tx.get(counterRef);
        final current = (snap.data()?['seq'] as num?)?.toInt() ?? 0;
        final next = current + 1;
        tx.set(counterRef, {'seq': next}, SetOptions(merge: true));
        return next;
      });

      final seqFormatted = sequence.toString().padLeft(4, '0');
      return 'TF-$dateStr-$seqFormatted';
    } catch (e) {
      // High-entropy timestamp fallback
      final timeSuffix = (DateTime.now().millisecondsSinceEpoch % 10000).toString().padLeft(4, '0');
      return 'TF-$dateStr-$timeSuffix';
    }
  }

  /// Saves order to Cloud Firestore and logs staff activity
  Future<StaffOrder> submitOrder({
    required String shopId,
    required StaffOrder order,
  }) async {
    final orderRef = _db
        .collection('shops')
        .doc(shopId)
        .collection('orders')
        .doc(order.orderId);

    await orderRef.set(order.toMap(useServerTimestamp: true));

    // Log action to unified activity logs
    try {
      await ActivityLog.record(
        action: 'Created Staff Order',
        entity: 'Staff Order',
        entityId: order.orderId,
        newValue: {
          'orderId': order.orderId,
          'totalTypes': order.totalTypes,
          'totalQuantity': order.totalQuantity,
          'items': order.products.map((p) => '${p.name} (${p.quantity})').toList(),
        },
        reason: order.generalRemarks,
      );
    } catch (_) {}

    return order;
  }

  /// Real-time stream of orders submitted by a specific staff member
  Stream<List<StaffOrder>> streamStaffOrders(String shopId, String staffId) {
    if (shopId.isEmpty) return const Stream.empty();
    return _db
        .collection('shops')
        .doc(shopId)
        .collection('orders')
        .where('staffId', isEqualTo: staffId)
        .snapshots()
        .map((snap) {
      final list =
          snap.docs.map((d) => StaffOrder.fromMap(d.id, d.data())).toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  /// Real-time stream of all staff orders across the company for Owner panel
  Stream<List<StaffOrder>> streamAllOrders(String shopId) {
    if (shopId.isEmpty) return const Stream.empty();
    return _db
        .collection('shops')
        .doc(shopId)
        .collection('orders')
        .snapshots()
        .map((snap) {
      final list =
          snap.docs.map((d) => StaffOrder.fromMap(d.id, d.data())).toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  /// Owner: Update order status
  Future<void> updateOrderStatus({
    required String shopId,
    required String orderId,
    required StaffOrderStatus newStatus,
    required String ownerName,
  }) async {
    final orderRef = _db
        .collection('shops')
        .doc(shopId)
        .collection('orders')
        .doc(orderId);

    await orderRef.update({
      'status': newStatus.name,
      'updatedBy': ownerName,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    try {
      await ActivityLog.record(
        action: 'Updated Order Status',
        entity: 'Staff Order',
        entityId: orderId,
        newValue: {'status': newStatus.name, 'updatedBy': ownerName},
        reason: 'Status changed to ${newStatus.label}',
      );
    } catch (_) {}
  }

  /// Update WhatsApp delivery status
  Future<void> updateWhatsAppStatus({
    required String shopId,
    required String orderId,
    required WhatsAppDeliveryStatus status,
    String? messageId,
  }) async {
    final orderRef = _db
        .collection('shops')
        .doc(shopId)
        .collection('orders')
        .doc(orderId);

    final updates = <String, dynamic>{
      'whatsappDeliveryStatus': status.name,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (messageId != null) updates['whatsappMessageId'] = messageId;

    await orderRef.update(updates);
  }

  /// Formats the order text according to Section 13 specification
  String formatWhatsAppMessage(StaffOrder order) {
    const divider = '━━━━━━━━━━━━━━━━━━';
    final sb = StringBuffer();

    sb.writeln('📦 NEW PRODUCT ORDER\n');
    sb.writeln('🏢 Company: Tekfix Digital\n');
    sb.writeln('$divider\n');

    sb.writeln('📋 ORDER INFORMATION\n');
    sb.writeln('🆔 Order ID: ${order.orderId}');
    sb.writeln('📅 Date: ${order.createdDate}');
    sb.writeln('🕒 Time: ${order.createdTime}');
    sb.writeln('👤 Ordered By: ${order.staffName}\n');
    sb.writeln('$divider\n');

    sb.writeln('🛒 PRODUCT DETAILS\n');
    for (var i = 0; i < order.products.length; i++) {
      final p = order.products[i];
      sb.writeln('${i + 1}. ${p.name}');
      sb.writeln('   Quantity: ${p.quantity} ${p.unit}');
      if (p.model.trim().isNotEmpty) {
        sb.writeln('   Model: ${p.model.trim()}');
      } else if (p.variant.trim().isNotEmpty) {
        sb.writeln('   Variant: ${p.variant.trim()}');
      }
      if (p.remarks.trim().isNotEmpty) {
        sb.writeln('   Remarks: ${p.remarks.trim()}');
      }
      sb.writeln('');
    }

    sb.writeln('$divider\n');
    sb.writeln('📊 ORDER SUMMARY\n');
    sb.writeln('Total Product Types: ${order.totalTypes}');
    final unitLabel = order.products.isNotEmpty ? order.products.first.unit : 'Pcs';
    sb.writeln('Total Quantity: ${order.totalQuantity} $unitLabel\n');

    if (order.generalRemarks.trim().isNotEmpty) {
      sb.writeln('📝 General Remarks:');
      sb.writeln('${order.generalRemarks.trim()}\n');
      sb.writeln('$divider\n');
    }

    sb.write('Submitted through Tekfix Orders App.');
    return sb.toString();
  }

  /// Copies order message to system clipboard
  Future<void> copyOrderToClipboard(String message) async {
    await Clipboard.setData(ClipboardData(text: message));
  }

  /// Launches the company WhatsApp group link
  Future<bool> openWhatsAppGroup(String groupUrl) async {
    final uri = Uri.parse(groupUrl);
    if (await canLaunchUrl(uri)) {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return false;
  }

  /// Reads WhatsApp configuration from settings
  Future<WhatsAppGroupConfig> getWhatsAppConfig(String shopId) async {
    try {
      final snap = await _db
          .collection('shops')
          .doc(shopId)
          .collection('settings')
          .doc('whatsapp')
          .get();
      if (snap.exists && snap.data() != null) {
        return WhatsAppGroupConfig.fromMap(snap.data()!);
      }
    } catch (_) {}
    return const WhatsAppGroupConfig();
  }

  /// Saves WhatsApp configuration
  Future<void> saveWhatsAppConfig(String shopId, WhatsAppGroupConfig config) async {
    await _db
        .collection('shops')
        .doc(shopId)
        .collection('settings')
        .doc('whatsapp')
        .set(config.toMap(), SetOptions(merge: true));
  }

  /// Exports orders to clean RFC-4180 CSV string
  String exportOrdersToCsv(List<StaffOrder> orders) {
    final sb = StringBuffer();
    sb.writeln('Order ID,Date,Time,Staff Name,Total Types,Total Quantity,Status,WhatsApp Status,Products Summary,General Remarks');

    for (final o in orders) {
      final productsSummary = o.products
          .map((p) => '${p.name} (${p.quantity} ${p.unit})')
          .join(' | ')
          .replaceAll('"', '""');
      final remarks = o.generalRemarks.replaceAll('"', '""');

      sb.writeln(
        '"${o.orderId}","${o.createdDate}","${o.createdTime}","${o.staffName}",${o.totalTypes},${o.totalQuantity},"${o.status.label}","${o.whatsappDeliveryStatus.label}","$productsSummary","$remarks"',
      );
    }

    return sb.toString();
  }
}
