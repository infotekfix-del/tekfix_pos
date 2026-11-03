import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart' show Db;
import '../purchases/purchase_models.dart';
import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
import '../utils/tek_helpers.dart';
import 'barcode_label_service.dart';

/// Modal dialog to configure, preview, and print barcode labels on TVS LP 46 Lite / LP 44 Lite.
/// Standardized for 50 mm × 25 mm stickers with 3 mm die-cut gap at 203 DPI (TSPL RAW).
class BarcodePrintDialog extends StatefulWidget {
  final List<BarcodeLabelItem> initialItems;
  final String title;

  const BarcodePrintDialog({
    super.key,
    required this.initialItems,
    this.title = 'Print Barcode Labels (TVS LP 46 Lite)',
  });

  /// Factory helper to build dialog items directly from a PurchaseBill.
  static Future<void> showForPurchaseBill(
    BuildContext context,
    PurchaseBill bill,
  ) async {
    final service = BarcodeLabelService.instance;
    final labelItems = <BarcodeLabelItem>[];

    for (final it in bill.items) {
      // 1. Look up item in Db.items to find existing barcode, selling price and MRP
      double? sellingPrice;
      double? mrp;
      String barcode = it.sku.trim();

      if (it.itemKey != null && Db.items.containsKey(it.itemKey)) {
        final rec = tekM(Db.items.get(it.itemKey));
        barcode = '${rec['barcode'] ?? rec['code'] ?? rec['sku'] ?? barcode}'.trim();
        sellingPrice = (rec['sellingPrice'] as num?)?.toDouble() ??
            (rec['price'] as num?)?.toDouble();
        mrp = (rec['mrp'] as num?)?.toDouble();
      }

      // Fallback from bill line item if available
      sellingPrice ??= (it.sellingPrice > 0 ? it.sellingPrice : null);

      // If still empty, ensure permanent barcode in Db.items
      if (barcode.isEmpty) {
        barcode = await service.ensureItemHasBarcode(
          it.itemKey,
          defaultBarcode: it.sku.isNotEmpty ? it.sku : null,
          sellingPrice: sellingPrice,
          mrp: mrp,
        );
      }

      labelItems.add(
        BarcodeLabelItem(
          itemKey: it.itemKey,
          itemId: it.itemId,
          name: it.name,
          model: it.model,
          brand: it.brand,
          barcode: barcode,
          sellingPrice: sellingPrice,
          mrp: mrp,
          quantity: it.quantity > 0 ? it.quantity : 1,
        ),
      );
    }

    if (context.mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => BarcodePrintDialog(
          initialItems: labelItems,
          title: 'Print Barcode Labels — Bill #${bill.billNumber}',
        ),
      );
    }
  }

  /// Factory helper for a single product from inventory.
  static Future<void> showForSingleProduct(
    BuildContext context, {
    required dynamic itemKey,
    required String name,
    String model = '',
    String brand = '',
    String? existingBarcode,
    double? sellingPrice,
    double? mrp,
    int initialQuantity = 1,
  }) async {
    final service = BarcodeLabelService.instance;

    // Look up from DB if not supplied
    double? effectiveSellingPrice = sellingPrice;
    double? effectiveMrp = mrp;
    if (itemKey != null && Db.items.containsKey(itemKey)) {
      final rec = tekM(Db.items.get(itemKey));
      effectiveSellingPrice ??= (rec['sellingPrice'] as num?)?.toDouble() ??
          (rec['price'] as num?)?.toDouble();
      effectiveMrp ??= (rec['mrp'] as num?)?.toDouble();
    }

    String barcode = (existingBarcode ?? '').trim();
    if (barcode.isEmpty) {
      barcode = await service.ensureItemHasBarcode(
        itemKey,
        defaultBarcode: existingBarcode,
        sellingPrice: effectiveSellingPrice,
        mrp: effectiveMrp,
      );
    }

    final item = BarcodeLabelItem(
      itemKey: itemKey,
      name: name,
      model: model,
      brand: brand,
      barcode: barcode,
      sellingPrice: effectiveSellingPrice,
      mrp: effectiveMrp,
      quantity: initialQuantity > 0 ? initialQuantity : 1,
    );

    if (context.mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => BarcodePrintDialog(
          initialItems: [item],
          title: 'Print Barcode Labels — $name',
        ),
      );
    }
  }

  @override
  State<BarcodePrintDialog> createState() => _BarcodePrintDialogState();
}

class _BarcodePrintDialogState extends State<BarcodePrintDialog> {
  final BarcodeLabelService _service = BarcodeLabelService.instance;
  late List<BarcodeLabelItem> _items;
  bool _showPrice = true;
  bool _isPrinting = false;
  bool _isCalibrating = false;
  int _selectedPreviewIndex = 0;

  @override
  void initState() {
    super.initState();
    _items = widget.initialItems.map((e) => e.copyWith()).toList();
    _service.addListener(_onServiceChanged);
    _service.initialize();
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  int get _totalLabelsCount =>
      _items.fold<int>(0, (sum, it) => sum + it.quantity);

  Future<void> _handlePrint() async {
    final validItems = _items.where((it) => it.quantity > 0).toList();
    if (validItems.isEmpty) {
      TekFeedback.error('No labels to print (Quantities are 0)');
      return;
    }

    setState(() => _isPrinting = true);
    try {
      // 1. Ensure any edited barcodes are saved permanently in Db.items
      for (final it in validItems) {
        if (it.itemKey != null && it.barcode.trim().isNotEmpty) {
          await _service.saveItemBarcode(
            it.itemKey,
            it.barcode.trim(),
            price: it.sellingPrice,
          );
        }
      }

      // 2. Dispatch direct TSPL print job to TVS LP 46 Lite
      final result = await _service.printLabels(
        items: validItems,
        showPrice: _showPrice,
      );

      if (mounted) {
        if (result.success) {
          TekFeedback.success(
            result.message.isNotEmpty
                ? result.message
                : 'Successfully sent $_totalLabelsCount labels to TVS LP 46 Lite.',
          );
          Navigator.of(context).pop();
        } else {
          TekFeedback.error(result.message);
        }
      }
    } catch (e) {
      if (mounted) TekFeedback.error('Print Error: $e');
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  Future<void> _handleCalibrate() async {
    setState(() => _isCalibrating = true);
    try {
      final res = await _service.calibratePrinter();
      if (mounted) {
        if (res.success) {
          TekFeedback.success('TVS LP 46 Lite Gap Sensor calibrated successfully (GAPDETECT).');
        } else {
          TekFeedback.error(res.message);
        }
      }
    } catch (e) {
      if (mounted) TekFeedback.error('Calibration error: $e');
    } finally {
      if (mounted) setState(() => _isCalibrating = false);
    }
  }

  Future<void> _handleTestPrint() async {
    final preview = _items.isNotEmpty
        ? _items[_selectedPreviewIndex.clamp(0, _items.length - 1)]
        : null;
    if (preview == null) return;

    setState(() => _isPrinting = true);
    try {
      final testItem = preview.copyWith(quantity: 1);
      final res = await _service.printLabels(
        items: [testItem],
        showPrice: _showPrice,
      );
      if (mounted) {
        if (res.success) {
          TekFeedback.success('Test label printed successfully on ${_service.config.profile.shortName} sticker.');
        } else {
          TekFeedback.error(res.message);
        }
      }
    } catch (e) {
      if (mounted) TekFeedback.error('Test print failed: $e');
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  void _showTsplCodeDialog() {
    final validItems = _items.where((it) => it.quantity > 0).toList();
    final tspl = _service.generateTsplCommands(
      items: validItems,
      showPrice: _showPrice,
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101846),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: DashboardColors.glassBorderHover),
        ),
        title: const Row(
          children: [
            Icon(Icons.code_rounded, color: DashboardColors.neonBlue),
            SizedBox(width: 8),
            Text(
              'TVS LP 46 Lite Native TSPL Commands',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
        content: Container(
          width: 540,
          height: 340,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12),
          ),
          child: SelectableText(
            tspl,
            style: const TextStyle(
              color: DashboardColors.neonGreen,
              fontFamily: 'Courier',
              fontSize: 12,
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy to Clipboard'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: tspl));
              TekFeedback.toast('TSPL commands copied!');
            },
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: DashboardColors.primaryBlue,
            ),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final previewItem = _items.isNotEmpty
        ? _items[_selectedPreviewIndex.clamp(0, _items.length - 1)]
        : null;

    final isPrinterConnected = _service.isConnected;
    final activePrinterName = _service.config.printerName;

    return Dialog(
      backgroundColor: const Color(0xFF0C1236),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: DashboardColors.glassBorderHover),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Container(
        width: 900,
        constraints: const BoxConstraints(maxHeight: 720),
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. DIALOG HEADER & PRINTER BADGES
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: DashboardColors.neonBlue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.print_rounded,
                      color: DashboardColors.neonBlue, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: DashboardTypography.poppins(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildBadge(
                            'TVS LP 46 Lite / LP 44 Lite',
                            DashboardColors.neonGreen,
                            Icons.check_circle_outline_rounded,
                          ),
                          _buildBadge(
                            '${_service.config.profile.name} (3 mm Gap)',
                            DashboardColors.neonBlue,
                            Icons.aspect_ratio_rounded,
                          ),
                          _buildBadge(
                            '203 DPI • TSPL RAW',
                            DashboardColors.neonPurple,
                            Icons.speed_rounded,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  tooltip: 'Close',
                ),
              ],
            ),

            const SizedBox(height: 14),

            // 2. PRINTER HARDWARE SELECTION & STATUS BAR
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isPrinterConnected
                      ? DashboardColors.neonGreen.withValues(alpha: 0.3)
                      : DashboardColors.neonOrange.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  // Status Icon Indicator
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isPrinterConnected
                          ? DashboardColors.neonGreen
                          : DashboardColors.neonOrange,
                      boxShadow: [
                        BoxShadow(
                          color: (isPrinterConnected
                                  ? DashboardColors.neonGreen
                                  : DashboardColors.neonOrange)
                              .withValues(alpha: 0.6),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),

                  // Connection status text
                  Text(
                    isPrinterConnected ? 'Printer Connected:' : 'Target Printer:',
                    style: TextStyle(
                      color: isPrinterConnected
                          ? DashboardColors.neonGreen
                          : DashboardColors.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Printer Selector Dropdown
                  Expanded(
                    child: _service.availablePrinters.isEmpty
                        ? Text(
                            activePrinterName.isNotEmpty
                                ? activePrinterName
                                : 'No printers detected. Click refresh to scan.',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          )
                        : DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _service.availablePrinters
                                      .any((p) => p.name == activePrinterName)
                                  ? activePrinterName
                                  : (_service.availablePrinters.isNotEmpty
                                      ? _service.availablePrinters.first.name
                                      : null),
                              isDense: true,
                              dropdownColor: const Color(0xFF141A42),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                              items: _service.availablePrinters.map((p) {
                                final isTvs = p.isTargetTvs;
                                return DropdownMenuItem<String>(
                                  value: p.name,
                                  child: Row(
                                    children: [
                                      Text(
                                        p.name,
                                        style: TextStyle(
                                          color: isTvs
                                              ? DashboardColors.neonGreen
                                              : Colors.white,
                                          fontWeight: isTvs
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                      if (isTvs) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: DashboardColors.neonGreen
                                                .withValues(alpha: 0.15),
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: const Text(
                                            'TVS Recommended',
                                            style: TextStyle(
                                              color: DashboardColors.neonGreen,
                                              fontSize: 10,
                                            ),
                                          ),
                                        ),
                                      ],
                                      if (p.port.isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        Text(
                                          '(${p.port})',
                                          style: const TextStyle(
                                            color: DashboardColors.textMuted,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  _service.selectPrinter(val);
                                }
                              },
                            ),
                          ),
                  ),

                  // Refresh printers button
                  IconButton(
                    icon: const Icon(Icons.sync_rounded,
                        size: 18, color: DashboardColors.neonBlue),
                    tooltip: 'Rescan Printers',
                    onPressed: () => _service.refreshPrinters(),
                  ),

                  const SizedBox(width: 6),

                  // Calibrate Gap Sensor Button
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: DashboardColors.neonPurple,
                      side: const BorderSide(color: DashboardColors.neonPurple),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: _isCalibrating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: DashboardColors.neonPurple,
                            ),
                          )
                        : const Icon(Icons.tune_rounded, size: 14),
                    label: const Text('Calibrate Gap',
                        style: TextStyle(fontSize: 12)),
                    onPressed: _isCalibrating || _isPrinting
                        ? null
                        : _handleCalibrate,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // 3. MAIN BODY (Items list on left, sticker preview & settings on right)
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left Column: Items List & Quantity Adjustments
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Items to Print (${_items.length})',
                              style: DashboardTypography.poppins(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: DashboardColors.neonGreen
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                    color: DashboardColors.neonGreen
                                        .withValues(alpha: 0.3)),
                              ),
                              child: Text(
                                'Total Stickers: $_totalLabelsCount',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: DashboardColors.neonGreen,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.03),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0x1AFFFFFF)),
                            ),
                            child: ListView.separated(
                              padding: const EdgeInsets.all(8),
                              itemCount: _items.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(color: Color(0x12FFFFFF), height: 12),
                              itemBuilder: (ctx, idx) {
                                final it = _items[idx];
                                final isSelected = _selectedPreviewIndex == idx;

                                return InkWell(
                                  onTap: () =>
                                      setState(() => _selectedPreviewIndex = idx),
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? DashboardColors.neonBlue
                                              .withValues(alpha: 0.12)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: isSelected
                                            ? DashboardColors.neonBlue
                                                .withValues(alpha: 0.4)
                                            : Colors.transparent,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        // Radio indicator
                                        Icon(
                                          isSelected
                                              ? Icons.radio_button_checked_rounded
                                              : Icons.radio_button_off_rounded,
                                          size: 16,
                                          color: isSelected
                                              ? DashboardColors.neonBlue
                                              : DashboardColors.textMuted,
                                        ),
                                        const SizedBox(width: 8),

                                        // Item Name & Model & Barcode
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                it.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Row(
                                                children: [
                                                  if (it.model.isNotEmpty) ...[
                                                    Text(
                                                      'Model: ${it.model}',
                                                      style: const TextStyle(
                                                        color: DashboardColors
                                                            .textMuted,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                  ],
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                            horizontal: 6,
                                                            vertical: 1.5),
                                                    decoration: BoxDecoration(
                                                      color: Colors.white
                                                          .withValues(alpha: 0.08),
                                                      borderRadius:
                                                          BorderRadius.circular(4),
                                                    ),
                                                    child: Text(
                                                      it.barcode,
                                                      style: const TextStyle(
                                                        color: DashboardColors
                                                            .neonPurple,
                                                        fontSize: 10.5,
                                                        fontFamily: 'Courier',
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),

                                        // Selling Price
                                        if (it.sellingPrice != null &&
                                            it.sellingPrice! > 0) ...[
                                          Text(
                                            '₹${it.sellingPrice!.toStringAsFixed(0)}',
                                            style: const TextStyle(
                                              color: DashboardColors.textLight,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                        ],

                                        // Quantity Stepper
                                        Container(
                                          decoration: BoxDecoration(
                                            color: Colors.black
                                                .withValues(alpha: 0.4),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            border: Border.all(
                                                color: const Color(0x2AFFFFFF)),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              IconButton(
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(
                                                    minWidth: 26, minHeight: 26),
                                                icon: const Icon(
                                                    Icons.remove_rounded,
                                                    size: 15,
                                                    color: Colors.white70),
                                                onPressed: () {
                                                  if (it.quantity > 0) {
                                                    setState(() => it.quantity--);
                                                  }
                                                },
                                              ),
                                              Container(
                                                width: 30,
                                                alignment: Alignment.center,
                                                child: Text(
                                                  '${it.quantity}',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                              IconButton(
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(
                                                    minWidth: 26, minHeight: 26),
                                                icon: const Icon(
                                                    Icons.add_rounded,
                                                    size: 15,
                                                    color: DashboardColors
                                                        .neonGreen),
                                                onPressed: () {
                                                  setState(() => it.quantity++);
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 18),

                  // Right Column: Physical Sticker Preview & Profile Options
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // PROFILE SWITCHER & PREVIEW HEADER
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Preview',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: DashboardColors.neonBlue.withValues(alpha: 0.5)),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<LabelProfile>(
                                  value: _service.config.profile,
                                  isDense: true,
                                  dropdownColor: const Color(0xFF141A42),
                                  style: const TextStyle(
                                    color: DashboardColors.neonBlue,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  icon: const Icon(Icons.arrow_drop_down, color: DashboardColors.neonBlue, size: 16),
                                  items: LabelProfile.values.map((prof) {
                                    return DropdownMenuItem<LabelProfile>(
                                      value: prof,
                                      child: Text(prof.shortName),
                                    );
                                  }).toList(),
                                  onChanged: (newProf) {
                                    if (newProf != null) {
                                      _service.setProfile(newProf);
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        // Physical Sticker Simulation Card (Exact Proportions for 38x25mm or 50x25mm)
                        Center(
                          child: Builder(
                            builder: (context) {
                              final is38x25 = _service.config.profile == LabelProfile.profile38x25;
                              final previewWidth = is38x25 ? 240.0 : 280.0;
                              final previewHeight = is38x25 ? 158.0 : 140.0;

                              return Container(
                                width: previewWidth,
                                height: previewHeight,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(4),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.4),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: previewItem != null
                                    ? Column(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          // 1. Store Name Header (Bold Uppercase, Single Line, Center)
                                          Text(
                                            _service.config.storeName.toUpperCase(),
                                            maxLines: 1,
                                            style: const TextStyle(
                                              color: Colors.black,
                                              fontSize: 10.0,
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: 0.5,
                                            ),
                                          ),

                                          // 2. Product Name (Single Line Truncated with Ellipsis)
                                          Text(
                                            previewItem.name.replaceAll(RegExp(r'\s+'), ' '),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: Colors.black,
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.bold,
                                              height: 1.1,
                                            ),
                                          ),

                                          // 3. Simulated Code 128 Barcode graphic (Height 10-11mm, Max 32mm width)
                                          _buildSimulatedBarcode(
                                            previewItem.barcode,
                                            maxWidth: is38x25 ? 180 : 220,
                                          ),

                                          // 4. Barcode Human-Readable String (Below bars, 5.5-6pt, no redundant IDs)
                                          Text(
                                            previewItem.barcode,
                                            maxLines: 1,
                                            style: const TextStyle(
                                              color: Colors.black,
                                              fontSize: 8.5,
                                              fontFamily: 'Courier',
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 1.1,
                                            ),
                                          ),

                                          // 5. Footer: PRICE: ₹450 (High Contrast Bold, Inside Margins)
                                          if (_showPrice && previewItem.hasValidPrice) ...[
                                            Text(
                                              'PRICE: ₹${previewItem.effectivePrice!.toStringAsFixed(previewItem.effectivePrice!.truncateToDouble() == previewItem.effectivePrice! ? 0 : 2)}',
                                              maxLines: 1,
                                              style: const TextStyle(
                                                color: Colors.black,
                                                fontSize: 11.0,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                          ] else if (_showPrice) ...[
                                            const Text(
                                              '⚠️ PRICE NOT SET',
                                              style: TextStyle(
                                                color: Colors.red,
                                                fontSize: 8.5,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ] else ...[
                                            const SizedBox(height: 12),
                                          ],
                                        ],
                                      )
                                    : const Center(
                                        child: Text(
                                          'No Item Selected',
                                          style: TextStyle(color: Colors.black54),
                                        ),
                                      ),
                              );
                            },
                          ),
                        ),

                        // Validation warning if price is missing/0
                        if (previewItem != null && _showPrice && !previewItem.hasValidPrice) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 16),
                                SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Selling Price / MRP is missing or ₹0. Price will not be printed.',
                                    style: TextStyle(color: Colors.orangeAccent, fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 10),

                        // Options & Toggles
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0x1AFFFFFF)),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: const Text(
                                'Print Selling Price (MRP)',
                                style: TextStyle(color: Colors.white, fontSize: 12),
                              ),
                              subtitle: const Text(
                                'Prints "PRICE: ₹..." on the sticker footer',
                                style: TextStyle(color: DashboardColors.textMuted, fontSize: 10.5),
                              ),
                              activeTrackColor: DashboardColors.neonGreen.withAlpha(128),
                              activeThumbColor: DashboardColors.neonGreen,
                              value: _showPrice,
                              onChanged: (v) => setState(() => _showPrice = v),
                            ),
                          ),
                        ),

                        const Spacer(),

                        // Advanced TSPL command viewer link
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            icon: const Icon(Icons.code_rounded, size: 14),
                            label: const Text(
                              'View TSPL Commands (Direct Thermal)',
                              style: TextStyle(fontSize: 11),
                            ),
                            onPressed: _showTsplCodeDialog,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            const Divider(color: Color(0x1AFFFFFF)),
            const SizedBox(height: 8),

            // 4. DIALOG ACTIONS
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel',
                      style: TextStyle(color: DashboardColors.textMuted)),
                ),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: DashboardColors.neonOrange,
                        side: const BorderSide(color: DashboardColors.neonOrange),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.print_outlined, size: 16),
                      label: const Text('Test Print (1 Label)'),
                      onPressed: _isPrinting ? null : _handleTestPrint,
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: DashboardColors.neonBlue,
                        side: const BorderSide(color: DashboardColors.neonBlue),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Reset'),
                      onPressed: () {
                        setState(() {
                          _items = widget.initialItems
                              .map((e) => e.copyWith())
                              .toList();
                        });
                      },
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: DashboardColors.neonGreen,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: _isPrinting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : const Icon(Icons.print_rounded, size: 18),
                      label: Text(
                        _isPrinting
                            ? 'Sending...'
                            : 'Print $_totalLabelsCount Labels',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13.5,
                        ),
                      ),
                      onPressed: _isPrinting ? null : _handlePrint,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBadge(String text, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimulatedBarcode(String code, {double maxWidth = 200}) {
    return Container(
      height: 34,
      width: maxWidth,
      decoration: const BoxDecoration(
        color: Colors.transparent,
      ),
      child: CustomPaint(
        painter: _BarcodePainter(code),
      ),
    );
  }
}

class _BarcodePainter extends CustomPainter {
  final String text;
  _BarcodePainter(this.text);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    final int hash = text.hashCode.abs();
    final double step = size.width / 46.0;

    for (int i = 0; i < 46; i++) {
      final bool bar = ((hash >> (i % 30)) & 1) == 1 || (i % 3 != 0);
      if (bar) {
        final double barWidth = (i % 5 == 0) ? step * 1.6 : step * 0.85;
        canvas.drawRect(
          Rect.fromLTWH(i * step, 0, barWidth, size.height),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarcodePainter oldDelegate) =>
      oldDelegate.text != text;
}
