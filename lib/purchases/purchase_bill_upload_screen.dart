import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db;
import '../theme/tek_tokens.dart';
import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
import 'purchase_bill_details_screen.dart';
import 'purchase_bill_service.dart';
import 'purchase_models.dart';
import '../barcode/barcode_label_service.dart';
import '../barcode/barcode_print_dialog.dart';

class PurchaseBillUploadScreen extends StatefulWidget {
  final PurchaseBill? editBill;

  const PurchaseBillUploadScreen({super.key, this.editBill});

  @override
  State<PurchaseBillUploadScreen> createState() =>
      _PurchaseBillUploadScreenState();
}

class _PurchaseBillUploadScreenState extends State<PurchaseBillUploadScreen> {
  final _formKey = GlobalKey<FormState>();

  // Controllers
  final _billNumberCtrl = TextEditingController();
  final _vendorInvoiceCtrl = TextEditingController();
  final _otherChargesCtrl = TextEditingController(text: '0');
  final _paidAmountCtrl = TextEditingController(text: '0');
  final _paymentRefCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  // Date & Time
  DateTime _purchaseDate = DateTime.now();
  TimeOfDay _purchaseTime = TimeOfDay.now();
  final DateTime _uploadTimestamp = DateTime.now();

  // Vendor state
  dynamic _selectedVendorKey;
  String _selectedVendorName = '';
  String _selectedVendorPhone = '';
  String _selectedVendorAddress = '';
  String _selectedVendorGst = '';
  double _vendorPrevBalance = 0.0;
  PurchaseBill? _duplicateInvoiceWarning;

  // Attachment state
  BillAttachment? _attachment;
  bool _isUploadingFile = false;

  // Items
  final List<PurchaseBillItem> _items = [];

  // Payment
  String _paymentMethod = 'Cash';
  DateTime _paymentDate = DateTime.now();
  TimeOfDay _paymentTime = TimeOfDay.now();

  // Loading & state
  bool _isSaving = false;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initData();
  }

  Future<void> _initData() async {
    if (widget.editBill != null) {
      final b = widget.editBill!;
      _billNumberCtrl.text = b.billNumber;
      _vendorInvoiceCtrl.text = b.vendorInvoiceNumber;
      _otherChargesCtrl.text = b.otherCharges.toStringAsFixed(0);
      _paidAmountCtrl.text = b.paidAmount.toStringAsFixed(0);
      _notesCtrl.text = b.notes ?? '';
      _purchaseDate = b.purchaseDate;
      _purchaseTime = TimeOfDay.fromDateTime(b.purchaseDate);
      _selectedVendorKey = b.vendorKey;
      _selectedVendorName = b.vendorName;
      _selectedVendorPhone = b.vendorPhone;
      _selectedVendorAddress = b.vendorAddress ?? '';
      _selectedVendorGst = b.vendorGst ?? '';
      _attachment = b.attachment;
      _items.addAll(b.items);
      _vendorPrevBalance = PurchaseBillService.instance
          .getVendorOutstandingBalance(b.vendorKey);
    } else {
      final nextNum =
          await PurchaseBillService.instance.generateBillNumber();
      if (mounted) {
        setState(() {
          _billNumberCtrl.text = nextNum;
        });
      }
    }
    setState(() => _isInitialized = true);
  }

  @override
  void dispose() {
    _billNumberCtrl.dispose();
    _vendorInvoiceCtrl.dispose();
    _otherChargesCtrl.dispose();
    _paidAmountCtrl.dispose();
    _paymentRefCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Calculations
  // ---------------------------------------------------------------------------

  double get _subtotal => _items.fold(
      0.0, (sum, it) => sum + (it.quantity * it.purchaseRate));

  int get _totalQuantity => _items.fold(0, (sum, it) => sum + it.quantity);

  double get _totalDiscount =>
      _items.fold(0.0, (sum, it) => sum + it.discount);

  double get _totalTax => _items.fold(0.0, (sum, it) => sum + it.taxAmount);

  double get _otherCharges => double.tryParse(_otherChargesCtrl.text) ?? 0.0;

  double get _grandTotal =>
      (_subtotal - _totalDiscount + _totalTax + _otherCharges)
          .clamp(0.0, double.infinity);

  double get _enteredPaidAmount =>
      double.tryParse(_paidAmountCtrl.text) ?? 0.0;

  double get _safePaidAmount => _enteredPaidAmount.clamp(0.0, _grandTotal);

  double get _remainingBalance =>
      (_grandTotal - _safePaidAmount).clamp(0.0, _grandTotal);

  double get _updatedVendorBalance => _vendorPrevBalance + _remainingBalance;

  String get _currentPaymentStatus {
    if (_grandTotal == 0) return BillPaymentStatus.paid;
    if (_safePaidAmount >= _grandTotal - 0.01) {
      return BillPaymentStatus.paid;
    } else if (_safePaidAmount > 0.01) {
      return BillPaymentStatus.partiallyPaid;
    }
    return BillPaymentStatus.unpaid;
  }

  // ---------------------------------------------------------------------------
  // File Picker & Camera
  // ---------------------------------------------------------------------------

  Future<void> _pickFile() async {
    try {
      setState(() => _isUploadingFile = true);
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'pdf'],
        withData: true,
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        final ext = (file.extension ?? '').toLowerCase();
        final mime = ext == 'pdf' ? 'application/pdf' : 'image/$ext';

        String? base64Data;
        if (file.bytes != null) {
          base64Data = base64Encode(file.bytes!);
        }

        setState(() {
          _attachment = BillAttachment(
            fileName: file.name,
            fileType: mime,
            fileSize: file.size,
            fileBytesBase64: base64Data,
            filePath: file.path,
            uploadedAt: DateTime.now(),
          );
        });
        TekFeedback.toast('Bill attached: ${file.name}');
      }
    } catch (e) {
      TekFeedback.error('Failed to attach bill: $e');
    } finally {
      if (mounted) setState(() => _isUploadingFile = false);
    }
  }

  void _removeAttachment() {
    setState(() => _attachment = null);
    TekFeedback.toast('Attachment removed');
  }

  // ---------------------------------------------------------------------------
  // Vendor Duplicate Invoice Check
  // ---------------------------------------------------------------------------

  void _onInvoiceOrVendorChanged() {
    final inv = _vendorInvoiceCtrl.text.trim();
    if (inv.isNotEmpty && _selectedVendorKey != null) {
      final dup = PurchaseBillService.instance
          .checkDuplicateInvoice(inv, _selectedVendorKey);
      if (widget.editBill != null && dup?.key == widget.editBill?.key) {
        setState(() => _duplicateInvoiceWarning = null);
      } else {
        setState(() => _duplicateInvoiceWarning = dup);
      }
    } else {
      setState(() => _duplicateInvoiceWarning = null);
    }
  }

  // ---------------------------------------------------------------------------
  // Add Vendor Inline Modal
  // ---------------------------------------------------------------------------

  void _showAddVendorDialog() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final addrCtrl = TextEditingController();
    final gstCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    final vFormKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101846),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: DashboardColors.glassBorderHover),
        ),
        title: Row(
          children: [
            const Icon(Icons.person_add_rounded,
                color: DashboardColors.neonBlue),
            const SizedBox(width: 10),
            Text('Add New Vendor',
                style: DashboardTypography.poppins(
                    fontSize: 18, fontWeight: FontWeight.w700)),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Form(
            key: vFormKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDialogTextField(
                    controller: nameCtrl,
                    label: 'Vendor / Company Name *',
                    icon: Icons.business_rounded,
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Enter vendor name' : null,
                  ),
                  const SizedBox(height: 12),
                  _buildDialogTextField(
                    controller: phoneCtrl,
                    label: 'Phone Number *',
                    icon: Icons.phone_rounded,
                    keyboardType: TextInputType.phone,
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Enter phone number' : null,
                  ),
                  const SizedBox(height: 12),
                  _buildDialogTextField(
                    controller: gstCtrl,
                    label: 'GST Number (Optional)',
                    icon: Icons.receipt_rounded,
                  ),
                  const SizedBox(height: 12),
                  _buildDialogTextField(
                    controller: addrCtrl,
                    label: 'Address (Optional)',
                    icon: Icons.location_on_rounded,
                  ),
                  const SizedBox(height: 12),
                  _buildDialogTextField(
                    controller: notesCtrl,
                    label: 'Notes / Payment Terms (Optional)',
                    icon: Icons.notes_rounded,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel',
                style: TextStyle(color: DashboardColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: DashboardColors.primaryBlue,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              if (vFormKey.currentState?.validate() != true) return;
              try {
                final created = await PurchaseBillService.instance.addNewVendor(
                  name: nameCtrl.text,
                  phone: phoneCtrl.text,
                  address: addrCtrl.text,
                  gst: gstCtrl.text,
                  notes: notesCtrl.text,
                );
                Navigator.pop(ctx);
                setState(() {
                  _selectedVendorKey = created['key'];
                  _selectedVendorName = created['name'];
                  _selectedVendorPhone = created['phone'];
                  _selectedVendorAddress = created['address'] ?? '';
                  _selectedVendorGst = created['gst'] ?? '';
                  _vendorPrevBalance = 0.0;
                });
                _onInvoiceOrVendorChanged();
                TekFeedback.success(
                    'Vendor "${created['name']}" added and selected!');
              } catch (e) {
                TekFeedback.error('$e');
              }
            },
            child: const Text('Save & Select Vendor',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Add Existing Item Modal
  // ---------------------------------------------------------------------------

  void _showAddExistingItemDialog() {
    final searchCtrl = TextEditingController();
    List<Map<String, dynamic>> allCatalogItems = [];

    for (final k in Db.items.keys) {
      final val = Db.items.get(k);
      if (val is Map) {
        allCatalogItems.add({
          'key': k,
          'id': val['_id']?.toString() ?? '$k',
          'name': val['name']?.toString() ?? '',
          'brand': val['brand']?.toString() ?? '',
          'model': val['model']?.toString() ?? '',
          'category': val['category']?.toString() ?? 'General',
          'code': val['code']?.toString() ?? val['barcode']?.toString() ?? '',
          'cost': (val['cost'] as num?)?.toDouble() ?? 0.0,
          'price': (val['price'] as num?)?.toDouble() ?? 0.0,
          'stock': (val['stock'] as num?)?.toInt() ?? 0,
        });
      }
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final query = searchCtrl.text.toLowerCase().trim();
            final filtered = allCatalogItems.where((it) {
              if (query.isEmpty) return true;
              return it['name'].toString().toLowerCase().contains(query) ||
                  it['code'].toString().toLowerCase().contains(query) ||
                  it['brand'].toString().toLowerCase().contains(query);
            }).toList();

            return AlertDialog(
              backgroundColor: const Color(0xFF101846),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: const BorderSide(color: DashboardColors.glassBorderHover),
              ),
              title: Row(
                children: [
                  const Icon(Icons.inventory_2_rounded,
                      color: DashboardColors.neonBlue),
                  const SizedBox(width: 10),
                  Text('Select Item from Catalog',
                      style: DashboardTypography.poppins(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                ],
              ),
              content: SizedBox(
                width: 580,
                height: 480,
                child: Column(
                  children: [
                    TextField(
                      controller: searchCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search by item name, SKU or brand...',
                        hintStyle:
                            const TextStyle(color: DashboardColors.textMuted),
                        prefixIcon: const Icon(Icons.search_rounded,
                            color: DashboardColors.neonBlue),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (_) => setModalState(() {}),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.search_off_rounded,
                                      size: 48,
                                      color: DashboardColors.textMuted),
                                  const SizedBox(height: 8),
                                  const Text('No catalog products match',
                                      style: TextStyle(
                                          color: DashboardColors.textMuted)),
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                        foregroundColor:
                                            DashboardColors.neonBlue),
                                    icon: const Icon(Icons.add_rounded),
                                    label: const Text('Create New Product'),
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      _showCreateNewItemDialog();
                                    },
                                  )
                                ],
                              ),
                            )
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) => const Divider(
                                  height: 1, color: Color(0x1AFFFFFF)),
                              itemBuilder: (context, i) {
                                final it = filtered[i];
                                return ListTile(
                                  dense: true,
                                  title: Text(it['name'],
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600)),
                                  subtitle: Text(
                                    '${it['brand']} ${it['model']} • SKU: ${it['code'].isEmpty ? 'N/A' : it['code']} • Current Stock: ${it['stock']}',
                                    style: const TextStyle(
                                        color: DashboardColors.textMuted,
                                        fontSize: 12),
                                  ),
                                  trailing: Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        '₹${(it['cost'] as double).toStringAsFixed(2)}',
                                        style: const TextStyle(
                                            color: DashboardColors.neonGreen,
                                            fontWeight: FontWeight.bold),
                                      ),
                                      const Text('Cost Rate',
                                          style: TextStyle(
                                              color: DashboardColors.textMuted,
                                              fontSize: 10)),
                                    ],
                                  ),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _openConfigureItemDialog(
                                      itemKey: it['key'],
                                      name: it['name'],
                                      brand: it['brand'],
                                      model: it['model'],
                                      category: it['category'],
                                      code: it['code'],
                                      defaultRate: it['cost'],
                                    );
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close',
                      style: TextStyle(color: DashboardColors.textMuted)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Create New Item Modal
  // ---------------------------------------------------------------------------

  void _showCreateNewItemDialog() {
    final nameCtrl = TextEditingController();
    final brandCtrl = TextEditingController();
    final modelCtrl = TextEditingController();
    final categoryCtrl = TextEditingController(text: 'General');
    final codeCtrl = TextEditingController();
    final costCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final nFormKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101846),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: DashboardColors.glassBorderHover),
        ),
        title: Row(
          children: [
            const Icon(Icons.add_box_rounded,
                color: DashboardColors.neonBlue),
            const SizedBox(width: 10),
            Text('Create New Product',
                style: DashboardTypography.poppins(
                    fontSize: 18, fontWeight: FontWeight.w700)),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: Form(
            key: nFormKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDialogTextField(
                    controller: nameCtrl,
                    label: 'Product / Item Name *',
                    icon: Icons.shopping_bag_rounded,
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Enter item name' : null,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildDialogTextField(
                          controller: brandCtrl,
                          label: 'Brand',
                          icon: Icons.branding_watermark_rounded,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildDialogTextField(
                          controller: modelCtrl,
                          label: 'Model',
                          icon: Icons.devices_other_rounded,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildDialogTextField(
                          controller: categoryCtrl,
                          label: 'Category',
                          icon: Icons.category_rounded,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildDialogTextField(
                          controller: codeCtrl,
                          label: 'SKU / Barcode',
                          icon: Icons.qr_code_rounded,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildDialogTextField(
                          controller: costCtrl,
                          label: 'Purchase Cost (₹) *',
                          icon: Icons.currency_rupee_rounded,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          validator: (v) =>
                              double.tryParse(v ?? '') == null
                                  ? 'Enter valid rate'
                                  : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildDialogTextField(
                          controller: priceCtrl,
                          label: 'Selling Price (₹) *',
                          icon: Icons.sell_rounded,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          validator: (v) =>
                              double.tryParse(v ?? '') == null
                                  ? 'Enter valid price'
                                  : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel',
                style: TextStyle(color: DashboardColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: DashboardColors.primaryBlue,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              if (nFormKey.currentState?.validate() != true) return;
              final name = nameCtrl.text.trim();
              final cost = double.tryParse(costCtrl.text) ?? 0.0;
              final price = double.tryParse(priceCtrl.text) ?? cost;

              final rawCode = codeCtrl.text.trim();
              final itemCode = rawCode.isNotEmpty
                  ? rawCode
                  : BarcodeLabelService.instance.generateUniqueBarcode();

              // Save to Db.items
              final newItem = {
                'name': name,
                'brand': brandCtrl.text.trim(),
                'model': modelCtrl.text.trim(),
                'category': categoryCtrl.text.trim(),
                'code': itemCode,
                'barcode': itemCode,
                'sku': itemCode,
                'cost': cost,
                'costPrice': cost,
                'price': price,
                'sellingPrice': price,
                'stock': 0,
                'createdAt': DateTime.now().toIso8601String(),
              };

              final itemKey = await Db.items.add(newItem);
              Navigator.pop(ctx);

              TekFeedback.success('Product "$name" added to catalog!');

              // Open configure item dialog to set quantity & warranty
              _openConfigureItemDialog(
                itemKey: itemKey,
                name: name,
                brand: brandCtrl.text.trim(),
                model: modelCtrl.text.trim(),
                category: categoryCtrl.text.trim(),
                code: codeCtrl.text.trim(),
                defaultRate: cost,
              );
            },
            child: const Text('Create & Add to Bill',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Configure Item Quantity, Rate, Warranty, Serial Dialog
  // ---------------------------------------------------------------------------

  void _openConfigureItemDialog({
    dynamic itemKey,
    required String name,
    String? brand,
    String? model,
    String? category,
    String? code,
    double defaultRate = 0.0,
    PurchaseBillItem? existingItem,
    int? editIndex,
  }) {
    final qtyCtrl = TextEditingController(
        text: (existingItem?.quantity ?? 1).toString());
    final rateCtrl = TextEditingController(
        text: (existingItem?.purchaseRate ?? defaultRate).toStringAsFixed(2));
    final discountCtrl = TextEditingController(
        text: (existingItem?.discount ?? 0.0).toStringAsFixed(0));
    final taxCtrl = TextEditingController(
        text: (existingItem?.taxPercent ?? 0.0).toStringAsFixed(0));
    final serialCtrl = TextEditingController(
        text: existingItem?.imeiOrSerial ?? '');
    final customDaysCtrl = TextEditingController(
        text: (existingItem?.customWarrantyDays ?? '').toString());

    bool warrantyAvailable = existingItem != null
        ? existingItem.hasWarranty
        : true;
    String selectedDuration = existingItem?.warrantyDuration ??
        ItemWarrantyDuration.months12;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final q = int.tryParse(qtyCtrl.text) ?? 1;
          final r = double.tryParse(rateCtrl.text) ?? 0.0;
          final disc = double.tryParse(discountCtrl.text) ?? 0.0;
          final tx = double.tryParse(taxCtrl.text) ?? 0.0;
          final taxable = (q * r) - disc;
          final lineTax = taxable > 0 ? (taxable * tx / 100) : 0.0;
          final lineTotal = (taxable + lineTax).clamp(0.0, double.infinity);

          final customDays = int.tryParse(customDaysCtrl.text);
          final expiry = warrantyAvailable
              ? PurchaseBillService.instance.calculateItemWarrantyExpiry(
                  _purchaseDate,
                  selectedDuration,
                  customDays: customDays,
                )
              : null;

          return AlertDialog(
            backgroundColor: const Color(0xFF101846),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: DashboardColors.glassBorderHover),
            ),
            title: Row(
              children: [
                const Icon(Icons.edit_note_rounded,
                    color: DashboardColors.neonBlue),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    editIndex != null ? 'Edit Item: $name' : 'Add Item: $name',
                    style: DashboardTypography.poppins(
                        fontSize: 17, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Item badge
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded,
                              size: 18, color: DashboardColors.neonBlue),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Category: ${category ?? "General"} | Brand: ${brand ?? "-"} | SKU: ${code ?? "-"}',
                              style: const TextStyle(
                                  color: DashboardColors.textLight, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Qty & Rate
                    Row(
                      children: [
                        Expanded(
                          child: _buildDialogTextField(
                            controller: qtyCtrl,
                            label: 'Quantity *',
                            icon: Icons.numbers_rounded,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildDialogTextField(
                            controller: rateCtrl,
                            label: 'Purchase Rate (₹) *',
                            icon: Icons.currency_rupee_rounded,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Discount & Tax %
                    Row(
                      children: [
                        Expanded(
                          child: _buildDialogTextField(
                            controller: discountCtrl,
                            label: 'Discount (₹)',
                            icon: Icons.discount_rounded,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildDialogTextField(
                            controller: taxCtrl,
                            label: 'Tax / GST %',
                            icon: Icons.percent_rounded,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // IMEI / Serial Number
                    _buildDialogTextField(
                      controller: serialCtrl,
                      label: 'IMEI / Serial Number (Optional)',
                      icon: Icons.qr_code_scanner_rounded,
                      hintText: 'e.g. 864501047123456 or SN998234',
                    ),
                    const SizedBox(height: 16),

                    // SECTION: ITEM WARRANTY OPTIONS
                    Text('Item Warranty Settings',
                        style: DashboardTypography.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: DashboardColors.textLight)),
                    const SizedBox(height: 8),

                    // Toggle: Warranty Available? Yes / No
                    Row(
                      children: [
                        const Text('Warranty Available?',
                            style: TextStyle(color: DashboardColors.textMuted)),
                        const Spacer(),
                        ChoiceChip(
                          label: const Text('Yes'),
                          selected: warrantyAvailable,
                          selectedColor: DashboardColors.neonBlue,
                          labelStyle: TextStyle(
                            color: warrantyAvailable
                                ? Colors.black
                                : Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                          onSelected: (val) {
                            setDialogState(() {
                              warrantyAvailable = true;
                              if (selectedDuration ==
                                  ItemWarrantyDuration.noWarranty) {
                                selectedDuration =
                                    ItemWarrantyDuration.months12;
                              }
                            });
                          },
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('No'),
                          selected: !warrantyAvailable,
                          selectedColor: DashboardColors.alertOrange,
                          labelStyle: TextStyle(
                            color: !warrantyAvailable
                                ? Colors.white
                                : DashboardColors.textMuted,
                            fontWeight: FontWeight.bold,
                          ),
                          onSelected: (val) {
                            setDialogState(() {
                              warrantyAvailable = false;
                              selectedDuration =
                                  ItemWarrantyDuration.noWarranty;
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    if (warrantyAvailable) ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <String>[
                          ItemWarrantyDuration.months3,
                          ItemWarrantyDuration.months6,
                          ItemWarrantyDuration.months12,
                          ItemWarrantyDuration.months24,
                          ItemWarrantyDuration.custom,
                        ].map<Widget>((String dur) {
                          final isSel = selectedDuration == dur;
                          return ChoiceChip(
                            label: Text(dur),
                            selected: isSel,
                            selectedColor: DashboardColors.neonBlue,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.05),
                            labelStyle: TextStyle(
                              color: isSel ? Colors.black : Colors.white,
                              fontWeight:
                                  isSel ? FontWeight.bold : FontWeight.normal,
                              fontSize: 12,
                            ),
                            onSelected: (sel) {
                              if (sel) {
                                setDialogState(() => selectedDuration = dur);
                              }
                            },
                          );
                        }).toList(),
                      ),
                      if (selectedDuration == ItemWarrantyDuration.custom) ...[
                        const SizedBox(height: 10),
                        _buildDialogTextField(
                          controller: customDaysCtrl,
                          label: 'Custom Duration (in Days)',
                          icon: Icons.calendar_today_rounded,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => setDialogState(() {}),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: DashboardColors.neonGreen
                              .withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: DashboardColors.neonGreen
                                  .withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.verified_rounded,
                                size: 16, color: DashboardColors.neonGreen),
                            const SizedBox(width: 8),
                            Text(
                              'Warranty Expiry: ${expiry != null ? DateFormat("dd MMM yyyy").format(expiry) : "N/A"}',
                              style: const TextStyle(
                                  color: DashboardColors.neonGreen,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.remove_circle_outline_rounded,
                                size: 16, color: DashboardColors.textMuted),
                            SizedBox(width: 8),
                            Text(
                              'Saved as: No Warranty',
                              style: TextStyle(
                                  color: DashboardColors.textMuted,
                                  fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),
                    const Divider(color: Color(0x1AFFFFFF)),
                    const SizedBox(height: 8),

                    // Calculated Line Total Display
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Line Total:',
                            style: TextStyle(
                                color: DashboardColors.textLight,
                                fontWeight: FontWeight.w600)),
                        Text(
                          '₹${lineTotal.toStringAsFixed(2)}',
                          style: DashboardTypography.poppins(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: DashboardColors.neonGreen),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: DashboardColors.textMuted)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: DashboardColors.neonBlue,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () {
                  final quantity = int.tryParse(qtyCtrl.text) ?? 1;
                  final rate = double.tryParse(rateCtrl.text) ?? 0.0;
                  final disc = double.tryParse(discountCtrl.text) ?? 0.0;
                  final taxP = double.tryParse(taxCtrl.text) ?? 0.0;
                  final customD = int.tryParse(customDaysCtrl.text);

                  if (quantity <= 0) {
                    TekFeedback.error('Quantity must be at least 1');
                    return;
                  }
                  if (rate < 0) {
                    TekFeedback.error('Purchase rate cannot be negative');
                    return;
                  }

                  final item = PurchaseBillItem(
                    itemKey: itemKey,
                    itemName: name,
                    brand: brand ?? '',
                    model: model ?? '',
                    category: category ?? '',
                    productCode: code ?? '',
                    imeiOrSerial: serialCtrl.text.trim().isNotEmpty
                        ? serialCtrl.text.trim()
                        : null,
                    quantity: quantity,
                    purchaseRate: rate,
                    discount: disc,
                    taxPercent: taxP,
                    hasWarranty: warrantyAvailable,
                    warrantyDuration: warrantyAvailable
                        ? selectedDuration
                        : ItemWarrantyDuration.noWarranty,
                    customWarrantyDays: customD,
                    warrantyExpiryDate: warrantyAvailable
                        ? PurchaseBillService.instance
                            .calculateItemWarrantyExpiry(_purchaseDate,
                                selectedDuration,
                                customDays: customD)
                        : null,
                  );

                  setState(() {
                    if (editIndex != null) {
                      _items[editIndex] = item;
                    } else {
                      _items.add(item);
                    }
                  });

                  Navigator.pop(ctx);
                  TekFeedback.toast(
                      editIndex != null ? 'Item updated' : 'Item added');
                },
                child: Text(
                  editIndex != null ? 'Update Item' : 'Add to Bill',
                  style: const TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Save or Draft Handler
  // ---------------------------------------------------------------------------

  Future<void> _submitBill({bool isDraft = false}) async {
    if (_formKey.currentState?.validate() != true) return;

    if (_selectedVendorKey == null && _selectedVendorName.trim().isEmpty) {
      TekFeedback.error('Please select or create a vendor');
      return;
    }

    if (_items.isEmpty) {
      TekFeedback.error('Please add at least one item to the purchase bill');
      return;
    }

    // Confirm dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101846),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: DashboardColors.glassBorderHover)),
        title: Text(isDraft ? 'Save as Draft?' : 'Confirm Purchase Bill?',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text(
          isDraft
              ? 'Draft bills will be saved without increasing inventory or vendor debt.'
              : 'Saving this purchase bill will increase inventory stock, record stock movements, and update vendor balances.\n\nGrand Total: ₹${_grandTotal.toStringAsFixed(2)}\nAmount Paid: ₹${_safePaidAmount.toStringAsFixed(2)}\nBalance Due: ₹${_remainingBalance.toStringAsFixed(2)}',
          style: const TextStyle(color: DashboardColors.textLight),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: DashboardColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isDraft
                  ? DashboardColors.neonOrange
                  : DashboardColors.neonGreen,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              isDraft ? 'Save Draft' : 'Confirm & Save',
              style: const TextStyle(
                  color: Colors.black, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final auth = Provider.of<AuthController>(context, listen: false);

    setState(() => _isSaving = true);
    try {
      final combinedPurchaseDate = DateTime(
        _purchaseDate.year,
        _purchaseDate.month,
        _purchaseDate.day,
        _purchaseTime.hour,
        _purchaseTime.minute,
      );

      final saved = await PurchaseBillService.instance.savePurchaseBill(
        key: widget.editBill?.key,
        billNumber: _billNumberCtrl.text.trim(),
        vendorInvoiceNumber: _vendorInvoiceCtrl.text.trim(),
        vendorKey: _selectedVendorKey,
        vendorName: _selectedVendorName,
        vendorPhone: _selectedVendorPhone,
        vendorGst: _selectedVendorGst,
        vendorAddress: _selectedVendorAddress,
        purchaseDate: combinedPurchaseDate,
        items: _items,
        otherCharges: _otherCharges,
        initialPaidAmount: _safePaidAmount,
        initialPaymentMethod: _paymentMethod,
        initialPaymentReference: _paymentRefCtrl.text.trim(),
        attachment: _attachment,
        staffId: auth.uid,
        staffName: auth.name.isNotEmpty ? auth.name : 'Owner',
        notes: _notesCtrl.text.trim(),
        isDraft: isDraft,
      );

      TekFeedback.success(isDraft
          ? 'Purchase Bill saved as draft (${saved.billNumber})'
          : 'Purchase Bill saved & inventory updated (${saved.billNumber})');

      if (mounted) {
        // Post-save action dialog offering Print Barcode Labels button (Requirement 8)
        final action = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF0C1236),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: DashboardColors.glassBorderHover),
            ),
            title: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: DashboardColors.neonGreen, size: 28),
                const SizedBox(width: 12),
                Text(
                  'Purchase Bill Saved!',
                  style: DashboardTypography.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isDraft
                      ? 'Purchase bill "${saved.billNumber}" has been saved as draft.'
                      : 'Purchase bill "${saved.billNumber}" confirmed successfully.\nInventory stock updated for ${saved.items.length} items (${saved.totalQuantity} total qty).',
                  style: const TextStyle(color: DashboardColors.textLight, fontSize: 13.5),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x1AFFFFFF)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.print_rounded, color: DashboardColors.neonBlue, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'TVS LP 46 Lite Barcode Printer:\nPrint ${saved.totalQuantity} stickers (38 mm × 25 mm Code 128)',
                          style: const TextStyle(color: DashboardColors.neonBlue, fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'details'),
                child: const Text('View Bill Details', style: TextStyle(color: DashboardColors.textMuted)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: DashboardColors.neonGreen,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.qr_code_2_rounded, size: 18, color: Colors.black),
                label: const Text(
                  'Print Barcode Labels',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black),
                ),
                onPressed: () => Navigator.pop(ctx, 'print'),
              ),
            ],
          ),
        );

        if (action == 'print' && mounted) {
          await BarcodePrintDialog.showForPurchaseBill(context, saved);
        }

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => PurchaseBillDetailsScreen(bill: saved),
            ),
          );
        }
      }
    } catch (e) {
      TekFeedback.error('Failed to save purchase bill: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Build Main Screen Layout
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        backgroundColor: DashboardColors.bgDarkNavyStart,
        body: Center(
          child: CircularProgressIndicator(color: DashboardColors.neonBlue),
        ),
      );
    }

    return Scaffold(
      backgroundColor: DashboardColors.bgDarkNavyStart,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0C1236),
        elevation: 0,
        title: Text(
          widget.editBill != null
              ? 'Edit Purchase Bill'
              : 'Upload Purchase Bill',
          style: DashboardTypography.poppins(
              fontSize: 18, fontWeight: FontWeight.w700),
        ),
        actions: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: DashboardColors.neonOrange,
              side: const BorderSide(color: DashboardColors.neonOrange),
            ),
            icon: const Icon(Icons.drafts_rounded, size: 16),
            label: const Text('Save as Draft'),
            onPressed: _isSaving ? null : () => _submitBill(isDraft: true),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: DashboardColors.neonBlue,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            icon: _isSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        color: Colors.black, strokeWidth: 2),
                  )
                : const Icon(Icons.check_circle_rounded,
                    color: Colors.black, size: 18),
            label: Text(
              _isSaving ? 'Saving...' : 'Confirm & Save Bill',
              style: const TextStyle(
                  color: Colors.black, fontWeight: FontWeight.bold),
            ),
            onPressed: _isSaving ? null : () => _submitBill(isDraft: false),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: DashboardColors.backgroundGradient,
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. BILL ATTACHMENT SECTION (JPG, PNG, WEBP, PDF)
                _buildAttachmentSection(),
                const SizedBox(height: 20),

                // 2. VENDOR SELECTION & DETAILS
                _buildVendorSection(),
                const SizedBox(height: 20),

                // 3. BILL NUMBERS, DATES & TIMESTAMPS
                _buildBillMetaSection(),
                const SizedBox(height: 20),

                // 4. ITEMS TABLE & ADD BUTTONS
                _buildItemsSection(),
                const SizedBox(height: 20),

                // 5. TOTALS & CALCULATIONS
                _buildTotalsSection(),
                const SizedBox(height: 20),

                // 6. VENDOR PAYMENT DETAILS & BALANCE
                _buildVendorPaymentSection(),
                const SizedBox(height: 30),

                // 7. BOTTOM ACTION BAR
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: DashboardColors.textMuted,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 16),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 14),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: DashboardColors.neonOrange,
                        side: const BorderSide(
                            color: DashboardColors.neonOrange),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 16),
                      ),
                      icon: const Icon(Icons.drafts_rounded),
                      label: const Text('Save as Draft'),
                      onPressed:
                          _isSaving ? null : () => _submitBill(isDraft: true),
                    ),
                    const SizedBox(width: 14),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: DashboardColors.neonBlue,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 32, vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.check_circle_rounded,
                          color: Colors.black),
                      label: Text(
                        _isSaving
                            ? 'Processing...'
                            : 'Confirm & Save Purchase Bill',
                        style: const TextStyle(
                            color: Colors.black,
                            fontSize: 16,
                            fontWeight: FontWeight.bold),
                      ),
                      onPressed:
                          _isSaving ? null : () => _submitBill(isDraft: false),
                    ),
                  ],
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section 1: Attachment
  // ---------------------------------------------------------------------------

  Widget _buildAttachmentSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(
        borderColor: DashboardColors.glassBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: DashboardColors.neonBlue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.cloud_upload_rounded,
                    color: DashboardColors.neonBlue, size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('1. Purchase Bill Document Upload',
                      style: DashboardTypography.poppins(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(
                    'Upload bill image (JPG, PNG, WEBP) or document (PDF)',
                    style: DashboardTypography.inter(
                        fontSize: 12, color: DashboardColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          if (_attachment == null)
            InkWell(
              onTap: _isUploadingFile ? null : _pickFile,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: DashboardColors.neonBlue.withValues(alpha: 0.4),
                    style: BorderStyle.solid,
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Column(
                    children: [
                      _isUploadingFile
                          ? const CircularProgressIndicator(
                              color: DashboardColors.neonBlue)
                          : const Icon(Icons.upload_file_rounded,
                              size: 44, color: DashboardColors.neonBlue),
                      const SizedBox(height: 12),
                      Text(
                        _isUploadingFile
                            ? 'Processing file...'
                            : 'Click or tap to upload Purchase Bill / Invoice',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Supports: JPG, PNG, WEBP, PDF up to 10MB',
                        style: TextStyle(
                            color: DashboardColors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: DashboardColors.neonGreen.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: _attachment!.isPdf
                          ? Colors.red.withValues(alpha: 0.2)
                          : DashboardColors.neonBlue.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Center(
                      child: Icon(
                        _attachment!.isPdf
                            ? Icons.picture_as_pdf_rounded
                            : Icons.image_rounded,
                        color: _attachment!.isPdf
                            ? Colors.redAccent
                            : DashboardColors.neonBlue,
                        size: 28,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_attachment!.fileName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14)),
                        const SizedBox(height: 4),
                        Text(
                          '${_attachment!.formattedSize} • Uploaded ${DateFormat("hh:mm a, dd MMM").format(_attachment!.uploadedAt)}',
                          style: const TextStyle(
                              color: DashboardColors.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: DashboardColors.neonBlue,
                      side: const BorderSide(color: DashboardColors.neonBlue),
                    ),
                    icon: const Icon(Icons.sync_rounded, size: 16),
                    label: const Text('Replace'),
                    onPressed: _pickFile,
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded,
                        color: DashboardColors.alertOrange),
                    tooltip: 'Remove Attachment',
                    onPressed: _removeAttachment,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section 2: Vendor
  // ---------------------------------------------------------------------------

  Widget _buildVendorSection() {
    final vendors = PurchaseBillService.instance.getVendors();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(
        borderColor: DashboardColors.glassBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: DashboardColors.neonPurple.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.storefront_rounded,
                        color: DashboardColors.neonPurple, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('2. Vendor Selection',
                          style: DashboardTypography.poppins(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      Text(
                        'Select existing vendor or register a new one',
                        style: DashboardTypography.inter(
                            fontSize: 12, color: DashboardColors.textMuted),
                      ),
                    ],
                  ),
                ],
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: DashboardColors.neonPurple,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('+ Add New Vendor',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: _showAddVendorDialog,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Searchable Vendor Dropdown
          DropdownButtonFormField<dynamic>(
            value: _selectedVendorKey,
            dropdownColor: const Color(0xFF101846),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Select Vendor *',
              labelStyle: const TextStyle(color: DashboardColors.textMuted),
              prefixIcon: const Icon(Icons.business_rounded,
                  color: DashboardColors.neonBlue),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: DashboardColors.glassBorder),
              ),
            ),
            items: vendors.map((v) {
              return DropdownMenuItem<dynamic>(
                value: v['key'],
                child: Text(
                  '${v['name']} (${v['phone'].isNotEmpty ? v['phone'] : "No Phone"})',
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }).toList(),
            onChanged: (key) {
              final found = vendors.firstWhere((v) => v['key'] == key,
                  orElse: () => {});
              if (found.isNotEmpty) {
                setState(() {
                  _selectedVendorKey = key;
                  _selectedVendorName = found['name'];
                  _selectedVendorPhone = found['phone'];
                  _selectedVendorAddress = found['address'] ?? '';
                  _selectedVendorGst = found['gst'] ?? '';
                  _vendorPrevBalance = PurchaseBillService.instance
                      .getVendorOutstandingBalance(key);
                });
                _onInvoiceOrVendorChanged();
              }
            },
            validator: (v) =>
                v == null ? 'Please select or add a vendor' : null,
          ),

          if (_selectedVendorKey != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x1AFFFFFF)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Phone: ${_selectedVendorPhone.isNotEmpty ? _selectedVendorPhone : "N/A"}',
                            style: const TextStyle(
                                color: DashboardColors.textLight, fontSize: 13)),
                        if (_selectedVendorGst.isNotEmpty)
                          Text('GST: $_selectedVendorGst',
                              style: const TextStyle(
                                  color: DashboardColors.textMuted, fontSize: 12)),
                        if (_selectedVendorAddress.isNotEmpty)
                          Text('Address: $_selectedVendorAddress',
                              style: const TextStyle(
                                  color: DashboardColors.textMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: _vendorPrevBalance > 0
                          ? DashboardColors.alertOrange.withValues(alpha: 0.15)
                          : DashboardColors.neonGreen.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _vendorPrevBalance > 0
                            ? DashboardColors.alertOrange
                            : DashboardColors.neonGreen,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text('Previous Outstanding',
                            style: TextStyle(
                                color: DashboardColors.textMuted, fontSize: 10)),
                        Text(
                          '₹${_vendorPrevBalance.toStringAsFixed(2)}',
                          style: TextStyle(
                            color: _vendorPrevBalance > 0
                                ? DashboardColors.alertOrange
                                : DashboardColors.neonGreen,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section 3: Bill Meta & Timestamps
  // ---------------------------------------------------------------------------

  Widget _buildBillMetaSection() {
    final auth = Provider.of<AuthController>(context);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(
        borderColor: DashboardColors.glassBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: DashboardColors.neonGreen.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.receipt_long_rounded,
                    color: DashboardColors.neonGreen, size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('3. Purchase Bill Date, Time & Numbers',
                      style: DashboardTypography.poppins(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(
                    'Indian date format, auto timestamps, and duplicate check',
                    style: DashboardTypography.inter(
                        fontSize: 12, color: DashboardColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Bill Number & Vendor Invoice Number
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _billNumberCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Purchase Bill Number *',
                    labelStyle:
                        const TextStyle(color: DashboardColors.textMuted),
                    prefixIcon: const Icon(Icons.tag_rounded,
                        color: DashboardColors.neonBlue),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: DashboardColors.glassBorder),
                    ),
                  ),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Enter bill number' : null,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextFormField(
                  controller: _vendorInvoiceCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Vendor Invoice Number *',
                    labelStyle:
                        const TextStyle(color: DashboardColors.textMuted),
                    prefixIcon: const Icon(Icons.receipt_rounded,
                        color: DashboardColors.neonGreen),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: DashboardColors.glassBorder),
                    ),
                  ),
                  onChanged: (_) => _onInvoiceOrVendorChanged(),
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Enter vendor invoice number'
                      : null,
                ),
              ),
            ],
          ),

          // Duplicate Invoice Warning Card
          if (_duplicateInvoiceWarning != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: DashboardColors.alertOrange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DashboardColors.alertOrange),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: DashboardColors.alertOrange),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Warning: A bill (${_duplicateInvoiceWarning!.billNumber}) already exists for this vendor with invoice "${_vendorInvoiceCtrl.text}". Please verify.',
                      style: const TextStyle(
                          color: DashboardColors.alertOrange, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Dates & Times
          Row(
            children: [
              // Purchase Date Picker
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _purchaseDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 30)),
                    );
                    if (picked != null) {
                      setState(() => _purchaseDate = picked);
                    }
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Purchase Date (dd-MM-yyyy)',
                      labelStyle:
                          const TextStyle(color: DashboardColors.textMuted),
                      prefixIcon: const Icon(Icons.calendar_month_rounded,
                          color: DashboardColors.neonBlue),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: DashboardColors.glassBorder),
                      ),
                    ),
                    child: Text(
                      DateFormat('dd-MM-yyyy').format(_purchaseDate),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),

              // Purchase Time Picker
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: _purchaseTime,
                    );
                    if (picked != null) {
                      setState(() => _purchaseTime = picked);
                    }
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Purchase Time',
                      labelStyle:
                          const TextStyle(color: DashboardColors.textMuted),
                      prefixIcon: const Icon(Icons.access_time_rounded,
                          color: DashboardColors.neonBlue),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: DashboardColors.glassBorder),
                      ),
                    ),
                    child: Text(
                      _purchaseTime.format(context),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),

              // Auto Upload Timestamp (Read-only)
              Expanded(
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Upload Timestamp (Auto)',
                    labelStyle:
                        const TextStyle(color: DashboardColors.textMuted),
                    prefixIcon: const Icon(Icons.cloud_done_rounded,
                        color: DashboardColors.neonGreen),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.02),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: DashboardColors.glassBorder),
                    ),
                  ),
                  child: Text(
                    DateFormat('dd-MM-yyyy, hh:mm a')
                        .format(_uploadTimestamp),
                    style: const TextStyle(color: DashboardColors.textMuted),
                  ),
                ),
              ),
              const SizedBox(width: 16),

              // Staff Name
              Expanded(
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Created By / Staff',
                    labelStyle:
                        const TextStyle(color: DashboardColors.textMuted),
                    prefixIcon: const Icon(Icons.person_rounded,
                        color: DashboardColors.neonPurple),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.02),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: DashboardColors.glassBorder),
                    ),
                  ),
                  child: Text(
                    auth.name.isNotEmpty ? auth.name : 'Owner',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          // Notes
          TextFormField(
            controller: _notesCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Purchase Bill Notes (Optional)',
              labelStyle: const TextStyle(color: DashboardColors.textMuted),
              prefixIcon: const Icon(Icons.notes_rounded,
                  color: DashboardColors.neonBlue),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: DashboardColors.glassBorder),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section 4: Items Table
  // ---------------------------------------------------------------------------

  Widget _buildItemsSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(
        borderColor: DashboardColors.glassBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: DashboardColors.neonBlue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.shopping_cart_rounded,
                        color: DashboardColors.neonBlue, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('4. Purchase Items & Warranty Settings',
                          style: DashboardTypography.poppins(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      Text(
                        'Dynamic item table with per-item warranty selection',
                        style: DashboardTypography.inter(
                            fontSize: 12, color: DashboardColors.textMuted),
                      ),
                    ],
                  ),
                ],
              ),
              Row(
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: DashboardColors.neonBlue,
                      side: const BorderSide(color: DashboardColors.neonBlue),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.inventory_2_rounded, size: 16),
                    label: const Text('+ Add Existing Item'),
                    onPressed: _showAddExistingItemDialog,
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: DashboardColors.neonGreen,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.add_box_rounded, size: 16),
                    label: const Text('+ Create New Item',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: _showCreateNewItemDialog,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          if (_items.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 40),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.02),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x1AFFFFFF)),
              ),
              child: Center(
                child: Column(
                  children: [
                    const Icon(Icons.add_shopping_cart_rounded,
                        size: 40, color: DashboardColors.textMuted),
                    const SizedBox(height: 10),
                    const Text('No items added to this purchase bill yet',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    const Text(
                        'Click "+ Add Existing Item" or "+ Create New Item" above',
                        style: TextStyle(
                            color: DashboardColors.textMuted, fontSize: 12)),
                  ],
                ),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(
                    Colors.white.withValues(alpha: 0.06)),
                dataRowColor: WidgetStateProperty.all(Colors.transparent),
                columnSpacing: 20,
                columns: const [
                  DataColumn(
                      label: Text('#',
                          style: TextStyle(
                              color: DashboardColors.textMuted,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Item Name',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('SKU / Code',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('IMEI / Serial',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Qty',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Purchase Rate',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Discount',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Tax %',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Line Total',
                          style: TextStyle(
                              color: DashboardColors.neonGreen,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Warranty',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Warranty Expiry',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Actions',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                ],
                rows: _items.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final it = entry.value;

                  return DataRow(
                    cells: [
                      DataCell(Text('${idx + 1}',
                          style: const TextStyle(
                              color: DashboardColors.textMuted))),
                      DataCell(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(it.itemName,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600)),
                            if ((it.brand ?? '').isNotEmpty ||
                                (it.model ?? '').isNotEmpty)
                              Text('${it.brand ?? ""} ${it.model ?? ""}'.trim(),
                                  style: const TextStyle(
                                      color: DashboardColors.textMuted,
                                      fontSize: 11)),
                          ],
                        ),
                      ),
                      DataCell(Text(it.productCode ?? '-',
                          style: const TextStyle(
                              color: DashboardColors.textLight))),
                      DataCell(Text(it.imeiOrSerial ?? '-',
                          style: const TextStyle(
                              color: DashboardColors.textLight))),
                      DataCell(Text('${it.quantity}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                      DataCell(Text('₹${it.purchaseRate.toStringAsFixed(2)}',
                          style: const TextStyle(color: Colors.white))),
                      DataCell(Text('₹${it.discount.toStringAsFixed(2)}',
                          style: const TextStyle(
                              color: DashboardColors.alertOrange))),
                      DataCell(Text('${it.taxPercent.toStringAsFixed(0)}%',
                          style: const TextStyle(
                              color: DashboardColors.textMuted))),
                      DataCell(Text('₹${it.lineTotal.toStringAsFixed(2)}',
                          style: const TextStyle(
                              color: DashboardColors.neonGreen,
                              fontWeight: FontWeight.bold))),
                      DataCell(
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: it.hasWarranty
                                ? DashboardColors.neonBlue
                                    .withValues(alpha: 0.15)
                                : Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: it.hasWarranty
                                    ? DashboardColors.neonBlue
                                    : const Color(0x22FFFFFF)),
                          ),
                          child: Text(
                            it.hasWarranty
                                ? it.warrantyDuration
                                : 'No Warranty',
                            style: TextStyle(
                              color: it.hasWarranty
                                  ? DashboardColors.neonBlue
                                  : DashboardColors.textMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          it.warrantyExpiryDate != null
                              ? DateFormat('dd MMM yyyy')
                                  .format(it.warrantyExpiryDate!)
                              : '-',
                          style: const TextStyle(
                              color: DashboardColors.textLight, fontSize: 12),
                        ),
                      ),
                      DataCell(
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_rounded,
                                  color: DashboardColors.neonBlue, size: 18),
                              tooltip: 'Edit Item',
                              onPressed: () {
                                _openConfigureItemDialog(
                                  itemKey: it.itemKey,
                                  name: it.itemName,
                                  brand: it.brand,
                                  model: it.model,
                                  category: it.category,
                                  code: it.productCode,
                                  defaultRate: it.purchaseRate,
                                  existingItem: it,
                                  editIndex: idx,
                                );
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline_rounded,
                                  color: DashboardColors.alertOrange, size: 18),
                              tooltip: 'Remove Item',
                              onPressed: () {
                                setState(() => _items.removeAt(idx));
                                TekFeedback.toast('Item removed');
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section 5: Totals
  // ---------------------------------------------------------------------------

  Widget _buildTotalsSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(
        borderColor: DashboardColors.glassBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: DashboardColors.neonOrange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.calculate_rounded,
                    color: DashboardColors.neonOrange, size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('5. Purchase Bill Total Calculation',
                      style: DashboardTypography.poppins(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(
                    'Accurate decimal calculations in Indian Rupees (₹)',
                    style: DashboardTypography.inter(
                        fontSize: 12, color: DashboardColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Summary cards
              Expanded(
                child: Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _buildCalcCard('Subtotal', '₹${_subtotal.toStringAsFixed(2)}',
                        Icons.layers_rounded, DashboardColors.textLight),
                    _buildCalcCard('Total Qty', '$_totalQuantity units',
                        Icons.format_list_numbered_rounded, DashboardColors.neonBlue),
                    _buildCalcCard('Total Discount', '- ₹${_totalDiscount.toStringAsFixed(2)}',
                        Icons.discount_rounded, DashboardColors.alertOrange),
                    _buildCalcCard('Total Tax / GST', '+ ₹${_totalTax.toStringAsFixed(2)}',
                        Icons.receipt_rounded, DashboardColors.neonPurple),
                  ],
                ),
              ),

              const SizedBox(width: 24),

              // Other Charges & Grand Total Box
              SizedBox(
                width: 320,
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: DashboardColors.neonBlue.withValues(alpha: 0.4)),
                  ),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _otherChargesCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Other Charges (₹)',
                          labelStyle:
                              const TextStyle(color: DashboardColors.textMuted),
                          prefixIcon: const Icon(Icons.local_shipping_rounded,
                              color: DashboardColors.neonOrange),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.05),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 14),
                      const Divider(color: Color(0x22FFFFFF)),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('GRAND TOTAL:',
                              style: TextStyle(
                                  color: DashboardColors.textLight,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14)),
                          Text(
                            '₹${_grandTotal.toStringAsFixed(2)}',
                            style: DashboardTypography.poppins(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: DashboardColors.neonGreen,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section 6: Vendor Payment
  // ---------------------------------------------------------------------------

  Widget _buildVendorPaymentSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(
        borderColor: DashboardColors.glassBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: DashboardColors.neonGreen.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.account_balance_wallet_rounded,
                        color: DashboardColors.neonGreen, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('6. Vendor Payment Details & Balance',
                          style: DashboardTypography.poppins(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      Text(
                        'Track partial, full, or zero payment and updated ledger balance',
                        style: DashboardTypography.inter(
                            fontSize: 12, color: DashboardColors.textMuted),
                      ),
                    ],
                  ),
                ],
              ),
              _buildStatusBadge(_currentPaymentStatus),
            ],
          ),
          const SizedBox(height: 16),

          // Overview row
          Row(
            children: [
              Expanded(
                child: _buildSummaryBox(
                  label: 'Total Bill Amount',
                  amount: _grandTotal,
                  color: DashboardColors.textLight,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildSummaryBox(
                  label: 'Previous Vendor Balance',
                  amount: _vendorPrevBalance,
                  color: DashboardColors.neonOrange,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildSummaryBox(
                  label: 'Total Payable to Vendor',
                  amount: _grandTotal + _vendorPrevBalance,
                  color: DashboardColors.neonBlue,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildSummaryBox(
                  label: 'Amount Paid Against Bill',
                  amount: _safePaidAmount,
                  color: DashboardColors.neonGreen,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildSummaryBox(
                  label: 'Remaining Bill Balance',
                  amount: _remainingBalance,
                  color: _remainingBalance > 0
                      ? DashboardColors.alertOrange
                      : DashboardColors.neonGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Payment Input Controls
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Paid Amount Field & Quick Buttons
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: _paidAmountCtrl,
                      style: const TextStyle(color: Colors.white),
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: InputDecoration(
                        labelText: 'Amount Paid (₹) *',
                        labelStyle:
                            const TextStyle(color: DashboardColors.textMuted),
                        prefixIcon: const Icon(Icons.currency_rupee_rounded,
                            color: DashboardColors.neonGreen),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: DashboardColors.glassBorder),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        ActionChip(
                          label: Text('Full (₹${_grandTotal.toStringAsFixed(0)})'),
                          backgroundColor:
                              DashboardColors.neonGreen.withValues(alpha: 0.15),
                          labelStyle: const TextStyle(
                              color: DashboardColors.neonGreen,
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                          onPressed: () {
                            setState(() {
                              _paidAmountCtrl.text =
                                  _grandTotal.toStringAsFixed(0);
                            });
                          },
                        ),
                        ActionChip(
                          label: Text(
                              'Half (₹${(_grandTotal / 2).toStringAsFixed(0)})'),
                          backgroundColor:
                              DashboardColors.neonBlue.withValues(alpha: 0.15),
                          labelStyle: const TextStyle(
                              color: DashboardColors.neonBlue,
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                          onPressed: () {
                            setState(() {
                              _paidAmountCtrl.text =
                                  (_grandTotal / 2).toStringAsFixed(0);
                            });
                          },
                        ),
                        ActionChip(
                          label: const Text('Unpaid (₹0)'),
                          backgroundColor:
                              DashboardColors.alertOrange.withValues(alpha: 0.15),
                          labelStyle: const TextStyle(
                              color: DashboardColors.alertOrange,
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                          onPressed: () {
                            setState(() {
                              _paidAmountCtrl.text = '0';
                            });
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),

              // Payment Method
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _paymentMethod,
                  dropdownColor: const Color(0xFF101846),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Payment Method',
                    labelStyle:
                        const TextStyle(color: DashboardColors.textMuted),
                    prefixIcon: const Icon(Icons.payment_rounded,
                        color: DashboardColors.neonBlue),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: DashboardColors.glassBorder),
                    ),
                  ),
                  items: [
                    'Cash',
                    'UPI',
                    'Bank Transfer',
                    'Card',
                    'Cheque',
                    'Other'
                  ].map((m) {
                    return DropdownMenuItem<String>(value: m, child: Text(m));
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) setState(() => _paymentMethod = val);
                  },
                ),
              ),
              const SizedBox(width: 16),

              // Transaction Ref
              Expanded(
                child: TextFormField(
                  controller: _paymentRefCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Payment Reference / Txn ID',
                    labelStyle:
                        const TextStyle(color: DashboardColors.textMuted),
                    prefixIcon: const Icon(Icons.confirmation_number_rounded,
                        color: DashboardColors.neonBlue),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: DashboardColors.glassBorder),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Updated Vendor Ledger Summary
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x1AFFFFFF)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Updated Total Outstanding Balance with ${_selectedVendorName.isNotEmpty ? _selectedVendorName : "Vendor"}:',
                  style: const TextStyle(
                      color: DashboardColors.textMuted, fontSize: 13),
                ),
                Text(
                  '₹${_updatedVendorBalance.toStringAsFixed(2)}',
                  style: DashboardTypography.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: _updatedVendorBalance > 0
                        ? DashboardColors.alertOrange
                        : DashboardColors.neonGreen,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helper Widgets
  // ---------------------------------------------------------------------------

  Widget _buildCalcCard(
      String label, String value, IconData icon, Color color) {
    return Container(
      width: 180,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: DashboardColors.textMuted, fontSize: 11)),
              Text(value,
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.bold, fontSize: 14)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryBox({
    required String label,
    required double amount,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: DashboardColors.textMuted, fontSize: 11)),
          const SizedBox(height: 4),
          Text(
            '₹${amount.toStringAsFixed(2)}',
            style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    Color bg;
    Color border;
    Color text;

    switch (status) {
      case BillPaymentStatus.paid:
        bg = DashboardColors.neonGreen.withValues(alpha: 0.15);
        border = DashboardColors.neonGreen;
        text = DashboardColors.neonGreen;
        break;
      case BillPaymentStatus.partiallyPaid:
        bg = DashboardColors.neonBlue.withValues(alpha: 0.15);
        border = DashboardColors.neonBlue;
        text = DashboardColors.neonBlue;
        break;
      default:
        bg = DashboardColors.alertOrange.withValues(alpha: 0.15);
        border = DashboardColors.alertOrange;
        text = DashboardColors.alertOrange;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(color: text, fontWeight: FontWeight.bold, fontSize: 12),
      ),
    );
  }

  Widget _buildDialogTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hintText,
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
    void Function(String)? onChanged,
  }) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        labelStyle: const TextStyle(color: DashboardColors.textMuted),
        hintStyle: const TextStyle(color: DashboardColors.textMuted),
        prefixIcon: Icon(icon, color: DashboardColors.neonBlue, size: 20),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: DashboardColors.glassBorder),
        ),
      ),
      validator: validator,
      onChanged: onChanged,
    );
  }
}
