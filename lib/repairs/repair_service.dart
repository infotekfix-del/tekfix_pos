import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../main.dart' show Db;
import '../utils/tek_helpers.dart';
import 'repair_models.dart';

class RepairService {
  RepairService._();
  static final RepairService instance = RepairService._();

  /// Real-time stream of all repairs for a shop, combining Firestore and local Hive cache
  Stream<List<RepairJob>> streamRepairs(String shopId) {
    if (shopId.isEmpty) {
      return Stream.value(_getLocalRepairs());
    }

    // Stream from Firestore collection `shops/{shopId}/services`
    return FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('services')
        .snapshots()
        .map((snapshot) {
      if (snapshot.docs.isEmpty) {
        // Fallback to local Hive if Firestore collection is empty or initial offline
        return _getLocalRepairs();
      }

      final list = <RepairJob>[];
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final job = RepairJob.fromMap(doc.id, data);
        list.add(job);
      }

      // Single-pass background cache update to Hive for offline resilience (O(N) instead of O(N^2))
      _syncAllToLocalCache(list);

      // Sort newest first
      list.sort((a, b) {
        final dtA = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final dtB = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return dtB.compareTo(dtA);
      });

      return list;
    }).handleError((e) {
      debugPrint('Firestore streamRepairs error: $e. Falling back to local cache.');
      return _getLocalRepairs();
    });
  }

  /// Synchronously get cached repairs from Hive
  List<RepairJob> _getLocalRepairs() {
    try {
      final list = <RepairJob>[];
      for (final key in Db.services.keys) {
        final val = Db.services.get(key);
        if (val != null) {
          final m = tekM(val);
          list.add(RepairJob.fromMap(key, m));
        }
      }
      list.sort((a, b) {
        final dtA = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final dtB = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return dtB.compareTo(dtA);
      });
      return list;
    } catch (e) {
      debugPrint('Error getting local repairs: $e');
      return [];
    }
  }

  void _syncAllToLocalCache(List<RepairJob> jobs) {
    try {
      // Build index map once in O(N)
      final keyMap = <String, dynamic>{};
      for (final key in Db.services.keys) {
        final val = Db.services.get(key);
        if (val != null) {
          final m = tekM(val);
          final id = '${m['jobId'] ?? m['_id']}';
          if (id.isNotEmpty) keyMap[id] = key;
        }
      }
      for (final job in jobs) {
        final existingKey = keyMap[job.id];
        if (existingKey != null) {
          Db.services.put(existingKey, job.toMap());
        } else {
          Db.services.add(job.toMap());
        }
      }
    } catch (_) {}
  }

  /// Staff action to update repair status and internal technician notes
  /// Strictly syncs with both Firestore server and local Hive database
  Future<void> updateRepairStatusAndNotes({
    required String shopId,
    required String jobId,
    dynamic hiveKey,
    required String newStatus,
    required String notes,
    required String staffName,
    required String staffId,
  }) async {
    final now = DateTime.now();
    final nowIso = now.toIso8601String();

    // 1. Fetch current job state from Hive or Firestore
    Map<String, dynamic> currentData = {};
    dynamic keyToUpdate = hiveKey;

    if (keyToUpdate != null) {
      final v = Db.services.get(keyToUpdate);
      if (v != null) currentData = tekM(v);
    } else {
      for (final k in Db.services.keys) {
        final v = Db.services.get(k);
        if (v != null) {
          final m = tekM(v);
          if ('${m['jobId']}' == jobId || '${m['_id']}' == jobId) {
            currentData = m;
            keyToUpdate = k;
            break;
          }
        }
      }
    }

    final oldStatus = '${currentData['status'] ?? 'Received'}';
    final history = ((currentData['statusHistory'] as List?) ?? []).toList();

    // Append new status history entry if status changed or notes added
    history.add({
      'date': nowIso,
      'status': newStatus,
      'user': staffName.isNotEmpty ? staffName : 'Staff ($staffId)',
      'notes': notes.trim(),
    });

    final updatedPayload = <String, dynamic>{
      ...currentData,
      'jobId': jobId,
      'status': newStatus,
      'notes': notes.trim(),
      'updatedAt': nowIso,
      'statusHistory': history,
    };

    // 2. Persist locally to Hive first (instant UI update)
    if (keyToUpdate != null) {
      await Db.services.put(keyToUpdate, updatedPayload);
    } else {
      await Db.services.add(updatedPayload);
    }

    // 3. Persist directly to Firestore collection `shops/{shopId}/services`
    if (shopId.isNotEmpty) {
      try {
        final docRef = FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('services')
            .doc(jobId);

        await docRef.set(updatedPayload, SetOptions(merge: true));

        // 4. Also broadcast a notification in `shops/{shopId}/notifications` for Owner and team
        final notifRef = FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('notifications')
            .doc();

        final notifPayload = {
          'id': notifRef.id,
          'shopId': shopId,
          'type': 'repair_update',
          'title': 'Repair #$jobId: $newStatus',
          'message': '$staffName updated #$jobId (${currentData['brandModel'] ?? 'Device'}) status to "$newStatus". Notes: ${notes.isEmpty ? 'None' : notes}',
          'priority': (newStatus == 'Ready' || newStatus == 'Waiting for Parts') ? 'urgent' : 'normal',
          'sender': staffName.isNotEmpty ? staffName : 'Staff',
          'staffId': staffId,
          'jobId': jobId,
          'status': newStatus,
          'createdAt': FieldValue.serverTimestamp(),
          'readBy': [staffId],
        };

        await notifRef.set(notifPayload);

        // 5. Append to activity_logs for audit trail
        final logRef = FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('activity_logs')
            .doc();

        await logRef.set({
          'action': 'Service Status & Notes Updated',
          'entity': 'Service Job',
          'entityId': jobId,
          'staffId': staffId,
          'staffName': staffName,
          'oldStatus': oldStatus,
          'newStatus': newStatus,
          'notes': notes.trim(),
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('Firestore repair sync error: $e. SyncEngine will push on reconnect.');
      }
    }
  }
}
