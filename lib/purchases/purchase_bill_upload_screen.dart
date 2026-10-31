import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db;
import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
import 'invoice_parser_service.dart';
import 'purchase_bill_details_screen.dart';
import 'purchase_bill_service.dart';
import 'purchase_models.dart';
import '../barcode/barcode_label_service.dart';
import '../barcode/barcode_print_dialog.dart';

enum PurchaseBillFlowState {
  idle,
  uploading,
  parsing,
  reviewRequired,
  confirming,
  confirmed,
  failed,
}

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

  // Attachment & Invoice Extraction state
  BillAttachment? _attachment;
  Uint8List? _attachmentBytes;
  bool _isUploadingFile = false;
  PurchaseBillFlowState _flowState = PurchaseBillFlowState.idle;
  String? _extractionStatusBanner;
  bool _showExtractionBanner = false;
  double? _invoiceExtractedTotal;

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
      _invoiceExtractedTotal = b.invoiceExtractedTotal;
      _items.addAll(b.items);

      final balPaise = await PurchaseBillService.instance
          .fetchVendorBalancePaise(b.vendorKey);
      _vendorPrevBalance = balPaise / 100.0;
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
  // Calculations & GST Validation (Intra-State CGST/SGST vs Inter-State IGST)
  // ---------------------------------------------------------------------------

  bool _isInterStateGst = false;
  bool _applyRoundOff = true;

  void _detectGstType() {
    final clean = _selectedVendorGst.trim().toUpperCase();
    if (clean.length >= 2) {
      final stateCode = clean.substring(0, 2);
      // '32' is Kerala State Code (Default store state)
      _isInterStateGst = stateCode != '32';
    } else {
      _isInterStateGst = false;
    }
  }

  double get _subtotal => _items.fold(
      0.0, (sum, it) => sum + (it.quantity * it.purchaseRate));

  int get _totalQuantity => _items.fold(0, (sum, it) => sum + it.quantity);

  double get _totalDiscount =>
      _items.fold(0.0, (sum, it) => sum + it.discount);

  double get _totalTax => _items.fold(0.0, (sum, it) => sum + it.taxAmount);

  double get _cgst => _isInterStateGst ? 0.0 : _totalTax / 2.0;

  double get _sgst => _isInterStateGst ? 0.0 : _totalTax / 2.0;

  double get _igst => _isInterStateGst ? _totalTax : 0.0;

  double get _otherCharges => double.tryParse(_otherChargesCtrl.text) ?? 0.0;

  double get _rawGrandTotal =>
      (_subtotal - _totalDiscount + _totalTax + _otherCharges)
          .clamp(0.0, double.infinity);

  double get _roundOff =>
      _applyRoundOff ? (_rawGrandTotal.roundToDouble() - _rawGrandTotal) : 0.0;

  double get _grandTotal =>
      (_rawGrandTotal + _roundOff).clamp(0.0, double.infinity);

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
  // File Picker & Automatic Invoice Parsing (Section 1 -> Section 3 & 4)
  // ---------------------------------------------------------------------------

  Future<void> _pickFile() async {
    try {
      setState(() {
        _isUploadingFile = true;
        _flowState = PurchaseBillFlowState.uploading;
      });

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
          _attachmentBytes = file.bytes;
          _attachment = BillAttachment(
            fileName: file.name,
            fileType: mime,
            fileSize: file.size,
            fileBytesBase64: base64Data,
            filePath: file.path,
            uploadedAt: DateTime.now(),
          );
          _flowState = PurchaseBillFlowState.parsing;
        });

        TekFeedback.toast('Extracting data from ${file.name}...');

        if (file.bytes != null) {
          final parsed = await InvoiceParserService.instance.parseInvoiceFile(
            fileBytes: file.bytes!,
            fileName: file.name,
            filePath: file.path,
          );

          if (mounted) {
            setState(() {
              if (parsed.invoiceNumber != null && parsed.invoiceNumber!.isNotEmpty) {
                _vendorInvoiceCtrl.text = parsed.invoiceNumber!;
              }
              if (parsed.invoiceDate != null) {
                _purchaseDate = parsed.invoiceDate!;
                _purchaseTime = TimeOfDay.fromDateTime(parsed.invoiceDate!);
              }
              if (parsed.invoiceTotal != null && parsed.invoiceTotal! > 0) {
                _invoiceExtractedTotal = parsed.invoiceTotal;
              }
            });

            // Match vendor if parsed and none selected
            if (_selectedVendorKey == null) {
              final vendors = PurchaseBillService.instance.getVendors();
              Map<String, dynamic>? matchedVendor;
              if (parsed.vendorGst != null && parsed.vendorGst!.isNotEmpty) {
                matchedVendor = vendors.cast<Map<String, dynamic>?>().firstWhere(
                  (v) => v?['gst']?.toString().toUpperCase() == parsed.vendorGst!.toUpperCase(),
                  orElse: () => null,
                );
              }
              if (matchedVendor == null && parsed.vendorName != null && parsed.vendorName!.isNotEmpty) {
                final target = parsed.vendorName!.toLowerCase();
                matchedVendor = vendors.cast<Map<String, dynamic>?>().firstWhere(
                  (v) => (v?['name']?.toString().toLowerCase().contains(target) ?? false) ||
                         target.contains(v?['name']?.toString().toLowerCase() ?? '---'),
                  orElse: () => null,
                );
              }
              if (matchedVendor != null) {
                final key = matchedVendor['key'];
                final balPaise = await PurchaseBillService.instance.fetchVendorBalancePaise(key);
                setState(() {
                  _selectedVendorKey = key;
                  _selectedVendorName = matchedVendor!['name'];
                  _selectedVendorPhone = matchedVendor['phone'];
                  _selectedVendorAddress = matchedVendor['address'] ?? '';
                  _selectedVendorGst = matchedVendor['gst'] ?? '';
                  _vendorPrevBalance = balPaise / 100.0;
                  _detectGstType();
                });
              } else if (parsed.vendorName != null && parsed.vendorName!.isNotEmpty) {
                setState(() {
                  _selectedVendorName = parsed.vendorName!;
                  if (parsed.vendorPhone != null) _selectedVendorPhone = parsed.vendorPhone!;
                  if (parsed.vendorGst != null) _selectedVendorGst = parsed.vendorGst!;
                  if (parsed.vendorAddress != null) _selectedVendorAddress = parsed.vendorAddress!;
                  _detectGstType();
                });
              }
            }

            // Auto-populate Section 4 items with Smart Product Matching (3-State Engine: Green/Amber/Red)
            if (parsed.hasItems) {
              final newItems = <PurchaseBillItem>[];
              for (final pItem in parsed.items) {
                final match = await PurchaseBillService.instance.matchProductInFirestore(
                  barcode: pItem.skuOrHsn,
                  sku: pItem.skuOrHsn,
                  name: pItem.description,
                  purchaseRate: pItem.unitPrice,
                  quantity: pItem.quantity,
                );

                final descLower = pItem.description.toLowerCase();
                final isPhone = descLower.contains('phone') ||
                    descLower.contains('iphone') ||
                    descLower.contains('samsung') ||
                    descLower.contains('mobile') ||
                    descLower.contains('pixel') ||
                    descLower.contains('oneplus');

                if (match != null) {
                  final data = match['data'] as Map?;
                  final matchedName = match['name']?.toString() ?? pItem.description;
                  final category = data?['category']?.toString() ?? '';
                  final brand = data?['brand']?.toString() ?? '';
                  final model = data?['model']?.toString() ?? '';
                  final sku = data?['sku']?.toString() ?? pItem.skuOrHsn ?? '';
                  final sellingPrice = (data?['sellingPrice'] as num?)?.toDouble() ??
                      ((data?['sellingPricePaise'] as num?) != null
                          ? (data?['sellingPricePaise'] as num).toDouble() / 100.0
                          : 0.0);
                  final requiresImei = data?['imeiRequired'] == true || isPhone;
                  final status = match['status']?.toString() ?? ProductMatchStatus.matched;
                  final notes = match['notes']?.toString();
                  final isAnomaly = status == ProductMatchStatus.reviewRequired;

                  newItems.add(pItem.toPurchaseBillItem(
                    matchedProductId: match['id']?.toString(),
                    itemKey: match['itemKey'] ?? match['id'],
                    matchedProductName: matchedName,
                    isNew: false,
                  ).copyWith(
                    category: category,
                    brand: brand,
                    model: model,
                    sku: sku,
                    sellingPrice: sellingPrice,
                    mrp: (data?['mrp'] as num?)?.toDouble() ?? (sellingPrice > 0 ? sellingPrice : pItem.unitPrice * 1.25),
                    hsnCode: pItem.skuOrHsn,
                    imeiRequired: requiresImei,
                    isStagedReady: !isAnomaly,
                    matchStatusOverride: status,
                    matchNotes: notes ?? (isAnomaly ? 'Rate or model anomaly detected' : 'Matched to $matchedName'),
                    extractionConfidence: 0.95,
                  ));
                } else {
                  newItems.add(pItem.toPurchaseBillItem(
                    isNew: true,
                  ).copyWith(
                    hsnCode: pItem.skuOrHsn,
                    imeiRequired: isPhone,
                    isStagedReady: false,
                    matchStatusOverride: ProductMatchStatus.quickRegister,
                    matchNotes: 'New Item: Not found in inventory (+ Quick Register)',
                    extractionConfidence: 0.85,
                  ));
                }
              }

              setState(() {
                _items.clear();
                _items.addAll(newItems);
                _extractionStatusBanner =
                    'Parsed ${parsed.itemCount} items from uploaded invoice (${parsed.parsingMethod}). Please review and confirm.';
                _showExtractionBanner = true;
                _flowState = PurchaseBillFlowState.reviewRequired;
              });

              TekFeedback.success('Extracted ${parsed.itemCount} items from invoice!');
            } else {
              setState(() {
                _extractionStatusBanner = 'Bill attached (${file.name}). Review items and proceed.';
                _showExtractionBanner = true;
                _flowState = PurchaseBillFlowState.reviewRequired;
              });
            }

            _onInvoiceOrVendorChanged();
          }
        }
      }
    } catch (e) {
      TekFeedback.error('Failed to attach/parse bill: $e');
      setState(() => _flowState = PurchaseBillFlowState.failed);
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingFile = false;
          if (_flowState == PurchaseBillFlowState.uploading || _flowState == PurchaseBillFlowState.parsing) {
            _flowState = PurchaseBillFlowState.reviewRequired;
          }
        });
      }
    }
  }

  void _removeAttachment() {
    setState(() {
      _attachment = null;
      _attachmentBytes = null;
      _showExtractionBanner = false;
      _extractionStatusBanner = null;
      _invoiceExtractedTotal = null;
      _flowState = PurchaseBillFlowState.idle;
    });
    TekFeedback.toast('Attachment removed');
  }

  // ---------------------------------------------------------------------------
  // Vendor Duplicate Invoice Check
  // ---------------------------------------------------------------------------

  void _onInvoiceOrVendorChanged() {
    _detectGstType();
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
  // SMART PRODUCT MATCHING & INLINE QUICK REGISTER DRAWER (Section 4)
  // ---------------------------------------------------------------------------

  void _showInlineProductRegistrationDialog(int itemIndex) {
    if (itemIndex < 0 || itemIndex >= _items.length) return;
    final item = _items[itemIndex];

    final nameCtrl = TextEditingController(text: item.name);
    final brandCtrl = TextEditingController(text: item.brand);
    final modelCtrl = TextEditingController(text: item.model);
    final categoryCtrl = TextEditingController(
      text: item.category.isNotEmpty ? item.category : 'Mobile / Accessories',
    );
    final hsnCtrl = TextEditingController(text: item.hsnCode ?? '');
    final barcodeCtrl = TextEditingController(
      text: item.sku.isNotEmpty ? item.sku : BarcodeLabelService.instance.generateUniqueBarcode(),
    );
    final purchaseRateCtrl = TextEditingController(text: item.purchaseRate.toStringAsFixed(2));
    final sellingPriceCtrl = TextEditingController(
      text: item.sellingPrice > 0
          ? item.sellingPrice.toStringAsFixed(2)
          : (item.purchaseRate * 1.25).toStringAsFixed(2),
    );
    final mrpCtrl = TextEditingController(
      text: item.mrp > 0
          ? item.mrp.toStringAsFixed(2)
          : (item.sellingPrice > 0
              ? (item.sellingPrice * 1.1).toStringAsFixed(2)
              : (item.purchaseRate * 1.35).toStringAsFixed(2)),
    );
    final customDaysCtrl = TextEditingController(text: (item.customWarrantyDays ?? '').toString());
    final imeiInputCtrl = TextEditingController();

    double selectedGstRate = item.taxPercent > 0 ? item.taxPercent : 18.0;

    bool imeiRequired = item.imeiRequired ||
        item.category.toLowerCase().contains('mobile') ||
        item.category.toLowerCase().contains('phone') ||
        item.name.toLowerCase().contains('phone') ||
        item.name.toLowerCase().contains('smartphone');

    final enteredImeis = List<String>.from(item.serialNumbers);
    String selectedWarranty = item.warrantyDuration.isNotEmpty && item.warrantyDuration != ItemWarrantyDuration.noWarranty
        ? item.warrantyDuration
        : ItemWarrantyDuration.months12;
    bool hasWarranty = item.hasWarranty || selectedWarranty != ItemWarrantyDuration.noWarranty;
    int qty = item.quantity > 0 ? item.quantity : 1;

    final drawerFormKey = GlobalKey<FormState>();

    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Quick Register Product',
      barrierColor: Colors.black.withValues(alpha: 0.65),
      transitionDuration: const Duration(milliseconds: 260),
      transitionBuilder: (ctx, anim1, anim2, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1.0, 0.0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic)),
          child: child,
        );
      },
      pageBuilder: (ctx, anim1, anim2) => StatefulBuilder(
        builder: (context, setDrawerState) {
          final customD = int.tryParse(customDaysCtrl.text);
          final expiry = hasWarranty
              ? PurchaseBillService.instance.calculateItemWarrantyExpiry(
                  _purchaseDate,
                  selectedWarranty,
                  customDays: customD,
                )
              : null;

          final curPurchaseRate = double.tryParse(purchaseRateCtrl.text) ?? item.purchaseRate;
          final curSellingPrice = double.tryParse(sellingPriceCtrl.text) ?? 0.0;
          final curMargin = curSellingPrice - curPurchaseRate;
          final curMarginPercent = curSellingPrice > 0 ? ((curMargin / curSellingPrice) * 100) : 0.0;

          final screenWidth = MediaQuery.of(context).size.width;
          final drawerWidth = screenWidth > 680 ? 620.0 : screenWidth;

          return Align(
            alignment: Alignment.centerRight,
            child: Material(
              color: const Color(0xFF101846),
              elevation: 24,
              borderRadius: BorderRadius.horizontal(
                left: Radius.circular(screenWidth > 680 ? 20 : 0),
              ),
              child: SizedBox(
                width: drawerWidth,
                height: MediaQuery.of(context).size.height,
                child: SafeArea(
                  child: Column(
                    children: [
                      // Drawer Header
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.03),
                          border: const Border(
                            bottom: BorderSide(color: DashboardColors.glassBorder),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: DashboardColors.neonGreen.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.app_registration_rounded, color: DashboardColors.neonGreen, size: 22),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        'Quick Register Product',
                                        style: DashboardTypography.poppins(fontSize: 17, fontWeight: FontWeight.w700),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: DashboardColors.alertOrange.withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          'Row ${itemIndex + 1}',
                                          style: const TextStyle(color: DashboardColors.alertOrange, fontSize: 11, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    item.name,
                                    style: const TextStyle(fontSize: 12, color: DashboardColors.textMuted),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close_rounded, color: DashboardColors.textLight),
                              onPressed: () => Navigator.pop(ctx),
                            ),
                          ],
                        ),
                      ),

                      // Drawer Form Body
                      Expanded(
                        child: Form(
                          key: drawerFormKey,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Product Name
                                _buildDialogTextField(
                                  controller: nameCtrl,
                                  label: 'Product Name *',
                                  icon: Icons.shopping_bag_rounded,
                                  validator: (v) => v == null || v.trim().isEmpty ? 'Enter product name' : null,
                                ),
                                const SizedBox(height: 14),

                                // Category, Brand & Model
                                Row(
                                  children: [
                                    Expanded(
                                      child: _buildDialogTextField(
                                        controller: categoryCtrl,
                                        label: 'Category',
                                        icon: Icons.category_rounded,
                                        onChanged: (cat) {
                                          final isMob = cat.toLowerCase().contains('mobile') ||
                                              cat.toLowerCase().contains('phone') ||
                                              cat.toLowerCase().contains('serial');
                                          if (isMob && !imeiRequired) {
                                            setDrawerState(() => imeiRequired = true);
                                          }
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: _buildDialogTextField(
                                        controller: brandCtrl,
                                        label: 'Brand',
                                        icon: Icons.branding_watermark_rounded,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: _buildDialogTextField(
                                        controller: modelCtrl,
                                        label: 'Model',
                                        icon: Icons.devices_other_rounded,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),

                                // Pricing & MRP with Live Margin Calculator
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.04),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: DashboardColors.glassBorder),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: _buildDialogTextField(
                                              controller: purchaseRateCtrl,
                                              label: 'Purchase Rate (₹) *',
                                              icon: Icons.currency_rupee_rounded,
                                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                              validator: (v) {
                                                final val = double.tryParse(v ?? '');
                                                if (val == null || val <= 0) return 'Enter rate > 0';
                                                return null;
                                              },
                                              onChanged: (_) => setDrawerState(() {}),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: _buildDialogTextField(
                                              controller: sellingPriceCtrl,
                                              label: 'Selling Price (₹) *',
                                              icon: Icons.sell_rounded,
                                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                              validator: (v) {
                                                final p = double.tryParse(v ?? '');
                                                if (p == null || p <= 0) return 'Enter price > 0';
                                                return null;
                                              },
                                              onChanged: (_) => setDrawerState(() {}),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: _buildDialogTextField(
                                              controller: mrpCtrl,
                                              label: 'MRP (₹) *',
                                              icon: Icons.price_check_rounded,
                                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                              validator: (v) {
                                                final m = double.tryParse(v ?? '');
                                                if (m == null || m <= 0) return 'Enter MRP';
                                                final s = double.tryParse(sellingPriceCtrl.text) ?? 0.0;
                                                if (m < s) return 'MRP >= Selling';
                                                return null;
                                              },
                                              onChanged: (_) => setDrawerState(() {}),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            'Gross Margin: ₹${curMargin.toStringAsFixed(2)} (${curMarginPercent.toStringAsFixed(1)}%)',
                                            style: TextStyle(
                                              color: curMargin >= 0 ? DashboardColors.neonGreen : DashboardColors.alertOrange,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Text(
                                            'Selling Price must be <= MRP',
                                            style: TextStyle(
                                              color: curSellingPrice <= (double.tryParse(mrpCtrl.text) ?? curSellingPrice)
                                                  ? DashboardColors.textMuted
                                                  : DashboardColors.alertOrange,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),

                                // GST Tax Presets & HSN Code
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            'GST Rate Presets (%)',
                                            style: TextStyle(color: DashboardColors.textLight, fontSize: 12, fontWeight: FontWeight.w600),
                                          ),
                                          const SizedBox(height: 6),
                                          Wrap(
                                            spacing: 6,
                                            children: [0.0, 5.0, 12.0, 18.0, 28.0].map((rate) {
                                              final isSel = selectedGstRate == rate;
                                              return ChoiceChip(
                                                label: Text('${rate.toInt()}%'),
                                                selected: isSel,
                                                selectedColor: DashboardColors.neonPurple,
                                                backgroundColor: Colors.white.withValues(alpha: 0.05),
                                                labelStyle: TextStyle(
                                                  color: isSel ? Colors.white : Colors.white70,
                                                  fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                                  fontSize: 12,
                                                ),
                                                onSelected: (val) {
                                                  if (val) setDrawerState(() => selectedGstRate = rate);
                                                },
                                              );
                                            }).toList(),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      flex: 2,
                                      child: _buildDialogTextField(
                                        controller: hsnCtrl,
                                        label: 'HSN Code',
                                        icon: Icons.tag_rounded,
                                        hintText: 'e.g. 8517',
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),

                                // Barcode / SKU with TVS LP46 Generator
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: _buildDialogTextField(
                                        controller: barcodeCtrl,
                                        label: 'Barcode / SKU * (TVS LP46 38x25mm Label Ready)',
                                        icon: Icons.qr_code_rounded,
                                        validator: (v) => v == null || v.trim().isEmpty ? 'Enter or generate barcode' : null,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: DashboardColors.neonBlue,
                                          foregroundColor: Colors.black,
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                        icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                                        label: const Text('Generate', style: TextStyle(fontWeight: FontWeight.bold)),
                                        onPressed: () {
                                          final gen = BarcodeLabelService.instance.generateUniqueBarcode();
                                          barcodeCtrl.text = gen;
                                          setDrawerState(() {});
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),

                                // IMEI / Serial Tracking Container
                                Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: imeiRequired
                                        ? DashboardColors.neonBlue.withValues(alpha: 0.08)
                                        : Colors.white.withValues(alpha: 0.03),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: imeiRequired
                                          ? DashboardColors.neonBlue.withValues(alpha: 0.4)
                                          : const Color(0x1AFFFFFF),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.qr_code_scanner_rounded,
                                            color: imeiRequired ? DashboardColors.neonBlue : DashboardColors.textMuted,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                const Text(
                                                  'IMEI / Serial Number Tracking',
                                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                                ),
                                                Text(
                                                  'Requires exactly $qty unique IMEIs for $qty purchased units',
                                                  style: const TextStyle(color: DashboardColors.textMuted, fontSize: 11),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Switch(
                                            value: imeiRequired,
                                            activeColor: DashboardColors.neonBlue,
                                            onChanged: (val) {
                                              setDrawerState(() => imeiRequired = val);
                                            },
                                          ),
                                        ],
                                      ),
                                      if (imeiRequired) ...[
                                        const SizedBox(height: 12),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: TextFormField(
                                                controller: imeiInputCtrl,
                                                style: const TextStyle(color: Colors.white, fontSize: 13),
                                                decoration: InputDecoration(
                                                  hintText: 'Enter IMEI / Serial (e.g. 864501047123456)',
                                                  hintStyle: const TextStyle(color: DashboardColors.textMuted, fontSize: 12),
                                                  filled: true,
                                                  fillColor: Colors.white.withValues(alpha: 0.05),
                                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                                  border: OutlineInputBorder(
                                                    borderRadius: BorderRadius.circular(8),
                                                    borderSide: const BorderSide(color: DashboardColors.glassBorder),
                                                  ),
                                                ),
                                                onFieldSubmitted: (val) {
                                                  final trimmed = val.trim().toUpperCase();
                                                  if (trimmed.isNotEmpty && !enteredImeis.contains(trimmed)) {
                                                    if (enteredImeis.length < qty) {
                                                      setDrawerState(() {
                                                        enteredImeis.add(trimmed);
                                                        imeiInputCtrl.clear();
                                                      });
                                                    } else {
                                                      TekFeedback.error('Already entered $qty IMEIs for $qty items');
                                                    }
                                                  }
                                                },
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            ElevatedButton.icon(
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: DashboardColors.neonGreen,
                                                foregroundColor: Colors.black,
                                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                              ),
                                              icon: const Icon(Icons.add_rounded, size: 16),
                                              label: const Text('Add', style: TextStyle(fontWeight: FontWeight.bold)),
                                              onPressed: () {
                                                final trimmed = imeiInputCtrl.text.trim().toUpperCase();
                                                if (trimmed.isEmpty) return;
                                                if (enteredImeis.contains(trimmed)) {
                                                  TekFeedback.error('IMEI "$trimmed" is already in the list');
                                                  return;
                                                }
                                                if (enteredImeis.length >= qty) {
                                                  TekFeedback.error('Cannot add more than $qty IMEIs');
                                                  return;
                                                }
                                                setDrawerState(() {
                                                  enteredImeis.add(trimmed);
                                                  imeiInputCtrl.clear();
                                                });
                                              },
                                            ),
                                            const SizedBox(width: 8),
                                            OutlinedButton.icon(
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: DashboardColors.neonBlue,
                                                side: const BorderSide(color: DashboardColors.neonBlue),
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                              ),
                                              icon: const Icon(Icons.paste_rounded, size: 16),
                                              label: const Text('Paste List'),
                                              onPressed: () async {
                                                final bulkCtrl = TextEditingController();
                                                final res = await showDialog<String>(
                                                  context: context,
                                                  builder: (bCtx) => AlertDialog(
                                                    backgroundColor: const Color(0xFF101846),
                                                    title: const Text('Paste Multiple IMEIs', style: TextStyle(color: Colors.white)),
                                                    content: TextField(
                                                      controller: bulkCtrl,
                                                      maxLines: 6,
                                                      style: const TextStyle(color: Colors.white),
                                                      decoration: const InputDecoration(
                                                        hintText: 'Paste IMEIs separated by commas, spaces, or newlines...',
                                                        hintStyle: TextStyle(color: DashboardColors.textMuted),
                                                      ),
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () => Navigator.pop(bCtx),
                                                        child: const Text('Cancel'),
                                                      ),
                                                      ElevatedButton(
                                                        onPressed: () => Navigator.pop(bCtx, bulkCtrl.text),
                                                        child: const Text('Add All'),
                                                      ),
                                                    ],
                                                  ),
                                                );

                                                if (res != null && res.trim().isNotEmpty) {
                                                  final tokens = res
                                                      .split(RegExp(r'[\r\n,\s]+'))
                                                      .map((e) => e.trim().toUpperCase())
                                                      .where((e) => e.isNotEmpty);
                                                  setDrawerState(() {
                                                    for (final t in tokens) {
                                                      if (!enteredImeis.contains(t) && enteredImeis.length < qty) {
                                                        enteredImeis.add(t);
                                                      }
                                                    }
                                                  });
                                                }
                                              },
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              'Entered IMEIs (${enteredImeis.length} of $qty required):',
                                              style: TextStyle(
                                                color: enteredImeis.length == qty
                                                    ? DashboardColors.neonGreen
                                                    : DashboardColors.alertOrange,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            if (enteredImeis.isNotEmpty)
                                              TextButton(
                                                onPressed: () => setDrawerState(() => enteredImeis.clear()),
                                                child: const Text('Clear All', style: TextStyle(color: DashboardColors.alertOrange, fontSize: 11)),
                                              ),
                                          ],
                                        ),
                                        if (enteredImeis.isNotEmpty) ...[
                                          const SizedBox(height: 6),
                                          Wrap(
                                            spacing: 6,
                                            runSpacing: 6,
                                            children: enteredImeis.map((imei) {
                                              return Chip(
                                                label: Text(imei, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                                                backgroundColor: DashboardColors.neonBlue.withValues(alpha: 0.15),
                                                deleteIcon: const Icon(Icons.close, size: 14, color: Colors.white70),
                                                onDeleted: () => setDrawerState(() => enteredImeis.remove(imei)),
                                              );
                                            }).toList(),
                                          ),
                                        ],
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),

                                // Supplier Warranty Duration Selection
                                Text('Supplier Warranty Duration', style: DashboardTypography.poppins(fontSize: 14, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    ItemWarrantyDuration.noWarranty,
                                    ItemWarrantyDuration.months3,
                                    ItemWarrantyDuration.months6,
                                    ItemWarrantyDuration.months12,
                                    ItemWarrantyDuration.months24,
                                    ItemWarrantyDuration.custom,
                                  ].map((dur) {
                                    final isSel = selectedWarranty == dur;
                                    return ChoiceChip(
                                      label: Text(dur == ItemWarrantyDuration.noWarranty ? '0 Months (No Warranty)' : dur),
                                      selected: isSel,
                                      selectedColor: DashboardColors.neonBlue,
                                      backgroundColor: Colors.white.withValues(alpha: 0.05),
                                      labelStyle: TextStyle(
                                        color: isSel ? Colors.black : Colors.white,
                                        fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                        fontSize: 12,
                                      ),
                                      onSelected: (sel) {
                                        if (sel) {
                                          setDrawerState(() {
                                            selectedWarranty = dur;
                                            hasWarranty = dur != ItemWarrantyDuration.noWarranty;
                                          });
                                        }
                                      },
                                    );
                                  }).toList(),
                                ),
                                if (selectedWarranty == ItemWarrantyDuration.custom) ...[
                                  const SizedBox(height: 10),
                                  _buildDialogTextField(
                                    controller: customDaysCtrl,
                                    label: 'Custom Duration (Days)',
                                    icon: Icons.calendar_today_rounded,
                                    keyboardType: TextInputType.number,
                                    onChanged: (_) => setDrawerState(() {}),
                                  ),
                                ],
                                if (hasWarranty && expiry != null) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: DashboardColors.neonGreen.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: DashboardColors.neonGreen.withValues(alpha: 0.3)),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.verified_rounded, size: 16, color: DashboardColors.neonGreen),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Auto Expiry: ${DateFormat("dd MMM yyyy").format(expiry)} (from ${DateFormat("dd-MM-yyyy").format(_purchaseDate)})',
                                          style: const TextStyle(color: DashboardColors.neonGreen, fontSize: 12, fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Drawer Footer Actions
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.03),
                          border: const Border(
                            top: BorderSide(color: DashboardColors.glassBorder),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancel', style: TextStyle(color: DashboardColors.textMuted)),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: DashboardColors.neonGreen,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.check_circle_rounded, size: 18),
                              label: const Text('Save & Mark Matched', style: TextStyle(fontWeight: FontWeight.bold)),
                              onPressed: () {
                                if (drawerFormKey.currentState?.validate() != true) return;

                                if (imeiRequired && enteredImeis.length != qty) {
                                  TekFeedback.error('Please enter exactly $qty IMEIs (currently entered ${enteredImeis.length})');
                                  return;
                                }

                                final enteredBarcode = barcodeCtrl.text.trim();
                                if (enteredBarcode.isNotEmpty) {
                                  for (final k in Db.items.keys) {
                                    final raw = Db.items.get(k);
                                    if (raw is Map) {
                                      final b = raw['barcode']?.toString().trim();
                                      final s = raw['sku']?.toString().trim();
                                      final c = raw['code']?.toString().trim();
                                      if ((b == enteredBarcode || s == enteredBarcode || c == enteredBarcode) &&
                                          raw['_id'] != item.matchedProductId) {
                                        TekFeedback.error('Barcode/SKU "$enteredBarcode" already belongs to "${raw['name']}". Please generate or use a unique barcode.');
                                        return;
                                      }
                                    }
                                  }
                                }

                                final rate = double.tryParse(purchaseRateCtrl.text) ?? item.purchaseRate;
                                final sPrice = double.tryParse(sellingPriceCtrl.text) ?? 0.0;
                                final mrpVal = double.tryParse(mrpCtrl.text) ?? (sPrice > 0 ? sPrice : rate);

                                final updated = item.copyWith(
                                  name: nameCtrl.text.trim(),
                                  brand: brandCtrl.text.trim(),
                                  model: modelCtrl.text.trim(),
                                  category: categoryCtrl.text.trim(),
                                  sku: enteredBarcode,
                                  hsnCode: hsnCtrl.text.trim(),
                                  purchaseRate: rate,
                                  sellingPrice: sPrice,
                                  mrp: mrpVal,
                                  taxPercent: selectedGstRate,
                                  imeiRequired: imeiRequired,
                                  serialNumbers: enteredImeis,
                                  imeiOrSerial: enteredImeis.isNotEmpty ? enteredImeis.first : null,
                                  warrantyAvailable: hasWarranty,
                                  warrantyDuration: selectedWarranty,
                                  warrantyExpiryDate: expiry,
                                  isNewProduct: true,
                                  isStagedReady: true,
                                  matchStatusOverride: ProductMatchStatus.matched,
                                  matchNotes: 'Registered via Quick Register',
                                  matchedProductName: nameCtrl.text.trim(),
                                );

                                setState(() {
                                  _items[itemIndex] = updated;
                                });

                                Navigator.pop(ctx);
                                TekFeedback.success('Product "${nameCtrl.text}" saved and marked ready!');
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Product Match Anomaly Resolution Modal (RED STATE)
  // ---------------------------------------------------------------------------

  void _showMatchAnomalyDialog(int itemIndex) {
    if (itemIndex < 0 || itemIndex >= _items.length) return;
    final item = _items[itemIndex];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101846),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: DashboardColors.alertOrange),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: DashboardColors.alertOrange.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.warning_amber_rounded, color: DashboardColors.alertOrange, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Review Required: Product Anomaly',
                    style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'Row #${itemIndex + 1}: ${item.itemName}',
                    style: const TextStyle(fontSize: 12, color: DashboardColors.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: DashboardColors.alertOrange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: DashboardColors.alertOrange.withValues(alpha: 0.4)),
                ),
                child: Text(
                  item.matchNotes ?? 'Rate or catalog anomaly detected. Please verify before continuing.',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'How would you like to resolve this?',
                style: TextStyle(color: DashboardColors.textLight, fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.check_circle_outline_rounded, color: DashboardColors.neonGreen),
                title: const Text('Accept & Override Anomaly', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                subtitle: Text(
                  item.matchedProductName != null
                      ? 'Keep matched to "${item.matchedProductName}" and proceed with invoice rate (₹${item.purchaseRate.toStringAsFixed(2)})'
                      : 'Proceed with current item details',
                  style: const TextStyle(color: DashboardColors.textMuted, fontSize: 11),
                ),
                onTap: () {
                  setState(() {
                    _items[itemIndex] = item.copyWith(
                      matchStatusOverride: ProductMatchStatus.matched,
                      isStagedReady: true,
                    );
                  });
                  Navigator.pop(ctx);
                  TekFeedback.success('Anomaly overridden. Item marked ready.');
                },
              ),
              const Divider(color: Color(0x22FFFFFF)),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.app_registration_rounded, color: DashboardColors.neonBlue),
                title: const Text('Register as Separate / New Product', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                subtitle: const Text('Open Quick Register drawer to stage this as a distinct inventory SKU', style: TextStyle(color: DashboardColors.textMuted, fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showInlineProductRegistrationDialog(itemIndex);
                },
              ),
              const Divider(color: Color(0x22FFFFFF)),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link_rounded, color: DashboardColors.neonOrange),
                title: const Text('Link to a Different Existing Product', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                subtitle: const Text('Search inventory to link this row with another item', style: TextStyle(color: DashboardColors.textMuted, fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAddExistingItemDialog();
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: DashboardColors.textMuted)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Serialized Stock, Dual-IMEI & Supplier Warranty Dialog (PHASE 3)
  // ---------------------------------------------------------------------------

  Widget _buildLuhnBadge(String status, {String labelPrefix = '', bool compact = false}) {
    Color bg;
    Color border;
    Color fg;
    String text;
    IconData icon;

    switch (status) {
      case 'VALID_IMEI':
        bg = DashboardColors.neonGreen.withValues(alpha: 0.15);
        border = DashboardColors.neonGreen.withValues(alpha: 0.4);
        fg = DashboardColors.neonGreen;
        text = 'Luhn OK';
        icon = Icons.verified_rounded;
        break;
      case 'INVALID_LUHN_IMEI':
        bg = DashboardColors.alertOrange.withValues(alpha: 0.2);
        border = DashboardColors.alertOrange.withValues(alpha: 0.5);
        fg = DashboardColors.alertOrange;
        text = 'Invalid Luhn';
        icon = Icons.warning_amber_rounded;
        break;
      case 'DEVICE_SERIAL':
        bg = DashboardColors.neonBlue.withValues(alpha: 0.15);
        border = DashboardColors.neonBlue.withValues(alpha: 0.4);
        fg = DashboardColors.neonBlue;
        text = 'Device Serial';
        icon = Icons.tag_rounded;
        break;
      default:
        return const SizedBox.shrink();
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: compact ? 2 : 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 10 : 12, color: fg),
          const SizedBox(width: 4),
          Text('$labelPrefix$text', style: TextStyle(color: fg, fontSize: compact ? 10 : 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Future<void> _addSerializedUnit(
    void Function(void Function()) setDialogState,
    List<String> enteredUnits,
    TextEditingController imei1Ctrl,
    TextEditingController imei2Ctrl,
    bool isDualImei,
    int qty,
    int itemIndex,
  ) async {
    final im1 = imei1Ctrl.text.trim().toUpperCase();
    final im2 = imei2Ctrl.text.trim().toUpperCase();

    if (im1.isEmpty) {
      TekFeedback.error('Please enter IMEI 1 / Serial Number');
      return;
    }

    if (enteredUnits.length >= qty) {
      TekFeedback.error('Already entered required $qty units for this row');
      return;
    }

    final newImeis = isDualImei ? [im1, if (im2.isNotEmpty) im2] : [im1];

    // Check duplicate within currently entered units
    for (final u in enteredUnits) {
      final existing = ImeiValidator.extractImeisFromUnit(u);
      for (final n in newImeis) {
        if (existing.contains(n)) {
          TekFeedback.error('IMEI "$n" is already in this list');
          return;
        }
      }
    }

    // Check duplicate across all other items in current bill
    for (int i = 0; i < _items.length; i++) {
      if (i != itemIndex) {
        for (final u in _items[i].serialNumbers) {
          final existing = ImeiValidator.extractImeisFromUnit(u);
          for (final n in newImeis) {
            if (existing.contains(n)) {
              TekFeedback.error('IMEI "$n" is already entered in Row #${i + 1} (${_items[i].itemName})');
              return;
            }
          }
        }
      }
    }

    // Check against Firestore stock_units in stock
    try {
      final inStockDup = await PurchaseBillService.instance.checkDuplicateImeisInStock(newImeis);
      if (inStockDup.isNotEmpty) {
        TekFeedback.error('Warning: IMEI "${inStockDup.first}" is already IN_STOCK in inventory!');
        return;
      }
    } catch (_) {}

    final formatted = isDualImei ? ImeiValidator.formatDualImei(im1, im2.isNotEmpty ? im2 : null) : im1;

    setDialogState(() {
      enteredUnits.add(formatted);
      imei1Ctrl.clear();
      imei2Ctrl.clear();
    });
  }

  Future<void> _handleBulkImeiPaste(
    void Function(void Function()) setDialogState,
    List<String> enteredUnits,
    int qty,
    bool isDualImei,
    int itemIndex,
  ) async {
    final bulkCtrl = TextEditingController();
    final res = await showDialog<String>(
      context: context,
      builder: (bCtx) => AlertDialog(
        backgroundColor: const Color(0xFF101846),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: DashboardColors.glassBorderHover),
        ),
        title: const Text('Bulk Paste IMEIs / Serials', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isDualImei
                    ? 'Paste one unit per line. For Dual-SIM, separate IMEI 1 and IMEI 2 with a comma, slash, or tab.'
                    : 'Paste IMEIs separated by newlines, commas, or spaces.',
                style: const TextStyle(color: DashboardColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: bulkCtrl,
                maxLines: 8,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  hintText: '864501047123456\n864501047123458, 864501047123459\n...',
                  hintStyle: TextStyle(color: DashboardColors.textMuted),
                  filled: true,
                  fillColor: Color(0x1AFFFFFF),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(bCtx),
            child: const Text('Cancel', style: TextStyle(color: DashboardColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: DashboardColors.neonGreen,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(bCtx, bulkCtrl.text),
            child: const Text('Add All Units', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (res != null && res.trim().isNotEmpty) {
      final lines = res.split(RegExp(r'[\r\n]+')).map((e) => e.trim()).where((e) => e.isNotEmpty);
      setDialogState(() {
        for (final line in lines) {
          if (enteredUnits.length >= qty) break;
          final imeis = ImeiValidator.extractImeisFromUnit(line);
          if (imeis.isEmpty) continue;
          final formatted = isDualImei && imeis.length >= 2
              ? ImeiValidator.formatDualImei(imeis[0], imeis[1])
              : imeis.first;
          if (!enteredUnits.contains(formatted)) {
            enteredUnits.add(formatted);
          }
        }
      });
    }
  }

  void _showImeiSerialEntryDialog(int itemIndex) {
    if (itemIndex < 0 || itemIndex >= _items.length) return;
    final item = _items[itemIndex];

    bool imeiRequired = item.imeiRequired;
    bool isDualImei = false;

    final imei1Ctrl = TextEditingController();
    final imei2Ctrl = TextEditingController();
    final customDaysCtrl = TextEditingController(text: (item.customWarrantyDays ?? '').toString());

    final enteredUnits = List<String>.from(item.serialNumbers);

    if (enteredUnits.any((u) => u.contains('/'))) {
      isDualImei = true;
    }

    String selectedWarranty = item.warrantyDuration.isNotEmpty && item.warrantyDuration != ItemWarrantyDuration.noWarranty
        ? item.warrantyDuration
        : ItemWarrantyDuration.months12;
    bool hasWarranty = item.hasWarranty || selectedWarranty != ItemWarrantyDuration.noWarranty;
    int qty = item.quantity > 0 ? item.quantity : 1;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final customD = int.tryParse(customDaysCtrl.text);
          final expiry = hasWarranty
              ? PurchaseBillService.instance.calculateItemWarrantyExpiry(
                  _purchaseDate,
                  selectedWarranty,
                  customDays: customD,
                )
              : null;

          final imei1Text = imei1Ctrl.text.trim();
          final imei2Text = imei2Ctrl.text.trim();
          final imei1Status = ImeiValidator.categorizeIdentifier(imei1Text);
          final imei2Status = ImeiValidator.categorizeIdentifier(imei2Text);

          return AlertDialog(
            backgroundColor: const Color(0xFF101846),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: DashboardColors.glassBorderHover),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: DashboardColors.neonBlue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.qr_code_scanner_rounded, color: DashboardColors.neonBlue, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Serialized Stock & Supplier Warranty',
                        style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'Row #${itemIndex + 1}: ${item.itemName} (Requires $qty unique units)',
                        style: const TextStyle(fontSize: 12, color: DashboardColors.textMuted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 580,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Tracking Mode & Dual-SIM Toggles
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: DashboardColors.glassBorder),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.inventory_2_rounded, size: 18, color: DashboardColors.neonBlue),
                                  SizedBox(width: 8),
                                  Text(
                                    'Enable Serial / IMEI Tracking',
                                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                ],
                              ),
                              Switch(
                                value: imeiRequired,
                                activeColor: DashboardColors.neonBlue,
                                onChanged: (val) {
                                  setDialogState(() => imeiRequired = val);
                                },
                              ),
                            ],
                          ),
                          if (imeiRequired) ...[
                            const Divider(color: Color(0x1AFFFFFF)),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Row(
                                  children: [
                                    Icon(Icons.sim_card_rounded, size: 18, color: DashboardColors.neonPurple),
                                    SizedBox(width: 8),
                                    Text(
                                      'Dual-SIM Device (IMEI 1 & IMEI 2)',
                                      style: TextStyle(color: Colors.white70, fontSize: 12.5),
                                    ),
                                  ],
                                ),
                                Switch(
                                  value: isDualImei,
                                  activeColor: DashboardColors.neonPurple,
                                  onChanged: (val) {
                                    setDialogState(() => isDualImei = val);
                                  },
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    if (imeiRequired) ...[
                      // Input Form for Unit
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: DashboardColors.neonBlue.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: DashboardColors.neonBlue.withValues(alpha: 0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: imei1Ctrl,
                                    style: const TextStyle(color: Colors.white, fontSize: 13),
                                    decoration: InputDecoration(
                                      labelText: isDualImei ? 'Primary IMEI (IMEI 1) *' : 'IMEI / Serial Number *',
                                      labelStyle: const TextStyle(color: DashboardColors.textMuted, fontSize: 12),
                                      hintText: 'e.g. 864501047123456',
                                      hintStyle: const TextStyle(color: DashboardColors.textMuted, fontSize: 11),
                                      filled: true,
                                      fillColor: Colors.white.withValues(alpha: 0.05),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: const BorderSide(color: DashboardColors.glassBorder),
                                      ),
                                    ),
                                    onChanged: (_) => setDialogState(() {}),
                                    onFieldSubmitted: (_) async {
                                      await _addSerializedUnit(
                                        setDialogState,
                                        enteredUnits,
                                        imei1Ctrl,
                                        imei2Ctrl,
                                        isDualImei,
                                        qty,
                                        itemIndex,
                                      );
                                    },
                                  ),
                                ),
                                if (isDualImei) ...[
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextFormField(
                                      controller: imei2Ctrl,
                                      style: const TextStyle(color: Colors.white, fontSize: 13),
                                      decoration: InputDecoration(
                                        labelText: 'Secondary IMEI (IMEI 2) [Optional]',
                                        labelStyle: const TextStyle(color: DashboardColors.textMuted, fontSize: 12),
                                        hintText: 'e.g. 864501047123457',
                                        hintStyle: const TextStyle(color: DashboardColors.textMuted, fontSize: 11),
                                        filled: true,
                                        fillColor: Colors.white.withValues(alpha: 0.05),
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(8),
                                          borderSide: const BorderSide(color: DashboardColors.glassBorder),
                                        ),
                                      ),
                                      onChanged: (_) => setDialogState(() {}),
                                      onFieldSubmitted: (_) async {
                                        await _addSerializedUnit(
                                          setDialogState,
                                          enteredUnits,
                                          imei1Ctrl,
                                          imei2Ctrl,
                                          isDualImei,
                                          qty,
                                          itemIndex,
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 8),

                            // Real-time Luhn Checksum Badges
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    if (imei1Text.isNotEmpty) _buildLuhnBadge(imei1Status, labelPrefix: isDualImei ? 'IMEI 1: ' : ''),
                                    if (isDualImei && imei2Text.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      _buildLuhnBadge(imei2Status, labelPrefix: 'IMEI 2: '),
                                    ],
                                  ],
                                ),
                                Row(
                                  children: [
                                    OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: DashboardColors.neonBlue,
                                        side: const BorderSide(color: DashboardColors.neonBlue),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      icon: const Icon(Icons.paste_rounded, size: 14),
                                      label: const Text('Bulk Paste', style: TextStyle(fontSize: 12)),
                                      onPressed: () async {
                                        await _handleBulkImeiPaste(setDialogState, enteredUnits, qty, isDualImei, itemIndex);
                                      },
                                    ),
                                    const SizedBox(width: 8),
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: DashboardColors.neonGreen,
                                        foregroundColor: Colors.black,
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      icon: const Icon(Icons.add_rounded, size: 16),
                                      label: const Text('Add Unit', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                      onPressed: () async {
                                        await _addSerializedUnit(
                                          setDialogState,
                                          enteredUnits,
                                          imei1Ctrl,
                                          imei2Ctrl,
                                          isDualImei,
                                          qty,
                                          itemIndex,
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Entered Units List
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Entered Units: ${enteredUnits.length} of $qty required',
                            style: TextStyle(
                              color: enteredUnits.length == qty ? DashboardColors.neonGreen : DashboardColors.alertOrange,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          if (enteredUnits.isNotEmpty)
                            TextButton(
                              onPressed: () => setDialogState(() => enteredUnits.clear()),
                              child: const Text('Clear All', style: TextStyle(color: DashboardColors.alertOrange, fontSize: 11)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (enteredUnits.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.02),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0x1AFFFFFF)),
                          ),
                          child: const Center(
                            child: Text('No IMEIs entered yet. Enter above or use Bulk Paste.',
                                style: TextStyle(color: DashboardColors.textMuted, fontSize: 12)),
                          ),
                        )
                      else
                        Container(
                          constraints: const BoxConstraints(maxHeight: 180),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.03),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: DashboardColors.glassBorder),
                          ),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: enteredUnits.length,
                            separatorBuilder: (_, __) => const Divider(color: Color(0x1AFFFFFF), height: 8),
                            itemBuilder: (context, uIdx) {
                              final u = enteredUnits[uIdx];
                              final imeis = ImeiValidator.extractImeisFromUnit(u);
                              return Row(
                                children: [
                                  Container(
                                    width: 24,
                                    height: 24,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: DashboardColors.neonBlue.withValues(alpha: 0.15),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text('${uIdx + 1}',
                                        style: const TextStyle(color: DashboardColors.neonBlue, fontSize: 11, fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      children: [
                                        Text(u, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                                        ...imeis.map((im) {
                                          final cat = ImeiValidator.categorizeIdentifier(im);
                                          return _buildLuhnBadge(cat, compact: true);
                                        }),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close_rounded, size: 16, color: DashboardColors.alertOrange),
                                    onPressed: () => setDialogState(() => enteredUnits.removeAt(uIdx)),
                                    tooltip: 'Remove',
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      const SizedBox(height: 16),
                    ],

                    // Supplier Warranty Duration
                    Text('Supplier Warranty Duration', style: DashboardTypography.poppins(fontSize: 14, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ItemWarrantyDuration.noWarranty,
                        ItemWarrantyDuration.months3,
                        ItemWarrantyDuration.months6,
                        ItemWarrantyDuration.months12,
                        ItemWarrantyDuration.months24,
                        ItemWarrantyDuration.custom,
                      ].map((dur) {
                        final isSel = selectedWarranty == dur;
                        return ChoiceChip(
                          label: Text(dur == ItemWarrantyDuration.noWarranty ? '0 Months (No Warranty)' : dur),
                          selected: isSel,
                          selectedColor: DashboardColors.neonBlue,
                          backgroundColor: Colors.white.withValues(alpha: 0.05),
                          labelStyle: TextStyle(
                            color: isSel ? Colors.black : Colors.white,
                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                            fontSize: 12,
                          ),
                          onSelected: (sel) {
                            if (sel) {
                              setDialogState(() {
                                selectedWarranty = dur;
                                hasWarranty = dur != ItemWarrantyDuration.noWarranty;
                              });
                            }
                          },
                        );
                      }).toList(),
                    ),
                    if (selectedWarranty == ItemWarrantyDuration.custom) ...[
                      const SizedBox(height: 10),
                      _buildDialogTextField(
                        controller: customDaysCtrl,
                        label: 'Custom Duration (Days)',
                        icon: Icons.calendar_today_rounded,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setDialogState(() {}),
                      ),
                    ],
                    if (hasWarranty && expiry != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: DashboardColors.neonGreen.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: DashboardColors.neonGreen.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.verified_rounded, size: 16, color: DashboardColors.neonGreen),
                            const SizedBox(width: 8),
                            Text(
                              'Auto Expiry: ${DateFormat("dd MMM yyyy").format(expiry)} (from ${DateFormat("dd-MM-yyyy").format(_purchaseDate)})',
                              style: const TextStyle(color: DashboardColors.neonGreen, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel', style: TextStyle(color: DashboardColors.textMuted)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: DashboardColors.neonGreen,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.check_circle_rounded, size: 18),
                label: const Text('Save & Apply', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () {
                  if (imeiRequired && enteredUnits.length != qty) {
                    TekFeedback.error('Please enter exactly $qty unique IMEIs for $qty units (currently entered ${enteredUnits.length})');
                    return;
                  }

                  final updated = item.copyWith(
                    imeiRequired: imeiRequired,
                    serialNumbers: enteredUnits,
                    imeiOrSerial: enteredUnits.isNotEmpty ? enteredUnits.first : null,
                    warrantyAvailable: hasWarranty,
                    warrantyDuration: selectedWarranty,
                    customWarrantyDays: customD,
                    warrantyExpiryDate: expiry,
                  );

                  setState(() {
                    _items[itemIndex] = updated;
                  });

                  Navigator.pop(ctx);
                  TekFeedback.success('Serial/IMEI settings updated for "${item.itemName}"!');
                },
              ),
            ],
          );
        },
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
    final existingDbItem = (itemKey != null && Db.items.containsKey(itemKey))
        ? Db.items.get(itemKey)
        : null;
    final isDbMultiUnit = (existingDbItem is Map && existingDbItem['isMultiUnit'] == true) ||
        name.toLowerCase().contains('paper') ||
        name.toLowerCase().contains('a4') ||
        (category?.toLowerCase().contains('consumable') ?? false);

    bool isMultiUnit = existingItem?.isMultiUnit ?? isDbMultiUnit;
    final purchaseUnitCtrl = TextEditingController(
        text: existingItem?.purchaseUnit ??
            (existingDbItem is Map ? existingDbItem['purchaseUnit']?.toString() : null) ??
            'Bundle');
    final baseUnitCtrl = TextEditingController(
        text: existingItem?.baseUnit ??
            (existingDbItem is Map ? existingDbItem['baseUnit']?.toString() : null) ??
            'Sheet');
    final convFactorCtrl = TextEditingController(
        text: (existingItem?.conversionFactor ??
                (existingDbItem is Map ? existingDbItem['conversionFactor'] : null) ??
                500)
            .toString());

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

          final factor = int.tryParse(convFactorCtrl.text) ?? 500;
          final totalBaseUnits = q * (factor > 0 ? factor : 1);
          final effCostPerBase = factor > 0 ? (r / factor) : r;
          final pUnit = purchaseUnitCtrl.text.trim().isEmpty ? 'Bundle' : purchaseUnitCtrl.text.trim();
          final bUnit = baseUnitCtrl.text.trim().isEmpty ? 'Sheet' : baseUnitCtrl.text.trim();

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
              width: 560,
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
                    const SizedBox(height: 12),

                    // SECTION: MULTI-UNIT CONVERSION CONFIGURATION
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isMultiUnit
                            ? DashboardColors.neonBlue.withValues(alpha: 0.1)
                            : Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isMultiUnit
                              ? DashboardColors.neonBlue.withValues(alpha: 0.35)
                              : Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                isMultiUnit
                                    ? Icons.layers_rounded
                                    : Icons.layers_outlined,
                                size: 18,
                                color: isMultiUnit
                                    ? DashboardColors.neonBlue
                                    : DashboardColors.textMuted,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Multi-Unit Consumable (e.g., Paper Bundles → Sheets)',
                                  style: TextStyle(
                                    color: isMultiUnit
                                        ? Colors.white
                                        : DashboardColors.textLight,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Switch(
                                value: isMultiUnit,
                                activeColor: DashboardColors.neonBlue,
                                onChanged: (val) {
                                  setDialogState(() => isMultiUnit = val);
                                },
                              ),
                            ],
                          ),
                          if (isMultiUnit) ...[
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: _buildDialogTextField(
                                    controller: purchaseUnitCtrl,
                                    label: 'Purchase Unit (e.g. Bundle)',
                                    icon: Icons.inventory_2_outlined,
                                    onChanged: (_) => setDialogState(() {}),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _buildDialogTextField(
                                    controller: baseUnitCtrl,
                                    label: 'Base Unit (e.g. Sheet)',
                                    icon: Icons.description_outlined,
                                    onChanged: (_) => setDialogState(() {}),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _buildDialogTextField(
                                    controller: convFactorCtrl,
                                    label: 'Ratio (1 Bundle = X Sheets)',
                                    icon: Icons.numbers_rounded,
                                    keyboardType: TextInputType.number,
                                    onChanged: (_) => setDialogState(() {}),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Qty & Rate
                    Row(
                      children: [
                        Expanded(
                          child: _buildDialogTextField(
                            controller: qtyCtrl,
                            label: isMultiUnit ? 'Quantity ($pUnit) *' : 'Quantity *',
                            icon: Icons.numbers_rounded,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildDialogTextField(
                            controller: rateCtrl,
                            label: isMultiUnit
                                ? 'Purchase Rate (₹ per $pUnit) *'
                                : 'Purchase Rate (₹) *',
                            icon: Icons.currency_rupee_rounded,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // REAL-TIME MULTI-UNIT CONVERSION PREVIEW CARD
                    if (isMultiUnit) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: DashboardColors.neonBlue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: DashboardColors.neonBlue.withValues(alpha: 0.4)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.calculate_rounded,
                                    size: 16, color: DashboardColors.neonBlue),
                                const SizedBox(width: 6),
                                Text(
                                  'Conversion: 1 $pUnit = $factor ${bUnit}s',
                                  style: const TextStyle(
                                      color: DashboardColors.neonBlue,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Total ${bUnit}s: ${NumberFormat("#,##0").format(totalBaseUnits)} ${bUnit}s | Effective Cost per $bUnit: ₹${effCostPerBase.toStringAsFixed(3)}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Line Total: $q × ₹${r.toStringAsFixed(2)} = ₹${(q * r).toStringAsFixed(2)}',
                              style: const TextStyle(
                                  color: DashboardColors.textLight,
                                  fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

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
                    isMultiUnit: isMultiUnit,
                    purchaseUnit: purchaseUnitCtrl.text.trim().isNotEmpty
                        ? purchaseUnitCtrl.text.trim()
                        : 'Bundle',
                    baseUnit: baseUnitCtrl.text.trim().isNotEmpty
                        ? baseUnitCtrl.text.trim()
                        : 'Sheet',
                    conversionFactor: int.tryParse(convFactorCtrl.text.trim()) ?? 500,
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
    if (_isSaving) return; // Prevent double submit / debounced
    if (_formKey.currentState?.validate() != true) return;

    if (_selectedVendorKey == null && _selectedVendorName.trim().isEmpty) {
      TekFeedback.error('Please select or create a vendor');
      return;
    }

    if (_items.isEmpty) {
      TekFeedback.error('Please add at least one item to the purchase bill');
      return;
    }

    if (!isDraft) {
      // Validate that all review required anomalies are resolved
      final reviewAnomaly = _items.indexWhere(
          (it) => it.matchStatus == ProductMatchStatus.reviewRequired);
      if (reviewAnomaly != -1) {
        TekFeedback.error(
            'Item "${_items[reviewAnomaly].itemName}" has a review-required anomaly. Please resolve before confirming');
        _showMatchAnomalyDialog(reviewAnomaly);
        return;
      }

      // Validate that all new items are registered
      final unconfigured =
          _items.indexWhere((it) => it.isNewProduct && !it.isStagedReady);
      if (unconfigured != -1) {
        TekFeedback.error(
            'Item "${_items[unconfigured].itemName}" is new and must be registered before confirming');
        _showInlineProductRegistrationDialog(unconfigured);
        return;
      }

      // Validate IMEI/Serial tracking exact counts
      final missingImei = _items.indexWhere(
          (it) => it.imeiRequired && it.serialNumbers.length != it.quantity);
      if (missingImei != -1) {
        TekFeedback.error(
            'Item "${_items[missingImei].itemName}" requires exactly ${_items[missingImei].quantity} IMEIs (${_items[missingImei].serialNumbers.length} entered)');
        _showInlineProductRegistrationDialog(missingImei);
        return;
      }
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
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text(
          isDraft
              ? 'Draft bills will be saved without increasing inventory or vendor debt.'
              : 'Saving this purchase bill will atomically increase inventory stock, register IMEI units in Cloud Firestore, record stock movements, and update vendor balances.\n\nGrand Total: ₹${_grandTotal.toStringAsFixed(2)}\nAmount Paid: ₹${_safePaidAmount.toStringAsFixed(2)}\nBalance Due: ₹${_remainingBalance.toStringAsFixed(2)}',
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

    setState(() {
      _isSaving = true;
      if (!isDraft) {
        _flowState = PurchaseBillFlowState.confirming;
      }
    });

    try {
      final combinedPurchaseDate = DateTime(
        _purchaseDate.year,
        _purchaseDate.month,
        _purchaseDate.day,
        _purchaseTime.hour,
        _purchaseTime.minute,
      );

      PurchaseBill saved;

      if (!isDraft) {
        // Atomic Firestore confirmation with reads-before-writes
        saved = await PurchaseBillService.instance.confirmPurchaseBill(
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
          attachmentBytes: _attachmentBytes,
          staffId: auth.uid,
          staffName: auth.name.isNotEmpty ? auth.name : 'Owner',
          notes: _notesCtrl.text.trim(),
          invoiceExtractedTotal: _invoiceExtractedTotal,
        );

        _flowState = PurchaseBillFlowState.confirmed;
        TekFeedback.success(
            'Purchase Bill confirmed & Firestore stock synced (${saved.billNumber})');
      } else {
        // Save as local draft
        saved = await PurchaseBillService.instance.savePurchaseBill(
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
          isDraft: true,
        );
        TekFeedback.success(
            'Purchase Bill saved as draft (${saved.billNumber})');
      }

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
                const Icon(Icons.check_circle_rounded,
                    color: DashboardColors.neonGreen, size: 28),
                const SizedBox(width: 12),
                Text(
                  isDraft ? 'Draft Bill Saved!' : 'Purchase Bill Confirmed!',
                  style: DashboardTypography.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
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
                      : 'Purchase bill "${saved.billNumber}" confirmed successfully.\nInventory stock and IMEI units atomically synced to Cloud Firestore for ${saved.items.length} items (${saved.totalQuantity} total qty).',
                  style: const TextStyle(
                      color: DashboardColors.textLight, fontSize: 13.5),
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
                      const Icon(Icons.print_rounded,
                          color: DashboardColors.neonBlue, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'TVS LP 46 Lite Barcode Printer:\nPrint ${saved.totalQuantity} stickers (38 mm × 25 mm Code 128)',
                          style: const TextStyle(
                              color: DashboardColors.neonBlue,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600),
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
                child: const Text('View Bill Details',
                    style: TextStyle(color: DashboardColors.textMuted)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: DashboardColors.neonGreen,
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.qr_code_2_rounded,
                    size: 18, color: Colors.black),
                label: const Text(
                  'Print Barcode Labels',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.black),
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
      if (!isDraft) {
        _flowState = PurchaseBillFlowState.failed;
      }
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
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  color: Colors.black, strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_rounded,
                              color: Colors.black),
                      label: Text(
                        _isSaving
                            ? 'Syncing to Cloud...'
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
          if (_flowState == PurchaseBillFlowState.uploading ||
              _flowState == PurchaseBillFlowState.parsing) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: DashboardColors.neonBlue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: DashboardColors.neonBlue.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: DashboardColors.neonBlue),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _flowState == PurchaseBillFlowState.uploading
                          ? 'Uploading document to secure storage...'
                          : 'Extracting invoice data, items & auto-matching inventory...',
                      style: const TextStyle(
                          color: DashboardColors.neonBlue,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_showExtractionBanner && _extractionStatusBanner != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: DashboardColors.neonGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: DashboardColors.neonGreen.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome_rounded,
                      color: DashboardColors.neonGreen, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _extractionStatusBanner!,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        size: 18, color: DashboardColors.textMuted),
                    tooltip: 'Dismiss',
                    onPressed: () =>
                        setState(() => _showExtractionBanner = false),
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
            onChanged: (key) async {
              final found = vendors.firstWhere((v) => v['key'] == key,
                  orElse: () => {});
              if (found.isNotEmpty) {
                final balPaise = await PurchaseBillService.instance
                    .fetchVendorBalancePaise(key);
                setState(() {
                  _selectedVendorKey = key;
                  _selectedVendorName = found['name'];
                  _selectedVendorPhone = found['phone'];
                  _selectedVendorAddress = found['address'] ?? '';
                  _selectedVendorGst = found['gst'] ?? '';
                  _vendorPrevBalance = balPaise / 100.0;
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
                columnSpacing: 18,
                columns: const [
                  DataColumn(
                      label: Text('#',
                          style: TextStyle(
                              color: DashboardColors.textMuted,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Item Description',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Model / HSN',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Product Match Status',
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
                      label: Text('GST % / Tax',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('Line Total',
                          style: TextStyle(
                              color: DashboardColors.neonGreen,
                              fontWeight: FontWeight.bold))),
                  DataColumn(
                      label: Text('IMEI / Serial',
                          style: TextStyle(
                              color: Colors.white,
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
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(it.itemName,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600)),
                              if (it.brand.isNotEmpty || it.category.isNotEmpty)
                                Text(
                                  '${it.brand.isNotEmpty ? it.brand : ''} ${it.category.isNotEmpty ? '• ${it.category}' : ''}'
                                      .trim(),
                                  style: const TextStyle(
                                      color: DashboardColors.textMuted,
                                      fontSize: 11),
                                ),
                            ],
                          ),
                        ),
                      ),
                      DataCell(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              it.model.isNotEmpty ? it.model : (it.productCode.isNotEmpty ? it.productCode : '-'),
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                            if (it.hsnCode.isNotEmpty)
                              Text('HSN: ${it.hsnCode}',
                                  style: const TextStyle(
                                      color: DashboardColors.textMuted, fontSize: 10)),
                          ],
                        ),
                      ),
                      DataCell(
                        () {
                          final status = it.matchStatus;
                          if (status == ProductMatchStatus.matched) {
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: DashboardColors.neonGreen.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                    color: DashboardColors.neonGreen.withValues(alpha: 0.4)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.check_circle_rounded,
                                      size: 12, color: DashboardColors.neonGreen),
                                  const SizedBox(width: 5),
                                  Text(
                                    it.isNewProduct
                                        ? 'Ready to Register (MRP ₹${it.sellingPrice.toStringAsFixed(0)})'
                                        : 'Matched to ${it.matchedProductName ?? it.itemName}',
                                    style: const TextStyle(
                                        color: DashboardColors.neonGreen,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            );
                          } else if (status == ProductMatchStatus.quickRegister) {
                            return InkWell(
                              onTap: () => _showInlineProductRegistrationDialog(idx),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: DashboardColors.alertOrange.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: DashboardColors.alertOrange),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.add_circle_outline_rounded,
                                        size: 12, color: DashboardColors.alertOrange),
                                    SizedBox(width: 5),
                                    Text(
                                      'New Item: + Quick Register',
                                      style: TextStyle(
                                          color: DashboardColors.alertOrange,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          } else {
                            // ProductMatchStatus.reviewRequired
                            return InkWell(
                              onTap: () => _showMatchAnomalyDialog(idx),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: DashboardColors.alertRed.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: DashboardColors.alertRed),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.warning_amber_rounded,
                                        size: 12, color: DashboardColors.alertRed),
                                    SizedBox(width: 5),
                                    Text(
                                      'Review Required: Anomaly',
                                      style: TextStyle(
                                          color: DashboardColors.alertRed,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                        }(),
                      ),
                      DataCell(
                        InkWell(
                          onTap: () => _showImeiSerialEntryDialog(idx),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: it.imeiRequired
                                  ? (it.serialNumbers.length == it.quantity
                                      ? DashboardColors.neonGreen
                                          .withValues(alpha: 0.15)
                                      : DashboardColors.alertOrange
                                          .withValues(alpha: 0.2))
                                  : Colors.white.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: it.imeiRequired
                                      ? (it.serialNumbers.length == it.quantity
                                          ? DashboardColors.neonGreen
                                          : DashboardColors.alertOrange)
                                      : const Color(0x22FFFFFF)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  it.imeiRequired
                                      ? (it.serialNumbers.length == it.quantity
                                          ? Icons.check_circle_rounded
                                          : Icons.qr_code_scanner_rounded)
                                      : Icons.tag_rounded,
                                  size: 13,
                                  color: it.imeiRequired
                                      ? (it.serialNumbers.length == it.quantity
                                          ? DashboardColors.neonGreen
                                          : DashboardColors.alertOrange)
                                      : DashboardColors.textMuted,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  it.imeiRequired
                                      ? 'IMEIs: ${it.serialNumbers.length}/${it.quantity}'
                                      : (it.imeiOrSerial.isNotEmpty
                                          ? it.imeiOrSerial
                                          : '+ Track IMEI'),
                                  style: TextStyle(
                                    color: it.imeiRequired
                                        ? (it.serialNumbers.length == it.quantity
                                            ? DashboardColors.neonGreen
                                            : DashboardColors.alertOrange)
                                        : DashboardColors.textLight,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      DataCell(Text(
                          it.isMultiUnit
                              ? '${it.quantity} ${it.purchaseUnit}s\n(${NumberFormat("#,##0").format(it.baseQuantity)} ${it.baseUnit}s)'
                              : '${it.quantity}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold))),
                      DataCell(Text(
                          it.isMultiUnit
                              ? '₹${it.purchaseRate.toStringAsFixed(2)}/${it.purchaseUnit}\n(₹${it.effectiveUnitCost.toStringAsFixed(3)}/${it.baseUnit})'
                              : '₹${it.purchaseRate.toStringAsFixed(2)}',
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
                        InkWell(
                          onTap: () => _showImeiSerialEntryDialog(idx),
                          child: Container(
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
                              icon: Icon(
                                it.matchStatus == ProductMatchStatus.reviewRequired
                                    ? Icons.warning_amber_rounded
                                    : (it.isNewProduct && !it.isStagedReady
                                        ? Icons.app_registration_rounded
                                        : Icons.edit_rounded),
                                color: it.matchStatus == ProductMatchStatus.reviewRequired
                                    ? DashboardColors.alertRed
                                    : (it.isNewProduct && !it.isStagedReady
                                        ? DashboardColors.alertOrange
                                        : DashboardColors.neonBlue),
                                size: 18,
                              ),
                              tooltip: it.matchStatus == ProductMatchStatus.reviewRequired
                                  ? 'Review Anomaly'
                                  : (it.isNewProduct
                                      ? 'Register / Edit Product'
                                      : 'Edit Item'),
                              onPressed: () {
                                if (it.matchStatus == ProductMatchStatus.reviewRequired) {
                                  _showMatchAnomalyDialog(idx);
                                } else if (it.isNewProduct) {
                                  _showInlineProductRegistrationDialog(idx);
                                } else {
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
                                }
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
              // GST Mode & Round Off Controls
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: DashboardColors.glassBorder),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _isInterStateGst ? 'Inter-State (IGST)' : 'Intra-State (CGST+SGST)',
                          style: TextStyle(
                            color: _isInterStateGst ? DashboardColors.neonPurple : DashboardColors.neonBlue,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Switch(
                          value: _isInterStateGst,
                          activeColor: DashboardColors.neonPurple,
                          inactiveThumbColor: DashboardColors.neonBlue,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onChanged: (val) => setState(() => _isInterStateGst = val),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: DashboardColors.glassBorder),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Round Off',
                          style: TextStyle(color: DashboardColors.textLight, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 4),
                        Checkbox(
                          value: _applyRoundOff,
                          activeColor: DashboardColors.neonGreen,
                          checkColor: Colors.black,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onChanged: (val) => setState(() => _applyRoundOff = val ?? true),
                        ),
                      ],
                    ),
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
                    if (!_isInterStateGst) ...[
                      _buildCalcCard('CGST (50%)', '+ ₹${_cgst.toStringAsFixed(2)}',
                          Icons.receipt_rounded, DashboardColors.neonBlue),
                      _buildCalcCard('SGST (50%)', '+ ₹${_sgst.toStringAsFixed(2)}',
                          Icons.receipt_long_rounded, DashboardColors.neonBlue),
                    ] else ...[
                      _buildCalcCard('IGST (100%)', '+ ₹${_igst.toStringAsFixed(2)}',
                          Icons.receipt_rounded, DashboardColors.neonPurple),
                    ],
                    if (_applyRoundOff && _roundOff.abs() > 0.001)
                      _buildCalcCard(
                        'Round Off',
                        '${_roundOff >= 0 ? '+' : '-'} ₹${_roundOff.abs().toStringAsFixed(2)}',
                        Icons.exposure_rounded,
                        DashboardColors.neonGreen,
                      ),
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
                      if (_applyRoundOff && _roundOff.abs() > 0.001) ...[
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Round Off Amount:',
                                style: TextStyle(
                                    color: DashboardColors.textMuted,
                                    fontSize: 12)),
                            Text(
                              '${_roundOff >= 0 ? '+' : '-'} ₹${_roundOff.abs().toStringAsFixed(2)}',
                              style: const TextStyle(
                                  color: DashboardColors.neonGreen,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ],
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
          if (_invoiceExtractedTotal != null &&
              (_grandTotal - _invoiceExtractedTotal!).abs() > 1.0) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: DashboardColors.alertOrange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: DashboardColors.alertOrange.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: DashboardColors.alertOrange, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Discrepancy Detected: Calculated Grand Total is ₹${_grandTotal.toStringAsFixed(2)}, but invoice extracted total is ₹${_invoiceExtractedTotal!.toStringAsFixed(2)} (Difference: ₹${(_grandTotal - _invoiceExtractedTotal!).abs().toStringAsFixed(2)}). Please verify item rates, quantities & taxes.',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500),
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
