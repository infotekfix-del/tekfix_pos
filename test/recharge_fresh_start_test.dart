// Fresh start: dashboard volume counts only from kRechargeFreshStartIstDate.
import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_backend.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_period_accounting.dart';

void main() {
  test('fresh start is 00:00 IST on 23 Nov 2026', () {
    expect(kRechargeFreshStartIstDate, '2026-11-23');
    expect(rechargeFreshStartUtc, DateTime.utc(2026, 11, 22, 18, 30));
  });

  test('All Time / Previous Month are limited to the fresh start', () {
    final now = DateTime.utc(2026, 12, 5, 6);
    final all = clampToFreshStart(istRangeFor(RechargePeriodFilter.allTime, now: now));
    expect(all.startUtc, rechargeFreshStartUtc);
    final prev = clampToFreshStart(istRangeFor(RechargePeriodFilter.previousMonth, now: now));
    expect(prev.startUtc, rechargeFreshStartUtc); // Nov 1 -> Nov 20
    final today = istRangeFor(RechargePeriodFilter.today, now: now);
    expect(clampToFreshStart(today).startUtc, today.startUtc); // unchanged
  });

  test('Vi fresh start: clear old 608, opening dues 1,000, wallet untouched, payment settles it', () async {
    const owner = AccountingActor(uid: 'o', name: 'Owner', isOwner: true);
    const staff = AccountingActor(uid: 's', name: 'Staff', isOwner: false);
    const vi = RechargeOperator.vi;
    final at = DateTime.utc(2026, 11, 20, 6);
    final b = LocalAccountingBackend()
      ..seedSettlement(SettlementEntry(distributorId: 'sm', distributorName: 'Sree Murugan',
          operator: vi, kind: SettlementEntryKind.creditLoad, amountPaise: 60800, at: at))
      ..seedSettlement(SettlementEntry(distributorId: 'apex', distributorName: 'Apex',
          operator: RechargeOperator.airtel, kind: SettlementEntryKind.creditLoad, amountPaise: 133300, at: at));

    await b.distributorCreditReversal(shopId: 's', actor: owner, distributorId: 'sm', operator: vi,
        amountPaise: 60800, reason: 'old dues settled', idempotencyKey: 'IDK_fresh_clear_vi');
    await b.distributorCreditReversal(shopId: 's', actor: owner, distributorId: 'apex',
        operator: RechargeOperator.airtel, amountPaise: 133300, reason: 'old dues settled',
        idempotencyKey: 'IDK_fresh_clear_apex');
    var s = await b.settlement('s');
    expect(s.outstandingPaise, 0);

    await b.distributorOpeningDues(shopId: 's', actor: owner, distributorId: 'sm', operator: vi,
        amountPaise: 100000, reason: 'owed before fresh start', idempotencyKey: 'IDK_fresh_odue_vi');
    // Same key again: posted once.
    await b.distributorOpeningDues(shopId: 's', actor: owner, distributorId: 'sm', operator: vi,
        amountPaise: 100000, reason: 'owed before fresh start', idempotencyKey: 'IDK_fresh_odue_vi');
    s = await b.settlement('s');
    expect(s.account('sm', vi)!.outstandingPaise, 100000);
    expect(s.account('apex', RechargeOperator.airtel)!.outstandingPaise, 0);
    expect(s.outstandingPaise, 100000);
    expect(b.postedCount, 0); // no wallet movement at all

    expect(
        () => b.distributorOpeningDues(shopId: 's', actor: staff, distributorId: 'sm', operator: vi,
            amountPaise: 100, reason: 'x', idempotencyKey: 'IDK_fresh_odue_staff'),
        throwsA(isA<AccountingException>()));

    await b.distributorPayment(shopId: 's', actor: owner, distributorId: 'sm', operator: vi,
        amountPaise: 100000, paymentMode: 'UPI', paymentDate: at, idempotencyKey: 'IDK_fresh_pay_vi');
    expect((await b.settlement('s')).outstandingPaise, 0);
  });

  test('wallet alignment: must equal the verified balance, is not a period movement', () async {
    const owner = AccountingActor(uid: 'o', name: 'Owner', isOwner: true);
    const staff = AccountingActor(uid: 's', name: 'Staff', isOwner: false);
    const airtel = RechargeOperator.airtel;
    final b = LocalAccountingBackend()
      ..seedClosing(VerifiedClosing(operator: airtel, actualPaise: 122600,
          at: DateTime.now().subtract(const Duration(hours: 1)), periodId: 'ref'));

    await expectLater(
        b.alignWallet(shopId: 's', actor: owner, operator: airtel, ownPaise: 100000, creditPaise: 0,
            reason: 'fresh start', idempotencyKey: 'IDK_align_bad'),
        throwsA(predicate((e) => e is AccountingException && e.code == 'ALIGNMENT_MISMATCH')));
    expect(
        () => b.alignWallet(shopId: 's', actor: staff, operator: airtel, ownPaise: 122600, creditPaise: 0,
            reason: 'fresh start', idempotencyKey: 'IDK_align_staff'),
        throwsA(isA<AccountingException>()));

    final r = await b.alignWallet(shopId: 's', actor: owner, operator: airtel, ownPaise: 122600,
        creditPaise: 0, reason: 'fresh start', idempotencyKey: 'IDK_align_ok');
    expect(r.data['balanceAfterPaise'], 122600);
    final st = (await b.periodState('s'))[airtel]!;
    expect(st.movements, isEmpty); // not a top-up or adjustment of the period
    expect(st.closing().expectedClosingPaise, 122600);
  });

  test('old recharges are not counted; new ones are', () {
    VolumeTxn tx(String id, DateTime at) => VolumeTxn(
        id: id, operator: RechargeOperator.jio, faceValuePaise: 50000,
        status: RechargeStatus.success, at: at);
    final v = computeVolume([
      tx('old', DateTime.utc(2026, 11, 22, 18, 29)), // 23:59 IST 22 Nov
      tx('new', DateTime.utc(2026, 11, 22, 18, 31)), // 00:01 IST 23 Nov
    ], clampToFreshStart(istRangeFor(RechargePeriodFilter.allTime, now: DateTime.utc(2026, 11, 24))));
    expect(v.grossPaise, 50000);
    expect(v.of(RechargeOperator.jio).successCount, 1);
  });
}
