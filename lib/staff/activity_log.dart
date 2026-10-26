import 'dart:convert';
import 'package:flutter/material.dart';
import '../auth/auth_controller.dart';
import '../core/device.dart';
import '../main.dart' show Db;

/// Normalised action categories shown on the owner dashboard.
class ActivityType {
  static const createdBill = 'Created Bill';
  static const editedStock = 'Edited Stock';
  static const deletedEntry = 'Deleted Entry';
  static const collectedPayment = 'Collected Payment';
  static const voidedBill = 'Voided Bill';
  static const paidOut = 'Paid Out';
  static const other = 'Other';

  static Color color(String t) {
    switch (t) {
      case createdBill: return const Color(0xFF166534);
      case editedStock: return const Color(0xFF1D4ED8);
      case deletedEntry: return const Color(0xFFB91C1C);
      case voidedBill: return const Color(0xFF9A3412);
      case collectedPayment: return const Color(0xFF0F766E);
      case paidOut: return const Color(0xFF6D28D9);
      default: return const Color(0xFF374151);
    }
  }

  static IconData icon(String t) {
    switch (t) {
      case createdBill: return Icons.receipt_long_rounded;
      case editedStock: return Icons.inventory_2_rounded;
      case deletedEntry: return Icons.delete_forever_rounded;
      case voidedBill: return Icons.report_gmailerrorred_rounded;
      case collectedPayment: return Icons.payments_rounded;
      case paidOut: return Icons.north_east_rounded;
      default: return Icons.history_rounded;
    }
  }
}

class ActivityLog {
  /// Add `...ActivityLog.stamp()` to every sale / service bill map so the
  /// dashboard can attribute sales to a staff member and a counter.
  static Map<String, dynamic> stamp() {
    final a = AuthController.instance;
    return {
      'staffId': a.uid,
      'staffName': a.name.isNotEmpty ? a.name : Db.setting('active_user', 'Admin'),
      'device': DeviceInfo.platform,
      'counter': DeviceInfo.counterName,
    };
  }

  static String typeOf(String action) {
    final l = action.toLowerCase();
    if (l.contains('return') || l.contains('cancel') || l.contains('void')) return ActivityType.voidedBill;
    if (l.contains('deleted')) return ActivityType.deletedEntry;
    if (l == 'sale created' || l == 'service billed') return ActivityType.createdBill;
    if (l == 'customer payment') return ActivityType.collectedPayment;
    if (l == 'supplier payment' || l == 'salary paid') return ActivityType.paidOut;
    if (l.contains('stock') || l.startsWith('product')) return ActivityType.editedStock;
    return ActivityType.other;
  }

  static String _clip(dynamic v, [int max = 1500]) {
    if (v == null) return '';
    String s;
    try { s = jsonEncode(v); } catch (_) { s = '$v'; }
    return s.length <= max ? s : '${s.substring(0, max)}…';
  }

  static double? _amount(dynamic v) {
    if (v is Map) {
      for (final k in const ['total', 'amount']) {
        final x = v[k];
        if (x is num) return x.toDouble();
      }
    }
    return null;
  }

  /// Replaces the body of Db.logAction.  Row keeps the legacy keys
  /// (date,user,action,entity,entityId,oldValue,newValue,reason) so the
  /// existing Audit screen still works, and adds the new audit-trail fields.
  static Future<void> record({
    required String action,
    required String entity,
    String entityId = '',
    dynamic oldValue,
    dynamic newValue,
    String reason = '',
    String user = '',
  }) async {
    final s = stamp();
    final type = typeOf(action);
    final amount = _amount(newValue) ?? _amount(oldValue);
    final who = user.isNotEmpty ? user : '${s['staffName']}';
    final row = <String, dynamic>{
      'date': DateTime.now().toIso8601String(),
      'user': who,
      'action': action,
      'entity': entity,
      'entityId': entityId,
      'oldValue': _clip(oldValue),
      'newValue': _clip(newValue),
      'reason': reason,
      // --- new audit-trail fields ---
      'staffId': s['staffId'],
      'staffName': who,
      'role': AuthController.instance.roleLabel,
      'actionType': type,
      'device': s['device'],
      'deviceId': DeviceInfo.id,
      'counter': s['counter'],
      'details': '$action • $entity${entityId.isEmpty ? '' : ' $entityId'}${reason.isEmpty ? '' : ' • $reason'}',
      'warn': type == ActivityType.voidedBill || type == ActivityType.deletedEntry,
      if (amount != null) 'amount': amount,
    };
    await Db.audit.add(row);
  }
}
