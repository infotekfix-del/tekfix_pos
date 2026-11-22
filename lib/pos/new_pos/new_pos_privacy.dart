// New POS (Step 3f): Customer View (privacy mode on a single monitor).
// Part of main.dart: builds the CustomerDisplayState from the bill on the
// counter (only name / qty / selling price / masked IMEI cross over) and
// shows it full screen. Leaving needs Esc + the staff PIN.
part of '../../main.dart';

const String kPosWelcomeSetting = 'pos_welcome_message';

/// The ONLY thing the customer screen gets.
CustomerDisplayState _posDisplayStateFor(_NewPosShellState s) {
  final h = s.h;
  final shop = Db.setting('shop_name', 'TEKFIX DIGITAL');
  if (h._cart.isEmpty && s._thanks != null) return s._thanks!;
  final total = h._total;
  var credit = 0.0;
  switch (s._mode) {
    case PosPayMode.credit:
      credit = total;
    case PosPayMode.split:
      credit = math.max(0, total - _d(h._cashCtrl.text) - _d(h._upiCtrl.text));
    case PosPayMode.cash:
    case PosPayMode.upi:
      break;
  }
  final linked = h._partyKey != null;
  final prev = linked ? _d(_m(Db.parties.get(h._partyKey))['balance']) : 0.0;
  String? qr;
  if (s._mode == PosPayMode.upi && !s._upiOk) {
    final vpa = posShopVpa();
    if (posValidVpa(vpa)) {
      qr = posUpiUri(vpa: vpa, payee: shop, amount: total, note: '$shop bill');
    }
  }
  return posBuildDisplayState(
    // Only real IMEI units show a masked IMEI on the customer screen; an
    // item code kept in the IMEI box is not shown.
    cart: [
      for (final l in h._cart)
        posIsUnitItem(l, _i(_m(Db.items.get(l['key']))['stock']))
            ? l
            : {...l, 'imei': ''}
    ],
    customerName: linked ? h._name.text : '',
    previousDue: prev,
    subtotal: h._subtotal,
    discount: h._discountAmt,
    total: total,
    creditThisBill: credit,
    paymentConfirmed: s._mode == PosPayMode.upi && s._upiOk,
    upiQrPayload: qr,
    welcome: Db.setting(kPosWelcomeSetting, ''),
    shopName: shop,
  );
}

/// Thank-you screen data from a SAVED bill (numbers and the name only).
CustomerDisplayState _posThanksFor(Map<String, dynamic> bill) {
  final due = _d(bill['due']);
  final paid = _d(bill['cash']) + _d(bill['upi']);
  final pk = bill['partyKey'];
  var prev = 0.0;
  if (pk != null) {
    // party balance now includes this bill's due
    prev = _d(_m(Db.parties.get(pk))['balance']) - due;
  }
  return posThanksState(
    total: _d(bill['total']),
    paid: paid,
    due: due,
    customerName: pk == null ? '' : '${bill['customerName'] ?? ''}',
    previousDue: prev,
    shopName: Db.setting('shop_name', 'TEKFIX DIGITAL'),
  );
}

/// Full-screen customer page. Read-only; every key is swallowed except Esc,
/// which asks for the staff PIN.
class _PosCustomerViewPage extends StatefulWidget {
  final ValueListenable<CustomerDisplayState> state;
  const _PosCustomerViewPage({required this.state});

  @override
  State<_PosCustomerViewPage> createState() => _PosCustomerViewPageState();
}

class _PosCustomerViewPageState extends State<_PosCustomerViewPage> {
  bool _asking = false;

  Future<void> _esc() async {
    if (_asking) return;
    _asking = true;
    final ok = await _posAskPin(context);
    _asking = false;
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
            _esc();
          }
          return KeyEventResult.handled; // nothing reaches the POS
        },
        child: Scaffold(
          body: ValueListenableBuilder<CustomerDisplayState>(
            valueListenable: widget.state,
            builder: (_, v, __) => CustomerDisplayView(state: v),
          ),
        ),
      ),
    );
  }
}

Future<bool> _posAskPin(BuildContext context) async {
  final stored = '${Db.settings.get(kPosViewPinSetting) ?? ''}';
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PosPinDialog(storedHash: stored),
  );
  return ok == true;
}

/// Owns its text controller, so it is only freed when the dialog is gone
/// (not while it is still animating out).
class _PosPinDialog extends StatefulWidget {
  final String storedHash;
  const _PosPinDialog({required this.storedHash});

  @override
  State<_PosPinDialog> createState() => _PosPinDialogState();
}

class _PosPinDialogState extends State<_PosPinDialog> {
  final _c = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _check() {
    if (posPinMatches(widget.storedHash, _c.text.trim())) {
      Navigator.pop(context, true);
    } else {
      setState(() => _err = 'Wrong PIN (PIN തെറ്റാണ്)');
      _c.clear();
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Staff PIN to leave (സ്റ്റാഫ് PIN)'),
        content: SizedBox(
          width: 280,
          child: TextField(
            controller: _c,
            autofocus: true,
            obscureText: true,
            maxLength: 6,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _check(),
            decoration: InputDecoration(labelText: 'PIN', errorText: _err),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay (തുടരുക)'),
          ),
          FilledButton(onPressed: _check, child: const Text('Leave (പുറത്ത്)')),
        ],
      );
}

/// Owner / admin: set the 4-6 digit PIN (stored hashed).
Future<bool> _posSetPin(BuildContext context) async {
  final a = TextEditingController();
  final b = TextEditingController();
  var saved = false;
  await formDialog(
    context,
    title: 'Customer View PIN (കസ്റ്റമർ വ്യൂ PIN)',
    saveLabel: 'Save (സേവ്)',
    body: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: Text('4–6 digits. Staff need it to leave Customer View. '
            '(Customer View-ൽ നിന്ന് പുറത്തുവരാൻ)'),
      ),
      tf(a, 'New PIN (പുതിയ PIN)', number: true, obscure: true),
      tf(b, 'Repeat PIN (വീണ്ടും)', number: true, obscure: true),
    ]),
    onSave: () async {
      final p = a.text.trim();
      if (!posValidPinFormat(p)) return '4–6 digits only (4–6 അക്കം മാത്രം)';
      if (p != b.text.trim()) return 'PINs do not match (PIN ഒന്നല്ല)';
      await Db.settings.put(kPosViewPinSetting, posPinHash(p));
      saved = true;
      return null;
    },
  );
  _posDisposeLater([a, b]);
  return saved;
}

/// Owner / admin: the text on the customer screen when no bill is open.
Future<void> _posEditWelcome(BuildContext context) async {
  final c = TextEditingController(text: Db.setting(kPosWelcomeSetting, ''));
  await formDialog(
    context,
    title: 'Customer screen welcome (സ്വാഗത സന്ദേശം)',
    saveLabel: 'Save (സേവ്)',
    body: (_) => tf(c, 'Shown when no bill is open', lines: 3),
    onSave: () async {
      await Db.settings.put(kPosWelcomeSetting, c.text.trim());
      return null;
    },
  );
  _posDisposeLater([c]);
}

/// Frees dialog text controllers after the dialog has finished closing
/// (its fields still rebuild during the close animation).
void _posDisposeLater(List<TextEditingController> cs) {
  Future<void>.delayed(const Duration(milliseconds: 600), () {
    for (final c in cs) {
      c.dispose();
    }
  });
}

/// Welcome screen (used when the POS closes).
CustomerDisplayState _posDisplayIdle() {
  final w = Db.setting(kPosWelcomeSetting, '');
  return CustomerDisplayState(
    phase: DisplayPhase.idle,
    shopName: Db.setting('shop_name', 'TEKFIX DIGITAL'),
    message: w.trim().isEmpty ? kDisplayWelcome : w.trim(),
  );
}

/// Owner / admin: Customer Display Auto / Second monitor / Off.
Future<void> _posPickDisplayMode(BuildContext context) async {
  final cur = customerDisplayModeFrom(
      Db.setting(kCustomerDisplaySetting, CustomerDisplayMode.auto.name));
  final picked = await showDialog<CustomerDisplayMode>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Customer Display (കസ്റ്റമർ ഡിസ്പ്ലേ)'),
      children: [
        for (final m in CustomerDisplayMode.values)
          ListTile(
            leading: Icon(m == cur
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_off_rounded),
            title: Text(m.label),
            subtitle: Text(switch (m) {
              CustomerDisplayMode.auto =>
                'Use a second monitor when one is connected',
              CustomerDisplayMode.second =>
                'Always use the second monitor; warn when it is missing',
              CustomerDisplayMode.off => 'Never open the customer window',
            }),
            onTap: () => Navigator.pop(ctx, m),
          ),
      ],
    ),
  );
  if (picked == null) return;
  await Db.settings.put(kCustomerDisplaySetting, picked.name);
  CustomerDisplayHost.instance.setMode(picked);
}
