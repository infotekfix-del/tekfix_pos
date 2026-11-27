// Phase 5 UI: segment builder, campaigns + report, automations, templates
// and the one-tap WhatsApp send queue. Owner only.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db, rs, AppCard, Pill, toast;
import '../reminders/reminder_service.dart';
import 'crm_messaging.dart';
import 'crm_app.dart' show crmCan;
import 'crm_permissions.dart';
import 'customer_crm.dart';
import 'customer_history.dart';
import 'customer_models.dart';
import 'customer_history_screen.dart' show openCustomerHistory;

String _rsP(int p) => rs(p / 100);
final _day = DateFormat('dd MMM yyyy');

String get _shopName => Db.setting('shop_name', 'TEKFIX');
String get _user => AuthController.instance.name;

Future<bool> _launchWa(Uri u) =>
    launchUrl(u, mode: LaunchMode.externalApplication);

Map<dynamic, String> _categoryMap() => {
      for (final v in Db.items.values)
        if (v is Map && v['_id'] != null) v['_id']: '${v['category'] ?? ''}'
    };

class CrmMessagingScreen extends StatelessWidget {
  const CrmMessagingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = CrmMessaging.maybeInstance;
    if (!crmCan(CrmAction.bulkSend) || !crmCan(CrmAction.editSegments)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Customer Offers')),
        body: const Center(child: Text(kCrmDenied)),
      );
    }
    if (m == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Customer Offers')),
        body: const Center(child: Text('CRM not started (CRM ആരംഭിച്ചിട്ടില്ല)')),
      );
    }
    m.seedDefaults(); // managers only reach here; no-op when present
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ഓഫറുകൾ & WhatsApp (Customer Offers)'),
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: 'Segment (വിഭാഗം)'),
            Tab(text: 'Campaigns (ക്യാമ്പെയ്ൻ)'),
            Tab(text: 'Automations (ഓട്ടോമാറ്റിക്)'),
            Tab(text: 'Templates (ടെംപ്ലേറ്റ്)'),
          ]),
        ),
        body: TabBarView(children: [
          _SegmentTab(m: m),
          _CampaignsTab(m: m),
          _AutomationsTab(m: m),
          _TemplatesTab(m: m),
        ]),
      ),
    );
  }
}

Widget _wrap(Widget child) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900), child: child),
    );

// ================================================================ segment
class _SegmentTab extends StatefulWidget {
  const _SegmentTab({required this.m});
  final CrmMessaging m;
  @override
  State<_SegmentTab> createState() => _SegmentTabState();
}

class _SegmentTabState extends State<_SegmentTab> {
  bool _useDays = false, _useSpent = false, _useItem = false;
  bool _birthday = false, _pending = false;
  final _days = TextEditingController(text: '60');
  final _spent = TextEditingController(text: '5000');
  final _item = TextEditingController();
  final _offer = TextEditingController();
  final _name = TextEditingController();
  String? _templateId;
  List<CrmCustomer>? _result;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_days, _spent, _item, _offer, _name]) {
      c.dispose();
    }
    super.dispose();
  }

  SegmentFilter get _filter => SegmentFilter(
        noPurchaseDays: _useDays ? int.tryParse(_days.text.trim()) : null,
        minSpentPaise: _useSpent
            ? ((double.tryParse(_spent.text.trim()) ?? 0) * 100).round()
            : null,
        boughtItem: _useItem && _item.text.trim().isNotEmpty ? _item.text : null,
        birthdayThisMonth: _birthday,
        pendingBalance: _pending,
      );

  void _recount() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      final cats = _categoryMap();
      final r = evaluateSegment(widget.m.crm, _filter,
          categoryOf: (l) => cats[l['itemId']]);
      if (mounted) setState(() => _result = r);
    });
  }

  @override
  void initState() {
    super.initState();
    _recount();
  }

  Future<void> _create() async {
    final r = _result ?? const [];
    final t = widget.m.template(_templateId ?? '');
    if (t == null) {
      toast(context, 'ടെംപ്ലേറ്റ് തിരഞ്ഞെടുക്കുക (Choose a template)',
          error: true);
      return;
    }
    if (r.isEmpty) {
      toast(context, 'കസ്റ്റമർമാർ ഇല്ല (No customers match)', error: true);
      return;
    }
    final cmp = await widget.m.createCampaign(
      name: _name.text,
      filter: _filter,
      template: t,
      customers: r,
      offer: _offer.text.trim(),
      user: _user,
    );
    await Db.logAction(
        action: 'Campaign Created',
        entity: 'Customer',
        entityId: '${cmp['_id']}',
        newValue: {
          'name': cmp['name'],
          'filter': cmp['filterText'],
          'customers': r.length,
          'template': t.name,
        });
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SendQueueScreen(
            title: '${cmp['name']}', campaignId: '${cmp['_id']}')));
  }

  Widget _rule(String label, bool on, ValueChanged<bool> set,
      {TextEditingController? ctrl, String? suffix, bool number = true}) {
    return Row(children: [
      Checkbox(
          value: on,
          onChanged: (v) {
            set(v ?? false);
            _recount();
          }),
      Expanded(child: Text(label)),
      if (ctrl != null)
        SizedBox(
          width: number ? 110 : 180,
          child: TextField(
            controller: ctrl,
            enabled: on,
            keyboardType: number ? TextInputType.number : TextInputType.text,
            onChanged: (_) => _recount(),
            decoration: InputDecoration(isDense: true, suffixText: suffix),
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final templates = widget.m.allTemplates();
    _templateId ??= templates.isEmpty ? null : templates.first.id;
    final r = _result;
    final t = widget.m.template(_templateId ?? '');
    final preview = (r == null || r.isEmpty || t == null)
        ? null
        : renderTemplate(t,
            name: r.first.name,
            lastItem: widget.m.lastItemOf(r.first),
            shopName: _shopName,
            offer: _offer.text.trim());
    return _wrap(ListView(
      padding: const EdgeInsets.all(16),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('ഫിൽട്ടറുകൾ (Filters) — എല്ലാം ശരിയാകണം (all must match)',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              _rule('N ദിവസമായി വാങ്ങിയിട്ടില്ല (No purchase in N days)',
                  _useDays, (v) => setState(() => _useDays = v),
                  ctrl: _days, suffix: 'days'),
              _rule('ആകെ ചെലവ് ഇതിൽ കൂടുതൽ (Total spent above ₹)', _useSpent,
                  (v) => setState(() => _useSpent = v),
                  ctrl: _spent, suffix: '₹'),
              _rule('ഈ ഐറ്റം / വിഭാഗം വാങ്ങിയവർ (Bought item / category)',
                  _useItem, (v) => setState(() => _useItem = v),
                  ctrl: _item, number: false),
              _rule('ഈ മാസം ജന്മദിനം (Birthday this month)', _birthday,
                  (v) => setState(() => _birthday = v)),
              _rule('ബാക്കി തുക ഉള്ളവർ (Pending balance)', _pending,
                  (v) => setState(() => _pending = v)),
              const SizedBox(height: 6),
              const Text(
                  'WhatsApp opt-in ചെയ്തവരും "Do not message" അല്ലാത്തവരും മാത്രം. (Only opted-in customers who have not opted out.)',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Expanded(
                    child: Text('ചേരുന്ന കസ്റ്റമർമാർ (Matching customers)',
                        style: TextStyle(fontWeight: FontWeight.w800))),
                Pill(r == null ? '…' : '${r.length}', Colors.indigo),
              ]),
              const SizedBox(height: 6),
              if (r != null)
                for (final c in r.take(8))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(c.name),
                    subtitle: Text(
                        '${c.phone} • ${_rsP(c.totalSpentPaise)} • last ${c.lastPurchaseAt == null ? '-' : _day.format(c.lastPurchaseAt!.toLocal())}'),
                    onTap: () => openCustomerHistory(context, c.id),
                  ),
              if (r != null && r.length > 8)
                Text('+${r.length - 8} more',
                    style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('മെസ്സേജ് (Message)',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _templateId,
                items: [
                  for (final t in templates)
                    DropdownMenuItem(value: t.id, child: Text(t.name)),
                ],
                onChanged: (v) => setState(() => _templateId = v),
                decoration: const InputDecoration(labelText: 'Template'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _offer,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                    labelText: '{offer} — ഓഫർ വിവരം (e.g. 10% off on covers)'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                    labelText: 'Campaign name (optional)'),
              ),
              if (preview != null) ...[
                const SizedBox(height: 10),
                Text('Preview (${r!.first.name}):',
                    style: const TextStyle(fontSize: 12)),
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.green.withAlpha(25),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(preview),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: (r?.isEmpty ?? true) ? null : _create,
                icon: const Icon(Icons.send_rounded),
                label: Text(
                    'ക്യാമ്പെയ്ൻ തുടങ്ങുക (Start campaign: ${r?.length ?? 0})'),
              ),
            ],
          ),
        ),
      ],
    ));
  }
}

// ============================================================== campaigns
class _CampaignsTab extends StatefulWidget {
  const _CampaignsTab({required this.m});
  final CrmMessaging m;
  @override
  State<_CampaignsTab> createState() => _CampaignsTabState();
}

class _CampaignsTabState extends State<_CampaignsTab> {
  @override
  Widget build(BuildContext context) {
    final list = widget.m.allCampaigns();
    if (list.isEmpty) {
      return const Center(
          child: Text('ക്യാമ്പെയ്നുകൾ ഇല്ല (No campaigns yet)'));
    }
    return _wrap(RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: list.length,
        itemBuilder: (_, i) {
          final c = list[i];
          final r = widget.m.report('${c['_id']}');
          final at = DateTime.tryParse('${c['createdAt']}');
          return AppCard(
            margin: const EdgeInsets.only(bottom: 10),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SendQueueScreen(
                      title: '${c['name']}', campaignId: '${c['_id']}')));
              if (mounted) setState(() {});
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${c['name']}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(
                    '${at == null ? '' : _day.format(at.toLocal())} • ${c['templateName']} • ${c['filterText']}',
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  Pill('Targeted ${r.targeted}', Colors.indigo),
                  Pill('Sent ${r.sent}', Colors.green),
                  Pill('Skipped ${r.skipped}', Colors.grey),
                  Pill('Bought in 7 days ${r.purchasedWithin7Days}',
                      Colors.orange),
                  if (r.revenuePaise > 0)
                    Pill('Revenue ${_rsP(r.revenuePaise)}', Colors.teal),
                ]),
              ],
            ),
          );
        },
      ),
    ));
  }
}

// ============================================================ automations
class _AutomationsTab extends StatefulWidget {
  const _AutomationsTab({required this.m});
  final CrmMessaging m;
  @override
  State<_AutomationsTab> createState() => _AutomationsTabState();
}

class _AutomationsTabState extends State<_AutomationsTab> {
  late AutomationSettings _a = widget.m.automation;
  late final _missDays = TextEditingController(text: '${_a.missYouDays}');
  late final _warrDays =
      TextEditingController(text: '${_a.warrantyDaysBefore}');
  late final _delay = TextEditingController(text: '${widget.m.delaySeconds}');
  late final _cap = TextEditingController(text: '${widget.m.dailyCap}');

  @override
  void dispose() {
    for (final c in [_missDays, _warrDays, _delay, _cap]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save(AutomationSettings a) async {
    setState(() => _a = a);
    await widget.m.setAutomation(a);
    await Db.logAction(
        action: 'CRM Automation Changed',
        entity: 'Customer',
        entityId: 'crm_automation',
        newValue: a.toMap());
  }

  List<QueuedMessage> _due() => widget.m.automationDue(
        shopName: _shopName,
        serviceJobs: Db.services.keys.map((k) => MapEntry(k, Db.services.get(k))),
        thankYouText: (c, s) {
          final items = saleLines(s);
          final d = DateTime.tryParse(saleWhen(s));
          return ReminderService.instance.buildFollowUp1Message(
            customerName: c.name,
            itemName: items.isEmpty ? '' : '${items.first['name'] ?? ''}',
            saleDate: d == null ? '' : _day.format(d.toLocal()),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final due = _due();
    Widget sw(String t, String sub, bool v, ValueChanged<bool> on,
            {TextEditingController? ctrl, String? suffix}) =>
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t),
          subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
          value: v,
          onChanged: on,
          secondary: ctrl == null
              ? null
              : SizedBox(
                  width: 70,
                  child: TextField(
                    controller: ctrl,
                    keyboardType: TextInputType.number,
                    decoration:
                        InputDecoration(isDense: true, suffixText: suffix),
                    onSubmitted: (_) => _saveNumbers(),
                  ),
                ),
        );
    return _wrap(ListView(
      padding: const EdgeInsets.all(16),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'എല്ലാം default ആയി OFF. ഓരോ ദിവസവും വേണ്ട മെസ്സേജുകൾ താഴെ ലിസ്റ്റ് ചെയ്യും; ഓരോന്നും ഒറ്റ ടാപ്പിൽ അയക്കാം. '
                  '(All off by default. Due messages are listed below and sent one tap each — personal WhatsApp is never automated.)',
                  style: TextStyle(fontSize: 12)),
              sw('ജന്മദിനാശംസ (Birthday wish)', 'On the customer\'s birthday',
                  _a.birthday, (v) => _save(_a.copyWith(birthday: v))),
              sw('"We miss you"', 'No purchase for N days', _a.missYou,
                  (v) => _save(_a.copyWith(missYou: v)),
                  ctrl: _missDays, suffix: 'd'),
              sw('വാറന്റി ഓർമ്മപ്പെടുത്തൽ (Warranty ending)',
                  'N days before an item warranty ends', _a.warranty,
                  (v) => _save(_a.copyWith(warranty: v)),
                  ctrl: _warrDays, suffix: 'd'),
              sw('സർവീസ് റെഡി (Service ready for pickup)',
                  'Repair job status "Ready"', _a.serviceReady,
                  (v) => _save(_a.copyWith(serviceReady: v))),
              sw('നന്ദി (Thank-you after purchase)',
                  'Uses the existing follow-up thank-you message, within 48 h',
                  _a.thankYou, (v) => _save(_a.copyWith(thankYou: v))),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('അയക്കൽ പരിധി (Sending limits)',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _delay,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Delay between customers (seconds)'),
                    onSubmitted: (_) => _saveNumbers(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _cap,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Daily cap (messages)'),
                    onSubmitted: (_) => _saveNumbers(),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                    onPressed: _saveNumbers, child: const Text('Save')),
              ),
              Text(
                  'Sent today: ${widget.m.sentToday()} / ${widget.m.dailyCap}',
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: due.isEmpty
              ? null
              : () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SendQueueScreen(
                          title: 'ഇന്നത്തെ മെസ്സേജുകൾ (Due today)',
                          automation: true,
                          loader: _due)));
                  if (mounted) setState(() {});
                },
          icon: const Icon(Icons.schedule_send_rounded),
          label: Text('ഇന്ന് അയക്കേണ്ടവ (Due today: ${due.length})'),
        ),
      ],
    ));
  }

  Future<void> _saveNumbers() async {
    final a = _a.copyWith(
      missYouDays: int.tryParse(_missDays.text.trim()) ?? _a.missYouDays,
      warrantyDaysBefore:
          int.tryParse(_warrDays.text.trim()) ?? _a.warrantyDaysBefore,
    );
    await _save(a);
    final d = int.tryParse(_delay.text.trim()) ?? widget.m.delaySeconds;
    final c = int.tryParse(_cap.text.trim()) ?? widget.m.dailyCap;
    await widget.m.setSending(
        delaySec: d.clamp(0, 600), dailyCap: c.clamp(1, 1000));
    if (mounted) {
      toast(context, 'സേവ് ചെയ്തു (Saved)');
      setState(() {});
    }
  }
}

// ============================================================== templates
class _TemplatesTab extends StatefulWidget {
  const _TemplatesTab({required this.m});
  final CrmMessaging m;
  @override
  State<_TemplatesTab> createState() => _TemplatesTabState();
}

class _TemplatesTabState extends State<_TemplatesTab> {
  Future<void> _edit([MsgTemplate? t]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => TemplateEditorScreen(m: widget.m, template: t)));
    if (saved == true && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.m.allTemplates();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('New template'),
      ),
      body: _wrap(ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
        children: [
          for (final t in list)
            AppCard(
              margin: const EdgeInsets.only(bottom: 10),
              onTap: () => _edit(t),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                        child: Text(t.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w800))),
                    Pill(t.kind, Colors.indigo),
                    const SizedBox(width: 4),
                    if (t.promotional) const Pill('promo', Colors.orange),
                  ]),
                  const SizedBox(height: 4),
                  Text(t.body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
        ],
      )),
    );
  }
}

class TemplateEditorScreen extends StatefulWidget {
  const TemplateEditorScreen({super.key, required this.m, this.template});
  final CrmMessaging m;
  final MsgTemplate? template;
  @override
  State<TemplateEditorScreen> createState() => _TemplateEditorScreenState();
}

class _TemplateEditorScreenState extends State<TemplateEditorScreen> {
  late final _name = TextEditingController(text: widget.template?.name ?? '');
  late final _body = TextEditingController(text: widget.template?.body ?? '');
  late String _kind = widget.template?.kind ?? 'promo';
  late bool _promo = widget.template?.promotional ?? true;

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  void _insert(String p) {
    final sel = _body.selection;
    final text = _body.text;
    final at = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    _body.value = TextEditingValue(
      text: text.replaceRange(at, end, p),
      selection: TextSelection.collapsed(offset: at + p.length),
    );
    setState(() {});
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _body.text.trim().isEmpty) {
      toast(context, 'പേരും മെസ്സേജും നൽകുക (Enter name and message)',
          error: true);
      return;
    }
    final t = await widget.m.saveTemplate(MsgTemplate(
        id: widget.template?.id ?? '',
        name: _name.text,
        body: _body.text,
        kind: _kind,
        promotional: _promo));
    await Db.logAction(
        action: widget.template == null ? 'Template Created' : 'Template Edited',
        entity: 'Customer',
        entityId: t.id,
        newValue: t.toMap());
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final t = widget.template;
    if (t == null) return;
    await widget.m.deleteTemplate(t.id);
    await Db.logAction(
        action: 'Template Deleted', entity: 'Customer', entityId: t.id);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final preview = renderTemplate(
      MsgTemplate(id: 'x', name: '', body: _body.text, promotional: _promo),
      name: 'Anu',
      lastItem: 'Redmi Note 13',
      shopName: _shopName,
      offer: '10% off',
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.template == null
            ? 'പുതിയ ടെംപ്ലേറ്റ് (New template)'
            : 'ടെംപ്ലേറ്റ് മാറ്റുക (Edit template)'),
        actions: [
          if (widget.template != null)
            IconButton(
                tooltip: 'Delete',
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline)),
          IconButton(
              tooltip: 'Save',
              onPressed: _save,
              icon: const Icon(Icons.check_rounded)),
        ],
      ),
      body: _wrap(ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name (പേര്)')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _kind,
            items: const [
              DropdownMenuItem(value: 'promo', child: Text('Offer / promo')),
              DropdownMenuItem(value: 'missyou', child: Text('We miss you')),
              DropdownMenuItem(value: 'birthday', child: Text('Birthday')),
              DropdownMenuItem(value: 'warranty', child: Text('Warranty')),
              DropdownMenuItem(value: 'service', child: Text('Service')),
            ],
            onChanged: (v) => setState(() => _kind = v ?? 'promo'),
            decoration: const InputDecoration(labelText: 'Type'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('പ്രൊമോഷണൽ (Promotional)'),
            subtitle: const Text(
                'Promotional messages always get the STOP opt-out line',
                style: TextStyle(fontSize: 12)),
            value: _promo,
            onChanged: (v) => setState(() => _promo = v),
          ),
          Wrap(spacing: 6, children: [
            for (final p in kTemplatePlaceholders)
              ActionChip(label: Text(p), onPressed: () => _insert(p)),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _body,
            minLines: 5,
            maxLines: 12,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                labelText: 'Message — Malayalam / English',
                alignLabelWithHint: true),
          ),
          const SizedBox(height: 12),
          const Text('Preview', style: TextStyle(fontWeight: FontWeight.w700)),
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.green.withAlpha(25),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(preview),
          ),
        ],
      )),
    );
  }
}

// ============================================================= send queue
/// One customer at a time: Open WhatsApp (marks Sent) / Skip / Opt out.
/// Enforces the delay between customers and the daily cap.
class SendQueueScreen extends StatefulWidget {
  const SendQueueScreen({
    super.key,
    required this.title,
    this.campaignId,
    this.loader,
    this.automation = false,
    this.sender,
  });
  final String title;
  final String? campaignId;
  final List<QueuedMessage> Function()? loader;
  final bool automation;
  final WhatsAppSender? sender;

  @override
  State<SendQueueScreen> createState() => _SendQueueScreenState();
}

class _SendQueueScreenState extends State<SendQueueScreen> {
  late final CrmMessaging _m = CrmMessaging.maybeInstance!;
  late final WhatsAppSender _sender = widget.sender ?? WaMeSender(_launchWa);
  List<QueuedMessage> _queue = const [];
  int _sent = 0, _skipped = 0;
  int _wait = 0;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _queue = widget.campaignId != null
          ? _m.campaignQueue(widget.campaignId!, shopName: _shopName)
          : (widget.loader?.call() ?? const []);
    });
  }

  void _startDelay() {
    final d = _m.delaySeconds;
    if (d <= 0) return;
    setState(() => _wait = d);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _wait--);
      if (_wait <= 0) t.cancel();
    });
  }

  Future<void> _record(QueuedMessage q, String status,
      {String reason = ''}) async {
    await _m.logMessage(
      customer: q.customer,
      templateId: q.templateId,
      kind: q.kind,
      status: status,
      campaignId: q.campaignId,
      dedupeKey: q.dedupeKey,
      channel: _sender.channel,
      text: q.text,
      reason: reason,
      user: _user,
    );
    await Db.logAction(
        action: status == 'sent' ? 'Customer Messaged' : 'Customer Message $status',
        entity: 'Customer',
        entityId: q.customer.id,
        newValue: {
          'template': q.templateId,
          'kind': q.kind,
          'campaign': q.campaignId,
          'status': status,
          if (reason.isNotEmpty) 'reason': reason,
        });
  }

  Future<void> _send(QueuedMessage q) async {
    if (_busy) return;
    if (_m.remainingToday() <= 0) {
      toast(context,
          'ഇന്നത്തെ പരിധി കഴിഞ്ഞു (Daily cap of ${_m.dailyCap} reached)',
          error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await _sender.send(phone: q.customer.phone, text: q.text);
      if (!r.ok) {
        await _record(q, 'failed', reason: r.error ?? '');
        if (mounted) toast(context, r.error ?? 'Failed', error: true);
        return;
      }
      await _record(q, 'sent');
      _sent++;
      _reload();
      _startDelay();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _skip(QueuedMessage q, {bool optOut = false}) async {
    if (optOut) {
      final p = Db.parties.get(q.customer.key);
      if (p is Map) {
        await Db.parties.put(q.customer.key,
            {...Map<String, dynamic>.from(p), 'doNotMessage': true});
        await Db.logAction(
            action: 'Customer Opted Out',
            entity: 'Customer',
            entityId: q.customer.id,
            newValue: {'doNotMessage': true});
        await CustomerCrm.maybeInstance?.idle;
      }
    }
    await _record(q, 'skipped', reason: optOut ? 'opted out' : '');
    _skipped++;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (!crmCan(CrmAction.bulkSend)) {
      return Scaffold(
          appBar: AppBar(title: Text(widget.title)),
          body: const Center(child: Text(kCrmDenied)));
    }
    final q = _queue.isEmpty ? null : _queue.first;
    final remaining = _m.remainingToday();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _wrap(ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            Pill('Left ${_queue.length}', Colors.indigo),
            Pill('Sent $_sent', Colors.green),
            Pill('Skipped $_skipped', Colors.grey),
            Pill('Today ${_m.sentToday()} / ${_m.dailyCap}',
                remaining > 0 ? Colors.teal : Colors.red),
          ]),
          const SizedBox(height: 12),
          if (q == null)
            const AppCard(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text('എല്ലാം കഴിഞ്ഞു! (All done — queue is empty)',
                    textAlign: TextAlign.center),
              ),
            )
          else
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const CircleAvatar(child: Icon(Icons.person)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(q.customer.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 16)),
                          Text('${q.customer.phone} • ${q.kind}'),
                        ],
                      ),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.green.withAlpha(25),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SelectableText(q.text),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _busy || _wait > 0 || remaining <= 0
                        ? null
                        : () => _send(q),
                    icon: const Icon(Icons.chat_rounded),
                    label: Text(_wait > 0
                        ? 'അടുത്തത് $_wait s-ൽ (Next in $_wait s)'
                        : remaining <= 0
                            ? 'Daily cap reached (ഇന്നത്തെ പരിധി)'
                            : 'WhatsApp-ൽ അയക്കുക (Open WhatsApp & mark Sent)'),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => _skip(q),
                        child: const Text('Skip (ഒഴിവാക്കുക)'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => _skip(q, optOut: true),
                        child: const Text('Opt out (STOP)'),
                      ),
                    ),
                  ]),
                  if (_sender.needsUserTap)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                          'WhatsApp തുറക്കും — അവിടെ Send അമർത്തുക. (WhatsApp opens; press Send there.)',
                          style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            ),
          if (_queue.length > 1) ...[
            const SizedBox(height: 12),
            const Text('അടുത്തത് (Up next)',
                style: TextStyle(fontWeight: FontWeight.w700)),
            for (final n in _queue.skip(1).take(5))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(n.customer.name),
                subtitle: Text(n.customer.phone),
              ),
          ],
        ],
      )),
    );
  }
}
