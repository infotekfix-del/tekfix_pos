// Profit & Loss engine: pure maps, no Hive / Firestore.
import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/reports/profit_report.dart';

void main() {
  final start = DateTime(2026, 11, 1);
  final end = DateTime(2026, 12, 1);

  Map<String, dynamic> sale(String date, double total, List<Map<String, dynamic>> lines,
          {String status = 'SOLD'}) =>
      {'saleDate': '${date}T10:00:00', 'total': total, 'items': lines, 'status': status};

  test('new POS: profit from saved unit cost; discount spread over lines', () {
    final r = computeProfitReport(start: start, end: end, sales: [
      sale('2026-11-20', 900, [
        {'itemId': 'A', 'name': 'Glass', 'qty': 2, 'lineTotal': 500, 'unitCost': 100},
        {'itemId': 'B', 'name': 'Case', 'qty': 1, 'lineTotal': 500, 'unitCost': 300},
      ]), // 100 bill discount
    ]);
    expect(r.grossSalesPaise, 90000);
    expect(r.cogsPaise, 50000);
    expect(r.grossProfitPaise, 40000);
    expect(r.items['glass']!.revenuePaise, 45000, reason: 'discount shared 50/50');
    expect(r.items['glass']!.profitPaise, 25000);
    expect(r.items['case']!.profitPaise, 15000);
    expect(r.estimatedLines, 0);
    expect(r.dailyProfit['2026-11-20'], 40000);
  });

  test('old sales without a saved cost use the item cost and are marked estimated', () {
    final r = computeProfitReport(
      start: start,
      end: end,
      sales: [
        sale('2026-11-05', 250, [
          {'itemId': 'A', 'name': 'Glass', 'qty': 1, 'lineTotal': 250},
        ]),
      ],
      items: [
        {'_id': 'A', 'name': 'Glass', 'costPrice': 100, 'stock': 5},
      ],
    );
    expect(r.cogsPaise, 10000);
    expect(r.estimatedLines, 1);
    expect(r.items['glass']!.estimated, isTrue);
  });

  test('returns excluded; other months excluded; old POS "cost" per unit works', () {
    final r = computeProfitReport(start: start, end: end, sales: [
      sale('2026-11-02', 300, [
        {'name': 'Charger', 'qty': 1, 'price': 300, 'cost': 180},
      ]),
      sale('2026-11-03', 500, [
        {'name': 'Charger', 'qty': 1, 'price': 500, 'cost': 180},
      ], status: 'RETURNED'),
      sale('2026-10-31', 999, [
        {'name': 'Charger', 'qty': 1, 'price': 999, 'cost': 180},
      ]),
    ]);
    expect(r.billCount, 1);
    expect(r.grossSalesPaise, 30000);
    expect(r.grossProfitPaise, 12000);
    expect(r.returnsPaise, 50000);
    expect(r.returnCount, 1);
  });

  test('net profit: expenses by category; owner pay is not an expense', () {
    final r = computeProfitReport(
      start: start,
      end: end,
      sales: [
        sale('2026-11-10', 10000, [
          {'name': 'Phone', 'qty': 1, 'lineTotal': 10000, 'unitCost': 8000},
        ]),
      ],
      expenses: [
        {'amount': 500, 'category': 'Rent', 'isDailyRent': true, 'expenseDate': '2026-11-10'},
        {'amount': 300, 'category': 'Tea', 'expenseDate': '2026-11-11'},
        {'amount': 999, 'category': 'Tea', 'expenseDate': '2026-11-11', 'isVoided': true},
        {'amount': 1000, 'category': 'Owner Salary', 'isOwnerWithdrawal': true, 'expenseDate': '2026-11-12'},
      ],
      otherIncome: {'Recharge commission': 3900},
      ownerDrawingsPaise: 70000,
    );
    expect(r.grossProfitPaise, 200000);
    expect(r.expensesByCategory, {'Rent': 50000, 'Tea': 30000});
    expect(r.totalExpensesPaise, 80000);
    expect(r.otherIncomePaise, 3900);
    expect(r.netProfitPaise, 200000 + 3900 - 80000);
    expect(r.ownerSalaryPaise, 100000);
    expect(r.afterOwnerPaise, 123900 - 100000 - 70000);
    expect(r.isProfit, isTrue);
  });

  test('loss month is shown as a loss', () {
    final r = computeProfitReport(start: start, end: end, sales: const [], expenses: [
      {'amount': 1200, 'category': 'Electricity', 'expenseDate': '2026-11-15'},
    ]);
    expect(r.netProfitPaise, -120000);
    expect(r.isProfit, isFalse);
  });

  test('top items by sales, by profit and by quantity', () {
    final r = computeProfitReport(start: start, end: end, sales: [
      sale('2026-11-01', 1000, [
        {'name': 'Phone Case', 'qty': 10, 'lineTotal': 1000, 'unitCost': 40},
      ]),
      sale('2026-11-02', 3000, [
        {'name': 'Earbuds', 'qty': 2, 'lineTotal': 3000, 'unitCost': 1400},
      ]),
    ]);
    expect(r.topByRevenue.first.name, 'Earbuds');
    expect(r.topByProfit.first.name, 'Phone Case', reason: '600 profit vs 200');
    expect(r.topByQty.first.name, 'Phone Case');
  });

  test('purchases and vendor payments are information only', () {
    final r = computeProfitReport(start: start, end: end, sales: const [], purchaseBills: [
      {'purchaseDate': '2026-11-03', 'grandTotal': 6000},
      {'purchaseDate': '2026-11-04', 'grandTotal': 999, 'isDraft': true},
      {'purchaseDate': '2026-11-04', 'grandTotal': 888, 'isVoided': true},
    ], vendorPayments: [
      {'paymentDate': '2026-11-05', 'amount': 500},
      {'paymentDate': '2026-11-06', 'amount': 100, 'isReturn': true},
    ]);
    expect(r.purchasesPaise, 600000);
    expect(r.vendorPaidPaise, 50000);
    expect(r.netProfitPaise, 0, reason: 'purchases are not expenses (cost counts when sold)');
  });

  test('low stock list: at or under minimum, lowest first, services skipped', () {
    final low = lowStockItems([
      {'name': 'Glass', 'stock': 2, 'minStock': 3},
      {'name': 'Cable', 'stock': 0, 'minStock': 2},
      {'name': 'Phone', 'stock': 9, 'minStock': 3},
      {'name': 'Screen fitting', 'stock': 0, 'type': 'service'},
    ], soldLast: {'glass': 14});
    expect(low.map((e) => e.name), ['Cable', 'Glass']);
    expect(low.last.soldLastPeriod, 14);
  });
}
