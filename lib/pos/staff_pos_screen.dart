import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../attendance/attendance_models.dart';
import '../attendance/attendance_service.dart';
import '../main.dart' show Db, kPrimary, toast;
import '../shared/tek_pos_strings.dart';
import 'pos_models.dart';
import 'pos_service.dart';

class StaffPosScreen extends StatefulWidget {
  final String shopId;
  final String staffId;
  final String staffName;
  final VoidCallback onNavigateToAttendance;

  const StaffPosScreen({
    super.key,
    required this.shopId,
    required this.staffId,
    required this.staffName,
    required this.onNavigateToAttendance,
  });

  @override
  State<StaffPosScreen> createState() => _StaffPosScreenState();
}

class _StaffPosScreenState extends State<StaffPosScreen> {
  final _searchCtrl = TextEditingController();
  final _custNameCtrl = TextEditingController();
  final _custPhoneCtrl = TextEditingController();
  final _cashReceivedCtrl = TextEditingController();
  final _splitCashCtrl = TextEditingController();
  final _splitUpiCtrl = TextEditingController();

  String _searchQuery = '';
  String _selectedCategory = 'All';
  final List<PosCartItem> _cart = [];
  bool _submitting = false;

  final List<String> _categories = [
    'All',
    'Tempered Glass',
    'Cases',
    'Chargers',
    'Cables',
    'Earbuds',
    'Others',
  ];

  @override
  void dispose() {
    _searchCtrl.dispose();
    _custNameCtrl.dispose();
    _custPhoneCtrl.dispose();
    _cashReceivedCtrl.dispose();
    _splitCashCtrl.dispose();
    _splitUpiCtrl.dispose();
    super.dispose();
  }

  double get _subtotal => _cart.fold(0.0, (sum, i) => sum + i.lineTotal);
  double get _discount => 0.0;
  double get _total => _subtotal - _discount;

  void _addToCart(PosItem item) {
    if (item.isOutOfStock) {
      toast(context, 'സ്റ്റോക്കില്ല (Out of stock)', error: true);
      return;
    }
    final existingIdx = _cart.indexWhere((c) => c.item.id == item.id);
    if (existingIdx >= 0) {
      final current = _cart[existingIdx];
      if (current.qty >= item.stock) {
        toast(context, 'പരമാവധി ലഭ്യമായ സ്റ്റോക്ക്: ${item.stock}', error: true);
        return;
      }
      setState(() => current.qty++);
    } else {
      setState(() {
        _cart.add(PosCartItem(
          item: item,
          qty: 1,
          unitPrice: item.sellingPrice,
        ));
      });
    }
  }

  void _updateCartQty(PosCartItem cartItem, int newQty) {
    if (newQty <= 0) {
      setState(() => _cart.remove(cartItem));
    } else if (newQty > cartItem.item.stock) {
      toast(context, 'പരമാവധി ലഭ്യമായ സ്റ്റോക്ക്: ${cartItem.item.stock}', error: true);
    } else {
      setState(() => cartItem.qty = newQty);
    }
  }

  Future<void> _editItemPrice(PosCartItem cartItem) async {
    final priceCtrl = TextEditingController(text: cartItem.unitPrice.toStringAsFixed(0));
    String? err;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('${cartItem.item.name} - വില തിരുത്തുക'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('MRP: ₹${cartItem.item.sellingPrice.toStringAsFixed(0)} | Min Floor: ₹${cartItem.item.minPrice.toStringAsFixed(0)}'),
              const SizedBox(height: 12),
              TextField(
                controller: priceCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'പുതിയ യൂണിറ്റ് വില (Unit Price)',
                  prefixText: '₹ ',
                  errorText: err,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('റദ്ദാക്കുക')),
            FilledButton(
              onPressed: () async {
                final newPrice = double.tryParse(priceCtrl.text) ?? cartItem.unitPrice;
                if (newPrice < cartItem.item.minPrice) {
                  // Below Floor Price!
                  set(() => err = TekStrings.errPriceBelowFloor.replaceAll('{min}', cartItem.item.minPrice.toStringAsFixed(0)));

                  // Offer Owner Approval / PIN dialog
                  final approved = await _requestOwnerPinApproval(cartItem.item, newPrice);
                  if (approved != null) {
                    setState(() {
                      cartItem.unitPrice = newPrice;
                      cartItem.approvalId = approved;
                    });
                    if (ctx.mounted) Navigator.pop(ctx);
                  }
                  return;
                }

                setState(() {
                  cartItem.unitPrice = newPrice;
                  cartItem.approvalId = null; // Reset override if above floor
                });
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('സേവ് ചെയ്യുക'),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _requestOwnerPinApproval(PosItem item, double requestedPrice) async {
    final pinCtrl = TextEditingController();
    String? pinErr;

    return showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          icon: const Icon(Icons.lock_person_rounded, size: 40, color: Colors.orange),
          title: const Text(TekStrings.pinApprovalTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${item.name}\nMRP: ₹${item.sellingPrice.toStringAsFixed(0)} ➔ ₹${requestedPrice.toStringAsFixed(0)} (Floor: ₹${item.minPrice.toStringAsFixed(0)})',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                TekStrings.pinApprovalSub,
                style: TextStyle(fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pinCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Owner PIN',
                  prefixIcon: const Icon(Icons.key_rounded),
                  errorText: pinErr,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('വേണ്ട (Cancel)')),
            FilledButton(
              onPressed: () async {
                final res = await PosService.instance.verifyOwnerPinAndApprove(
                  shopId: widget.shopId,
                  enteredPin: pinCtrl.text,
                  item: item,
                  requestedPrice: requestedPrice,
                  staffId: widget.staffId,
                  staffName: widget.staffName,
                );

                if (!res.success) {
                  set(() => pinErr = res.error);
                } else {
                  if (ctx.mounted) Navigator.pop(ctx, res.approvalId);
                }
              },
              child: const Text('അംഗീകരിക്കുക (Approve)'),
            ),
          ],
        ),
      ),
    );
  }

  void _openCheckoutSheet() {
    if (_cart.isEmpty) {
      toast(context, TekStrings.emptyCart, error: true);
      return;
    }

    String paymentMode = 'Cash';
    _cashReceivedCtrl.text = _total.toStringAsFixed(0);
    _splitCashCtrl.text = (_total / 2).toStringAsFixed(0);
    _splitUpiCtrl.text = (_total / 2).toStringAsFixed(0);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final double cashReceived = double.tryParse(_cashReceivedCtrl.text) ?? _total;
          final double changeDue = cashReceived >= _total ? cashReceived - _total : 0.0;
          final upiUri = PosService.instance.generateUpiPaymentUri(
            amount: _total,
            invoiceId: 'PREVIEW',
          );

          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'ചെക്ക്ഔട്ട് (Checkout)',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '₹${_total.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF16A34A),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),

                  // Customer details (Optional)
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _custNameCtrl,
                          decoration: const InputDecoration(
                            labelText: TekStrings.customerName,
                            prefixIcon: Icon(Icons.person_outline, size: 18),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _custPhoneCtrl,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            labelText: TekStrings.customerPhone,
                            prefixIcon: Icon(Icons.phone_outlined, size: 18),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Payment mode selector
                  const Text(
                    TekStrings.paymentMode,
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'Cash', label: Text('Cash')),
                      ButtonSegment(value: 'UPI', label: Text('UPI / QR')),
                      ButtonSegment(value: 'Card', label: Text('Card')),
                      ButtonSegment(value: 'Split', label: Text('Split')),
                    ],
                    selected: {paymentMode},
                    onSelectionChanged: (val) => setSheet(() => paymentMode = val.first),
                  ),
                  const SizedBox(height: 16),

                  // Mode details
                  if (paymentMode == 'Cash') ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _cashReceivedCtrl,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setSheet(() {}),
                            decoration: const InputDecoration(
                              labelText: TekStrings.cashReceived,
                              prefixText: '₹ ',
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.green.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  TekStrings.changeDue,
                                  style: TextStyle(fontSize: 11, color: Colors.green),
                                ),
                                Text(
                                  '₹${changeDue.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ] else if (paymentMode == 'UPI') ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: Column(
                        children: [
                          const Text(
                            TekStrings.upiScanPrompt,
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          const SizedBox(height: 10),
                          QrImageView(
                            data: upiUri,
                            version: QrVersions.auto,
                            size: 160.0,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Amount: ₹${_total.toStringAsFixed(2)}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ] else if (paymentMode == 'Split') ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _splitCashCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'Cash Amount', prefixText: '₹ '),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _splitUpiCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: 'UPI Amount', prefixText: '₹ '),
                          ),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 24),

                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: const Color(0xFF16A34A),
                    ),
                    onPressed: _submitting
                        ? null
                        : () async {
                            setSheet(() => _submitting = true);
                            try {
                              double cashAmt = 0.0;
                              double upiAmt = 0.0;
                              double cardAmt = 0.0;

                              if (paymentMode == 'Cash') {
                                cashAmt = _total;
                              } else if (paymentMode == 'UPI') {
                                upiAmt = _total;
                              } else if (paymentMode == 'Card') {
                                cardAmt = _total;
                              } else if (paymentMode == 'Split') {
                                cashAmt = double.tryParse(_splitCashCtrl.text) ?? 0.0;
                                upiAmt = double.tryParse(_splitUpiCtrl.text) ?? 0.0;
                              }

                              final pmt = PosPayment(
                                mode: paymentMode,
                                totalAmount: _total,
                                cashAmount: cashAmt,
                                upiAmount: upiAmt,
                                cardAmount: cardAmt,
                                cashReceived: cashReceived,
                                changeDue: changeDue,
                              );

                              final invoice = await PosService.instance.completeSale(
                                shopId: widget.shopId,
                                staffId: widget.staffId,
                                staffName: widget.staffName,
                                cartItems: List.from(_cart),
                                payment: pmt,
                                subtotal: _subtotal,
                                discount: _discount,
                                total: _total,
                                customerName: _custNameCtrl.text,
                                customerPhone: _custPhoneCtrl.text,
                              );

                              if (ctx.mounted) Navigator.pop(ctx);

                              setState(() {
                                _cart.clear();
                                _custNameCtrl.clear();
                                _custPhoneCtrl.clear();
                              });

                              if (mounted) _showSaleSuccessDialog(invoice);
                            } catch (e) {
                              if (mounted) toast(context, 'വിൽപ്പന പരാജയപ്പെട്ടു: $e', error: true);
                            } finally {
                              setSheet(() => _submitting = false);
                            }
                          },
                    icon: _submitting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check_circle_rounded),
                    label: Text(
                      _submitting ? 'പ്രോസസ്സ് ചെയ്യുന്നു...' : TekStrings.btnCompleteSale,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showSaleSuccessDialog(PosInvoice invoice) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle_rounded, color: Color(0xFF16A34A), size: 48),
        title: const Text(TekStrings.saleSuccessTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${TekStrings.invoiceNo}: #${invoice.invoiceId}', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('${TekStrings.grandTotal}: ₹${invoice.total.toStringAsFixed(2)}'),
            Text('കസ്റ്റമർ: ${invoice.customerName}'),
            const SizedBox(height: 12),
            const Text('വിൽപ്പന വിജയകരമായി രേഖപ്പെടുത്തി.'),
          ],
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () {
              PosService.instance.shareReceiptWhatsApp(
                invoice: invoice,
                shopName: Db.setting('shop_name', 'TEKFIX MOBILE HUB'),
                shopPhone: Db.setting('shop_phone', '7034093101'),
              );
            },
            icon: const Icon(Icons.chat_rounded, color: Colors.green),
            label: const Text(TekStrings.btnShareWhatsApp),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(TekStrings.btnNewSale),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AttendanceRecord?>(
      stream: AttendanceService.instance.streamTodayAttendance(widget.shopId, widget.staffId),
      builder: (context, snapshot) {
        final record = snapshot.data ?? AttendanceService.instance.getCachedTodayAttendance(widget.staffId);
        final bool isCheckedIn = record != null && record.checkIn != null;
        final bool isCheckedOut = record != null && record.checkOut != null;
        final bool isGatedUnlocked = isCheckedIn && !isCheckedOut;

        if (!isGatedUnlocked) {
          return _buildLockedGatedState(context, isCheckedOut);
        }

        return _buildUnlockedPos(context, record);
      },
    );
  }

  Widget _buildLockedGatedState(BuildContext context, bool isCheckedOut) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(TekStrings.tabPos),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.lock_rounded,
                  size: 64,
                  color: Colors.red.shade700,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                TekStrings.posLockedTitle,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.shade300),
                ),
                child: Text(
                  isCheckedOut
                      ? 'ഇന്നത്തെ ഡ്യൂട്ടി പൂർത്തിയായി (Shift is completed for today). POS ക്ലോസ് ചെയ്തിരിക്കുന്നു.'
                      : TekStrings.posLockedBanner,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.amber.shade900,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                TekStrings.posLockedSub,
                style: TextStyle(fontSize: 12.5, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              if (!isCheckedOut)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                    backgroundColor: kPrimary,
                  ),
                  onPressed: widget.onNavigateToAttendance,
                  icon: const Icon(Icons.how_to_reg_rounded),
                  label: const Text(
                    TekStrings.btnCheckInNow,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUnlockedPos(BuildContext context, AttendanceRecord record) {
    final catalog = PosService.instance.getCatalogItems();
    final filtered = catalog.where((it) {
      final matchesCat = _selectedCategory == 'All' || it.category == _selectedCategory;
      final q = _searchQuery.toLowerCase();
      final matchesSearch = q.isEmpty ||
          it.name.toLowerCase().contains(q) ||
          it.barcode.toLowerCase().contains(q) ||
          it.sku.toLowerCase().contains(q);
      return matchesCat && matchesSearch;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(TekStrings.tabPos, style: TextStyle(fontWeight: FontWeight.bold)),
            _buildApprovalBadge(record),
          ],
        ),
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.shopping_cart_rounded),
                onPressed: _openCheckoutSheet,
              ),
              if (_cart.isNotEmpty)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      '${_cart.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: TekStrings.searchItems,
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
                isDense: true,
              ),
            ),
          ),

          // Category Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              children: _categories.map((cat) {
                final isSel = _selectedCategory == cat;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    selected: isSel,
                    label: Text(cat),
                    onSelected: (val) => setState(() => _selectedCategory = cat),
                  ),
                );
              }).toList(),
            ),
          ),

          const Divider(height: 12),

          // Catalog Grid
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Text('ഉൽപ്പന്നങ്ങൾ ലഭ്യമല്ല (No items found).'),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: 0.85,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: filtered.length,
                    itemBuilder: (context, idx) {
                      final item = filtered[idx];
                      return _buildItemCard(item);
                    },
                  ),
          ),

          // Floating Cart Summary Bar
          if (_cart.isNotEmpty) _buildBottomCartBar(),
        ],
      ),
    );
  }

  Widget _buildApprovalBadge(AttendanceRecord r) {
    String text;
    Color color;

    if (r.isApproved) {
      text = TekStrings.badgeApproved;
      color = Colors.greenAccent;
    } else if (r.isRejected) {
      text = '${TekStrings.badgeRejected}: ${r.adjustReason ?? ''}';
      color = Colors.redAccent;
    } else if (r.isAdjusted) {
      text = '${TekStrings.badgeAdjusted}: ${r.adjustReason ?? ''}';
      color = Colors.purpleAccent;
    } else {
      text = TekStrings.badgePendingApproval;
      color = Colors.amberAccent;
    }

    return Text(
      text,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
    );
  }

  Widget _buildItemCard(PosItem it) {
    Color stockColor = Colors.green;
    String stockText = '${it.stock} In Stock';
    if (it.isOutOfStock) {
      stockColor = Colors.red;
      stockText = TekStrings.outOfStock;
    } else if (it.isLowStock) {
      stockColor = Colors.orange;
      stockText = 'Only ${it.stock} Left';
    }

    return Card(
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: it.isOutOfStock ? null : () => _addToCart(it),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: stockColor.withAlpha(25),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: stockColor.withAlpha(80)),
                    ),
                    child: Text(
                      stockText,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: stockColor),
                    ),
                  ),
                  Text(
                    it.category,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                it.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '₹${it.sellingPrice.toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF16A34A),
                    ),
                  ),
                  IconButton.filledTonal(
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    onPressed: it.isOutOfStock ? null : () => _addToCart(it),
                    icon: const Icon(Icons.add_shopping_cart_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomCartBar() {
    final count = _cart.fold(0, (s, i) => s + i.qty);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, -3))],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count Items • Cart',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                Text(
                  '₹${_total.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF16A34A)),
                ),
              ],
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _showCartItemListModal(),
              icon: const Icon(Icons.list_alt_rounded),
              label: const Text('View Cart'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF16A34A),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              ),
              onPressed: _openCheckoutSheet,
              icon: const Icon(Icons.arrow_forward_rounded),
              label: const Text('Checkout', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  void _showCartItemListModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => Container(
          height: MediaQuery.of(ctx).size.height * 0.65,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('കാർട്ടിലെ സാധനങ്ങൾ (Cart Items)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                ],
              ),
              const Divider(),
              Expanded(
                child: ListView.separated(
                  itemCount: _cart.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, idx) {
                    final item = _cart[idx];
                    return ListTile(
                      title: Text(item.item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Row(
                        children: [
                          Text('₹${item.unitPrice.toStringAsFixed(0)}'),
                          if (item.hasValidOverride)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(color: Colors.amber.shade100, borderRadius: BorderRadius.circular(4)),
                              child: const Text('PIN Approved', style: TextStyle(fontSize: 9, color: Colors.orange)),
                            ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.edit_note_rounded, size: 20),
                            onPressed: () async {
                              await _editItemPrice(item);
                              setM(() {});
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline, size: 20),
                            onPressed: () {
                              _updateCartQty(item, item.qty - 1);
                              setM(() {});
                            },
                          ),
                          Text('${item.qty}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline, size: 20),
                            onPressed: () {
                              _updateCartQty(item, item.qty + 1);
                              setM(() {});
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _openCheckoutSheet();
                },
                child: Text('Checkout • ₹${_total.toStringAsFixed(2)}'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
