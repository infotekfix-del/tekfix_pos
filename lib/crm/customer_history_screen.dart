// Phase 3: Customer history screen.
// Header (name, phone, total spent, bills, first/last visit, balance),
// purchase timeline grouped by day with item search + date range filter,
// service jobs and warranty items, and WhatsApp / call / new bill actions.
//
// Opened from: POS customer card, Parties list, global search.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart'
    show
        Db,
        rs,
        AppCard,
        Pill,
        toast,
        SaleView,
        printInvoice,
        sendInvoiceWhatsApp,
        showPartyForm,
        showServiceJobForm;
import 'customer_crm.dart';
import 'customer_history.dart';
import 'customer_models.dart';
import 'phone_utils.dart';

final _day = DateFormat('dd MMM yyyy');
final _dayTime = DateFormat('dd MMM yyyy, hh:mm a');
String _rsP(int paise) => rs(paise / 100);
int _qty(Map l) => int.tryParse('${l['qty'] ?? 1}') ?? 1;
String _fmtDay(DateTime? d) => d == null ? '-' : _day.format(d.toLocal());

/// Opens the history screen for a customer uuid.
Future<void> openCustomerHistory(BuildContext context, String customerId) {
  return Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CustomerHistoryScreen(customerId: customerId)));
}

/// For party maps (Parties list / global search). Returns false when the
/// party is not an indexed customer (e.g. a supplier).
bool openCustomerHistoryForParty(BuildContext context, Map party) {
  final id = party['_id'];
  if (id is! String || !isCustomerParty(party)) return false;
  if (CustomerCrm.maybeInstance?.byId(id) == null) return false;
  openCustomerHistory(context, id);
  return true;
}

class CustomerHistoryScreen extends StatefulWidget {
  const CustomerHistoryScreen({super.key, required this.customerId});
  final String customerId;

  @override
  State<CustomerHistoryScreen> createState() => _CustomerHistoryScreenState();
}

class _CustomerHistoryScreenState extends State<CustomerHistoryScreen> {
  final _search = TextEditingController();
  CrmCustomer? _c;
  List<MapEntry<dynamic, Map<String, dynamic>>> _sales = const [];
  List<MapEntry<dynamic, Map<String, dynamic>>> _jobs = const [];
  List<WarrantyLine> _warranty = const [];
  DateTimeRange? _range;
  String _q = '';
  final _subs = <StreamSubscription>[];
  Timer? _reload;

  @override
  void initState() {
    super.initState();
    _load();
    // refresh after edits, new bills, returns or records arriving via sync
    void later(_) {
      _reload?.cancel();
      _reload = Timer(const Duration(milliseconds: 400), () async {
        await CustomerCrm.maybeInstance?.idle;
        if (mounted) _load();
      });
    }

    _subs
      ..add(Db.sales.watch().listen(later))
      ..add(Db.parties.watch().listen(later))
      ..add(Db.services.watch().listen(later));
  }

  @override
  void dispose() {
    _reload?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _search.dispose();
    super.dispose();
  }

  void _load() {
    final crm = CustomerCrm.maybeInstance;
    final c = crm?.byId(widget.customerId);
    setState(() {
      _c = c;
      _sales = c == null ? const [] : crm!.salesOf(c.id);
      _warranty = warrantyLines(_sales);
      _jobs = c == null
          ? const []
          : servicesForPhone(
              Db.services.keys.map((k) => MapEntry(k, Db.services.get(k))),
              c.phone,
              customerId: c.id);
    });
  }

  Future<void> _whatsApp(CrmCustomer c) async {
    if (c.phone.isEmpty) return;
    final shop = Db.setting('shop_name', 'TEKFIX');
    final msg = 'നമസ്കാരം ${c.name},\n$shop';
    final url = Uri.https('wa.me', '/91${c.phone}', {'text': msg});
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication) &&
          mounted) {
        toast(context, 'WhatsApp തുറക്കാൻ പറ്റിയില്ല (Could not open WhatsApp)',
            error: true);
      }
    } catch (_) {
      if (mounted) {
        toast(context, 'WhatsApp തുറക്കാൻ പറ്റിയില്ല (Could not open WhatsApp)',
            error: true);
      }
    }
    await Db.logAction(
        action: 'Customer Messaged',
        entity: 'Customer',
        entityId: c.id,
        newValue: {'channel': 'whatsapp', 'template': 'manual'});
  }

  Future<void> _call(CrmCustomer c) async {
    if (c.phone.isEmpty) return;
    try {
      if (!await launchUrl(Uri(scheme: 'tel', path: '+91${c.phone}')) &&
          mounted) {
        toast(context, 'കോൾ ചെയ്യാൻ പറ്റിയില്ല (Calling not supported here)',
            error: true);
      }
    } catch (_) {
      if (mounted) {
        toast(context, 'കോൾ ചെയ്യാൻ പറ്റിയില്ല (Calling not supported here)',
            error: true);
      }
    }
  }

  void _newBill(CrmCustomer c) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SaleView(initialPhone: c.phone)));
  }

  void _edit(CrmCustomer c) {
    final p = Db.parties.get(c.key);
    if (p is! Map) return;
    showPartyForm(context, c.key, Map<String, dynamic>.from(p));
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _range,
      helpText: 'തീയതി പരിധി (Date range)',
    );
    if (r != null) setState(() => _range = r);
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Customer (കസ്റ്റമർ)')),
        body: const Center(
            child: Text('കസ്റ്റമറെ കണ്ടെത്താനായില്ല (Customer not found)')),
      );
    }
    final days = groupHistory(_sales,
        itemQuery: _q, from: _range?.start, to: _range?.end);
    final wide = MediaQuery.of(context).size.width >= 900;

    final header = _header(c);
    final timeline = _timeline(days);
    final extras = _servicesAndWarranty();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(c.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Edit (മാറ്റുക)',
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => _edit(c),
            ),
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _load,
            ),
          ],
          bottom: wide
              ? null
              : TabBar(tabs: [
                  Tab(text: 'ബില്ലുകൾ (Bills ${_sales.length})'),
                  Tab(
                      text:
                          'സർവീസ് / വാറന്റി (${_jobs.length + _warranty.length})'),
                ]),
        ),
        body: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 380,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [header, const SizedBox(height: 12), ...extras],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(children: [
                      _filters(),
                      Expanded(child: timeline),
                    ]),
                  ),
                ],
              )
            : TabBarView(children: [
                Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: header,
                  ),
                  _filters(),
                  Expanded(child: timeline),
                ]),
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: extras,
                ),
              ]),
      ),
    );
  }

  Widget _header(CrmCustomer c) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget stat(String label, String value, {Color? color}) => SizedBox(
          width: 150,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 11, color: muted)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15, color: color)),
            ],
          ),
        );
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const CircleAvatar(child: Icon(Icons.person_rounded)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 17)),
                  Text(c.phone.isEmpty ? '-' : c.phone,
                      style: TextStyle(color: muted)),
                ],
              ),
            ),
            if (c.doNotMessage)
              const Pill('Do not message', Colors.red)
            else if (c.whatsappOptIn)
              const Pill('WhatsApp OK', Colors.green),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 10, children: [
            stat('ആകെ (Total spent)', _rsP(c.totalSpentPaise)),
            stat('ബില്ലുകൾ (Bills)', '${c.billCount}'),
            stat('ആദ്യം (First visit)', _fmtDay(c.firstPurchaseAt)),
            stat('അവസാനം (Last visit)', _fmtDay(c.lastPurchaseAt)),
            stat('ബാക്കി (Balance)', _rsP(c.balancePaise),
                color: c.balancePaise > 0 ? Colors.red.shade600 : null),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(
              onPressed: c.phone.isEmpty ? null : () => _whatsApp(c),
              icon: const Icon(Icons.chat_rounded),
              label: const Text('WhatsApp'),
            ),
            OutlinedButton.icon(
              onPressed: c.phone.isEmpty ? null : () => _call(c),
              icon: const Icon(Icons.call_rounded),
              label: const Text('Call (വിളിക്കുക)'),
            ),
            FilledButton.icon(
              onPressed: () => _newBill(c),
              icon: const Icon(Icons.add_shopping_cart_rounded),
              label: const Text('New bill (പുതിയ ബിൽ)'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _filters() {
    final r = _range;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: 'ഐറ്റം തിരയുക (Search item)',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear_rounded, size: 18),
                      onPressed: () => setState(() {
                        _search.clear();
                        _q = '';
                      }),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        r == null
            ? IconButton.outlined(
                tooltip: 'തീയതി പരിധി (Date range)',
                onPressed: _pickRange,
                icon: const Icon(Icons.date_range_rounded),
              )
            : InputChip(
                label: Text(
                    '${DateFormat('dd/MM').format(r.start)}–${DateFormat('dd/MM').format(r.end)}'),
                onPressed: _pickRange,
                onDeleted: () => setState(() => _range = null),
              ),
      ]),
    );
  }

  Widget _timeline(List<HistoryDay> days) {
    if (days.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
              _sales.isEmpty
                  ? 'ബില്ലുകൾ ഇല്ല (No bills yet)'
                  : 'ഫിൽട്ടറിന് ചേരുന്ന ബില്ലുകൾ ഇല്ല (No bills match the filter)',
              textAlign: TextAlign.center),
        ),
      );
    }
    // flattened list: header rows + bill rows, built lazily
    final rows = <Object>[];
    for (final d in days) {
      rows.add(d);
      rows.addAll(d.sales);
    }
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final r = rows[i];
        if (r is HistoryDay) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
            child: Row(children: [
              Text(_day.format(r.day),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const Spacer(),
              Text(_rsP(r.totalPaise),
                  style: TextStyle(color: muted, fontWeight: FontWeight.w700)),
            ]),
          );
        }
        final e = r as MapEntry<dynamic, Map<String, dynamic>>;
        return _billTile(e.key, e.value);
      },
    );
  }

  Widget _billTile(dynamic key, Map<String, dynamic> s) {
    final lines = saleLines(s);
    final returned = isSaleReturnedMap(s);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return AppCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      onTap: () => _openBill(s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('${s['invoice'] ?? '-'}',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            if (returned) ...[
              const Pill('RETURNED', Colors.red),
              const SizedBox(width: 6),
            ],
            Text(_rsP(toPaise(s['total'])),
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    decoration: returned ? TextDecoration.lineThrough : null)),
          ]),
          const SizedBox(height: 4),
          for (final l in lines.take(4))
            Text('${l['name'] ?? '-'}  ×${l['qty'] ?? 1}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          if (lines.length > 4)
            Text('+${lines.length - 4} more',
                style: TextStyle(fontSize: 12, color: muted)),
          const SizedBox(height: 4),
          Text(paymentMode(s), style: TextStyle(fontSize: 12, color: muted)),
        ],
      ),
    );
  }

  void _openBill(Map<String, dynamic> s) {
    final lines = saleLines(s);
    final when = DateTime.tryParse(saleWhen(s));
    Widget row(String k, String v, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(k)),
            Text(v,
                style: TextStyle(
                    fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
          ]),
        );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text('${s['invoice'] ?? '-'}',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text(when == null ? '-' : _dayTime.format(when.toLocal())),
            if (isSaleReturnedMap(s))
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Pill('RETURNED (തിരിച്ചു നൽകി)', Colors.red),
              ),
            const Divider(height: 24),
            for (final l in lines)
              row(
                  '${l['name'] ?? '-'} × ${l['qty'] ?? 1}'
                  '${'${l['imei'] ?? ''}'.isNotEmpty ? '\nIMEI ${l['imei']}' : ''}'
                  '${parseWarranty('${l['warranty'] ?? ''}') != null ? '\nWarranty ${l['warranty']}' : ''}',
                  _rsP(toPaise(l['price'] ?? l['unitPrice']) * _qty(l))),
            const Divider(height: 24),
            if (s['subtotal'] != null)
              row('Subtotal', _rsP(toPaise(s['subtotal']))),
            if (toPaise(s['discount']) > 0)
              row('Discount', '- ${_rsP(toPaise(s['discount']))}'),
            row('Total (ആകെ)', _rsP(toPaise(s['total'])), bold: true),
            row('Payment (പേയ്മെന്റ്)', paymentMode(s)),
            if (toPaise(s['due']) > 0)
              row('Due (ബാക്കി)', _rsP(toPaise(s['due']))),
            if ('${s['staffName'] ?? ''}'.isNotEmpty)
              row('Billed by', '${s['staffName']}'),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: () => printInvoice(ctx, s, a4: false),
                icon: const Icon(Icons.print_rounded),
                label: const Text('Print'),
              ),
              OutlinedButton.icon(
                onPressed: () => printInvoice(ctx, s, a4: true),
                icon: const Icon(Icons.picture_as_pdf_rounded),
                label: const Text('A4 PDF'),
              ),
              OutlinedButton.icon(
                onPressed: '${s['customerPhone'] ?? ''}'.isEmpty
                    ? null
                    : () => sendInvoiceWhatsApp(ctx, s),
                icon: const Icon(Icons.chat_rounded),
                label: const Text('WhatsApp bill'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  List<Widget> _servicesAndWarranty() {
    final now = DateTime.now();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return [
      const Padding(
        padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text('സർവീസ് / റിപ്പയർ (Service jobs)',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      if (_jobs.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text('സർവീസ് ജോലികൾ ഇല്ല (No service jobs)',
              style: TextStyle(color: muted)),
        ),
      for (final e in _jobs)
        AppCard(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          onTap: () => showServiceJobForm(context, e.key, e.value),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text('${e.value['jobId'] ?? '-'}',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                Pill('${e.value['status'] ?? '-'}', Colors.indigo),
              ]),
              const SizedBox(height: 4),
              Text(
                  '${e.value['brandModel'] ?? ''} ${e.value['productType'] ?? ''}'
                      .trim(),
                  style: const TextStyle(fontSize: 13)),
              if ('${e.value['complaint'] ?? ''}'.isNotEmpty)
                Text('${e.value['complaint']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: muted)),
              Text(
                  '${_fmtDay(DateTime.tryParse('${e.value['createdAt'] ?? ''}'))}'
                  '${e.value['warrantyEnd'] != null ? ' • Warranty till ${_fmtDay(DateTime.tryParse('${e.value['warrantyEnd']}'))}' : ''}',
                  style: TextStyle(fontSize: 12, color: muted)),
            ],
          ),
        ),
      const Padding(
        padding: EdgeInsets.fromLTRB(4, 12, 4, 8),
        child: Text('വാറന്റി (Warranty items)',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      if (_warranty.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('വാറന്റി ഉള്ള ഐറ്റങ്ങൾ ഇല്ല (No warranty items)',
              style: TextStyle(color: muted)),
        ),
      for (final w in _warranty)
        AppCard(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          onTap: () => _openBill(w.sale),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(w.item,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(
                      '${w.imei.isNotEmpty ? 'IMEI ${w.imei} • ' : ''}${w.warranty} • till ${_fmtDay(w.expires)}',
                      style: TextStyle(fontSize: 12, color: muted)),
                ],
              ),
            ),
            w.activeOn(now)
                ? const Pill('Active', Colors.green)
                : const Pill('Expired', Colors.grey),
          ]),
        ),
    ];
  }
}

/// "Last: 12 Nov 2026 • Redmi Note 13 • ₹15,000" (or "No purchases yet").
String lastPurchaseLabel(CrmCustomer c, {Map<String, dynamic>? lastSale}) {
  if (c.lastPurchaseAt == null) return 'വാങ്ങലുകൾ ഇല്ല (No purchases yet)';
  final items = (lastSale?['items'] as List?) ?? const [];
  final item =
      items.isNotEmpty && items.first is Map ? '${(items.first as Map)['name']}' : null;
  return 'Last: ${_fmtDay(c.lastPurchaseAt)}'
      '${item == null ? '' : ' • $item'}'
      '${lastSale == null ? '' : ' • ${_rsP(toPaise(lastSale['total']))}'}';
}

/// O(1) label for a party map in lists (null for non-indexed parties).
String? lastPurchaseLabelForParty(Map party) {
  final id = party['_id'];
  if (id is! String) return null;
  final c = CustomerCrm.maybeInstance?.byId(id);
  if (c == null || c.lastPurchaseAt == null) return null;
  return 'Last: ${_fmtDay(c.lastPurchaseAt)} • ${c.billCount} bills';
}
