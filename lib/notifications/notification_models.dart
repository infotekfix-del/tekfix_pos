import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

enum NotificationType {
  announcement,
  repairUpdate,
  systemAlert,
  attendance,
}

enum NotificationPriority {
  urgent,
  normal,
  info,
}

class TekNotification {
  final String id;
  final String shopId;
  final NotificationType type;
  final String title;
  final String message;
  final NotificationPriority priority;
  final String sender;
  final DateTime createdAt;
  final bool isRead;
  final Map<String, dynamic> metadata;

  const TekNotification({
    required this.id,
    required this.shopId,
    required this.type,
    required this.title,
    required this.message,
    this.priority = NotificationPriority.normal,
    this.sender = 'System',
    required this.createdAt,
    this.isRead = false,
    this.metadata = const {},
  });

  bool get isUrgent => priority == NotificationPriority.urgent;

  String get timeFormatted {
    final now = DateTime.now();
    final diff = now.difference(createdAt);

    if (diff.inSeconds < 60) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else if (diff.inDays == 1) {
      return 'Yesterday, ${DateFormat('hh:mm a').format(createdAt)}';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return DateFormat('dd MMM yyyy, hh:mm a').format(createdAt);
    }
  }

  factory TekNotification.fromMap(String docId, Map<String, dynamic> map, {bool isRead = false}) {
    DateTime parseDt(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is DateTime) return val;
      if (val != null) {
        try {
          return DateTime.parse(val.toString());
        } catch (_) {}
      }
      return DateTime.now();
    }

    NotificationType parseType(dynamic val) {
      final str = '$val'.toLowerCase();
      if (str.contains('repair') || str.contains('service')) {
        return NotificationType.repairUpdate;
      } else if (str.contains('announcement') || str.contains('owner') || str.contains('broadcast')) {
        return NotificationType.announcement;
      } else if (str.contains('attendance')) {
        return NotificationType.attendance;
      }
      return NotificationType.systemAlert;
    }

    NotificationPriority parsePriority(dynamic val) {
      final str = '$val'.toLowerCase();
      if (str == 'urgent' || str == 'high') return NotificationPriority.urgent;
      if (str == 'info' || str == 'low') return NotificationPriority.info;
      return NotificationPriority.normal;
    }

    return TekNotification(
      id: docId,
      shopId: '${map['shopId'] ?? ''}',
      type: parseType(map['type']),
      title: '${map['title'] ?? 'Notification'}',
      message: '${map['message'] ?? ''}',
      priority: parsePriority(map['priority']),
      sender: '${map['sender'] ?? 'System'}',
      createdAt: parseDt(map['createdAt']),
      isRead: isRead,
      metadata: (map['metadata'] as Map?)?.cast<String, dynamic>() ?? {},
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'shopId': shopId,
      'type': type.name,
      'title': title,
      'message': message,
      'priority': priority.name,
      'sender': sender,
      'createdAt': Timestamp.fromDate(createdAt),
      'metadata': metadata,
    };
  }

  TekNotification copyWith({
    String? id,
    String? shopId,
    NotificationType? type,
    String? title,
    String? message,
    NotificationPriority? priority,
    String? sender,
    DateTime? createdAt,
    bool? isRead,
    Map<String, dynamic>? metadata,
  }) {
    return TekNotification(
      id: id ?? this.id,
      shopId: shopId ?? this.shopId,
      type: type ?? this.type,
      title: title ?? this.title,
      message: message ?? this.message,
      priority: priority ?? this.priority,
      sender: sender ?? this.sender,
      createdAt: createdAt ?? this.createdAt,
      isRead: isRead ?? this.isRead,
      metadata: metadata ?? this.metadata,
    );
  }
}
