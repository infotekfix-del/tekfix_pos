// Distributor refill commission (owner rule 2026-11-21): a refill of
// Rs 1,039 = Rs 1,000 payable to the agent + Rs 39 commission (profit).
// In-memory LocalAccountingBackend only.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_backend.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_service.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_period_accounting.dart';
import 'package:tekfix_erp_pos/recharge/wallet_distributor_dialogs.dart';

const owner = AccountingActor(uid: 'owner1', name: 'Owner', isOwner: true);
const staff = AccountingActor(uid: 'staff1', name: 'Staff', isOwner: false);
const shop = 'shop_test';
const airtel = RechargeOperator.airtel;

int rs(num r) => (r * 100).round();

void main() {
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('tekfix_topup_comm_');
    Hive.init(dir.path);
  });

  test('3.9%: 1,039 -> 39; 2,078 -> 78; never negative', () {
    expect(topUpCommissionPaise(rs(1039), kDefaultTopUpCommissionBp), rs(39));
    expect(topUpCommissionPaise(rs(2078), kDefaultTopUpCommissionBp), rs(78));
    expect(topUpCommissionPaise(rs(519.50), kDefaultTopUpCommissionBp), rs(19.50));
    expect(topUpCommissionPaise(0, kDefaultTopUpCommissionBp), 0);
  });

  test('top-up distributor follows the operator (Jio -> Kochi Jio, not Apex)', () {
    expect(distributorIdForOperator(RechargeOperator.jio, 'DIST_APEX_AIRTEL'), 'DIST_JIO_AGENCY');
    expect(distributorIdForOperator(RechargeOperator.airtel, 'X'), 'DIST_APEX_AIRTEL');
    expect(distributorIdForOperator(RechargeOperator.vi, 'X'), 'DIST_MURUGAN_VI');
    expect(distributorIdForOperator(RechargeOperator.bsnl, 'X'), 'DIST_BSNL_CSC');
    expect(distributorIdForOperator(RechargeOperator.other, 'KEEP'), 'KEEP');
  });

  group('accounting', () {
    late LocalAccountingBackend b;
    final svc = RechargeAccountingService.instance;
    late String pid;

    setUp(() async {
      svc.resetForTesting();
      svc.pendingKeys = PendingPostingKeys(memoryOnly: true);
      svc.isOnline = () async => true;
      b = LocalAccountingBackend();
      svc.useBackendForTesting(b);
      b.seedDistributor('APEX', 'Apex Telecom', defaultOperator: airtel);
      b.seedClosing(VerifiedClosing(
          operator: airtel, actualPaise: rs(500),
          at: DateTime.now().subtract(const Duration(hours: 10)), periodId: 'p0'));
      pid = (await svc.periodState(shop))[airtel]!.periodId;
    });

    tearDown(() => svc.resetForTesting());

    test('morning refill 1,039: dues 1,000, commission 39, pay 1,000 -> nothing left', () async {
      await svc.verifyMorning(
          shopId: shop, actor: owner, operator: airtel, morningActualPaise: rs(1539), periodId: pid);
      await svc.postDistributorCreditWithCommission(
          shopId: shop, actor: owner, operator: airtel, receivedPaise: rs(1039),
          commissionPaise: rs(39), distributorId: 'APEX', reason: 'auto refill', periodId: pid);

      final st = (await svc.periodState(shop))[airtel]!;
      expect(st.morning!.remainingPaise, 0);
      expect(st.closing().expectedClosingPaise, rs(1539), reason: 'wallet gets the full 1,039');
      expect((await svc.settlement(shop)).account('APEX', airtel)!.outstandingPaise, rs(1000));
      expect((await svc.topUpCommissionSummary(shop)).totalPaise, rs(39));

      await svc.distributorPayment(
          shopId: shop, actor: owner, distributorId: 'APEX', operator: airtel,
          amountPaise: rs(1000), paymentMode: 'cash', paymentDate: DateTime.now());
      final s = await svc.settlement(shop);
      expect(s.account('APEX', airtel)!.outstandingPaise, 0);
      expect(s.account('APEX', airtel)!.advancePaise, 0);
    });

    test('commission must be less than the amount received', () async {
      await svc.verifyMorning(
          shopId: shop, actor: owner, operator: airtel, morningActualPaise: rs(1539), periodId: pid);
      await expectLater(
          svc.postDistributorCreditWithCommission(
              shopId: shop, actor: owner, operator: airtel, receivedPaise: rs(1039),
              commissionPaise: rs(1039), distributorId: 'APEX', reason: 'x', periodId: pid),
          throwsA(predicate((e) => e is AccountingException && e.code == 'INVALID_COMMISSION')));
      expect(b.postedCount, 0);
    });

    test('mid-day commission credit: profit, not payable, morning untouched', () async {
      await svc.verifyMorning(
          shopId: shop, actor: owner, operator: airtel, morningActualPaise: rs(500), periodId: pid);
      final before = (await svc.periodState(shop))[airtel]!;
      await svc.topUpCommission(
          shopId: shop, actor: owner, operator: airtel, distributorId: 'APEX',
          commissionPaise: rs(39), formTag: 't1');
      final after = (await svc.periodState(shop))[airtel]!;
      expect(after.morning!.remainingPaise, before.morning!.remainingPaise);
      expect(after.closing().expectedClosingPaise, before.closing().expectedClosingPaise + rs(39));
      expect((await svc.settlement(shop)).account('APEX', airtel), isNull,
          reason: 'commission is never payable');
      expect((await svc.topUpCommissionSummary(shop)).byOperator(airtel), rs(39));
    });

    test('staff refused; same form posts once', () async {
      await expectLater(
          svc.topUpCommission(
              shopId: shop, actor: staff, operator: airtel, commissionPaise: rs(39), formTag: 't'),
          throwsA(predicate((e) => e is AccountingException && e.code == 'PERMISSION_DENIED')));
      final r = await Future.wait([
        svc.topUpCommission(shopId: shop, actor: owner, operator: airtel, commissionPaise: rs(39), formTag: 't2'),
        svc.topUpCommission(shopId: shop, actor: owner, operator: airtel, commissionPaise: rs(39), formTag: 't2'),
      ]);
      expect(r.where((x) => x.replayed).length, 1);
      expect((await svc.topUpCommissionSummary(shop)).totalPaise, rs(39));
    });
  });
}
