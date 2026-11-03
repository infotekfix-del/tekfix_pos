import 'package:flutter/material.dart';
import '../main.dart' show Db, ModeSelector, printInvoice, toast;
import '../staff/activity_log.dart';
import '../theme/tek_tokens.dart';
import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
import '../utils/tek_helpers.dart';

/// Represents a selected spare part item for a service bill.
class ServiceSparePart {
  final dynamic itemKey;
  final String itemId;
  final String name;
  final String category;
  final String barcode;
  final double costPrice;
  final double unitPrice;
  int qty;
  final int maxStock;

  ServiceSparePart({
    required this.itemKey,
    this.itemId = '',
    required this.name,
    this.category = '',
    this.barcode = '',
    this.costPrice = 0.0,
    required this.unitPrice,
    this.qty = 1,
    required this.maxStock,
  });

  double get lineTotal => unitPrice * qty;
  double get lineCost => costPrice * qty;

  Map<String, dynamic> toMap() => {
        'key': itemKey,
        'id': itemId,
        'name': name,
        'category': category,
        'barcode': barcode,
        'costPrice': costPrice,
        'price': unitPrice,
        'qty': qty,
        'lineTotal': lineTotal,
        'lineCost': lineCost,
      };
}

/// Production-ready Service Bill Dialog with searchable inventory autocomplete,
/// multi-item spare parts tracking, real-time pricing calculation, and atomic stock reduction.
class ServiceBillDialog extends StatefulWidget {
  final dynamic jobKey;
  final Map<String, dynamic> job;

  const ServiceBillDialog({
    super.key,
    required this.jobKey,
    required this.job,
  });

  /// Factory helper to launch the dialog.
  static Future<bool> show(
    BuildContext context, {
    required dynamic jobKey,
    required Map<String, dynamic> job,
  }) async {
    if (job['billCreated'] == true) {
      TekFeedback.error('ഈ Job-ന് ബിൽ ഇതിനകം സൃഷ്ടിച്ചിട്ടുണ്ട് (Bill already created)');
      return false;
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ServiceBillDialog(jobKey: jobKey, job: job),
    );
    return result ?? false;
  }

  @override
  State<ServiceBillDialog> createState() => _ServiceBillDialogState();
}

class _ServiceBillDialogState extends State<ServiceBillDialog> {
  late final TextEditingController _serviceChargeCtrl;
  late final TextEditingController _partsChargeCtrl;
  late final TextEditingController _labourCtrl;
  late final TextEditingController _discountCtrl;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  final List<ServiceSparePart> _selectedParts = [];
  List<MapEntry<dynamic, Map<String, dynamic>>> _searchResults = [];
  bool _isSearching = false;
  bool _autoSyncPartsCharge = true;
  String _paymentMode = 'Cash';
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final estCost = (widget.job['estimatedCost'] as num?)?.toDouble() ??
        double.tryParse('${widget.job['estimatedCost']}') ??
        0.0;
    _serviceChargeCtrl = TextEditingController(
      text: estCost > 0 ? estCost.toStringAsFixed(0) : '0',
    );
    _partsChargeCtrl = TextEditingController(text: '0');
    _labourCtrl = TextEditingController(text: '0');
    _discountCtrl = TextEditingController(text: '0');

    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _serviceChargeCtrl.dispose();
    _partsChargeCtrl.dispose();
    _labourCtrl.dispose();
    _discountCtrl.dispose();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchCtrl.text.trim().toLowerCase();
    if (query.isEmpty) {
      if (_searchResults.isNotEmpty) {
        setState(() {
          _searchResults = [];
          _isSearching = false;
        });
      }
      return;
    }

    final allItems = entriesOf(Db.items);
    final matches = allItems.where((e) {
      final it = e.value;
      final name = '${it['name'] ?? ''}'.toLowerCase();
      final cat = '${it['category'] ?? ''}'.toLowerCase();
      final barcode =
          '${it['barcode'] ?? it['code'] ?? it['sku'] ?? ''}'.toLowerCase();
      final model = '${it['model'] ?? ''}'.toLowerCase();
      return name.contains(query) ||
          cat.contains(query) ||
          barcode.contains(query) ||
          model.contains(query);
    }).take(8).toList();

    setState(() {
      _searchResults = matches;
      _isSearching = true;
    });
  }

  double get _partsTotal =>
      _selectedParts.fold<double>(0.0, (sum, p) => sum + p.lineTotal);

  double get _totalCostPrice =>
      _selectedParts.fold<double>(0.0, (sum, p) => sum + p.lineCost);

  double get _serviceCharge =>
      double.tryParse(_serviceChargeCtrl.text.trim()) ?? 0.0;

  double get _partsCharge =>
      double.tryParse(_partsChargeCtrl.text.trim()) ?? 0.0;

  double get _labour => double.tryParse(_labourCtrl.text.trim()) ?? 0.0;

  double get _discount => double.tryParse(_discountCtrl.text.trim()) ?? 0.0;

  double get _grossTotal {
    final t = _serviceCharge + _partsCharge + _labour - _discount;
    return t < 0 ? 0.0 : t;
  }

  double get _advanceReceived {
    final adv = widget.job['advance'];
    return (adv as num?)?.toDouble() ?? double.tryParse('$adv') ?? 0.0;
  }

  double get _netBalanceDue {
    final bal = _grossTotal - _advanceReceived;
    return bal < 0 ? 0.0 : bal;
  }

  void _syncPartsCharge() {
    if (_autoSyncPartsCharge) {
      _partsChargeCtrl.text = _partsTotal.toStringAsFixed(0);
    }
  }

  void _addSparePart(MapEntry<dynamic, Map<String, dynamic>> entry) {
    final raw = entry.value;
    final key = entry.key;
    final name = '${raw['name'] ?? 'Spare Part'}'.trim();
    final cat = '${raw['category'] ?? ''}'.trim();
    final barcode =
        '${raw['barcode'] ?? raw['code'] ?? raw['sku'] ?? ''}'.trim();
    final costPrice = (raw['costPrice'] as num?)?.toDouble() ?? 0.0;
    final sellingPrice = (raw['sellingPrice'] as num?)?.toDouble() ??
        (raw['price'] as num?)?.toDouble() ??
        costPrice;
    final stock = (raw['stock'] as num?)?.toInt() ?? 0;

    // Check if already in selected list
    final existingIndex = _selectedParts.indexWhere((p) => p.itemKey == key);
    if (existingIndex >= 0) {
      final existing = _selectedParts[existingIndex];
      if (existing.qty < stock) {
        setState(() {
          existing.qty++;
          _syncPartsCharge();
        });
        TekFeedback.toast('Incremented quantity: $name (${existing.qty})');
      } else {
        TekFeedback.error('Cannot add more than available stock ($stock)');
      }
    } else {
      if (stock <= 0) {
        TekFeedback.error('Warning: "$name" is out of stock in inventory (Stock: 0)');
      }
      setState(() {
        _selectedParts.add(
          ServiceSparePart(
            itemKey: key,
            itemId: '${raw['id'] ?? key}',
            name: name,
            category: cat,
            barcode: barcode,
            costPrice: costPrice,
            unitPrice: sellingPrice,
            qty: 1,
            maxStock: stock,
          ),
        );
        _syncPartsCharge();
      });
      TekFeedback.success('Added "$name" to repair bill');
    }

    _searchCtrl.clear();
    setState(() {
      _searchResults = [];
      _isSearching = false;
    });
  }

  void _removeSparePart(int index) {
    setState(() {
      _selectedParts.removeAt(index);
      _syncPartsCharge();
    });
  }

  void _updateQuantity(int index, int delta) {
    setState(() {
      final part = _selectedParts[index];
      final newQty = part.qty + delta;
      if (newQty <= 0) {
        _selectedParts.removeAt(index);
      } else if (newQty > part.maxStock) {
        TekFeedback.error('Cannot exceed available stock (${part.maxStock}) for ${part.name}');
      } else {
        part.qty = newQty;
      }
      _syncPartsCharge();
    });
  }

  Future<void> _handleConfirmBill() async {
    final total = _grossTotal;
    final advance = _advanceReceived;

    if (total < 0 || _discount < 0) {
      setState(() => _errorMessage = 'Please enter valid positive amounts.');
      return;
    }

    if (total < advance) {
      setState(() => _errorMessage =
          'Final bill (₹${total.toStringAsFixed(0)}) cannot be less than advance already paid (₹${advance.toStringAsFixed(0)}).');
      return;
    }

    // 1. Live stock verification for all selected spare parts
    for (final part in _selectedParts) {
      if (part.itemKey != null && Db.items.containsKey(part.itemKey)) {
        final currentRec = tekM(Db.items.get(part.itemKey));
        final currentStock = (currentRec['stock'] as num?)?.toInt() ?? 0;
        if (currentStock < part.qty) {
          setState(() => _errorMessage =
              'Insufficient stock for "${part.name}": Available $currentStock, Required ${part.qty}');
          return;
        }
      }
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final due = (total - advance).clamp(0.0, double.infinity);
      final appliedAdvance = total < advance ? total : advance;
      final invoice = await Db.nextInvoice();

      // 2. Atomically reduce inventory & record stock movements
      final usedParts = <Map<String, dynamic>>[];
      double finalPartsCost = 0.0;

      for (final part in _selectedParts) {
        if (part.itemKey != null && Db.items.containsKey(part.itemKey)) {
          final item = tekM(Db.items.get(part.itemKey));
          final curStock = (item['stock'] as num?)?.toInt() ?? 0;
          final updated = Map<String, dynamic>.from(item);
          updated['stock'] = curStock - part.qty;
          await Db.items.put(part.itemKey, updated);

          final cost = (updated['costPrice'] as num?)?.toDouble() ?? part.costPrice;
          finalPartsCost += cost * part.qty;

          usedParts.add({
            'key': part.itemKey,
            'id': part.itemId,
            'name': part.name,
            'qty': part.qty,
            'unitPrice': part.unitPrice,
            'costPrice': cost,
            'lineTotal': part.lineTotal,
          });

          // Single-Step Inventory Movement log
          await Db.stockMove(
            part.itemKey,
            '${updated['name'] ?? part.name}',
            -part.qty,
            'Service ${widget.job['jobId']} - Spare Part',
          );
        }
      }

      // 3. Assemble detailed bill line items
      final billItems = <Map<String, dynamic>>[
        {
          'name': 'Service ${widget.job['jobId']} • ${widget.job['brandModel']}',
          'qty': 1,
          'price': _serviceCharge + _labour - _discount,
          'costPrice': 0.0,
          'warranty': '${tekI(widget.job['warrantyDays'])} days',
        },
        for (final p in _selectedParts)
          {
            'name': '${p.name} (Spare Part)',
            'qty': p.qty,
            'price': p.unitPrice,
            'costPrice': p.costPrice,
            'key': p.itemKey,
          },
      ];

      final bill = <String, dynamic>{
        'invoice': invoice,
        'createdAt': DateTime.now().toIso8601String(),
        'customerName': widget.job['customerName'],
        'customerPhone': widget.job['phone'],
        'partyKey': null,
        'items': billItems,
        'subtotal': total,
        'discount': _discount,
        'total': total,
        'cash': _paymentMode == 'Cash' ? due : 0.0,
        'upi': _paymentMode == 'Cash' ? 0.0 : due,
        'due': 0.0,
        'profit': tekR2(total - finalPartsCost),
        'gstRate': double.tryParse(Db.setting('gst_rate', '0')) ?? 0.0,
        'serviceJobId': widget.job['jobId'],
        'serviceAdvanceApplied': appliedAdvance,
        'serviceBill': true,
        'parts': usedParts,
        'status': 'SOLD',
        ...ActivityLog.stamp(),
      };

      // 4. Save sale record and accounting
      await Db.sales.add(bill);
      await Db.logAction(
        action: 'Service Billed',
        entity: 'Invoice',
        entityId: invoice,
        newValue: {'job': widget.job['jobId'], 'total': total, 'parts': usedParts},
      );

      if (due > 0) {
        await Db.moveMoney(_paymentMode, due, 'Service bill $invoice');
      }

      // 5. Update service job status and details
      final nextJob = Map<String, dynamic>.from(widget.job);
      nextJob['finalAmount'] = total;
      nextJob['paidAmount'] = total;
      nextJob['advanceApplied'] = appliedAdvance;
      nextJob['billCreated'] = true;
      nextJob['invoice'] = invoice;
      nextJob['parts'] = usedParts;
      nextJob['status'] = 'Ready';
      nextJob['warrantyStart'] = DateTime.now().toIso8601String();
      nextJob['warrantyEnd'] = DateTime.now()
          .add(Duration(days: tekI(widget.job['warrantyDays'])))
          .toIso8601String();

      await Db.services.put(widget.jobKey, nextJob);

      if (mounted) {
        TekFeedback.success('Service Invoice #$invoice created successfully!');
        Navigator.of(context).pop(true);
        await printInvoice(context, bill, a4: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = 'Failed to generate bill: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0C1236),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: DashboardColors.glassBorderHover),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Container(
        width: 820,
        constraints: const BoxConstraints(maxHeight: 740),
        padding: const EdgeInsets.all(22),
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
                  child: const Icon(Icons.receipt_long_rounded,
                      color: DashboardColors.neonBlue, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Service Bill • Job #${widget.job['jobId']}',
                        style: DashboardTypography.poppins(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.job['customerName'] ?? 'Customer'} • ${widget.job['brandModel'] ?? 'Device'} • Phone: ${widget.job['phone'] ?? 'N/A'}',
                        style: const TextStyle(
                          color: DashboardColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                  tooltip: 'Close',
                ),
              ],
            ),

            const SizedBox(height: 12),
            const Divider(color: Color(0x1AFFFFFF)),
            const SizedBox(height: 10),

            // 2. MAIN SCROLLABLE CONTENT
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A. CHARGES INPUT ROW (Service, Labour, Discount)
                    Row(
                      children: [
                        Expanded(
                          child: _buildInputField(
                            controller: _serviceChargeCtrl,
                            label: 'Service Charge ₹',
                            icon: Icons.handyman_rounded,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildInputField(
                            controller: _labourCtrl,
                            label: 'Labour Charge ₹',
                            icon: Icons.engineering_rounded,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildInputField(
                            controller: _discountCtrl,
                            label: 'Discount ₹',
                            icon: Icons.local_offer_rounded,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // B. SPARE PARTS SECTION HEADER & SEARCH INPUT
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.inventory_2_rounded,
                                size: 18, color: DashboardColors.neonGreen),
                            const SizedBox(width: 8),
                            Text(
                              'Spare Parts Used from Inventory',
                              style: DashboardTypography.poppins(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Text(
                              'Auto-sync Parts Charge',
                              style: TextStyle(
                                color: _autoSyncPartsCharge
                                    ? DashboardColors.neonGreen
                                    : DashboardColors.textMuted,
                                fontSize: 11,
                              ),
                            ),
                            Transform.scale(
                              scale: 0.75,
                              child: Switch(
                                value: _autoSyncPartsCharge,
                                activeColor: DashboardColors.neonGreen,
                                onChanged: (val) {
                                  setState(() {
                                    _autoSyncPartsCharge = val;
                                    if (val) _syncPartsCharge();
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // Searchable Autocomplete Bar
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        TextField(
                          controller: _searchCtrl,
                          focusNode: _searchFocus,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Search spare parts (Screen, Battery, IC, Cable, Barcode)...',
                            hintStyle: const TextStyle(
                                color: DashboardColors.textMuted, fontSize: 12),
                            prefixIcon: const Icon(Icons.search_rounded,
                                color: DashboardColors.neonBlue, size: 20),
                            suffixIcon: _searchCtrl.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear_rounded,
                                        size: 18, color: Colors.white60),
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() {
                                        _searchResults = [];
                                        _isSearching = false;
                                      });
                                    },
                                  )
                                : null,
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.05),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide:
                                  const BorderSide(color: Color(0x33FFFFFF)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                  color: DashboardColors.neonBlue, width: 1.5),
                            ),
                          ),
                        ),

                        // Autocomplete Suggestions Dropdown List
                        if (_isSearching && _searchResults.isNotEmpty)
                          Positioned(
                            top: 48,
                            left: 0,
                            right: 0,
                            child: Material(
                              elevation: 10,
                              borderRadius: BorderRadius.circular(10),
                              color: const Color(0xFF141C48),
                              child: Container(
                                constraints: const BoxConstraints(maxHeight: 220),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: DashboardColors.neonBlue
                                          .withValues(alpha: 0.5)),
                                ),
                                child: ListView.separated(
                                  shrinkWrap: true,
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  itemCount: _searchResults.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(color: Color(0x14FFFFFF), height: 1),
                                  itemBuilder: (ctx, idx) {
                                    final itemEntry = _searchResults[idx];
                                    final it = itemEntry.value;
                                    final name = '${it['name'] ?? ''}';
                                    final cat = '${it['category'] ?? ''}';
                                    final stock =
                                        (it['stock'] as num?)?.toInt() ?? 0;
                                    final price = (it['sellingPrice'] as num?)
                                            ?.toDouble() ??
                                        (it['price'] as num?)?.toDouble() ??
                                        0.0;
                                    final inStock = stock > 0;

                                    return ListTile(
                                      dense: true,
                                      leading: CircleAvatar(
                                        radius: 14,
                                        backgroundColor: inStock
                                            ? DashboardColors.neonGreen
                                                .withValues(alpha: 0.15)
                                            : Colors.red.withValues(alpha: 0.15),
                                        child: Icon(
                                          inStock
                                              ? Icons.check_circle_rounded
                                              : Icons.warning_rounded,
                                          size: 16,
                                          color: inStock
                                              ? DashboardColors.neonGreen
                                              : Colors.red,
                                        ),
                                      ),
                                      title: Text(
                                        name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      subtitle: Text(
                                        '${cat.isNotEmpty ? '$cat • ' : ''}Stock: $stock',
                                        style: TextStyle(
                                          color: inStock
                                              ? DashboardColors.neonGreen
                                              : Colors.red,
                                          fontSize: 11,
                                        ),
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '₹${price.toStringAsFixed(0)}',
                                            style: const TextStyle(
                                              color: DashboardColors.neonBlue,
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: inStock
                                                  ? DashboardColors.neonBlue
                                                  : Colors.white24,
                                              foregroundColor: Colors.black,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 10, vertical: 6),
                                              minimumSize: Size.zero,
                                              tapTargetSize:
                                                  MaterialTapTargetSize.shrinkWrap,
                                            ),
                                            onPressed: () =>
                                                _addSparePart(itemEntry),
                                            child: const Text('Add',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold)),
                                          ),
                                        ],
                                      ),
                                      onTap: () => _addSparePart(itemEntry),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // C. ATTACHED SPARE PARTS LIST
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0x1AFFFFFF)),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Parts Attached (${_selectedParts.length})',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12.5,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: DashboardColors.neonGreen
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: DashboardColors.neonGreen
                                          .withValues(alpha: 0.3)),
                                ),
                                child: Text(
                                  'Parts Total: ₹${_partsTotal.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                    color: DashboardColors.neonGreen,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (_selectedParts.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              child: Center(
                                child: Column(
                                  children: [
                                    Icon(Icons.inventory_2_outlined,
                                        size: 28, color: Colors.white24),
                                    const SizedBox(height: 6),
                                    const Text(
                                      'No spare parts attached yet.',
                                      style: TextStyle(
                                          color: DashboardColors.textMuted,
                                          fontSize: 12),
                                    ),
                                    const Text(
                                      'Search inventory above to add replacement screens, batteries, etc.',
                                      style: TextStyle(
                                          color: Colors.white38, fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _selectedParts.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(color: Color(0x14FFFFFF), height: 10),
                              itemBuilder: (ctx, idx) {
                                final part = _selectedParts[idx];
                                return Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            part.name,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          Text(
                                            'Stock: ${part.maxStock} • Unit: ₹${part.unitPrice.toStringAsFixed(0)}',
                                            style: const TextStyle(
                                              color: DashboardColors.textMuted,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),

                                    // Quantity Stepper
                                    Container(
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.4),
                                        borderRadius: BorderRadius.circular(6),
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
                                            onPressed: () =>
                                                _updateQuantity(idx, -1),
                                          ),
                                          Container(
                                            width: 28,
                                            alignment: Alignment.center,
                                            child: Text(
                                              '${part.qty}',
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
                                            icon: const Icon(Icons.add_rounded,
                                                size: 15,
                                                color:
                                                    DashboardColors.neonGreen),
                                            onPressed: () =>
                                                _updateQuantity(idx, 1),
                                          ),
                                        ],
                                      ),
                                    ),

                                    const SizedBox(width: 12),

                                    // Line Total
                                    SizedBox(
                                      width: 75,
                                      child: Text(
                                        '₹${part.lineTotal.toStringAsFixed(0)}',
                                        textAlign: TextAlign.right,
                                        style: const TextStyle(
                                          color: DashboardColors.neonBlue,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),

                                    const SizedBox(width: 6),

                                    // Remove Icon Button
                                    IconButton(
                                      icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 18,
                                          color: Colors.redAccent),
                                      onPressed: () => _removeSparePart(idx),
                                      tooltip: 'Remove',
                                    ),
                                  ],
                                );
                              },
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Manual Spare Parts Charge override if auto-sync is off
                    if (!_autoSyncPartsCharge) ...[
                      _buildInputField(
                        controller: _partsChargeCtrl,
                        label: 'Spare Parts Charge Billed to Customer ₹',
                        icon: Icons.price_check_rounded,
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // D. SUMMARY BREAKDOWN CARD
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141C48),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: DashboardColors.neonBlue
                                .withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        children: [
                          _buildSummaryRow(
                              'Service Charge:', '₹${_serviceCharge.toStringAsFixed(0)}'),
                          const SizedBox(height: 4),
                          _buildSummaryRow('Spare Parts Charge:',
                              '₹${_partsCharge.toStringAsFixed(0)}'),
                          if (_labour > 0) ...[
                            const SizedBox(height: 4),
                            _buildSummaryRow(
                                'Labour Charge:', '₹${_labour.toStringAsFixed(0)}'),
                          ],
                          if (_discount > 0) ...[
                            const SizedBox(height: 4),
                            _buildSummaryRow(
                              'Discount:',
                              '-₹${_discount.toStringAsFixed(0)}',
                              color: Colors.orangeAccent,
                            ),
                          ],
                          const Divider(color: Color(0x26FFFFFF), height: 14),
                          _buildSummaryRow(
                            'Gross Bill Total:',
                            '₹${_grossTotal.toStringAsFixed(0)}',
                            bold: true,
                            fontSize: 14,
                            color: Colors.white,
                          ),
                          if (_advanceReceived > 0) ...[
                            const SizedBox(height: 4),
                            _buildSummaryRow(
                              'Advance Paid by Customer:',
                              '-₹${_advanceReceived.toStringAsFixed(0)}',
                              color: DashboardColors.neonGreen,
                            ),
                          ],
                          const Divider(color: Color(0x33FFFFFF), height: 14),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Net Balance to Collect:',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                '₹${_netBalanceDue.toStringAsFixed(0)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                  color: DashboardColors.neonGreen,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // E. PAYMENT MODE
                    Row(
                      children: [
                        const Text(
                          'Payment Mode: ',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ModeSelector(
                            value: _paymentMode,
                            onChanged: (v) => setState(() => _paymentMode = v),
                          ),
                        ),
                      ],
                    ),

                    if (_errorMessage != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.red.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline_rounded,
                                color: Colors.redAccent, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(
                                    color: Colors.redAccent, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 14),
            const Divider(color: Color(0x1AFFFFFF)),
            const SizedBox(height: 8),

            // 3. DIALOG ACTIONS
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel',
                      style: TextStyle(color: DashboardColors.textMuted)),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: DashboardColors.neonGreen,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Icon(Icons.check_circle_rounded, size: 18),
                  label: Text(
                    _isSubmitting
                        ? 'Creating Bill...'
                        : 'Confirm & Create Bill (₹${_netBalanceDue.toStringAsFixed(0)})',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  onPressed: _isSubmitting ? null : _handleConfirmBill,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: DashboardColors.textMuted,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(icon, size: 18, color: DashboardColors.neonBlue),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0x26FFFFFF)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide:
                  const BorderSide(color: DashboardColors.neonBlue, width: 1.5),
            ),
          ),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildSummaryRow(
    String label,
    String value, {
    bool bold = false,
    double fontSize = 12.5,
    Color color = Colors.white70,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.bold : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

