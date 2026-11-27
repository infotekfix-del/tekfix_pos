// New POS (Step 3a): theme + responsive shell behind the "Use new POS"
// setting. A `part` of main.dart on purpose: it drives the SAME
// _SaleViewState (same cart list, same customer controller, same
// _addToCart / _pickSaleDate / _finish -> _checkout), so no billing logic
// is copied or moved. The classic layout stays in _SaleViewState.build.
part of '../../main.dart';

/// Old local setting (settings box is not synced). The new POS is now the
/// only POS: the setting is ignored and the "Use old POS" option is gone.
const String kNewPosSetting = 'pos_new_ui';

/// Tests only: shows the classic screen so the old-vs-new bill comparison
/// can still run. Never set in the app.
@visibleForTesting
bool debugShowClassicPos = false;

bool newPosEnabled() => !debugShowClassicPos;

/// Only the owner / admin may switch layouts.
bool canSwitchPosLayout() {
  final a = AuthController.instance;
  return a.isOwner || a.isAdmin;
}

Future<void> setNewPosEnabled(bool on) =>
    Db.settings.put(kNewPosSetting, on ? 'true' : 'false');

/// Stock badge: colour + icon + words, never a number by default.
typedef PosBadge = ({
  String label,
  String short,
  IconData icon,
  Color fg,
  Color bg
});

PosBadge posStockBadge(Map<String, dynamic> item) {
  final stock = _i(item['stock']);
  final min = item['minStock'] == null ? 3 : _i(item['minStock']);
  if (stock <= 0) {
    return (
      label: 'Out of stock (ഇല്ല)',
      short: 'Out',
      icon: Icons.block_rounded,
      fg: PosTokens.error,
      bg: PosTokens.errorSoft
    );
  }
  if (stock <= min) {
    return (
      label: 'Low (കുറവ്)',
      short: 'Low',
      icon: Icons.warning_amber_rounded,
      fg: PosTokens.warning,
      bg: PosTokens.warningSoft
    );
  }
  return (
    label: 'Available (ഉണ്ട്)',
    short: 'In stock',
    icon: Icons.check_circle_rounded,
    fg: PosTokens.success,
    bg: PosTokens.successSoft
  );
}

/// Fields searched: name, barcode, code, SKU, IMEI, serial (those present).
const _kPosSearchFields = ['barcode', 'code', 'sku', 'imei', 'serial'];

bool posItemMatches(Map<String, dynamic> item, String q) {
  if (q.isEmpty) return false;
  if ('${item['name'] ?? ''}'.toLowerCase().contains(q)) return true;
  for (final f in _kPosSearchFields) {
    final v = '${item[f] ?? ''}'.toLowerCase();
    if (v.isNotEmpty && v.contains(q)) return true;
  }
  return false;
}

bool posItemExact(Map<String, dynamic> item, String q) {
  if (q.isEmpty) return false;
  for (final f in _kPosSearchFields) {
    if ('${item[f] ?? ''}'.trim().toLowerCase() == q) return true;
  }
  return false;
}

class _NewPosShell extends StatefulWidget {
  final _SaleViewState host;
  const _NewPosShell({required this.host});

  @override
  State<_NewPosShell> createState() => _NewPosShellState();
}

class _NewPosShellState extends State<_NewPosShell> {
  final _searchFocus = FocusNode(debugLabel: 'pos-search');
  final _custFocus = FocusNode(debugLabel: 'pos-customer');
  final _discFocus = FocusNode(debugLabel: 'pos-discount');

  // Customer View (Step 3f): the customer screen only ever gets this.
  final _display = ValueNotifier<CustomerDisplayState>(
      const CustomerDisplayState(phase: DisplayPhase.idle));
  CustomerDisplayState? _thanks; // shown for a few seconds after a sale
  Timer? _thanksTimer;
  Timer? _displayTimer;
  bool _inCustomerView = false;

  void _pushToSecondScreen() =>
      CustomerDisplayHost.instance.push(_display.value);

  /// Debounced (~100 ms) refresh of the customer screen after any change.
  void _scheduleDisplay() {
    _displayTimer?.cancel();
    _displayTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted) _display.value = _posDisplayStateFor(this);
    });
  }

  Future<void> _openCustomerView() async {
    if (_inCustomerView) return;
    final pin = '${Db.settings.get(kPosViewPinSetting) ?? ''}';
    if (pin.isEmpty) {
      if (!canSwitchPosLayout()) {
        toast(
            context,
            'Owner must set a Customer View PIN first (⋮ menu) '
            '(ഉടമ PIN സെറ്റ് ചെയ്യണം)',
            error: true);
        return;
      }
      if (!await _posSetPin(context) || !mounted) return;
    }
    _clearSearch(); // privacy: no search results behind the customer view
    _display.value = _posDisplayStateFor(this);
    _inCustomerView = true;
    PosKioskWindow.enter(); // full screen + on top (best effort, Windows)
    final theme = Theme.of(context);
    try {
      await Navigator.of(context).push(PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: PosTokens.fast,
        reverseTransitionDuration: PosTokens.fast,
        pageBuilder: (_, __, ___) =>
            Theme(data: theme, child: _PosCustomerViewPage(state: _display)),
      ));
    } finally {
      PosKioskWindow.exit();
      _inCustomerView = false;
    }
    if (mounted) _searchFocus.requestFocus(); // back to the same bill
  }

  Timer? _debounce;
  String _query = '';
  int _highlight = 0;
  bool _saving = false;

  // Payment (Step 3e). Only decides which existing amount (Cash or
  // UPI/Card) is filled in; the rest is credit, as before.
  PosPayMode _mode = PosPayMode.cash;
  final _tender = TextEditingController(); // cash handed over (not stored)
  final _payFocus = FocusNode(debugLabel: 'pos-pay');
  double? _upiOkTotal; // UPI/Card confirmed by the cashier for this total
  bool get _upiOk =>
      _upiOkTotal != null && (_upiOkTotal! - h._total).abs() < 0.005;

  void _setMode(PosPayMode m) {
    _mode = m;
    _upiOkTotal = null;
    if (m != PosPayMode.cash) _tender.clear();
  }

  bool _alt = false; // Alt held: owner/admin see cost on cards

  /// Purchase price: owner / admin only, and only while Alt is held.
  bool get _showCost {
    final a = AuthController.instance;
    return _alt && (a.isOwner || a.isAdmin);
  }

  bool _onKey(KeyEvent _) {
    final alt = HardwareKeyboard.instance.isAltPressed;
    if (alt != _alt && mounted) setState(() => _alt = alt);
    return false; // never swallow keys
  }

  _SaleViewState get h => widget.host;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    // Second monitor (Step 3g): same state as Customer View.
    _display.addListener(_pushToSecondScreen);
    CustomerDisplayHost.instance.start(customerDisplayModeFrom(
        Db.setting(kCustomerDisplaySetting, CustomerDisplayMode.auto.name)));
    _pushToSecondScreen();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _debounce?.cancel();
    _searchFocus.dispose();
    _custFocus.dispose();
    _discFocus.dispose();
    _payFocus.dispose();
    _tender.dispose();
    _displayTimer?.cancel();
    _thanksTimer?.cancel();
    _display.removeListener(_pushToSecondScreen);
    // Leaving the POS: the second screen goes back to the welcome screen.
    CustomerDisplayHost.instance.push(_posDisplayIdle());
    CustomerDisplayHost.instance.stop();
    _display.dispose();
    super.dispose();
  }

  /// Any change to the bill goes through the host (same state as old POS).
  void _upd(VoidCallback f) {
    // ignore: invalid_use_of_protected_member
    h.setState(f);
  }

  // ------------------------------------------------------------- search
  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() {
        _query = v.trim().toLowerCase();
        _highlight = 0;
      });
    });
  }

  List<MapEntry<dynamic, Map<String, dynamic>>> _results() {
    if (_query.isEmpty) return const [];
    final out = <MapEntry<dynamic, Map<String, dynamic>>>[];
    for (final e in entriesOf(Db.items)) {
      if (posItemMatches(e.value, _query)) out.add(e);
      if (out.length >= 40) break;
    }
    return out;
  }

  void _clearSearch() {
    _debounce?.cancel();
    h._search.clear();
    setState(() {
      _query = '';
      _highlight = 0;
    });
    _searchFocus.requestFocus();
  }

  void _add(dynamic key, Map<String, dynamic> item) {
    if (!_posBlockDuplicateImei(context, h, key, item)) {
      h._addToCart(key, item);
    }
    _clearSearch(); // privacy: results close as soon as an item is added
  }

  /// Remove a line at once; Undo for 5 s instead of a confirm dialog.
  void _removeLine(int i, void Function(VoidCallback) upd) {
    if (i >= h._cart.length) return;
    final removed = h._cart[i];
    upd(() => h._cart.removeAt(i));
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 5),
        content: Text('Removed (മാറ്റി): ${removed['name']}'),
        action: SnackBarAction(
          label: 'UNDO (തിരികെ)',
          onPressed: () {
            // Not if the same item is back on the bill or the bill is done.
            if (h._cart.any((l) => l['key'] == removed['key'])) return;
            upd(() => h._cart.insert(math.min(i, h._cart.length), removed));
          },
        ),
      ));
  }

  /// Enter: exact barcode / IMEI / SKU / serial first (scanner), else the
  /// highlighted result.
  void _onSubmit(String raw) {
    final q = raw.trim().toLowerCase();
    if (q.isEmpty) return;
    for (final e in entriesOf(Db.items)) {
      if (posItemExact(e.value, q)) {
        _add(e.key, e.value);
        return;
      }
    }
    _debounce?.cancel();
    _query = q;
    final r = _results();
    if (r.isEmpty) {
      toast(context, 'ഐറ്റം കണ്ടെത്തിയില്ല (No item found)', error: true);
      _searchFocus.requestFocus();
      return;
    }
    final e = r[_highlight.clamp(0, r.length - 1)];
    _add(e.key, e.value);
  }

  KeyEventResult _onSearchKey(FocusNode _, KeyEvent ev) {
    if (ev is! KeyDownEvent && ev is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final n = _results().length;
    if (ev.logicalKey == LogicalKeyboardKey.arrowDown && n > 0) {
      setState(() => _highlight = (_highlight + 1) % n);
      return KeyEventResult.handled;
    }
    if (ev.logicalKey == LogicalKeyboardKey.arrowUp && n > 0) {
      setState(() => _highlight = (_highlight - 1 + n) % n);
      return KeyEventResult.handled;
    }
    if (ev.logicalKey == LogicalKeyboardKey.escape && _query.isNotEmpty) {
      _clearSearch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ----------------------------------------------------------- checkout
  /// Validate the payment, fill the existing Cash / UPI-Card amounts, then
  /// save through the existing _checkout (once). On any failure the bill
  /// stays on screen and nothing is cleared.
  Future<void> _complete({BuildContext? sheetCtx}) async {
    if (_saving || h._busy || h._cart.isEmpty) return;
    final total = h._total;
    var change = 0.0;
    switch (_mode) {
      case PosPayMode.cash:
        final t = posTender(total, _tender.text);
        if (t.error != null) {
          toast(context, t.error!, error: true);
          _payFocus.requestFocus();
          return;
        }
        change = t.change;
      case PosPayMode.upi:
        if (!_upiOk) {
          final ok = await confirm(
              context,
              'Received ${rs(total)} by UPI / Card?\n'
              '(UPI / കാർഡ് വഴി പണം ലഭിച്ചോ?)',
              yes: 'Received (ലഭിച്ചു)');
          if (!ok || !mounted) return;
        }
      case PosPayMode.credit:
        if (h._partyKey == null && !h._crmCtrl.willHaveCustomer) {
          toast(context, 'Credit needs a customer (ക്രെഡിറ്റിന് കസ്റ്റമർ വേണം)',
              error: true);
          _custFocus.requestFocus();
          return;
        }
      case PosPayMode.split:
        break; // amounts as typed; the existing rules check them
    }
    if (_saving || h._busy) return; // a second tap while confirming
    // Last check of quantities, stock (all lines of an item) and IMEIs.
    final bad = posValidateCart(h._cart, (k) {
      final it = Db.items.get(k);
      return it == null ? null : _i(_m(it)['stock']);
    });
    if (bad != null) {
      toast(context, bad, error: true);
      return;
    }
    final p = posPaymentFor(_mode, total);
    if (p != null) {
      h._cashCtrl.text = p.cash > 0 ? _numText(p.cash) : '';
      h._upiCtrl.text = p.upi > 0 ? _numText(p.upi) : '';
    }
    setState(() => _saving = true); // disabled + loader at once
    Map<String, dynamic>? bill;
    try {
      bill = await h._checkout(); // the existing save, called once
    } catch (e) {
      if (mounted) {
        toast(
            context,
            'Bill not saved – nothing was cleared, please try again '
            '(ബിൽ സേവ് ആയില്ല): $e',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (bill == null || !mounted) {
      _searchFocus.requestFocus();
      return;
    }
    if (sheetCtx != null && sheetCtx.mounted) Navigator.pop(sheetCtx);
    // A finished bill must not take back a removed line.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _upd(() {
      _mode = PosPayMode.cash;
      _tender.clear();
      _upiOkTotal = null;
    });
    // Customer screen: thank-you for a few seconds, then the welcome screen.
    _thanks = _posThanksFor(bill);
    _thanksTimer?.cancel();
    _thanksTimer = Timer(const Duration(seconds: 8), () {
      _thanks = null;
      if (mounted) _scheduleDisplay();
    });
    _scheduleDisplay();
    await _posShowBillDone(context, bill, change);
    if (mounted) _searchFocus.requestFocus();
  }

  Future<void> _confirmClear(void Function(VoidCallback) upd) async {
    final ok = await confirm(context,
        'ബില്ലിലെ എല്ലാ ഐറ്റംസും മാറ്റണോ? (Clear all items from this bill?)',
        yes: 'Clear (മാറ്റുക)');
    if (ok) {
      upd(() => h._cart.clear());
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
  }

  // ------------------------------------------------------------- layout
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    _scheduleDisplay(); // any change on the counter -> customer screen
    return Theme(
      data: posTheme(Theme.of(context)),
      child: Builder(builder: (context) {
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.f2): () =>
                _searchFocus.requestFocus(),
            const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
                _searchFocus.requestFocus(),
            const SingleActivator(LogicalKeyboardKey.f3): () =>
                _custFocus.requestFocus(),
            const SingleActivator(LogicalKeyboardKey.f4): _openViewAll,
            const SingleActivator(LogicalKeyboardKey.f11): _openCustomerView,
            const SingleActivator(LogicalKeyboardKey.f1): () =>
                _posShowHelp(context),
            const SingleActivator(LogicalKeyboardKey.f6): () =>
                _posHoldBill(this),
            const SingleActivator(LogicalKeyboardKey.f7): () =>
                _posOpenHeld(this),
            const SingleActivator(LogicalKeyboardKey.f8): () =>
                _discFocus.requestFocus(),
            const SingleActivator(LogicalKeyboardKey.keyP, control: true): () =>
                _posReprintLast(context),
            const SingleActivator(LogicalKeyboardKey.keyR, control: true): () =>
                _posOpenRecent(context),
            const SingleActivator(LogicalKeyboardKey.f9): () =>
                _payFocus.requestFocus(),
            const SingleActivator(LogicalKeyboardKey.f12): _complete,
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                _complete,
          },
          child: Scaffold(
            appBar: _topBar(context, auth),
            body: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              if (w < PosTokens.medium) return _mainArea(context, phone: true);
              final panelW = w >= PosTokens.wide
                  ? PosTokens.cartPanelWide
                  : PosTokens.cartPanelNarrow;
              return Row(children: [
                Expanded(child: _mainArea(context)),
                SizedBox(
                  width: panelW,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: PosTokens.surface,
                      border: Border(left: BorderSide(color: PosTokens.border)),
                    ),
                    child: _billPanel(context, _upd),
                  ),
                ),
              ]);
            }),
            bottomNavigationBar: LayoutBuilder(builder: (context, c) {
              final phone = MediaQuery.sizeOf(context).width < PosTokens.medium;
              if (!phone || h._cart.isEmpty) return const SizedBox.shrink();
              return _phoneCartBar(context);
            }),
          ),
        );
      }),
    );
  }

  Widget _heldButton() {
    final n = _posHeldList().length;
    return IconButton(
      tooltip: 'Held bills (ഹോൾഡ് ബില്ലുകൾ)  F7',
      icon: Badge(
        isLabelVisible: n > 0,
        label: Text('$n'),
        child: const Icon(Icons.pause_circle_outline_rounded),
      ),
      onPressed: () => _posOpenHeld(this),
    );
  }

  void _openLedger(AuthController auth) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: const TekAppBar(
              title: Text('Daily Sales Ledger (ഇന്നത്തെ വിൽപ്പന)')),
          body: DailySalesLedgerView(
            shopId: auth.shopId,
            currentStaffId: auth.uid,
            currentStaffName: auth.name,
          ),
        ),
      ));

  void _openEod(AuthController auth) =>
      DailySalesLedgerView.showEodClosingModal(
        context,
        shopId: auth.shopId,
        currentStaffId: auth.uid,
        currentStaffName: auth.name,
      );

  PreferredSizeWidget _topBar(BuildContext context, AuthController auth) {
    return TekAppBar(
      title: const Text('Sale / POS (വിൽപ്പന)'),
      actions: [
        ValueListenableBuilder<bool>(
          valueListenable: CustomerDisplayHost.instance.showing,
          builder: (_, on, __) => ValueListenableBuilder<bool>(
            valueListenable: CustomerDisplayHost.instance.missing,
            builder: (_, missing, __) => on
                ? const Tooltip(
                    message:
                        'Customer display on 2nd screen (രണ്ടാം സ്ക്രീനിൽ കാണിക്കുന്നു)',
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.connected_tv_rounded,
                          color: PosTokens.success),
                    ),
                  )
                : missing
                    ? const Tooltip(
                        message:
                            'No second monitor found (രണ്ടാം സ്ക്രീൻ ഇല്ല) – use Customer View',
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Icon(Icons.tv_off_rounded,
                              color: PosTokens.warning),
                        ),
                      )
                    : const SizedBox.shrink(),
          ),
        ),
        if (MediaQuery.sizeOf(context).width >= PosTokens.wide)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: FilledButton.tonalIcon(
              onPressed: _openCustomerView,
              icon: const Icon(Icons.visibility_rounded, size: 18),
              label: const Text('Customer View (കസ്റ്റമർ വ്യൂ)  F11'),
            ),
          )
        else
          IconButton(
            tooltip: 'Customer View (കസ്റ്റമർ വ്യൂ)  F11',
            icon: const Icon(Icons.visibility_rounded),
            onPressed: _openCustomerView,
          ),
        _heldButton(),
        if (MediaQuery.sizeOf(context).width >= PosTokens.wide) ...[
          IconButton(
            tooltip: 'Recent bills (സമീപകാല ബില്ലുകൾ)  Ctrl+R',
            icon: const Icon(Icons.history_rounded),
            onPressed: () => _posOpenRecent(context),
          ),
          IconButton(
            tooltip: 'Daily Sales Ledger (ഇന്നത്തെ വിൽപ്പന)',
            icon: const Icon(Icons.receipt_long_rounded),
            onPressed: () => _openLedger(auth),
          ),
          IconButton(
            tooltip: 'End of Day / Register Close (ഡേ ക്ലോസിംഗ്)',
            icon: const Icon(Icons.nights_stay_rounded),
            onPressed: () => _openEod(auth),
          ),
          IconButton(
            tooltip: 'Keyboard shortcuts (സഹായം)  F1',
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: () => _posShowHelp(context),
          ),
        ] else
          PopupMenuButton<String>(
            tooltip: 'More (കൂടുതൽ)',
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (v) {
              switch (v) {
                case 'recent':
                  _posOpenRecent(context);
                case 'ledger':
                  _openLedger(auth);
                case 'eod':
                  _openEod(auth);
                case 'help':
                  _posShowHelp(context);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'recent',
                  child: Text('Recent bills (സമീപകാല ബില്ലുകൾ)')),
              PopupMenuItem(
                  value: 'ledger',
                  child: Text('Daily Sales Ledger (ഇന്നത്തെ വിൽപ്പന)')),
              PopupMenuItem(
                  value: 'eod',
                  child: Text('End of Day / Register Close (ഡേ ക്ലോസിംഗ്)')),
              PopupMenuItem(
                  value: 'help', child: Text('Keyboard shortcuts (സഹായം)')),
            ],
          ),
        if (canSwitchPosLayout())
          PopupMenuButton<String>(
            tooltip: 'POS options',
            onSelected: (v) async {
              if (v == 'upi') {
                await _posEditShopUpi(context);
              } else if (v == 'display') {
                await _posPickDisplayMode(context);
              } else if (v == 'pin') {
                await _posSetPin(context);
              } else if (v == 'welcome') {
                await _posEditWelcome(context);
                _scheduleDisplay();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'display',
                child: ListTile(
                  leading: Icon(Icons.connected_tv_rounded),
                  title: Text('Customer Display (കസ്റ്റമർ ഡിസ്പ്ലേ)'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'pin',
                child: ListTile(
                  leading: Icon(Icons.pin_rounded),
                  title: Text('Customer View PIN (PIN)'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'welcome',
                child: ListTile(
                  leading: Icon(Icons.waving_hand_rounded),
                  title: Text('Customer screen welcome (സ്വാഗതം)'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'upi',
                child: ListTile(
                  leading: Icon(Icons.qr_code_2_rounded),
                  title: Text('Shop UPI ID for QR (UPI ഐഡി)'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
      ],
    );
  }

  // -------------------------------------------------- left / main area
  Widget _mainArea(BuildContext context, {bool phone = false}) {
    final results = _results();
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 14, 16, phone ? 0 : 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Focus(
          onKeyEvent: _onSearchKey,
          skipTraversal: true,
          child: TextField(
            controller: h._search,
            focusNode: _searchFocus,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: _onSearchChanged,
            onSubmitted: _onSubmit,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText:
                  'Scan barcode or search name / IMEI / SKU (ബാർകോഡ് സ്കാൻ ചെയ്യുക)',
              prefixIcon: const Icon(Icons.qr_code_scanner_rounded),
              suffixIcon: h._search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear (Esc)',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: _clearSearch,
                    ),
            ),
          ),
        ),
        const SizedBox(height: PosTokens.gap),
        Expanded(
          child: _query.isEmpty
              ? _landing(context)
              : results.isEmpty
                  ? const _PosEmpty(
                      icon: Icons.search_off_rounded,
                      text: 'ഐറ്റം കണ്ടെത്തിയില്ല (No matching items)')
                  : _resultList(results),
        ),
      ]),
    );
  }

  /// Default view: category chips + Top Selling + Favorites (never the full
  /// inventory grid: customer privacy).
  Widget _landing(BuildContext context) => _PosCatalog(
        host: h,
        showCost: _showCost,
        onAdded: () => _searchFocus.requestFocus(),
        onViewAll: _openViewAll,
      );

  Future<void> _openViewAll() async {
    final theme = Theme.of(context);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Theme(
        data: theme,
        child: _PosViewAll(host: h, canSeeCost: () => _showCost),
      ),
    ));
    if (!mounted) return;
    _upd(() {});
    _searchFocus.requestFocus();
  }

  Widget _resultList(List<MapEntry<dynamic, Map<String, dynamic>>> r) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        itemCount: r.length,
        separatorBuilder: (_, __) => const Divider(),
        itemBuilder: (context, i) {
          final e = r[i];
          final badge = posStockBadge(e.value);
          final selected = i == _highlight;
          final imei = '${e.value['imei'] ?? ''}'.trim();
          return Material(
            color: selected ? PosTokens.primarySoft : PosTokens.surface,
            child: InkWell(
              onTap: () => _add(e.key, e.value),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Tooltip(
                            message: '${e.value['name']}',
                            child: Text('${e.value['name']}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: PosTokens.text)),
                          ),
                          if (imei.isNotEmpty &&
                              posIsUnitItem(e.value, _i(e.value['stock'])))
                            Text('IMEI tracked',
                                style:
                                    PosTokens.label.copyWith(fontSize: 11.5)),
                        ]),
                  ),
                  const SizedBox(width: 10),
                  _StockChip(badge: badge),
                  const SizedBox(width: 12),
                  Text(rs(_d(e.value['sellingPrice'])),
                      style: PosTokens.money.copyWith(fontSize: 16)),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------- right panel
  /// The bill: scrolling top (date, customer, lines, discount) and a fixed
  /// bottom (totals, payment, Complete) that never scrolls away.
  /// The bill, grouped: header (count, hold, clear) / customer / items /
  /// discount, then the fixed totals + payment box at the bottom.
  Widget _billPanel(BuildContext context, void Function(VoidCallback) upd,
      {BuildContext? sheetCtx}) {
    final hasItems = h._cart.isNotEmpty;
    return Column(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: PosTokens.border)),
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
                color: PosTokens.primarySoft, borderRadius: PosTokens.brSm),
            child: const Icon(Icons.receipt_long_rounded,
                size: 20, color: PosTokens.primary),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: PosBiText('Current bill', 'ബിൽ',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: PosTokens.text)),
          ),
          if (hasItems)
            Container(
              margin: const EdgeInsets.only(right: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: PosTokens.primarySoft,
                  borderRadius: BorderRadius.circular(20)),
              child: Text('${h._qtyCount} items',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: PosTokens.primaryDark)),
            ),
          if (hasItems)
            IconButton(
              tooltip: 'Hold bill (ഹോൾഡ്)  F6',
              icon: const Icon(Icons.pause_circle_outline_rounded),
              onPressed: () async {
                if (sheetCtx != null && sheetCtx.mounted) {
                  Navigator.pop(sheetCtx);
                }
                await _posHoldBill(this);
              },
            ),
          if (hasItems)
            IconButton(
              tooltip: 'Clear bill (മാറ്റുക)',
              icon: const Icon(Icons.delete_sweep_rounded,
                  color: PosTokens.error),
              onPressed: () => _confirmClear(upd),
            ),
        ]),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          children: [
            const PosSectionLabel(
                'Customer', 'കസ്റ്റമർ', Icons.person_outline_rounded),
            _PosCustomerSection(
              host: h,
              upd: upd,
              // The phone cart sheet gets its own focus node.
              focusNode: sheetCtx == null ? _custFocus : null,
            ),
            const SizedBox(height: 10),
            _dateRow(context, upd, sheetCtx),
            const SizedBox(height: 18),
            PosSectionLabel('Items', 'ഐറ്റംസ്', Icons.shopping_bag_outlined,
                trailing: hasItems
                    ? Text(rs(h._subtotal),
                        style: PosTokens.money.copyWith(fontSize: 13))
                    : null),
            if (!hasItems)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: PosTokens.surfaceAlt,
                  borderRadius: PosTokens.br,
                  border: Border.all(color: PosTokens.border),
                ),
                child: const Row(children: [
                  Icon(Icons.qr_code_scanner_rounded,
                      size: 28, color: PosTokens.primary),
                  SizedBox(width: 12),
                  Expanded(
                    child: PosBiText('Scan a barcode or search to add items',
                        'ബാർകോഡ് സ്കാൻ ചെയ്യുക',
                        maxLines: 2,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: PosTokens.muted)),
                  ),
                ]),
              )
            else
              for (var i = 0; i < h._cart.length; i++)
                _PosCartLine(
                  key: ValueKey(h._cart[i]['key']),
                  host: h,
                  index: i,
                  upd: upd,
                  onRemove: (i) => _removeLine(i, upd),
                ),
            if (hasItems) ...[
              const SizedBox(height: 6),
              TextField(
                controller: h._discount,
                focusNode: sheetCtx == null ? _discFocus : null,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => upd(() {}),
                decoration: InputDecoration(
                  labelText: 'Discount ₹ (കിഴിവ്)',
                  prefixIcon: const Icon(Icons.local_offer_outlined),
                  suffixText: posDiscountPercent(h._discountAmt, h._subtotal),
                ),
              ),
            ],
          ],
        ),
      ),
      _PosPaymentBox(shell: this, upd: upd, sheetCtx: sheetCtx),
    ]);
  }

  /// Today: one quiet line. Backdated: an amber strip that stands out.
  Widget _dateRow(BuildContext context, void Function(VoidCallback) upd,
      BuildContext? sheetCtx) {
    final today = _isToday(h._saleDate);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
      decoration: BoxDecoration(
        color: today ? Colors.transparent : PosTokens.warningSoft,
        borderRadius: PosTokens.brSm,
        border: today ? null : Border.all(color: PosTokens.warning),
      ),
      child: Row(children: [
        Icon(Icons.calendar_month_rounded,
            size: 16, color: today ? PosTokens.subtle : PosTokens.warning),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
              today
                  ? 'Today · ${dtFormat.format(h._saleDate)}'
                  : 'Backdated sale (മുൻകാലം) · ${dtFormat.format(h._saleDate)}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: today ? FontWeight.w500 : FontWeight.w800,
                  color: today ? PosTokens.muted : PosTokens.warning)),
        ),
        IconButton(
          tooltip: 'Change date (തീയതി മാറ്റുക)',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.edit_calendar_rounded, size: 18),
          onPressed: () => h._pickSaleDate(sheetCtx ?? context, upd),
        ),
        if (!today)
          IconButton(
            tooltip: 'Back to today (ഇന്നത്തേക്ക്)',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            onPressed: () => upd(() => h._saleDate = DateTime.now()),
          ),
      ]),
    );
  }

  // ------------------------------------------------------------- phone
  Widget _phoneCartBar(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: const BoxDecoration(
          color: PosTokens.surface,
          border: Border(top: BorderSide(color: PosTokens.border)),
        ),
        child: SizedBox(
          height: 50,
          child: FilledButton.icon(
            onPressed: () => _openPhoneCart(context),
            icon: const Icon(Icons.shopping_cart_checkout_rounded),
            label: Text('Cart (${h._qtyCount}) – ${rs(h._total)}  (കാർട്ട്)',
                style: const TextStyle(fontFeatures: PosTokens.tabular)),
          ),
        ),
      ),
    );
  }

  void _openPhoneCart(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: PosTokens.surface,
      builder: (ctx) => Theme(
        data: theme,
        child: StatefulBuilder(
          builder: (ctx, set) => Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.9,
              child: _billPanel(ctx, (f) {
                _upd(f);
                set(() {});
              }, sheetCtx: ctx),
            ),
          ),
        ),
      ),
    );
  }
}

class _StockChip extends StatelessWidget {
  final PosBadge badge;
  final bool compact;
  const _StockChip({required this.badge, this.compact = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: 4),
        decoration:
            BoxDecoration(color: badge.bg, borderRadius: PosTokens.brSm),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(badge.icon, size: 14, color: badge.fg),
          const SizedBox(width: 4),
          Text(compact ? badge.short : badge.label,
              semanticsLabel: badge.label,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: badge.fg)),
        ]),
      );
}

class _PosEmpty extends StatelessWidget {
  final IconData icon;
  final String text;
  const _PosEmpty({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: const BoxDecoration(
                  color: PosTokens.primarySoft, shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: PosTokens.primary),
            ),
            const SizedBox(height: 14),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: PosTokens.muted)),
          ]),
        ),
      );
}
