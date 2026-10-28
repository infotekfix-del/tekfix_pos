import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../attendance/attendance_models.dart';
import '../attendance/attendance_service.dart';
import '../main.dart' show Db, toast;
import '../shared/tek_pos_strings.dart';
import '../theme/tek_tokens.dart';
import '../inventory/consumables_service.dart';
import 'pos_models.dart';
import 'pos_service.dart';
import '../returns/returns_dashboard_view.dart';

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
    'Photostat / Printing',
    'Tempered Glass',
    'Cases & Covers',
    'Chargers',
    'Cables',
    'Earbuds & Audio',
    'Displays & Screens',
    'Batteries',
    'Others',
  ];

  late Stream<AttendanceRecord?> _attendanceStream;
  late Stream<List<PosItem>> _catalogStream;

  @override
  void initState() {
    super.initState();
    _initStreams();
  }

  void _initStreams() {
    _attendanceStream = AttendanceService.instance.streamTodayAttendance(widget.shopId, widget.staffId);
    _catalogStream = PosService.instance.streamCatalogItems(widget.shopId);
  }

  @override
  void didUpdateWidget(StaffPosScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shopId != widget.shopId || oldWidget.staffId != widget.staffId) {
      _initStreams();
    }
  }

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
      HapticFeedback.lightImpact();
      setState(() => current.qty++);
    } else {
      HapticFeedback.lightImpact();
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
    HapticFeedback.lightImpact();
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

    try {
      await showDialog(
        context: context,
        builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: TekColors.bgCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: TekColors.border),
          ),
          title: Text(
            '${cartItem.item.name} - വില തിരുത്തുക',
            style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MRP: ₹${cartItem.item.sellingPrice.toStringAsFixed(0)} | Min Floor: ₹${cartItem.item.minPrice.toStringAsFixed(0)}',
                style: const TextStyle(color: TekColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: priceCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  labelText: 'പുതിയ യൂണിറ്റ് വില (Unit Price)',
                  labelStyle: const TextStyle(color: TekColors.textSecondary),
                  prefixText: '₹ ',
                  prefixStyle: const TextStyle(color: TekColors.secondary, fontWeight: FontWeight.bold),
                  errorText: err,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('റദ്ദാക്കുക', style: TextStyle(color: TekColors.textSecondary)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: TekColors.primary),
              onPressed: () async {
                final newPrice = double.tryParse(priceCtrl.text) ?? cartItem.unitPrice;
                if (newPrice < cartItem.item.minPrice) {
                  // Below Floor Price!
                  setD(() => err = TekStrings.errPriceBelowFloor.replaceAll('{min}', cartItem.item.minPrice.toStringAsFixed(0)));

                  // Offer Owner PIN approval dialog
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
    } finally {
      priceCtrl.dispose();
    }
  }

  Future<String?> _requestOwnerPinApproval(PosItem item, double requestedPrice) async {
    final pinCtrl = TextEditingController();
    String? pinErr;

    try {
      return await showDialog<String?>(
        context: context,
        barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: TekColors.bgCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: TekColors.border),
          ),
          icon: const Icon(Icons.lock_person_rounded, size: 40, color: TekColors.warning),
          title: const Text(
            TekStrings.pinApprovalTitle,
            style: TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${item.name}\nMRP: ₹${item.sellingPrice.toStringAsFixed(0)} ➔ ₹${requestedPrice.toStringAsFixed(0)} (Floor: ₹${item.minPrice.toStringAsFixed(0)})',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.textPrimary, fontSize: 13),
              ),
              const SizedBox(height: 12),
              const Text(
                TekStrings.pinApprovalSub,
                style: TextStyle(fontSize: 12, color: TekColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pinCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: true,
                style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold, letterSpacing: 4),
                decoration: InputDecoration(
                  labelText: 'Owner PIN',
                  labelStyle: const TextStyle(color: TekColors.textSecondary),
                  prefixIcon: const Icon(Icons.key_rounded, color: TekColors.secondary),
                  errorText: pinErr,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('വേണ്ട (Cancel)', style: TextStyle(color: TekColors.textSecondary)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: TekColors.primary),
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
                  setD(() => pinErr = res.error);
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
    } finally {
      pinCtrl.dispose();
    }
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
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final double cashReceived = double.tryParse(_cashReceivedCtrl.text) ?? _total;
          final double changeDue = cashReceived >= _total ? cashReceived - _total : 0.0;
          final upiUri = PosService.instance.generateUpiPaymentUri(
            amount: _total,
            invoiceId: 'PREVIEW',
          );

          return Container(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            decoration: const BoxDecoration(
              color: TekColors.bgCard,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(top: BorderSide(color: TekColors.border, width: 1.5)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: TekColors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'ചെക്ക്ഔട്ട് (Checkout & Billing)',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: TekColors.textPrimary,
                          fontFamilyFallback: TekTypography.malayalamFallback,
                        ),
                      ),
                      Text(
                        '₹${_total.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: TekColors.success,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24, color: TekColors.border),

                  // Cart Item Summary Review
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TekColors.bgSecondary,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: TekColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Cart Items (തിരഞ്ഞെടുത്ത ഇനങ്ങൾ)',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: TekColors.textSecondary),
                        ),
                        const SizedBox(height: 8),
                        ..._cart.map((c) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      c.item.name,
                                      style: const TextStyle(color: TekColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Row(
                                      children: [
                                        Text(
                                          '₹${c.unitPrice.toStringAsFixed(0)} each',
                                          style: const TextStyle(color: TekColors.textSecondary, fontSize: 11),
                                        ),
                                        if (c.hasValidOverride) ...[
                                          const SizedBox(width: 4),
                                          const Icon(Icons.verified_user_rounded, size: 12, color: TekColors.success),
                                        ],
                                        const SizedBox(width: 4),
                                        InkWell(
                                          onTap: () async {
                                            await _editItemPrice(c);
                                            setSheet(() {});
                                          },
                                          child: const Icon(Icons.edit_outlined, size: 14, color: TekColors.secondary),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.remove_circle_outline_rounded, size: 18, color: TekColors.textSecondary),
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () {
                                      _updateCartQty(c, c.qty - 1);
                                      if (_cart.isEmpty) {
                                        Navigator.pop(ctx);
                                      } else {
                                        setSheet(() {});
                                      }
                                    },
                                  ),
                                  Text(
                                    '${c.qty}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.textPrimary, fontSize: 13),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.add_circle_outline_rounded, size: 18, color: TekColors.primary),
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () {
                                      _updateCartQty(c, c.qty + 1);
                                      setSheet(() {});
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '₹${c.lineTotal.toStringAsFixed(2)}',
                                style: const TextStyle(color: TekColors.secondary, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                        )),
                        const Divider(height: 16, color: TekColors.border),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Grand Total (ആകെ തുക):', style: TextStyle(fontWeight: FontWeight.bold, color: TekColors.textPrimary)),
                            Text('₹${_total.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.success, fontSize: 16)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Customer details (Optional)
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _custNameCtrl,
                          style: const TextStyle(color: TekColors.textPrimary),
                          decoration: const InputDecoration(
                            labelText: TekStrings.customerName,
                            labelStyle: TextStyle(color: TekColors.textSecondary),
                            prefixIcon: Icon(Icons.person_outline, size: 18, color: TekColors.secondary),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _custPhoneCtrl,
                          keyboardType: TextInputType.phone,
                          style: const TextStyle(color: TekColors.textPrimary),
                          decoration: const InputDecoration(
                            labelText: TekStrings.customerPhone,
                            labelStyle: TextStyle(color: TekColors.textSecondary),
                            prefixIcon: Icon(Icons.phone_outlined, size: 18, color: TekColors.secondary),
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
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: TekColors.textPrimary,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
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
                            style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold),
                            onChanged: (_) => setSheet(() {}),
                            decoration: const InputDecoration(
                              labelText: TekStrings.cashReceived,
                              labelStyle: TextStyle(color: TekColors.textSecondary),
                              prefixText: '₹ ',
                              prefixStyle: TextStyle(color: TekColors.secondary, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: TekColors.success.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: TekColors.success.withValues(alpha: 0.4)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  TekStrings.changeDue,
                                  style: TextStyle(fontSize: 11, color: TekColors.success, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  '₹${changeDue.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: TekColors.success,
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
                        color: TekColors.bgSecondary,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: TekColors.border),
                      ),
                      child: Column(
                        children: [
                          const Text(
                            TekStrings.upiScanPrompt,
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: TekColors.textPrimary),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: QrImageView(
                              data: upiUri,
                              version: QrVersions.auto,
                              size: 160.0,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Amount: ₹${_total.toStringAsFixed(2)}',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.secondary, fontSize: 15),
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
                            style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold),
                            decoration: const InputDecoration(
                              labelText: 'Cash Amount',
                              labelStyle: TextStyle(color: TekColors.textSecondary),
                              prefixText: '₹ ',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _splitUpiCtrl,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold),
                            decoration: const InputDecoration(
                              labelText: 'UPI Amount',
                              labelStyle: TextStyle(color: TekColors.textSecondary),
                              prefixText: '₹ ',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 24),

                  // Complete Sale Action Button with atomic Firestore transaction and double submission lock
                  GestureDetector(
                    onTap: _submitting
                        ? null
                        : () async {
                            HapticFeedback.heavyImpact();
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
                                final splitTotal = cashAmt + upiAmt;
                                if ((splitTotal - _total).abs() > 0.01) {
                                  toast(ctx, 'തുക കൃത്യമല്ല (Split total must equal ₹${_total.toStringAsFixed(2)})', error: true);
                                  setSheet(() => _submitting = false);
                                  return;
                                }
                              }

                              final payment = PosPayment(
                                mode: paymentMode,
                                totalAmount: _total,
                                cashAmount: cashAmt,
                                upiAmount: upiAmt,
                                cardAmount: cardAmt,
                                cashReceived: cashReceived,
                                changeDue: changeDue,
                              );

                              // Execute atomic sale with Firestore transaction & stock check
                              final invoice = await PosService.instance.completeSale(
                                shopId: widget.shopId,
                                staffId: widget.staffId,
                                staffName: widget.staffName,
                                cartItems: _cart,
                                payment: payment,
                                subtotal: _subtotal,
                                discount: _discount,
                                total: _total,
                                customerName: _custNameCtrl.text,
                                customerPhone: _custPhoneCtrl.text,
                              );

                              if (!mounted) return;
                              if (ctx.mounted) Navigator.pop(ctx);

                              setState(() {
                                _cart.clear();
                                _custNameCtrl.clear();
                                _custPhoneCtrl.clear();
                                _cashReceivedCtrl.clear();
                              });

                              _showSaleSuccessDialog(invoice);
                            } catch (e) {
                              if (ctx.mounted) {
                                showDialog(
                                  context: ctx,
                                  builder: (errCtx) => AlertDialog(
                                    backgroundColor: TekColors.bgCard,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                    icon: const Icon(Icons.error_outline_rounded, color: TekColors.error, size: 40),
                                    title: const Text('ബില്ലിംഗ് തടസ്സപ്പെട്ടു', style: TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold)),
                                    content: Text('$e', style: const TextStyle(color: TekColors.textSecondary)),
                                    actions: [
                                      FilledButton(
                                        style: FilledButton.styleFrom(backgroundColor: TekColors.primary),
                                        onPressed: () => Navigator.pop(errCtx),
                                        child: const Text('OK'),
                                      ),
                                    ],
                                  ),
                                );
                              }
                            } finally {
                              if (mounted) setSheet(() => _submitting = false);
                            }
                          },
                    child: Container(
                      height: 52,
                      decoration: BoxDecoration(
                        gradient: _submitting
                            ? const LinearGradient(colors: [Colors.grey, Colors.black45])
                            : TekColors.primaryGradient,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: TekColors.primaryGlow,
                      ),
                      child: Center(
                        child: _submitting
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              )
                            : const Text(
                                'Complete Sale (ബില്ലിംഗ് പൂർത്തിയാക്കുക)',
                                style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  fontFamilyFallback: TekTypography.malayalamFallback,
                                ),
                              ),
                      ),
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
        backgroundColor: TekColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: TekColors.border),
        ),
        icon: const Icon(Icons.check_circle_rounded, color: TekColors.success, size: 48),
        title: const Text(
          TekStrings.saleSuccessTitle,
          style: TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${TekStrings.invoiceNo}: #${invoice.invoiceId}', style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.secondary)),
            const SizedBox(height: 4),
            Text('${TekStrings.grandTotal}: ₹${invoice.total.toStringAsFixed(2)}', style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text('കസ്റ്റമർ: ${invoice.customerName}', style: const TextStyle(color: TekColors.textSecondary)),
            const SizedBox(height: 12),
            const Text(
              'വിൽപ്പന വിജയകരമായി രേഖപ്പെടുത്തി (Transaction atomic & synced with cash register).',
              style: TextStyle(fontSize: 12, color: TekColors.textMuted),
            ),
          ],
        ),
        actions: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF22C55E)),
            ),
            onPressed: () {
              PosService.instance.shareReceiptWhatsApp(
                invoice: invoice,
                shopName: Db.setting('shop_name', 'TEKFIX DIGITAL'),
                shopPhone: Db.setting('shop_phone', '7034093101'),
              );
            },
            icon: const Icon(Icons.chat_rounded, color: Color(0xFF22C55E), size: 18),
            label: const Text(TekStrings.btnShareWhatsApp, style: TextStyle(color: Color(0xFF22C55E))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TekColors.primary),
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
      stream: _attendanceStream,
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
      backgroundColor: TekColors.bgMain,
      appBar: AppBar(
        backgroundColor: TekColors.bgMain,
        elevation: 0,
        title: const Text('POS Billing (സെയിൽസ്)'),
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
                  color: TekColors.error.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: TekColors.error.withValues(alpha: 0.4)),
                ),
                child: const Icon(
                  Icons.lock_rounded,
                  size: 56,
                  color: TekColors.error,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                TekStrings.posLockedTitle,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: TekColors.textPrimary),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: TekColors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: TekColors.warning.withValues(alpha: 0.4)),
                ),
                child: Text(
                  isCheckedOut
                      ? 'ഇന്നത്തെ ഡ്യൂട്ടി പൂർത്തിയായി (Shift is completed for today). POS ക്ലോസ് ചെയ്തിരിക്കുന്നു.'
                      : TekStrings.posLockedBanner,
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: TekColors.warning,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                    fontFamilyFallback: TekTypography.malayalamFallback,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                TekStrings.posLockedSub,
                style: TextStyle(fontSize: 12, color: TekColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              if (!isCheckedOut)
                GestureDetector(
                  onTap: widget.onNavigateToAttendance,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    decoration: BoxDecoration(
                      gradient: TekColors.primaryGradient,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: TekColors.primaryGlow,
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.how_to_reg_rounded, color: Colors.white, size: 20),
                        SizedBox(width: 8),
                        Text(
                          TekStrings.btnCheckInNow,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUnlockedPos(BuildContext context, AttendanceRecord record) {
    return Scaffold(
      backgroundColor: TekColors.bgMain,
      appBar: AppBar(
        backgroundColor: TekColors.bgMain,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('POS Billing (സെയിൽസ്)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            _buildApprovalBadge(record),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Customer Returns & Warranty',
            icon: const Icon(Icons.assignment_return_rounded, color: TekColors.secondary, size: 24),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ReturnsDashboardView()),
              );
            },
          ),
          const SizedBox(width: 4),
          Stack(
            children: [
              IconButton(
                tooltip: 'Shopping Cart',
                icon: const Icon(Icons.shopping_cart_rounded, color: TekColors.secondary, size: 24),
                onPressed: _openCheckoutSheet,
              ),
              if (_cart.isNotEmpty)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: TekColors.error, shape: BoxShape.circle),
                    constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                    child: Text(
                      '${_cart.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: StreamBuilder<List<PosItem>>(
        stream: _catalogStream,
        builder: (context, snapshot) {
          final catalog = snapshot.data ?? PosService.instance.getCatalogItems();
          final itemsList = List<PosItem>.from(catalog);

          // Ensure quick Photostat services exist for one-click billing
          if (!itemsList.any((i) => i.name.toLowerCase().contains('single side'))) {
            itemsList.add(const PosItem(
              id: 'SERVICE_PHOTOSTAT_SINGLE',
              name: 'Photostat - Single Side (₹5)',
              category: 'Photostat / Printing',
              sellingPrice: 5.0,
              minPrice: 5.0,
              stock: 9999,
            ));
          }
          if (!itemsList.any((i) => i.name.toLowerCase().contains('double side'))) {
            itemsList.add(const PosItem(
              id: 'SERVICE_PHOTOSTAT_DOUBLE',
              name: 'Photostat - Double Side (₹7)',
              category: 'Photostat / Printing',
              sellingPrice: 7.0,
              minPrice: 7.0,
              stock: 9999,
            ));
          }

          final filtered = itemsList.where((it) {
            final matchesCat = _selectedCategory == 'All' ||
                it.category == _selectedCategory ||
                (_selectedCategory == 'Photostat / Printing' &&
                    ConsumablesService.isPhotostatItem(it.name, it.category));
            final q = _searchQuery.toLowerCase();
            final matchesSearch = q.isEmpty ||
                it.name.toLowerCase().contains(q) ||
                it.barcode.toLowerCase().contains(q) ||
                it.sku.toLowerCase().contains(q);
            return matchesCat && matchesSearch;
          }).toList();

          return Column(
            children: [
              // Search Bar
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _searchCtrl,
                  style: const TextStyle(color: TekColors.textPrimary, fontSize: 14),
                  onChanged: (v) => setState(() => _searchQuery = v.trim()),
                  decoration: InputDecoration(
                    hintText: TekStrings.searchItems,
                    hintStyle: const TextStyle(color: TekColors.textMuted, fontSize: 13),
                    prefixIcon: const Icon(Icons.search_rounded, color: TekColors.secondary, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18, color: TekColors.textSecondary),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: TekColors.bgSecondary,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: TekColors.border)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: TekColors.border)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: TekColors.primary, width: 1.5)),
                  ),
                ),
              ),

              // Real-Time Paper Stock Indicator & Threshold Alert
              _buildPaperStockIndicator(),

              // Category Filter Chips
              SizedBox(
                height: 40,
                child: ListView.separated(
                  cacheExtent: 300,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _categories.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (ctx, i) {
                    final cat = _categories[i];
                    final isSel = _selectedCategory == cat;
                    return ChoiceChip(
                      selected: isSel,
                      label: Text(cat),
                      labelStyle: TextStyle(
                        fontSize: 12,
                        fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
                        color: isSel ? Colors.white : TekColors.textSecondary,
                      ),
                      selectedColor: TekColors.primary,
                      backgroundColor: TekColors.bgSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: isSel ? TekColors.primary : TekColors.border),
                      ),
                      onSelected: (val) {
                        if (val) {
                          HapticFeedback.selectionClick();
                          setState(() => _selectedCategory = cat);
                        }
                      },
                    );
                  },
                ),
              ),

              const SizedBox(height: 8),

              // Catalog Grid
              Expanded(
                child: filtered.isEmpty
                    ? const Center(
                        child: Text(
                          'ഉൽപ്പന്നങ്ങൾ ലഭ്യമല്ല (No items found).',
                          style: TextStyle(color: TekColors.textSecondary),
                        ),
                      )
                    : GridView.builder(
                        cacheExtent: 300,
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 85),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 0.82,
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
          );
        },
      ),
    );
  }

  Widget _buildPaperStockIndicator() {
    return ValueListenableBuilder(
      valueListenable: Db.items.listenable(),
      builder: (ctx, box, _) {
        final paper = ConsumablesService.getA4PaperItem();
        final stock = (paper?['stock'] as num?)?.toInt() ?? 1500;
        final factor = (paper?['conversionFactor'] as num?)?.toInt() ?? 500;
        final minStock = (paper?['minStock'] as num?)?.toInt() ?? 200;
        final paperCost = (paper?['costPrice'] as num?)?.toDouble() ?? 0.414;

        final isLow = stock > 0 && stock <= minStock;
        final isOut = stock <= 0;

        final stockStr = ConsumablesService.formatStockDisplay(
          baseStock: stock,
          conversionFactor: factor,
          baseUnit: 'Sheet',
          purchaseUnit: 'Bundle',
        );

        Color cardBg = TekColors.bgSecondary;
        Color borderColor = TekColors.border;
        Color iconColor = TekColors.secondary;
        Color textColor = TekColors.textPrimary;

        if (isOut) {
          cardBg = TekColors.error.withValues(alpha: 0.15);
          borderColor = TekColors.error;
          iconColor = TekColors.error;
          textColor = TekColors.error;
        } else if (isLow) {
          cardBg = TekColors.warning.withValues(alpha: 0.15);
          borderColor = TekColors.warning;
          iconColor = TekColors.warning;
          textColor = TekColors.warning;
        }

        return Container(
          margin: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: (isLow || isOut) ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Icon(
                isOut
                    ? Icons.error_outline_rounded
                    : (isLow ? Icons.warning_amber_rounded : Icons.description_rounded),
                size: 20,
                color: iconColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isOut
                          ? '🚨 Out of Paper (0 Sheets remaining)'
                          : (isLow
                              ? '⚠️ Low Paper Alert: Only $stock Sheets remaining (~${(stock / factor).toStringAsFixed(1)} Bundle)!'
                              : '📄 A4 Paper: $stockStr remaining'),
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isOut
                          ? 'Please purchase / refill A4 paper bundles before billing printing.'
                          : (isLow
                              ? 'Paper stock fell below threshold (< $minStock sheets / ~0.4 bundle). Refill soon.'
                              : 'Dynamic Unit Cost: ₹${paperCost.toStringAsFixed(3)}/sheet • Auto-deducts on POS billing'),
                      style: TextStyle(
                        fontSize: 11,
                        color: (isLow || isOut) ? textColor : TekColors.textMuted,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (!isOut && !isLow)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: TekColors.success.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Optimal',
                    style: TextStyle(
                      color: TekColors.success,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildApprovalBadge(AttendanceRecord r) {
    String text;
    Color color;

    if (r.isApproved) {
      text = TekStrings.badgeApproved;
      color = TekColors.success;
    } else if (r.isRejected) {
      text = '${TekStrings.badgeRejected}: ${r.adjustReason ?? ''}';
      color = TekColors.error;
    } else if (r.isAdjusted) {
      text = '${TekStrings.badgeAdjusted}: ${r.adjustReason ?? ''}';
      color = TekColors.secondary;
    } else {
      text = TekStrings.badgePendingApproval;
      color = TekColors.warning;
    }

    return Text(
      text,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
    );
  }

  Widget _buildItemCard(PosItem it) {
    final isPhotostat = ConsumablesService.isPhotostatItem(it.name, it.category);
    final paperStock = ((ConsumablesService.getA4PaperItem()?['stock'] as num?)?.toInt() ?? 1500);
    final isPaperOut = isPhotostat && paperStock <= 0;

    Color stockColor = TekColors.success;
    String stockText = isPhotostat ? '1 Sheet/copy' : '${it.stock} In Stock';
    if (isPaperOut || it.isOutOfStock) {
      stockColor = TekColors.error;
      stockText = isPaperOut ? 'No Paper!' : TekStrings.outOfStock;
    } else if (it.isLowStock && !isPhotostat) {
      stockColor = TekColors.warning;
      stockText = 'Only ${it.stock} Left';
    }

    final cartIdx = _cart.indexWhere((c) => c.item.id == it.id);
    final cartQty = cartIdx >= 0 ? _cart[cartIdx].qty : 0;

    return Container(
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cartQty > 0 ? TekColors.primary : TekColors.border),
        boxShadow: TekColors.cardShadow,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: (it.isOutOfStock || isPaperOut)
            ? () {
                if (isPaperOut) {
                  toast(context, 'A4 പേപ്പർ തീർന്നു (Out of paper). സ്റ്റോക്ക് റീഫിൽ ചെയ്യുക.', error: true);
                }
              }
            : () => _addToCart(it),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: stockColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: stockColor.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      stockText,
                      style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: stockColor),
                    ),
                  ),
                  Text(
                    it.category,
                    style: const TextStyle(fontSize: 10, color: TekColors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              const Spacer(),
              Text(
                it.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: TekColors.textPrimary),
              ),
              if (isPhotostat) ...[
                Builder(builder: (_) {
                  final margin = ConsumablesService.calculatePhotostatMargin(sellingPrice: it.sellingPrice);
                  final profit = (margin['profit'] as num?)?.toDouble() ?? 0.0;
                  final pct = ((margin['marginPercent'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(0);
                  return Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Margin: ₹${profit.toStringAsFixed(2)} ($pct%)',
                      style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: TekColors.success),
                    ),
                  );
                }),
              ],
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '₹${it.sellingPrice.toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: TekColors.secondary,
                    ),
                  ),
                  if (cartQty > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: TekColors.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'x$cartQty',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: (it.isOutOfStock || isPaperOut)
                            ? TekColors.bgSecondary
                            : TekColors.primary.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.add_shopping_cart_rounded,
                        size: 16,
                        color: (it.isOutOfStock || isPaperOut) ? TekColors.textMuted : TekColors.primary,
                      ),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: TekColors.bgSecondary,
        border: const Border(top: BorderSide(color: TekColors.border)),
        boxShadow: TekColors.cardShadow,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_cart.length} Products (${_cart.fold(0, (s, i) => s + i.qty)} Qty)',
                style: const TextStyle(fontSize: 12, color: TekColors.textSecondary),
              ),
              Text(
                '₹${_total.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: TekColors.success),
              ),
            ],
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: TekColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
            icon: const Icon(Icons.shopping_cart_checkout_rounded, size: 18),
            label: const Text('Checkout (ബിൽ)', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: _openCheckoutSheet,
          ),
        ],
      ),
    );
  }
}
