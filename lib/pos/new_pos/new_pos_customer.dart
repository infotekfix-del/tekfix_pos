// New POS (Step 3c): customer section of the bill panel.
// Part of main.dart: it drives the SAME PosCustomerController the checkout
// uses (_SaleViewState._crmCtrl -> resolveForBill), so how a customer is
// attached to a bill, credit rules, dues and history are all unchanged.
// Customers are read from / created through the existing Customer CRM
// (parties box); nothing new is stored.
part of '../../main.dart';

class _PosCustomerSection extends StatefulWidget {
  final _SaleViewState host;
  final FocusNode? focusNode;
  final void Function(VoidCallback) upd;
  const _PosCustomerSection({
    required this.host,
    required this.upd,
    this.focusNode,
  });

  @override
  State<_PosCustomerSection> createState() => _PosCustomerSectionState();
}

class _PosCustomerSectionState extends State<_PosCustomerSection> {
  final _q = TextEditingController();
  FocusNode? _ownFocus;
  Timer? _debounce;
  String _query = '';
  List<CustomerSearchHit> _hits = const [];
  int _hl = 0;

  /// A customer without a phone number cannot be found by the phone-driven
  /// controller; it is linked to the bill directly (same fields).
  CrmCustomer? _noPhonePick;

  _SaleViewState get h => widget.host;
  PosCustomerController get ctrl => h._crmCtrl;
  CustomerCrm? get crm => CustomerCrm.maybeInstance;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void dispose() {
    _debounce?.cancel();
    _ownFocus?.dispose();
    _q.dispose();
    super.dispose();
  }

  CrmCustomer? get _current {
    if (ctrl.found != null) return ctrl.found;
    final p = _noPhonePick;
    if (p != null && h._partyId == p.id) return p;
    return null;
  }

  // ---------------------------------------------------------------- search
  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () => _search(v));
  }

  void _search(String v) {
    if (!mounted) return;
    final q = v.trim();
    final c = crm;
    if (q.isEmpty || c == null) {
      setState(() {
        _query = q;
        _hits = const [];
      });
      return;
    }
    // Phone-first: a full number that belongs to a customer selects at once.
    final ph = normalizePhone(q);
    if (ph != null) {
      final found = c.lookupByPhone(ph);
      if (found != null) {
        _select(found);
        return;
      }
    }
    setState(() {
      _query = q;
      _hits = c.searchCustomers(q, limit: 8);
      _hl = 0;
    });
  }

  void _select(CrmCustomer c) {
    _debounce?.cancel();
    if (c.phone.isNotEmpty) {
      _noPhonePick = null;
      ctrl.phone.text = c.phone;
      ctrl.name.text = c.name;
      ctrl.lookupNow(); // links party key / id through onLinked
    } else {
      _noPhonePick = c;
      ctrl.name.text = c.name;
      h._partyKey = c.key;
      h._partyId = c.id;
    }
    _q.clear();
    setState(() {
      _query = '';
      _hits = const [];
    });
    widget.upd(() {});
  }

  void _clear() {
    _noPhonePick = null;
    ctrl.phone.clear();
    ctrl.name.clear();
    ctrl.lookupNow();
    h._partyKey = null;
    h._partyId = null;
    widget.upd(() {});
    _focus.requestFocus();
  }

  void _submit(String v) {
    if (_hits.isNotEmpty) {
      _select(_hits[_hl.clamp(0, _hits.length - 1)].customer);
    } else if (v.trim().isNotEmpty) {
      _newCustomer(v.trim());
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final n = _hits.length;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown && n > 0) {
      setState(() => _hl = (_hl + 1) % n);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp && n > 0) {
      setState(() => _hl = (_hl - 1 + n) % n);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && _query.isNotEmpty) {
      _q.clear();
      _search('');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  List<CrmCustomer> _recent() {
    final c = crm;
    if (c == null) return const [];
    final keys = Db.sales.keys.toList();
    final sales = <Map>[];
    for (var i = keys.length - 1; i >= 0 && sales.length < 80; i--) {
      final v = Db.sales.get(keys[i]);
      if (v is Map) sales.add(v);
    }
    return [
      for (final id in posRecentCustomerIds(sales))
        if (c.byId(id) != null) c.byId(id)!
    ];
  }

  // ---------------------------------------------------------- new customer
  Future<void> _newCustomer(String typed) async {
    final c = crm;
    if (c == null) {
      toast(context, 'Customer CRM is not ready yet (CRM തയ്യാറായിട്ടില്ല)',
          error: true);
      return;
    }
    final r = await showDialog<({CrmCustomer? created, CrmCustomer? existing})>(
      context: context,
      builder: (_) => _PosNewCustomerDialog(crm: c, typed: typed),
    );
    if (!mounted || r == null) return;
    final dup = r.existing;
    if (dup != null) {
      final pick = await confirm(
        context,
        'Customer already exists – select? (കസ്റ്റമർ നിലവിലുണ്ട്)\n\n'
        '${dup.name} · ${posMaskPhone(dup.phone)}',
        yes: 'Select (തിരഞ്ഞെടുക്കുക)',
      );
      if (pick && mounted) _select(dup);
      return;
    }
    final made = r.created;
    if (made != null) _select(made);
  }

  // ------------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        if (_noPhonePick != null && h._partyId != _noPhonePick!.id) {
          _noPhonePick = null; // bill finished / cleared elsewhere
        }
        final c = _current;
        return c != null ? _card(context, c) : _searchBox(context);
      },
    );
  }

  Widget _searchBox(BuildContext context) {
    final recent = _query.isEmpty ? _recent() : const <CrmCustomer>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Focus(
        onKeyEvent: _onKey,
        skipTraversal: true,
        child: TextField(
          controller: _q,
          focusNode: _focus,
          onChanged: _onChanged,
          onSubmitted: _submit,
          decoration: InputDecoration(
            labelText: 'Phone or name  ·  F3',
            hintText: 'ഫോൺ / പേര് — empty = walk-in',
            prefixIcon: const Icon(Icons.person_search_rounded),
            suffixIcon: IconButton(
              tooltip: 'New customer (പുതിയ കസ്റ്റമർ)',
              icon: const Icon(Icons.person_add_alt_1_rounded),
              onPressed: () => _newCustomer(_q.text.trim()),
            ),
          ),
        ),
      ),
      if (_query.isNotEmpty) ...[
        const SizedBox(height: 6),
        _suggestions(context),
      ] else ...[
        const SizedBox(height: 6),
        Row(children: [
          const Icon(Icons.storefront_rounded,
              size: 16, color: PosTokens.subtle),
          const SizedBox(width: 6),
          Expanded(
            child: Text('Walk-in / Cash customer (വാക്ക്-ഇൻ)',
                style: PosTokens.label.copyWith(fontSize: 12)),
          ),
        ]),
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final r in recent)
              ActionChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                avatar: const Icon(Icons.history_rounded, size: 16),
                label: Text(r.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5)),
                tooltip: 'Recent customer (സ്ഥിരം കസ്റ്റമർ)',
                onPressed: () => _select(r),
              ),
          ]),
        ],
      ],
    ]);
  }

  Widget _suggestions(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: PosTokens.surface,
        borderRadius: PosTokens.br,
        border: Border.all(color: PosTokens.border),
        boxShadow: PosTokens.shadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < _hits.length; i++) _hitRow(_hits[i], i == _hl),
        Material(
          color: PosTokens.surfaceAlt,
          child: InkWell(
            onTap: () => _newCustomer(_query),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                const Icon(Icons.person_add_alt_1_rounded,
                    size: 18, color: PosTokens.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      _hits.isEmpty
                          ? 'No match – add new customer (പുതിയ കസ്റ്റമർ)'
                          : 'New customer (പുതിയ കസ്റ്റമർ)',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: PosTokens.primary)),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _hitRow(CustomerSearchHit hit, bool selected) {
    final c = hit.customer;
    return Material(
      color: selected ? PosTokens.primarySoft : PosTokens.surface,
      child: InkWell(
        onTap: () => _select(c),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: PosTokens.text)),
                    // Privacy: masked number in suggestions.
                    Text(
                        c.phone.isEmpty
                            ? 'No phone (ഫോൺ ഇല്ല)'
                            : posMaskPhone(c.phone),
                        style: PosTokens.label.copyWith(
                            fontSize: 12, fontFeatures: PosTokens.tabular)),
                  ]),
            ),
            if (c.balancePaise > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: PosTokens.errorSoft, borderRadius: PosTokens.brSm),
                child: Text('Due ${rs(c.balancePaise / 100)}',
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: PosTokens.error,
                        fontFeatures: PosTokens.tabular)),
              ),
          ]),
        ),
      ),
    );
  }

  // ----------------------------------------------------------- the card
  Widget _card(BuildContext context, CrmCustomer c) {
    final bills = crm?.salesOf(c.id) ?? const [];
    final due = c.balancePaise;
    final initial = c.name.trim().isEmpty ? '?' : c.name.trim()[0];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: PosTokens.surface,
        borderRadius: PosTokens.br,
        border: Border.all(color: PosTokens.primary.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: PosTokens.primarySoft,
            child: Text(initial.toUpperCase(),
                style: const TextStyle(
                    fontWeight: FontWeight.w800, color: PosTokens.primary)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: PosTokens.text)),
              Text(c.phone.isEmpty ? 'No phone (ഫോൺ ഇല്ല)' : c.phone,
                  style: PosTokens.label
                      .copyWith(fontFeatures: PosTokens.tabular)),
            ]),
          ),
          IconButton(
            tooltip: 'Change customer (കസ്റ്റമറെ മാറ്റുക)',
            icon: const Icon(Icons.close_rounded),
            onPressed: _clear,
          ),
        ]),
        const SizedBox(height: 8),
        _dueBlock(due),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.history_rounded, size: 18, color: PosTokens.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text('Purchase history (വാങ്ങിയവ) · ${bills.length}',
                style: PosTokens.sectionTitle.copyWith(fontSize: 13)),
          ),
          if (bills.isNotEmpty)
            TextButton(
              onPressed: () => _openHistory(context, c),
              child: const Text('All bills (എല്ലാം) →'),
            ),
        ]),
        if (bills.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 24, bottom: 2),
            child: Text('No bills yet (ബില്ലുകൾ ഇല്ല)',
                style: PosTokens.label.copyWith(fontSize: 12)),
          )
        else
          for (final b in bills.take(3))
            _PosBillRow(sale: b.value, compact: true),
      ]),
    );
  }

  Widget _dueBlock(int duePaise) {
    if (duePaise <= 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
            color: PosTokens.successSoft, borderRadius: PosTokens.brSm),
        child: const Row(children: [
          Icon(Icons.check_circle_rounded, color: PosTokens.success, size: 20),
          SizedBox(width: 8),
          Text('No due (ബാക്കിയില്ല)',
              style: TextStyle(
                  fontWeight: FontWeight.w800, color: PosTokens.success)),
        ]),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: PosTokens.errorSoft,
        borderRadius: PosTokens.brSm,
        border: Border.all(color: PosTokens.error.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        const Icon(Icons.warning_amber_rounded, color: PosTokens.error),
        const SizedBox(width: 8),
        const Expanded(
          child: Text('Old due (പഴയ ബാക്കി)',
              style: TextStyle(
                  fontWeight: FontWeight.w800, color: PosTokens.error)),
        ),
        Text(rs(duePaise / 100),
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: PosTokens.error,
                fontFeatures: PosTokens.tabular)),
      ]),
    );
  }

  /// Full purchase history in a side sheet (newest first, read-only).
  Future<void> _openHistory(BuildContext context, CrmCustomer c) {
    final theme = Theme.of(context);
    final bills = crm?.salesOf(c.id) ?? const [];
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
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.history_rounded,
                        color: PosTokens.primary),
                    title: Text('${c.name} · ${bills.length} bills',
                        style: PosTokens.sectionTitle),
                    subtitle: const Text(
                        'Purchase history (വാങ്ങിയവ) – newest first',
                        style: PosTokens.label),
                    trailing: IconButton(
                      tooltip: 'Close (അടയ്ക്കുക)',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: bills.length,
                      itemBuilder: (_, i) => _PosBillRow(sale: bills[i].value),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        openCustomerHistory(context, c.id);
                      },
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Open full history (മുഴുവൻ ഹിസ്റ്ററി)'),
                    ),
                  ),
                ]),
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
}

/// One past bill: date, invoice, items, amount, paid, due.
class _PosBillRow extends StatelessWidget {
  final Map<String, dynamic> sale;
  final bool compact;
  const _PosBillRow({required this.sale, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final s = invoicePaymentSummary(sale); // paise, due field authoritative
    final when =
        DateTime.tryParse('${sale['saleDate'] ?? sale['createdAt'] ?? ''}')
            ?.toLocal();
    final lines = (sale['items'] as List?) ?? const [];
    final items = [
      for (final l in lines)
        if (l is Map) '${l['name'] ?? 'Item'} × ${l['qty'] ?? 1}'
    ].join(', ');
    final date = when == null ? '-' : dayFormat.format(when);
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 3, 8, 3),
        child: Row(children: [
          Expanded(
            child: Text('$date · ${items.isEmpty ? '-' : items}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: PosTokens.text)),
          ),
          const SizedBox(width: 8),
          Text(rs(s.totalPaise / 100),
              style: PosTokens.money.copyWith(fontSize: 12.5)),
          if (s.balancePaise > 0) ...[
            const SizedBox(width: 6),
            Text('Due ${rs(s.balancePaise / 100)}',
                style: PosTokens.money
                    .copyWith(fontSize: 12, color: PosTokens.error)),
          ],
        ]),
      );
    }
    Widget amt(String k, int paise, {Color? color}) => Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k, style: PosTokens.label.copyWith(fontSize: 11.5)),
            Text(rs(paise / 100),
                style: PosTokens.money
                    .copyWith(fontSize: 14, color: color ?? PosTokens.text)),
          ]),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PosTokens.surface,
        borderRadius: PosTokens.br,
        border: Border.all(color: PosTokens.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('$date · ${sale['invoice'] ?? '-'}',
                style: const TextStyle(
                    fontWeight: FontWeight.w800, color: PosTokens.text)),
          ),
          Text(
              switch (s.status) {
                InvoicePaymentStatus.paid => 'PAID',
                InvoicePaymentStatus.partial => 'PARTIAL',
                InvoicePaymentStatus.pending => 'PENDING',
              },
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: s.status == InvoicePaymentStatus.paid
                      ? PosTokens.success
                      : PosTokens.error)),
        ]),
        const SizedBox(height: 4),
        Text(items.isEmpty ? '-' : items,
            style: const TextStyle(fontSize: 12.5, color: PosTokens.muted)),
        const SizedBox(height: 8),
        Row(children: [
          amt('Amount (തുക)', s.totalPaise),
          amt('Paid (അടച്ചത്)', s.paidPaise, color: PosTokens.success),
          amt('Due (ബാക്കി)', s.balancePaise,
              color: s.balancePaise > 0 ? PosTokens.error : PosTokens.muted),
        ]),
      ]),
    );
  }
}

/// New customer: name + mobile (+ WhatsApp OK). Labels sit above each
/// field (English, Malayalam smaller) so nothing overlaps. Saves through
/// the existing Customer CRM; a number that already exists is returned as
/// `existing` so the caller can offer to select that customer.
class _PosNewCustomerDialog extends StatefulWidget {
  final CustomerCrm crm;
  final String typed;
  const _PosNewCustomerDialog({required this.crm, required this.typed});

  @override
  State<_PosNewCustomerDialog> createState() => _PosNewCustomerDialogState();
}

class _PosNewCustomerDialogState extends State<_PosNewCustomerDialog> {
  late final bool _typedPhone =
      RegExp(r'^[0-9+\-\s()]+$').hasMatch(widget.typed);
  late final _phone =
      TextEditingController(text: _typedPhone ? widget.typed : '');
  late final _name =
      TextEditingController(text: _typedPhone ? '' : widget.typed);
  bool _optIn = true;
  bool _saving = false;
  String? _phoneErr;
  String? _nameErr;

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final ph = normalizePhone(_phone.text);
    setState(() {
      _phoneErr = ph == null
          ? (phoneError(_phone.text) ??
              'Enter a valid 10-digit mobile number (10 അക്ക നമ്പർ)')
          : null;
      _nameErr = _name.text.trim().isEmpty
          ? 'Enter the customer name (പേര് നൽകുക)'
          : null;
    });
    if (ph == null || _nameErr != null) return;
    final dup = widget.crm.duplicateOf(ph);
    if (dup != null) {
      Navigator.pop(context, (created: null, existing: dup));
      return;
    }
    setState(() => _saving = true);
    try {
      final c = await widget.crm.createCustomer(
          name: _name.text.trim(), phone: ph, whatsappOptIn: _optIn);
      if (mounted) Navigator.pop(context, (created: c, existing: null));
    } on DuplicatePhoneException catch (e) {
      if (mounted) {
        Navigator.pop(context, (created: null, existing: e.existing));
      }
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _phoneErr = e.message;
        });
      }
    }
  }

  Widget _field(String en, String ml, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(en,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: PosTokens.text)),
            const SizedBox(width: 6),
            Text(ml,
                style:
                    const TextStyle(fontSize: 11.5, color: PosTokens.subtle)),
          ]),
          const SizedBox(height: 6),
          child,
        ],
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 6),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 6),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      title: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(
              color: PosTokens.primarySoft, shape: BoxShape.circle),
          child: const Icon(Icons.person_add_alt_1_rounded,
              color: PosTokens.primary),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: PosBiText('New customer', 'പുതിയ കസ്റ്റമർ',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: PosTokens.text)),
        ),
      ]),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _field(
            'Mobile number *',
            'മൊബൈൽ നമ്പർ',
            TextField(
              key: const ValueKey('pos-new-customer-phone'),
              controller: _phone,
              autofocus: _typedPhone ? false : _phone.text.isEmpty,
              keyboardType: TextInputType.phone,
              inputFormatters: [LengthLimitingTextInputFormatter(16)],
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                hintText: '98470 12345',
                prefixIcon: const Icon(Icons.phone_rounded),
                errorText: _phoneErr,
                errorMaxLines: 2,
              ),
            ),
          ),
          const SizedBox(height: 14),
          _field(
            'Customer name *',
            'പേര്',
            TextField(
              key: const ValueKey('pos-new-customer-name'),
              controller: _name,
              autofocus: _typedPhone,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                hintText: 'Full name',
                prefixIcon: const Icon(Icons.badge_outlined),
                errorText: _nameErr,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            const Expanded(
              child: PosBiText(
                  'WhatsApp messages OK', 'വാട്സ്ആപ്പ് സന്ദേശം ശരി',
                  style: TextStyle(fontSize: 13, color: PosTokens.text)),
            ),
            Switch(
              value: _optIn,
              onChanged: (v) => setState(() => _optIn = v),
            ),
          ]),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.check_rounded),
          label: const Text('Save customer'),
        ),
      ],
    );
  }
}
