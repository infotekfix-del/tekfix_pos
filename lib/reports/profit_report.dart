// Profit & Loss engine (owner request 2026-11-23). Pure functions over plain
// maps so it can be tested without Hive or Firestore. All money in paise.
//
// Rules:
// - Gross profit = net sales - purchase cost of the items sold.
//   Cost per unit comes from the sale line ('unitCost' new POS, 'cost' old
//   POS). Older sales without a saved cost use the item's current cost price
//   and are counted as "estimated".
// - Bill discounts are spread over the bill's lines in proportion.
// - Returned bills are left out of sales and profit (shown as returns).
// - Expenses include rent, staff salary and other expenses (cash and bank).
//   Owner salary and owner drawings are NOT business expenses; they are shown
//   as money the owner took out of the profit.
// - Purchases, vendor payments and stock are information only.

int _p(dynamic v) => ((v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0) * 100).round();

DateTime? _date(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
  try {
    // Firestore Timestamp without importing it.
    final d = (v as dynamic).toDate();
    if (d is DateTime) return d;
  } catch (_) {}
  return DateTime.tryParse('$v');
}

String _dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// One item's figures for the period.
class ItemStat {
  final String name;
  int qty = 0;
  int revenuePaise = 0;
  int costPaise = 0;
  bool estimated = false;
  ItemStat(this.name);
  int get profitPaise => revenuePaise - costPaise;
}

/// A product at or under its minimum stock.
class LowStockItem {
  final String name;
  final int stock;
  final int minStock;
  final int soldLastPeriod;
  const LowStockItem(this.name, this.stock, this.minStock, this.soldLastPeriod);
}

class ProfitReport {
  final DateTime start;
  final DateTime end; // exclusive
  int billCount = 0;
  int grossSalesPaise = 0;
  int returnsPaise = 0;
  int returnCount = 0;
  int cogsPaise = 0;
  int estimatedLines = 0;
  int otherIncomePaise = 0; // recharge commission etc.
  final Map<String, int> otherIncome = {};
  final Map<String, int> expensesByCategory = {};
  int ownerSalaryPaise = 0;
  int ownerDrawingsPaise = 0;
  int purchasesPaise = 0;
  int vendorPaidPaise = 0;
  final Map<String, ItemStat> items = {};
  final Map<String, int> dailyProfit = {}; // yyyy-MM-dd -> gross profit
  final Map<String, int> dailySales = {};

  ProfitReport(this.start, this.end);

  int get netSalesPaise => grossSalesPaise;
  int get grossProfitPaise => netSalesPaise - cogsPaise;
  int get totalExpensesPaise => expensesByCategory.values.fold(0, (a, b) => a + b);
  int get netProfitPaise => grossProfitPaise + otherIncomePaise - totalExpensesPaise;
  int get afterOwnerPaise => netProfitPaise - ownerSalaryPaise - ownerDrawingsPaise;
  bool get isProfit => netProfitPaise >= 0;

  /// Gross margin in percent of net sales (0 when there are no sales).
  double get marginPercent => netSalesPaise == 0 ? 0 : grossProfitPaise * 100 / netSalesPaise;

  List<ItemStat> topBy(int Function(ItemStat) key, {int n = 10}) {
    final l = items.values.where((e) => e.qty > 0).toList()
      ..sort((a, b) => key(b).compareTo(key(a)));
    return l.take(n).toList();
  }

  List<ItemStat> get topByRevenue => topBy((e) => e.revenuePaise);
  List<ItemStat> get topByProfit => topBy((e) => e.profitPaise);
  List<ItemStat> get topByQty => topBy((e) => e.qty);
}

bool _in(DateTime? d, DateTime start, DateTime end) =>
    d != null && !d.isBefore(start) && d.isBefore(end);

/// Builds the report for [start, end).
///
/// [sales]: Db.sales values. [items]: Db.items values (for cost fallback and
/// low stock). [expenses]: Db.expenses values. [purchaseBills] and
/// [vendorPayments]: maps from the purchase boxes. [otherIncome]: extra
/// income already summed for the period (e.g. {'Recharge commission': paise}).
/// [ownerDrawingsPaise]: drawings part of owner withdrawals in the period.
ProfitReport computeProfitReport({
  required DateTime start,
  required DateTime end,
  required Iterable<Map> sales,
  Iterable<Map> items = const [],
  Iterable<Map> expenses = const [],
  Iterable<Map> purchaseBills = const [],
  Iterable<Map> vendorPayments = const [],
  Map<String, int> otherIncome = const {},
  int ownerDrawingsPaise = 0,
}) {
  final r = ProfitReport(start, end);

  // Item cost lookup by id / key / name.
  final costById = <String, int>{};
  final costByName = <String, int>{};
  for (final it in items) {
    final c = _p(it['costPrice']);
    if (c <= 0) continue;
    for (final k in [it['_id'], it['id'], it['key']]) {
      if (k != null) costById['$k'] = c;
    }
    final n = '${it['name'] ?? ''}'.trim().toLowerCase();
    if (n.isNotEmpty) costByName[n] = c;
  }

  for (final s in sales) {
    final when = _date(s['saleDate']) ?? _date(s['createdAt']);
    if (!_in(when, start, end)) continue;
    final total = _p(s['total']);
    final returned = s['returned'] == true || '${s['status'] ?? ''}'.toUpperCase() == 'RETURNED';
    if (returned) {
      r.returnsPaise += total;
      r.returnCount++;
      continue;
    }
    r.billCount++;
    r.grossSalesPaise += total;

    final lines = [for (final l in (s['items'] as List?) ?? const []) if (l is Map) l];
    var linesTotal = 0;
    final lineRevenue = <int>[];
    for (final l in lines) {
      final qty = (l['qty'] as num?)?.toInt() ?? 1;
      final lt = l.containsKey('lineTotal')
          ? _p(l['lineTotal'])
          : _p(l['unitPrice'] ?? l['price']) * qty;
      lineRevenue.add(lt);
      linesTotal += lt;
    }

    var billCost = 0;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final qty = (l['qty'] as num?)?.toInt() ?? 1;
      final name = '${l['name'] ?? 'Item'}'.trim();
      // Bill-level discount spread in proportion to each line.
      final rev = linesTotal == 0 ? 0 : (lineRevenue[i] * total / linesTotal).round();
      int? unitCost;
      var estimated = false;
      if (l['unitCost'] != null) {
        unitCost = _p(l['unitCost']);
      } else if (l['cost'] != null && _p(l['cost']) > 0) {
        unitCost = _p(l['cost']);
      } else {
        unitCost = costById['${l['itemId'] ?? l['itemKey'] ?? ''}'] ?? costByName[name.toLowerCase()];
        estimated = unitCost != null;
      }
      final lineCost = (unitCost ?? 0) * qty;
      if (estimated) r.estimatedLines++;
      billCost += lineCost;

      final st = r.items.putIfAbsent(name.toLowerCase(), () => ItemStat(name));
      st.qty += qty;
      st.revenuePaise += rev;
      st.costPaise += lineCost;
      st.estimated = st.estimated || estimated;
    }
    // Old-POS bills may carry only a bill-level cost/profit.
    if (lines.isEmpty && s['profit'] != null) {
      billCost = total - _p(s['profit']);
    }
    r.cogsPaise += billCost;
    final day = _dayKey(when!);
    r.dailyProfit[day] = (r.dailyProfit[day] ?? 0) + total - billCost;
    r.dailySales[day] = (r.dailySales[day] ?? 0) + total;
  }

  for (final e in expenses) {
    if (e['isVoided'] == true) continue;
    final when = _date(e['expenseDate']) ?? _date(e['createdAt']) ?? _date(e['date']);
    if (!_in(when, start, end)) continue;
    final amt = e['amountPaise'] != null ? (e['amountPaise'] as num).toInt() : _p(e['amount']);
    if (e['isOwnerWithdrawal'] == true) {
      final drawings = e['drawingsPortionPaise'] != null
          ? (e['drawingsPortionPaise'] as num).toInt()
          : (e['drawingsPortion'] != null ? _p(e['drawingsPortion']) : 0);
      final salary = e['salaryPortionPaise'] != null
          ? (e['salaryPortionPaise'] as num).toInt()
          : (e['salaryPortion'] != null ? _p(e['salaryPortion']) : (amt - drawings));
      r.ownerSalaryPaise += salary;
      if (drawings > 0 && r.ownerDrawingsPaise == 0) {
        r.ownerDrawingsPaise += drawings;
      }
      continue;
    }
    final cat = e['isDailyRent'] == true
        ? 'Rent'
        : ('${e['category'] ?? ''}'.trim().isEmpty ? 'Other' : '${e['category']}'.trim());
    r.expensesByCategory[cat] = (r.expensesByCategory[cat] ?? 0) + amt;
  }

  otherIncome.forEach((k, v) {
    if (v == 0) return;
    r.otherIncome[k] = (r.otherIncome[k] ?? 0) + v;
    r.otherIncomePaise += v;
  });
  r.ownerDrawingsPaise = ownerDrawingsPaise;

  for (final b in purchaseBills) {
    final draft = b['isDraft'] == true || '${b['status'] ?? ''}'.toLowerCase() == 'draft';
    final voided = b['isVoided'] == true || '${b['paymentStatus'] ?? ''}'.toLowerCase() == 'voided';
    if (draft || voided) continue;
    if (!_in(_date(b['purchaseDate']) ?? _date(b['createdAt']), start, end)) continue;
    r.purchasesPaise += b['grandTotalPaise'] != null
        ? (b['grandTotalPaise'] as num).toInt()
        : _p(b['grandTotal']);
  }
  for (final p in vendorPayments) {
    if (p['isReturn'] == true) continue;
    if (!_in(_date(p['paymentDate']), start, end)) continue;
    r.vendorPaidPaise += _p(p['amount']);
  }
  return r;
}

/// Items at or under their minimum stock, lowest first. [soldLast] gives the
/// quantity sold in the last period per item name (lower-case).
List<LowStockItem> lowStockItems(Iterable<Map> items, {Map<String, int> soldLast = const {}}) {
  final out = <LowStockItem>[];
  for (final it in items) {
    if (it['isService'] == true || '${it['type'] ?? ''}'.toLowerCase() == 'service') continue;
    final stock = (it['stock'] as num?)?.toInt() ?? 0;
    final min = (it['minStock'] as num?)?.toInt() ?? 3;
    if (stock > min) continue;
    final name = '${it['name'] ?? ''}'.trim();
    if (name.isEmpty) continue;
    out.add(LowStockItem(name, stock, min, soldLast[name.toLowerCase()] ?? 0));
  }
  out.sort((a, b) {
    final c = a.stock.compareTo(b.stock);
    return c != 0 ? c : b.soldLastPeriod.compareTo(a.soldLastPeriod);
  });
  return out;
}

/// Month helpers.
DateTime monthStart(DateTime d) => DateTime(d.year, d.month, 1);
DateTime nextMonth(DateTime d) => DateTime(d.year, d.month + 1, 1);
DateTime prevMonth(DateTime d) => DateTime(d.year, d.month - 1, 1);
