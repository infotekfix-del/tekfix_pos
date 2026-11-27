import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/recharge/recharge_accounting_backend.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_period_accounting.dart';
import 'package:tekfix_erp_pos/recharge/recharge_period_widgets.dart';
import 'package:tekfix_erp_pos/recharge/recharge_reset_point.dart';

SettlementAccount acc(String id, RechargeOperator op, int payable, int paid, [DateTime? last]) =>
    SettlementAccount(id, id, op)
      ..payablePaise = payable
      ..paidPaise = paid
      ..lastPaymentAt = last;

void main() {
  tearDown(RechargeResetStore.clearForTesting);

  group('Quick Recharge reset (പുതിയ തുടക്കം)', () {
    final resetAt = DateTime.utc(2026, 11, 27, 6);

    test('dues and payments restart from ₹0 at the reset', () {
      final before = SettlementSummary([
        acc('AIRTEL_D', RechargeOperator.airtel, 500000, 300000, DateTime.utc(2026, 11, 26)),
        acc('VI_D', RechargeOperator.vi, 200000, 0),
      ]);
      final point = RechargeResetPoint.fromSettlement(before, resetAt);

      final right = applySettlementReset(before, point);
      expect(right.outstandingPaise, 0);
      expect(right.advancePaise, 0);
      for (final a in right.accounts) {
        expect(a.payablePaise, 0);
        expect(a.paidPaise, 0);
        expect(a.lastPaymentAt, isNull); // last payment was before the reset
      }

      // After the reset: Airtel loads ₹1,000 on credit, shop pays ₹400.
      final later = SettlementSummary([
        acc('AIRTEL_D', RechargeOperator.airtel, 600000, 340000, DateTime.utc(2026, 11, 27, 8)),
        acc('VI_D', RechargeOperator.vi, 200000, 0),
        acc('JIO_D', RechargeOperator.jio, 50000, 0), // new account after reset
      ]);
      final s = applySettlementReset(later, point);
      final airtel = s.account('AIRTEL_D', RechargeOperator.airtel)!;
      expect(airtel.outstandingPaise, 60000);
      expect(airtel.lastPaymentAt, DateTime.utc(2026, 11, 27, 8));
      expect(s.account('VI_D', RechargeOperator.vi)!.balancePaise, 0);
      expect(s.account('JIO_D', RechargeOperator.jio)!.outstandingPaise, 50000);
    });

    test('reset point survives a save/load round trip', () {
      final p = RechargeResetPoint.fromSettlement(
          SettlementSummary([acc('AIRTEL_D', RechargeOperator.airtel, 500000, 300000)]), resetAt);
      final back = RechargeResetPoint.fromJson(p.toJson())!;
      expect(back.atUtc, resetAt);
      expect(back.settlementBaseline['AIRTEL_D|airtel']!.payablePaise, 500000);
      expect(back.settlementBaseline['AIRTEL_D|airtel']!.paidPaise, 300000);
    });

    test('excess and top-up commission count only from the reset', () {
      final ex = applyExcessReset(
          ExcessSummary([
            ExcessEntry(operator: RechargeOperator.vi, amountPaise: 1000,
                at: resetAt.subtract(const Duration(minutes: 1)), source: ExcessSource.morning),
            ExcessEntry(operator: RechargeOperator.vi, amountPaise: 2500,
                at: resetAt.add(const Duration(minutes: 1)), source: ExcessSource.closing),
          ]),
          RechargeResetPoint(at: resetAt, settlementBaseline: const {}));
      expect(ex.totalPaise, 2500);

      final tc = applyTopUpCommissionReset(
          TopUpCommissionSummary([
            TopUpCommissionEntry(operator: RechargeOperator.airtel, amountPaise: 3900,
                at: resetAt.subtract(const Duration(hours: 1))),
          ]),
          RechargeResetPoint(at: resetAt, settlementBaseline: const {}));
      expect(tc.totalPaise, 0);
    });

    test('volume counting moves to the reset time', () {
      expect(rechargeFreshStartUtc, DateTime.utc(2026, 11, 22, 18, 30));
      rechargeResetPointUtc = resetAt;
      expect(rechargeFreshStartUtc, resetAt);
      expect(rechargeFreshStartLabel, '2026-11-27 11:30'); // IST
      final r = clampToFreshStart(
          istRangeFor(RechargePeriodFilter.allTime, now: DateTime.utc(2026, 11, 28)));
      expect(r.startUtc, resetAt);
    });

    test('vendor payment lines are written in plain Malayalam', () {
      expect(shopPaymentLineMalayalam(RechargeOperator.airtel, 100000),
          'ഷോപ്പിൽ നിന്നും എയർടെലിൻ്റെ ആൾക്ക് കൊടുക്കാനുള്ള പേയ്മെൻ്റ്: ${formatInrPaise(100000)}');
      expect(shopPaymentLineMalayalam(RechargeOperator.vi, 50000),
          'ഷോപ്പിൽ നിന്നും വിഐയുടെ ആൾക്ക് കൊടുക്കാനുള്ള പേയ്മെൻ്റ്: ${formatInrPaise(50000)}');
      expect(shopPaymentLineMalayalam(RechargeOperator.jio, -20000), contains('അഡ്വാൻസ്'));
      expect(shopPaymentLineMalayalam(RechargeOperator.bsnl, 0), contains('ബാക്കിയില്ല'));
    });
  });
}
