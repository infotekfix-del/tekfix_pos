import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../main.dart' show Db, kPrimary, toast;
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
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  int get _totalCartQty => _cart.fold(0, (sum, item) => sum + item.quantity);

  // Add catalog item to cart or increment quantity
  void _addCatalogItemToCart(PosItem item) {
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
    toast(context, '${item.name} ഓർഡർ ലിസ്റ്റിൽ ചേർത്തു');
  }

  void _updateCartItemQty(int index, int newQty) {
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
        title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: modelCtrl,
                decoration: const InputDecoration(
                  labelText: 'മോഡൽ (Model, e.g. iPhone 13)',
                  prefixIcon: Icon(Icons.phone_android_rounded),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: variantCtrl,
                decoration: const InputDecoration(
                  labelText: 'വേരിയൻ്റ് / കളർ (Variant / Color)',
                  prefixIcon: Icon(Icons.palette_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: unitCtrl,
                decoration: const InputDecoration(
                  labelText: 'യൂണിറ്റ് (Unit: Pcs, Box, Set)',
                  prefixIcon: Icon(Icons.straighten_rounded),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: remarksCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'പ്രത്യേക കുറിപ്പ് (Item Remarks)',
                  prefixIcon: Icon(Icons.note_alt_outlined),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('റദ്ദാക്കുക (Cancel)'),
          ),
          FilledButton(
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
          title: const Row(
            children: [
              Icon(Icons.add_shopping_cart_rounded, color: kPrimary),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'കസ്റ്റം പ്രോഡക്റ്റ് ചേർക്കുക (Add Custom Item)',
                  style: TextStyle(fontSize: 16),
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
                  decoration: const InputDecoration(
                    labelText: 'ഉൽപ്പന്നത്തിന്റെ പേര് (Product Name) *',
                    hintText: 'e.g. Display Combo, Speaker, Back Panel',
                    prefixIcon: Icon(Icons.shopping_bag_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: modelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'മോഡൽ / ബ്രാൻഡ് (Model / Brand)',
                    hintText: 'e.g. Samsung M31, Redmi Note 10',
                    prefixIcon: Icon(Icons.devices_rounded),
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
                        decoration: const InputDecoration(
                          labelText: 'എണ്ണം (Qty) *',
                          prefixIcon: Icon(Icons.numbers_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: unitCtrl,
                        decoration: const InputDecoration(
                          labelText: 'യൂണിറ്റ് (Unit)',
                          hintText: 'Pcs',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: customCategory,
                  decoration: const InputDecoration(
                    labelText: 'വിഭാഗം (Category)',
                    prefixIcon: Icon(Icons.category_outlined),
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
                  decoration: const InputDecoration(
                    labelText: 'കുറിപ്പ് (Remarks / Specifics)',
                    hintText: 'e.g. Original quality only, Customer waiting',
                    prefixIcon: Icon(Icons.edit_note_rounded),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('റദ്ദാക്കുക (Cancel)'),
            ),
            FilledButton(
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

  // Cart Review Bottom Sheet Modal
  void _openCartReviewSheet() {
    final remarksCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
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
              height: MediaQuery.of(ctx).size.height * 0.78,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.shopping_cart_checkout_rounded,
                              color: kPrimary, size: 26),
                          const SizedBox(width: 8),
                          Text(
                            'ഓർഡർ അവലോകനം (Review Order)',
                            style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: kPrimary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Text('ആകെ ഇനങ്ങൾ: $totalTypes Types',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        const Text('•', style: TextStyle(color: Colors.grey)),
                        Text('ആകെ എണ്ണം: $totalQty Pcs',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, color: kPrimary)),
                      ],
                    ),
                  ),
                  const Divider(height: 18),
                  Expanded(
                    child: _cart.isEmpty
                        ? const Center(
                            child: Text('ലിസ്റ്റിൽ ഉൽപ്പന്നങ്ങളൊന്നുമില്ല'),
                          )
                        : ListView.separated(
                            itemCount: _cart.length,
                            separatorBuilder: (_, __) => const Divider(height: 8),
                            itemBuilder: (ctx, i) {
                              final item = _cart[i];
                              return ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: CircleAvatar(
                                  backgroundColor: item.isCustom
                                      ? Colors.orange.shade100
                                      : kPrimary.withValues(alpha: 0.12),
                                  child: Icon(
                                    item.isCustom
                                        ? Icons.build_circle_outlined
                                        : Icons.inventory_2_outlined,
                                    color: item.isCustom ? Colors.orange.shade800 : kPrimary,
                                    size: 20,
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.name,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold, fontSize: 13.5),
                                      ),
                                    ),
                                    if (item.isCustom)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.orange.shade50,
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(color: Colors.orange.shade300),
                                        ),
                                        child: const Text('Custom',
                                            style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.orange)),
                                      ),
                                  ],
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (item.model.isNotEmpty || item.variant.isNotEmpty)
                                      Text(
                                        [
                                          if (item.model.isNotEmpty) item.model,
                                          if (item.variant.isNotEmpty) item.variant
                                        ].join(' | '),
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    if (item.remarks.isNotEmpty)
                                      Text(
                                        'Note: ${item.remarks}',
                                        style: TextStyle(
                                            fontSize: 11.5,
                                            fontStyle: FontStyle.italic,
                                            color: Colors.grey.shade700),
                                      ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        InkWell(
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            _editCartItemDetails(i);
                                          },
                                          child: const Text(
                                            'വിശദാംശങ്ങൾ മാറ്റുക (Edit details)',
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: kPrimary,
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.remove_circle_outline,
                                          size: 22, color: Colors.red),
                                      onPressed: () {
                                        _updateCartItemQty(i, item.quantity - 1);
                                        setS(() {});
                                      },
                                    ),
                                    Text(
                                      '${item.quantity}',
                                      style: const TextStyle(
                                          fontSize: 14, fontWeight: FontWeight.bold),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.add_circle_outline,
                                          size: 22, color: Colors.green),
                                      onPressed: () {
                                        _updateCartItemQty(i, item.quantity + 1);
                                        setS(() {});
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: remarksCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'പൊതുവായ കുറിപ്പുകൾ (General Remarks / Note)',
                      hintText: 'e.g. Urgent delivery required for customer repairs',
                      prefixIcon: Icon(Icons.notes_rounded),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: kPrimary,
                    ),
                    icon: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                    label: Text(
                      _submitting
                          ? 'ഓർഡർ സമർപ്പിക്കുന്നു...'
                          : 'ഓർഡർ സമർപ്പിക്കുക (Submit Order)',
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
            icon: const Icon(Icons.error_outline_rounded, color: Colors.red, size: 40),
            title: const Text('ഓർഡർ പരാജയപ്പെട്ടു (Order Failed)'),
            content: Text(e.toString()),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
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
        icon: const Icon(Icons.check_circle_rounded, color: Colors.green, size: 52),
        title: const Text(
          'ഓർഡർ വിജയകരമായി സമർപ്പിച്ചു!',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Order ID: ${order.orderId}',
                style: const TextStyle(fontWeight: FontWeight.bold, color: kPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                '${order.totalTypes} Product Types • ${order.totalQuantity} Total Units',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF25D366).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF25D366).withValues(alpha: 0.3)),
                ),
                child: const Text(
                  'ഈ ഓർഡർ കമ്പനിയുടെ ഔദ്യോഗിക WhatsApp ഗ്രൂപ്പിലേക്ക് അയക്കുക അല്ലെങ്കിൽ മെസ്സേജ് കോപ്പി ചെയ്യുക.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5),
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
                  ),
                  icon: const Icon(Icons.send_rounded),
                  label: const Text(
                    'WhatsApp ഗ്രൂപ്പിലേക്ക് അയക്കുക',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onPressed: () async {
                    // Copy to clipboard first for seamless pasting in group
                    await OrderService.instance.copyOrderToClipboard(formattedMessage);
                    // Launch WhatsApp group
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
                  ),
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('ഓർഡർ കോപ്പി ചെയ്യുക (Copy Text)'),
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
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'TekFix Orders (ഓർഡറുകൾ)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16.5),
            ),
            Text(
              'Staff: ${widget.staffName}',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(icon: Icon(Icons.add_shopping_cart_rounded), text: 'New Order (പുതിയത്)'),
            Tab(icon: Icon(Icons.history_rounded), text: 'Order History (ചരിത്രം)'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildNewOrderTab(),
          _buildOrderHistoryTab(),
        ],
      ),
      bottomNavigationBar: _cart.isNotEmpty && _tabController.index == 0
          ? _buildCartSummaryBottomBar()
          : null,
    );
  }

  Widget _buildCartSummaryBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: kPrimary,
              foregroundColor: Colors.white,
              child: Text('${_cart.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_cart.length} Types • $_totalCartQty Total Items',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const Text('ടാപ്പ് ചെയ്ത് ഓർഡർ അയക്കുക',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: kPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              icon: const Icon(Icons.shopping_cart_checkout_rounded, size: 18),
              label: const Text('അവലോകനം (Review)'),
              onPressed: _openCartReviewSheet,
            ),
          ],
        ),
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
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                  decoration: InputDecoration(
                    hintText: 'ഉൽപ്പന്നങ്ങൾ തിരയുക (Search product)...',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('കസ്റ്റം (+ Custom)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                onPressed: _showAddCustomProductDialog,
              ),
            ],
          ),
        ),

        // Category Pills
        SizedBox(
          height: 38,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (ctx, i) {
              final cat = _categories[i];
              final isSel = _selectedCategory == cat;
              return ChoiceChip(
                label: Text(cat, style: TextStyle(fontSize: 12, color: isSel ? Colors.white : null)),
                selected: isSel,
                selectedColor: kPrimary,
                onSelected: (val) {
                  if (val) setState(() => _selectedCategory = cat);
                },
              );
            },
          ),
        ),

        const SizedBox(height: 8),

        // Product Catalog List
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.inventory_2_outlined, size: 48, color: Colors.grey.shade400),
                      const SizedBox(height: 12),
                      const Text(
                        'ഉൽപ്പന്നങ്ങളൊന്നും കണ്ടെത്തിയില്ല\n(No catalog products found)',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('+ കസ്റ്റം ഉൽപ്പന്നം ചേർക്കുക'),
                        onPressed: _showAddCustomProductDialog,
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 6),
                  itemBuilder: (ctx, i) {
                    final item = filtered[i];
                    final cartIdx =
                        _cart.indexWhere((c) => !c.isCustom && c.productId == item.id);
                    final cartQty = cartIdx >= 0 ? _cart[cartIdx].quantity : 0;

                    return Card(
                      elevation: cartQty > 0 ? 2 : 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: cartQty > 0 ? kPrimary : Colors.grey.shade300,
                          width: cartQty > 0 ? 1.5 : 0.8,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: item.stock <= 0
                                  ? Colors.red.shade50
                                  : kPrimary.withValues(alpha: 0.08),
                              child: Icon(
                                Icons.inventory_2_outlined,
                                color: item.stock <= 0 ? Colors.red : kPrimary,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      Text(
                                        item.category,
                                        style: TextStyle(
                                            fontSize: 11.5, color: Colors.grey.shade600),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: item.stock <= 0
                                              ? Colors.red.shade100
                                              : Colors.grey.shade200,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          'Stock: ${item.stock}',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.bold,
                                            color: item.stock <= 0
                                                ? Colors.red.shade900
                                                : Colors.black87,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            if (cartQty > 0)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.remove_circle_outline,
                                        color: Colors.red, size: 22),
                                    onPressed: () {
                                      _updateCartItemQty(cartIdx, cartQty - 1);
                                    },
                                  ),
                                  Text(
                                    '$cartQty',
                                    style: const TextStyle(
                                        fontSize: 14, fontWeight: FontWeight.bold),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.add_circle_outline,
                                        color: Colors.green, size: 22),
                                    onPressed: () {
                                      _updateCartItemQty(cartIdx, cartQty + 1);
                                    },
                                  ),
                                ],
                              )
                            else
                              IconButton.filledTonal(
                                icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
                                onPressed: () => _addCatalogItemToCart(item),
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
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded, color: Colors.red, size: 48),
                  const SizedBox(height: 12),
                  Text('ഓർഡറുകൾ ലോഡ് ചെയ്യുന്നതിൽ പിശക്: ${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.red)),
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
                Icon(Icons.shopping_bag_outlined, size: 54, color: Colors.grey.shade400),
                const SizedBox(height: 12),
                const Text(
                  'നിങ്ങൾ ഇതുവരെ ഓർഡറുകളൊന്നും സമർപ്പിച്ചിട്ടില്ല\n(No orders submitted yet)',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('പുതിയ ഓർഡർ ഉണ്ടാക്കുക (Create Order)'),
                  onPressed: () => _tabController.animateTo(0),
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: orders.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (ctx, i) {
            final o = orders[i];
            return Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                leading: CircleAvatar(
                  backgroundColor: o.status.color.withValues(alpha: 0.15),
                  child: Icon(Icons.receipt_long_rounded, color: o.status.color),
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        o.orderId,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: o.status.color.withValues(alpha: 0.12),
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
                      Icon(Icons.access_time_rounded, size: 13, color: Colors.grey.shade600),
                      const SizedBox(width: 4),
                      Text(
                        '${o.createdDate} • ${o.createdTime}',
                        style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                      ),
                      const Spacer(),
                      Text(
                        '${o.totalTypes} Types (${o.totalQuantity} Units)',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                children: [
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'ഓർഡർ ചെയ്ത ഉൽപ്പന്നങ്ങൾ (Ordered Products):',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        ...o.products.map(
                          (p) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('• ', style: TextStyle(fontWeight: FontWeight.bold)),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p.name,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600, fontSize: 13),
                                      ),
                                      if (p.model.isNotEmpty || p.remarks.isNotEmpty)
                                        Text(
                                          [
                                            if (p.model.isNotEmpty) 'Model: ${p.model}',
                                            if (p.remarks.isNotEmpty) 'Note: ${p.remarks}',
                                          ].join(' • '),
                                          style: TextStyle(
                                              fontSize: 11.5, color: Colors.grey.shade700),
                                        ),
                                    ],
                                  ),
                                ),
                                Text(
                                  '${p.quantity} ${p.unit}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (o.generalRemarks.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Remarks: ${o.generalRemarks}',
                              style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.copy_rounded, size: 16),
                                label: const Text('Copy Text', style: TextStyle(fontSize: 12)),
                                onPressed: () async {
                                  final msg =
                                      OrderService.instance.formatWhatsAppMessage(o);
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
                                ),
                                icon: const Icon(Icons.send_rounded, size: 16),
                                label: const Text('WhatsApp', style: TextStyle(fontSize: 12)),
                                onPressed: () async {
                                  final msg =
                                      OrderService.instance.formatWhatsAppMessage(o);
                                  await OrderService.instance.copyOrderToClipboard(msg);
                                  await OrderService.instance.openWhatsAppGroup(
                                    'https://chat.whatsapp.com/GD5fTnnLRk9I0mPXdJ80n0?s=cl&p=a&mlu=4&ilr=4',
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filledTonal(
                              tooltip: 'Reorder / Duplicate to Cart',
                              icon: const Icon(Icons.replay_rounded, size: 18),
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
            );
          },
        );
      },
    );
  }
}
