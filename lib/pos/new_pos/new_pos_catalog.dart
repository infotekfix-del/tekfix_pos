// New POS (Step 3b): category chips, Top Selling, Favorites, product cards
// and View All. Part of main.dart so it adds to the SAME cart through
// _SaleViewState._addToCart (stock rule unchanged). Reads items and sales
// only; Favorites are a local settings key (list of item `_id`s).
part of '../../main.dart';

IconData posCategoryIcon(PosCategory c) => switch (c) {
      PosCategory.mobiles => Icons.smartphone_rounded,
      PosCategory.accessories => Icons.phone_android_rounded,
      PosCategory.chargers => Icons.power_rounded,
      PosCategory.cables => Icons.cable_rounded,
      PosCategory.earphones => Icons.headphones_rounded,
      PosCategory.bluetooth => Icons.bluetooth_audio_rounded,
      PosCategory.gadgets => Icons.devices_other_rounded,
      PosCategory.service => Icons.build_circle_rounded,
      PosCategory.other => Icons.category_rounded,
    };

typedef _PosEntry = MapEntry<dynamic, Map<String, dynamic>>;

List<String> _posFavorites() =>
    posFavoritesFrom(Db.settings.get(kPosFavoritesSetting));

Future<void> _posToggleFavorite(String ref) => Db.settings
    .put(kPosFavoritesSetting, posToggleFavorite(_posFavorites(), ref));

int _posInBill(_SaleViewState h, dynamic key) {
  for (final c in h._cart) {
    if (c['key'] == key) return _i(c['qty']);
  }
  return 0;
}

// ---------------------------------------------------------------- landing
class _PosCatalog extends StatefulWidget {
  final _SaleViewState host;
  final bool showCost;
  final VoidCallback onAdded;
  final VoidCallback onViewAll;
  const _PosCatalog({
    required this.host,
    required this.showCost,
    required this.onAdded,
    required this.onViewAll,
  });

  @override
  State<_PosCatalog> createState() => _PosCatalogState();
}

class _PosCatalogState extends State<_PosCatalog> {
  PosCategory? _cat; // null = Top Selling + Favorites
  List<String> _top = const [];
  bool _topReady = false;
  Timer? _topTimer;
  dynamic _flashKey;
  Timer? _flashTimer;
  late final Listenable _sales = Db.sales.listenable();

  _SaleViewState get h => widget.host;

  @override
  void initState() {
    super.initState();
    _scheduleTop();
    _sales.addListener(_scheduleTop);
  }

  @override
  void dispose() {
    _sales.removeListener(_scheduleTop);
    _topTimer?.cancel();
    _flashTimer?.cancel();
    super.dispose();
  }

  /// Top Selling is computed after the first frame and again (debounced)
  /// when sales change; the UI never waits for it.
  void _scheduleTop() {
    _topTimer?.cancel();
    _topTimer = Timer(const Duration(milliseconds: 300), _computeTop);
  }

  Future<void> _computeTop() async {
    final from = DateTime.now().subtract(const Duration(days: 31));
    final recent = <Map>[];
    var n = 0;
    for (final v in Db.sales.values) {
      if (v is Map) {
        final d = DateTime.tryParse('${v['saleDate'] ?? v['createdAt'] ?? ''}');
        if (d == null || !d.isBefore(from)) recent.add(v);
      }
      if (++n % 400 == 0) await Future<void>.delayed(Duration.zero);
    }
    final top = posTopSelling(recent, limit: 16);
    if (mounted) {
      setState(() {
        _top = top;
        _topReady = true;
      });
    }
  }

  void _add(_PosEntry e) {
    if (_posBlockDuplicateImei(context, h, e.key, e.value)) return;
    h._addToCart(e.key, e.value);
    _flashTimer?.cancel();
    setState(() => _flashKey = e.key);
    _flashTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _flashKey = null);
    });
    widget.onAdded();
  }

  Future<void> _fav(String ref) async {
    await _posToggleFavorite(ref);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box>(
      valueListenable: Db.items.listenable(),
      builder: (context, _, __) {
        final entries = entriesOf(Db.items);
        final byRef = <String, _PosEntry>{};
        final counts = <PosCategory, int>{};
        for (final e in entries) {
          byRef[posItemRef(e.key, e.value)] = e;
          byRef['k:${e.key}'] = e;
          final c = posCategoryOf(e.value);
          counts[c] = (counts[c] ?? 0) + 1;
        }
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _chips(counts),
              const SizedBox(height: 10),
              Expanded(
                child: CustomScrollView(slivers: [
                  if (_cat == null)
                    ..._homeSlivers(byRef)
                  else
                    ..._categorySlivers(entries),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: OutlinedButton.icon(
                          onPressed: widget.onViewAll,
                          icon: const Icon(Icons.view_list_rounded),
                          label:
                              const Text('View All Items (എല്ലാ ഐറ്റംസ്)  F4'),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ]);
      },
    );
  }

  /// Wrapping rows (not a horizontal scroller): a mouse wheel cannot scroll
  /// sideways on Windows, so every chip must always be visible. Each chip
  /// stacks English over a smaller Malayalam line and shows a count badge.
  Widget _chips(Map<PosCategory, int> counts) {
    Widget chip(String en, String ml, IconData icon, int? count, bool sel,
            VoidCallback f) =>
        Material(
          color: sel ? Colors.transparent : PosTokens.surface,
          shape: RoundedRectangleBorder(
            borderRadius: PosTokens.br,
            side: BorderSide(color: sel ? PosTokens.primary : PosTokens.border),
          ),
          child: Ink(
            decoration: sel
                ? BoxDecoration(
                    gradient: PosTokens.gradient,
                    borderRadius: PosTokens.br,
                    boxShadow: PosTokens.glow)
                : null,
            child: InkWell(
              customBorder: RoundedRectangleBorder(borderRadius: PosTokens.br),
              onTap: f,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon,
                      size: 18, color: sel ? Colors.white : PosTokens.primary),
                  const SizedBox(width: 8),
                  PosBiText(en, ml,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: sel ? Colors.white : PosTokens.text)),
                  if (count != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: sel
                            ? Colors.white.withValues(alpha: 0.22)
                            : PosTokens.surfaceAlt,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('$count',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              fontFeatures: PosTokens.tabular,
                              color: sel ? Colors.white : PosTokens.muted)),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        );
    return Wrap(spacing: 8, runSpacing: 8, children: [
      chip('Top & Favorites', 'ടോപ്പ്', Icons.star_rounded, null, _cat == null,
          () => setState(() => _cat = null)),
      for (final c in PosCategory.values)
        if ((counts[c] ?? 0) > 0)
          chip(c.en, c.ml, posCategoryIcon(c), counts[c], _cat == c,
              () => setState(() => _cat = c)),
    ]);
  }

  Widget _header(String en, String ml, IconData icon, {String? hint}) =>
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 2, 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: PosTokens.primarySoft, borderRadius: PosTokens.brSm),
              child: Icon(icon, size: 18, color: PosTokens.primary),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: PosBiText(en, ml,
                  style: PosTokens.sectionTitle.copyWith(fontSize: 15)),
            ),
            if (hint != null) ...[
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(hint,
                    overflow: TextOverflow.ellipsis,
                    style: PosTokens.label.copyWith(fontSize: 12)),
              ),
            ],
          ]),
        ),
      );

  Widget _note(String text) => SliverToBoxAdapter(
        child: Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: PosTokens.surface,
            borderRadius: PosTokens.br,
            border: Border.all(color: PosTokens.border),
          ),
          child: Text(text, style: PosTokens.label),
        ),
      );

  Widget _grid(List<_PosEntry> list) {
    final favs = _posFavorites().toSet();
    return SliverGrid.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 230,
        mainAxisExtent: kPosCardHeight,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final e = list[i];
        final ref = posItemRef(e.key, e.value);
        return _PosProductCard(
          item: e.value,
          inBill: _posInBill(h, e.key),
          flash: _flashKey == e.key,
          favorite: favs.contains(ref),
          showCost: widget.showCost,
          onTap: () => _add(e),
          onFavorite: () => _fav(ref),
        );
      },
    );
  }

  List<Widget> _homeSlivers(Map<String, _PosEntry> byRef) {
    final top = [
      for (final r in _top)
        if (byRef[r] != null) byRef[r]!
    ];
    final favs = [
      for (final r in _posFavorites())
        if (byRef[r] != null) byRef[r]!
    ];
    return [
      _header('Top Selling', 'കൂടുതൽ വിറ്റത്', Icons.trending_up_rounded,
          hint: 'last 30 days'),
      if (!_topReady)
        const SliverToBoxAdapter(
            child: Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator())))
      else if (top.isEmpty)
        _note('No sales in the last 30 days (കഴിഞ്ഞ 30 ദിവസം വിൽപ്പനയില്ല)')
      else
        _grid(top),
      const SliverToBoxAdapter(child: SizedBox(height: 18)),
      _header('Favorites', 'പ്രിയപ്പെട്ടവ', Icons.star_rounded,
          hint: 'tap ☆ on any item'),
      if (favs.isEmpty)
        _note('No favorites yet: tap ☆ on an item to pin it here '
            '(☆ അമർത്തി ഇവിടെ ചേർക്കാം)')
      else
        _grid(favs),
    ];
  }

  List<Widget> _categorySlivers(List<_PosEntry> entries) {
    final c = _cat!;
    final list = entries.where((e) => posCategoryOf(e.value) == c).toList()
      ..sort((a, b) => '${a.value['name']}'
          .toLowerCase()
          .compareTo('${b.value['name']}'.toLowerCase()));
    return [
      _header(c.en, c.ml, posCategoryIcon(c), hint: '${list.length} items'),
      _grid(list),
    ];
  }
}

// ------------------------------------------------------------- the card
/// Every card has the same height; the name always takes two lines of
/// space, and price, stock and "+ Add" sit on the same bottom lines.
const double kPosCardHeight = 196;

class _PosProductCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final int inBill;
  final bool flash;
  final bool favorite;
  final bool showCost;
  final VoidCallback onTap;
  final VoidCallback onFavorite;
  const _PosProductCard({
    required this.item,
    required this.inBill,
    required this.flash,
    required this.favorite,
    required this.showCost,
    required this.onTap,
    required this.onFavorite,
  });

  @override
  Widget build(BuildContext context) {
    final name = '${item['name'] ?? ''}';
    final badge = posStockBadge(item);
    final cat = posCategoryOf(item);
    final imei = posIsUnitItem(item, _i(item['stock']));
    final brand = '${item['brand'] ?? ''}'.trim();
    final extra =
        [if (brand.isNotEmpty) brand, if (imei) 'IMEI tracked'].join(' · ');
    final out = _i(item['stock']) <= 0;
    return AnimatedContainer(
      duration: PosTokens.fast,
      decoration: BoxDecoration(
        color: flash ? PosTokens.primarySoft : PosTokens.surface,
        borderRadius: PosTokens.br,
        border: Border.all(
            color: flash || inBill > 0 ? PosTokens.primary : PosTokens.border,
            width: flash ? 2 : 1),
        boxShadow: PosTokens.shadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: PosTokens.br,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                          color: PosTokens.primarySoft,
                          borderRadius: PosTokens.brSm),
                      child: Icon(posCategoryIcon(cat),
                          size: 18, color: PosTokens.primary),
                    ),
                    const Spacer(),
                    if (inBill > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                            color: PosTokens.primary,
                            borderRadius: BorderRadius.circular(20)),
                        child: Text('In bill $inBill',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800)),
                      ),
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: IconButton(
                        tooltip: favorite
                            ? 'Remove favorite (മാറ്റുക)'
                            : 'Add to favorites (പ്രിയപ്പെട്ടത്)',
                        padding: EdgeInsets.zero,
                        iconSize: 20,
                        onPressed: onFavorite,
                        icon: Icon(
                            favorite
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            color: favorite
                                ? PosTokens.warning
                                : PosTokens.subtle),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  // Always two lines of space, so all cards line up.
                  SizedBox(
                    height: 38,
                    child: Tooltip(
                      message: name,
                      child: Text(name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14,
                              height: 1.3,
                              fontWeight: FontWeight.w700,
                              color: PosTokens.text)),
                    ),
                  ),
                  SizedBox(
                    height: 18,
                    child: Text(
                        showCost ? 'Cost ${rs(_d(item['costPrice']))}' : extra,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PosTokens.label.copyWith(
                            fontSize: 11.5,
                            color: showCost
                                ? PosTokens.warning
                                : PosTokens.subtle)),
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Row(children: [
                      Expanded(
                        child: FittedBox(
                          alignment: Alignment.centerLeft,
                          fit: BoxFit.scaleDown,
                          child: Text(rs(_d(item['sellingPrice'])),
                              style: PosTokens.money.copyWith(fontSize: 18)),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Tooltip(
                          message: badge.label,
                          child: _StockChip(badge: badge, compact: true)),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: SizedBox(
                      height: 34,
                      child: FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 34),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: out ? null : onTap,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: FittedBox(
                          child:
                              Text(out ? 'Out of stock' : 'Add  ·  ചേർക്കുക'),
                        ),
                      ),
                    ),
                  ),
                ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- View All
class _PosViewAll extends StatefulWidget {
  final _SaleViewState host;
  final bool Function() canSeeCost;
  const _PosViewAll({required this.host, required this.canSeeCost});

  @override
  State<_PosViewAll> createState() => _PosViewAllState();
}

class _PosViewAllState extends State<_PosViewAll> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _q = '';
  PosCategory? _cat;
  bool _inStock = false;
  PosSort _sort = PosSort.name;

  _SaleViewState get h => widget.host;

  bool _onKey(KeyEvent _) {
    if (mounted) setState(() {}); // Alt pressed / released: cost column
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  List<_PosEntry> _filtered() {
    final out = <_PosEntry>[];
    for (final e in entriesOf(Db.items)) {
      if (_inStock && _i(e.value['stock']) <= 0) continue;
      if (_cat != null && posCategoryOf(e.value) != _cat) continue;
      if (_q.isNotEmpty && !posItemMatches(e.value, _q)) continue;
      out.add(e);
    }
    int byName(_PosEntry a, _PosEntry b) => '${a.value['name']}'
        .toLowerCase()
        .compareTo('${b.value['name']}'.toLowerCase());
    switch (_sort) {
      case PosSort.name:
        out.sort(byName);
      case PosSort.priceLow:
        out.sort((a, b) =>
            _d(a.value['sellingPrice']).compareTo(_d(b.value['sellingPrice'])));
      case PosSort.priceHigh:
        out.sort((a, b) =>
            _d(b.value['sellingPrice']).compareTo(_d(a.value['sellingPrice'])));
      case PosSort.stock:
        out.sort(
            (a, b) => _i(b.value['stock']).compareTo(_i(a.value['stock'])));
    }
    return out;
  }

  void _add(_PosEntry e) {
    if (_posBlockDuplicateImei(context, h, e.key, e.value)) return;
    final before = h._qtyCount;
    h._addToCart(e.key, e.value); // same stock rule as the bill
    if (h._qtyCount > before && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: const Duration(milliseconds: 1200),
          content: Text('Added (ചേർത്തു): ${e.value['name']}'),
        ));
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final showCost = widget.canSeeCost();
    return Scaffold(
      backgroundColor: PosTokens.bg,
      appBar: AppBar(
        backgroundColor: PosTokens.surface,
        surfaceTintColor: Colors.transparent,
        title: const PosBiText('All Items', 'എല്ലാ ഐറ്റംസ്',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: PosTokens.text)),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
                color: PosTokens.primarySoft, borderRadius: PosTokens.br),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.receipt_rounded,
                  size: 18, color: PosTokens.primary),
              const SizedBox(width: 6),
              Text('Bill: ${h._qtyCount} items · ${rs(h._total)}',
                  style: PosTokens.money
                      .copyWith(fontSize: 14, color: PosTokens.primaryDark)),
            ]),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          // No huge gaps on wide screens: the table stays a readable width.
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(children: [
              _toolbar(),
              const SizedBox(height: 12),
              Expanded(
                child: ValueListenableBuilder<Box>(
                  valueListenable: Db.items.listenable(),
                  builder: (context, _, __) {
                    final list = _filtered();
                    return LayoutBuilder(builder: (context, c) {
                      final cols = _ViewAllCols.forWidth(c.maxWidth);
                      return Container(
                        decoration: BoxDecoration(
                          color: PosTokens.surface,
                          borderRadius: PosTokens.br,
                          border: Border.all(color: PosTokens.border),
                          boxShadow: PosTokens.shadow,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(children: [
                          _headRow(cols),
                          const Divider(height: 1),
                          Expanded(
                            child: list.isEmpty
                                ? const _PosEmpty(
                                    icon: Icons.search_off_rounded,
                                    text:
                                        'No matching items\n(ഐറ്റം കണ്ടെത്തിയില്ല)')
                                : ListView.separated(
                                    itemCount: list.length,
                                    separatorBuilder: (_, __) =>
                                        const Divider(height: 1),
                                    itemBuilder: (context, i) => _row(list[i],
                                        cols: cols, showCost: showCost),
                                  ),
                          ),
                          const Divider(height: 1),
                          Container(
                            width: double.infinity,
                            color: PosTokens.surfaceAlt,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            child: Text('${list.length} items',
                                style: PosTokens.label.copyWith(fontSize: 12)),
                          ),
                        ]),
                      );
                    });
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Search + filters in one aligned row (wraps on narrow windows).
  Widget _toolbar() {
    InputDecoration box(String label) => InputDecoration(
          labelText: label,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PosTokens.surface,
        borderRadius: PosTokens.br,
        border: Border.all(color: PosTokens.border),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 340,
            child: TextField(
              controller: _search,
              autofocus: true,
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 200), () {
                  if (mounted) {
                    setState(() => _q = v.trim().toLowerCase());
                  }
                });
              },
              decoration: const InputDecoration(
                hintText: 'Search name, barcode, IMEI, SKU (തിരയുക)',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
              ),
            ),
          ),
          SizedBox(
            width: 230,
            child: DropdownButtonFormField<PosCategory?>(
              initialValue: _cat,
              isExpanded: true,
              decoration: box('Category (വിഭാഗം)'),
              onChanged: (v) => setState(() => _cat = v),
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('All categories')),
                for (final c in PosCategory.values)
                  DropdownMenuItem(value: c, child: Text(c.en)),
              ],
            ),
          ),
          SizedBox(
            width: 200,
            child: DropdownButtonFormField<PosSort>(
              initialValue: _sort,
              isExpanded: true,
              decoration: box('Sort (ക്രമം)'),
              onChanged: (v) => setState(() => _sort = v ?? PosSort.name),
              items: const [
                DropdownMenuItem(value: PosSort.name, child: Text('Name A–Z')),
                DropdownMenuItem(
                    value: PosSort.priceLow, child: Text('Price: low → high')),
                DropdownMenuItem(
                    value: PosSort.priceHigh, child: Text('Price: high → low')),
                DropdownMenuItem(
                    value: PosSort.stock, child: Text('Stock: most first')),
              ],
            ),
          ),
          FilterChip(
            label: const Text('In stock only (സ്റ്റോക്ക് ഉള്ളത്)'),
            selected: _inStock,
            onSelected: (v) => setState(() => _inStock = v),
          ),
        ],
      ),
    );
  }

  Widget _headRow(_ViewAllCols cols) {
    const st = TextStyle(
        fontSize: 11.5,
        letterSpacing: 0.5,
        fontWeight: FontWeight.w800,
        color: PosTokens.muted);
    return Container(
      color: PosTokens.surfaceAlt,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        const Expanded(child: Text('ITEM', style: st)),
        if (cols.category)
          const SizedBox(
              width: _ViewAllCols.cat, child: Text('CATEGORY', style: st)),
        const SizedBox(
            width: _ViewAllCols.stock, child: Text('STOCK', style: st)),
        const SizedBox(
            width: _ViewAllCols.price,
            child: Text('PRICE', textAlign: TextAlign.right, style: st)),
        const SizedBox(width: _ViewAllCols.action),
      ]),
    );
  }

  Widget _row(_PosEntry e,
      {required _ViewAllCols cols, required bool showCost}) {
    final item = e.value;
    final cat = posCategoryOf(item);
    final badge = posStockBadge(item);
    final stock = _i(item['stock']);
    final inBill = _posInBill(h, e.key);
    final imei = posIsUnitItem(item, stock);
    final meta = [
      if (imei) 'IMEI tracked',
      if (showCost) 'Cost ${rs(_d(item['costPrice']))}',
    ].join(' · ');
    return InkWell(
      onTap: () => _add(e),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: '${item['name']}',
                    child: Text('${item['name']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: PosTokens.text)),
                  ),
                  if (meta.isNotEmpty)
                    Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PosTokens.label.copyWith(
                            fontSize: 12,
                            color: showCost
                                ? PosTokens.warning
                                : PosTokens.subtle)),
                ]),
          ),
          if (cols.category)
            SizedBox(
              width: _ViewAllCols.cat,
              child: Row(children: [
                Icon(posCategoryIcon(cat), size: 16, color: PosTokens.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(cat.en,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, color: PosTokens.muted)),
                ),
              ]),
            ),
          SizedBox(
            width: _ViewAllCols.stock,
            child: Row(children: [
              SizedBox(
                width: 40,
                child: Text('$stock',
                    style: PosTokens.money.copyWith(fontSize: 14)),
              ),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                      message: badge.label,
                      child: _StockChip(badge: badge, compact: true)),
                ),
              ),
            ]),
          ),
          SizedBox(
            width: _ViewAllCols.price,
            child: Text(rs(_d(item['sellingPrice'])),
                textAlign: TextAlign.right,
                style: PosTokens.money.copyWith(fontSize: 15)),
          ),
          SizedBox(
            width: _ViewAllCols.action,
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                onPressed: stock <= 0 ? null : () => _add(e),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(inBill > 0 ? 'Add · $inBill' : 'Add'),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Fixed column widths for the View All table.
class _ViewAllCols {
  static const double cat = 170;
  static const double stock = 150;
  static const double price = 100;
  static const double action = 120;
  final bool category;
  const _ViewAllCols(this.category);
  factory _ViewAllCols.forWidth(double w) => _ViewAllCols(w >= 760);
}
