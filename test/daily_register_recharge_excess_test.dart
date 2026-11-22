// Shop Daily Register: recharge cash is part of the expected drawer cash,
// and only the real leftover shows as Excess (owner rule 2026-11-21).
// Pure computation: no Hive, no Firestore.
import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/pos/daily_register_models.dart';
import 'package:tekfix_erp_pos/pos/daily_register_service.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_backend.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_period_accounting.dart';

RechargeEntry rc(String id, double amount, {
  RechargePaymentMode mode = RechargePaymentMode.cash,
  bool collected = true,
  String date = '2026-11-21',
  double? refund,
  String? refundMethod,
  DateTime? updatedAt,
}) {
  final t = DateTime.utc(2026, 11, 21, 6);
  return RechargeEntry(
    rechargeId: id,
    shopId: 'S1',
    operator: RechargeOperator.airtel,
    customerMobile: '9999999999',
    amount: amount,
    amountPaise: (amount * 100).round(),
    fundingType: RechargeFundingType.distributorCredit,
    paymentMode: mode,
    status: RechargeStatus.success,
    staffId: 'o',
    staffName: 'Owner',
    createdAt: t,
    updatedAt: updatedAt ?? t,
    dateString: date,
    customerPaymentCollected: collected,
    refundAmount: refund,
    refundMethod: refundMethod,
  );
}

void main() {
  final svc = DailyRegisterService.instance;
  final sales = [
    {'total': 2000.0, 'subtotal': 2000.0, 'cash': 2000.0, 'items': const []},
  ];

  test('owner example: sales 2,000 + recharge 1,000, counted 3,500 -> Excess 500', () {
    final s = svc.computeDailySummary(
      sales: sales,
      date: DateTime(2026, 11, 21),
      openingCash: 0,
      rechargeCashCollection: 1000,
      physicalCashCount: 3500,
    );
    expect(s.expectedClosingCash, 3000);
    expect(s.cashDiscrepancy, 500);
    expect(s.cashExcess, 500);
    expect(s.cashShortage, 0);
  });

  test('counted 2,900 -> Shortage 100, only shown', () {
    final s = svc.computeDailySummary(
      sales: sales,
      date: DateTime(2026, 11, 21),
      rechargeCashCollection: 1000,
      physicalCashCount: 2900,
    );
    expect(s.cashShortage, 100);
    expect(s.cashExcess, 0);
    expect(s.rechargeCashCollection, 1000, reason: 'recharge cash is not reduced');
  });

  test('recharge cash survives save/load of a closed register', () {
    final s = svc.computeDailySummary(
      sales: sales, date: DateTime(2026, 11, 21), rechargeCashCollection: 1000,
      physicalCashCount: 3500);
    final back = DailyRegisterSummary.fromMap(s.toMap());
    expect(back.rechargeCashCollection, 1000);
    expect(back.expectedClosingCash, 3000);
  });

  test('recharge cash: cash + collected on that day, minus cash refunds that day', () {
    final paise = rechargeCashCollectedPaise([
      rc('a', 500),
      rc('b', 500),
      rc('c', 300, mode: RechargePaymentMode.upi), // not drawer cash
      rc('d', 200, collected: false), // never collected
      rc('e', 400, date: '2026-11-20'), // other day
      rc('f', 100, refund: 100, refundMethod: 'cash'), // refunded in cash same day
    ], '2026-11-21');
    expect(paise, 100000);
  });

  test('evening agent collection: paid 1,000 cash -> no false shortage', () {
    final s = svc.computeDailySummary(
      sales: sales,
      date: DateTime(2026, 11, 21),
      rechargeCashCollection: 1000,
      distributorCashPaid: 1000,
      physicalCashCount: 2000,
    );
    expect(s.expectedClosingCash, 2000);
    expect(s.cashDiscrepancy, 0);
    expect(s.totalCashOutflows, 1000);
    final back = DailyRegisterSummary.fromMap(s.toMap());
    expect(back.distributorCashPaid, 1000);
    expect(back.expectedClosingCash, 2000);
  });

  test('distributor cash for a day: cash payments out, cash returns in, UPI ignored', () async {
    const owner = AccountingActor(uid: 'o', name: 'Owner', isOwner: true);
    final b = LocalAccountingBackend()
      ..seedDistributor('APEX', 'Apex', defaultOperator: RechargeOperator.airtel)
      ..seedSettlement(SettlementEntry(
          distributorId: 'APEX', distributorName: 'Apex', operator: RechargeOperator.airtel,
          kind: SettlementEntryKind.creditLoad, amountPaise: 500000, at: DateTime.now()));
    final now = DateTime.now();
    await b.distributorPayment(shopId: 's', actor: owner, distributorId: 'APEX',
        operator: RechargeOperator.airtel, amountPaise: 200000, paymentMode: 'Cash',
        paymentDate: now, idempotencyKey: 'KEY_PAY_00001');
    await b.distributorPayment(shopId: 's', actor: owner, distributorId: 'APEX',
        operator: RechargeOperator.airtel, amountPaise: 50000, paymentMode: 'UPI',
        paymentDate: now, idempotencyKey: 'KEY_PAY_00002');
    await b.agentSettlement(shopId: 's', actor: owner, distributorId: 'APEX',
        operator: RechargeOperator.airtel, totalPayablePaise: 100000, rechargeAdjustmentPaise: 30000,
        paymentMode: 'CASH', paymentDate: now, idempotencyKey: 'KEY_SET_00001');
    await b.agentReturn(shopId: 's', actor: owner, distributorId: 'APEX',
        operator: RechargeOperator.airtel, returnPaise: 10000, returnMode: 'cash',
        returnDate: now, idempotencyKey: 'KEY_RET_00001');
    // -2,000 cash payment, -700 settlement cash part, +100 return = -2,600
    expect(await b.distributorCashForDate('s', istBusinessDate(now)), -260000);
    expect(await b.distributorCashForDate('s', '2000-01-01'), 0);
  });
}
