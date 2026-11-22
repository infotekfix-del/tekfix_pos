// Quick Recharge v2.1: the legacy flows (agent settlement, agent return,
// distributor credit reversal, customer refund, failed-recharge reversal,
// commission reversal) on the server-authoritative accounting path.
// In-memory LocalAccountingBackend only: no Firestore, no Supabase, no live Hive.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_backend.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_service.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_period_accounting.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';

const owner = AccountingActor(uid: 'owner1', name: 'Owner', isOwner: true);
const staff = AccountingActor(uid: 'staff1', name: 'Staff', isOwner: false);
const shop = 'shop_test';
const airtel = RechargeOperator.airtel;
const jio = RechargeOperator.jio;

int rs(num r) => (r * 100).round();

void main() {
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('tekfix_recharge_legacy_srv_');
    Hive.init(dir.path); // temporary Hive: only pending-form keys
  });

  late LocalAccountingBackend b;
  final svc = RechargeAccountingService.instance;
  final now = DateTime.now();

  setUp(() {
    svc.resetForTesting();
    svc.pendingKeys = PendingPostingKeys(memoryOnly: true);
    svc.isOnline = () async => true;
    b = LocalAccountingBackend();
    svc.useBackendForTesting(b);
    b.seedDistributor('D1', 'Apex', defaultOperator: airtel);
    b.seedSettlement(SettlementEntry(
        distributorId: 'D1', distributorName: 'Apex', operator: airtel,
        kind: SettlementEntryKind.creditLoad, amountPaise: rs(1000), at: now));
    b.seedSettlement(SettlementEntry(
        distributorId: 'D1', distributorName: 'Apex', operator: jio,
        kind: SettlementEntryKind.creditLoad, amountPaise: rs(300), at: now));
  });

  tearDown(() => svc.resetForTesting());

  Future<PostingResult> settle(int total, int adj, {AccountingActor actor = owner, String ref = ''}) =>
      svc.agentSettlement(
          shopId: shop, actor: actor, distributorId: 'D1', operator: airtel,
          totalPayablePaise: total, rechargeAdjustmentPaise: adj, paymentMode: 'CASH',
          paymentDate: now, referenceNo: ref);

  group('agent settlement', () {
    test('payable 1,000, adjustment 500 -> balance 0, pending return 500, cash out 500', () async {
      final r = await settle(rs(1000), rs(500));
      expect(r.data['balanceAfterPaise'], 0);
      expect(r.data['actualPaymentPaise'], rs(500));
      expect(r.data['pendingReturnPaise'], rs(500));
      expect(b.cashBankVouchers.single['paise'], -rs(500));
      final s = await svc.settlement(shop);
      expect(s.account('D1', airtel)!.outstandingPaise, 0);
      expect(s.account('D1', jio)!.outstandingPaise, rs(300), reason: 'other operator untouched');
      expect((await svc.agentPendingReturns(shop))[agentReturnKey('D1', airtel)], rs(500));
      expect(b.postedCount, 0, reason: 'no wallet movement, cumulative unchanged');
    });

    test('settling more than outstanding becomes an advance on that operator only', () async {
      await settle(rs(1500), 0);
      final s = await svc.settlement(shop);
      expect(s.account('D1', airtel)!.advancePaise, rs(500));
      expect(s.outstandingPaise, rs(300));
      expect(s.advancePaise, rs(500));
    });

    test('adjustment above total and unknown distributor are refused', () async {
      expect(() => settle(rs(100), rs(200)), throwsA(isA<AccountingException>()));
      await expectLater(
          svc.agentSettlement(
              shopId: shop, actor: owner, distributorId: 'NOPE', operator: airtel,
              totalPayablePaise: rs(10), rechargeAdjustmentPaise: 0, paymentMode: 'cash',
              paymentDate: now),
          throwsA(predicate((e) => e is AccountingException && e.code == 'UNKNOWN_DISTRIBUTOR')));
    });

    test('double tap posts once (same form, concurrent)', () async {
      final rr = await Future.wait([settle(rs(400), rs(100)), settle(rs(400), rs(100))]);
      expect(rr.where((r) => r.replayed).length, 1);
      final s = await svc.settlement(shop);
      expect(s.account('D1', airtel)!.balancePaise, rs(600));
      expect(b.cashBankVouchers.length, 1);
    });

    test('network failure then retry reuses the key and posts once', () async {
      b.failNextPosting = true;
      await expectLater(settle(rs(200), 0), throwsA(isA<AccountingException>()));
      await settle(rs(200), 0);
      final s = await svc.settlement(shop);
      expect(s.account('D1', airtel)!.balancePaise, rs(800));
    });
  });

  group('agent return', () {
    test('return up to the pending amount, never more', () async {
      await settle(rs(1000), rs(500));
      Future<PostingResult> ret(int p) => svc.agentReturn(
          shopId: shop, actor: owner, distributorId: 'D1', operator: airtel,
          returnPaise: p, returnMode: 'UPI', returnDate: now);
      await expectLater(ret(rs(600)),
          throwsA(predicate((e) => e is AccountingException && e.code == 'EXCEEDS_PENDING_RETURN')));
      final r1 = await ret(rs(200));
      expect(r1.data['pendingReturnPaise'], rs(300));
      final r2 = await ret(rs(300));
      expect(r2.data['pendingReturnPaise'], 0);
      expect(b.cashBankVouchers.where((v) => (v['paise'] as int) > 0).length, 2);
      final s = await svc.settlement(shop);
      expect(s.account('D1', airtel)!.balancePaise, 0, reason: 'returns do not touch the payable');
    });

    test('a return on another operator has nothing pending', () async {
      await settle(rs(1000), rs(500));
      await expectLater(
          svc.agentReturn(
              shopId: shop, actor: owner, distributorId: 'D1', operator: jio,
              returnPaise: rs(1), returnMode: 'cash', returnDate: now),
          throwsA(isA<AccountingException>()));
    });
  });

  group('distributor credit reversal', () {
    test('reduces the payable of that operator; capped at the credit; reason required', () async {
      await expectLater(
          svc.distributorCreditReversal(
              shopId: shop, actor: owner, distributorId: 'D1', operator: airtel,
              amountPaise: rs(100), reason: ' '),
          throwsA(isA<AccountingException>()));
      await expectLater(
          svc.distributorCreditReversal(
              shopId: shop, actor: owner, distributorId: 'D1', operator: airtel,
              amountPaise: rs(1001), reason: 'wrong load'),
          throwsA(predicate((e) => e is AccountingException && e.code == 'EXCEEDS_PAYABLE')));
      await svc.distributorCreditReversal(
          shopId: shop, actor: owner, distributorId: 'D1', operator: airtel,
          amountPaise: rs(250), reason: 'wrong load');
      final s = await svc.settlement(shop);
      expect(s.account('D1', airtel)!.outstandingPaise, rs(750));
      expect(s.account('D1', jio)!.outstandingPaise, rs(300));
    });
  });

  group('customer refund', () {
    setUp(() {
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'R1', operator: jio, amountPaise: rs(299)));
      b.seedRecharge(LocalRechargeRecord(
          rechargeId: 'R2', operator: jio, amountPaise: rs(100), paymentCollected: false));
    });

    Future<PostingResult> refund(String id, int p, {AccountingActor actor = owner}) =>
        svc.customerRefund(
            shopId: shop, actor: actor, rechargeId: id, refundPaise: p,
            refundMethod: 'cash', reason: 'customer request');

    test('refunds once, never more than the recharge, no wallet movement', () async {
      await expectLater(refund('R1', rs(300)),
          throwsA(predicate((e) => e is AccountingException && e.code == 'EXCEEDS_RECHARGE')));
      final r = await refund('R1', rs(299));
      expect(r.data['status'], 'refunded');
      expect(b.recharge('R1')!.status, 'refunded');
      expect(b.postedCount, 0);
      await expectLater(refund('R1', rs(1)),
          throwsA(predicate((e) => e is AccountingException && e.code == 'ALREADY_REFUNDED')));
    });

    test('no customer payment collected -> refused', () async {
      await expectLater(refund('R2', rs(100)),
          throwsA(predicate((e) => e is AccountingException && e.code == 'PAYMENT_NOT_COLLECTED')));
    });

    test('refund never lowers cumulative (gross) volume', () {
      final t = DateTime.utc(2026, 11, 19, 6);
      final v = computeVolume([
        VolumeTxn(id: 'R1', operator: jio, faceValuePaise: rs(299), status: RechargeStatus.refunded,
            at: t, refundPaise: rs(299), refundAt: t),
      ], IstRange(DateTime.utc(2000), DateTime.utc(2100)));
      expect(v.grossPaise, rs(299));
      expect(v.refundsPaise, rs(299));
    });
  });

  group('failed-recharge reversal', () {
    setUp(() {
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'P1', operator: airtel, amountPaise: rs(199), status: 'pending'));
      b.seedRecharge(LocalRechargeRecord(
          rechargeId: 'P2', operator: airtel, amountPaise: rs(99), status: 'pending', walletDebited: false));
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'P3', operator: airtel, amountPaise: rs(50), status: 'refunded'));
    });

    Future<PostingResult> fail(String id) =>
        svc.failedRechargeReversal(shopId: shop, actor: owner, rechargeId: id, reason: 'operator failed');

    test('debited wallet credited back exactly once', () async {
      final r = await fail('P1');
      expect(r.data['walletCreditPaise'], rs(199));
      final again = await fail('P1');
      expect(again.data['alreadyFailed'], true);
      expect(b.postedMovements.where((m) => m.kind == WalletMovementKind.refundCredit).length, 1);
    });

    test('not debited -> no wallet credit; refunded -> refused', () async {
      final r = await fail('P2');
      expect(r.data['walletCreditPaise'], 0);
      expect(b.postedCount, 0);
      await expectLater(fail('P3'),
          throwsA(predicate((e) => e is AccountingException && e.code == 'INVALID_STATUS')));
    });
  });

  group('commission reversal', () {
    setUp(() {
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'C1', operator: jio, amountPaise: rs(299)));
      b.seedCommission('C1', rs(8));
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'C2', operator: jio, amountPaise: rs(99)));
    });

    test('amount comes from the server record; once; unknown refused', () async {
      final r = await svc.commissionReversal(
          shopId: shop, actor: owner, rechargeId: 'C1', clawbackFromWallet: true, reason: 'reversed');
      expect(r.data['commissionPaise'], rs(8));
      expect(b.postedMovements.single.kind, WalletMovementKind.commissionClawback);
      // new form after the first was confirmed -> new key -> refused as duplicate
      await expectLater(
          svc.commissionReversal(
              shopId: shop, actor: owner, rechargeId: 'C1', clawbackFromWallet: false, reason: 'again'),
          throwsA(predicate((e) => e is AccountingException && e.code == 'ALREADY_REVERSED')));
      await expectLater(
          svc.commissionReversal(
              shopId: shop, actor: owner, rechargeId: 'C2', clawbackFromWallet: false, reason: 'x'),
          throwsA(predicate((e) => e is AccountingException && e.code == 'UNKNOWN_COMMISSION')));
    });
  });

  group('owner-only, online-only', () {
    test('staff is refused on all six postings before anything is sent', () async {
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'S1', operator: jio, amountPaise: rs(10)));
      final calls = <Future<Object?> Function()>[
        () => settle(rs(10), 0, actor: staff),
        () => svc.agentReturn(shopId: shop, actor: staff, distributorId: 'D1', operator: airtel,
            returnPaise: rs(1), returnMode: 'cash', returnDate: now),
        () => svc.distributorCreditReversal(shopId: shop, actor: staff, distributorId: 'D1',
            operator: airtel, amountPaise: rs(1), reason: 'x'),
        () => svc.customerRefund(shopId: shop, actor: staff, rechargeId: 'S1', refundPaise: rs(1),
            refundMethod: 'cash', reason: 'x'),
        () => svc.failedRechargeReversal(shopId: shop, actor: staff, rechargeId: 'S1', reason: 'x'),
        () => svc.commissionReversal(shopId: shop, actor: staff, rechargeId: 'S1',
            clawbackFromWallet: false, reason: 'x'),
      ];
      for (final c in calls) {
        await expectLater(c(),
            throwsA(predicate((e) => e is AccountingException && e.code == 'PERMISSION_DENIED')));
      }
      expect(b.auditLog, isEmpty);
    });

    test('offline -> blocked, nothing saved', () async {
      svc.isOnline = () async => false;
      await expectLater(settle(rs(10), 0),
          throwsA(predicate((e) => e is AccountingException && e.code == 'OFFLINE')));
      expect(b.auditLog, isEmpty);
    });
  });

  group('RechargeService routing', () {
    tearDown(() => RechargeBackendBridge.configure(mode: RechargeBackendMode.localTestMock));

    test('outside localTestMock the legacy methods post through the accounting backend', () async {
      RechargeBackendBridge.configure(mode: RechargeBackendMode.supabaseEdgeFunction);
      final rs0 = RechargeService.instance..resetLocalCacheForTesting();
      final res = await rs0.recordAgentSettlement(
        shopId: shop, distributorId: 'D1', totalPayable: 1000, rechargeAdjustment: 500,
        paymentMode: 'CASH', staffId: 'owner1', staffName: 'Owner', operator: airtel, actor: owner,
      );
      expect(res.actualPayment, 500.0);
      expect(res.pendingReturn, 500.0);
      expect(b.auditLog.single['action'], 'AGENT_SETTLEMENT');

      final ret = await rs0.recordRechargeAmountReturn(
        shopId: shop, distributorId: 'D1', returnAmount: 200, returnMode: 'UPI',
        staffId: 'owner1', staffName: 'Owner', operator: airtel, actor: owner,
      );
      expect(ret.remainingPendingReturn, 300.0);
      expect(b.auditLog.last['action'], 'AGENT_RETURN');
    });

    test('server not configured -> fails closed, nothing written locally', () async {
      svc.useBackendForTesting(null);
      RechargeBackendBridge.configure(mode: RechargeBackendMode.supabaseEdgeFunction);
      final rs0 = RechargeService.instance..resetLocalCacheForTesting();
      await expectLater(
          rs0.recordAgentSettlement(
            shopId: shop, distributorId: 'D1', totalPayable: 10, rechargeAdjustment: 0,
            paymentMode: 'CASH', staffId: 'owner1', staffName: 'Owner', operator: airtel, actor: owner,
          ),
          throwsA(predicate((e) => e is AccountingException && e.code == 'SERVER_UNAVAILABLE')));
      expect(rs0.getLocalDistributorLedger(), isEmpty);
    });
  });
}
