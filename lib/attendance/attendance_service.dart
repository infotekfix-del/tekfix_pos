import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:hive/hive.dart';
import '../main.dart' show Db;
import '../utils/tek_helpers.dart';
import '../utils/timestamp_adapter.dart';
import 'attendance_models.dart';

class AttendanceService {
  AttendanceService._();
  static final AttendanceService instance = AttendanceService._();

  final DateFormat _dateKey = DateFormat('yyyy-MM-dd');

  /// Fetches Shift configuration (default: 8:30 AM to 9:30 PM, 6.5h half day, 15m grace)
  ShiftConfig getShiftConfig() {
    try {
      final m = Db.settings.get('shift_config');
      if (m is Map) return ShiftConfig.fromMap(Map<String, dynamic>.from(m));
    } catch (_) {}
    return const ShiftConfig();
  }

  Future<void> saveShiftConfig(String shopId, ShiftConfig config) async {
    await Db.settings.put('shift_config', config.toMap());
    try {
      await FirebaseFirestore.instance
          .collection('shops')
          .doc(shopId)
          .collection('settings')
          .doc('shift')
          .set(config.toMap(), SetOptions(merge: true));
    } catch (e) {
      debugPrint('Sync shift config failed: $e');
    }
  }

  /// Fetches shop location and geofence settings from local Db settings.
  ShopLocationConfig getShopConfig() {
    final lat = double.tryParse(Db.setting('shop_latitude', '0.0')) ?? 0.0;
    final lng = double.tryParse(Db.setting('shop_longitude', '0.0')) ?? 0.0;
    final radius =
        double.tryParse(Db.setting('shop_allowed_radius', '100.0')) ?? 100.0;
    final block = Db.setting('block_outside_checkin', 'false') == 'true';
    return ShopLocationConfig(
      latitude: lat,
      longitude: lng,
      allowedRadiusMeters: radius,
      blockOutsideCheckIn: block,
    );
  }

  Future<void> saveShopConfig(ShopLocationConfig config) async {
    await Db.settings.put('shop_latitude', config.latitude.toString());
    await Db.settings.put('shop_longitude', config.longitude.toString());
    await Db.settings
        .put('shop_allowed_radius', config.allowedRadiusMeters.toString());
    await Db.settings
        .put('block_outside_checkin', config.blockOutsideCheckIn.toString());
  }

  /// Capture location only when called, validate accuracy and mock GPS.
  Future<({Position position, String locationStatus})>
      captureAndValidateLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception(
          'ഫോണിലെ ലൊക്കേഷൻ (GPS) ഓഫ് ആണ്. ദയവായി ഓൺ ചെയ്യുക (GPS is turned off).');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception(
            'ലൊക്കേഷൻ അനുമതി നൽകിയിട്ടില്ല (Location permission is required for attendance).');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception(
          'ലൊക്കേഷൻ അനുമതി പൂർണ്ണമായി ബ്ലോക്ക് ചെയ്തിരിക്കുന്നു. Settings-ൽ പോയി അനുമതി നൽകുക.');
    }

    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );

    if (pos.isMocked) {
      throw Exception(
          'വ്യാജ ലൊക്കേഷൻ (Fake GPS) അനുവദനീയമല്ല. ദയവായി യഥാർത്ഥ ലൊക്കേഷൻ ഉപയോഗിക്കുക.');
    }

    if (pos.accuracy > 100.0) {
      throw Exception(
          'ലൊക്കേഷൻ കൃത്യത കുറവാണ് (${pos.accuracy.toStringAsFixed(0)}m > 100m). ദയവായി തുറന്ന സ്ഥലത്തേക്ക് മാറി വീണ്ടും ശ്രമിക്കുക.');
    }

    final shop = getShopConfig();
    String status = 'Inside shop';
    if (shop.latitude != 0.0 && shop.longitude != 0.0) {
      final distance = Geolocator.distanceBetween(
        shop.latitude,
        shop.longitude,
        pos.latitude,
        pos.longitude,
      );
      if (distance > shop.allowedRadiusMeters) {
        status = 'Outside shop';
        if (shop.blockOutsideCheckIn) {
          throw Exception(
              'നിങ്ങൾ ഷോപ്പിന് പുറത്താണ് (${distance.toStringAsFixed(0)}m അകലെ). ഷോപ്പിൽ എത്തിയ ശേഷം മാത്രം ഹാജർ രേഖപ്പെടുത്തുക.');
        }
      }
    }

    return (position: pos, locationStatus: status);
  }

  /// Computes sales summary made by this staff member since checkIn time today.
  Map<String, dynamic> computeShiftSalesSummary(String staffId, DateTime checkInTime) {
    double cash = 0.0;
    double upi = 0.0;
    double card = 0.0;
    double total = 0.0;
    int bills = 0;

    for (final v in Db.sales.values) {
      final s = tekM(v);
      final sStaff = '${s['staffId'] ?? s['_by'] ?? ''}'.trim();
      final dtStr = s['createdAt'] ?? s['date'];
      final dt = DateTime.tryParse('$dtStr');
      if (dt == null) continue;

      if ((sStaff == staffId || sStaff.isEmpty) && dt.isAfter(checkInTime)) {
        bills++;
        final c = (s['cash'] as num?)?.toDouble() ?? 0.0;
        final u = (s['upi'] as num?)?.toDouble() ?? 0.0;
        final crd = (s['card'] as num?)?.toDouble() ?? 0.0;
        final t = (s['total'] as num?)?.toDouble() ?? (c + u + crd);
        cash += c;
        upi += u;
        card += crd;
        total += t;
      }
    }

    return {
      'cash': cash,
      'upi': upi,
      'card': card,
      'total': total,
      'billCount': bills,
    };
  }

  /// Calculates duty stage based on worked hours and shift configuration
  String calculateDutyStage(double workedHours, ShiftConfig shift) {
    if (workedHours >= shift.fullShiftHours) {
      return 'Full Duty Completed';
    } else if (workedHours >= shift.halfDayThresholdHours) {
      return 'Half Duty / Half Day';
    } else {
      return 'Incomplete / Short Duty';
    }
  }

  /// Check-in or Check-out action for staff.
  Future<({bool isCheckIn, AttendanceRecord record})> recordAttendance({
    required String shopId,
    required String staffId,
    required String staffName,
    double? closingCashInDrawer,
  }) async {
    final now = DateTime.now();
    final today = _dateKey.format(now);
    final authUid = FirebaseAuth.instance.currentUser?.uid;
    final effectiveStaffId = (authUid != null && authUid.isNotEmpty) ? authUid : staffId;
    final docId = '${effectiveStaffId}_$today';
    final ref = FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('attendance')
        .doc(docId);

    // Auto-reconcile previous forgotten check-outs first
    await autoCloseForgottenCheckOut(shopId, effectiveStaffId);

    DocumentSnapshot<Map<String, dynamic>>? snap;
    try {
      snap = await ref.get();
    } catch (_) {
      try {
        snap = await ref.get(const GetOptions(source: Source.cache));
      } catch (_) {}
    }

    final existingData = snap?.data();
    final existing =
        existingData != null ? AttendanceRecord.fromMap(docId, existingData) : null;

    if (existing != null &&
        existing.checkIn != null &&
        existing.checkOut != null) {
      throw Exception(
          'ഇന്നത്തെ ഡ്യൂട്ടി ഇതിനകം അവസാനിപ്പിച്ചിട്ടുണ്ട് (Already checked out for today).');
    }

    final loc = await captureAndValidateLocation();
    final isCheckIn = existing == null || existing.checkIn == null;
    final shiftConfig = getShiftConfig();

    try {
      if (isCheckIn) {
        // Late calculation: 8:30 AM + 15m = 8:45 AM
        final lateThresholdMinutes =
            shiftConfig.startHour * 60 + shiftConfig.startMinute + shiftConfig.lateGraceMinutes;
        final currentMinutes = now.hour * 60 + now.minute;
        final isLate = currentMinutes > lateThresholdMinutes;

        final newRecord = AttendanceRecord(
          id: docId,
          staffId: effectiveStaffId,
          staffName: staffName,
          date: today,
          checkIn: now,
          checkInLat: loc.position.latitude,
          checkInLng: loc.position.longitude,
          checkInAccuracy: loc.position.accuracy,
          checkInMocked: loc.position.isMocked,
          checkInStatus: loc.locationStatus,
          status: 'present',
          dutyStage: 'Shift Started',
          workedHours: 0.0,
          isLate: isLate,
          approvalStatus: 'pending_approval',
          updatedAt: now,
        );

        await ref.set(newRecord.toMap(useServerTimestamp: true), SetOptions(merge: true));
        await _cacheLocalAttendance(effectiveStaffId, newRecord);
        return (isCheckIn: true, record: newRecord);
      } else {
        // Check-out calculation
        final inTime = existing.checkIn ?? now;
        final workedHours = now.difference(inTime).inMinutes / 60.0;
        final stage = calculateDutyStage(workedHours, shiftConfig);

        // Shift sales and Cash register
        final salesSummary = computeShiftSalesSummary(staffId, inTime);
        final expectedCash = (salesSummary['cash'] as num?)?.toDouble() ?? 0.0;
        final closingCash = closingCashInDrawer ?? expectedCash;
        final difference = closingCash - expectedCash;
        final mismatch = difference.abs() > 0.01;

        final cashRegister = {
          'expectedCash': expectedCash,
          'closingCash': closingCash,
          'difference': difference,
          'mismatch': mismatch,
          'submittedAt': now.toIso8601String(),
        };

        final updatedRecord = AttendanceRecord(
          id: docId,
          staffId: staffId,
          staffName: staffName,
          date: today,
          checkIn: existing.checkIn,
          checkInLat: existing.checkInLat,
          checkInLng: existing.checkInLng,
          checkInAccuracy: existing.checkInAccuracy,
          checkInMocked: existing.checkInMocked,
          checkInStatus: existing.checkInStatus,
          status: existing.status,
          dutyStage: stage,
          workedHours: workedHours,
          isLate: existing.isLate,
          approvalStatus: existing.approvalStatus,
          approvedBy: existing.approvedBy,
          approvedAt: existing.approvedAt,
          checkOut: now,
          checkOutLat: loc.position.latitude,
          checkOutLng: loc.position.longitude,
          checkOutAccuracy: loc.position.accuracy,
          checkOutMocked: loc.position.isMocked,
          checkOutStatus: loc.locationStatus,
          shiftSalesSummary: salesSummary,
          cashRegister: cashRegister,
          updatedAt: now,
        );

        await ref.update({
          'checkOut': FieldValue.serverTimestamp(),
          'checkOutLat': loc.position.latitude,
          'checkOutLng': loc.position.longitude,
          'checkOutAccuracy': loc.position.accuracy,
          'checkOutMocked': loc.position.isMocked,
          'checkOutStatus': loc.locationStatus,
          'dutyStage': stage,
          'workedHours': workedHours,
          'shiftSalesSummary': salesSummary,
          'cashRegister': cashRegister,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        await _cacheLocalAttendance(staffId, updatedRecord);
        return (isCheckIn: false, record: updatedRecord);
      }
    } catch (e) {
      debugPrint('Firestore record error, storing offline queue: $e');
      final offlineRecord = AttendanceRecord(
        id: docId,
        staffId: staffId,
        staffName: staffName,
        date: today,
        checkIn: isCheckIn ? now : existing.checkIn,
        checkInLat: isCheckIn ? loc.position.latitude : existing.checkInLat,
        checkInLng: isCheckIn ? loc.position.longitude : existing.checkInLng,
        checkInAccuracy: isCheckIn ? loc.position.accuracy : existing.checkInAccuracy,
        checkInMocked: isCheckIn ? loc.position.isMocked : existing.checkInMocked,
        checkInStatus: isCheckIn ? loc.locationStatus : existing.checkInStatus,
        checkOut: isCheckIn ? null : now,
        checkOutLat: isCheckIn ? null : loc.position.latitude,
        checkOutLng: isCheckIn ? null : loc.position.longitude,
        checkOutAccuracy: isCheckIn ? null : loc.position.accuracy,
        checkOutMocked: isCheckIn ? false : loc.position.isMocked,
        checkOutStatus: isCheckIn ? null : loc.locationStatus,
        status: 'present',
        dutyStage: isCheckIn ? 'Shift Started' : 'Full Duty Completed',
        approvalStatus: 'pending_approval',
        syncedLate: true,
        updatedAt: now,
      );

      await _saveToOfflineQueue(shopId, offlineRecord);
      await _cacheLocalAttendance(staffId, offlineRecord);
      return (isCheckIn: isCheckIn, record: offlineRecord);
    }
  }

  /// Automatically closes forgotten previous check-outs if any
  Future<void> autoCloseForgottenCheckOut(String shopId, String staffId) async {
    try {
      final today = _dateKey.format(DateTime.now());
      final snap = await FirebaseFirestore.instance
          .collection('shops')
          .doc(shopId)
          .collection('attendance')
          .where('staffId', isEqualTo: staffId)
          .where('checkOut', isNull: true)
          .get();

      for (final doc in snap.docs) {
        final data = doc.data();
        if (data['date'] != today && data['checkIn'] != null) {
          final inTs = data['checkIn'] as Timestamp?;
          final inDate = inTs?.toDate() ?? DateTime.now();
          final autoOut = inDate.add(const Duration(hours: 13));

          await doc.reference.update({
            'checkOut': Timestamp.fromDate(autoOut),
            'dutyStage': 'Needs review',
            'manualEditNote': 'Auto-closed by system due to forgotten check-out',
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      }
    } catch (e) {
      debugPrint('Auto-close forgotten check-out error: $e');
    }
  }

  Future<void> _cacheLocalAttendance(String staffId, AttendanceRecord r) async {
    try {
      await Db.settings.put('today_attendance_$staffId', r.toMap(useServerTimestamp: false));
    } catch (_) {}
  }

  AttendanceRecord? getCachedTodayAttendance(String staffId) {
    try {
      final m = Db.settings.get('today_attendance_$staffId');
      if (m is Map) {
        final map = Map<String, dynamic>.from(m);
        final today = _dateKey.format(DateTime.now());
        if (map['date'] == today) {
          return AttendanceRecord.fromMap('${map['id']}', map);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveToOfflineQueue(String shopId, AttendanceRecord r) async {
    if (!Hive.isAdapterRegistered(42)) {
      Hive.registerAdapter(TimestampAdapter());
    }
    final list = (Db.settings.get('offline_attendance_queue') as List?)?.toList() ?? [];
    list.add({
      'shopId': shopId,
      'data': r.toMap(useServerTimestamp: false),
    });
    await Db.settings.put('offline_attendance_queue', list);
  }

  /// Syncs any queued offline attendance records when internet is restored.
  Future<void> syncOfflineQueue() async {
    final list = (Db.settings.get('offline_attendance_queue') as List?)?.toList();
    if (list == null || list.isEmpty) return;

    final remaining = <dynamic>[];
    for (final item in list) {
      try {
        final m = Map<String, dynamic>.from(item as Map);
        final shopId = '${m['shopId']}';
        final data = Map<String, dynamic>.from(m['data'] as Map);
        final docId = '${data['id']}';
        data['syncedLate'] = true;
        await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('attendance')
            .doc(docId)
            .set(data, SetOptions(merge: true));
      } catch (e) {
        remaining.add(item);
      }
    }
    await Db.settings.put('offline_attendance_queue', remaining);
  }

  /// Stream of today's attendance record for a specific staff member.
  Stream<AttendanceRecord?> streamTodayAttendance(String shopId, String staffId) {
    final today = _dateKey.format(DateTime.now());
    final docId = '${staffId}_$today';
    return FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('attendance')
        .doc(docId)
        .snapshots()
        .map((snap) {
      if (!snap.exists || snap.data() == null) return null;
      final rec = AttendanceRecord.fromMap(snap.id, snap.data()!);
      _cacheLocalAttendance(staffId, rec);
      return rec;
    });
  }

  /// Stream of pending approvals for Owner Dashboard
  Stream<List<AttendanceRecord>> streamPendingApprovals(String shopId) {
    if (shopId.isEmpty) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('attendance')
        .where('approvalStatus', isEqualTo: 'pending_approval')
        .snapshots()
        .map((snap) {
      final list =
          snap.docs.map((d) => AttendanceRecord.fromMap(d.id, d.data())).toList();
      list.sort((a, b) => (b.checkIn ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.checkIn ?? DateTime.fromMillisecondsSinceEpoch(0)));
      return list;
    });
  }

  /// Owner: Approve an attendance record
  Future<void> approveAttendance({
    required String shopId,
    required String docId,
    required String ownerUid,
  }) async {
    final ref = FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('attendance')
        .doc(docId);

    final snap = await ref.get();
    final beforeData = snap.data() ?? {};

    await ref.update({
      'approvalStatus': 'approved',
      'approvedBy': ownerUid,
      'approvedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // Write audit log
    await _logAudit(
      shopId: shopId,
      ownerUid: ownerUid,
      action: 'APPROVE',
      attendanceId: docId,
      before: beforeData,
      after: {'approvalStatus': 'approved', 'approvedBy': ownerUid},
      reason: 'Standard approval',
    );
  }

  /// Owner: Adjust check-in/out times
  Future<void> adjustAttendance({
    required String shopId,
    required String docId,
    required String ownerUid,
    required DateTime adjustedCheckIn,
    DateTime? adjustedCheckOut,
    required String reason,
  }) async {
    if (reason.trim().isEmpty) {
      throw Exception('മാറ്റം വരുത്താനുള്ള കാരണം നൽകുക (Reason is required for adjustment).');
    }

    final ref = FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('attendance')
        .doc(docId);

    final snap = await ref.get();
    final before = snap.data() ?? {};

    final inDate = adjustedCheckIn;
    final outDate = adjustedCheckOut;
    final double workedHours = (outDate != null)
        ? (outDate.difference(inDate).inMinutes / 60.0)
        : ((before['workedHours'] as num?)?.toDouble() ?? 0.0);

    final shift = getShiftConfig();
    final stage = calculateDutyStage(workedHours, shift);
    final lateThresholdMinutes =
        shift.startHour * 60 + shift.startMinute + shift.lateGraceMinutes;
    final currentMinutes = inDate.hour * 60 + inDate.minute;
    final isLate = currentMinutes > lateThresholdMinutes;

    final updates = <String, dynamic>{
      'originalCheckIn': before['originalCheckIn'] ?? before['checkIn'],
      'originalCheckOut': before['originalCheckOut'] ?? before['checkOut'],
      'checkIn': Timestamp.fromDate(inDate),
      'checkOut': outDate != null ? Timestamp.fromDate(outDate) : before['checkOut'],
      'workedHours': workedHours,
      'dutyStage': stage,
      'isLate': isLate,
      'approvalStatus': 'approved',
      'adjustedBy': ownerUid,
      'adjustReason': reason.trim(),
      'approvedBy': ownerUid,
      'approvedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    await ref.update(updates);

    await _logAudit(
      shopId: shopId,
      ownerUid: ownerUid,
      action: 'ADJUST',
      attendanceId: docId,
      before: before,
      after: updates,
      reason: reason.trim(),
    );
  }

  /// Owner: Reject an attendance record
  Future<void> rejectAttendance({
    required String shopId,
    required String docId,
    required String ownerUid,
    required String reason,
    bool revokeAccess = false,
  }) async {
    if (reason.trim().isEmpty) {
      throw Exception('നിരസിക്കാനുള്ള കാരണം നൽകുക (Reason is required for rejection).');
    }

    final ref = FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('attendance')
        .doc(docId);

    final snap = await ref.get();
    final before = snap.data() ?? {};

    final updates = <String, dynamic>{
      'approvalStatus': 'rejected',
      'adjustReason': reason.trim(),
      'approvedBy': ownerUid,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (revokeAccess) {
      updates['checkOut'] = FieldValue.serverTimestamp();
      updates['dutyStage'] = 'Incomplete / Short Duty';
    }

    await ref.update(updates);

    await _logAudit(
      shopId: shopId,
      ownerUid: ownerUid,
      action: 'REJECT',
      attendanceId: docId,
      before: before,
      after: updates,
      reason: reason.trim(),
    );
  }

  /// Owner: Manual Attendance Entry
  Future<void> ownerManualEntry({
    required String shopId,
    required String staffId,
    required String staffName,
    required String date,
    required DateTime checkIn,
    DateTime? checkOut,
    required String reason,
  }) async {
    final cleanDate = date.replaceAll('-', '');
    final docId = '${staffId}_$cleanDate';

    final shift = getShiftConfig();
    double workedHours = 0.0;
    if (checkOut != null) {
      workedHours = checkOut.difference(checkIn).inMinutes / 60.0;
    }
    final stage = calculateDutyStage(workedHours, shift);
    final lateThresholdMinutes =
        shift.startHour * 60 + shift.startMinute + shift.lateGraceMinutes;
    final inMinutes = checkIn.hour * 60 + checkIn.minute;
    final isLate = inMinutes > lateThresholdMinutes;

    final ref = FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('attendance')
        .doc(docId);

    final record = AttendanceRecord(
      id: docId,
      staffId: staffId,
      staffName: staffName,
      date: cleanDate,
      checkIn: checkIn,
      checkOut: checkOut,
      status: 'present',
      dutyStage: stage,
      workedHours: workedHours,
      isLate: isLate,
      approvalStatus: 'approved',
      approvedBy: 'owner',
      approvedAt: DateTime.now(),
      adjustedBy: 'owner',
      adjustReason: 'Manual entry: $reason',
      checkInStatus: 'Owner Manual Entry',
      updatedAt: DateTime.now(),
    );

    await ref.set(record.toMap(useServerTimestamp: true), SetOptions(merge: true));
    await _logAudit(
      shopId: shopId,
      action: 'MANUAL_ENTRY',
      attendanceId: docId,
      ownerUid: 'owner',
      reason: reason,
      before: {},
      after: record.toMap(),
    );
  }

  /// Owner: Bulk approve multiple attendance records
  Future<void> bulkApprovePending({
    required String shopId,
    required String ownerUid,
    required List<String> docIds,
  }) async {
    final batch = FirebaseFirestore.instance.batch();
    for (final id in docIds) {
      final ref = FirebaseFirestore.instance
          .collection('shops')
          .doc(shopId)
          .collection('attendance')
          .doc(id);
      batch.update(ref, {
        'approvalStatus': 'approved',
        'approvedBy': ownerUid,
        'approvedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();

    await _logAudit(
      shopId: shopId,
      ownerUid: ownerUid,
      action: 'BULK_APPROVE',
      attendanceId: docIds.join(','),
      before: {},
      after: {'approvedCount': docIds.length},
      reason: 'Bulk approved by owner',
    );
  }

  Future<void> _logAudit({
    required String shopId,
    required String ownerUid,
    required String action,
    required String attendanceId,
    required Map<String, dynamic> before,
    required Map<String, dynamic> after,
    required String reason,
  }) async {
    try {
      await FirebaseFirestore.instance
          .collection('shops')
          .doc(shopId)
          .collection('attendanceAudit')
          .add({
        'action': action,
        'attendanceId': attendanceId,
        'ownerUid': ownerUid,
        'reason': reason,
        'before': before,
        'after': after,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Audit log write failed: $e');
    }
  }

  /// Stream of all attendance records for today (for Owner Dashboard).
  Stream<List<AttendanceRecord>> streamAllTodayAttendance(String shopId) {
    final today = _dateKey.format(DateTime.now());
    return FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('attendance')
        .where('date', isEqualTo: today)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => AttendanceRecord.fromMap(d.id, d.data())).toList());
  }

  /// Stream monthly attendance records for the shop.
  Stream<List<AttendanceRecord>> streamMonthAttendance(String shopId, String yearMonth) {
    return FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('attendance')
        .where('date', isGreaterThanOrEqualTo: '$yearMonth-01')
        .where('date', isLessThanOrEqualTo: '$yearMonth-31')
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => AttendanceRecord.fromMap(d.id, d.data())).toList());
  }
}
