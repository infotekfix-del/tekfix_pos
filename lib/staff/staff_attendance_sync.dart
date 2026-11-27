// ============================================================================
// TEKFIX ERP - Approved staff-app attendance -> salary attendance.
// When the owner approves attendance from the staff app (check-in / check-out),
// the day is written to the staff record used for salary, so it does not have
// to be marked again by hand. Full duty -> Present, half duty -> Half Day,
// absent / leave -> Absent; anything else is left for the owner to mark.
// ============================================================================

import '../attendance/attendance_models.dart';
import '../main.dart' show Db;
import 'staff_payroll.dart';

/// Returns how many staff-days were written.
Future<int> applyApprovedAttendanceToSalary(Iterable<AttendanceRecord> records) async {
  final staffByKey = <dynamic, Map<String, dynamic>>{
    for (final k in Db.staff.keys)
      if (Db.staff.get(k) is Map) k: Map<String, dynamic>.from(Db.staff.get(k) as Map),
  };
  var written = 0;
  for (final r in records) {
    final status = statusForApprovedRecord(r);
    final day = normalizeAttendanceDate(r.date);
    if (status == null || day == null) continue;
    final key = findStaffKey(staffByKey, staffId: r.staffId, staffName: r.staffName);
    if (key == null) continue;
    final staff = staffByKey[key]!;
    final att = Map<String, dynamic>.from((staff['attendance'] as Map?) ?? {});
    if (att[day] == status) continue;
    att[day] = status;
    staff['attendance'] = att;
    staff['lastUpdated'] = DateTime.now().toIso8601String();
    await Db.staff.put(key, staff);
    await Db.logAction(
        action: 'Attendance From Staff App (Approved)',
        entity: 'Staff',
        entityId: '$key',
        newValue: {'date': day, 'status': status, 'record': r.id});
    written++;
  }
  return written;
}
