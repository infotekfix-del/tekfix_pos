// =============================================================================
// TEKFIX ERP — MANUAL PURCHASE ENTRY SCREEN
// Full manual purchase entry: Supplier → Invoice → Items → Charges → Payment
// Uses PurchaseCalculationEngine (shared with Upload Bill mode).
// Draft auto-saved locally; resumes after crash/back-press/restart.
// entrySource = 'manual' written to every saved bill.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db;
import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
import 'invoice_parser_service.dart';
import 'manual_purchase_draft_service.dart';
import 'purchase_bill_service.dart';
import 'purchase_calculation_engine.dart';
import 'purchase_models.dart';
import 'quick_register_drawer.dart';
import 'supplier_search_sheet.dart';
import 'purchase_bill_details_screen.dart';

// ---------------------------------------------------------------------------
// EditablePurchaseItem — mutable wrapper used by the item table
// ---------------------------------------------------------------------------
class _EditableItem {
  final String rowId;
  dynamic itemKey;
  String name;
  String brand;
  String model;
  String sku;
  String hsnCode;
  int quantity;
  double purchaseRate;
  double mrp;
  double sellingPrice;
  double discount;
  double taxPercent;
  bool isNewProduct;
  bool isStagedReady;
  String? matchedProductId;
  String? matchedProductName;
  String? matchStatus; // null = not checked yet
  bool isMatchLoading;
  String? matchNotes;
  bool imeiRequired;
  String warrantyDuration;

  _EditableItem({
    String? rowId,
    this.itemKey,
    this.name = '',
    this.brand = '',
    this.model = '',
    this.sku = '',
    this.hsnCode = '',
    this.quantity = 1,
    this.purchaseRate = 0.0,
    this.mrp = 0.0,
    this.sellingPrice = 0.0,
    this.discount = 0.0,
    this.taxPercent = 18.0,
    this.isNewProduct = false,
    this.isStagedReady = true,
    this.matchedProductId,
    this.matchedProductName,
    this.matchStatus,
    this.isMatchLoading = false,
    this.matchNotes,
    this.imeiRequired = false,
    this.warrantyDuration = 'No Warranty',
  }) : rowId = rowId ?? 'ROW_${DateTime.now().microsecondsSinceEpoch}';

  /// Converts to a PurchaseBillItem for saving/calculation
  PurchaseBillItem toItem() {
    final gross = quantity * purchaseRate;
    final taxable = (gross - discount).clamp(0.0, double.infinity);
    final tax = taxable * taxPercent / 100;
    return PurchaseBillItem(
      id: rowId,
      itemKey: itemKey,
      itemId: matchedProductId,
      name: name,
      brand: brand,
      model: model,
      sku: sku,
      hsnCode: hsnCode,
      quantity: quantity,
      purchaseRate: purchaseRate,
      mrp: mrp,
      sellingPrice: sellingPrice,
      discount: discount,
      taxPercent: taxPercent,
      taxAmount: tax,
      lineTotal: taxable + tax,
      isNewProduct: isNewProduct,
      isStagedReady: isStagedReady,
      matchedProductId: matchedProductId,
      matchedProductName: matchedProductName,
      matchStatusOverride: matchStatus,
      matchNotes: matchNotes,
      imeiRequired: imeiRequired,
      warrantyDuration: warrantyDuration,
    );
  }

  Map<String, dynamic> toMap() => toItem().toMap();
}

// ---------------------------------------------------------------------------
// ManualPurchaseEntryScreen
// ---------------------------------------------------------------------------
class ManualPurchaseEntryScreen extends StatefulWidget {
  final dynamic initialVendorKey;
  final String? initialVendorName;

  const ManualPurchaseEntryScreen({
    super.key,
    this.initialVendorKey,
    this.initialVendorName,
  });

  @override
  State<ManualPurchaseEntryScreen> createState() =>
      _ManualPurchaseEntryScreenState();
}

class _ManualPurchaseEntryScreenState
    extends State<ManualPurchaseEntryScreen> {
  // ---- Supplier ----
  dynamic _vendorKey;
  String _vendorName = '';
  String _vendorPhone = '';
  String _vendorGst = '';
  String _vendorAddress = '';
  String _vendorState = '';
  double _vendorPrevBalance = 0.0;
  bool _loadingBalance = false;

  // ---- Invoice ----
  final _invoiceNumCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  DateTime _invoiceDate = DateTime.now();
  String _placeOfSupply = '';
  PurchaseBill? _duplicateWarning;
  bool _duplicateBlocked = false;

  // ---- Items ----
  final List<_EditableItem> _items = [];
  final _productSearchCtrl = TextEditingController();
  bool _isSearchingProduct = false;
  Timer? _matchDebounce;

  // ---- Charges & round-off ----
  final _chargesCtrl = TextEditingController(text: '0');
  double _chargesGstRate = 0.0;
  bool _applyRoundOff = true;

  // ---- Payment ----
  final _paidCtrl = TextEditingController(text: '0');
  String _paymentMethod = 'Cash';
  final _paymentRefCtrl = TextEditingController();
  final _printedTotalCtrl = TextEditingController();

  // ---- State ----
  bool _isSaving = false;
  bool _saveAttempted = false;
  final List<String> _validationErrors = [];

  // ---- Document Attachment & OCR State ----
  BillAttachment? _attachment;
  Uint8List? _attachmentBytes;
  bool _isParsingBill = false;
  String? _parsedBillBanner;

  // ---- Calculation engine ----
  PurchaseCalculationEngine _engine = const PurchaseCalculationEngine(isInterState: false);
  late BillCalcResult _calc;

  // ---- Draft auto-save ----
  Timer? _draftTimer;
  static const _draftDebounce = Duration(seconds: 3);

  // ---- Bill number ----
  String _billNumber = '';

  @override
  void initState() {
    super.initState();
    _calc = _recalculate();
    _init();
  }

  Future<void> _init() async {
    _billNumber = await PurchaseBillService.instance.generateBillNumber();
    if (mounted) setState(() {});

    // Check for initial vendor from caller
    if (widget.initialVendorKey != null) {
      final vendors = PurchaseBillService.instance.getVendors();
      final v = vendors.cast<Map<String, dynamic>?>().firstWhere(
        (e) => e?['key'] == widget.initialVendorKey || '${e?['key']}' == '${widget.initialVendorKey}',
        orElse: () => null,
      );
      if (v != null) {
        await _applyVendorMap(v);
      } else if (widget.initialVendorName != null && mounted) {
        setState(() => _vendorName = widget.initialVendorName!);
      }
    }

    // Check for existing draft if no initial vendor
    final draft = ManualPurchaseDraftService.instance.load();
    if (draft != null && draft.hasData && mounted && widget.initialVendorKey == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final resume = await _showResumeDraftDialog(draft);
        if (resume == true && mounted) {
          _restoreDraft(draft);
        }
      });
    }
  }

  Future<bool?> _showResumeDraftDialog(ManualPurchaseDraft draft) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0B1030),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(children: [
          const Icon(Icons.restore_rounded,
              color: DashboardColors.neonGreen, size: 22),
          const SizedBox(width: 10),
          Text('Resume Draft?',
              style: DashboardTypography.poppins(
                  fontSize: 17, fontWeight: FontWeight.w700)),
        ]),
        content: Text(
          'You have an unsaved purchase draft${draft.vendorName.isNotEmpty ? " for ${draft.vendorName}" : ""} '
          'with ${draft.itemMaps.length} item(s). Resume it?',
          style: const TextStyle(color: DashboardColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ManualPurchaseDraftService.instance.delete();
              Navigator.pop(ctx, false);
            },
            child: const Text('Discard',
                style: TextStyle(color: DashboardColors.alertRed)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: DashboardColors.neonGreen,
                foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Resume',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _restoreDraft(ManualPurchaseDraft draft) {
    setState(() {
      _vendorKey = draft.vendorKey;
      _vendorName = draft.vendorName;
      _vendorPhone = draft.vendorPhone;
      _vendorGst = draft.vendorGst;
      _vendorAddress = draft.vendorAddress;
      _vendorState = draft.vendorState;
      _invoiceNumCtrl.text = draft.vendorInvoiceNumber;
      _notesCtrl.text = draft.notes;
      _invoiceDate = draft.purchaseDate;
      _placeOfSupply = draft.placeOfSupply;
      _chargesCtrl.text = draft.otherCharges.toStringAsFixed(0);
      _chargesGstRate = draft.otherChargesGstRate;
      _paidCtrl.text = draft.paidAmount.toStringAsFixed(0);
      _paymentMethod = draft.paymentMethod;
      _paymentRefCtrl.text = draft.paymentRef;
      _applyRoundOff = draft.applyRoundOff;

      _items.clear();
      for (final m in draft.itemMaps) {
        final item = PurchaseBillItem.fromMap(m);
        _items.add(_EditableItem(
          rowId: item.id,
          name: item.name,
          brand: item.brand,
          model: item.model,
          sku: item.sku,
          hsnCode: item.hsnCode,
          quantity: item.quantity,
          purchaseRate: item.purchaseRate,
          mrp: item.mrp,
          sellingPrice: item.sellingPrice,
          discount: item.discount,
          taxPercent: item.taxPercent,
          isNewProduct: item.isNewProduct,
          isStagedReady: item.isStagedReady,
          matchedProductId: item.matchedProductId,
          matchedProductName: item.matchedProductName,
          matchStatus: item.matchStatusOverride,
          matchNotes: item.matchNotes,
          imeiRequired: item.imeiRequired,
          warrantyDuration: item.warrantyDuration,
        ));
      }
    });
    _updateEngine();
    _recalcState();
  }

  void _updateEngine() {
    _engine = PurchaseCalculationEngine(
      isInterState: PurchaseCalculationEngine.deriveInterState(
        _vendorGst,
        Db.setting('store_state_code', '32'),
      ),
    );
  }

  BillCalcResult _recalculate() {
    final items = _items.map((e) => e.toItem()).toList();
    final charges = <BillCharge>[];
    final chargeAmt = double.tryParse(_chargesCtrl.text) ?? 0.0;
    if (chargeAmt > 0) {
      charges.add(BillCharge(
        label: 'Other Charges',
        amount: chargeAmt,
        gstRate: _chargesGstRate,
      ));
    }
    final printed = _printedTotalCtrl.text.trim().isNotEmpty
        ? ((double.tryParse(_printedTotalCtrl.text) ?? 0.0) * 100).round()
        : null;

    return _engine.calculate(
      items: items,
      paidAmountPaise: ((double.tryParse(_paidCtrl.text) ?? 0.0) * 100).round(),
      charges: charges,
      applyRoundOff: _applyRoundOff,
      printedTotalPaise: printed,
    );
  }

  void _recalcState() {
    setState(() => _calc = _recalculate());
  }

  void _scheduleDraftSave() {
    _draftTimer?.cancel();
    _draftTimer = Timer(_draftDebounce, _saveDraft);
  }

  void _saveDraft() {
    final draft = ManualPurchaseDraft(
      vendorKey: _vendorKey,
      vendorName: _vendorName,
      vendorPhone: _vendorPhone,
      vendorGst: _vendorGst,
      vendorAddress: _vendorAddress,
      vendorState: _vendorState,
      vendorInvoiceNumber: _invoiceNumCtrl.text,
      purchaseDate: _invoiceDate,
      placeOfSupply: _placeOfSupply,
      notes: _notesCtrl.text,
      itemMaps: _items.map((e) => e.toMap()).toList(),
      otherCharges: double.tryParse(_chargesCtrl.text) ?? 0.0,
      otherChargesGstRate: _chargesGstRate,
      paidAmount: double.tryParse(_paidCtrl.text) ?? 0.0,
      paymentMethod: _paymentMethod,
      paymentRef: _paymentRefCtrl.text,
      applyRoundOff: _applyRoundOff,
    );
    ManualPurchaseDraftService.instance.save(draft);
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _matchDebounce?.cancel();
    _invoiceNumCtrl.dispose();
    _notesCtrl.dispose();
    _productSearchCtrl.dispose();
    _chargesCtrl.dispose();
    _paidCtrl.dispose();
    _paymentRefCtrl.dispose();
    _printedTotalCtrl.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // VENDOR SELECTION
  // -------------------------------------------------------------------------
  Future<void> _applyVendorMap(Map<String, dynamic> result) async {
    setState(() {
      _vendorKey = result['key'];
      _vendorName = result['name']?.toString() ?? '';
      _vendorPhone = result['phone']?.toString() ?? '';
      _vendorGst = result['gst']?.toString() ?? '';
      _vendorAddress = result['address']?.toString() ?? '';
      _loadingBalance = true;
    });

    _updateEngine();
    _recalcState();
    _scheduleDraftSave();

    // Derive state from GSTIN
    final gstin = _vendorGst.trim().toUpperCase();
    if (gstin.length >= 2) {
      setState(() => _vendorState = gstin.substring(0, 2));
      setState(() => _placeOfSupply = _vendorState == '32' ? 'Kerala' : _vendorState);
    }

    // Fetch real-time balance
    final balPaise = await PurchaseBillService.instance
        .fetchVendorBalancePaise(_vendorKey);
    if (mounted) {
      setState(() {
        _vendorPrevBalance = balPaise / 100.0;
        _loadingBalance = false;
      });
    }
  }

  Future<void> _selectVendor() async {
    final result = await SupplierSearchSheet.show(context);
    if (result == null || !mounted) return;
    await _applyVendorMap(result);
  }

  // -------------------------------------------------------------------------
  // AUTOMATED BILL EXTRACTION (OCR / PDF / IMAGE PARSER)
  // -------------------------------------------------------------------------
  Future<void> _pickAndAutoParseBill() async {
    try {
      setState(() => _isParsingBill = true);
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final ext = (file.extension ?? '').toLowerCase();
      final mime = ext == 'pdf' ? 'application/pdf' : 'image/$ext';

      Uint8List? fileBytes = file.bytes;
      if (fileBytes == null && file.path != null && File(file.path!).existsSync()) {
        fileBytes = await File(file.path!).readAsBytes();
      }

      if (fileBytes == null) {
        TekFeedback.error('Unable to read selected bill file.');
        return;
      }

      _attachmentBytes = fileBytes;
      _attachment = BillAttachment(
        fileName: file.name,
        fileType: mime,
        fileSizeBytes: fileBytes.length,
        bytesBase64: base64Encode(fileBytes),
        filePath: file.path,
        uploadedAt: DateTime.now(),
      );

      TekFeedback.toast('Extracting bill data with OCR parser...');

      final parsed = await InvoiceParserService.instance.parseInvoiceFile(
        fileBytes: fileBytes,
        fileName: file.name,
        filePath: file.path,
      );

      if (!mounted) return;

      setState(() {
        if (parsed.invoiceNumber != null && parsed.invoiceNumber!.isNotEmpty) {
          _invoiceNumCtrl.text = parsed.invoiceNumber!;
        }
        if (parsed.invoiceDate != null) {
          _invoiceDate = parsed.invoiceDate!;
        }
        if (parsed.invoiceTotal != null && parsed.invoiceTotal! > 0) {
          _printedTotalCtrl.text = parsed.invoiceTotal!.toStringAsFixed(2);
        }
      });

      // Match or populate vendor
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
        await _applyVendorMap(matchedVendor);
      } else if (parsed.vendorName != null && parsed.vendorName!.isNotEmpty) {
        setState(() {
          _vendorName = parsed.vendorName!;
          if (parsed.vendorPhone != null) _vendorPhone = parsed.vendorPhone!;
          if (parsed.vendorGst != null) _vendorGst = parsed.vendorGst!;
          if (parsed.vendorAddress != null) _vendorAddress = parsed.vendorAddress!;
        });
      }

      // Auto-populate line items if extracted
      if (parsed.hasItems) {
        final newRows = <_EditableItem>[];
        for (final pItem in parsed.items) {
          final row = _EditableItem(
            name: pItem.description,
            sku: pItem.skuOrHsn ?? '',
            hsnCode: pItem.skuOrHsn ?? '',
            quantity: pItem.quantity,
            purchaseRate: pItem.unitPrice,
            mrp: pItem.mrp,
            sellingPrice: pItem.mrp > 0 ? pItem.mrp : (pItem.unitPrice * 1.20).roundToDouble(),
            discount: pItem.discount,
            taxPercent: pItem.taxPercent > 0 ? pItem.taxPercent : 18.0,
            isMatchLoading: true,
          );
          newRows.add(row);
        }

        setState(() {
          _items.clear();
          _items.addAll(newRows);
          _parsedBillBanner =
              'Auto-extracted ${parsed.itemCount} items from ${file.name} (${parsed.parsingMethod}). Review & confirm.';
        });

        // Smart product matching against inventory
        for (final row in newRows) {
          _triggerProductMatch(row);
        }

        TekFeedback.success('Extracted ${parsed.itemCount} items from bill!');
      } else {
        setState(() {
          _parsedBillBanner = 'Bill attached (${file.name}). Enter items below.';
        });
        TekFeedback.toast('Bill attached: ${file.name}');
      }

      _checkDuplicateInvoice();
      _recalcState();
      _scheduleDraftSave();
    } catch (e) {
      TekFeedback.error('Failed to parse bill: $e');
    } finally {
      if (mounted) setState(() => _isParsingBill = false);
    }
  }

  // -------------------------------------------------------------------------
  // DUPLICATE INVOICE CHECK
  // -------------------------------------------------------------------------
  void _checkDuplicateInvoice() {
    if (_invoiceNumCtrl.text.trim().isEmpty || _vendorKey == null) {
      setState(() {
        _duplicateWarning = null;
        _duplicateBlocked = false;
      });
      return;
    }
    final dup = PurchaseBillService.instance
        .checkDuplicateInvoice(_invoiceNumCtrl.text.trim(), _vendorKey);
    setState(() {
      _duplicateWarning = dup;
      _duplicateBlocked = dup != null;
    });
  }

  // -------------------------------------------------------------------------
  // ADD ITEM
  // -------------------------------------------------------------------------
  Future<void> _addItemBySearch(String query) async {
    if (query.trim().isEmpty) return;

    final newRow = _EditableItem(
      name: query.trim(),
      isMatchLoading: true,
      matchStatus: null,
    );

    setState(() {
      _items.add(newRow);
      _productSearchCtrl.clear();
      _isSearchingProduct = false;
    });

    _scheduleDraftSave();

    // Trigger async product match
    _triggerProductMatch(newRow);
  }

  void _triggerProductMatch(_EditableItem row) async {
    try {
      final match = await PurchaseBillService.instance.matchProductInFirestore(
        name: row.name,
        sku: row.sku.isNotEmpty ? row.sku : null,
        model: row.model.isNotEmpty ? row.model : null,
        barcode: row.sku.isNotEmpty ? row.sku : null,
      );

      if (!mounted) return;

      setState(() {
        row.isMatchLoading = false;
        if (match != null) {
          row.matchStatus = match['status'] as String? ?? ProductMatchStatus.matched;
          row.matchedProductId = match['id']?.toString();
          row.itemKey = match['itemKey'] ?? match['id'];
          row.matchedProductName = match['name']?.toString() ?? row.name;
          row.matchNotes = match['notes']?.toString();
          row.isNewProduct = match['status'] == ProductMatchStatus.quickRegister;
          row.isStagedReady = match['status'] == ProductMatchStatus.matched;

          // Pre-fill from catalog data
          final data = match['data'] as Map?;
          if (data != null) {
            if (row.taxPercent == 18.0 && data['gstRate'] != null) {
              row.taxPercent = (data['gstRate'] as num).toDouble();
            }
            if (row.sellingPrice == 0.0 && data['sellingPrice'] != null) {
              row.sellingPrice = (data['sellingPrice'] as num).toDouble();
            }
            if (row.mrp == 0.0 && data['mrp'] != null) {
              row.mrp = (data['mrp'] as num).toDouble();
            }
            if (row.hsnCode.isEmpty && data['hsn'] != null) {
              row.hsnCode = data['hsn'].toString();
            }
            row.imeiRequired = data['imeiRequired'] == true;
          }
        } else {
          row.matchStatus = ProductMatchStatus.quickRegister;
          row.isNewProduct = true;
          row.isStagedReady = false;
        }
      });
      _recalcState();
    } catch (e) {
      if (mounted) {
        setState(() {
          row.isMatchLoading = false;
          row.matchStatus = ProductMatchStatus.quickRegister;
          row.isNewProduct = true;
          row.isStagedReady = false;
        });
      }
    }
  }

  Future<void> _openQuickRegister(_EditableItem row) async {
    final result = await QuickRegisterDrawer.show(
      context,
      prefillName: row.name,
      prefillBrand: row.brand,
      prefillModel: row.model,
      prefillSku: row.sku,
      prefillGstRate: row.taxPercent,
      prefillHsn: row.hsnCode,
      prefillMrp: row.mrp,
      prefillSellingPrice: row.sellingPrice,
    );

    if (result == null || !mounted) return;

    setState(() {
      row.matchedProductId = result['id']?.toString() ?? result['matchedProductId']?.toString();
      row.itemKey = result['key'] ?? result['itemKey'] ?? result['id'];
      row.matchedProductName = result['name']?.toString() ?? row.name;
      row.isNewProduct = false;
      row.isStagedReady = true;
      row.matchStatus = ProductMatchStatus.matched;
      row.matchNotes = null;
      // Update fields from registered product
      if ((result['gstRate'] as num?) != null) {
        row.taxPercent = (result['gstRate'] as num).toDouble();
      }
      if ((result['sellingPrice'] as num?) != null && row.sellingPrice == 0.0) {
        row.sellingPrice = (result['sellingPrice'] as num).toDouble();
      }
      if ((result['mrp'] as num?) != null && row.mrp == 0.0) {
        row.mrp = (result['mrp'] as num).toDouble();
      }
      row.imeiRequired = result['imeiRequired'] == true;
      row.warrantyDuration = result['warranty']?.toString() ?? 'No Warranty';
    });
    _recalcState();
    _scheduleDraftSave();
  }

  void _removeItem(int index) {
    final name = _items[index].name;
    setState(() => _items.removeAt(index));
    _recalcState();
    _scheduleDraftSave();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed "$name"'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            // Can't perfectly restore because item was removed; minimal undo
          },
        ),
        duration: const Duration(seconds: 3),
        backgroundColor: const Color(0xFF1E293B),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // VALIDATION
  // -------------------------------------------------------------------------
  List<String> _validate() {
    final errors = <String>[];
    if (_vendorKey == null || _vendorName.isEmpty) {
      errors.add('Please select a supplier.');
    }
    if (_invoiceNumCtrl.text.trim().isEmpty) {
      errors.add('Invoice/Bill number is required.');
    }
    if (_duplicateBlocked) {
      errors.add('This invoice number already exists for the selected supplier.');
    }
    if (_items.isEmpty) {
      errors.add('Add at least one item.');
    }
    for (int i = 0; i < _items.length; i++) {
      final it = _items[i];
      if (it.name.isEmpty) errors.add('Row ${i + 1}: Product name is missing.');
      if (it.quantity <= 0) errors.add('Row ${i + 1}: Quantity must be > 0.');
      if (it.purchaseRate < 0) errors.add('Row ${i + 1}: Purchase rate cannot be negative.');
      if (it.isNewProduct && !it.isStagedReady) {
        errors.add('Row ${i + 1}: "${it.name}" needs to be registered via Quick Register before saving.');
      }
    }
    final paid = double.tryParse(_paidCtrl.text) ?? 0.0;
    if (paid < 0) errors.add('Paid amount cannot be negative.');
    return errors;
  }

  // -------------------------------------------------------------------------
  // SAVE
  // -------------------------------------------------------------------------
  Future<void> _save() async {
    setState(() => _saveAttempted = true);
    final errors = _validate();
    if (errors.isNotEmpty) {
      setState(() => _validationErrors
        ..clear()
        ..addAll(errors));
      return;
    }

    // Mismatch acknowledgement if needed
    if (_calc.hasMismatch) {
      final ack = await _showMismatchDialog();
      if (ack != true || !mounted) return;
    }

    // Confirm dialog
    final confirmed = await _showConfirmDialog();
    if (confirmed != true || !mounted) return;

    setState(() => _isSaving = true);

    try {
      final auth = Provider.of<AuthController>(context, listen: false);

      final confirmedBill = await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: _billNumber,
        vendorInvoiceNumber: _invoiceNumCtrl.text.trim(),
        vendorKey: _vendorKey,
        vendorName: _vendorName,
        vendorPhone: _vendorPhone,
        vendorGst: _vendorGst,
        vendorAddress: _vendorAddress,
        purchaseDate: _invoiceDate,
        items: _items.map((e) => e.toItem()).toList(),
        otherCharges: double.tryParse(_chargesCtrl.text) ?? 0.0,
        initialPaidAmount: double.tryParse(_paidCtrl.text) ?? 0.0,
        initialPaymentMethod: _paymentMethod,
        initialPaymentReference: _paymentRefCtrl.text.trim(),
        attachment: _attachment,
        attachmentBytes: _attachmentBytes,
        staffId: auth.uid,
        staffName: auth.name.isNotEmpty ? auth.name : 'Owner',
        notes: _notesCtrl.text.trim(),
        entrySource: EntrySource.manual,
      );

      // Delete draft on success
      await ManualPurchaseDraftService.instance.delete();

      if (mounted) {
        TekFeedback.success('Purchase bill ${confirmedBill.billNumber} saved!');
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => PurchaseBillDetailsScreen(bill: confirmedBill),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        TekFeedback.error('Save failed: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    }
  }

  Future<bool?> _showMismatchDialog() {
    final diff = (_calc.mismatchPaise ?? 0).abs() / 100.0;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0B1030),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(children: [
          const Icon(Icons.warning_amber_rounded,
              color: DashboardColors.neonOrange, size: 22),
          const SizedBox(width: 10),
          Text('Total Mismatch',
              style: DashboardTypography.poppins(
                  fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
        content: Text(
          'Your computed total (₹${_calc.grandTotal.toStringAsFixed(2)}) differs from '
          'the printed total by ₹${diff.toStringAsFixed(2)}. '
          'Please review before saving.',
          style: const TextStyle(color: DashboardColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Review',
                style: TextStyle(color: DashboardColors.neonBlue)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: DashboardColors.neonOrange,
                foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Acknowledge & Save',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showConfirmDialog() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0B1030),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(children: [
          const Icon(Icons.receipt_long_rounded,
              color: DashboardColors.neonGreen, size: 22),
          const SizedBox(width: 10),
          Text('Confirm Purchase',
              style: DashboardTypography.poppins(
                  fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _confirmRow('Supplier', _vendorName),
            _confirmRow('Invoice No.', _invoiceNumCtrl.text.trim()),
            _confirmRow('Items', '${_items.length} item(s), ${_calc.lines.fold(0, (s, l) => s + l.quantity)} unit(s)'),
            _confirmRow('Grand Total',
                '₹${NumberFormat('#,##0.00', 'en_IN').format(_calc.grandTotal)}'),
            _confirmRow('Paid Now',
                '₹${NumberFormat('#,##0.00', 'en_IN').format(_calc.paidAmount)}'),
            _confirmRow('Balance Due',
                '₹${NumberFormat('#,##0.00', 'en_IN').format(_calc.balanceDue)}'),
            _confirmRow('New Vendor Outstanding',
                '₹${NumberFormat('#,##0.00', 'en_IN').format(_vendorPrevBalance + _calc.balanceDue)}'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: DashboardColors.neonGreen.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Stock and vendor ledger will be updated atomically. This cannot be undone.',
                style: TextStyle(
                    color: DashboardColors.textMuted, fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: DashboardColors.textMuted)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: DashboardColors.neonGreen,
                foregroundColor: Colors.black),
            icon: const Icon(Icons.check_circle_rounded, size: 18),
            label: const Text('Confirm & Save',
                style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
  }

  Widget _confirmRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(
                    color: DashboardColors.textMuted, fontSize: 13)),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );

  // =========================================================================
  // BUILD
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      backgroundColor: DashboardColors.bgDarkNavyStart,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1030),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Manual Purchase Entry',
                style: DashboardTypography.poppins(
                    fontSize: 17, fontWeight: FontWeight.w700)),
            if (_billNumber.isNotEmpty)
              Text(_billNumber,
                  style: const TextStyle(
                      color: DashboardColors.textMuted, fontSize: 11)),
          ],
        ),
        actions: [
          // Auto-Extract from Bill (OCR) button
          if (_isParsingBill)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: DashboardColors.neonGreen.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DashboardColors.neonGreen),
              ),
              child: const Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: DashboardColors.neonGreen,
                    ),
                  ),
                  SizedBox(width: 8),
                  Text('Parsing OCR...',
                      style: TextStyle(
                          color: DashboardColors.neonGreen,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            )
          else if (_attachment != null)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: DashboardColors.neonBlue.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DashboardColors.neonBlue.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.attach_file_rounded,
                      color: DashboardColors.neonBlue, size: 14),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      _attachment!.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () {
                      setState(() {
                        _attachment = null;
                        _attachmentBytes = null;
                        _parsedBillBanner = null;
                      });
                      TekFeedback.toast('Bill detached');
                    },
                    child: const Icon(Icons.close_rounded,
                        color: DashboardColors.textMuted, size: 14),
                  ),
                ],
              ),
            )
          else
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: DashboardColors.neonGreen,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 2,
                ),
                icon: const Icon(Icons.document_scanner_rounded,
                    size: 16, color: Colors.black),
                label: const Text('Auto-Extract Bill (OCR)',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Colors.black)),
                onPressed: _pickAndAutoParseBill,
              ),
            ),

          // Source chip
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: DashboardColors.neonBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: DashboardColors.neonBlue.withValues(alpha: 0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.edit_note_rounded,
                    color: DashboardColors.neonBlue, size: 14),
                SizedBox(width: 5),
                Text('Manual Entry',
                    style: TextStyle(
                        color: DashboardColors.neonBlue,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
      body: isWide ? _buildWideLayout() : _buildNarrowLayout(),
      bottomNavigationBar: isWide ? null : _buildStickyBottom(),
    );
  }

  // ---- Wide (tablet/desktop) layout: two-pane ----
  Widget _buildWideLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left pane: entry form
        Expanded(
          flex: 7,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: Column(
              children: [
                _buildExtractionBanner(),
                _buildValidationErrors(),
                _buildSupplierSection(),
                const SizedBox(height: 16),
                _buildInvoiceSection(),
                const SizedBox(height: 16),
                _buildItemsSection(),
                const SizedBox(height: 16),
                _buildChargesSection(),
              ],
            ),
          ),
        ),
        // Right pane: summary + payment + save
        Container(
          width: 360,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height - kToolbarHeight - 50,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(0, 22, 22, 22),
            child: Column(
              children: [
                _buildTaxSummaryCard(),
                const SizedBox(height: 16),
                _buildPaymentSection(),
                const SizedBox(height: 16),
                _buildSaveButton(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---- Narrow (phone) layout: single column with sticky bottom ----
  Widget _buildNarrowLayout() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      child: Column(
        children: [
          _buildExtractionBanner(),
          _buildValidationErrors(),
          _buildSupplierSection(),
          const SizedBox(height: 14),
          _buildInvoiceSection(),
          const SizedBox(height: 14),
          _buildItemsSection(),
          const SizedBox(height: 14),
          _buildChargesSection(),
          const SizedBox(height: 14),
          _buildTaxSummaryCard(),
          const SizedBox(height: 14),
          _buildPaymentSection(),
        ],
      ),
    );
  }

  Widget _buildExtractionBanner() {
    if (_parsedBillBanner == null) return const SizedBox();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DashboardColors.neonGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: DashboardColors.neonGreen.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline_rounded,
              color: DashboardColors.neonGreen, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _parsedBillBanner!,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                color: DashboardColors.textMuted, size: 16),
            onPressed: () => setState(() => _parsedBillBanner = null),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  Widget _buildStickyBottom() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1428),
        border: Border(
            top: BorderSide(color: DashboardColors.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${_items.length} item(s)',
                    style: const TextStyle(
                        color: DashboardColors.textMuted, fontSize: 11)),
                Text(
                    '₹${NumberFormat('#,##0.00', 'en_IN').format(_calc.grandTotal)}',
                    style: DashboardTypography.poppins(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: DashboardColors.neonGreen)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: _buildSaveButton()),
        ],
      ),
    );
  }

  // =========================================================================
  // SECTION BUILDERS
  // =========================================================================

  Widget _buildValidationErrors() {
    if (!_saveAttempted || _validationErrors.isEmpty) return const SizedBox();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DashboardColors.alertRed.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: DashboardColors.alertRed.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.error_outline_rounded,
                color: DashboardColors.alertRed, size: 18),
            SizedBox(width: 8),
            Text('Please fix the following:',
                style: TextStyle(
                    color: DashboardColors.alertRed,
                    fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          ..._validationErrors.map((e) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• ',
                        style:
                            TextStyle(color: DashboardColors.alertRed)),
                    Expanded(
                        child: Text(e,
                            style: const TextStyle(
                                color: DashboardColors.alertRed,
                                fontSize: 13))),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  // ---- A. SUPPLIER ----
  Widget _buildSupplierSection() {
    return _sectionCard(
      icon: Icons.business_rounded,
      iconColor: DashboardColors.neonBlue,
      title: 'Supplier',
      child: _vendorKey == null
          ? _buildSupplierPrompt()
          : _buildSupplierCard(),
    );
  }

  Widget _buildSupplierPrompt() {
    final hasError = _saveAttempted && _vendorKey == null;
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        side: BorderSide(
            color: hasError
                ? DashboardColors.alertRed
                : DashboardColors.neonBlue,
            width: hasError ? 1.5 : 1),
        foregroundColor: DashboardColors.neonBlue,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: const Icon(Icons.search_rounded, size: 18),
      label: const Text('Search or Add Supplier',
          style: TextStyle(fontWeight: FontWeight.w600)),
      onPressed: _selectVendor,
    );
  }

  Widget _buildSupplierCard() {
    return GestureDetector(
      onTap: _selectVendor,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: DashboardColors.neonBlue.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: DashboardColors.activePillGradient,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(
                  _vendorName.isNotEmpty
                      ? _vendorName[0].toUpperCase()
                      : 'S',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 18),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_vendorName,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                  if (_vendorPhone.isNotEmpty)
                    Text(_vendorPhone,
                        style: const TextStyle(
                            color: DashboardColors.textMuted,
                            fontSize: 12)),
                  if (_vendorGst.isNotEmpty)
                    Text('GSTIN: $_vendorGst',
                        style: const TextStyle(
                            color: DashboardColors.neonBlue,
                            fontSize: 11)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text('Previous Balance',
                    style: TextStyle(
                        color: DashboardColors.textMuted, fontSize: 10)),
                if (_loadingBalance)
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: DashboardColors.neonOrange))
                else
                  Text(
                    '₹${NumberFormat('#,##0.00', 'en_IN').format(_vendorPrevBalance)}',
                    style: TextStyle(
                        color: _vendorPrevBalance > 0
                            ? DashboardColors.neonOrange
                            : DashboardColors.neonGreen,
                        fontWeight: FontWeight.w800,
                        fontSize: 13),
                  ),
                TextButton(
                  style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 0),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  onPressed: _selectVendor,
                  child: const Text('Change',
                      style: TextStyle(
                          color: DashboardColors.textMuted, fontSize: 11)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---- B. INVOICE ----
  Widget _buildInvoiceSection() {
    return _sectionCard(
      icon: Icons.receipt_rounded,
      iconColor: DashboardColors.neonPurple,
      title: 'Invoice Details',
      child: Column(
        children: [
          // Invoice number + date row
          Row(children: [
            Expanded(
              child: _textField(
                _invoiceNumCtrl,
                'Invoice / Bill No. *',
                Icons.tag_rounded,
                onChanged: (_) {
                  _checkDuplicateInvoice();
                  _scheduleDraftSave();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _pickInvoiceDate,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: DashboardColors.glassBorder),
                  ),
                  child: Row(children: [
                    const Icon(Icons.calendar_today_rounded,
                        color: DashboardColors.neonBlue, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Invoice Date',
                              style: TextStyle(
                                  color: DashboardColors.textMuted,
                                  fontSize: 10),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          Text(
                            DateFormat('dd MMM yyyy').format(_invoiceDate),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]),

          // Duplicate warning
          if (_duplicateWarning != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: DashboardColors.alertRed.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: DashboardColors.alertRed.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.warning_rounded,
                    color: DashboardColors.alertRed, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Duplicate! Invoice "${_invoiceNumCtrl.text.trim()}" already exists '
                    'for $_vendorName (Bill: ${_duplicateWarning!.billNumber}). '
                    'Change the invoice number or open the existing purchase.',
                    style: const TextStyle(
                        color: DashboardColors.alertRed, fontSize: 12),
                  ),
                ),
              ]),
            ),
          ],

          const SizedBox(height: 12),
          _textField(_notesCtrl, 'Notes / Remarks (optional)', Icons.notes_rounded,
              maxLines: 2, onChanged: (_) => _scheduleDraftSave()),
        ],
      ),
    );
  }

  Future<void> _pickInvoiceDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _invoiceDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 7)),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: DashboardColors.neonBlue,
            surface: Color(0xFF101846),
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _invoiceDate = picked);
      _scheduleDraftSave();
    }
  }

  // ---- C. ITEMS ----
  Widget _buildItemsSection() {
    return _sectionCard(
      icon: Icons.inventory_2_rounded,
      iconColor: DashboardColors.neonGreen,
      title: 'Items  (${_items.length})',
      trailing: IconButton(
        icon: const Icon(Icons.add_circle_rounded,
            color: DashboardColors.neonGreen, size: 22),
        tooltip: 'Add item',
        onPressed: () => setState(() => _isSearchingProduct = true),
      ),
      child: Column(
        children: [
          // Product search field
          if (_isSearchingProduct || _items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _productSearchCtrl,
                    autofocus: _isSearchingProduct,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText:
                          'Type product name, SKU or barcode and press Enter...',
                      hintStyle: const TextStyle(
                          color: DashboardColors.textMuted, fontSize: 12),
                      prefixIcon: const Icon(Icons.search_rounded,
                          color: DashboardColors.neonBlue, size: 18),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: DashboardColors.neonBlue),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: DashboardColors.glassBorder),
                      ),
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (v) {
                      if (v.trim().isNotEmpty) {
                        _addItemBySearch(v.trim());
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(() {
                    _isSearchingProduct = false;
                    _productSearchCtrl.clear();
                  }),
                  child: const Text('Cancel',
                      style:
                          TextStyle(color: DashboardColors.textMuted)),
                ),
              ]),
            ),

          if (_items.isEmpty && !_isSearchingProduct)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  const Icon(Icons.add_shopping_cart_rounded,
                      color: DashboardColors.textMuted, size: 48),
                  const SizedBox(height: 8),
                  const Text('No items added yet.',
                      style: TextStyle(color: DashboardColors.textMuted)),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.add_rounded,
                        color: DashboardColors.neonGreen),
                    label: const Text('Add First Item',
                        style:
                            TextStyle(color: DashboardColors.neonGreen)),
                    onPressed: () =>
                        setState(() => _isSearchingProduct = true),
                  ),
                ],
              ),
            )
          else
            // Items list
            ...List.generate(_items.length, (i) => _buildItemRow(i)),
        ],
      ),
    );
  }

  Widget _buildItemRow(int i) {
    final row = _items[i];
    final statusColor = row.matchStatus != null
        ? ProductMatchStatus.getColor(row.matchStatus!)
        : DashboardColors.textMuted;

    return Dismissible(
      key: Key(row.rowId),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: DashboardColors.alertRed.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_outline_rounded,
            color: DashboardColors.alertRed, size: 24),
      ),
      onDismissed: (_) => _removeItem(i),
      child: GestureDetector(
        onTap: () => _editItemDialog(i),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: statusColor.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      row.name.isNotEmpty ? row.name : 'Unnamed Item',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14),
                    ),
                  ),
                  // Match status badge
                  if (row.isMatchLoading)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: DashboardColors.neonBlue),
                    )
                  else if (row.matchStatus != null)
                    _matchBadge(row.matchStatus!, row),

                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.edit_rounded,
                        color: DashboardColors.textMuted, size: 16),
                    onPressed: () => _editItemDialog(i),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(children: [
                _itemChip('Qty: ${row.quantity}', DashboardColors.neonBlue),
                const SizedBox(width: 6),
                _itemChip('₹${row.purchaseRate.toStringAsFixed(0)}', DashboardColors.textMuted),
                const SizedBox(width: 6),
                _itemChip('GST: ${row.taxPercent.toStringAsFixed(0)}%', DashboardColors.neonPurple),
                const Spacer(),
                Text(
                  '₹${NumberFormat('#,##0.00', 'en_IN').format((row.quantity * row.purchaseRate * (1 + row.taxPercent / 100)) - row.discount)}',
                  style: const TextStyle(
                      color: DashboardColors.neonGreen,
                      fontWeight: FontWeight.w800,
                      fontSize: 14),
                ),
              ]),

              // Quick Register button for new products
              if (row.matchStatus == ProductMatchStatus.quickRegister &&
                  !row.isStagedReady) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: DashboardColors.neonOrange,
                    side: const BorderSide(color: DashboardColors.neonOrange),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.add_box_rounded, size: 16),
                  label: const Text('+ Quick Register',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  onPressed: () => _openQuickRegister(row),
                ),
              ],

              // Duplicate / review warning
              if (row.matchNotes != null &&
                  row.matchStatus == ProductMatchStatus.reviewRequired) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: DashboardColors.alertRed, size: 14),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(row.matchNotes!,
                        style: const TextStyle(
                            color: DashboardColors.alertRed, fontSize: 11)),
                  ),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _matchBadge(String status, _EditableItem row) {
    final color = ProductMatchStatus.getColor(status);
    final icon = status == ProductMatchStatus.matched
        ? Icons.check_circle_rounded
        : status == ProductMatchStatus.quickRegister
            ? Icons.add_circle_outline_rounded
            : Icons.warning_rounded;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 12),
        const SizedBox(width: 4),
        Text(
          status == ProductMatchStatus.matched
              ? (row.matchedProductName ?? 'Matched')
              : status == ProductMatchStatus.quickRegister
                  ? 'New'
                  : 'Review',
          style:
              TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
        ),
      ]),
    );
  }

  Widget _itemChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }

  // ---- Item edit dialog ----
  Future<void> _editItemDialog(int index) async {
    final row = _items[index];

    final nameCtrl = TextEditingController(text: row.name);
    final qtyCtrl = TextEditingController(text: row.quantity.toString());
    final rateCtrl = TextEditingController(text: row.purchaseRate.toStringAsFixed(2));
    final discCtrl = TextEditingController(text: row.discount.toStringAsFixed(2));
    final mrpCtrl = TextEditingController(text: row.mrp.toStringAsFixed(0));
    final spCtrl = TextEditingController(text: row.sellingPrice.toStringAsFixed(0));
    final hsnCtrl = TextEditingController(text: row.hsnCode);
    double taxPct = row.taxPercent;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setLocal) => AlertDialog(
          backgroundColor: const Color(0xFF0B1030),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text('Edit Item: ${row.name}',
              style: DashboardTypography.poppins(
                  fontSize: 16, fontWeight: FontWeight.w700)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _dialogField(nameCtrl, 'Product Name', TextInputType.text),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: _dialogField(
                        qtyCtrl, 'Qty', TextInputType.number)),
                const SizedBox(width: 10),
                Expanded(
                    child: _dialogField(
                        rateCtrl, 'Purchase Rate (₹)',
                        const TextInputType.numberWithOptions(decimal: true))),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: _dialogField(
                        discCtrl, 'Discount (₹)',
                        const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<double>(
                    value: taxPct,
                    dropdownColor: const Color(0xFF0B1030),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'GST %',
                      labelStyle: const TextStyle(
                          color: DashboardColors.textMuted, fontSize: 12),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                              color: DashboardColors.glassBorder)),
                      isDense: true,
                    ),
                    items: [0.0, 3.0, 5.0, 12.0, 18.0, 28.0]
                        .map((r) => DropdownMenuItem(
                            value: r, child: Text('${r.toStringAsFixed(0)}%')))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setLocal(() => taxPct = v);
                    },
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: _dialogField(
                        mrpCtrl, 'MRP (₹)',
                        const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 10),
                Expanded(
                    child: _dialogField(
                        spCtrl, 'Selling Price (₹)',
                        const TextInputType.numberWithOptions(decimal: true))),
              ]),
              const SizedBox(height: 10),
              _dialogField(hsnCtrl, 'HSN Code', TextInputType.number),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: DashboardColors.textMuted))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: DashboardColors.neonBlue,
                  foregroundColor: Colors.black),
              onPressed: () {
                setState(() {
                  row.name = nameCtrl.text.trim();
                  row.quantity = int.tryParse(qtyCtrl.text) ?? row.quantity;
                  row.purchaseRate =
                      double.tryParse(rateCtrl.text) ?? row.purchaseRate;
                  row.discount =
                      double.tryParse(discCtrl.text) ?? row.discount;
                  row.taxPercent = taxPct;
                  row.mrp = double.tryParse(mrpCtrl.text) ?? row.mrp;
                  row.sellingPrice =
                      double.tryParse(spCtrl.text) ?? row.sellingPrice;
                  row.hsnCode = hsnCtrl.text.trim();
                });
                _recalcState();
                _scheduleDraftSave();
                Navigator.pop(ctx);
              },
              child: const Text('Update',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );

    nameCtrl.dispose();
    qtyCtrl.dispose();
    rateCtrl.dispose();
    discCtrl.dispose();
    mrpCtrl.dispose();
    spCtrl.dispose();
    hsnCtrl.dispose();
  }

  Widget _dialogField(TextEditingController ctrl, String label,
      TextInputType keyboardType) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(
            color: DashboardColors.textMuted, fontSize: 12),
        isDense: true,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: DashboardColors.glassBorder),
        ),
      ),
    );
  }

  // ---- D. CHARGES ----
  Widget _buildChargesSection() {
    return _sectionCard(
      icon: Icons.local_shipping_rounded,
      iconColor: DashboardColors.neonOrange,
      title: 'Additional Charges',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _textField(
                  _chargesCtrl,
                  'Other Charges (₹)',
                  Icons.attach_money_rounded,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) {
                    _recalcState();
                    _scheduleDraftSave();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<double>(
                  value: _chargesGstRate,
                  dropdownColor: const Color(0xFF0B1030),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'GST Rate',
                    labelStyle: const TextStyle(
                        color: DashboardColors.textMuted, fontSize: 12),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.04),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: DashboardColors.glassBorder)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: DashboardColors.glassBorder)),
                  ),
                  items: [0.0, 5.0, 12.0, 18.0, 28.0]
                      .map((r) => DropdownMenuItem(
                          value: r,
                          child: Text(
                              r == 0 ? 'None (0%)' : '${r.toStringAsFixed(0)}%')))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _chargesGstRate = v);
                      _recalcState();
                      _scheduleDraftSave();
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: DashboardColors.glassBorder),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_fix_high_rounded,
                    color: DashboardColors.neonGreen, size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Round-off to nearest Rupee',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                      Text('Automatically adjusts fraction paise to ₹0.00',
                          style: TextStyle(
                              color: DashboardColors.textMuted, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Switch(
                  value: _applyRoundOff,
                  activeColor: DashboardColors.neonGreen,
                  onChanged: (v) {
                    setState(() => _applyRoundOff = v);
                    _recalcState();
                    _scheduleDraftSave();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- E. TAX SUMMARY ----
  Widget _buildTaxSummaryCard() {
    final fmt = NumberFormat('#,##0.00', 'en_IN');
    return _sectionCard(
      icon: Icons.calculate_rounded,
      iconColor: DashboardColors.neonPurple,
      title: 'Bill Summary',
      child: Column(
        children: [
          _summaryRow('Subtotal (Gross)', fmt.format(_calc.subtotal),
              color: Colors.white),
          _summaryRow('Total Discount', '- ₹${fmt.format(_calc.totalDiscount)}',
              color: DashboardColors.neonOrange),
          _summaryRow('Taxable Value', '₹${fmt.format(_calc.taxableValue)}',
              color: Colors.white),
          const Divider(color: DashboardColors.glassBorder, height: 16),
          // GST slabs
          if (_calc.gstSlabs.isNotEmpty) ...[
            for (final slab in _calc.gstSlabs) ...[
              _summaryRow(
                'GST ${slab.rate.toStringAsFixed(0)}% on ₹${fmt.format(slab.taxable)}',
                '₹${fmt.format(slab.totalGst)}',
                color: DashboardColors.neonPurple,
                small: true,
              ),
              if (!_engine.isInterState) ...[
                _summaryRow('  CGST ${(slab.rate / 2).toStringAsFixed(1)}%',
                    '₹${fmt.format(slab.cgst)}',
                    color: DashboardColors.textMuted, small: true),
                _summaryRow('  SGST ${(slab.rate / 2).toStringAsFixed(1)}%',
                    '₹${fmt.format(slab.sgst)}',
                    color: DashboardColors.textMuted, small: true),
              ] else
                _summaryRow('  IGST ${slab.rate.toStringAsFixed(0)}%',
                    '₹${fmt.format(slab.igst)}',
                    color: DashboardColors.textMuted, small: true),
            ],
            const Divider(color: DashboardColors.glassBorder, height: 16),
          ],
          if (_calc.chargesTotal > 0)
            _summaryRow('Other Charges',
                '₹${fmt.format(_calc.chargesTotal)}',
                color: DashboardColors.neonOrange),
          if (_calc.roundOffPaise != 0)
            _summaryRow('Round Off',
                '${_calc.roundOff >= 0 ? '+' : ''}₹${fmt.format(_calc.roundOff.abs())}',
                color: DashboardColors.textMuted),
          const Divider(color: DashboardColors.glassBorder, height: 16),
          _summaryRow('Grand Total', '₹${fmt.format(_calc.grandTotal)}',
              color: DashboardColors.neonGreen, bold: true, large: true),

          // Mismatch warning
          if (_calc.hasMismatch) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: DashboardColors.neonOrange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: DashboardColors.neonOrange.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded,
                    color: DashboardColors.neonOrange, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Computed total differs from printed bill by '
                    '₹${((_calc.mismatchPaise ?? 0).abs() / 100).toStringAsFixed(2)}',
                    style: const TextStyle(
                        color: DashboardColors.neonOrange, fontSize: 12),
                  ),
                ),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryRow(
    String label,
    String value, {
    Color color = Colors.white,
    bool bold = false,
    bool small = false,
    bool large = false,
  }) {
    final fontSize = large ? 16.0 : (small ? 11.5 : 13.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  color: small
                      ? DashboardColors.textMuted
                      : DashboardColors.textLight,
                  fontSize: fontSize - (small ? 0 : 0))),
        ),
        Text(value,
            style: TextStyle(
                color: color,
                fontSize: fontSize,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
      ]),
    );
  }

  // ---- F. PAYMENT ----
  Widget _buildPaymentSection() {
    final fmt = NumberFormat('#,##0.00', 'en_IN');
    return _sectionCard(
      icon: Icons.payments_rounded,
      iconColor: DashboardColors.neonGreen,
      title: 'Payment',
      child: Column(
        children: [
          // Invoice balance lines
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: DashboardColors.glassBorder),
            ),
            child: Column(children: [
              _summaryRow('Invoice Total',
                  '₹${fmt.format(_calc.grandTotal)}'),
              _summaryRow('Paid Now',
                  '- ₹${fmt.format(_calc.paidAmount)}',
                  color: DashboardColors.neonGreen),
              const Divider(color: DashboardColors.glassBorder, height: 12),
              _summaryRow('Invoice Balance Due',
                  '₹${fmt.format(_calc.balanceDue)}',
                  color: _calc.balanceDue > 0
                      ? DashboardColors.alertRed
                      : DashboardColors.neonGreen,
                  bold: true),
              const SizedBox(height: 8),
              _summaryRow('Previous Vendor Balance',
                  '₹${fmt.format(_vendorPrevBalance)}',
                  color: DashboardColors.textMuted, small: true),
              _summaryRow('New Vendor Outstanding',
                  '₹${fmt.format(_vendorPrevBalance + _calc.balanceDue)}',
                  color: (_vendorPrevBalance + _calc.balanceDue) > 0
                      ? DashboardColors.neonOrange
                      : DashboardColors.neonGreen,
                  bold: true),
            ]),
          ),
          const SizedBox(height: 14),

          // Paid amount field
          _textField(
            _paidCtrl,
            'Amount Paid Now (₹)',
            Icons.currency_rupee_rounded,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) {
              _recalcState();
              _scheduleDraftSave();
            },
          ),
          const SizedBox(height: 12),

          // Payment method
          DropdownButtonFormField<String>(
            value: _paymentMethod,
            dropdownColor: const Color(0xFF0B1030),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              labelText: 'Payment Method',
              labelStyle: const TextStyle(
                  color: DashboardColors.textMuted, fontSize: 12),
              prefixIcon: const Icon(Icons.payment_rounded,
                  color: DashboardColors.neonBlue, size: 18),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.04),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: DashboardColors.glassBorder)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: DashboardColors.glassBorder)),
            ),
            items: ['Cash', 'UPI', 'Bank Transfer', 'Card', 'Cheque', 'Other']
                .map((m) =>
                    DropdownMenuItem(value: m, child: Text(m)))
                .toList(),
            onChanged: (v) {
              if (v != null) {
                setState(() => _paymentMethod = v);
                _scheduleDraftSave();
              }
            },
          ),
          const SizedBox(height: 12),

          _textField(
            _paymentRefCtrl,
            'Transaction Ref / UPI ID (optional)',
            Icons.tag_rounded,
            onChanged: (_) => _scheduleDraftSave(),
          ),
          const SizedBox(height: 12),

          _textField(
            _printedTotalCtrl,
            'Printed Bill Total (optional, for mismatch check)',
            Icons.receipt_outlined,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => _recalcState(),
          ),
        ],
      ),
    );
  }

  // ---- G. SAVE BUTTON ----
  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: DashboardColors.neonGreen,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          disabledBackgroundColor:
              DashboardColors.neonGreen.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          elevation: 4,
        ),
        icon: _isSaving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.black))
            : const Icon(Icons.check_circle_rounded, size: 20),
        label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            _isSaving ? 'Saving...' : 'Review & Save',
            style: DashboardTypography.poppins(
                fontSize: 14, fontWeight: FontWeight.w800),
          ),
        ),
        onPressed: _isSaving ? null : _save,
      ),
    );
  }

  // =========================================================================
  // SHARED CARD WRAPPER
  // =========================================================================
  Widget _sectionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: DashboardColors.glassCard(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Section header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 0),
            child: Row(children: [
              Icon(icon, color: iconColor, size: 18),
              const SizedBox(width: 10),
              Text(title,
                  style: DashboardTypography.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.white)),
              const Spacer(),
              if (trailing != null) trailing,
            ]),
          ),
          const SizedBox(height: 10),
          const Divider(
              height: 1,
              color: DashboardColors.glassBorder,
              indent: 16,
              endIndent: 16),
          Padding(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ],
      ),
    );
  }

  Widget _textField(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
    void Function(String)? onChanged,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboardType,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(
            color: DashboardColors.textMuted, fontSize: 12),
        prefixIcon:
            Icon(icon, color: DashboardColors.neonBlue, size: 18),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: DashboardColors.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: DashboardColors.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: DashboardColors.neonBlue, width: 1.5),
        ),
      ),
    );
  }
}

