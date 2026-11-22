// New POS (Step 3e): payment area, UPI QR and the "bill saved" dialog.
// Part of main.dart. The bill is still saved by the existing
// _SaleViewState._checkout (called once); this file only fills the
// existing Cash and UPI/Card amounts from the chosen mode, helps with change,
// shows a UPI QR and asks the cashier to confirm UPI/Card money.
part of '../../main.dart';

const String kShopUpiSetting = 'shop_upi';
const String kShopUpiDefault = 'Q085585286@ybl'; // same as staff POS

String posShopVpa() => Db.setting(kShopUpiSetting, kShopUpiDefault).trim();

class _PosPaymentBox extends StatelessWidget {
  final _NewPosShellState shell;
  final void Function(VoidCallback) upd;
  final BuildContext? sheetCtx;
  const _PosPaymentBox({
    required this.shell,
    required this.upd,
    this.sheetCtx,
  });

  _SaleViewState get h => shell.h;

  @override
  Widget build(BuildContext context) {
    final total = h._total;
    final empty = h._cart.isEmpty;
    Widget row(String k, String v, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            Expanded(child: Text(k, style: PosTokens.label)),
            Text(v,
                style: PosTokens.money
                    .copyWith(fontSize: 14, color: color ?? PosTokens.text)),
          ]),
        );
    final busy = shell._saving || h._busy;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        color: PosTokens.surfaceAlt,
        border: Border(top: BorderSide(color: PosTokens.border)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        row('Subtotal (ഉപതുക)', rs(h._subtotal)),
        if (h._discountAmt > 0)
          row(
              'Discount (കിഴിവ്) '
                  '${posDiscountPercent(h._discountAmt, h._subtotal)}',
              '− ${rs(h._discountAmt)}',
              color: PosTokens.success),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          const Expanded(
            child: Text('GRAND TOTAL (ആകെ)',
                style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: PosTokens.text,
                    fontSize: 14)),
          ),
          Text(rs(total), style: PosTokens.grandTotal),
        ]),
        const SizedBox(height: 12),
        const PosSectionLabel(
            'Payment', 'പേയ്മെന്റ്', Icons.account_balance_wallet_outlined),
        Row(children: [
          for (final m in PosPayMode.values) ...[
            if (m != PosPayMode.cash) const SizedBox(width: 6),
            Expanded(
              child: _PayModeButton(
                mode: m,
                selected: shell._mode == m,
                enabled: !empty,
                onTap: () => upd(() => shell._setMode(m)),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        _modeDetail(context, total, empty),
        const SizedBox(height: 10),
        AnimatedContainer(
          duration: PosTokens.fast,
          width: double.infinity,
          height: 56,
          decoration: BoxDecoration(
            borderRadius: PosTokens.br,
            gradient: empty ? null : PosTokens.gradient,
            boxShadow: empty ? null : PosTokens.glow,
          ),
          child: FilledButton.icon(
            style: empty
                ? null
                : FilledButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white),
            onPressed: empty || busy
                ? null
                : () => shell._complete(sheetCtx: sheetCtx),
            icon: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Colors.white))
                : const Icon(Icons.check_circle_rounded),
            label: FittedBox(
              child: PosBiText('COMPLETE PAYMENT  ·  F12', 'ബിൽ പൂർത്തിയാക്കുക',
                  cross: CrossAxisAlignment.center,
                  mlColor: empty ? PosTokens.subtle : Colors.white70,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: empty ? PosTokens.subtle : Colors.white)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _modeDetail(BuildContext context, double total, bool empty) {
    switch (shell._mode) {
      case PosPayMode.cash:
        final t = posTender(total, shell._tender.text);
        // Quick cash buttons share one row under the field, so they fit
        // the narrow (340 px) bill panel too.
        Widget quick(String label, double v, {bool first = false}) => Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: first ? 0 : 4),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(40, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  onPressed: empty || v + 0.001 < total
                      ? null
                      : () => upd(() => shell._tender.text = _numText(v)),
                  child: FittedBox(
                    child: Text(label,
                        style:
                            const TextStyle(fontFeatures: PosTokens.tabular)),
                  ),
                ),
              ),
            );
        return Column(children: [
          TextField(
            controller: shell._tender,
            focusNode: sheetCtx == null ? shell._payFocus : null,
            enabled: !empty,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => upd(() {}),
            onSubmitted: (_) => shell._complete(sheetCtx: sheetCtx),
            decoration: const InputDecoration(
              labelText: 'Received ₹ (ലഭിച്ചത്)',
              hintText: 'Empty = exact amount',
            ),
          ),
          const SizedBox(height: 6),
          Row(children: [
            quick('Exact', total, first: true),
            for (final q in kPosQuickCash) quick('₹$q', q.toDouble()),
          ]),
          if (t.error != null && shell._tender.text.trim().isNotEmpty)
            _note(t.error!, PosTokens.error, Icons.error_outline_rounded)
          else if (t.change > 0)
            _bigLine('Give change (ബാക്കി കൊടുക്കുക)', rs(t.change),
                PosTokens.warning),
        ]);
      case PosPayMode.upi:
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                onPressed: empty
                    ? null
                    : () => _posShowUpiQr(context, shell, sheetCtx: sheetCtx),
                icon: const Icon(Icons.qr_code_2_rounded),
                label: const Text('Show UPI QR (QR കാണിക്കുക)',
                    overflow: TextOverflow.ellipsis),
              ),
              shell._upiOk
                  ? _note('Received (ലഭിച്ചു)', PosTokens.success,
                      Icons.check_circle_rounded)
                  : _note(
                      'Not confirmed (ഉറപ്പാക്കിയില്ല) – card: just complete',
                      PosTokens.warning,
                      Icons.hourglass_top_rounded),
            ]);
      case PosPayMode.credit:
        final c = h._crmCtrl.found;
        if (h._partyKey == null && !h._crmCtrl.willHaveCustomer) {
          return Row(children: [
            Expanded(
              child: _note(
                  'Credit needs a customer (ക്രെഡിറ്റിന് കസ്റ്റമർ വേണം)',
                  PosTokens.error,
                  Icons.person_off_rounded),
            ),
            TextButton(
              onPressed: () => shell._custFocus.requestFocus(),
              child: const Text('Select (F3)'),
            ),
          ]);
        }
        final old = (c?.balancePaise ?? 0) / 100;
        return Column(children: [
          _bigLine('On credit (കടം)', rs(total), PosTokens.warning),
          if (c != null)
            _note(
                'Total due after this bill (ഈ ബില്ലിന് ശേഷം ആകെ ബാക്കി): '
                '${rs(old + total)}',
                PosTokens.muted,
                Icons.info_outline_rounded),
        ]);
      case PosPayMode.split:
        final cash = _d(h._cashCtrl.text);
        final upi = _d(h._upiCtrl.text);
        final due = _r2(total - cash - upi);
        return Column(children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: h._cashCtrl,
                focusNode: sheetCtx == null ? shell._payFocus : null,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => upd(() {}),
                decoration: const InputDecoration(labelText: 'Cash ₹'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: h._upiCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => upd(() {}),
                decoration: const InputDecoration(labelText: 'UPI / Card ₹'),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          if (due < 0)
            _note('More than the bill (ബില്ലിനേക്കാൾ കൂടുതൽ): ${rs(-due)}',
                PosTokens.error, Icons.error_outline_rounded)
          else
            _bigLine(
                due == 0
                    ? 'Fully paid (മുഴുവൻ അടച്ചു)'
                    : 'Rest on credit (ബാക്കി കടം)',
                rs(due),
                due == 0 ? PosTokens.success : PosTokens.warning),
        ]);
    }
  }

  Widget _bigLine(String k, String v, Color c) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Expanded(
            child: Text(k,
                style: TextStyle(fontWeight: FontWeight.w800, color: c)),
          ),
          Text(v,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: c,
                  fontFeatures: PosTokens.tabular)),
        ]),
      );

  Widget _note(String text, Color c, IconData icon) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: c)),
          ),
        ]),
      );
}

class _PayModeButton extends StatelessWidget {
  final PosPayMode mode;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  const _PayModeButton({
    required this.mode,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (String en, String ml, IconData icon, Color color) = switch (mode) {
      PosPayMode.cash => (
          'CASH',
          'പണം',
          Icons.payments_rounded,
          PosTokens.cash
        ),
      PosPayMode.upi => (
          'UPI / CARD',
          'യുപിഐ',
          Icons.qr_code_2_rounded,
          PosTokens.upi
        ),
      PosPayMode.credit => (
          'CREDIT',
          'കടം',
          Icons.schedule_rounded,
          PosTokens.credit
        ),
      PosPayMode.split => (
          'SPLIT',
          'വിഭജിക്കുക',
          Icons.call_split_rounded,
          PosTokens.secondary
        ),
    };
    // Dark theme: the selected mode glows in its own colour (tinted fill,
    // bright border and text) instead of a solid block.
    final fg = !enabled ? PosTokens.subtle : color;
    return Semantics(
      button: true,
      selected: selected,
      label: '$en ($ml)',
      child: Material(
        color: selected && enabled
            ? color.withValues(alpha: 0.2)
            : color.withValues(alpha: 0.06),
        borderRadius: PosTokens.br,
        child: InkWell(
          borderRadius: PosTokens.br,
          onTap: enabled ? onTap : null,
          child: Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              borderRadius: PosTokens.br,
              border: Border.all(
                  color: selected ? color : color.withValues(alpha: 0.35),
                  width: selected ? 2 : 1),
            ),
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(selected ? Icons.check_circle_rounded : icon,
                    size: 16, color: fg),
                const SizedBox(width: 3),
                Flexible(
                  child: FittedBox(
                    child: Text(en,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            color: fg)),
                  ),
                ),
              ]),
              FittedBox(
                child: Text(ml,
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// UPI QR for the exact amount. The app cannot see the bank, so the
/// cashier confirms the money arrived ("UPI Received"); only then the bill
/// is completed.
Future<void> _posShowUpiQr(BuildContext context, _NewPosShellState shell,
    {BuildContext? sheetCtx}) async {
  final h = shell.h;
  final total = h._total;
  final vpa = posShopVpa();
  final payee = Db.setting('shop_name', 'TEKFIX DIGITAL');
  if (!posValidVpa(vpa)) {
    toast(context,
        'Shop UPI ID is not set or invalid (UPI ഐഡി ശരിയല്ല) – owner: ⋮ menu',
        error: true);
    return;
  }
  final uri =
      posUpiUri(vpa: vpa, payee: payee, amount: total, note: '$payee bill');
  final theme = Theme.of(context);
  final received = await showDialog<bool>(
    context: context,
    builder: (ctx) => Theme(
      data: theme,
      child: AlertDialog(
        title: const Text('Scan to pay (സ്കാൻ ചെയ്ത് പണമടയ്ക്കുക)'),
        content: SizedBox(
          width: 300,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(
                data: uri,
                size: 240,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            Text(rs(total), style: PosTokens.grandTotal),
            Text('$payee · $vpa',
                textAlign: TextAlign.center, style: PosTokens.label),
            const SizedBox(height: 10),
            const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.hourglass_top_rounded,
                  size: 16, color: PosTokens.warning),
              SizedBox(width: 6),
              Flexible(
                child: Text(
                    'Waiting – check your UPI app / bank SMS '
                    '(പണം വന്നോ എന്ന് നോക്കുക)',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: PosTokens.warning)),
              ),
            ]),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet (ഇല്ല)'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: PosTokens.success,
                foregroundColor: PosTokens.onBright),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.check_rounded),
            label: const Text('UPI Received (ലഭിച്ചു)'),
          ),
        ],
      ),
    ),
  );
  if (received != true || !shell.mounted) return;
  shell._upiOkTotal = total;
  shell._upd(() {});
  final sheet = sheetCtx;
  // confirmed: save now (the cart sheet, if any, closes after saving)
  await shell._complete(
      sheetCtx: sheet != null && sheet.mounted ? sheet : null);
}

/// After a successful save: invoice number, payment, change, and Print /
/// WhatsApp / New bill. Printing and WhatsApp use the existing functions.
Future<void> _posShowBillDone(
    BuildContext context, Map<String, dynamic> bill, double change) {
  final theme = Theme.of(context);
  final cash = _d(bill['cash']);
  final upi = _d(bill['upi']);
  final due = _d(bill['due']);
  return showDialog(
    context: context,
    builder: (ctx) => Theme(
      data: theme,
      child: AlertDialog(
        icon: const Icon(Icons.check_circle_rounded,
            color: PosTokens.success, size: 52),
        title: const Text('Bill saved (ബില്ലിംഗ് പൂർത്തിയായി!)'),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Invoice (ഇൻവോയ്സ്): ${bill['invoice']}',
                style: const TextStyle(
                    fontWeight: FontWeight.w800, color: PosTokens.text)),
            const SizedBox(height: 6),
            Text(rs(_d(bill['total'])), style: PosTokens.grandTotal),
            const SizedBox(height: 6),
            Text(
                [
                  if (cash > 0) 'Cash ${rs(cash)}',
                  if (upi > 0) 'UPI/Card ${rs(upi)}',
                  if (due > 0) 'Credit ${rs(due)}',
                ].join(' · '),
                textAlign: TextAlign.center,
                style: PosTokens.label),
            if (change > 0) ...[
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: PosTokens.warningSoft, borderRadius: PosTokens.brSm),
                child: Text('Give change (ബാക്കി കൊടുക്കുക): ${rs(change)}',
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: PosTokens.warning,
                        fontFeatures: PosTokens.tabular)),
              ),
            ],
          ]),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actionsOverflowButtonSpacing: 6,
        actions: [
          OutlinedButton.icon(
            icon: const Icon(Icons.print_rounded),
            label: const Text('A4'),
            onPressed: () => printInvoice(context, bill, a4: true),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.receipt_rounded),
            label: const Text('Thermal (തെർമൽ)'),
            onPressed: () => printInvoice(context, bill, a4: false),
          ),
          if ('${bill['customerPhone'] ?? ''}'.trim().isNotEmpty)
            OutlinedButton.icon(
              icon: const Icon(Icons.send_rounded, color: PosTokens.success),
              label: const Text('WhatsApp'),
              onPressed: () => sendInvoiceWhatsApp(context, bill),
            ),
          FilledButton.icon(
            autofocus: true,
            icon: const Icon(Icons.add_rounded),
            label: const Text('New bill (പുതിയ ബിൽ)'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    ),
  );
}

/// Owner / admin: the shop UPI ID used for the QR (local setting).
Future<void> _posEditShopUpi(BuildContext context) async {
  final c = TextEditingController(text: posShopVpa());
  await formDialog(
    context,
    title: 'Shop UPI ID (UPI ഐഡി)',
    saveLabel: 'Save (സേവ്)',
    body: (_) => tf(c, 'UPI ID, e.g. shop@okaxis'),
    onSave: () async {
      if (!posValidVpa(c.text)) {
        return 'Enter a valid UPI ID like name@bank (ശരിയായ UPI ഐഡി നൽകുക)';
      }
      await Db.settings.put(kShopUpiSetting, c.text.trim());
      return null;
    },
  );
  _posDisposeLater([c]);
}
