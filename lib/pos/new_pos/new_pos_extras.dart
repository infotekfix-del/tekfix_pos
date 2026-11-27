// New POS (Step 3h): hold / resume, recent bills + reprint, shortcuts help.
// Part of main.dart. Held bills are a local settings key only; recent
// bills are read-only (reprint / WhatsApp use the existing functions).
part of '../../main.dart';

List<Map<String, dynamic>> _posHeldList() =>
    posHeldFrom(Db.settings.get(kPosHeldSetting));

Future<void> _posSaveHeld(List<Map<String, dynamic>> list) =>
    Db.settings.put(kPosHeldSetting, list);

bool _posIsOwnerish() {
  final a = AuthController.instance;
  return a.isOwner || a.isAdmin;
}

/// F6: park the bill (no stock change, no sale, no invoice number).
Future<void> _posHoldBill(_NewPosShellState s) async {
  final h = s.h;
  final ctx = s.context;
  if (h._cart.isEmpty) {
    toast(ctx, 'Nothing to hold – the bill is empty (ബിൽ ശൂന്യമാണ്)',
        error: true);
    return;
  }
  final list = _posHeldList();
  if (list.length >= kPosMaxHeld) {
    toast(
        ctx,
        'Max $kPosMaxHeld held bills – resume or discard one first '
        '(പരമാവധി $kPosMaxHeld)',
        error: true);
    return;
  }
  final draft = posHeldDraft(
    cart: h._cart,
    customerPhone: h._phone.text,
    customerName:
        h._partyKey == null && h._phone.text.trim().isEmpty ? '' : h._name.text,
    partyId: h._partyId,
    discount: h._discount.text,
    by: AuthController.instance.name.trim().isNotEmpty
        ? AuthController.instance.name.trim()
        : Db.setting('active_user', 'Staff'),
    now: DateTime.now(),
  );
  await _posSaveHeld([...list, draft]);
  _posClearBill(s);
  if (ctx.mounted) {
    ScaffoldMessenger.of(ctx).hideCurrentSnackBar();
    toast(ctx, 'Bill held (ഹോൾഡ് ചെയ്തു) – F7 to resume');
  }
}

/// Empties the counter exactly like a finished bill does.
void _posClearBill(_NewPosShellState s) {
  final h = s.h;
  s._upd(() {
    h._cart.clear();
    h._partyKey = null;
    h._partyId = null;
    h._saleDate = DateTime.now();
    for (final c in [h._discount, h._cashCtrl, h._upiCtrl]) {
      c.clear();
    }
    s._setMode(PosPayMode.cash);
  });
  h._crmCtrl.phone.clear();
  h._crmCtrl.name.clear();
  h._crmCtrl.lookupNow();
}

/// Brings a held bill back, re-checked against current stock / prices.
Future<bool> _posResume(_NewPosShellState s, Map<String, dynamic> held) async {
  final h = s.h;
  final ctx = s.context;
  if (h._cart.isNotEmpty) {
    toast(ctx, 'Finish or hold (F6) the current bill first (ആദ്യം ഈ ബിൽ)',
        error: true);
    return false;
  }
  final byId = <String, _PosEntry>{};
  final byKey = <String, _PosEntry>{};
  for (final e in entriesOf(Db.items)) {
    final id = '${e.value['_id'] ?? ''}';
    if (id.isNotEmpty) byId[id] = e;
    byKey['${e.key}'] = e;
  }
  final plan = posPlanResume(held, find: (l) {
    final e = byId['${l['itemId'] ?? ''}'] ?? byKey['${l['key']}'];
    return e == null ? null : (key: e.key, item: e.value);
  });
  if (plan.warnings.isNotEmpty) {
    final go = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded,
            color: PosTokens.warning, size: 40),
        title: const Text('Changed since it was held (മാറ്റങ്ങൾ ഉണ്ട്)'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final w in plan.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• '),
                      Expanded(child: Text(w)),
                    ]),
              ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel (റദ്ദാക്കുക)')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Resume anyway (തുടരുക)')),
        ],
      ),
    );
    if (go != true || !ctx.mounted) return false;
  }
  if (plan.lines.isEmpty) {
    toast(ctx, 'Nothing left to resume (ഒന്നും ബാക്കിയില്ല)', error: true);
    return false;
  }
  // Lines are created by the existing _addToCart (same shape and stock
  // rule), then the held qty (already capped at stock) and price are set.
  for (final l in plan.lines) {
    h._addToCart(l.key, Map<String, dynamic>.from(l.item));
  }
  s._upd(() {
    for (final l in plan.lines) {
      final i = h._cart.indexWhere((c) => c['key'] == l.key);
      if (i < 0) continue;
      h._cart[i]['qty'] = l.qty;
      h._cart[i]['price'] = l.price;
    }
    h._discount.text = '${held['discount'] ?? ''}';
  });
  // Customer: by phone (CRM link), else the party id.
  final phone = '${held['customerPhone'] ?? ''}'.trim();
  if (phone.isNotEmpty) {
    h._crmCtrl.phone.text = phone;
    h._crmCtrl.name.text = '${held['customerName'] ?? ''}';
    h._crmCtrl.lookupNow();
  } else if ('${held['partyId'] ?? ''}'.isNotEmpty &&
      '${held['partyId']}' != 'null') {
    for (final e in entriesOf(Db.parties)) {
      if ('${e.value['_id']}' == '${held['partyId']}') {
        s._upd(() {
          h._partyKey = e.key;
          h._partyId = e.value['_id'];
          h._name.text = '${e.value['name'] ?? ''}';
        });
        break;
      }
    }
  }
  final rest = _posHeldList().where((x) => x['id'] != held['id']).toList();
  await _posSaveHeld(rest);
  if (ctx.mounted) toast(ctx, 'Bill resumed (തിരികെ എടുത്തു)');
  return true;
}

/// Right-side panel used by Held bills and Recent bills.
Future<void> _posSidePanel(
  BuildContext context, {
  required String title,
  required IconData icon,
  required Widget Function(BuildContext ctx, StateSetter set) body,
}) {
  final theme = Theme.of(context);
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    transitionDuration: PosTokens.fast,
    pageBuilder: (ctx, _, __) => Theme(
      data: theme,
      child: Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: PosTokens.bg,
          elevation: 8,
          child: SizedBox(
            width: math.min(480, MediaQuery.sizeOf(ctx).width),
            height: double.infinity,
            child: SafeArea(
              child: StatefulBuilder(
                builder: (ctx, set) => Column(children: [
                  ListTile(
                    leading: Icon(icon, color: PosTokens.primary),
                    title: Text(title, style: PosTokens.sectionTitle),
                    trailing: IconButton(
                      tooltip: 'Close (അടയ്ക്കുക)',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ),
                  const Divider(),
                  Expanded(child: body(ctx, set)),
                ]),
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (_, a, __, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: a, curve: Curves.easeOut)),
      child: child,
    ),
  );
}

/// F7: held bills (resume; owner / admin may discard).
Future<void> _posOpenHeld(_NewPosShellState s) {
  final ctx = s.context;
  return _posSidePanel(
    ctx,
    title: 'Held bills (ഹോൾഡ് ബില്ലുകൾ)',
    icon: Icons.pause_circle_rounded,
    body: (pctx, set) {
      final list = _posHeldList().reversed.toList();
      if (list.isEmpty) {
        return const _PosEmpty(
            icon: Icons.pause_circle_outline_rounded,
            text: 'No held bills (ഹോൾഡ് ബില്ലുകൾ ഇല്ല)\nF6 holds the bill');
      }
      final now = DateTime.now();
      return ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: list.length,
        itemBuilder: (_, i) {
          final hb = list[i];
          final who = '${hb['customerName'] ?? ''}'.trim();
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: PosTokens.surface,
              borderRadius: PosTokens.br,
              border: Border.all(color: PosTokens.border),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(who.isEmpty ? 'Walk-in (വാക്ക്-ഇൻ)' : who,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: PosTokens.text)),
                    ),
                    Text(rs(posHeldTotal(hb)),
                        style: PosTokens.money.copyWith(fontSize: 16)),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                      '${posHeldCount(hb)} items · held '
                      '${posHeldAge('${hb['heldAt']}', now)} ago · '
                      'by ${hb['by'] ?? '-'}',
                      style: PosTokens.label.copyWith(fontSize: 12)),
                  Text(
                      [
                        for (final l in (hb['lines'] as List?) ?? const [])
                          if (l is Map) '${l['name']} × ${l['qty']}'
                      ].join(', '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5, color: PosTokens.muted)),
                  const SizedBox(height: 8),
                  Row(children: [
                    if (_posIsOwnerish())
                      TextButton.icon(
                        style: TextButton.styleFrom(
                            foregroundColor: PosTokens.error),
                        onPressed: () async {
                          final ok = await confirm(pctx,
                              'Discard this held bill? (ഈ ഹോൾഡ് ബിൽ കളയണോ?)',
                              yes: 'Discard (കളയുക)');
                          if (!ok) return;
                          await _posSaveHeld(_posHeldList()
                              .where((x) => x['id'] != hb['id'])
                              .toList());
                          set(() {});
                          s._upd(() {});
                        },
                        icon:
                            const Icon(Icons.delete_outline_rounded, size: 18),
                        label: const Text('Discard (കളയുക)'),
                      ),
                    const Spacer(),
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        Navigator.pop(pctx);
                        await _posResume(s, hb);
                      },
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Resume (തുടരുക)'),
                    ),
                  ]),
                ]),
          );
        },
      );
    },
  );
}

/// The newest [n] sales (read-only).
List<Map<String, dynamic>> _posRecentSales({int n = 20}) {
  final keys = Db.sales.keys.toList();
  final out = <Map<String, dynamic>>[];
  for (var i = keys.length - 1; i >= 0 && out.length < n; i--) {
    final v = Db.sales.get(keys[i]);
    if (v is Map) out.add(_m(v));
  }
  return out;
}

/// Recent bills: reprint / resend WhatsApp, nothing editable.
Future<void> _posOpenRecent(BuildContext context) {
  return _posSidePanel(
    context,
    title: 'Recent bills (സമീപകാല ബില്ലുകൾ)',
    icon: Icons.history_rounded,
    body: (pctx, _) {
      final bills = _posRecentSales();
      if (bills.isEmpty) {
        return const _PosEmpty(
            icon: Icons.receipt_long_outlined,
            text: 'No bills yet (ബില്ലുകൾ ഇല്ല)');
      }
      return ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: bills.length,
        itemBuilder: (_, i) {
          final b = bills[i];
          final s = invoicePaymentSummary(b);
          final when =
              DateTime.tryParse('${b['saleDate'] ?? b['createdAt'] ?? ''}')
                  ?.toLocal();
          final phone = '${b['customerPhone'] ?? ''}'.trim();
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
            decoration: BoxDecoration(
              color: PosTokens.surface,
              borderRadius: PosTokens.br,
              border: Border.all(color: PosTokens.border),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text('${b['invoice'] ?? '-'}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: PosTokens.text)),
                    ),
                    Text(rs(_d(b['total'])),
                        style: PosTokens.money.copyWith(fontSize: 16)),
                    const SizedBox(width: 6),
                  ]),
                  Text(
                      '${when == null ? '-' : dtFormat.format(when)} · '
                      '${b['customerName'] ?? 'Walk-in'} · '
                      '${switch (s.status) {
                        InvoicePaymentStatus.paid => 'PAID',
                        InvoicePaymentStatus.partial => 'PARTIAL',
                        InvoicePaymentStatus.pending => 'PENDING',
                      }}',
                      style: PosTokens.label.copyWith(fontSize: 12)),
                  Wrap(spacing: 4, children: [
                    TextButton.icon(
                      onPressed: () => printInvoice(context, b, a4: false),
                      icon: const Icon(Icons.receipt_rounded, size: 18),
                      label: const Text('Thermal (തെർമൽ)'),
                    ),
                    TextButton.icon(
                      onPressed: () => printInvoice(context, b, a4: true),
                      icon: const Icon(Icons.print_rounded, size: 18),
                      label: const Text('A4'),
                    ),
                    if (phone.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => sendInvoiceWhatsApp(context, b),
                        icon: const Icon(Icons.send_rounded,
                            size: 18, color: PosTokens.success),
                        label: const Text('WhatsApp'),
                      ),
                  ]),
                ]),
          );
        },
      );
    },
  );
}

/// Ctrl+P: reprint the last bill on the thermal printer.
void _posReprintLast(BuildContext context) {
  final last = _posRecentSales(n: 1);
  if (last.isEmpty) {
    toast(context, 'No bill to reprint yet (ബില്ലുകൾ ഇല്ല)', error: true);
    return;
  }
  printInvoice(context, last.first, a4: false);
}

/// F1 / "?" : keyboard shortcuts.
Future<void> _posShowHelp(BuildContext context) {
  const keys = [
    ('F2 / Ctrl+F', 'Product search (തിരയുക)'),
    ('F3', 'Customer search (കസ്റ്റമർ)'),
    ('F4', 'View All Items (എല്ലാ ഐറ്റംസ്)'),
    ('F6', 'Hold bill (ഹോൾഡ്)'),
    ('F7', 'Held bills (ഹോൾഡ് ബില്ലുകൾ)'),
    ('F8', 'Discount (കിഴിവ്)'),
    ('F9', 'Payment (പേയ്മെന്റ്)'),
    ('F11', 'Customer View (കസ്റ്റമർ വ്യൂ)'),
    ('F12 / Ctrl+Enter', 'Complete payment (ബിൽ പൂർത്തിയാക്കുക)'),
    ('Ctrl+P', 'Reprint last bill – thermal (വീണ്ടും പ്രിന്റ്)'),
    ('Ctrl+R', 'Recent bills (സമീപകാല ബില്ലുകൾ)'),
    ('↑ ↓ Enter', 'Pick from a list (തിരഞ്ഞെടുക്കുക)'),
    ('Esc', 'Close / clear search (അടയ്ക്കുക)'),
    ('Alt (hold)', 'Owner: show cost on cards'),
    ('F1', 'This help (സഹായം)'),
  ];
  final theme = Theme.of(context);
  return showDialog(
    context: context,
    builder: (ctx) => Theme(
      data: theme,
      child: AlertDialog(
        title: const Text('Keyboard shortcuts (കീബോർഡ്)'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final (k, v) in keys)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Container(
                      width: 150,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: PosTokens.primarySoft,
                        borderRadius: PosTokens.brSm,
                      ),
                      child: Text(k,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: PosTokens.primaryDark)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(v)),
                  ]),
                ),
            ]),
          ),
        ),
        actions: [
          FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK')),
        ],
      ),
    ),
  );
}
