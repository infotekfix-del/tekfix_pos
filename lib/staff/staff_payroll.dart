// ============================================================================
// TEKFIX ERP - STAFF PAYROLL (pure rules, no I/O)
// ============================================================================
//
// Staff record (Hive box tek_staff) fields used here:
//   attendance  : { 'yyyy-MM-dd': 'Present' | 'Half Day' | 'Absent' }
//   payments    : [ {date, month 'yyyy-MM', amount, mode, note,
//                    type: 'salary' | 'advance', reversed?: bool} ]
//   adjustments : [ {date, month, amount (+ bonus / - deduction), note,
//                    reversed?: bool} ]
//
// Balance carries forward month to month from [kPayrollCarryStartMonth]:
//   net(month) = carriedIn + earned + adjustments - paid
// net > 0  : salary still to pay (ബാക്കി)
// net < 0  : advance already given (അഡ്വാൻസ്), recovered next month.
// ============================================================================

import '../attendance/attendance_models.dart';
import 'salary_calculator.dart';

/// Months before this are not carried forward (older records may have been
/// settled outside the app).
const String kPayrollCarryStartMonth = '2026-11';

String payrollMonthKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

String payrollDayKey(DateTime d) =>
    '${payrollMonthKey(d)}-${d.day.toString().padLeft(2, '0')}';

DateTime monthStart(String monthKey) {
  final p = monthKey.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]));
}

String shiftMonth(String monthKey, int delta) {
  final d = monthStart(monthKey);
  return payrollMonthKey(DateTime(d.year, d.month + delta));
}

double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
double _r2(double v) => (v * 100).round() / 100;

List<Map<String, dynamic>> _list(dynamic v) => [
      for (final e in (v as List?) ?? const [])
        if (e is Map) Map<String, dynamic>.from(e)
    ];

class PayrollMonth {
  final String month;
  final int present;
  final int halfDays;
  final int absent;
  final double dailyRate;
  final int daysInMonth;
  final double earned;
  final double adjustments; // + bonus, - deduction
  final double paidSalary;
  final double paidAdvance;
  final double carriedIn; // + owed to staff, - advance from earlier months
  final List<Map<String, dynamic>> payments; // this month, incl. reversed
  final List<Map<String, dynamic>> adjustmentEntries;

  const PayrollMonth({
    required this.month,
    required this.present,
    required this.halfDays,
    required this.absent,
    required this.dailyRate,
    required this.daysInMonth,
    required this.earned,
    required this.adjustments,
    required this.paidSalary,
    required this.paidAdvance,
    required this.carriedIn,
    required this.payments,
    required this.adjustmentEntries,
  });

  double get daysWorked => present + 0.5 * halfDays;
  double get monthlySalary => _r2(dailyRate * daysInMonth);
  double get paid => _r2(paidSalary + paidAdvance);

  /// > 0 still to pay, < 0 advance.
  double get net => _r2(carriedIn + earned + adjustments - paid);
}

/// Month summary with carry-forward from [kPayrollCarryStartMonth].
PayrollMonth payrollFor(Map<String, dynamic> staff, String month, {DateTime? now}) {
  final att = Map<String, dynamic>.from((staff['attendance'] as Map?) ?? const {});
  final pays = _list(staff['payments']);
  final adjs = _list(staff['adjustments']);
  final ref = monthStart(month);
  final rate = SalaryCalculator.getDailyRate(staff, ref);

  ({int p, int h, int a, double earned, double adj, double sal, double adv}) one(String m) {
    var p = 0, h = 0, a = 0;
    att.forEach((d, st) {
      if (!d.startsWith(m)) return;
      if (st == 'Present') p++;
      if (st == 'Half Day') h++;
      if (st == 'Absent') a++;
    });
    final earned = _r2(rate * (p + 0.5 * h));
    var adj = 0.0;
    for (final x in adjs) {
      if ('${x['month']}' == m && x['reversed'] != true) adj += _num(x['amount']);
    }
    var sal = 0.0, adv = 0.0;
    for (final x in pays) {
      if ('${x['month']}' != m || x['reversed'] == true) continue;
      if ('${x['type'] ?? 'salary'}' == 'advance') {
        adv += _num(x['amount']);
      } else {
        sal += _num(x['amount']);
      }
    }
    return (p: p, h: h, a: a, earned: earned, adj: _r2(adj), sal: _r2(sal), adv: _r2(adv));
  }

  var carried = 0.0;
  if (month.compareTo(kPayrollCarryStartMonth) > 0) {
    var m = kPayrollCarryStartMonth;
    var guard = 0;
    while (m.compareTo(month) < 0 && guard++ < 240) {
      final o = one(m);
      carried = _r2(carried + o.earned + o.adj - o.sal - o.adv);
      m = shiftMonth(m, 1);
    }
  }
  final o = one(month);
  return PayrollMonth(
    month: month,
    present: o.p,
    halfDays: o.h,
    absent: o.a,
    dailyRate: rate,
    daysInMonth: SalaryCalculator.getDaysInMonth(ref),
    earned: o.earned,
    adjustments: o.adj,
    paidSalary: o.sal,
    paidAdvance: o.adv,
    carriedIn: carried,
    payments: [for (final x in pays) if ('${x['month']}' == month) x],
    adjustmentEntries: [for (final x in adjs) if ('${x['month']}' == month) x],
  );
}

/// Plain-text salary slip (for WhatsApp / copy).
String salarySlipText(Map<String, dynamic> staff, PayrollMonth p,
    {String shopName = 'TEKFIX Digital'}) {
  String r(double v) => '₹${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2)}';
  final b = StringBuffer()
    ..writeln('🧾 $shopName – Salary Slip')
    ..writeln('👤 ${staff['name']}${'${staff['role'] ?? ''}'.isEmpty ? '' : ' (${staff['role']})'}')
    ..writeln('📅 Month: ${p.month}')
    ..writeln('')
    ..writeln('ഹാജർ (Present): ${p.present}  •  Half day: ${p.halfDays}  •  ലീവ്: ${p.absent}')
    ..writeln('ജോലി ചെയ്ത ദിവസം: ${p.daysWorked}')
    ..writeln('പ്രതിദിന വേതനം: ${r(p.dailyRate)}')
    ..writeln('നേടിയത് (Earned): ${r(p.earned)}');
  if (p.adjustments != 0) {
    b.writeln('${p.adjustments > 0 ? 'ബോണസ്' : 'കുറവ്'} (Adjustment): ${r(p.adjustments)}');
  }
  if (p.carriedIn != 0) {
    b.writeln(p.carriedIn > 0
        ? 'കഴിഞ്ഞ മാസത്തെ ബാക്കി: ${r(p.carriedIn)}'
        : 'കഴിഞ്ഞ മാസത്തെ അഡ്വാൻസ്: -${r(-p.carriedIn)}');
  }
  b
    ..writeln('നൽകിയത് (Paid): ${r(p.paid)}')
    ..writeln('')
    ..writeln(p.net >= 0
        ? '✅ ഇനി നൽകാനുള്ളത്: ${r(p.net)}'
        : '⚠️ അഡ്വാൻസ് (അടുത്ത മാസം കുറയ്ക്കും): ${r(-p.net)}');
  return b.toString().trim();
}

/// Maps an owner-approved staff-app attendance record to the manual
/// attendance status used for salary. null = leave it to the owner.
String? statusFromApproved(AttendanceRecord r) {
  if (r.approvalStatus != 'approved') return null;
  return statusForApprovedRecord(r);
}

/// Same mapping for a record the owner has just approved.
String? statusForApprovedRecord(AttendanceRecord r) {
  if (r.status == 'absent' || r.status == 'leave') return 'Absent';
  if (r.dutyStage.startsWith('Full Duty')) return 'Present';
  if (r.dutyStage.startsWith('Half Duty')) return 'Half Day';
  return null;
}

/// 'YYYY-MM-DD' or 'yyyyMMdd' -> 'yyyy-MM-dd' (null if unreadable).
String? normalizeAttendanceDate(String raw) {
  final s = raw.trim();
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return s;
  if (RegExp(r'^\d{8}$').hasMatch(s)) {
    return '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}';
  }
  return null;
}

/// Finds the staff record for a staff-app record (by phone, then by name).
dynamic findStaffKey(Map<dynamic, Map<String, dynamic>> staffByKey,
    {required String staffId, required String staffName}) {
  String digits(String v) => v.replaceAll(RegExp(r'\D'), '');
  final id = digits(staffId);
  if (id.length >= 10) {
    for (final e in staffByKey.entries) {
      final ph = digits('${e.value['phone'] ?? ''}');
      if (ph.isNotEmpty && (ph.endsWith(id.substring(id.length - 10)) || id.endsWith(ph))) {
        return e.key;
      }
    }
  }
  final n = staffName.trim().toLowerCase();
  if (n.isEmpty) return null;
  for (final e in staffByKey.entries) {
    if ('${e.value['name'] ?? ''}'.trim().toLowerCase() == n) return e.key;
  }
  return null;
}

// ------------------------------------------------------------------ missing
class MissingAttendance {
  final dynamic staffKey;
  final String staffName;
  final DateTime day;
  const MissingAttendance(this.staffKey, this.staffName, this.day);
}

/// Days on which a staff member has no attendance mark, from the first day
/// they were marked (or joined) - never before the payroll carry start - up
/// to yesterday. Newest first. Today is handled by the quick "today" buttons.
List<MissingAttendance> missingAttendance(
  Map<dynamic, Map<String, dynamic>> staffByKey, {
  DateTime? now,
  int maxDaysBack = 62,
}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final floor = monthStart(kPayrollCarryStartMonth);
  final limit = today.subtract(Duration(days: maxDaysBack));
  final out = <MissingAttendance>[];
  staffByKey.forEach((key, s) {
    final att = Map<String, dynamic>.from((s['attendance'] as Map?) ?? const {});
    DateTime? start;
    for (final k in att.keys) {
      final d = DateTime.tryParse(k);
      if (d != null && (start == null || d.isBefore(start))) start = d;
    }
    final joined = DateTime.tryParse('${s['joinedAt'] ?? s['createdAt'] ?? ''}');
    if (joined != null && (start == null || joined.isBefore(start))) {
      start = DateTime(joined.year, joined.month, joined.day);
    }
    if (start == null) return; // never marked: nothing to chase yet
    if (start.isBefore(floor)) start = floor;
    if (start.isBefore(limit)) start = limit;
    for (var d = start; d.isBefore(today); d = DateTime(d.year, d.month, d.day + 1)) {
      if (att[payrollDayKey(d)] == null) {
        out.add(MissingAttendance(key, '${s['name'] ?? ''}', d));
      }
    }
  });
  out.sort((a, b) {
    final c = b.day.compareTo(a.day);
    return c != 0 ? c : a.staffName.compareTo(b.staffName);
  });
  return out;
}
