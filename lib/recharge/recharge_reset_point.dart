// Quick Recharge "Reset / start new" (പുതിയ തുടക്കം).
//
// The server ledger is audited and append-only, so a reset never deletes
// anything. It records a reset point: from then on the dashboard counts from
// zero. Distributor dues and payments restart from ₹0 (the amounts at the
// reset are kept as a baseline and subtracted), and volume, commission and
// excess count only from the reset time. Operator wallet balances are the
// real money in the Airtel / Jio / Vi / BSNL apps and are not changed.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'recharge_accounting_backend.dart'
    show ExcessSummary, TopUpCommissionSummary;
import 'recharge_period_accounting.dart';

class RechargeResetPoint {
  final DateTime atUtc;

  /// `distributorId|operator` -> (payable, paid) at the reset.
  final Map<String, ({int payablePaise, int paidPaise})> settlementBaseline;

  RechargeResetPoint({required DateTime at, required this.settlementBaseline})
      : atUtc = at.toUtc();

  static String accountKey(SettlementAccount a) =>
      '${a.distributorId}|${a.operator.name}';

  factory RechargeResetPoint.fromSettlement(SettlementSummary? s, DateTime at) =>
      RechargeResetPoint(at: at, settlementBaseline: {
        for (final a in s?.accounts ?? const <SettlementAccount>[])
          accountKey(a): (payablePaise: a.payablePaise, paidPaise: a.paidPaise),
      });

  Map<String, dynamic> toJson() => {
        'at': atUtc.toIso8601String(),
        'settlement': {
          for (final e in settlementBaseline.entries)
            e.key: {'payable': e.value.payablePaise, 'paid': e.value.paidPaise},
        },
      };

  static RechargeResetPoint? fromJson(Map<String, dynamic> m) {
    final at = DateTime.tryParse(m['at']?.toString() ?? '');
    if (at == null) return null;
    final raw = (m['settlement'] as Map?) ?? const {};
    int i(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    return RechargeResetPoint(at: at, settlementBaseline: {
      for (final e in raw.entries)
        e.key.toString(): (
          payablePaise: i((e.value as Map)['payable']),
          paidPaise: i((e.value as Map)['paid']),
        ),
    });
  }
}

/// Dues and payments counted from the reset: the baseline is subtracted per
/// account; a last payment from before the reset is not shown.
SettlementSummary applySettlementReset(SettlementSummary raw, RechargeResetPoint? p) {
  if (p == null) return raw;
  final out = <SettlementAccount>[];
  for (final a in raw.accounts) {
    final base = p.settlementBaseline[RechargeResetPoint.accountKey(a)];
    final acc = SettlementAccount(a.distributorId, a.distributorName, a.operator)
      ..payablePaise = a.payablePaise - (base?.payablePaise ?? 0)
      ..paidPaise = a.paidPaise - (base?.paidPaise ?? 0)
      ..lastPaymentAt = (a.lastPaymentAt != null && !a.lastPaymentAt!.toUtc().isBefore(p.atUtc))
          ? a.lastPaymentAt
          : null;
    out.add(acc);
  }
  return SettlementSummary(out);
}

ExcessSummary applyExcessReset(ExcessSummary raw, RechargeResetPoint? p) => p == null
    ? raw
    : ExcessSummary(raw.entries.where((e) => !e.at.toUtc().isBefore(p.atUtc)).toList());

TopUpCommissionSummary applyTopUpCommissionReset(TopUpCommissionSummary raw, RechargeResetPoint? p) =>
    p == null
        ? raw
        : TopUpCommissionSummary(
            raw.entries.where((e) => !e.at.toUtc().isBefore(p.atUtc)).toList());

/// Keeps the reset point per shop in the local settings box.
class RechargeResetStore {
  RechargeResetStore._();

  static const String _boxName = 'tek_settings'; // boxSettings in main.dart
  static String _key(String shopId) => 'recharge_reset_point_v1_$shopId';

  static final Map<String, RechargeResetPoint?> _cache = {};

  /// The reset point for [shopId] (also moves [rechargeFreshStartUtc]).
  static RechargeResetPoint? current(String shopId) {
    if (!_cache.containsKey(shopId)) {
      RechargeResetPoint? p;
      try {
        if (Hive.isBoxOpen(_boxName)) {
          final raw = Hive.box(_boxName).get(_key(shopId));
          if (raw is String && raw.isNotEmpty) {
            p = RechargeResetPoint.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
          }
        }
      } catch (e) {
        debugPrint('[RechargeResetStore] load notice: $e');
      }
      _cache[shopId] = p;
    }
    final p = _cache[shopId];
    rechargeResetPointUtc = p?.atUtc;
    return p;
  }

  static Future<void> save(String shopId, RechargeResetPoint p) async {
    _cache[shopId] = p;
    rechargeResetPointUtc = p.atUtc;
    try {
      if (Hive.isBoxOpen(_boxName)) {
        await Hive.box(_boxName).put(_key(shopId), jsonEncode(p.toJson()));
      }
    } catch (e) {
      debugPrint('[RechargeResetStore] save notice: $e');
    }
  }

  @visibleForTesting
  static void clearForTesting() {
    _cache.clear();
    rechargeResetPointUtc = null;
  }
}
