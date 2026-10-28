import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart' show Db;
import '../purchases/purchase_models.dart';
import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
import '../utils/tek_helpers.dart';
import 'barcode_label_service.dart';

/// Modal dialog to configure and print barcode labels on TVS LP 46 Lite (38 mm x 25 mm).
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
      // 1. Look up item in Db.items to find existing barcode and selling price
      double? sellingPrice;
      String barcode = it.sku.trim();

      if (it.itemKey != null && Db.items.containsKey(it.itemKey)) {
        final rec = tekM(Db.items.get(it.itemKey));
        barcode = '${rec['barcode'] ?? rec['code'] ?? rec['sku'] ?? barcode}'.trim();
        sellingPrice = (rec['price'] as num?)?.toDouble() ??
            (rec['sellingPrice'] as num?)?.toDouble();
      }

      // If still empty, ensure permanent barcode in Db.items
      if (barcode.isEmpty) {
        barcode = await service.ensureItemHasBarcode(
          it.itemKey,
          defaultBarcode: it.sku.isNotEmpty ? it.sku : null,
          sellingPrice: sellingPrice,
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
          // Requirement 9: Default quantity to purchased quantity (e.g. 10 if 10 purchased)
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
    int initialQuantity = 1,
  }) async {
    final service = BarcodeLabelService.instance;
    String barcode = (existingBarcode ?? '').trim();
    if (barcode.isEmpty) {
      barcode = await service.ensureItemHasBarcode(
        itemKey,
        defaultBarcode: existingBarcode,
        sellingPrice: sellingPrice,
      );
    }

    final item = BarcodeLabelItem(
      itemKey: itemKey,
      name: name,
      model: model,
      brand: brand,
      barcode: barcode,
      sellingPrice: sellingPrice,
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
  late List<BarcodeLabelItem> _items;
  bool _showPrice = true;
  bool _isPrinting = false;
  int _selectedPreviewIndex = 0;

  @override
  void initState() {
    super.initState();
    _items = widget.initialItems.map((e) => e.copyWith()).toList();
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
      // 1. Ensure any edited barcodes are saved permanently in Db.items (Requirement 10)
      for (final it in validItems) {
        if (it.itemKey != null && it.barcode.trim().isNotEmpty) {
          await BarcodeLabelService.instance.saveItemBarcode(
            it.itemKey,
            it.barcode.trim(),
            price: it.sellingPrice,
          );
        }
      }

      // 2. Dispatch print job using native printer dialog with exact 38x25mm specs
      if (mounted) {
        await BarcodeLabelService.instance.printLabels(
          context,
          items: validItems,
          showPrice: _showPrice,
          jobName: 'TVS_LP46_38x25mm_Labels',
        );
      }
    } catch (e) {
      TekFeedback.error('Print Error: $e');
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  void _showTsplCodeDialog() {
    final validItems = _items.where((it) => it.quantity > 0).toList();
    final tspl = BarcodeLabelService.instance.generateTsplCommands(
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
        title: Row(
          children: [
            const Icon(Icons.code_rounded, color: DashboardColors.neonBlue),
            const SizedBox(width: 8),
            const Text(
              'TVS LP 46 Lite TSPL Commands',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
        content: Container(
          width: 520,
          height: 320,
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

    return Dialog(
      backgroundColor: const Color(0xFF0C1236),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: DashboardColors.glassBorderHover),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 860,
        constraints: const BoxConstraints(maxHeight: 680),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. DIALOG HEADER
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
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          _buildBadge(
                            'TVS LP 46 Lite',
                            DashboardColors.neonGreen,
                            Icons.check_circle_outline_rounded,
                          ),
                          const SizedBox(width: 8),
                          _buildBadge(
                            '38 mm × 25 mm Sticker',
                            DashboardColors.neonBlue,
                            Icons.aspect_ratio_rounded,
                          ),
                          const SizedBox(width: 8),
                          _buildBadge(
                            'Code 128 Standard',
                            DashboardColors.neonPurple,
                            Icons.qr_code_2_rounded,
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

            const SizedBox(height: 18),
            const Divider(color: Color(0x1AFFFFFF)),
            const SizedBox(height: 12),

            // 2. MAIN BODY (Items list on left, sticker preview & settings on right)
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
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              'Total Stickers: $_totalLabelsCount',
                              style: DashboardTypography.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: DashboardColors.neonGreen,
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
                              padding: const EdgeInsets.all(10),
                              itemCount: _items.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(color: Color(0x12FFFFFF), height: 16),
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
                                                        color: DashboardColors.textMuted,
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
                                                        color: DashboardColors.neonPurple,
                                                        fontSize: 10.5,
                                                        fontFamily: 'Courier',
                                                        fontWeight: FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),

                                        // Price display / edit
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
                                          const SizedBox(width: 12),
                                        ],

                                        // Quantity Stepper (Requirement 9)
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
                                                    minWidth: 28, minHeight: 28),
                                                icon: const Icon(
                                                    Icons.remove_rounded,
                                                    size: 16,
                                                    color: Colors.white70),
                                                onPressed: () {
                                                  if (it.quantity > 0) {
                                                    setState(() => it.quantity--);
                                                  }
                                                },
                                              ),
                                              Container(
                                                width: 34,
                                                alignment: Alignment.center,
                                                child: Text(
                                                  '${it.quantity}',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 13,
                                                  ),
                                                ),
                                              ),
                                              IconButton(
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(
                                                    minWidth: 28, minHeight: 28),
                                                icon: const Icon(
                                                    Icons.add_rounded,
                                                    size: 16,
                                                    color: DashboardColors.neonGreen),
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

                  const SizedBox(width: 20),

                  // Right Column: Physical Sticker Preview & Settings
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '38 × 25 mm Physical Preview',
                          style: DashboardTypography.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),

                        // Physical Sticker Simulation Card
                        Center(
                          child: Container(
                            width: 228, // 38 mm proportional preview (6x scale)
                            height: 150, // 25 mm proportional preview (6x scale)
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(4),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.35),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: previewItem != null
                                ? Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      // Shop Name Header
                                      const Text(
                                        'TEKFIX DIGITAL',
                                        style: TextStyle(
                                          color: Colors.black,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0.5,
                                        ),
                                      ),

                                      // Item Name
                                      Text(
                                        previewItem.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.black,
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),

                                      // Model (if any)
                                      if (previewItem.model.isNotEmpty)
                                        Text(
                                          'Model: ${previewItem.model}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.black87,
                                            fontSize: 8.5,
                                          ),
                                        ),

                                      // Simulated Barcode graphic
                                      _buildSimulatedBarcode(previewItem.barcode),

                                      // Barcode Text
                                      Text(
                                        previewItem.barcode,
                                        style: const TextStyle(
                                          color: Colors.black,
                                          fontSize: 9,
                                          fontFamily: 'Courier',
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 1.0,
                                        ),
                                      ),

                                      // Selling Price (MRP)
                                      if (_showPrice &&
                                          previewItem.sellingPrice != null &&
                                          previewItem.sellingPrice! > 0)
                                        Text(
                                          'MRP: Rs. ${previewItem.sellingPrice!.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            color: Colors.black,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        )
                                      else
                                        const SizedBox(height: 2),
                                    ],
                                  )
                                : const Center(
                                    child: Text(
                                      'No Item Selected',
                                      style: TextStyle(color: Colors.black54),
                                    ),
                                  ),
                          ),
                        ),

                        const SizedBox(height: 16),

                        // Options & Toggles
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0x1AFFFFFF)),
                          ),
                          child: Column(
                            children: [
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: const Text(
                                  'Print Selling Price (MRP)',
                                  style: TextStyle(
                                      color: Colors.white, fontSize: 13),
                                ),
                                subtitle: const Text(
                                  'Includes MRP at the bottom of the label',
                                  style: TextStyle(
                                      color: DashboardColors.textMuted,
                                      fontSize: 11),
                                ),
                                activeColor: DashboardColors.neonGreen,
                                value: _showPrice,
                                onChanged: (v) => setState(() => _showPrice = v),
                              ),
                            ],
                          ),
                        ),

                        const Spacer(),

                        // Advanced TSPL command viewer link
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            icon: const Icon(Icons.code_rounded, size: 15),
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

            const SizedBox(height: 16),
            const Divider(color: Color(0x1AFFFFFF)),
            const SizedBox(height: 10),

            // 3. DIALOG ACTIONS
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel',
                      style: TextStyle(color: DashboardColors.textMuted)),
                ),
                Row(
                  children: [
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: DashboardColors.neonBlue,
                        side: const BorderSide(color: DashboardColors.neonBlue),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Reset Quantities'),
                      onPressed: () {
                        setState(() {
                          _items = widget.initialItems
                              .map((e) => e.copyWith())
                              .toList();
                        });
                      },
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: DashboardColors.neonGreen,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
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
                            ? 'Preparing Print Job...'
                            : 'Print $_totalLabelsCount Labels (TVS LP 46)',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
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

  Widget _buildSimulatedBarcode(String code) {
    return Container(
      height: 38,
      width: 180,
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
    final double step = size.width / 42.0;

    for (int i = 0; i < 42; i++) {
      final bool bar = ((hash >> (i % 30)) & 1) == 1 || (i % 3 != 0);
      if (bar) {
        final double barWidth = (i % 5 == 0) ? step * 1.5 : step * 0.8;
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
