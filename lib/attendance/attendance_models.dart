import 'package:cloud_firestore/cloud_firestore.dart';

class AttendanceRecord {
  final String id; // Document ID: ${staffId}_${yyyyMMdd}
  final String staffId;
  final String staffName;
  final String date; // YYYY-MM-DD or yyyyMMdd
  final DateTime? checkIn;
  final DateTime? checkOut;
  final double? checkInLat;
  final double? checkInLng;
  final double? checkInAccuracy;
  final bool checkInMocked;
  final String checkInStatus; // "Inside shop" or "Outside shop"
  final double? checkOutLat;
  final double? checkOutLng;
  final double? checkOutAccuracy;
  final bool checkOutMocked;
  final String? checkOutStatus;
  final bool syncedLate;
  final String? manualEditNote;
  final DateTime? updatedAt;

  // New Shift & Approval Fields
  final String status; // "present", "absent", "leave"
  final String dutyStage; // "Shift Started", "Full Duty Completed", "Half Duty / Half Day", "Incomplete / Short Duty", "Needs review"
  final double workedHours;
  final bool isLate;
  final String approvalStatus; // "pending_approval", "approved", "rejected"
  final String? approvedBy; // owner uid
  final DateTime? approvedAt;
  final DateTime? originalCheckIn;
  final DateTime? originalCheckOut;
  final String? adjustedBy;
  final String? adjustReason;
  final Map<String, dynamic>? shiftSalesSummary;
  final Map<String, dynamic>? cashRegister;

  const AttendanceRecord({
    required this.id,
    required this.staffId,
    required this.staffName,
    required this.date,
    this.checkIn,
    this.checkOut,
    this.checkInLat,
    this.checkInLng,
    this.checkInAccuracy,
    this.checkInMocked = false,
    this.checkInStatus = 'Inside shop',
    this.checkOutLat,
    this.checkOutLng,
    this.checkOutAccuracy,
    this.checkOutMocked = false,
    this.checkOutStatus,
    this.syncedLate = false,
    this.manualEditNote,
    this.updatedAt,
    this.status = 'present',
    this.dutyStage = 'Shift Started',
    this.workedHours = 0.0,
    this.isLate = false,
    this.approvalStatus = 'pending_approval',
    this.approvedBy,
    this.approvedAt,
    this.originalCheckIn,
    this.originalCheckOut,
    this.adjustedBy,
    this.adjustReason,
    this.shiftSalesSummary,
    this.cashRegister,
  });

  Map<String, dynamic> toMap({bool useServerTimestamp = true}) {
    final m = <String, dynamic>{
      'id': id,
      'staffId': staffId,
      'staffName': staffName,
      'date': date,
      'status': status,
      'dutyStage': dutyStage,
      'workedHours': workedHours > 0 ? workedHours : workingHours,
      'isLate': isLate,
      'approvalStatus': approvalStatus,
      'checkInMocked': checkInMocked,
      'checkInStatus': checkInStatus,
      'syncedLate': syncedLate,
      'updatedAt': useServerTimestamp
          ? FieldValue.serverTimestamp()
          : (updatedAt != null ? Timestamp.fromDate(updatedAt!) : FieldValue.serverTimestamp()),
    };

    if (checkIn != null) {
      m['checkIn'] = (useServerTimestamp && checkOut == null)
          ? FieldValue.serverTimestamp()
          : Timestamp.fromDate(checkIn!);
    }
    if (checkOut != null) {
      m['checkOut'] = useServerTimestamp
          ? FieldValue.serverTimestamp()
          : Timestamp.fromDate(checkOut!);
    }
    if (checkInLat != null) m['checkInLat'] = checkInLat;
    if (checkInLng != null) m['checkInLng'] = checkInLng;
    if (checkInAccuracy != null) m['checkInAccuracy'] = checkInAccuracy;
    if (checkOutLat != null) m['checkOutLat'] = checkOutLat;
    if (checkOutLng != null) m['checkOutLng'] = checkOutLng;
    if (checkOutAccuracy != null) m['checkOutAccuracy'] = checkOutAccuracy;
    m['checkOutMocked'] = checkOutMocked;
    if (checkOutStatus != null) m['checkOutStatus'] = checkOutStatus;
    if (manualEditNote != null) m['manualEditNote'] = manualEditNote;

    if (approvedBy != null) m['approvedBy'] = approvedBy;
    if (approvedAt != null) m['approvedAt'] = Timestamp.fromDate(approvedAt!);
    if (originalCheckIn != null) m['originalCheckIn'] = Timestamp.fromDate(originalCheckIn!);
    if (originalCheckOut != null) m['originalCheckOut'] = Timestamp.fromDate(originalCheckOut!);
    if (adjustedBy != null) m['adjustedBy'] = adjustedBy;
    if (adjustReason != null) m['adjustReason'] = adjustReason;
    if (shiftSalesSummary != null) m['shiftSalesSummary'] = shiftSalesSummary;
    if (cashRegister != null) m['cashRegister'] = cashRegister;

    return m;
  }

  factory AttendanceRecord.fromMap(String docId, Map<String, dynamic> m) {
    DateTime? parseTs(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is String) return DateTime.tryParse(v);
      if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
      return null;
    }

    final double rawHours = (m['workedHours'] as num?)?.toDouble() ?? 0.0;
    final inTime = parseTs(m['checkIn']);
    final outTime = parseTs(m['checkOut']);
    final calculatedHours = (rawHours > 0 || inTime == null || outTime == null)
        ? rawHours
        : (outTime.difference(inTime).inMinutes / 60.0);

    return AttendanceRecord(
      id: docId,
      staffId: '${m['staffId'] ?? ''}',
      staffName: '${m['staffName'] ?? ''}',
      date: '${m['date'] ?? ''}',
      checkIn: inTime,
      checkOut: outTime,
      checkInLat: (m['checkInLat'] as num?)?.toDouble(),
      checkInLng: (m['checkInLng'] as num?)?.toDouble(),
      checkInAccuracy: (m['checkInAccuracy'] as num?)?.toDouble(),
      checkInMocked: m['checkInMocked'] == true,
      checkInStatus: '${m['checkInStatus'] ?? 'Inside shop'}',
      checkOutLat: (m['checkOutLat'] as num?)?.toDouble(),
      checkOutLng: (m['checkOutLng'] as num?)?.toDouble(),
      checkOutAccuracy: (m['checkOutAccuracy'] as num?)?.toDouble(),
      checkOutMocked: m['checkOutMocked'] == true,
      checkOutStatus: m['checkOutStatus'] as String?,
      syncedLate: m['syncedLate'] == true,
      manualEditNote: m['manualEditNote'] as String?,
      updatedAt: parseTs(m['updatedAt']),
      status: '${m['status'] ?? 'present'}',
      dutyStage: '${m['dutyStage'] ?? (outTime != null ? 'Full Duty Completed' : 'Shift Started')}',
      workedHours: calculatedHours,
      isLate: m['isLate'] == true,
      approvalStatus: '${m['approvalStatus'] ?? 'pending_approval'}',
      approvedBy: m['approvedBy'] as String?,
      approvedAt: parseTs(m['approvedAt']),
      originalCheckIn: parseTs(m['originalCheckIn']),
      originalCheckOut: parseTs(m['originalCheckOut']),
      adjustedBy: m['adjustedBy'] as String?,
      adjustReason: m['adjustReason'] as String?,
      shiftSalesSummary: m['shiftSalesSummary'] is Map
          ? Map<String, dynamic>.from(m['shiftSalesSummary'])
          : null,
      cashRegister: m['cashRegister'] is Map
          ? Map<String, dynamic>.from(m['cashRegister'])
          : null,
    );
  }

  double get workingHours {
    if (workedHours > 0) return workedHours;
    if (checkIn == null || checkOut == null) return 0.0;
    final diff = checkOut!.difference(checkIn!);
    return diff.inMinutes / 60.0;
  }

  bool get isApproved => approvalStatus == 'approved';
  bool get isPending => approvalStatus == 'pending_approval';
  bool get isRejected => approvalStatus == 'rejected';
  bool get isAdjusted => adjustedBy != null && adjustedBy!.isNotEmpty;
}

class ShiftConfig {
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;
  final double halfDayThresholdHours;
  final int lateGraceMinutes;

  const ShiftConfig({
    this.startHour = 8,
    this.startMinute = 30,
    this.endHour = 21,
    this.endMinute = 30,
    this.halfDayThresholdHours = 6.5,
    this.lateGraceMinutes = 15,
  });

  factory ShiftConfig.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const ShiftConfig();
    return ShiftConfig(
      startHour: m['startHour'] as int? ?? 8,
      startMinute: m['startMinute'] as int? ?? 30,
      endHour: m['endHour'] as int? ?? 21,
      endMinute: m['endMinute'] as int? ?? 30,
      halfDayThresholdHours: (m['halfDayThresholdHours'] as num?)?.toDouble() ?? 6.5,
      lateGraceMinutes: m['lateGraceMinutes'] as int? ?? 15,
    );
  }

  Map<String, dynamic> toMap() => {
        'startHour': startHour,
        'startMinute': startMinute,
        'endHour': endHour,
        'endMinute': endMinute,
        'halfDayThresholdHours': halfDayThresholdHours,
        'lateGraceMinutes': lateGraceMinutes,
      };

  double get fullShiftHours {
    final startMins = startHour * 60 + startMinute;
    final endMins = endHour * 60 + endMinute;
    return (endMins - startMins) / 60.0;
  }
}

class ShopLocationConfig {
  final double latitude;
  final double longitude;
  final double allowedRadiusMeters;
  final bool blockOutsideCheckIn;

  const ShopLocationConfig({
    required this.latitude,
    required this.longitude,
    this.allowedRadiusMeters = 100.0,
    this.blockOutsideCheckIn = false,
  });
}
