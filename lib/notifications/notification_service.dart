import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../main.dart' show Db;
import 'notification_models.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _readController = StreamController<void>.broadcast();

  List<String> _getReadIds(String staffId) {
    try {
      final list = Db.settings.get('read_notifications_$staffId');
      if (list is List) return list.map((e) => '$e').toList();
    } catch (_) {}
    return [];
  }

  Future<void> _saveReadIds(String staffId, List<String> ids) async {
    try {
      await Db.settings.put('read_notifications_$staffId', ids);
      _readController.add(null);
    } catch (_) {}
  }

  /// Mark single notification as read
  Future<void> markAsRead(String staffId, String notificationId) async {
    final ids = _getReadIds(staffId);
    if (!ids.contains(notificationId)) {
      ids.add(notificationId);
      await _saveReadIds(staffId, ids);
    }
  }

  /// Mark all notifications as read
  Future<void> markAllAsRead(String staffId, List<String> notificationIds) async {
    final ids = _getReadIds(staffId);
    final set = ids.toSet()..addAll(notificationIds);
    await _saveReadIds(staffId, set.toList());
  }

  /// Real-time stream of notifications for staff
  Stream<List<TekNotification>> streamNotifications(String shopId, String staffId) {
    if (shopId.isEmpty) {
      return Stream.value(_getDefaultAnnouncements(shopId, staffId));
    }

    return FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('notifications')
        .snapshots()
        .map((snapshot) {
      final readIds = _getReadIds(staffId);

      if (snapshot.docs.isEmpty) {
        // Return default system/owner announcements if collection is new
        return _getDefaultAnnouncements(shopId, staffId);
      }

      final list = snapshot.docs.map((doc) {
        final data = doc.data();
        final isRead = readIds.contains(doc.id) ||
            ((data['readBy'] as List?)?.contains(staffId) ?? false);
        return TekNotification.fromMap(doc.id, data, isRead: isRead);
      }).toList();

      // Sort newest first
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    }).handleError((e) {
      debugPrint('Error streaming notifications: $e. Returning default list.');
      return _getDefaultAnnouncements(shopId, staffId);
    });
  }

  /// Real-time stream of unread count
  Stream<int> streamUnreadCount(String shopId, String staffId) {
    return streamNotifications(shopId, staffId).map((list) {
      return list.where((n) => !n.isRead).length;
    });
  }

  /// Seed initial owner announcement & system alerts if collection is newly created
  List<TekNotification> _getDefaultAnnouncements(String shopId, String staffId) {
    final readIds = _getReadIds(staffId);
    final now = DateTime.now();

    final defaults = [
      TekNotification(
        id: 'announcement_phase4',
        shopId: shopId,
        type: NotificationType.announcement,
        title: 'ഷോപ്പ് ഉടമയുടെ അറിയിപ്പ് (Owner Announcement)',
        message: 'സ്റ്റാഫ് പോർട്ടൽ v1.0.2 അപ്‌ഡേറ്റ് ചെയ്തു. എല്ലാ സർവീസ് ജോലികളുടെയും സ്റ്റാറ്റസ് യഥാസമയം അപ്ഡേറ്റ് ചെയ്യുക. കസ്റ്റമർക്ക് വാട്സാപ്പ് സന്ദേശങ്ങൾ അയക്കുക.',
        priority: NotificationPriority.urgent,
        sender: 'Owner (ഷോപ്പ് ഉടമ)',
        createdAt: now.subtract(const Duration(hours: 1)),
        isRead: readIds.contains('announcement_phase4'),
      ),
      TekNotification(
        id: 'system_attendance_policy',
        shopId: shopId,
        type: NotificationType.systemAlert,
        title: 'ഡ്യൂട്ടി & ക്യാഷ് രജിസ്റ്റർ ഓർമ്മപ്പെടുത്തൽ',
        message: 'ഷിഫ്റ്റ് പൂർത്തിയാക്കുമ്പോൾ ഡ്രോയറിലെ ക്യാഷ് എണ്ണി തിട്ടപ്പെടുത്തി മാത്രമേ ചെക്ക്-ഔട്ട് ചെയ്യാൻ പാടുള്ളൂ.',
        priority: NotificationPriority.normal,
        sender: 'TEKFIX Core System',
        createdAt: now.subtract(const Duration(hours: 4)),
        isRead: readIds.contains('system_attendance_policy'),
      ),
      TekNotification(
        id: 'repair_intake_alert',
        shopId: shopId,
        type: NotificationType.repairUpdate,
        title: 'പുതിയ സർവീസ് ജോലികൾ പരിശോധിക്കുക',
        message: 'പുതിയ സർവീസ് ടിക്കറ്റുകൾ "Repairs" ടാബിൽ ലഭ്യമാണ്. സ്പെയർ പാർട്സ് ആവശ്യമെങ്കിൽ "Orders" വഴി ഓർഡർ ചെയ്യുക.',
        priority: NotificationPriority.info,
        sender: 'Service Desk',
        createdAt: now.subtract(const Duration(days: 1)),
        isRead: readIds.contains('repair_intake_alert'),
      ),
    ];

    return defaults;
  }

  /// Owner or System action to broadcast an announcement to all staff members
  Future<void> sendAnnouncement({
    required String shopId,
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.normal,
    String sender = 'Owner',
    String? staffId,
  }) async {
    if (shopId.isEmpty) return;
    final ref = FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('notifications')
        .doc();

    await ref.set({
      'id': ref.id,
      'shopId': shopId,
      'type': 'announcement',
      'title': title,
      'message': message,
      'priority': priority.name,
      'sender': sender,
      'staffId': staffId,
      'createdAt': FieldValue.serverTimestamp(),
      'readBy': [],
    });
  }
}
