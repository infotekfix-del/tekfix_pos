// Shop Daily Register: drawer cash outside sales/expenses (owner rule
// 2026-11-22): vendor payments, customer dues, service advances, manual
// Money In/Out and commission cash. Pure computation: no Hive, no Firestore.
import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/pos/daily_register_models.dart';
import 'package:tekfix_erp_pos/pos/daily_register_service.dart';

Map<String, dynamic> log(String date, String account, double amount, String note, [String? cat]) => {
      'date': '${date}T10:15:00.000',
      'account': account,
      'amount': amount,
      'note': note,
      if (cat != null) 'category': cat,
    };

void main() {
  final svc = DailyRegisterService.instance;
  final sales = [
    {'total': 2000.0, 'subtotal': 2000.0, 'cash': 2000.0, 'items': const []},
  ];

  test('owner example: vendor paid 1,000 in cash -> no false shortage', () {
    const other = OtherCashFlows(vendorPaid: 1000);
    final s = svc.computeDailySummary(
      sales: sales,
      date: DateTime(2026, 11, 22),
      openingCash: 1000,
      otherCash: other,
      physicalCashCount: 2000,
    );
    expect(s.expectedClosingCash, 2000);
    expect(s.cashDiscrepancy, 0);
    expect(s.cashShortage, 0);
    expect(s.totalCashOutflows, 1000);
  });

  test('cash log: tagged and old untagged entries; bank, other days and counted items ignored', () {
    final f = OtherCashFlows.fromLog([
      log('2026-11-22', 'Cash', -1000, 'Vendor Advance Payment: G7', 'vendor'),
      log('2026-11-22', 'Cash', -500, 'Purchase Bill PB-1 payment'), // old, untagged
      log('2026-11-22', 'Cash', 200, 'Purchase Return PR-1 cash from G7'), // vendor gave cash back
      log('2026-11-22', 'Bank', -700, 'Vendor Payment PB-2', 'vendor'), // not drawer cash
      log('2026-11-21', 'Cash', -900, 'Vendor Payment PB-3', 'vendor'), // other day
      log('2026-11-22', 'Cash', 300, 'Received from Ravi', 'customer_due'),
      log('2026-11-22', 'Cash', 250, 'Service advance J1'),
      log('2026-11-22', 'Cash', -50, 'Service advance adjusted J1', 'service_advance'),
      log('2026-11-22', 'Cash', 400, 'Owner put cash', 'manual'),
      log('2026-11-22', 'Cash', -100, 'Money paid'),
      log('2026-11-22', 'Cash', 39, 'Recharge Commission Cash Received: Jio (T1)', 'commission'),
      log('2026-11-22', 'Cash', 2000, 'Sale INV-1'), // counted as sales
      log('2026-11-22', 'Cash', -150, 'Expense (Tea): tea'), // counted as expense
      log('2026-11-22', 'Cash', -800, 'Salary: Anu'), // staff salary is an expense
    ], '2026-11-22');
    expect(f.vendorPaid, 1300);
    expect(f.customerDuesReceived, 300);
    expect(f.serviceAdvanceReceived, 200);
    expect(f.manualNet, 300);
    expect(f.commissionCashIn, 39);
    expect(f.net, 300 + 200 + 300 + 39 - 1300);
    expect(f.outflows, 1300);
  });

  test('closed register keeps the lines after save/load', () {
    const other = OtherCashFlows(vendorPaid: 1000, customerDuesReceived: 300, manualNet: -100);
    final s = svc.computeDailySummary(
        sales: sales, date: DateTime(2026, 11, 22), openingCash: 1000, otherCash: other,
        physicalCashCount: 2200);
    final back = DailyRegisterSummary.fromMap(s.toMap());
    expect(back.otherCash.vendorPaid, 1000);
    expect(back.otherCash.customerDuesReceived, 300);
    expect(back.otherCash.manualNet, -100);
    expect(back.expectedClosingCash, 1000 + 2000 - 1000 + 300 - 100);
    expect(DailyRegisterSummary.fromMap(<String, dynamic>{...s.toMap()}..remove('otherCash'))
        .otherCash
        .isEmpty, true, reason: 'registers saved before this change still load');
  });

  test('20 Nov example: owner drawings are subtracted (expected 1,498, not 2,198)', () {
    final s = svc.computeDailySummary(
      sales: [
        {'total': 2400.0, 'subtotal': 2400.0, 'cash': 2400.0, 'items': const []},
      ],
      date: DateTime(2026, 11, 20),
      openingCash: 1000,
      totalCashExpenses: 1900, // rent 500 + other 1,400
      cashRentPaid: 500,
      ownerCashDrawingsDrawn: 700,
      otherCash: const OtherCashFlows(customerDuesReceived: 698),
    );
    expect(s.expectedClosingCash, 1498);
    expect(s.copyWith(openingCash: 1000).expectedClosingCash, 1498,
        reason: 'the EOD sheet uses the same calculation');
    expect(s.totalCashOutflows, 2600);
  });
}
