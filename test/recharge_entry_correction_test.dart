// Owner edit of a saved recharge (2026-11-22): details edit (mobile, Cash <-> UPI)
// and correction (wrong amount / operator). LocalAccountingBackend + temporary
// Hive only: no Firestore, no Supabase, no live data.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart' show Db, boxParties, boxRecharges;
import 'package:tekfix_erp_pos/recharge/recharge_accounting_backend.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_service.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/recharge_edit_dialog.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_period_accounting.dart';

const owner = AccountingActor(uid: 'owner1', name: 'Owner', isOwner: true);
const staff = AccountingActor(uid: 'staff1', name: 'Staff', isOwner: false);
const shop = 'shop_test';
const airtel = RechargeOperator.airtel;

int rs(num r) => (r * 100).round();

bool code(Object? e, String c) => e is AccountingException && e.code == c;

RechargeEntry entry(String id, double amount,
    {RechargeStatus status = RechargeStatus.success,
    RechargePaymentMode mode = RechargePaymentMode.cash,
    String date = '2026-11-22'}) {
  final t = DateTime.utc(2026, 11, 22, 6);
  return RechargeEntry(
    rechargeId: id,
    shopId: shop,
    operator: airtel,
    customerMobile: '9876543210',
    amount: amount,
    amountPaise: rs(amount),
    fundingType: RechargeFundingType.distributorCredit,
    paymentMode: mode,
    status: status,
    staffId: 'o',
    staffName: 'Owner',
    createdAt: t,
    updatedAt: t,
    dateString: date,
    customerPaymentCollected: true,
  );
}

void main() {
  setUpAll(() async {
    RechargeBackendBridge.configure(mode: RechargeBackendMode.localTestMock);
    final dir = await Directory.systemTemp.createTemp('tekfix_recharge_correction_');
    Hive.init(dir.path);
    await Hive.openBox(boxRecharges);
    await Hive.openBox(boxParties);
  });

  late LocalAccountingBackend b;
  final svc = RechargeAccountingService.instance;

  setUp(() async {
    svc.resetForTesting();
    svc.pendingKeys = PendingPostingKeys(memoryOnly: true);
    svc.isOnline = () async => true;
    b = LocalAccountingBackend();
    svc.useBackendForTesting(b);
    await Db.recharges.clear();
    await Db.parties.clear();
  });

  tearDown(() => svc.resetForTesting());

  group('correction (wrong amount / operator)', () {
    test('wallet credited back once; replay and second correction post nothing more', () async {
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'R1', operator: airtel, amountPaise: rs(349)));
      final r = await svc.correctRecharge(shopId: shop, actor: owner, rechargeId: 'R1', reason: 'wrong amount');
      expect(r.data['walletCreditPaise'], rs(349));
      expect(b.recharge('R1')!.status, 'reversed');
      final again = await svc.correctRecharge(shopId: shop, actor: owner, rechargeId: 'R1', reason: 'again');
      expect(again.replayed, true);
      expect(b.postedMovements.where((m) => m.kind == WalletMovementKind.refundCredit).length, 1);
    });

    test('staff refused; pending / refunded refused', () async {
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'R1', operator: airtel, amountPaise: rs(199)));
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'P1', operator: airtel, amountPaise: rs(199), status: 'pending'));
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'F1', operator: airtel, amountPaise: rs(199), status: 'refunded'));
      await expectLater(svc.correctRecharge(shopId: shop, actor: staff, rechargeId: 'R1', reason: 'x'),
          throwsA(predicate((e) => code(e, 'PERMISSION_DENIED'))));
      await expectLater(svc.correctRecharge(shopId: shop, actor: owner, rechargeId: 'P1', reason: 'x'),
          throwsA(predicate((e) => code(e, 'INVALID_STATUS'))));
      await expectLater(svc.correctRecharge(shopId: shop, actor: owner, rechargeId: 'F1', reason: 'x'),
          throwsA(predicate((e) => code(e, 'INVALID_STATUS'))));
      await expectLater(svc.correctRecharge(shopId: shop, actor: owner, rechargeId: 'R1', reason: '  '),
          throwsA(predicate((e) => code(e, 'REASON_REQUIRED'))));
      expect(b.postedCount, 0);
    });

    test('locked after that operator\'s closing is verified', () async {
      final at = DateTime.now().subtract(const Duration(hours: 5));
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'OLD', operator: airtel, amountPaise: rs(199), createdAt: at));
      b.seedClosing(VerifiedClosing(
          operator: airtel, actualPaise: rs(500), at: DateTime.now().subtract(const Duration(hours: 1)),
          periodId: 'p0'));
      await expectLater(svc.correctRecharge(shopId: shop, actor: owner, rechargeId: 'OLD', reason: 'x'),
          throwsA(predicate((e) => code(e, 'LOCKED_PERIOD'))));
      await expectLater(
          svc.editRechargeDetails(
              shopId: shop, actor: owner, rechargeId: 'OLD', customerPhone: '9000000000', reason: 'x'),
          throwsA(predicate((e) => code(e, 'LOCKED_PERIOD'))));
      expect(b.postedCount, 0);
    });
  });

  group('details edit (mobile, Cash <-> UPI)', () {
    setUp(() {
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'R1', operator: airtel, amountPaise: rs(199)));
      b.seedRecharge(LocalRechargeRecord(
          rechargeId: 'D1', operator: airtel, amountPaise: rs(199), paymentMode: 'Credit / Due'));
    });

    test('valid change saved; no wallet movement', () async {
      final r = await svc.editRechargeDetails(
          shopId: shop, actor: owner, rechargeId: 'R1', customerPhone: '9000000001', paymentMode: 'UPI',
          reason: 'typed wrong');
      expect(r.data['customerPhone'], '9000000001');
      expect(r.data['paymentMode'], 'UPI');
      expect(b.postedCount, 0);
    });

    test('bad phone, nothing to change, Credit / Due mode change, staff: all refused', () async {
      Future<PostingResult> edit({String? phone, String? mode, AccountingActor actor = owner, String id = 'R1'}) =>
          svc.editRechargeDetails(
              shopId: shop, actor: actor, rechargeId: id, customerPhone: phone, paymentMode: mode, reason: 'x');
      await expectLater(edit(phone: '12345'), throwsA(predicate((e) => code(e, 'INVALID_PHONE'))));
      await expectLater(edit(), throwsA(predicate((e) => code(e, 'NOTHING_TO_CHANGE'))));
      await expectLater(edit(mode: 'Card'), throwsA(predicate((e) => code(e, 'INVALID_PAYMENT_MODE'))));
      await expectLater(edit(mode: 'Cash', id: 'D1'), throwsA(predicate((e) => code(e, 'INVALID_PAYMENT_MODE'))));
      await expectLater(edit(phone: '9000000001', actor: staff),
          throwsA(predicate((e) => code(e, 'PERMISSION_DENIED'))));
    });
  });

  group('totals and Daily Register', () {
    test('a corrected entry is not counted anywhere', () {
      final corrected = entry('C1', 349, status: RechargeStatus.corrected);
      final ok = entry('S1', 199);
      final v = computeVolume([VolumeTxn.fromEntry(corrected), VolumeTxn.fromEntry(ok)],
          IstRange(DateTime.utc(2000), DateTime.utc(2100)));
      final a = v.byOperator[airtel]!;
      expect(a.grossPaise, rs(199));
      expect(a.successCount, 1);
      expect(a.pendingCount, 0);
      expect(a.failedCount, 0);
      expect(rechargeCashCollectedPaise([corrected, ok], '2026-11-22'), rs(199));
    });

    test('status text round-trips', () {
      expect(RechargeStatus.fromString('CORRECTED'), RechargeStatus.corrected);
      expect(RechargeStatus.fromString('SUCCESS'), RechargeStatus.success);
    });
  });

  group('local copy (RechargeEntryEditor)', () {
    test('correction: CORRECTED, Credit / Due taken off the customer once, prefill kept', () async {
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'RX', operator: airtel, amountPaise: rs(349)));
      await Db.parties.put('P1', {'name': 'Ravi', 'balance': 349.0});
      await Db.recharges.put('RX', {
        'rechargeId': 'RX', 'shopId': shop, 'operator': 'Airtel', 'mobile': '9876543210',
        'customerMobile': '9876543210', 'amount': 349.0, 'amountPaise': rs(349),
        'paymentMode': 'Credit / Due', 'partyKey': 'P1', 'status': 'SUCCESS',
        'createdAt': DateTime.utc(2026, 11, 22, 6).toIso8601String(), 'dateString': '2026-11-22',
      });
      final e = RechargeEntry.fromMap(Map<String, dynamic>.from(Db.recharges.get('RX') as Map), 'RX');
      final p = RechargeEntryEditor.prefillFor(e);
      expect(p.operator, 'Airtel');
      expect(p.paymentMode, 'Credit / Due');
      expect(p.amount, 349);

      await RechargeEntryEditor.correct(shopId: shop, actor: owner, entry: e, reason: 'wrong amount');
      await RechargeEntryEditor.correct(shopId: shop, actor: owner, entry: e, reason: 'tapped twice');
      final m = Db.recharges.get('RX') as Map;
      expect(RechargeStatus.fromString(m['status'] as String), RechargeStatus.corrected);
      expect((Db.parties.get('P1') as Map)['balance'], 0.0, reason: 'due reduced once, not twice');
    });

    test('details edit updates mobile and mode on this device', () async {
      b.seedRecharge(LocalRechargeRecord(rechargeId: 'RY', operator: airtel, amountPaise: rs(199)));
      await Db.recharges.put('RY', {
        'rechargeId': 'RY', 'shopId': shop, 'operator': 'Airtel', 'mobile': '9876543210',
        'customerMobile': '9876543210', 'amount': 199.0, 'amountPaise': rs(199),
        'paymentMode': 'Cash', 'status': 'SUCCESS',
        'createdAt': DateTime.utc(2026, 11, 22, 6).toIso8601String(), 'dateString': '2026-11-22',
      });
      final e = RechargeEntry.fromMap(Map<String, dynamic>.from(Db.recharges.get('RY') as Map), 'RY');
      await RechargeEntryEditor.editDetails(
          shopId: shop, actor: owner, entry: e, newMobile: '9000000002', newPaymentMode: 'UPI',
          reason: 'typed wrong');
      final m = Db.recharges.get('RY') as Map;
      expect(m['customerMobile'], '9000000002');
      expect(m['paymentMode'], 'UPI');
      final back = RechargeEntry.fromMap(Map<String, dynamic>.from(m), 'RY');
      expect(back.paymentMode, RechargePaymentMode.upi);
      expect(back.status, RechargeStatus.success);
    });
  });
}
