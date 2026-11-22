// Quick Recharge Excess account (owner rule 2026-11-21): extra morning
// balance = distributor credit; the rest = Excess; positive closing
// variance = Excess; a shortage is only shown. Excess is never own money
// or profit. In-memory LocalAccountingBackend only.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_backend.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_service.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_period_accounting.dart';

const owner = AccountingActor(uid: 'owner1', name: 'Owner', isOwner: true);
const shop = 'shop_test';
const airtel = RechargeOperator.airtel;

int rs(num r) => (r * 100).round();

void main() {
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('tekfix_excess_');
    Hive.init(dir.path);
  });

  late LocalAccountingBackend b;
  final svc = RechargeAccountingService.instance;
  late String pid;

  setUp(() async {
    svc.resetForTesting();
    svc.pendingKeys = PendingPostingKeys(memoryOnly: true);
    svc.isOnline = () async => true;
    b = LocalAccountingBackend();
    svc.useBackendForTesting(b);
    b.seedDistributor('D1', 'Apex Airtel', defaultOperator: airtel);
    b.seedClosing(VerifiedClosing(
        operator: airtel, actualPaise: rs(500),
        at: DateTime.now().subtract(const Duration(hours: 10)), periodId: 'p0'));
    pid = (await svc.periodState(shop))[airtel]!.periodId;
    // Morning 2,500 after a 500 closing: 2,000 unexplained.
    await svc.verifyMorning(
        shopId: shop, actor: owner, operator: airtel, morningActualPaise: rs(2500), periodId: pid);
  });

  tearDown(() => svc.resetForTesting());

  Future<PostingResult> classify(UnexplainedCategory c, int paise, {String? dist}) =>
      svc.postClassified(
          shopId: shop, actor: owner, operator: airtel, category: c, amountPaise: paise,
          reason: 'test', transactionDate: DateTime.now(), distributorId: dist, periodId: pid);

  test('1,500 from distributor + 500 excess: dues 1,500, Excess 500, own money untouched', () async {
    await classify(UnexplainedCategory.topUpDistributorCredit, rs(1500), dist: 'D1');
    await classify(UnexplainedCategory.excess, rs(500));
    final st = (await svc.periodState(shop))[airtel]!;
    expect(st.morning!.remainingPaise, 0);
    expect(st.morning!.status, MorningStatus.verified);
    expect((await svc.settlement(shop)).account('D1', airtel)!.outstandingPaise, rs(1500));
    final ex = await svc.excessSummary(shop);
    expect(ex.totalPaise, rs(500));
    expect(ex.bySource(ExcessSource.morning), rs(500));
    expect(b.postedMovements.where((m) => m.kind == WalletMovementKind.topUpOwn), isEmpty,
        reason: 'excess is not own money');
    expect(b.postedMovements.where((m) => m.kind == WalletMovementKind.commissionCredit), isEmpty,
        reason: 'excess is not profit');
    expect(st.closing().expectedClosingPaise, rs(2500));
  });

  test('excess is capped by the unexplained amount and must be positive', () async {
    await expectLater(classify(UnexplainedCategory.excess, rs(2001)),
        throwsA(predicate((e) => e is AccountingException && e.code == 'EXCEEDS_UNEXPLAINED')));
    await expectLater(classify(UnexplainedCategory.excess, -rs(10)),
        throwsA(predicate((e) => e is AccountingException && e.code == 'INVALID_AMOUNT')));
    expect(UnexplainedCategory.excess.isAdjustment, isFalse);
  });

  test('closing above expected -> Excess account; below -> shortage only shown', () async {
    await classify(UnexplainedCategory.topUpDistributorCredit, rs(2000), dist: 'D1');
    // expected 2,500; actual 2,600 -> excess 100
    final r = await svc.verifyClosing(
        shopId: shop, actor: owner, operator: airtel, actualPaise: rs(2600), periodId: pid,
        reason: 'counted');
    expect(r.data['status'], VarianceStatus.excess.name);
    var ex = await svc.excessSummary(shop);
    expect(ex.bySource(ExcessSource.closing), rs(100));
    expect(ex.byOperator(airtel), rs(100));

    // Next period: no movements, expected 2,600; actual 2,550 -> shortage, no excess.
    final pid2 = (await svc.periodState(shop))[airtel]!.periodId;
    final r2 = await svc.verifyClosing(
        shopId: shop, actor: owner, operator: airtel, actualPaise: rs(2550), periodId: pid2,
        reason: 'short');
    expect(r2.data['status'], VarianceStatus.shortage.name);
    ex = await svc.excessSummary(shop);
    expect(ex.totalPaise, rs(100), reason: 'shortage never reduces the Excess account');
    expect(b.postedCount, 1, reason: 'a shortage posts nothing');
  });
}
