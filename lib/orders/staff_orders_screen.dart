import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../main.dart' show Db, toast;
import '../pos/pos_models.dart';
import 'order_models.dart';
import 'order_service.dart';

class StaffOrdersScreen extends StatefulWidget {
  final String shopId;
  final String staffId;
  final String staffName;

  const StaffOrdersScreen({
    super.key,
    required this.shopId,
    required this.staffId,
    required this.staffName,
  });

  @override
  State<StaffOrdersScreen> createState() => _StaffOrdersScreenState();
}

class _StaffOrdersScreenState extends State<StaffOrdersScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String _selectedCategory = 'All';

  // Current order cart items
  final List<StaffOrderProduct> _cart = [];
  bool _submitting = false;

  final List<String> _categories = [
    'All',
    'Screen / Display',
    'Battery',
    'Charging / Flex',
    'Tempered Glass',
    'Cases / Covers',
    'Chargers & Cables',
    'Earbuds & Audio',
    'Spare Parts',
    'Others',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  int get _totalCartQty => _cart.fold(0, (sum, item) => sum + item.quantity);

  IconData _getCategoryIcon(String cat) {
    final lower = cat.toLowerCase();
    if (lower.contains('screen') || lower.contains('display')) return Icons.phone_android_rounded;
    if (lower.contains('battery')) return Icons.battery_charging_full_rounded;
    if (lower.contains('charge') || lower.contains('flex')) return Icons.power_rounded;
    if (lower.contains('glass') || lower.contains('tempered')) return Icons.shield_rounded;
    if (lower.contains('case') || lower.contains('cover')) return Icons.phone_iphone_rounded;
    if (lower.contains('charger') || lower.contains('cable')) return Icons.cable_rounded;
    if (lower.contains('earbud') || lower.contains('audio')) return Icons.headphones_rounded;
    if (lower.contains('spare') || lower.contains('part')) return Icons.build_rounded;
    if (cat == 'All') return Icons.grid_view_rounded;
    return Icons.inventory_2_rounded;
  }

  Color _getCategoryColor(String cat) {
    final lower = cat.toLowerCase();
    if (lower.contains('screen') || lower.contains('display')) return const Color(0xFF38BDF8); // Sky
    if (lower.contains('battery')) return const Color(0xFF34D399); // Emerald
    if (lower.contains('charge') || lower.contains('flex')) return const Color(0xFFA78BFA); // Purple
    if (lower.contains('glass') || lower.contains('tempered')) return const Color(0xFF2DD4BF); // Teal
    if (lower.contains('case') || lower.contains('cover')) return const Color(0xFFF472B6); // Pink
    if (lower.contains('charger') || lower.contains('cable')) return const Color(0xFFFBBF24); // Amber
    if (lower.contains('earbud') || lower.contains('audio')) return const Color(0xFF818CF8); // Indigo
    if (lower.contains('spare') || lower.contains('part')) return const Color(0xFFFB923C); // Orange
    return const Color(0xFF94A3B8); // Slate
  }

  // Add catalog item to cart or increment quantity
  void _addCatalogItemToCart(PosItem item) {
    HapticFeedback.lightImpact();
    final idx = _cart.indexWhere((p) => !p.isCustom && p.productId == item.id);
    if (idx >= 0) {
      setState(() {
        final cur = _cart[idx];
        _cart[idx] = StaffOrderProduct(
          id: cur.id,
          productId: cur.productId,
          name: cur.name,
          sku: cur.sku,
          category: cur.category,
          model: cur.model,
          variant: cur.variant,
          quantity: cur.quantity + 1,
          unit: cur.unit,
          remarks: cur.remarks,
          isCustom: false,
        );
      });
    } else {
      setState(() {
        _cart.add(StaffOrderProduct(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          productId: item.id,
          name: item.name,
          sku: item.sku,
          category: item.category.isNotEmpty ? item.category : 'Others',
          quantity: 1,
          unit: 'Pcs',
          isCustom: false,
        ));
      });
    }
    toast(context, '${item.name} ഓർഡറിൽ ചേർത്തു (+1)');
  }

  void _updateCartItemQty(int index, int newQty) {
    HapticFeedback.lightImpact();
    if (newQty <= 0) {
      setState(() => _cart.removeAt(index));
    } else {
      setState(() {
        final cur = _cart[index];
        _cart[index] = StaffOrderProduct(
          id: cur.id,
          productId: cur.productId,
          name: cur.name,
          sku: cur.sku,
          category: cur.category,
          model: cur.model,
          variant: cur.variant,
          quantity: newQty,
          unit: cur.unit,
          remarks: cur.remarks,
          isCustom: cur.isCustom,
        );
      });
    }
  }

  // Open dialog to customize item (model, unit, remarks)
  Future<void> _editCartItemDetails(int index) async {
    final item = _cart[index];
    final modelCtrl = TextEditingController(text: item.model);
    final variantCtrl = TextEditingController(text: item.variant);
    final remarksCtrl = TextEditingController(text: item.remarks);
    final unitCtrl = TextEditingController(text: item.unit);

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: modelCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'മോഡൽ (Model, e.g. iPhone 13)',
                  labelStyle: const TextStyle(color: Colors.white70),
                  prefixIcon: const Icon(Icons.phone_android_rounded, color: Color(0xFF38BDF8)),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: variantCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'വേരിയൻ്റ് / കളർ (Variant / Color)',
                  labelStyle: const TextStyle(color: Colors.white70),
                  prefixIcon: const Icon(Icons.palette_outlined, color: Color(0xFF818CF8)),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: unitCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'യൂണിറ്റ് (Unit: Pcs, Box, Set)',
                  labelStyle: const TextStyle(color: Colors.white70),
                  prefixIcon: const Icon(Icons.straighten_rounded, color: Color(0xFF34D399)),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: remarksCtrl,
                maxLines: 2,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'പ്രത്യേക കുറിപ്പ് (Item Remarks)',
                  labelStyle: const TextStyle(color: Colors.white70),
                  prefixIcon: const Icon(Icons.note_alt_outlined, color: Color(0xFFFBBF24)),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('റദ്ദാക്കുക (Cancel)', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              setState(() {
                _cart[index] = StaffOrderProduct(
                  id: item.id,
                  productId: item.productId,
                  name: item.name,
                  sku: item.sku,
                  category: item.category,
                  model: modelCtrl.text.trim(),
                  variant: variantCtrl.text.trim(),
                  quantity: item.quantity,
                  unit: unitCtrl.text.trim().isEmpty ? 'Pcs' : unitCtrl.text.trim(),
                  remarks: remarksCtrl.text.trim(),
                  isCustom: item.isCustom,
                );
              });
              Navigator.pop(ctx);
            },
            child: const Text('സേവ് ചെയ്യുക (Save)'),
          ),
        ],
      ),
    );
  }

  // Dialog to add custom non-catalog item
  Future<void> _showAddCustomProductDialog() async {
    final nameCtrl = TextEditingController();
    final modelCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');
    final unitCtrl = TextEditingController(text: 'Pcs');
    final remarksCtrl = TextEditingController();
    String customCategory = 'Others';

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.add_shopping_cart_rounded, color: Color(0xFF38BDF8)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'കസ്റ്റം പ്രോഡക്റ്റ് ചേർക്കുക (Add Custom Item)',
                  style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'ഉൽപ്പന്നത്തിന്റെ പേര് (Product Name) *',
                    labelStyle: const TextStyle(color: Colors.white70),
                    hintText: 'e.g. Display Combo, Speaker, Back Panel',
                    prefixIcon: const Icon(Icons.shopping_bag_outlined, color: Color(0xFF38BDF8)),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: modelCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'മോഡൽ / ബ്രാൻഡ് (Model / Brand)',
                    labelStyle: const TextStyle(color: Colors.white70),
                    hintText: 'e.g. Samsung M31, Redmi Note 10',
                    prefixIcon: const Icon(Icons.devices_rounded, color: Color(0xFF818CF8)),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: qtyCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          labelText: 'എണ്ണം (Qty) *',
                          labelStyle: const TextStyle(color: Colors.white70),
                          prefixIcon: const Icon(Icons.numbers_rounded, color: Color(0xFF34D399)),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: unitCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'യൂണിറ്റ് (Unit)',
                          labelStyle: const TextStyle(color: Colors.white70),
                          hintText: 'Pcs',
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: customCategory,
                  dropdownColor: const Color(0xFF1E293B),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'വിഭാഗം (Category)',
                    labelStyle: const TextStyle(color: Colors.white70),
                    prefixIcon: const Icon(Icons.category_outlined, color: Color(0xFFFBBF24)),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  items: _categories
                      .where((c) => c != 'All')
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setD(() => customCategory = v);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: remarksCtrl,
                  maxLines: 2,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'കുറിപ്പ് (Remarks / Specifics)',
                    labelStyle: const TextStyle(color: Colors.white70),
                    hintText: 'e.g. Original quality only, Customer waiting',
                    prefixIcon: const Icon(Icons.edit_note_rounded, color: Color(0xFFFB923C)),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('റദ്ദാക്കുക (Cancel)', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                final name = nameCtrl.text.trim();
                final qty = int.tryParse(qtyCtrl.text.trim()) ?? 1;
                if (name.isEmpty) {
                  toast(context, 'ഉൽപ്പന്നത്തിന്റെ പേര് നൽകുക', error: true);
                  return;
                }
                if (qty <= 0) {
                  toast(context, 'സാധുവായ എണ്ണം നൽകുക', error: true);
                  return;
                }

                setState(() {
                  _cart.add(StaffOrderProduct(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: name,
                    category: customCategory,
                    model: modelCtrl.text.trim(),
                    quantity: qty,
                    unit: unitCtrl.text.trim().isEmpty ? 'Pcs' : unitCtrl.text.trim(),
                    remarks: remarksCtrl.text.trim(),
                    isCustom: true,
                  ));
                });
                Navigator.pop(ctx);
                toast(context, '$name ഓർഡറിൽ ചേർത്തു');
              },
              child: const Text('ചേർക്കുക (Add to Order)'),
            ),
          ],
        ),
      ),
    );
  }

  // Quick Barcode Scan Dialog
  Future<void> _openQuickScannerDialog() async {
    final barcodeCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.qr_code_scanner_rounded, size: 40, color: Color(0xFF38BDF8)),
        title: const Text(
          'ബാർകോഡ് സ്കാനർ (Barcode Search)',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'ഉൽപ്പന്നത്തിന്റെ ബാർകോഡ് നൽകുക അല്ലെങ്കിൽ സ്കാൻ ചെയ്യുക:',
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: barcodeCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                hintText: 'ബാർകോഡ് ഇവിടെ നൽകുക (Barcode)...',
                prefixIcon: const Icon(Icons.barcode_reader, color: Color(0xFF38BDF8)),
                filled: true,
                fillColor: const Color(0xFF0F172A),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onSubmitted: (val) {
                if (val.trim().isNotEmpty) {
                  _searchCtrl.text = val.trim();
                  setState(() => _searchQuery = val.trim());
                  Navigator.pop(ctx);
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('റദ്ദാക്കുക', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
            onPressed: () {
              final val = barcodeCtrl.text.trim();
              if (val.isNotEmpty) {
                _searchCtrl.text = val;
                setState(() => _searchQuery = val);
              }
              Navigator.pop(ctx);
            },
            child: const Text('തിരയുക (Search)'),
          ),
        ],
      ),
    );
  }

  // Cart Review Bottom Sheet Modal with Glassmorphic Dark Styling
  void _openCartReviewSheet() {
    final remarksCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final totalTypes = _cart.length;
          final totalQty = _totalCartQty;

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
              top: 16,
              left: 16,
              right: 16,
            ),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.80,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.shopping_cart_checkout_rounded, color: Color(0xFF38BDF8), size: 26),
                          SizedBox(width: 8),
                          Text(
                            'ഓർഡർ അവലോകനം (Review Order)',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white70),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Summary Pill
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Text(
                          'ആകെ ഇനങ്ങൾ: $totalTypes Types',
                          style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white70),
                        ),
                        const Text('•', style: TextStyle(color: Colors.white38)),
                        Text(
                          'ആകെ എണ്ണം: $totalQty Pcs',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF38BDF8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 18, color: Color(0xFF334155)),

                  Expanded(
                    child: _cart.isEmpty
                        ? const Center(
                            child: Text(
                              'ലിസ്റ്റിൽ ഉൽപ്പന്നങ്ങളൊന്നുമില്ല',
                              style: TextStyle(color: Colors.white54),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _cart.length,
                            separatorBuilder: (_, __) => const Divider(height: 8, color: Color(0xFF334155)),
                            itemBuilder: (ctx, i) {
                              final item = _cart[i];
                              return ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: item.isCustom
                                        ? Colors.orange.withValues(alpha: 0.15)
                                        : const Color(0xFF2563EB).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    item.isCustom ? Icons.build_circle_outlined : Icons.inventory_2_outlined,
                                    color: item.isCustom ? Colors.orange : const Color(0xFF38BDF8),
                                    size: 20,
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13.5,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    if (item.isCustom)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: Colors.orange.withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'Custom',
                                          style: TextStyle(fontSize: 10, color: Colors.orange, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                  ],
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 2),
                                    Text(
                                      [
                                        if (item.category.isNotEmpty) item.category,
                                        if (item.model.isNotEmpty) 'Model: ${item.model}',
                                        if (item.remarks.isNotEmpty) 'Note: ${item.remarks}',
                                      ].join(' • '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11.5, color: Colors.white60),
                                    ),
                                    const SizedBox(height: 3),
                                    InkWell(
                                      onTap: () async {
                                        await _editCartItemDetails(i);
                                        setS(() {});
                                      },
                                      child: const Text(
                                        'വിശദാംശങ്ങൾ മാറ്റുക (Edit details)',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF38BDF8),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0F172A),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: const Color(0xFF334155)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                        icon: const Icon(Icons.remove_rounded, size: 18, color: Color(0xFFEF4444)),
                                        onPressed: () {
                                          _updateCartItemQty(i, item.quantity - 1);
                                          setS(() {});
                                        },
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 6),
                                        child: Text(
                                          '${item.quantity}',
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                        icon: const Icon(Icons.add_rounded, size: 18, color: Color(0xFF10B981)),
                                        onPressed: () {
                                          _updateCartItemQty(i, item.quantity + 1);
                                          setS(() {});
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),

                  TextField(
                    controller: remarksCtrl,
                    maxLines: 2,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'പൊതുവായ കുറിപ്പുകൾ (General Remarks / Note)',
                      labelStyle: const TextStyle(color: Colors.white70),
                      hintText: 'e.g. Urgent delivery required for customer repairs',
                      prefixIcon: const Icon(Icons.notes_rounded, color: Color(0xFF38BDF8)),
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 14),

                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: const Color(0xFF2563EB),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                    label: Text(
                      _submitting ? 'ഓർഡർ സമർപ്പിക്കുന്നു...' : 'ഓർഡർ സമർപ്പിക്കുക (Submit Order)',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    onPressed: _submitting || _cart.isEmpty
                        ? null
                        : () async {
                            Navigator.pop(ctx);
                            await _handleOrderSubmission(remarksCtrl.text.trim());
                          },
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // Handle Order Submission with Idempotency guard and post-submission modal
  Future<void> _handleOrderSubmission(String generalRemarks) async {
    if (_cart.isEmpty || _submitting) return;

    setState(() => _submitting = true);

    try {
      final now = DateTime.now();
      final dateStr = DateFormat('yyyy-MM-dd').format(now);
      final timeStr = DateFormat('hh:mm a').format(now);

      // Generate sequential order ID
      final orderId = await OrderService.instance.generateOrderId(widget.shopId);

      // Resolve effective staff ID (prefer current auth UID to guarantee rule matching)
      final authUid = FirebaseAuth.instance.currentUser?.uid;
      final effectiveStaffId = (authUid != null && authUid.isNotEmpty)
          ? authUid
          : (widget.staffId.isNotEmpty ? widget.staffId : Db.setting('staff_logged_id'));

      final order = StaffOrder(
        orderId: orderId,
        shopId: widget.shopId,
        staffId: effectiveStaffId,
        staffName: widget.staffName,
        createdDate: dateStr,
        createdTime: timeStr,
        createdAt: now,
        products: List.from(_cart),
        totalTypes: _cart.length,
        totalQuantity: _totalCartQty,
        generalRemarks: generalRemarks,
        status: StaffOrderStatus.submitted,
        whatsappDeliveryStatus: WhatsAppDeliveryStatus.orderSaved,
      );

      // Save to Cloud Firestore & log staff action
      await OrderService.instance.submitOrder(
        shopId: widget.shopId,
        order: order,
      );

      setState(() {
        _cart.clear();
      });

      if (!mounted) return;

      // Show post-submission WhatsApp Action dialog
      _showPostOrderActionDialog(order);
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            icon: const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 40),
            title: const Text('ഓർഡർ പരാജയപ്പെട്ടു (Order Failed)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            content: Text(e.toString(), style: const TextStyle(color: Colors.white70)),
            actions: [
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // Section 13 Post-Submission Modal
  void _showPostOrderActionDialog(StaffOrder order) {
    final formattedMessage = OrderService.instance.formatWhatsAppMessage(order);
    const groupUrl = 'https://chat.whatsapp.com/GD5fTnnLRk9I0mPXdJ80n0?s=cl&p=a&mlu=4&ilr=4';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 52),
        title: const Text(
          'ഓർഡർ വിജയകരമായി സമർപ്പിച്ചു!',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: Colors.white),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Order ID: ${order.orderId}',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF38BDF8), fontSize: 15),
              ),
              const SizedBox(height: 6),
              Text(
                '${order.totalTypes} Product Types • ${order.totalQuantity} Total Units',
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF25D366).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF25D366).withValues(alpha: 0.35)),
                ),
                child: const Text(
                  'ഈ ഓർഡർ കമ്പനിയുടെ ഔദ്യോഗിക WhatsApp ഗ്രൂപ്പിലേക്ക് അയക്കുക അല്ലെങ്കിൽ മെസ്സേജ് കോപ്പി ചെയ്യുക.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: Colors.white),
                ),
              ),
              const SizedBox(height: 16),
              // Button 1: Open WhatsApp Group
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.send_rounded),
                  label: const Text(
                    'WhatsApp ഗ്രൂപ്പിലേക്ക് അയക്കുക',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onPressed: () async {
                    await OrderService.instance.copyOrderToClipboard(formattedMessage);
                    await OrderService.instance.openWhatsAppGroup(groupUrl);
                    await OrderService.instance.updateWhatsAppStatus(
                      shopId: widget.shopId,
                      orderId: order.orderId,
                      status: WhatsAppDeliveryStatus.sentSuccessfully,
                    );
                    if (ctx.mounted) {
                      toast(ctx, 'ഓർഡർ കോപ്പി ചെയ്തു, ഗ്രൂപ്പിൽ പേസ്റ്റ് ചെയ്യുക');
                    }
                  },
                ),
              ),
              const SizedBox(height: 10),
              // Button 2: Copy Order Text
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: const BorderSide(color: Color(0xFF334155)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.copy_rounded, color: Colors.white70),
                  label: const Text('ഓർഡർ കോപ്പി ചെയ്യുക (Copy Text)', style: TextStyle(color: Colors.white)),
                  onPressed: () async {
                    await OrderService.instance.copyOrderToClipboard(formattedMessage);
                    if (ctx.mounted) {
                      toast(ctx, 'ഓർഡർ വിവരങ്ങൾ ക്ലിപ്ബോർഡിലേക്ക് കോപ്പി ചെയ്തു');
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _tabController.animateTo(1); // Switch to Order History tab
            },
            child: const Text('പൂർത്തിയായി (Done)'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'TekFix Orders (ഓർഡറുകൾ)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: Colors.white),
            ),
            Text(
              'Staff: ${widget.staffName} • ${widget.shopId.toUpperCase()}',
              style: const TextStyle(fontSize: 11.5, color: Colors.white60),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF38BDF8),
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          tabs: const [
            Tab(icon: Icon(Icons.add_shopping_cart_rounded), text: 'New Order (പുതിയത്)'),
            Tab(icon: Icon(Icons.history_rounded), text: 'Order History (ചരിത്രം)'),
          ],
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabController,
            children: [
              _buildNewOrderTab(),
              _buildOrderHistoryTab(),
            ],
          ),

          // Interactive Bottom Floating Cart Bar with Spring Transition
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedSlide(
              offset: (_cart.isNotEmpty && _tabController.index == 0)
                  ? Offset.zero
                  : const Offset(0, 1.5),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: (_cart.isNotEmpty && _tabController.index == 0) ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: _buildFloatingCartBar(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Interactive Bottom Floating Cart Sheet
  Widget _buildFloatingCartBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.6), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1D4ED8).withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          // Glowing Quantity Circle
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
            ),
            child: Text(
              '${_cart.length}',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
            ),
          ),
          const SizedBox(width: 14),

          // Cart Summary Text
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_cart.length} Types • $_totalCartQty Items',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                ),
                const SizedBox(height: 2),
                const Text(
                  'ടാപ്പ് ചെയ്ത് ഓർഡർ അയക്കുക',
                  style: TextStyle(fontSize: 11, color: Color(0xFF38BDF8)),
                ),
              ],
            ),
          ),

          // Vibrant Review & Submit Button
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: 4,
            ),
            icon: const Icon(Icons.shopping_cart_checkout_rounded, size: 18),
            label: const Text(
              'അവലോകനം (Review)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            onPressed: () {
              HapticFeedback.mediumImpact();
              _openCartReviewSheet();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildNewOrderTab() {
    final allItems = <PosItem>[];
    for (final v in Db.items.values) {
      if (v is Map) {
        final m = Map<String, dynamic>.from(v);
        allItems.add(PosItem.fromMap(m['id']?.toString() ?? '', m));
      }
    }

    // Filter items by category & search query
    final filtered = allItems.where((it) {
      final matchesCat =
          _selectedCategory == 'All' || it.category.toLowerCase() == _selectedCategory.toLowerCase();
      final q = _searchQuery.toLowerCase();
      final matchesQuery = q.isEmpty ||
          it.name.toLowerCase().contains(q) ||
          it.sku.toLowerCase().contains(q) ||
          it.barcode.toLowerCase().contains(q);
      return matchesCat && matchesQuery;
    }).toList();

    return Column(
      children: [
        // Top Search and Add Custom Button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    onChanged: (val) => setState(() => _searchQuery = val.trim()),
                    decoration: InputDecoration(
                      hintText: 'തിരയുക (Search products, SKU)...',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded, color: Colors.white60),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_searchQuery.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.clear_rounded, color: Colors.white60, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _searchQuery = '');
                              },
                            ),
                          IconButton(
                            tooltip: 'Barcode Scanner',
                            icon: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF38BDF8), size: 20),
                            onPressed: () {
                              HapticFeedback.lightImpact();
                              _openQuickScannerDialog();
                            },
                          ),
                        ],
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // + Custom Item Button
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  _showAddCustomProductDialog();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFF59E0B), Color(0xFFEA580C)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.add_circle_outline_rounded, size: 18, color: Colors.white),
                      SizedBox(width: 6),
                      Text(
                        '+ Custom',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // Horizontal Category Filter Pills with Matching Icons
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (ctx, i) {
              final cat = _categories[i];
              final isSel = _selectedCategory == cat;
              final icon = _getCategoryIcon(cat);
              final color = _getCategoryColor(cat);

              return GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _selectedCategory = cat);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: isSel
                        ? const LinearGradient(
                            colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    color: isSel ? null : const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSel ? const Color(0xFF3B82F6) : const Color(0xFF334155),
                    ),
                    boxShadow: isSel
                        ? [
                            BoxShadow(
                              color: const Color(0xFF2563EB).withValues(alpha: 0.35),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 16, color: isSel ? Colors.white : color),
                      const SizedBox(width: 6),
                      Text(
                        cat,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
                          color: isSel ? Colors.white : Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 8),

        // Dynamic Stock Cards List
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.inventory_2_outlined, size: 52, color: Colors.white24),
                      const SizedBox(height: 12),
                      const Text(
                        'ഉൽപ്പന്നങ്ങളൊന്നും കണ്ടെത്തിയില്ല\n(No catalog products found)',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('+ കസ്റ്റം ഉൽപ്പന്നം ചേർക്കുക'),
                        onPressed: _showAddCustomProductDialog,
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(16, 6, 16, _cart.isNotEmpty ? 90 : 20),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (ctx, i) {
                    final item = filtered[i];
                    final cartIdx = _cart.indexWhere((c) => !c.isCustom && c.productId == item.id);
                    final cartQty = cartIdx >= 0 ? _cart[cartIdx].quantity : 0;
                    final catColor = _getCategoryColor(item.category);
                    final catIcon = _getCategoryIcon(item.category);

                    // Stock health styling
                    final bool inStock = item.stock > 10;
                    final bool lowStock = item.stock > 0 && item.stock <= 10;
                    final healthColor = inStock
                        ? const Color(0xFF10B981)
                        : (lowStock ? const Color(0xFFF59E0B) : const Color(0xFFEF4444));
                    final healthText = inStock
                        ? 'In Stock (${item.stock})'
                        : (lowStock ? 'Low Stock (${item.stock} left)' : 'Out of Stock');

                    return Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: cartQty > 0
                              ? const Color(0xFF3B82F6)
                              : const Color(0xFF334155),
                          width: cartQty > 0 ? 1.5 : 1.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: cartQty > 0
                                ? const Color(0xFF2563EB).withValues(alpha: 0.15)
                                : Colors.black.withValues(alpha: 0.2),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            // Category-specific colored icon badge
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: catColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: catColor.withValues(alpha: 0.3)),
                              ),
                              child: Icon(catIcon, color: catColor, size: 22),
                            ),
                            const SizedBox(width: 12),

                            // Item details
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14.5,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    [
                                      if (item.category.isNotEmpty) item.category,
                                      if (item.sku.isNotEmpty) 'SKU: ${item.sku}',
                                    ].join(' • '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11.5, color: Colors.white60),
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      // Price Tag
                                      if (item.sellingPrice > 0) ...[
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            '₹${item.sellingPrice.toStringAsFixed(0)}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xFF38BDF8),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                      ],

                                      // Stock Health Badge Pill
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: healthColor.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: healthColor.withValues(alpha: 0.4)),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Container(
                                              width: 6,
                                              height: 6,
                                              decoration: BoxDecoration(
                                                color: healthColor,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              healthText,
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.bold,
                                                color: healthColor,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(width: 8),

                            // Animated Incremental Counter / Add Button
                            if (cartQty > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0F172A),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFF3B82F6)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                      icon: const Icon(Icons.remove_rounded, color: Color(0xFFEF4444), size: 18),
                                      onPressed: () {
                                        _updateCartItemQty(cartIdx, cartQty - 1);
                                      },
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6),
                                      child: Text(
                                        '$cartQty',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                      icon: const Icon(Icons.add_rounded, color: Color(0xFF10B981), size: 18),
                                      onPressed: () {
                                        _updateCartItemQty(cartIdx, cartQty + 1);
                                      },
                                    ),
                                  ],
                                ),
                              )
                            else
                              GestureDetector(
                                onTap: () => _addCatalogItemToCart(item),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF2563EB).withValues(alpha: 0.3),
                                        blurRadius: 8,
                                        offset: const Offset(0, 3),
                                      ),
                                    ],
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.add_rounded, color: Colors.white, size: 18),
                                      SizedBox(width: 4),
                                      Text(
                                        '+ Add',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12.5,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildOrderHistoryTab() {
    final authUid = FirebaseAuth.instance.currentUser?.uid;
    final effectiveStaffId = (authUid != null && authUid.isNotEmpty)
        ? authUid
        : (widget.staffId.isNotEmpty ? widget.staffId : Db.setting('staff_logged_id'));

    return StreamBuilder<List<StaffOrder>>(
      stream: OrderService.instance.streamStaffOrders(widget.shopId, effectiveStaffId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: Color(0xFF38BDF8)));
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    'ഓർഡറുകൾ ലോഡ് ചെയ്യുന്നതിൽ പിശക്: ${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ],
              ),
            ),
          );
        }

        final orders = snapshot.data ?? [];
        if (orders.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.shopping_bag_outlined, size: 54, color: Colors.white24),
                const SizedBox(height: 12),
                const Text(
                  'നിങ്ങൾ ഇതുവരെ ഓർഡറുകളൊന്നും സമർപ്പിച്ചിട്ടില്ല\n(No orders submitted yet)',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('പുതിയ ഓർഡർ ഉണ്ടാക്കുക (Create Order)'),
                  onPressed: () => _tabController.animateTo(0),
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: orders.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (ctx, i) {
            final o = orders[i];
            return Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF334155)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Theme(
                data: Theme.of(ctx).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: o.status.color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.receipt_long_rounded, color: o.status.color, size: 22),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          o.orderId,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5, color: Colors.white),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: o.status.color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: o.status.color.withValues(alpha: 0.4)),
                        ),
                        child: Text(
                          '${o.status.label} (${o.status.labelMl})',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: o.status.color,
                          ),
                        ),
                      ),
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.access_time_rounded, size: 13, color: Colors.white54),
                        const SizedBox(width: 4),
                        Text(
                          '${o.createdDate} • ${o.createdTime}',
                          style: const TextStyle(fontSize: 11.5, color: Colors.white60),
                        ),
                        const Spacer(),
                        Text(
                          '${o.totalTypes} Types (${o.totalQuantity} Units)',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8)),
                        ),
                      ],
                    ),
                  ),
                  children: [
                    const Divider(height: 1, color: Color(0xFF334155)),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'ഓർഡർ ചെയ്ത ഉൽപ്പന്നങ്ങൾ (Ordered Products):',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                          ),
                          const SizedBox(height: 8),
                          ...o.products.map(
                            (p) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('• ', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF38BDF8))),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          p.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                            color: Colors.white,
                                          ),
                                        ),
                                        if (p.model.isNotEmpty || p.remarks.isNotEmpty)
                                          Text(
                                            [
                                              if (p.model.isNotEmpty) 'Model: ${p.model}',
                                              if (p.remarks.isNotEmpty) 'Note: ${p.remarks}',
                                            ].join(' • '),
                                            style: const TextStyle(fontSize: 11.5, color: Colors.white60),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    '${p.quantity} ${p.unit}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: Color(0xFF38BDF8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (o.generalRemarks.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F172A),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFF334155)),
                              ),
                              child: Text(
                                'Remarks: ${o.generalRemarks}',
                                style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.white70),
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(color: Color(0xFF334155)),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  icon: const Icon(Icons.copy_rounded, size: 16, color: Colors.white70),
                                  label: const Text('Copy Text', style: TextStyle(fontSize: 12, color: Colors.white)),
                                  onPressed: () async {
                                    final msg = OrderService.instance.formatWhatsAppMessage(o);
                                    await OrderService.instance.copyOrderToClipboard(msg);
                                    if (ctx.mounted) {
                                      toast(ctx, 'ഓർഡർ മെസ്സേജ് കോപ്പി ചെയ്തു');
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF25D366),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  icon: const Icon(Icons.send_rounded, size: 16),
                                  label: const Text('WhatsApp', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                  onPressed: () async {
                                    final msg = OrderService.instance.formatWhatsAppMessage(o);
                                    await OrderService.instance.copyOrderToClipboard(msg);
                                    await OrderService.instance.openWhatsAppGroup(
                                      'https://chat.whatsapp.com/GD5fTnnLRk9I0mPXdJ80n0?s=cl&p=a&mlu=4&ilr=4',
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Reorder / Duplicate to Cart',
                                style: IconButton.styleFrom(
                                  backgroundColor: const Color(0xFF0F172A),
                                  side: const BorderSide(color: Color(0xFF334155)),
                                ),
                                icon: const Icon(Icons.replay_rounded, size: 18, color: Color(0xFF38BDF8)),
                                onPressed: () {
                                  setState(() {
                                    _cart.clear();
                                    _cart.addAll(o.products);
                                  });
                                  _tabController.animateTo(0);
                                  toast(context, 'ഉൽപ്പന്നങ്ങൾ കാർട്ടിലേക്ക് ചേർത്തു');
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
