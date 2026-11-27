// Staff payroll: carry-forward of balance / advance, salary vs advance,
// reversed payments, bonus / deduction, staff-app approval mapping, slip.
import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/attendance/attendance_models.dart';
import 'package:tekfix_erp_pos/staff/staff_payroll.dart';

Map<String, dynamic> staff() => {
      'name': 'SHAHAL',
      'role': 'SERVICE',
      'phone': '9946268502',
      'dailyRate': 350.0,
      'attendance': <String, dynamic>{},
      'payments': <dynamic>[],
      'adjustments': <dynamic>[],
    };

void mark(Map<String, dynamic> s, String month, int present, int half) {
  final att = s['attendance'] as Map<String, dynamic>;
  var d = 1;
  for (var i = 0; i < present; i++) {
    att['$month-${(d++).toString().padLeft(2, '0')}'] = 'Present';
  }
  for (var i = 0; i < half; i++) {
    att['$month-${(d++).toString().padLeft(2, '0')}'] = 'Half Day';
  }
}

void pay(Map<String, dynamic> s, String month, double amount,
        {String type = 'salary', bool reversed = false}) =>
    (s['payments'] as List).add({
      'month': month,
      'amount': amount,
      'mode': 'Cash',
      'type': type,
      if (reversed) 'reversed': true,
    });

void main() {
  test('screenshot case: 11 present + 1 half day, paid 4,400 -> advance 375', () {
    final s = staff();
    mark(s, '2026-11', 11, 1);
    pay(s, '2026-11', 4400);
    final p = payrollFor(s, '2026-11');
    expect(p.daysWorked, 11.5);
    expect(p.earned, 4025);
    expect(p.monthlySalary, 10500);
    expect(p.paid, 4400);
    expect(p.net, -375); // advance
  });

  test('advance carries into the next month and is recovered', () {
    final s = staff();
    mark(s, '2026-11', 11, 1); // 4,025
    pay(s, '2026-11', 4400); // 375 advance
    mark(s, '2026-12', 20, 0); // 7,000
    final dec = payrollFor(s, '2026-12');
    expect(dec.carriedIn, -375);
    expect(dec.net, 6625); // 7,000 - 375
  });

  test('unpaid balance carries forward; months before the start are ignored', () {
    final s = staff();
    mark(s, '2026-10', 25, 0); // before carry start: ignored
    mark(s, '2026-11', 10, 0); // 3,500 earned, 3,000 paid -> 500 owed
    pay(s, '2026-11', 3000);
    final dec = payrollFor(s, '2026-12');
    expect(dec.carriedIn, 500);
    expect(dec.net, 500);
    expect(payrollFor(s, '2026-11').carriedIn, 0);
  });

  test('reversed payments do not count; salary and advance are split', () {
    final s = staff();
    mark(s, '2026-11', 10, 0);
    pay(s, '2026-11', 1000, type: 'advance');
    pay(s, '2026-11', 2000);
    pay(s, '2026-11', 500, reversed: true);
    final p = payrollFor(s, '2026-11');
    expect(p.paidAdvance, 1000);
    expect(p.paidSalary, 2000);
    expect(p.paid, 3000);
    expect(p.net, 500);
    expect(p.payments.length, 3); // reversed one still listed (audit)
  });

  test('bonus and deduction change the amount due; reversed ones do not', () {
    final s = staff();
    mark(s, '2026-11', 10, 0); // 3,500
    (s['adjustments'] as List)
      ..add({'month': '2026-11', 'amount': 300, 'note': 'overtime'})
      ..add({'month': '2026-11', 'amount': -100, 'note': 'late'})
      ..add({'month': '2026-11', 'amount': 999, 'note': 'wrong', 'reversed': true});
    final p = payrollFor(s, '2026-11');
    expect(p.adjustments, 200);
    expect(p.net, 3700);
  });

  test('salary slip text has the key figures', () {
    final s = staff();
    mark(s, '2026-11', 11, 1);
    pay(s, '2026-11', 4400);
    final t = salarySlipText(s, payrollFor(s, '2026-11'));
    expect(t, contains('SHAHAL'));
    expect(t, contains('₹4025'));
    expect(t, contains('അഡ്വാൻസ്'));
    expect(t, contains('₹375'));
  });

  test('staff-app approval mapping, dates and staff matching', () {
    AttendanceRecord rec(String stage, {String status = 'present', String approval = 'approved'}) =>
        AttendanceRecord.fromMap('9946268502_20261120', {
          'staffId': '9946268502',
          'staffName': 'Shahal',
          'date': '20261120',
          'status': status,
          'dutyStage': stage,
          'approvalStatus': approval,
        });
    expect(statusFromApproved(rec('Full Duty Completed')), 'Present');
    expect(statusFromApproved(rec('Half Duty / Half Day')), 'Half Day');
    expect(statusFromApproved(rec('Incomplete / Short Duty')), isNull);
    expect(statusFromApproved(rec('Full Duty Completed', status: 'leave')), 'Absent');
    expect(statusFromApproved(rec('Full Duty Completed', approval: 'pending_approval')), isNull);
    expect(statusForApprovedRecord(rec('Full Duty Completed', approval: 'pending_approval')), 'Present');

    expect(normalizeAttendanceDate('20261120'), '2026-11-20');
    expect(normalizeAttendanceDate('2026-11-20'), '2026-11-20');
    expect(normalizeAttendanceDate('20/11/2026'), isNull);

    final byKey = <dynamic, Map<String, dynamic>>{1: staff(), 2: {'name': 'Anu', 'phone': ''}};
    expect(findStaffKey(byKey, staffId: '+91 99462 68502', staffName: ''), 1);
    expect(findStaffKey(byKey, staffId: 'uid_xyz', staffName: 'anu'), 2);
    expect(findStaffKey(byKey, staffId: 'uid_xyz', staffName: 'nobody'), isNull);
  });

  test('missing attendance: unmarked past days from first mark, newest first', () {
    final a = staff()..['attendance'] = {'2026-11-16': 'Present', '2026-11-18': 'Absent'};
    final b = {'name': 'Anu', 'attendance': <String, dynamic>{}}; // never marked
    final m = missingAttendance({1: a, 2: b}, now: DateTime(2026, 11, 20, 15));
    // 17 and 19 missing; 20 (today) is left to the quick buttons; Anu skipped.
    expect([for (final x in m) payrollDayKey(x.day)], ['2026-11-19', '2026-11-17']);
    expect(m.every((x) => x.staffKey == 1), isTrue);
  });

  test('missing attendance never goes before the carry start month', () {
    final a = staff()..['attendance'] = {'2026-10-28': 'Present'};
    final m = missingAttendance({1: a}, now: DateTime(2026, 11, 3));
    expect([for (final x in m) payrollDayKey(x.day)], ['2026-11-02', '2026-11-01']);
  });

  test('month helpers', () {
    expect(shiftMonth('2026-12', 1), '2027-01');
    expect(shiftMonth('2027-01', -1), '2026-12');
    expect(payrollDayKey(DateTime(2026, 11, 5)), '2026-11-05');
  });
}
