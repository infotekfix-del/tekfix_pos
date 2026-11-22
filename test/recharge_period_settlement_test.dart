// Quick Recharge: period reconciliation, cumulative volume and operator-wise
// distributor settlement (TEST 1 - 14 of the v2 spec). Pure rules plus the
// in-memory accounting backend; no Firestore, no Supabase, no Hive.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_backend.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_service.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_period_accounting.dart';

const owner = AccountingActor(uid: 'owner1', name: 'Owner', isOwner: true);
const staff = AccountingActor(uid: 'staff1', name: 'Staff', isOwner: false);
const shop = 'shop_test';
const jio = RechargeOperator.jio;
const airtel = RechargeOperator.airtel;
const vi = RechargeOperator.vi;
const bsnl = RechargeOperator.bsnl;

int rs(num r) => (r * 100).round();

/// Fake clock that moves forward one minute per read.
class Clock {
  DateTime t;
  Clock(this.t);
  DateTime call() => t = t.add(const Duration(minutes: 1));
}

WalletMovement mv(RechargeOperator op, WalletMovementKind k, num rupees, DateTime at,
        {bool pending = false}) =>
    WalletMovement(operator: op, kind: k, amountPaise: rs(rupees), at: at, pending: pending);

VolumeTxn tx(String id, RechargeOperator op, num rupees, RechargeStatus s, DateTime at,
        {num refund = 0, DateTime? refundAt}) =>
    VolumeTxn(id: id, operator: op, faceValuePaise: rs(rupees), status: s, at: at,
        refundPaise: rs(refund), refundAt: refundAt);

void main() {
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('tekfix_recharge_period_');
    Hive.init(dir.path); // temporary Hive: only pending-form keys are stored
  });

  final closeAt = DateTime.utc(2026, 11, 18, 16, 30); // 22:00 IST
  final morningAt = DateTime.utc(2026, 11, 19, 3, 30); // 09:00 IST
  final prevClosing =
      VerifiedClosing(operator: jio, actualPaise: rs(500), at: closeAt, periodId: 'p0');

  group('morning entry', () {
    test('TEST 1: previous closing 500, morning 1,500, nothing overnight -> net top-up 1,000', () {
      final c = computeMorningCheck(
          operator: jio, previousClosing: prevClosing, morningActualPaise: rs(1500),
          morningAt: morningAt, ledger: const []);
      expect(c.rawDifferencePaise, rs(1000));
      expect(c.alreadyRecordedPaise, 0);
      expect(c.unexplainedPaise, rs(1000));
      expect(c.status, MorningStatus.pendingVerification);
    });

    test('TEST 1b: a 200 recharge after closing -> unexplained 1,200 and the 200 is not posted again', () async {
      final debitAfterClose = mv(jio, WalletMovementKind.rechargeDebit, 200,
          closeAt.add(const Duration(minutes: 20)));
      final c = computeMorningCheck(
          operator: jio, previousClosing: prevClosing, morningActualPaise: rs(1500),
          morningAt: morningAt, ledger: [debitAfterClose]);
      expect(c.rawDifferencePaise, rs(1000));
      expect(c.alreadyRecordedPaise, -rs(200));
      expect(c.unexplainedPaise, rs(1200));

      // Through the backend: only the classified 1,200 is posted; the
      // ledger then explains the morning balance exactly.
      final clock = Clock(morningAt.subtract(const Duration(minutes: 1)));
      final b = LocalAccountingBackend(clock: clock.call)
        ..seedClosing(prevClosing)
        ..seedMovement(debitAfterClose);
      final r = await b.verifyMorning(shopId: shop, actor: owner, operator: jio,
          morningActualPaise: rs(1500), idempotencyKey: 'IDK_morning_1b');
      expect(r.data['unexplainedPaise'], rs(1200));
      await b.postClassified(shopId: shop, actor: owner, operator: jio,
          category: UnexplainedCategory.topUpOwn, amountPaise: rs(1200),
          reason: 'Morning top-up', transactionDate: morningAt,
          idempotencyKey: 'IDK_classify_1b');
      final st = (await b.periodState(shop))[jio]!;
      expect(st.closing().expectedClosingPaise, rs(1500)); // 500 - 200 + 1,200
      expect(st.morning!.status, MorningStatus.verified);
      // Posting more than the unexplained amount is refused.
      expect(
          () => b.postClassified(shopId: shop, actor: owner, operator: jio,
              category: UnexplainedCategory.topUpOwn, amountPaise: 1,
              reason: 'extra', transactionDate: morningAt, idempotencyKey: 'IDK_classify_1b_x'),
          throwsA(isA<AccountingException>()));
    });

    test('previous closing missing: no auto calculation, reference balance first', () async {
      final c = computeMorningCheck(operator: jio, previousClosing: null,
          morningActualPaise: rs(900), morningAt: morningAt, ledger: const []);
      expect(c.status, MorningStatus.previousClosingMissing);
      expect(c.unexplainedPaise, 0);

      final b = LocalAccountingBackend(clock: Clock(morningAt).call);
      await expectLater(
          b.verifyMorning(shopId: shop, actor: owner, operator: jio,
              morningActualPaise: rs(900), idempotencyKey: 'IDK_missing_1'),
          throwsA(predicate((e) => e is AccountingException && e.code == 'PREVIOUS_CLOSING_MISSING')));
      await b.postReferenceBalance(shopId: shop, actor: owner, operator: jio,
          balancePaise: rs(900), reason: 'Checked in Jio app', idempotencyKey: 'IDK_ref_1');
      expect((await b.periodState(shop))[jio]!.previousClosing!.actualPaise, rs(900));
      expect(b.auditLog.last['action'], 'REFERENCE_BALANCE');
    });

    test('morning entered twice in the same period is blocked; same key replays', () async {
      final b = LocalAccountingBackend(clock: Clock(morningAt).call)..seedClosing(prevClosing);
      final first = await b.verifyMorning(shopId: shop, actor: owner, operator: jio,
          morningActualPaise: rs(1500), idempotencyKey: 'IDK_twice_1');
      final replay = await b.verifyMorning(shopId: shop, actor: owner, operator: jio,
          morningActualPaise: rs(1500), idempotencyKey: 'IDK_twice_1');
      expect(replay.replayed, isTrue);
      expect(replay.referenceId, first.referenceId);
      await expectLater(
          b.verifyMorning(shopId: shop, actor: owner, operator: jio,
              morningActualPaise: rs(1600), idempotencyKey: 'IDK_twice_2'),
          throwsA(predicate((e) => e is AccountingException && e.code == 'DUPLICATE_MORNING')));
    });

    test('negative unexplained difference is a discrepancy and is never posted', () async {
      final b = LocalAccountingBackend(clock: Clock(morningAt).call)..seedClosing(prevClosing);
      final r = await b.verifyMorning(shopId: shop, actor: owner, operator: jio,
          morningActualPaise: rs(450), idempotencyKey: 'IDK_neg_1');
      expect(r.data['unexplainedPaise'], -rs(50));
      expect(r.data['status'], MorningStatus.discrepancy.name);
      expect(b.postedCount, 0);
      // Only an owner-documented correction can resolve it.
      await b.postClassified(shopId: shop, actor: owner, operator: jio,
          category: UnexplainedCategory.manualCorrection, amountPaise: -rs(50),
          reason: 'Operator fee found in statement', transactionDate: morningAt,
          idempotencyKey: 'IDK_neg_fix');
      expect((await b.periodState(shop))[jio]!.morning!.status, MorningStatus.verified);
    });

    test('distributor-credit classification also raises that distributor\'s payable', () async {
      final b = LocalAccountingBackend(clock: Clock(morningAt).call)
        ..seedClosing(prevClosing)
        ..seedDistributor('d1', 'Kerala Telecom');
      await b.verifyMorning(shopId: shop, actor: owner, operator: jio,
          morningActualPaise: rs(1500), idempotencyKey: 'IDK_dc_m');
      await b.postClassified(shopId: shop, actor: owner, operator: jio,
          category: UnexplainedCategory.topUpDistributorCredit, amountPaise: rs(1000),
          reason: 'Credit from distributor', transactionDate: morningAt,
          distributorId: 'd1', idempotencyKey: 'IDK_dc_c');
      final s = await b.settlement(shop);
      expect(s.account('d1', jio)!.outstandingPaise, rs(1000));
    });
  });

  group('night closing', () {
    final opening = VerifiedClosing(operator: jio, actualPaise: rs(500), at: closeAt, periodId: 'p0');
    final ledger = [
      mv(jio, WalletMovementKind.topUpOwn, 1000, morningAt),
      mv(jio, WalletMovementKind.topUpOwn, 500, morningAt.add(const Duration(hours: 3))),
      mv(jio, WalletMovementKind.rechargeDebit, 700, morningAt.add(const Duration(hours: 4))),
      mv(jio, WalletMovementKind.rechargeDebit, 500, morningAt.add(const Duration(hours: 5))),
    ];

    test('TEST 2: 500 + 1,000 + 500 - 1,200 -> expected 800', () {
      final b = computeClosing(operator: jio, previousClosing: opening, ledger: ledger);
      expect(b.openingPaise, rs(500));
      expect(b.topUpsPaise, rs(1500));
      expect(b.rechargeDebitsPaise, rs(1200));
      expect(b.expectedClosingPaise, rs(800));
    });

    test('TEST 3: expected 800, actual 750 -> variance -50, Shortage', () {
      final b = computeClosing(operator: jio, previousClosing: opening, ledger: ledger,
          actualClosingPaise: rs(750));
      expect(b.variancePaise, -rs(50));
      expect(b.status, VarianceStatus.shortage);
      final ex = computeClosing(operator: jio, previousClosing: opening, ledger: ledger,
          actualClosingPaise: rs(820));
      expect(ex.status, VarianceStatus.excess);
      final ok = computeClosing(operator: jio, previousClosing: opening, ledger: ledger,
          actualClosingPaise: rs(800));
      expect(ok.status, VarianceStatus.match);
    });

    test('TEST 11: wallet uses the ACTUAL debit while volume uses face value', () {
      // Operator with instant margin: 100 recharge debits only 97.
      final b = computeClosing(operator: jio, previousClosing: opening, ledger: [
        mv(jio, WalletMovementKind.rechargeDebit, 97, morningAt),
      ]);
      expect(b.expectedClosingPaise, rs(403));
      final v = computeVolume([tx('r1', jio, 100, RechargeStatus.success, morningAt)],
          istRangeFor(RechargePeriodFilter.allTime, now: morningAt));
      expect(v.of(jio).grossPaise, rs(100));
    });

    test('pending debit is shown separately and needs investigation', () {
      final b = computeClosing(operator: jio, previousClosing: opening, ledger: [
        mv(jio, WalletMovementKind.rechargeDebit, 100, morningAt, pending: true),
      ], actualClosingPaise: rs(400));
      expect(b.pendingDebitsPaise, rs(100));
      expect(b.rechargeDebitsPaise, 0);
      expect(b.variancePaise, 0);
      expect(b.status, VarianceStatus.investigationRequired);
    });

    test('TEST 13: a transaction after the closing snapshot goes to the next period', () async {
      final clock = Clock(DateTime.utc(2026, 11, 19, 16, 0));
      final b = LocalAccountingBackend(clock: clock.call)
        ..seedClosing(opening);
      for (final m in ledger) {
        b.seedMovement(m);
      }
      final r = await b.verifyClosing(shopId: shop, actor: owner, operator: jio,
          actualPaise: rs(800), idempotencyKey: 'IDK_close_13');
      expect(r.data['status'], VarianceStatus.match.name);
      // Same calendar date (IST), after the snapshot:
      b.seedMovement(mv(jio, WalletMovementKind.rechargeDebit, 50, clock().add(const Duration(minutes: 5))));
      final st = (await b.periodState(shop))[jio]!;
      expect(st.previousClosing!.actualPaise, rs(800)); // new opening = verified closing
      expect(st.movements.length, 1);
      expect(st.closing().expectedClosingPaise, rs(750));
    });

    test('shop closed for a day: opening carries forward from the last verified closing', () async {
      final b = LocalAccountingBackend(clock: Clock(DateTime.utc(2026, 11, 21, 3, 30)).call)
        ..seedClosing(opening); // last closing two days earlier
      final st = (await b.periodState(shop))[jio]!;
      expect(st.previousClosing!.at, closeAt);
      expect(st.closing().openingPaise, rs(500));
    });

    test('locked period: a back-dated top-up is refused, a correction is allowed', () async {
      final b = LocalAccountingBackend(clock: Clock(morningAt).call)..seedClosing(opening);
      await expectLater(
          b.postClassified(shopId: shop, actor: owner, operator: jio,
              category: UnexplainedCategory.topUpOwn, amountPaise: rs(100), reason: 'late entry',
              transactionDate: closeAt.subtract(const Duration(hours: 2)),
              idempotencyKey: 'IDK_locked_1'),
          throwsA(predicate((e) => e is AccountingException && e.code == 'LOCKED_PERIOD')));
      await b.postClassified(shopId: shop, actor: owner, operator: jio,
          category: UnexplainedCategory.manualCorrection, amountPaise: rs(100),
          reason: 'Correction for 18 Nov', transactionDate: closeAt.subtract(const Duration(hours: 2)),
          idempotencyKey: 'IDK_locked_2');
      final st = (await b.periodState(shop))[jio]!;
      expect(st.previousClosing!.actualPaise, rs(500)); // locked record unchanged
      expect(st.closing().adjustmentsPaise, rs(100)); // correction in the open period
    });

    test('variance requires a reason before the closing is verified', () async {
      final b = LocalAccountingBackend(clock: Clock(morningAt).call)..seedClosing(opening);
      await expectLater(
          b.verifyClosing(shopId: shop, actor: owner, operator: jio,
              actualPaise: rs(450), idempotencyKey: 'IDK_reason_1'),
          throwsA(predicate((e) => e is AccountingException && e.code == 'REASON_REQUIRED')));
    });
  });

  group('recharge volume', () {
    final now = DateTime.utc(2026, 11, 19, 10, 0); // 15:30 IST

    test('TEST 4: Airtel 1,000 + Jio 500 + Vi 2,000 + BSNL 0 -> 3,500', () {
      final v = computeVolume([
        tx('a', airtel, 1000, RechargeStatus.success, now),
        tx('j', jio, 500, RechargeStatus.success, now),
        tx('v', vi, 2000, RechargeStatus.success, now),
      ], istRangeFor(RechargePeriodFilter.allTime, now: now));
      expect(v.grossPaise, rs(3500));
      expect(v.of(bsnl).grossPaise, 0);
    });

    test('TEST 6: a distributor payment never reduces cumulative recharge', () async {
      final txns = [
        tx('a', airtel, 1000, RechargeStatus.success, now),
        tx('j', jio, 500, RechargeStatus.success, now),
      ];
      final before = computeVolume(txns, istRangeFor(RechargePeriodFilter.allTime, now: now)).grossPaise;
      final b = LocalAccountingBackend(clock: Clock(now).call)
        ..seedSettlement(SettlementEntry(distributorId: 'd1', distributorName: 'D1',
            operator: airtel, kind: SettlementEntryKind.creditLoad, amountPaise: rs(1000), at: now));
      await b.distributorPayment(shopId: shop, actor: owner, distributorId: 'd1', operator: airtel,
          amountPaise: rs(1000), paymentMode: 'UPI', paymentDate: now, idempotencyKey: 'IDK_pay_6');
      final after = computeVolume(txns, istRangeFor(RechargePeriodFilter.allTime, now: now)).grossPaise;
      expect(after, before);
      expect(after, rs(1500));
    });

    test('TEST 7: failed and pending recharges never add to totals; duplicates count once', () {
      final v = computeVolume([
        tx('ok', jio, 300, RechargeStatus.success, now),
        tx('ok', jio, 300, RechargeStatus.success, now), // duplicate record
        tx('f', jio, 200, RechargeStatus.failed, now),
        tx('p', jio, 100, RechargeStatus.pending, now),
      ], istRangeFor(RechargePeriodFilter.today, now: now));
      expect(v.grossPaise, rs(300));
      expect(v.of(jio).successCount, 1);
      expect(v.of(jio).failedCount, 1);
      expect(v.of(jio).pendingCount, 1);
    });

    test('TEST 9: refund counted once, net = gross - refunds', () {
      final v = computeVolume([
        tx('r1', jio, 500, RechargeStatus.refunded, now, refund: 500, refundAt: now),
        tx('r2', jio, 300, RechargeStatus.success, now),
      ], istRangeFor(RechargePeriodFilter.today, now: now));
      expect(v.of(jio).grossPaise, rs(800));
      expect(v.of(jio).refundsPaise, rs(500));
      expect(v.of(jio).netPaise, rs(300));
      // A refund dated another day belongs to that day's report only.
      final y = computeVolume([
        tx('r3', jio, 500, RechargeStatus.refunded, now.subtract(const Duration(days: 1)),
            refund: 500, refundAt: now),
      ], istRangeFor(RechargePeriodFilter.yesterday, now: now));
      expect(y.of(jio).grossPaise, rs(500));
      expect(y.of(jio).refundsPaise, 0);
    });

    test('TEST 12: 23:59 IST and 00:01 IST fall on the correct business dates', () {
      final lateNight = DateTime.utc(2026, 11, 18, 18, 29); // 23:59 IST 18 Nov
      final earlyMorning = DateTime.utc(2026, 11, 18, 18, 31); // 00:01 IST 19 Nov
      expect(istBusinessDate(lateNight), '2026-11-18');
      expect(istBusinessDate(earlyMorning), '2026-11-19');
      final today = istRangeFor(RechargePeriodFilter.today, now: now);
      final yesterday = istRangeFor(RechargePeriodFilter.yesterday, now: now);
      expect(today.contains(earlyMorning), isTrue);
      expect(today.contains(lateNight), isFalse);
      expect(yesterday.contains(lateNight), isTrue);
    });

    test('date filters: Monday week start, last 7 days, previous month', () {
      final thu = DateTime.utc(2026, 11, 19, 6, 0); // Thursday IST
      final w = istRangeFor(RechargePeriodFilter.thisWeek, now: thu);
      expect(istBusinessDate(w.startUtc!), '2026-11-16'); // Monday
      final l7 = istRangeFor(RechargePeriodFilter.last7Days, now: thu);
      expect(istBusinessDate(l7.startUtc!), '2026-11-13');
      final pm = istRangeFor(RechargePeriodFilter.previousMonth, now: thu);
      expect(istBusinessDate(pm.startUtc!), '2026-10-01');
      expect(istBusinessDate(pm.endUtc), '2026-11-01');
      final jan = istRangeFor(RechargePeriodFilter.previousMonth, now: DateTime.utc(2027, 1, 5));
      expect(istBusinessDate(jan.startUtc!), '2026-12-01');
    });
  });

  group('distributor settlement', () {
    final at = DateTime.utc(2026, 11, 19, 6, 0);
    LocalAccountingBackend seeded() {
      final b = LocalAccountingBackend(clock: Clock(at).call);
      for (final e in [
        (airtel, 1000),
        (jio, 500),
        (vi, 2000),
      ]) {
        b.seedSettlement(SettlementEntry(distributorId: 'd1', distributorName: 'Kerala Telecom',
            operator: e.$1, kind: SettlementEntryKind.creditLoad, amountPaise: rs(e.$2), at: at));
      }
      return b;
    }

    test('TEST 5: pay Airtel 1,500 -> Airtel advance 500, Jio/Vi unchanged, cards 2,500 / 500', () async {
      final b = seeded();
      final r = await b.distributorPayment(shopId: shop, actor: owner, distributorId: 'd1',
          operator: airtel, amountPaise: rs(1500), paymentMode: 'Bank Transfer',
          paymentDate: at, referenceNo: 'UTR123', idempotencyKey: 'IDK_pay_5');
      expect(r.data['advancePaise'], rs(500));
      final s = await b.settlement(shop);
      expect(s.account('d1', airtel)!.advancePaise, rs(500));
      expect(s.account('d1', airtel)!.outstandingPaise, 0);
      expect(s.account('d1', jio)!.outstandingPaise, rs(500));
      expect(s.account('d1', vi)!.outstandingPaise, rs(2000));
      expect(s.outstandingPaise, rs(2500)); // not netted
      expect(s.advancePaise, rs(500));
      expect(s.netPositionPaise, rs(2000));
    });

    test('partial and full payments', () async {
      final b = seeded();
      await b.distributorPayment(shopId: shop, actor: owner, distributorId: 'd1', operator: vi,
          amountPaise: rs(800), paymentMode: 'Cash', paymentDate: at, idempotencyKey: 'IDK_part_1');
      expect((await b.settlement(shop)).account('d1', vi)!.outstandingPaise, rs(1200));
      await b.distributorPayment(shopId: shop, actor: owner, distributorId: 'd1', operator: vi,
          amountPaise: rs(1200), paymentMode: 'Cash', paymentDate: at, idempotencyKey: 'IDK_part_2');
      final acc = (await b.settlement(shop)).account('d1', vi)!;
      expect(acc.outstandingPaise, 0);
      expect(acc.advancePaise, 0);
      expect(acc.lastPaymentAt, at);
    });

    test('TEST 8: duplicate payment with the same idempotency key posts once', () async {
      final b = seeded();
      final first = await b.distributorPayment(shopId: shop, actor: owner, distributorId: 'd1',
          operator: jio, amountPaise: rs(500), paymentMode: 'UPI', paymentDate: at,
          idempotencyKey: 'IDK_dup_8');
      final again = await b.distributorPayment(shopId: shop, actor: owner, distributorId: 'd1',
          operator: jio, amountPaise: rs(500), paymentMode: 'UPI', paymentDate: at,
          idempotencyKey: 'IDK_dup_8');
      expect(again.replayed, isTrue);
      expect(again.referenceId, first.referenceId);
      expect(b.settlementEntries.where((e) => e.kind == SettlementEntryKind.payment).length, 1);
      expect((await b.settlement(shop)).account('d1', jio)!.outstandingPaise, 0);
    });

    test('TEST 14: concurrent payments: different keys both post, same key posts once', () async {
      final b = seeded();
      Future<PostingResult> pay(String key) => b.distributorPayment(shopId: shop, actor: owner,
          distributorId: 'd1', operator: vi, amountPaise: rs(100), paymentMode: 'UPI',
          paymentDate: at, idempotencyKey: key);
      await Future.wait([pay('IDK_conc_a'), pay('IDK_conc_b')]);
      expect((await b.settlement(shop)).account('d1', vi)!.paidPaise, rs(200));
      final same = await Future.wait([pay('IDK_conc_c'), pay('IDK_conc_c'), pay('IDK_conc_c')]);
      expect(same.where((r) => !r.replayed).length, 1);
      expect((await b.settlement(shop)).account('d1', vi)!.paidPaise, rs(300));
    });

    test('network failure: nothing posted; the retry with the same key posts once', () async {
      final b = seeded()..failNextPosting = true;
      Future<PostingResult> pay() => b.distributorPayment(shopId: shop, actor: owner,
          distributorId: 'd1', operator: jio, amountPaise: rs(200), paymentMode: 'UPI',
          paymentDate: at, idempotencyKey: 'IDK_net_1');
      await expectLater(pay(), throwsA(isA<AccountingException>()));
      expect(b.settlementEntries.where((e) => e.kind == SettlementEntryKind.payment), isEmpty);
      await pay();
      await pay();
      expect(b.settlementEntries.where((e) => e.kind == SettlementEntryKind.payment).length, 1);
    });

    test('validation: zero, negative, over limit, future date, unknown operator', () {
      final b = seeded();
      Future<PostingResult> pay({int amount = 100, DateTime? date, RechargeOperator op = jio}) =>
          b.distributorPayment(shopId: shop, actor: owner, distributorId: 'd1', operator: op,
              amountPaise: amount, paymentMode: 'UPI', paymentDate: date ?? at,
              idempotencyKey: 'IDK_val_${amount}_${op.name}');
      expect(() => pay(amount: 0), throwsA(isA<AccountingException>()));
      expect(() => pay(amount: -5), throwsA(isA<AccountingException>()));
      expect(() => pay(amount: kMaxPostingPaise + 1), throwsA(isA<AccountingException>()));
      expect(() => pay(date: DateTime.now().add(const Duration(days: 2))),
          throwsA(isA<AccountingException>()));
      expect(() => pay(op: RechargeOperator.other), throwsA(isA<AccountingException>()));
    });
  });

  group('security and the service layer', () {
    final at = DateTime.utc(2026, 11, 19, 6, 0);
    tearDown(RechargeAccountingService.instance.resetForTesting);

    test('TEST 10: staff cannot perform any recharge accounting operation', () async {
      final b = LocalAccountingBackend(clock: Clock(at).call)
        ..seedClosing(prevClosing)
        ..seedDistributor('d1', 'D1');
      bool denied(Object e) => e is AccountingException && e.code == 'PERMISSION_DENIED';
      expect(() => b.verifyMorning(shopId: shop, actor: staff, operator: jio,
          morningActualPaise: 1, idempotencyKey: 'IDK_staff_1'), throwsA(predicate(denied)));
      expect(() => b.postClassified(shopId: shop, actor: staff, operator: jio,
          category: UnexplainedCategory.topUpOwn, amountPaise: 1, reason: 'x',
          transactionDate: at, idempotencyKey: 'IDK_staff_2'), throwsA(predicate(denied)));
      expect(() => b.postReferenceBalance(shopId: shop, actor: staff, operator: jio,
          balancePaise: 1, reason: 'x', idempotencyKey: 'IDK_staff_3'), throwsA(predicate(denied)));
      expect(() => b.verifyClosing(shopId: shop, actor: staff, operator: jio,
          actualPaise: 1, idempotencyKey: 'IDK_staff_4'), throwsA(predicate(denied)));
      expect(() => b.distributorPayment(shopId: shop, actor: staff, distributorId: 'd1',
          operator: jio, amountPaise: 1, paymentMode: 'UPI', paymentDate: at,
          idempotencyKey: 'IDK_staff_5'), throwsA(predicate(denied)));

      final svc = RechargeAccountingService.instance
        ..useBackendForTesting(b)
        ..isOnline = () async => true;
      await expectLater(
          svc.distributorPayment(shopId: shop, actor: staff, distributorId: 'd1', operator: jio,
              amountPaise: 1, paymentMode: 'UPI', paymentDate: at),
          throwsA(predicate(denied)));
      expect(b.auditLog, isEmpty);
    });

    test('offline: posting is blocked before anything is sent', () async {
      final b = LocalAccountingBackend(clock: Clock(at).call)..seedDistributor('d1', 'D1');
      final svc = RechargeAccountingService.instance
        ..useBackendForTesting(b)
        ..isOnline = () async => false;
      await expectLater(
          svc.distributorPayment(shopId: shop, actor: owner, distributorId: 'd1', operator: jio,
              amountPaise: rs(10), paymentMode: 'UPI', paymentDate: at),
          throwsA(predicate((e) => e is AccountingException && e.code == 'OFFLINE')));
      expect(b.settlementEntries, isEmpty);
    });

    test('app restart: the pending form keeps its idempotency key until confirmed', () async {
      final b = LocalAccountingBackend(clock: Clock(at).call)
        ..seedDistributor('d1', 'D1')
        ..failNextPosting = true;
      final svc = RechargeAccountingService.instance
        ..useBackendForTesting(b)
        ..isOnline = () async => true;
      Future<PostingResult> pay() => svc.distributorPayment(shopId: shop, actor: owner,
          distributorId: 'd1', operator: jio, amountPaise: rs(250), paymentMode: 'UPI',
          paymentDate: at, referenceNo: 'UTR9');
      const sig = 'payment|shop_test|d1|jio|25000|UPI|2026-11-19|UTR9';
      await expectLater(pay(), throwsA(isA<AccountingException>()));
      final kept = await svc.pendingKeys.keyFor(sig);
      expect(await svc.pendingKeys.has(sig), isTrue);
      // "Restart": a fresh key store reads the same persisted draft key.
      expect(await PendingPostingKeys().keyFor(sig), kept);
      final r = await pay();
      expect(r.referenceId, 'PAY_$kept'); // same key reused after the failure
      expect(await svc.pendingKeys.has(sig), isFalse);
    });

    test('incorrect operator: corrected by a reversal entry plus a new entry', () async {
      final b = LocalAccountingBackend(clock: Clock(at).call)
        ..seedClosing(prevClosing)
        ..seedClosing(VerifiedClosing(operator: airtel, actualPaise: 0, at: closeAt, periodId: 'pa'));
      await b.postClassified(shopId: shop, actor: owner, operator: jio,
          category: UnexplainedCategory.otherAdjustment, amountPaise: rs(300),
          reason: 'Bonus', transactionDate: at, idempotencyKey: 'IDK_wrongop_1');
      await b.postClassified(shopId: shop, actor: owner, operator: jio,
          category: UnexplainedCategory.manualCorrection, amountPaise: -rs(300),
          reason: 'Reverse IDK_wrongop_1: wrong operator', transactionDate: at,
          idempotencyKey: 'IDK_wrongop_2');
      await b.postClassified(shopId: shop, actor: owner, operator: airtel,
          category: UnexplainedCategory.otherAdjustment, amountPaise: rs(300),
          reason: 'Bonus (moved from Jio)', transactionDate: at, idempotencyKey: 'IDK_wrongop_3');
      final st = await b.periodState(shop);
      expect(st[jio]!.closing().expectedClosingPaise, rs(500));
      expect(st[airtel]!.closing().expectedClosingPaise, rs(300));
      expect(st[jio]!.movements.length, 2); // nothing edited or deleted
    });

    test('money: rupee parsing without floating point, half-up commission rounding', () {
      expect(parseRupeesToPaise('1,23,456.70'), 12345670);
      expect(parseRupeesToPaise('₹0.05'), 5);
      expect(parseRupeesToPaise('12.345'), isNull);
      expect(parseRupeesToPaise('-5'), isNull);
      expect(percentOfPaise(10000, 350), 350); // 3.5% of ₹100
      expect(percentOfPaise(333, 150), 5); // 4.995 -> 5 (half up)
      expect(percentOfPaise(333, 149), 5); // 4.9617 -> 5
      expect(percentOfPaise(100, 50), 1); // 0.5 -> 1
      expect(percentOfPaise(100, 49), 0); // 0.49 -> 0
    });
  });
}
