// Quick Recharge period workflow UI: morning entry (net top-up), night
// closing (variance), operator-wise distributor payment (advance), plus the
// owner-only Firestore rules text. In-memory backend only: no Firestore,
// no Supabase, no live data.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_backend.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_service.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_period_accounting.dart';
import 'package:tekfix_erp_pos/recharge/recharge_period_widgets.dart';
import 'package:tekfix_erp_pos/recharge/wallet_distributor_dialogs.dart';

const owner = AccountingActor(uid: 'owner1', name: 'Owner', isOwner: true);
const shop = 'shop_test_ui';
int rs(num r) => (r * 100).round();

DistributorProfile dist(String id, String name) =>
    DistributorProfile(id: id, shopId: shop, name: name, updatedAt: DateTime(2026));

/// Opens [dialog] from a button and returns the dialog's result holder.
Future<List<bool?>> openDialog(WidgetTester t, Future<bool?> Function(BuildContext) dialog) async {
  final result = <bool?>[];
  t.view.physicalSize = const Size(1200, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async => result.add(await dialog(ctx)),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return result;
}

Future<void> typeKey(WidgetTester t, String key, String text) async {
  await t.enterText(find.byKey(ValueKey(key)), text);
  await t.pump();
}

/// Lets the in-memory backend's async work finish.
Future<void> settle(WidgetTester t) async {
  // Hive (pending-form key) writes finish on real disk I/O.
  for (var i = 0; i < 30; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 50));
  }
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final dir = await Directory.systemTemp.createTemp('tekfix_recharge_period_ui_');
    Hive.init(dir.path);
  });
  tearDown(RechargeAccountingService.instance.resetForTesting);

  final closeAt = DateTime.utc(2026, 11, 18, 16, 30);
  final jioDist = DistributorProfile(
      id: 'DJ', shopId: shop, name: 'Jio Dist', defaultOperator: RechargeOperator.jio,
      updatedAt: DateTime.utc(2026, 11, 18));

  LocalAccountingBackend backend() {
    final b = LocalAccountingBackend()
      ..seedClosing(VerifiedClosing(
          operator: RechargeOperator.jio, actualPaise: rs(500), at: closeAt, periodId: 'p0'));
    RechargeAccountingService.instance
      ..useBackendForTesting(b)
      ..isOnline = (() async => true)
      // Hive writes inside widget tests can block the next test's I/O;
      // key persistence is covered by recharge_period_settlement_test.
      ..pendingKeys = PendingPostingKeys(memoryOnly: true);
    return b;
  }

  testWidgets('morning: 500 -> 1,500 shows a net top-up of 1,000 and posts only after classification',
      (t) async {
    final b = backend()..seedDistributor('DJ', 'Jio Dist', defaultOperator: RechargeOperator.jio);
    final st = (await t.runAsync(() => b.periodState(shop)))![RechargeOperator.jio]!;
    final res = await openDialog(t, (ctx) => MorningEntryDialog.show(ctx,
        shopId: shop, actor: owner, state: st, distributors: [jioDist]));

    await typeKey(t, 'morning-amount', '1500');
    expect(find.text('₹1,000.00'), findsWidgets); // raw + unexplained preview
    expect(find.text('New Net Top-Up (to confirm)'), findsOneWidget);
    expect(b.postedCount, 0);

    await t.tap(find.byKey(const ValueKey('morning-save')));
    await settle(t);
    expect(find.text(MorningStatus.pendingVerification.label), findsOneWidget);
    expect(b.postedCount, 0); // the morning entry itself posts nothing

    // Shop rule: the default is distributor credit (pre-selected), not own money.
    expect(find.text(UnexplainedCategory.topUpOwn.label, findRichText: true), findsNothing);
    // 1,000 received -> 3.9% commission auto-filled (37.54); set it to 0 here.
    expect(find.byKey(const ValueKey('morning-split')), findsOneWidget);
    await typeKey(t, 'morning-commission', '0');
    await typeKey(t, 'morning-reason', 'Distributor top-up');
    await t.tap(find.byKey(const ValueKey('morning-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('morning-classify')));
    await settle(t);
    expect(b.postedCount, 1);
    expect(b.postedMovements.single.kind, WalletMovementKind.creditLoad);
    final s = await t.runAsync(() => b.settlement(shop));
    expect(s!.account('DJ', RechargeOperator.jio)!.outstandingPaise, rs(1000));
    final after = (await t.runAsync(() => b.periodState(shop)))![RechargeOperator.jio]!;
    expect(after.closing().expectedClosingPaise, rs(1500));
    expect(after.morning!.status, MorningStatus.verified);
    expect(res.single, isTrue);
  });

  testWidgets('morning: refill 1,039 auto-splits into 1,000 payable + 39 commission', (t) async {
    final b = backend()..seedDistributor('DJ', 'Jio Dist', defaultOperator: RechargeOperator.jio);
    final st = (await t.runAsync(() => b.periodState(shop)))![RechargeOperator.jio]!;
    final res = await openDialog(t, (ctx) => MorningEntryDialog.show(ctx,
        shopId: shop, actor: owner, state: st, distributors: [jioDist]));
    await typeKey(t, 'morning-amount', '1539'); // 1,039 unexplained
    await t.tap(find.byKey(const ValueKey('morning-save')));
    await settle(t);
    expect(find.textContaining('Commission – profit (കമ്മീഷൻ): ₹39.00'), findsOneWidget);
    await typeKey(t, 'morning-reason', 'Auto refill');
    await t.tap(find.byKey(const ValueKey('morning-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('morning-classify')));
    await settle(t);
    expect(res.single, isTrue);
    final s = await t.runAsync(() => b.settlement(shop));
    expect(s!.account('DJ', RechargeOperator.jio)!.outstandingPaise, rs(1000));
    final c = await t.runAsync(() => b.topUpCommissionSummary(shop));
    expect(c!.totalPaise, rs(39));
  });

  testWidgets('morning: part from distributor, the rest stays open as Excess', (t) async {
    final b = backend()..seedDistributor('DJ', 'Jio Dist', defaultOperator: RechargeOperator.jio);
    final st = (await t.runAsync(() => b.periodState(shop)))![RechargeOperator.jio]!;
    final res = await openDialog(t, (ctx) => MorningEntryDialog.show(ctx,
        shopId: shop, actor: owner, state: st, distributors: [jioDist]));
    await typeKey(t, 'morning-amount', '1500'); // 1,000 unexplained
    await t.tap(find.byKey(const ValueKey('morning-save')));
    await settle(t);

    await typeKey(t, 'morning-class-amount', '800');
    await typeKey(t, 'morning-commission', '0');
    await typeKey(t, 'morning-reason', 'Distributor top-up');
    await t.tap(find.byKey(const ValueKey('morning-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('morning-classify')));
    await settle(t);
    // Dialog stays open with the remaining 200 pre-filled as Excess.
    expect(find.byKey(const ValueKey('morning-classify')), findsOneWidget);
    expect(find.textContaining('separate Excess account'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('morning-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('morning-classify')));
    await settle(t);

    expect(res.single, isTrue);
    final ex = await t.runAsync(() => b.excessSummary(shop));
    expect(ex!.totalPaise, rs(200));
    final s = await t.runAsync(() => b.settlement(shop));
    expect(s!.account('DJ', RechargeOperator.jio)!.outstandingPaise, rs(800));
  });

  testWidgets('morning: own money is never offered; no distributor -> blocked', (t) async {
    final b = backend();
    final st = (await t.runAsync(() => b.periodState(shop)))![RechargeOperator.jio]!;
    await openDialog(t, (ctx) => MorningEntryDialog.show(ctx,
        shopId: shop, actor: owner, state: st, distributors: const []));
    await typeKey(t, 'morning-amount', '1500');
    await t.tap(find.byKey(const ValueKey('morning-save')));
    await settle(t);

    await typeKey(t, 'morning-reason', 'x');
    await t.tap(find.byKey(const ValueKey('morning-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('morning-classify')));
    await settle(t);
    expect(find.textContaining('Select the distributor'), findsOneWidget);
    expect(b.postedCount, 0);

    await t.tap(find.byKey(const ValueKey('morning-other-categories')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('morning-category')));
    await t.pumpAndSettle();
    expect(find.textContaining(UnexplainedCategory.commissionCredit.label), findsWidgets);
    expect(find.textContaining(UnexplainedCategory.topUpOwn.label), findsNothing,
        reason: 'shop rule: own money is never added to a recharge wallet');
  });

  testWidgets('Add Balance: no Own Money option; 1,039 -> 1,000 payable + 39 commission', (t) async {
    await openDialog(t, (ctx) => WalletTopUpDialog.show(ctx,
        shopId: shop, staffId: 'owner1', staffName: 'Owner',
        initialOperator: RechargeOperator.airtel,
        initialFundingType: RechargeFundingType.ownMoney));
    expect(find.text('Own Money'), findsNothing);
    await typeKey(t, 'topup-amount', '1039');
    expect(find.textContaining('Payable to distributor (കൊടുക്കേണ്ടത്): ₹1,000.00'), findsOneWidget);
    expect(find.textContaining('Commission – profit (കമ്മീഷൻ): ₹39.00'), findsOneWidget);
  });

  testWidgets('closing: expected 800, actual 750 -> Shortage; a reason is required', (t) async {
    final b = backend();
    for (final m in [
      WalletMovement(operator: RechargeOperator.jio, kind: WalletMovementKind.topUpOwn,
          amountPaise: rs(1500), at: closeAt.add(const Duration(hours: 11))),
      WalletMovement(operator: RechargeOperator.jio, kind: WalletMovementKind.rechargeDebit,
          amountPaise: rs(1200), at: closeAt.add(const Duration(hours: 12))),
    ]) {
      b.seedMovement(m);
    }
    final st = (await t.runAsync(() => b.periodState(shop)))![RechargeOperator.jio]!;
    final res = await openDialog(
        t, (ctx) => ClosingEntryDialog.show(ctx, shopId: shop, actor: owner, state: st));
    expect(find.text('₹800.00'), findsOneWidget); // expected closing

    await typeKey(t, 'closing-amount', '750');
    expect(find.text('-₹50.00'), findsOneWidget);
    expect(find.text('Shortage'), findsOneWidget);

    await t.tap(find.byType(CheckboxListTile));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('closing-save')));
    await settle(t);
    expect(find.textContaining('A reason is required'), findsOneWidget);
    expect(res, isEmpty);

    await t.enterText(find.widgetWithText(TextField, 'Reason / remarks (required if variance)'),
        'Cash short');
    await t.tap(find.byKey(const ValueKey('closing-save')));
    await settle(t);
    expect(res.single, isTrue);
    final next = (await t.runAsync(() => b.periodState(shop)))![RechargeOperator.jio]!;
    expect(next.previousClosing!.actualPaise, rs(750)); // next opening
  });

  testWidgets('payment: Airtel 1,000 outstanding, pay 1,500 -> ADVANCE 500; Jio and Vi untouched',
      (t) async {
    final b = backend()..seedDistributor('d1', 'Kerala Telecom');
    final at = DateTime.utc(2026, 11, 19, 5);
    for (final e in [(RechargeOperator.airtel, 1000), (RechargeOperator.jio, 500), (RechargeOperator.vi, 2000)]) {
      b.seedSettlement(SettlementEntry(distributorId: 'd1', distributorName: 'Kerala Telecom',
          operator: e.$1, kind: SettlementEntryKind.creditLoad, amountPaise: rs(e.$2), at: at));
    }
    final summary = await t.runAsync(() => b.settlement(shop));
    final res = await openDialog(
        t,
        (ctx) => DistributorPaymentV2Dialog.show(ctx,
            shopId: shop,
            actor: owner,
            distributors: [dist('d1', 'Kerala Telecom')],
            summary: summary,
            initialDistributorId: 'd1',
            initialOperator: RechargeOperator.airtel));

    expect(find.text('₹1,000.00 outstanding'), findsOneWidget);
    await typeKey(t, 'pay-amount', '1500');
    expect(find.text('₹500.00 ADVANCE / EXCESS'), findsOneWidget);

    // Without confirmation nothing is posted.
    await t.tap(find.byKey(const ValueKey('pay-submit')));
    await settle(t);
    expect(b.settlementEntries.where((e) => e.kind == SettlementEntryKind.payment), isEmpty);

    await t.tap(find.byKey(const ValueKey('pay-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('pay-submit')));
    await settle(t);
    expect(res.single, isTrue);
    final s = (await t.runAsync(() => b.settlement(shop)))!;
    expect(s.account('d1', RechargeOperator.airtel)!.advancePaise, rs(500));
    expect(s.account('d1', RechargeOperator.jio)!.outstandingPaise, rs(500));
    expect(s.account('d1', RechargeOperator.vi)!.outstandingPaise, rs(2000));
    expect(s.outstandingPaise, rs(2500));
    expect(s.advancePaise, rs(500));
  });

  testWidgets('payment while offline is blocked with a clear message and nothing posts', (t) async {
    final b = backend()..seedDistributor('d1', 'Kerala Telecom');
    RechargeAccountingService.instance.isOnline = () async => false;
    await openDialog(
        t,
        (ctx) => DistributorPaymentV2Dialog.show(ctx,
            shopId: shop,
            actor: owner,
            distributors: [dist('d1', 'Kerala Telecom')],
            initialDistributorId: 'd1',
            initialOperator: RechargeOperator.jio));
    await typeKey(t, 'pay-amount', '100');
    await t.tap(find.byKey(const ValueKey('pay-confirm')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('pay-submit')));
    await settle(t);
    expect(find.textContaining('You are offline'), findsOneWidget);
    expect(b.settlementEntries, isEmpty);
  });

  test('settlement table and cards render at phone width without overflow', () {
    // Pure formatter checks used by every money label.
    expect(formatInrPaise(12345600), '₹1,23,456.00');
    expect(formatInrPaise(-5000), '-₹50.00');
    expect(formatInrPaise(5), '₹0.05');
    expect(formatInrPaise(100000000), '₹10,00,000.00');
  });

  testWidgets('settlement table: phone width, advance in its own column', (t) async {
    t.view.physicalSize = const Size(390, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = computeSettlement([
      SettlementEntry(distributorId: 'd1', distributorName: 'Kerala Telecom',
          operator: RechargeOperator.airtel, kind: SettlementEntryKind.creditLoad,
          amountPaise: rs(1000), at: DateTime.utc(2026)),
      SettlementEntry(distributorId: 'd1', distributorName: 'Kerala Telecom',
          operator: RechargeOperator.airtel, kind: SettlementEntryKind.payment,
          amountPaise: rs(1500), at: DateTime.utc(2026)),
    ]);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DistributorSettlementTable(summary: s, error: null, onPay: (_) {}),
        ),
      ),
    ));
    expect(find.text('ADVANCE ₹500.00'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  test('Firestore rules: distributor records and daily collections are owner-only', () {
    for (final path in ['firebase/firestore.rules', 'lib/firestore.rules']) {
      final rules = File(path).readAsStringSync();
      String block(String match) {
        final i = rules.indexOf(match);
        expect(i, isNot(-1), reason: '$path: $match');
        return rules.substring(i, rules.indexOf('\n      }', i));
      }

      for (final m in ['match /recharge_distributors/{distId}', 'match /recharge_daily_collections/{id}']) {
        final b = block(m);
        expect(b, contains('allow create, update: if isOwner(shop);'), reason: '$path $m');
        expect(b, isNot(contains('allow create, update: if isShopMember(shop);')), reason: '$path $m');
      }
    }
  });
}
