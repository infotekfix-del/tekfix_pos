// Quick Recharge: change the source of an already-posted top-up from own
// money to distributor credit (two classified postings, own idempotency
// keys, safe retry). In-memory LocalAccountingBackend only.
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
const airtel = RechargeOperator.airtel;

int rs(num r) => (r * 100).round();

void main() {
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('tekfix_reclass_');
    Hive.init(dir.path);
  });

  late LocalAccountingBackend b;
  final svc = RechargeAccountingService.instance;

  /// Closing 500 last night; morning 2,500; the 2,000 was classified as own money.
  Future<void> seedMistake() async {
    b.seedClosing(VerifiedClosing(
        operator: airtel, actualPaise: rs(500),
        at: DateTime.now().subtract(const Duration(hours: 10)), periodId: 'p0'));
    final st = (await svc.periodState(shop))[airtel]!;
    await svc.verifyMorning(
        shopId: shop, actor: owner, operator: airtel, morningActualPaise: rs(2500), periodId: st.periodId);
    await svc.postClassified(
        shopId: shop, actor: owner, operator: airtel, category: UnexplainedCategory.topUpOwn,
        amountPaise: rs(2000), reason: 'morning', transactionDate: DateTime.now(), periodId: st.periodId);
  }

  setUp(() async {
    svc.resetForTesting();
    svc.pendingKeys = PendingPostingKeys(memoryOnly: true);
    svc.isOnline = () async => true;
    b = LocalAccountingBackend();
    svc.useBackendForTesting(b);
    b.seedDistributor('D1', 'Apex Airtel', defaultOperator: airtel);
    await seedMistake();
  });

  tearDown(() => svc.resetForTesting());

  Future<({PostingResult correction, PostingResult credit})> reclass(String dist,
          {AccountingActor actor = owner, int? paise}) =>
      svc.reclassifyOwnTopUpToDistributor(
          shopId: shop, actor: actor, operator: airtel, amountPaise: paise ?? rs(2000),
          distributorId: dist, reason: 'was distributor credit');

  int sumOf(WalletMovementKind k) => b.postedMovements
      .where((m) => m.kind == k)
      .fold(0, (a, m) => a + m.amountPaise);

  test('moves 2,000 own -> distributor; wallet total and expected closing unchanged', () async {
    final before = (await svc.periodState(shop))[airtel]!.closing().expectedClosingPaise;
    await reclass('D1');
    expect(sumOf(WalletMovementKind.adjustment), -rs(2000));
    expect(sumOf(WalletMovementKind.creditLoad), rs(2000));
    final st = (await svc.periodState(shop))[airtel]!;
    expect(st.closing().expectedClosingPaise, before, reason: 'wallet total unchanged');
    expect(st.morning!.remainingPaise, 0, reason: 'morning stays fully classified');
    final s = await svc.settlement(shop);
    expect(s.account('D1', airtel)!.outstandingPaise, rs(2000), reason: 'distributor dues +2,000');
  });

  test('step 2 failure is reported; retry finishes without posting step 1 twice', () async {
    await expectLater(reclass('D2'),
        throwsA(predicate((e) => e is AccountingException && e.code == 'RECLASSIFY_INCOMPLETE')));
    expect(sumOf(WalletMovementKind.adjustment), -rs(2000));
    expect(await svc.reclassifyPending(
        shopId: shop, operator: airtel, amountPaise: rs(2000), distributorId: 'D2'), isTrue);

    b.seedDistributor('D2', 'Other Airtel', defaultOperator: airtel);
    final r = await reclass('D2');
    expect(r.correction.replayed, isTrue);
    expect(sumOf(WalletMovementKind.adjustment), -rs(2000), reason: 'step 1 posted once');
    expect(sumOf(WalletMovementKind.creditLoad), rs(2000));
    expect(await svc.reclassifyPending(
        shopId: shop, operator: airtel, amountPaise: rs(2000), distributorId: 'D2'), isFalse);
  });

  test('two 1,000 entries can be moved one by one', () async {
    await reclass('D1', paise: rs(1000));
    await reclass('D1', paise: rs(1000));
    expect(sumOf(WalletMovementKind.creditLoad), rs(2000));
    expect((await svc.settlement(shop)).account('D1', airtel)!.outstandingPaise, rs(2000));
  });

  test('a later identical move after a confirmed one gets new keys (posts again)', () async {
    await reclass('D1', paise: rs(500));
    await reclass('D1', paise: rs(500));
    expect(sumOf(WalletMovementKind.adjustment), -rs(1000));
  });

  test('staff refused and offline blocked before anything is posted', () async {
    final count = b.postedCount;
    await expectLater(reclass('D1', actor: staff),
        throwsA(predicate((e) => e is AccountingException && e.code == 'PERMISSION_DENIED')));
    svc.isOnline = () async => false;
    await expectLater(reclass('D1'),
        throwsA(predicate((e) => e is AccountingException && e.code == 'OFFLINE')));
    expect(b.postedCount, count);
  });
}
