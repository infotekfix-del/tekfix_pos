// Profit & Loss (ലാഭ-നഷ്ട കണക്ക്) — owner report, month by month.
// Figures come from profit_report.dart; this file only loads data and draws.
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart';

import '../auth/auth_controller.dart';
import '../main.dart'
    show AppCard, Db, SectionTitle, StatCard, boxPurchaseBills, boxVendorPayments, rs, statGrid;
import '../owner/owner_finance_service.dart';
import '../recharge/recharge_accounting_service.dart';
import 'profit_report.dart';

class ProfitLossView extends StatefulWidget {
  const ProfitLossView({super.key});

  @override
  State<ProfitLossView> createState() => _ProfitLossViewState();
}

class _ProfitLossViewState extends State<ProfitLossView> {
  DateTime _month = monthStart(DateTime.now());
  ProfitReport? _r;
  ProfitReport? _prev;
  List<LowStockItem> _low = const []; // sold this or last month
  int _lowDormant = 0; // low/out of stock but no sales in 2 months
  int _vendorOutstandingPaise = 0;
  bool _loading = true;
  int _topTab = 0; // 0 sales, 1 profit, 2 quantity

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<Map> _values(String box) =>
      Hive.isBoxOpen(box) ? [for (final v in Hive.box(box).values) if (v is Map) v] : const [];

  List<Map> _itemsWithKeys() => Db.items.isOpen
      ? [
          for (final k in Db.items.keys)
            if (Db.items.get(k) is Map) {...Map<String, dynamic>.from(Db.items.get(k) as Map), 'key': '$k'}
        ]
      : const [];

  /// Recharge margin from local recharge records + server top-up commission.
  Future<int> _rechargeIncome(DateTime start, DateTime end) async {
    var paise = 0;
    if (Db.recharges.isOpen) {
      for (final v in Db.recharges.values) {
        if (v is! Map) continue;
        if ('${v['status'] ?? ''}'.toUpperCase() != 'SUCCESS') continue;
        final d = DateTime.tryParse('${v['createdAt'] ?? v['date'] ?? ''}');
        if (d == null || d.isBefore(start) || !d.isBefore(end)) continue;
        paise += (((v['commission'] as num?) ?? 0) * 100).round();
      }
    }
    try {
      final shop = AuthController.instance.shopId;
      if (shop.isNotEmpty) {
        final s = await RechargeAccountingService.instance
            .topUpCommissionSummary(shop)
            .timeout(const Duration(seconds: 6));
        for (final e in s.entries) {
          final at = e.at.toLocal();
          if (!at.isBefore(start) && at.isBefore(end)) paise += e.amountPaise;
        }
      }
    } catch (_) {
      // Offline: top-up commission is left out; noted on screen.
    }
    return paise;
  }

  Future<int> _ownerDrawings(DateTime month) async {
    try {
      final list = await OwnerFinanceService.instance.getWithdrawalsForMonth(month);
      return list.fold<int>(0, (a, w) => a + w.drawingsPortionPaise);
    } catch (_) {
      return 0;
    }
  }

  Future<ProfitReport> _build(DateTime month) async {
    final start = monthStart(month), end = nextMonth(month);
    return computeProfitReport(
      start: start,
      end: end,
      sales: Db.sales.isOpen ? [for (final v in Db.sales.values) if (v is Map) v] : const [],
      items: _itemsWithKeys(),
      expenses: Db.expenses.isOpen ? [for (final v in Db.expenses.values) if (v is Map) v] : const [],
      purchaseBills: _values(boxPurchaseBills),
      vendorPayments: _values(boxVendorPayments),
      otherIncome: {'Recharge commission (റീചാർജ് കമ്മീഷൻ)': await _rechargeIncome(start, end)},
      ownerDrawingsPaise: await _ownerDrawings(month),
    );
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await _build(_month);
    final prev = await _build(prevMonth(_month));
    final soldLast = {for (final e in prev.items.entries) e.key: e.value.qty};
    var owe = 0;
    if (Db.parties.isOpen) {
      for (final v in Db.parties.values) {
        if (v is! Map || '${v['type']}' != 'Supplier') continue;
        final bal = (((v['balance'] as num?) ?? 0) * 100).round();
        if (bal < 0) owe += -bal; // supplier balance is negative when we owe
      }
    }
    if (!mounted) return;
    setState(() {
      _r = r;
      _prev = prev;
      final recent = {...r.items.keys, ...prev.items.keys};
      final all = lowStockItems(_itemsWithKeys(), soldLast: soldLast);
      _low = [for (final it in all) if (recent.contains(it.name.toLowerCase())) it];
      _lowDormant = all.length - _low.length;
      _vendorOutstandingPaise = owe;
      _loading = false;
    });
  }

  String _m(int paise) => rs(paise / 100.0);

  String _change(int now, int before) {
    // No meaningful % when last month was zero, a loss, or tiny.
    if (before <= 0 || before * 20 < now.abs()) return '—';
    final pct = (now - before) * 100 / before.abs();
    return '${pct >= 0 ? '▲' : '▼'} ${pct.abs().toStringAsFixed(0)}%';
  }

  Widget _row(String label, int paise, {bool bold = false, Color? color, String sign = ''}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontSize: bold ? 15 : 13))),
          Text('$sign${_m(paise)}',
              style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.w600, color: color, fontSize: bold ? 15 : 13)),
        ]),
      );

  Widget _resultCard(ProfitReport r, ProfitReport? p) {
    final profit = r.isProfit;
    final color = profit ? const Color(0xFF22C55E) : const Color(0xFFEF4444);
    return AppCard(
      child: Row(children: [
        Icon(profit ? Icons.trending_up_rounded : Icons.trending_down_rounded, color: color, size: 44),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(profit ? 'ഈ മാസം ലാഭത്തിലാണ് (Profit)' : 'ഈ മാസം നഷ്ടത്തിലാണ് (Loss)',
                style: TextStyle(color: color, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(_m(r.netProfitPaise.abs()),
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: color)),
            if (p != null)
              Text('കഴിഞ്ഞ മാസം (Last month): ${_m(p.netProfitPaise)}  ${_change(r.netProfitPaise, p.netProfitPaise)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
        ),
      ]),
    );
  }

  Widget _statement(ProfitReport r) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _row('Sales (വിൽപന) — ${r.billCount} bills', r.grossSalesPaise),
          if (r.returnsPaise > 0)
            Text('  Returns (${r.returnCount}) not counted: ${_m(r.returnsPaise)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          _row('− Cost of goods sold (വാങ്ങിയ വില)', r.cogsPaise, color: Colors.redAccent),
          const Divider(),
          _row('Gross Profit (മൊത്ത ലാഭം) · ${r.marginPercent.toStringAsFixed(1)}%', r.grossProfitPaise, bold: true),
          for (final e in r.otherIncome.entries) _row('+ ${e.key}', e.value, color: Colors.teal),
          for (final e in (r.expensesByCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
            _row('− ${e.key}', e.value, color: Colors.redAccent),
          const Divider(),
          _row(r.isProfit ? 'Net Profit (അറ്റാദായം)' : 'Net Loss (നഷ്ടം)', r.netProfitPaise.abs(),
              bold: true, color: r.isProfit ? Colors.green : Colors.red),
          const SizedBox(height: 10),
          Text('Owner (ഉടമ എടുത്തത് — ചിലവല്ല):', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          _row('  Owner salary', r.ownerSalaryPaise),
          _row('  Owner drawings', r.ownerDrawingsPaise),
          _row('Left in the business (ബിസിനസ്സിൽ ബാക്കി)', r.afterOwnerPaise,
              bold: true, color: r.afterOwnerPaise >= 0 ? Colors.green : Colors.red),
          if (r.estimatedLines > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  '${r.estimatedLines} older sale lines had no saved cost; their cost uses today\'s item cost (estimated). '
                  '(പഴയ ചില sales-ന്റെ cost ഏകദേശമാണ്)',
                  style: const TextStyle(fontSize: 11, color: Colors.orange)),
            ),
        ]),
      );

  Widget _dailyChart(ProfitReport r) {
    final days = DateUtils.getDaysInMonth(r.start.year, r.start.month);
    final values = [
      for (var d = 1; d <= days; d++)
        r.dailyProfit[DateFormat('yyyy-MM-dd').format(DateTime(r.start.year, r.start.month, d))] ?? 0
    ];
    final maxAbs = values.fold<int>(1, (a, v) => v.abs() > a ? v.abs() : a);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Daily gross profit (ദിവസ ലാഭം)', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        SizedBox(
          height: 110,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < values.length; i++)
              Expanded(
                child: Tooltip(
                  message: '${i + 1}: ${_m(values[i])}',
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    height: 4 + 100 * values[i].abs() / maxAbs,
                    decoration: BoxDecoration(
                      color: values[i] >= 0 ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('1', style: TextStyle(fontSize: 10, color: Colors.grey)),
          Text('$days', style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ]),
      ]),
    );
  }

  Widget _topItems(ProfitReport r, ProfitReport? p) {
    final list = [r.topByRevenue, r.topByProfit, r.topByQty][_topTab];
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, children: [
          for (final (i, label) in [
            (0, 'Top sales (കൂടുതൽ വിറ്റത്)'),
            (1, 'Top profit (കൂടുതൽ ലാഭം)'),
            (2, 'Top quantity (എണ്ണം)'),
          ])
            ChoiceChip(label: Text(label), selected: _topTab == i, onSelected: (_) => setState(() => _topTab = i)),
        ]),
        const SizedBox(height: 8),
        if (list.isEmpty) const Text('ഈ മാസം വിൽപന ഇല്ല (No sales this month)'),
        for (var i = 0; i < list.length; i++)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(radius: 14, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
            title: Text(list[i].name + (list[i].estimated ? ' *' : '')),
            subtitle: Text(
                '${list[i].qty} sold · last month ${p?.items[list[i].name.toLowerCase()]?.qty ?? 0}'),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_m(list[i].revenuePaise), style: const TextStyle(fontWeight: FontWeight.bold)),
              Text('profit ${_m(list[i].profitPaise)}',
                  style: TextStyle(fontSize: 11, color: list[i].profitPaise >= 0 ? Colors.green : Colors.red)),
            ]),
          ),
      ]),
    );
  }

  Widget _lowStock() => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_low.isEmpty)
            const Text('വിൽക്കുന്ന സാധനങ്ങൾക്കെല്ലാം stock ഉണ്ട് (Items that sell are in stock)'),
          for (final it in _low.take(20))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.warning_amber_rounded, color: it.stock <= 0 ? Colors.red : Colors.orange),
              title: Text(it.name),
              subtitle: Text('Min ${it.minStock} · this month ${_r?.items[it.name.toLowerCase()]?.qty ?? 0} · last month ${it.soldLastPeriod}'),
              trailing: Text(it.stock <= 0 ? 'OUT (തീർന്നു)' : 'Stock ${it.stock}',
                  style: TextStyle(fontWeight: FontWeight.bold, color: it.stock <= 0 ? Colors.red : Colors.orange)),
            ),
          if (_low.length > 20) Text('+ ${_low.length - 20} more', style: const TextStyle(color: Colors.grey)),
          if (_lowDormant > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  '$_lowDormant more items are low/out of stock but did not sell in the last 2 months (not listed). '
                  '(2 മാസമായി വിൽക്കാത്തവ കാണിക്കുന്നില്ല)',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final r = _r, p = _prev;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profit & Loss (ലാഭ-നഷ്ടം)'),
        actions: [
          IconButton(
              key: const ValueKey('pl-prev'),
              icon: const Icon(Icons.chevron_left),
              onPressed: _loading
                  ? null
                  : () {
                      _month = prevMonth(_month);
                      _load();
                    }),
          Center(child: Text(DateFormat('MMMM yyyy').format(_month), style: const TextStyle(fontWeight: FontWeight.bold))),
          IconButton(
              key: const ValueKey('pl-next'),
              icon: const Icon(Icons.chevron_right),
              onPressed: _loading || !nextMonth(_month).isBefore(DateTime.now().add(const Duration(days: 1)))
                  ? null
                  : () {
                      _month = nextMonth(_month);
                      _load();
                    }),
        ],
      ),
      body: _loading || r == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                _resultCard(r, p),
                const SizedBox(height: 12),
                statGrid([
                  StatCard('Sales · ${p == null ? '' : _change(r.grossSalesPaise, p.grossSalesPaise)}',
                      _m(r.grossSalesPaise), Icons.point_of_sale, Colors.green),
                  StatCard('Gross Profit · ${r.marginPercent.toStringAsFixed(0)}%', _m(r.grossProfitPaise),
                      Icons.trending_up, Colors.teal),
                  StatCard('Expenses (ചിലവ്)', _m(r.totalExpensesPaise), Icons.money_off, Colors.redAccent),
                  StatCard('Other income', _m(r.otherIncomePaise), Icons.flash_on, Colors.indigo),
                ]),
                const SectionTitle('ലാഭ-നഷ്ട കണക്ക് (Profit & Loss statement)'),
                _statement(r),
                const SectionTitle('Daily (ദിവസം തിരിച്ച്)'),
                _dailyChart(r),
                const SectionTitle('Best items (മികച്ച സാധനങ്ങൾ)'),
                _topItems(r, p),
                SectionTitle('Low stock — items that sell (stock കുറഞ്ഞവ) · ${_low.length}'),
                _lowStock(),
                const SectionTitle('Purchases & vendors (വിവരത്തിന് മാത്രം)'),
                AppCard(
                  child: Column(children: [
                    _row('Purchases this month (വാങ്ങിയത്)', r.purchasesPaise),
                    _row('Paid to vendors (കൊടുത്തത്)', r.vendorPaidPaise),
                    _row('Vendors still to be paid (ഇനി കൊടുക്കാനുള്ളത്)', _vendorOutstandingPaise,
                        bold: true, color: Colors.orange),
                    const Text(
                        'Purchases are not an expense: their cost is counted when the items are sold. '
                        '(വാങ്ങിയ സാധനം വിൽക്കുമ്പോഴാണ് cost കണക്കാക്കുന്നത്)',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ]),
                ),
                const SizedBox(height: 24),
              ]),
            ),
    );
  }
}
