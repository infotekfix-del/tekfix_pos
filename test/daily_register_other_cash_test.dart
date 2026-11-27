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

  test('owner rule: vendor paid from Cash in Hand never changes the EOD drawer', () {
    final other = OtherCashFlows.fromLog([
      log('2026-11-22', 'Cash', -1000, 'Vendor Advance Payment: G7', 'vendor'),
    ], '2026-11-22');
    final s = svc.computeDailySummary(
      sales: sales,
      date: DateTime(2026, 11, 22),
      openingCash: 1000,
      otherCash: other,
      physicalCashCount: 3000,
    );
    expect(s.expectedClosingCash, 3000, reason: 'opening 1,000 + sales 2,000');
    expect(s.cashDiscrepancy, 0);
    expect(s.totalCashOutflows, 0);
    expect(s.netSales, 2000, reason: 'sales are never reduced');
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
    expect(f.vendorPaid, 0, reason: 'vendors are paid from Cash in Hand, not the drawer');
    expect(f.customerDuesReceived, 300);
    expect(f.serviceAdvanceReceived, 200);
    expect(f.manualNet, 300, reason: 'kept for the Cash in Hand section only');
    expect(f.commissionCashIn, 39);
    expect(f.net, 300 + 200 + 39, reason: 'manual Money In/Out is Cash in Hand');
    expect(f.outflows, 0);
  });

  test('closed register keeps the lines after save/load', () {
    const other = OtherCashFlows(customerDuesReceived: 300, manualNet: -100);
    final s = svc.computeDailySummary(
        sales: sales, date: DateTime(2026, 11, 22), openingCash: 1000, otherCash: other,
        physicalCashCount: 2200);
    final back = DailyRegisterSummary.fromMap(s.toMap());
    expect(back.otherCash.customerDuesReceived, 300);
    expect(back.otherCash.manualNet, -100);
    expect(back.expectedClosingCash, 1000 + 2000 + 300);
    expect(DailyRegisterSummary.fromMap(<String, dynamic>{...s.toMap()}..remove('otherCash'))
        .otherCash
        .isEmpty, true, reason: 'registers saved before this change still load');
  });

  test('20 Nov example: rent, expenses and drawings come from Cash in Hand (expected 4,098)', () {
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
    expect(s.expectedClosingCash, 1000 + 2400 + 698);
    expect(s.copyWith(openingCash: 1000).expectedClosingCash, 4098,
        reason: 'the EOD sheet uses the same calculation');
    expect(s.paidFromCashInHand, 2600);
    expect(s.totalCashOutflows, 0);
  });
}
