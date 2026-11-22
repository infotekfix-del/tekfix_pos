// New POS (Step 3d): bill lines. Part of main.dart: edits the SAME
// _SaleViewState._cart list the existing checkout saves. Rules kept:
// qty 1..stock counted over all lines of an item, price edit through the
// existing _editPrice dialog, an IMEI item is one unit and never added
// twice. "−  Qty  +" on every line:
//  - normal item: + / − by one, 0 removes the line (with Undo), + is off
//    at the stock limit, the number can be typed.
//  - IMEI item (one record per IMEI): + picks another unsold IMEI of the
//    same model (Cancel = nothing), − asks which IMEI to take off and
//    confirms the last unit. Item records are never changed or deleted.
part of '../../main.dart';

/// Blocks adding an IMEI / serial item that is already on the bill.
/// Returns true when blocked (and tells the cashier).
bool _posBlockDuplicateImei(
    BuildContext context, _SaleViewState h, dynamic key, Map item) {
  if (!posImeiAlreadyInCart(h._cart, key, item)) return false;
  toast(context, 'This IMEI is already in the bill (ഈ IMEI ബില്ലിൽ ഉണ്ട്)',
      error: true);
  return true;
}

class _PosCartLine extends StatefulWidget {
  final _SaleViewState host;
  final int index;
  final void Function(VoidCallback) upd;
  final void Function(int index) onRemove;
  const _PosCartLine({
    super.key,
    required this.host,
    required this.index,
    required this.upd,
    required this.onRemove,
  });

  @override
  State<_PosCartLine> createState() => _PosCartLineState();
}

class _PosCartLineState extends State<_PosCartLine> {
  late final TextEditingController _qty =
      TextEditingController(text: '${_i(_line['qty'])}');
  final _qtyFocus = FocusNode();

  /// True while a dialog of this line is open: extra taps are ignored.
  bool _working = false;

  _SaleViewState get h => widget.host;
  Map<String, dynamic> get _line => h._cart[widget.index];

  @override
  void initState() {
    super.initState();
    _qtyFocus.addListener(() {
      if (!_qtyFocus.hasFocus) _commitQty();
    });
  }

  @override
  void didUpdateWidget(covariant _PosCartLine old) {
    super.didUpdateWidget(old);
    if (widget.index >= h._cart.length) return;
    final q = '${_i(_line['qty'])}';
    if (!_qtyFocus.hasFocus && _qty.text != q) _qty.text = q;
  }

  @override
  void dispose() {
    _qty.dispose();
    _qtyFocus.dispose();
    super.dispose();
  }

  int get _stock => _i(_m(Db.items.get(_line['key']))['stock']);

  /// A real IMEI unit (IMEI box filled AND stock <= 1). Items that use the
  /// IMEI box as a short code (e.g. Photostat "1", stock 2340) count up.
  bool get _unit => posIsUnitItem(_line, _stock);

  bool get _alive => mounted && widget.index < h._cart.length;

  void _commitQty() {
    if (!_alive || _unit) return;
    final r = posLineQtyCheck(_qty.text, h._cart, widget.index, _stock);
    if (r.error != null) {
      toast(context, r.error!, error: true);
      _qty.text = '${_i(_line['qty'])}'; // back to the last valid qty
      return;
    }
    if (r.qty == 0) {
      widget.onRemove(widget.index); // with Undo
    } else if (r.qty != _i(_line['qty'])) {
      widget.upd(() => h._cart[widget.index]['qty'] = r.qty);
    }
  }

  // ------------------------------------------------------- normal items
  void _less() {
    if (_working || !_alive) return;
    if (_unit) {
      _lessImei();
      return;
    }
    final q = _i(_line['qty']);
    if (q <= 1) {
      widget.onRemove(widget.index); // 1 -> 0: line off, with Undo
    } else {
      widget.upd(() => h._cart[widget.index]['qty'] = q - 1);
    }
  }

  void _more() {
    if (_working || !_alive) return;
    if (_unit) {
      _moreImei();
      return;
    }
    final room = posQtyRoom(h._cart, _line['key'], _stock);
    if (room <= 0) {
      toast(context, posStockShortMsg(_stock), error: true);
      return;
    }
    widget.upd(() =>
        h._cart[widget.index]['qty'] = _i(h._cart[widget.index]['qty']) + 1);
  }

  // --------------------------------------------------------- IMEI items
  List<MapEntry<dynamic, Map>> _candidates() => posImeiCandidates(
      entriesOf(Db.items).map((e) => MapEntry<dynamic, Map>(e.key, e.value)),
      h._cart,
      posModelKey(_line));

  Future<void> _moreImei() async {
    final list = _candidates();
    if (list.isEmpty) {
      toast(context, posStockShortMsg(0), error: true);
      return;
    }
    setState(() => _working = true);
    try {
      final pick = await showDialog<MapEntry<dynamic, Map>>(
        context: context,
        builder: (ctx) => _PosImeiPickDialog<MapEntry<dynamic, Map>>(
          title: 'Select IMEI / Serial',
          titleMl: 'IMEI തിരഞ്ഞെടുക്കുക',
          subtitle: '${_line['name']} · ${list.length} in stock',
          rows: [
            for (final e in list)
              (
                label: '${e.value['imei']}',
                detail: rs(_d(e.value['sellingPrice'])),
                value: e
              ),
          ],
        ),
      );
      if (pick == null || !mounted) return; // Cancel = no change
      final cur = Db.items.get(pick.key);
      final item = cur == null ? null : _m(cur);
      if (item == null || _i(item['stock']) <= 0) {
        toast(context, posStockShortMsg(0), error: true);
        return;
      }
      if (_posBlockDuplicateImei(context, h, pick.key, item)) return;
      h._addToCart(pick.key, item); // the existing add (new IMEI line)
      widget.upd(() {});
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _lessImei() async {
    final lines = posImeiLinesOf(h._cart, posModelKey(_line),
        (l) => posIsUnitItem(l, _i(_m(Db.items.get(l['key']))['stock'])));
    setState(() => _working = true);
    try {
      int? target;
      if (lines.length > 1) {
        // Never pick silently: the cashier says which device comes off.
        target = await showDialog<int>(
          context: context,
          builder: (ctx) => _PosImeiPickDialog<int>(
            title: 'Which IMEI to remove?',
            titleMl: 'ഏത് IMEI മാറ്റണം?',
            subtitle: '${_line['name']} · ${lines.length} in bill',
            danger: true,
            rows: [
              for (final i in lines)
                (
                  label: '${h._cart[i]['imei']}',
                  detail: rs(_d(h._cart[i]['price'])),
                  value: i
                ),
            ],
          ),
        );
      } else {
        final ok = await confirm(
          context,
          'Remove the last unit? (അവസാന യൂണിറ്റ് മാറ്റണോ?)\n\n'
          '${_line['name']}\nIMEI ${_line['imei']}',
          yes: 'Remove (മാറ്റുക)',
        );
        if (ok) target = widget.index;
      }
      if (target == null || !mounted || target >= h._cart.length) return;
      widget.onRemove(target); // line off (with Undo); item record untouched
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = _line;
    final qty = _i(line['qty']);
    final price = _d(line['price']);
    final imei = _unit;
    final canMore = !_working &&
        (imei
            ? _candidates().isNotEmpty
            : posQtyRoom(h._cart, line['key'], _stock) > 0);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: PosTokens.surface,
        borderRadius: PosTokens.br,
        border: Border.all(color: PosTokens.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Tooltip(
                message: '${line['name']}',
                child: Text('${line['name']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: PosTokens.text)),
              ),
              // Last 4 digits only (the customer may see this screen).
              if (imei)
                Text(posImeiMasked('${line['imei']}'),
                    style: PosTokens.label.copyWith(
                        fontSize: 12, fontFeatures: PosTokens.tabular)),
            ]),
          ),
          IconButton(
            tooltip: 'Remove (മാറ്റുക)',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.delete_outline_rounded,
                color: PosTokens.error),
            onPressed: _working ? null : () => widget.onRemove(widget.index),
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          // Unit price: tap to change (existing price-edit dialog).
          Expanded(
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    borderRadius: PosTokens.brSm,
                    onTap: () =>
                        h._editPrice(widget.index, () => widget.upd(() {})),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: 2),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(
                          child: Text('${rs(price)} each',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PosTokens.label
                                  .copyWith(fontFeatures: PosTokens.tabular)),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.edit_rounded,
                            size: 14, color: PosTokens.subtle),
                      ]),
                    ),
                  ))),
          const SizedBox(width: 4),
          _stepper(qty, imei, canMore),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 64, maxWidth: 104),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(rs(price * qty),
                  textAlign: TextAlign.right,
                  style: PosTokens.money.copyWith(fontSize: 15)),
            ),
          ),
          const SizedBox(width: 8),
        ]),
      ]),
    );
  }

  /// "−  Qty  +" in one rounded pill, 40 px tap areas.
  Widget _stepper(int qty, bool imei, bool canMore) {
    final k = '${_line['key']}';
    Widget btn(IconData icon, String tip, VoidCallback? f, String id) =>
        SizedBox(
          width: 40,
          height: 40,
          child: IconButton(
            key: ValueKey('pos-qty-$id-$k'),
            tooltip: tip,
            padding: EdgeInsets.zero,
            iconSize: 20,
            color: PosTokens.primaryDark,
            disabledColor: PosTokens.subtle.withValues(alpha: 0.5),
            icon: Icon(icon),
            onPressed: f,
          ),
        );
    return Container(
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: PosTokens.surfaceAlt,
        borderRadius: PosTokens.br,
        border: Border.all(color: PosTokens.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        btn(
            Icons.remove_rounded,
            qty <= 1 ? 'Remove (മാറ്റുക)' : 'Less (കുറയ്ക്കുക)',
            _working ? null : _less,
            'minus'),
        SizedBox(
          width: 40,
          child: imei
              // One IMEI = one unit: the number is not typed.
              ? Text('$qty',
                  key: ValueKey('pos-qty-value-$k'),
                  textAlign: TextAlign.center,
                  style: PosTokens.money.copyWith(fontSize: 15))
              : TextField(
                  key: ValueKey('pos-qty-value-$k'),
                  controller: _qty,
                  focusNode: _qtyFocus,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: (_) => _commitQty(),
                  style: PosTokens.money.copyWith(fontSize: 15),
                  decoration: const InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
        ),
        btn(
            Icons.add_rounded,
            canMore
                ? (imei ? 'Add another IMEI (IMEI ചേർക്കുക)' : 'More (കൂട്ടുക)')
                : posStockShortMsg(imei ? 0 : _stock),
            canMore ? _more : null,
            'plus'),
      ]),
    );
  }
}

/// A short list to pick one IMEI from (add another unit / which to remove).
class _PosImeiPickDialog<T> extends StatelessWidget {
  final String title;
  final String titleMl;
  final String subtitle;
  final List<({String label, String detail, T value})> rows;
  final bool danger;
  const _PosImeiPickDialog({
    super.key,
    required this.title,
    required this.titleMl,
    required this.subtitle,
    required this.rows,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: PosBiText(title, titleMl,
            style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: PosTokens.text)),
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(subtitle, style: PosTokens.label),
              ),
            ),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final r in rows)
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: PosTokens.br),
                    leading: Icon(
                        danger
                            ? Icons.remove_circle_outline_rounded
                            : Icons.qr_code_2_rounded,
                        color: danger ? PosTokens.error : PosTokens.primary),
                    title: Text(r.label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontFeatures: PosTokens.tabular,
                            color: PosTokens.text)),
                    trailing: Text(r.detail, style: PosTokens.money),
                    onTap: () => Navigator.pop(context, r.value),
                  ),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel (വേണ്ട)'),
          ),
        ],
      );
}
