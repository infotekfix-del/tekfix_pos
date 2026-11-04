// =============================================================================
// TEKFIX ERP — SMART INVENTORY SEARCH COMBOBOX
// Version 2.0 Pro: High-Performance Autocomplete, Keyboard Nav & Barcode Scanner
// =============================================================================

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
import 'smart_inventory_models.dart';
import 'smart_inventory_search_engine.dart';

class SmartInventoryCombobox extends StatefulWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String placeholder;
  final ValueChanged<InventorySearchItem> onProductSelected;
  final ValueChanged<String> onAddNewItem;
  final VoidCallback? onBarcodeScannerPressed;
  final bool isGstEnabled;
  final double dropdownMaxHeight;

  const SmartInventoryCombobox({
    super.key,
    this.controller,
    this.focusNode,
    this.placeholder = 'Search product name, SKU or scan barcode...',
    required this.onProductSelected,
    required this.onAddNewItem,
    this.onBarcodeScannerPressed,
    this.isGstEnabled = false,
    this.dropdownMaxHeight = 320.0,
  });

  @override
  State<SmartInventoryCombobox> createState() => _SmartInventoryComboboxState();
}

class _SmartInventoryComboboxState extends State<SmartInventoryCombobox> {
  late TextEditingController _searchCtrl;
  late FocusNode _focusNode;
  bool _ownsController = false;
  bool _ownsFocusNode = false;

  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  Timer? _debounceTimer;
  DateTime? _lastKeystrokeTime;
  int _rapidKeystrokeCount = 0;

  List<InventorySearchItem> _searchResults = [];
  bool _isSearching = false;
  int _highlightedIndex = -1;

  final SmartInventorySearchEngine _engine = SmartInventorySearchEngine.instance;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _searchCtrl = widget.controller!;
    } else {
      _searchCtrl = TextEditingController();
      _ownsController = true;
    }

    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }

    _searchCtrl.addListener(_onSearchChanged);
    _focusNode.addListener(_onFocusChanged);

    // Initialize search engine
    _engine.initialize();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _removeOverlay();

    _searchCtrl.removeListener(_onSearchChanged);
    _focusNode.removeListener(_onFocusChanged);

    if (_ownsController) _searchCtrl.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) {
      _performSearch(_searchCtrl.text, immediate: true);
      _showOverlayOrBottomSheet();
    } else {
      // Delay dismissing overlay briefly to allow clicks on dropdown items
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted && !_focusNode.hasFocus) {
          _removeOverlay();
        }
      });
    }
  }

  void _onSearchChanged() {
    final query = _searchCtrl.text;
    final now = DateTime.now();

    // Barcode scanner detection: fast consecutive keystrokes (< 50ms apart)
    if (_lastKeystrokeTime != null &&
        now.difference(_lastKeystrokeTime!).inMilliseconds < 55) {
      _rapidKeystrokeCount++;
    } else {
      _rapidKeystrokeCount = 1;
    }
    _lastKeystrokeTime = now;

    // If scanner typed 8+ characters in rapid bursts, attempt immediate barcode match
    if (_rapidKeystrokeCount >= 8) {
      final exact = _engine.findExactBarcodeOrSku(query.trim());
      if (exact != null) {
        _handleSubmitted(query.trim());
        return;
      }
    }

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        _performSearch(query);
      }
    });
  }

  void _performSearch(String query, {bool immediate = false}) {
    setState(() => _isSearching = true);

    final results = _engine.search(query);
    if (!mounted) return;

    setState(() {
      _searchResults = results;
      _isSearching = false;
      _highlightedIndex = -1;
    });

    _updateOverlay();
  }

  /// Handles hardware keyboard wedge barcode scanner input or Enter key submission.
  void _handleSubmitted(String rawValue) {
    final clean = rawValue.trim();
    if (clean.isEmpty) return;

    // Check exact barcode or SKU match
    final exactMatch = _engine.findExactBarcodeOrSku(clean);
    if (exactMatch != null) {
      HapticFeedback.mediumImpact();
      TekFeedback.success('Scanned: "${exactMatch.name}"');
      _selectProduct(exactMatch);
      return;
    }

    // If an item in dropdown is highlighted via keyboard navigation
    if (_highlightedIndex >= 0 && _highlightedIndex < _searchResults.length) {
      _selectProduct(_searchResults[_highlightedIndex]);
      return;
    }

    // If exactly one match in current search
    if (_searchResults.length == 1) {
      _selectProduct(_searchResults.first);
      return;
    }

    // Otherwise, ensure overlay is showing with results and Add New Item option
    _showOverlayOrBottomSheet();
  }

  void _selectProduct(InventorySearchItem item) {
    HapticFeedback.selectionClick();
    _removeOverlay();
    _searchCtrl.clear();
    _focusNode.unfocus();
    widget.onProductSelected(item);
  }

  void _triggerAddNewItem() {
    final query = _searchCtrl.text.trim();
    HapticFeedback.lightImpact();
    _removeOverlay();
    _searchCtrl.clear();
    _focusNode.unfocus();
    widget.onAddNewItem(query);
  }

  // ---------------------------------------------------------------------------
  // OVERLAY / BOTTOM SHEET LOGIC
  // ---------------------------------------------------------------------------

  void _showOverlayOrBottomSheet() {
    final screenWidth = MediaQuery.of(context).size.width;
    if (screenWidth < 600) {
      // Mobile: Open Bottom Sheet
      _removeOverlay();
      _openMobileBottomSheet();
    } else {
      // Desktop / Tablet: Anchored Dropdown Overlay
      _showDesktopOverlay();
    }
  }

  void _showDesktopOverlay() {
    if (_overlayEntry != null) {
      _overlayEntry!.markNeedsBuild();
      return;
    }

    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: _getDropdownWidth(),
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 48),
          child: Material(
            elevation: 12,
            shadowColor: Colors.black.withValues(alpha: 0.6),
            color: Colors.transparent,
            child: _buildDropdownContainer(),
          ),
        ),
      ),
    );

    overlay.insert(_overlayEntry!);
  }

  void _updateOverlay() {
    if (_overlayEntry != null && mounted) {
      _overlayEntry!.markNeedsBuild();
    }
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  double _getDropdownWidth() {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      return renderBox.size.width;
    }
    return 420.0;
  }

  // ---------------------------------------------------------------------------
  // MOBILE BOTTOM SHEET
  // ---------------------------------------------------------------------------

  void _openMobileBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0C1236),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: DashboardColors.glassBorderHover),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSheetState) {
          final query = _searchCtrl.text;
          final tokens = InventorySearchItem.normalize(query).split(' ').where((t) => t.isNotEmpty).toList();

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
              top: 16,
              left: 16,
              right: 16,
            ),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.75,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Select or Add Product',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white70),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Mobile Search Input
                  TextField(
                    controller: _searchCtrl,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: widget.placeholder,
                      hintStyle: const TextStyle(color: DashboardColors.textMuted, fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded, color: DashboardColors.neonBlue, size: 20),
                      suffixIcon: _searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, color: Colors.white70, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setSheetState(() {});
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: DashboardColors.neonBlue),
                      ),
                    ),
                    onChanged: (val) {
                      _performSearch(val);
                      setSheetState(() {});
                    },
                    onSubmitted: (val) {
                      Navigator.pop(ctx);
                      _handleSubmitted(val);
                    },
                  ),
                  const SizedBox(height: 12),

                  // Offline warning banner if applicable
                  if (_engine.isOffline) _buildOfflineBadge(),

                  // Results list
                  Expanded(
                    child: _searchResults.isEmpty
                        ? _buildEmptyState(query, inSheet: true)
                        : ListView.separated(
                            itemCount: _searchResults.length,
                            separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 1),
                            itemBuilder: (c, idx) {
                              final item = _searchResults[idx];
                              return _buildProductResultTile(item, tokens, () {
                                Navigator.pop(ctx);
                                _selectProduct(item);
                              });
                            },
                          ),
                  ),

                  // Pinned Add New Item Footer
                  _buildPinnedAddButton(query, () {
                    Navigator.pop(ctx);
                    _triggerAddNewItem();
                  }),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DESKTOP DROPDOWN CONTAINER
  // ---------------------------------------------------------------------------

  Widget _buildDropdownContainer() {
    final query = _searchCtrl.text;
    final tokens = InventorySearchItem.normalize(query).split(' ').where((t) => t.isNotEmpty).toList();

    return Container(
      constraints: BoxConstraints(maxHeight: widget.dropdownMaxHeight),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1236),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DashboardColors.neonBlue.withValues(alpha: 0.4), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.7),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: DashboardColors.neonBlue.withValues(alpha: 0.15),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Optional offline notice
            if (_engine.isOffline) _buildOfflineBadge(),

            // Results scroll area
            Flexible(
              child: _isSearching
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24.0),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: DashboardColors.neonBlue,
                          ),
                        ),
                      ),
                    )
                  : _searchResults.isEmpty
                      ? _buildEmptyState(query)
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          shrinkWrap: true,
                          itemCount: _searchResults.length,
                          separatorBuilder: (_, __) => Divider(
                            color: Colors.white.withValues(alpha: 0.06),
                            height: 1,
                          ),
                          itemBuilder: (c, idx) {
                            final item = _searchResults[idx];
                            final isHighlighted = idx == _highlightedIndex;
                            return _buildProductResultTile(
                              item,
                              tokens,
                              () => _selectProduct(item),
                              isHighlighted: isHighlighted,
                            );
                          },
                        ),
            ),

            // Pinned Always-Visible Add New Item Footer
            _buildPinnedAddButton(query, _triggerAddNewItem),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // PRODUCT RESULT TILE
  // ---------------------------------------------------------------------------

  Widget _buildProductResultTile(
    InventorySearchItem item,
    List<String> queryTokens,
    VoidCallback onTap, {
    bool isHighlighted = false,
  }) {
    final isOut = item.isOutOfStock;

    return InkWell(
      onTap: onTap,
      hoverColor: DashboardColors.neonBlue.withValues(alpha: 0.1),
      splashColor: DashboardColors.neonBlue.withValues(alpha: 0.2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: isHighlighted ? DashboardColors.neonBlue.withValues(alpha: 0.12) : Colors.transparent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Left icon indicator
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: isOut
                    ? DashboardColors.neonOrange.withValues(alpha: 0.12)
                    : DashboardColors.neonGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isOut
                      ? DashboardColors.neonOrange.withValues(alpha: 0.3)
                      : DashboardColors.neonGreen.withValues(alpha: 0.3),
                ),
              ),
              child: Icon(
                item.trackImei ? Icons.smartphone_rounded : Icons.inventory_2_rounded,
                color: isOut ? DashboardColors.neonOrange : DashboardColors.neonGreen,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),

            // Details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Product Name with highlight
                  InventorySearchItem.buildHighlightedText(
                    text: item.name,
                    queryTokens: queryTokens,
                    baseStyle: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                    highlightStyle: const TextStyle(
                      color: DashboardColors.neonBlue,
                      fontWeight: FontWeight.w800,
                      backgroundColor: Color(0x3300D9F6),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 3),

                  // Brand / Model / SKU subtitle
                  Text(
                    [
                      if (item.brand.isNotEmpty) 'Brand: ${item.brand}',
                      if (item.model.isNotEmpty) 'Model: ${item.model}',
                      if (item.sku.isNotEmpty) 'SKU: ${item.sku}'
                      else if (item.barcode.isNotEmpty) 'Barcode: ${item.barcode}',
                    ].join(' • '),
                    style: const TextStyle(color: DashboardColors.textMuted, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),

                  // Rates & Stock Badge Row
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      // Stock pill
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isOut
                              ? DashboardColors.neonOrange.withValues(alpha: 0.15)
                              : DashboardColors.neonGreen.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: isOut
                                ? DashboardColors.neonOrange.withValues(alpha: 0.4)
                                : DashboardColors.neonGreen.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Text(
                          isOut ? 'Stock: 0 PCS' : 'Stock: ${item.stock} PCS',
                          style: TextStyle(
                            color: isOut ? DashboardColors.neonOrange : DashboardColors.neonGreen,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),

                      // Last purchase rate
                      if (item.lastPurchaseRate > 0)
                        Text(
                          'Last: ₹${item.lastPurchaseRate.toStringAsFixed(2)}',
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),

                      // GST
                      if (item.gst > 0)
                        Text(
                          'GST: ${item.gst.toStringAsFixed(0)}%',
                          style: const TextStyle(color: DashboardColors.neonPurple, fontSize: 11),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // Select button
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: DashboardColors.neonBlue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: DashboardColors.neonBlue.withValues(alpha: 0.35)),
              ),
              child: const Text(
                'SELECT',
                style: TextStyle(
                  color: DashboardColors.neonBlue,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // EMPTY STATE & PINNED ADD ACTION
  // ---------------------------------------------------------------------------

  Widget _buildEmptyState(String query, {bool inSheet = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inventory_2_outlined, color: Colors.white.withValues(alpha: 0.3), size: 36),
          const SizedBox(height: 8),
          const Text(
            'No matching items found in inventory.',
            style: TextStyle(color: DashboardColors.textMuted, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          if (query.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Click below to register "$query" as a new product.',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPinnedAddButton(String query, VoidCallback onAdd) {
    final label = query.trim().isNotEmpty ? 'Add as New Item "$query"' : 'Add as New Item';

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101844),
        border: Border(
          top: BorderSide(color: DashboardColors.neonBlue.withValues(alpha: 0.25)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: InkWell(
        onTap: onAdd,
        borderRadius: BorderRadius.circular(8),
        hoverColor: DashboardColors.neonGreen.withValues(alpha: 0.1),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: DashboardColors.neonGreen.withValues(alpha: 0.12),
            border: Border.all(color: DashboardColors.neonGreen.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add_circle_outline_rounded, color: DashboardColors.neonGreen, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '+ $label',
                  style: const TextStyle(
                    color: DashboardColors.neonGreen,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOfflineBadge() {
    return Container(
      color: Colors.amber.shade900.withValues(alpha: 0.25),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: const Row(
        children: [
          Icon(Icons.cloud_off_rounded, color: Colors.amber, size: 14),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Showing saved inventory data. Sync pending.',
              style: TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // MAIN SEARCH INPUT BUILDER
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: RawKeyboardListener(
        focusNode: FocusNode(),
        onKey: (event) {
          if (event is RawKeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              if (_searchResults.isNotEmpty) {
                setState(() {
                  _highlightedIndex = (_highlightedIndex + 1).clamp(0, _searchResults.length - 1);
                });
                _updateOverlay();
              }
            } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              if (_searchResults.isNotEmpty) {
                setState(() {
                  _highlightedIndex = (_highlightedIndex - 1).clamp(0, _searchResults.length - 1);
                });
                _updateOverlay();
              }
            } else if (event.logicalKey == LogicalKeyboardKey.enter) {
              if (_highlightedIndex >= 0 && _highlightedIndex < _searchResults.length) {
                _selectProduct(_searchResults[_highlightedIndex]);
              } else {
                _handleSubmitted(_searchCtrl.text);
              }
            } else if (event.logicalKey == LogicalKeyboardKey.escape) {
              _removeOverlay();
              _focusNode.unfocus();
            }
          }
        },
        child: TextField(
          controller: _searchCtrl,
          focusNode: _focusNode,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: widget.placeholder,
            hintStyle: const TextStyle(color: DashboardColors.textMuted, fontSize: 12),
            prefixIcon: const Icon(Icons.search_rounded, color: DashboardColors.neonBlue, size: 18),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isSearching)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6.0),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5, color: DashboardColors.neonBlue),
                    ),
                  ),
                if (_searchCtrl.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 16),
                    tooltip: 'Clear',
                    onPressed: () {
                      _searchCtrl.clear();
                      _performSearch('');
                    },
                  ),
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner_rounded, color: DashboardColors.neonBlue, size: 18),
                  tooltip: 'Scan Barcode',
                  onPressed: widget.onBarcodeScannerPressed ?? () => _focusNode.requestFocus(),
                ),
              ],
            ),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.04),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: DashboardColors.neonBlue),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: DashboardColors.glassBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: DashboardColors.neonBlue, width: 1.5),
            ),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: _handleSubmitted,
        ),
      ),
    );
  }
}

