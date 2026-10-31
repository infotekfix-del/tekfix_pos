// =============================================================================
// TEKFIX ERP — QUICK REGISTER PRODUCT DRAWER
// Inline bottom sheet for registering a new product without navigating away.
// Returns the newly created product data so the purchase line can be updated.
// =============================================================================

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart' show Db;
import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
import 'purchase_bill_service.dart';

class QuickRegisterDrawer extends StatefulWidget {
  /// Pre-filled data from the extracted invoice row.
  final String prefillName;
  final String prefillBrand;
  final String prefillModel;
  final String prefillSku;
  final double prefillGstRate;
  final String prefillHsn;
  final double prefillMrp;
  final double prefillSellingPrice;

  const QuickRegisterDrawer({
    super.key,
    this.prefillName = '',
    this.prefillBrand = '',
    this.prefillModel = '',
    this.prefillSku = '',
    this.prefillGstRate = 0.0,
    this.prefillHsn = '',
    this.prefillMrp = 0.0,
    this.prefillSellingPrice = 0.0,
  });

  /// Opens Quick Register as a modal bottom sheet.
  /// Returns the registered product data map, or null if dismissed.
  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    String prefillName = '',
    String prefillBrand = '',
    String prefillModel = '',
    String prefillSku = '',
    double prefillGstRate = 0.0,
    String prefillHsn = '',
    double prefillMrp = 0.0,
    double prefillSellingPrice = 0.0,
  }) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QuickRegisterDrawer(
        prefillName: prefillName,
        prefillBrand: prefillBrand,
        prefillModel: prefillModel,
        prefillSku: prefillSku,
        prefillGstRate: prefillGstRate,
        prefillHsn: prefillHsn,
        prefillMrp: prefillMrp,
        prefillSellingPrice: prefillSellingPrice,
      ),
    );
  }

  @override
  State<QuickRegisterDrawer> createState() => _QuickRegisterDrawerState();
}

class _QuickRegisterDrawerState extends State<QuickRegisterDrawer> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _brandCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _skuCtrl;
  late final TextEditingController _barcodeCtrl;
  late final TextEditingController _categoryCtrl;
  late final TextEditingController _hsnCtrl;
  late final TextEditingController _mrpCtrl;
  late final TextEditingController _sellingPriceCtrl;
  late final TextEditingController _warrantyCtrl;

  double _gstRate = 0.0;
  String _unit = 'Piece';
  bool _trackImei = false;
  bool _isSaving = false;
  String? _saveError;

  static const _units = ['Piece', 'Box', 'Bundle', 'Pair', 'Set', 'Kg', 'Gram', 'Litre', 'Metre'];
  static const _gstRates = [0.0, 3.0, 5.0, 12.0, 18.0, 28.0];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.prefillName);
    _brandCtrl = TextEditingController(text: widget.prefillBrand);
    _modelCtrl = TextEditingController(text: widget.prefillModel);
    _skuCtrl = TextEditingController(text: widget.prefillSku);
    _barcodeCtrl = TextEditingController();
    _categoryCtrl = TextEditingController(text: 'General');
    _hsnCtrl = TextEditingController(text: widget.prefillHsn);
    _mrpCtrl = TextEditingController(
        text: widget.prefillMrp > 0 ? widget.prefillMrp.toStringAsFixed(0) : '');
    _sellingPriceCtrl = TextEditingController(
        text: widget.prefillSellingPrice > 0
            ? widget.prefillSellingPrice.toStringAsFixed(0)
            : '');
    _warrantyCtrl = TextEditingController(text: 'No Warranty');
    _gstRate = widget.prefillGstRate;
  }

  @override
  void dispose() {
    for (final c in [
      _nameCtrl, _brandCtrl, _modelCtrl, _skuCtrl, _barcodeCtrl,
      _categoryCtrl, _hsnCtrl, _mrpCtrl, _sellingPriceCtrl, _warrantyCtrl
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final name = _nameCtrl.text.trim();
    var sku = _skuCtrl.text.trim();
    var barcode = _barcodeCtrl.text.trim();

    // Auto-generate SKU and Barcode if left blank
    if (sku.isEmpty) {
      sku = 'SKU_${DateTime.now().millisecondsSinceEpoch}';
    }
    if (barcode.isEmpty) {
      barcode = 'TKF${DateTime.now().millisecondsSinceEpoch.toString().substring(3)}';
    }

    final mrp = double.tryParse(_mrpCtrl.text) ?? 0.0;
    final sp = double.tryParse(_sellingPriceCtrl.text) ?? 0.0;

    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    try {
      // Duplicate check by SKU/barcode in local catalog
      for (final k in Db.items.keys) {
        final raw = Db.items.get(k);
        if (raw is! Map) continue;
        final existingSku = raw['sku']?.toString().trim() ?? '';
        final existingBarcode = raw['barcode']?.toString().trim() ?? '';
        if (_skuCtrl.text.trim().isNotEmpty && existingSku == sku) {
          throw Exception('A product with SKU "$sku" already exists: ${raw['name']}');
        }
        if (_barcodeCtrl.text.trim().isNotEmpty && existingBarcode == barcode) {
          throw Exception('A product with barcode "$barcode" already exists: ${raw['name']}');
        }
      }

      // Create product in Firestore if available
      String? firestoreProductId;
      if (Firebase.apps.isNotEmpty) {
        final shopId = Db.setting('shop_id', 'tekfix');
        try {
          final docRef = FirebaseFirestore.instance
              .collection('shops')
              .doc(shopId)
              .collection('products')
              .doc();
          firestoreProductId = docRef.id;

          await docRef.set({
            'id': firestoreProductId,
            'name': name,
            'normalizedName': PurchaseBillService.normalizeProductName(name),
            'brand': _brandCtrl.text.trim(),
            'model': _modelCtrl.text.trim(),
            'category': _categoryCtrl.text.trim().isNotEmpty
                ? _categoryCtrl.text.trim()
                : 'General',
            'sku': sku.isNotEmpty ? sku : firestoreProductId,
            'barcode': barcode.isNotEmpty ? barcode : sku,
            'hsn': _hsnCtrl.text.trim(),
            'gstRate': _gstRate,
            'mrp': mrp,
            'sellingPrice': sp,
            'mrpPaise': (mrp * 100).round(),
            'sellingPricePaise': (sp * 100).round(),
            'unit': _unit,
            'currentStock': 0,
            'imeiRequired': _trackImei,
            'warrantyDuration': _warrantyCtrl.text.trim(),
            'registeredViaQuickRegister': true,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } catch (e) {
          debugPrint('[QuickRegister] Firestore write warning: $e');
        }
      }

      // Local Hive catalog
      final newItem = <String, dynamic>{
        'name': name,
        'normalizedName': PurchaseBillService.normalizeProductName(name),
        'brand': _brandCtrl.text.trim(),
        'model': _modelCtrl.text.trim(),
        'category': _categoryCtrl.text.trim().isNotEmpty
            ? _categoryCtrl.text.trim()
            : 'General',
        'sku': sku,
        'barcode': barcode.isNotEmpty ? barcode : sku,
        'hsn': _hsnCtrl.text.trim(),
        'gstRate': _gstRate,
        'mrp': mrp,
        'sellingPrice': sp,
        'costPrice': 0.0,
        'stock': 0,
        'unit': _unit,
        'imeiRequired': _trackImei,
        'warranty': _warrantyCtrl.text.trim(),
        if (firestoreProductId != null) '_id': firestoreProductId,
      };
      final hiveKey = await Db.items.add(newItem);

      final resultMap = <String, dynamic>{
        ...newItem,
        'key': hiveKey,
        'id': firestoreProductId ?? '$hiveKey',
        'matchedProductId': firestoreProductId ?? '$hiveKey',
        'matchedProductName': name,
      };

      if (mounted) {
        TekFeedback.success('Product "$name" registered successfully');
        Navigator.of(context).pop(resultMap);
      }
    } catch (e) {
      setState(() => _saveError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.97,
      expand: false,
      builder: (ctx, scrollCtrl) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0B1030),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: DashboardColors.neonGreen, width: 1.5),
            ),
          ),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                // Handle
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 4),
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: DashboardColors.neonGreen.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: DashboardColors.neonGreen.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.add_box_rounded,
                            color: DashboardColors.neonGreen, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Quick Register Product',
                              style: DashboardTypography.poppins(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                          const Text('New product — stock added after bill save',
                              style: TextStyle(
                                  color: DashboardColors.textMuted,
                                  fontSize: 11)),
                        ],
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: DashboardColors.textMuted),
                        onPressed: () => Navigator.of(context).pop(null),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: DashboardColors.glassBorder),

                // Error banner
                if (_saveError != null)
                  Container(
                    margin: const EdgeInsets.all(12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: DashboardColors.alertRed.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: DashboardColors.alertRed.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            color: DashboardColors.alertRed, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_saveError!,
                              style: const TextStyle(
                                  color: DashboardColors.alertRed,
                                  fontSize: 13)),
                        ),
                      ],
                    ),
                  ),

                // Form fields
                Expanded(
                  child: ListView(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    children: [
                      _sectionLabel('Product Identity'),
                      _fField('Product Name *', _nameCtrl,
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Product name is required'
                              : null),
                      _row([
                        _fField('Brand', _brandCtrl),
                        _fField('Model / Part No.', _modelCtrl),
                      ]),
                      _row([
                        _fField('Category', _categoryCtrl),
                        _fField('SKU / Code', _skuCtrl),
                      ]),
                      _fField('Barcode (auto-generated if blank)', _barcodeCtrl,
                          hint: 'Leave blank to auto-generate unique barcode'),

                      const SizedBox(height: 16),
                      _sectionLabel('Pricing & Tax'),
                      _row([
                        _fField('MRP (₹)', _mrpCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                        _fField('Selling Price (₹)', _sellingPriceCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                      ]),
                      _row([
                        _dropdownGst(),
                        _fField('HSN Code', _hsnCtrl,
                            keyboardType: TextInputType.number),
                      ]),

                      const SizedBox(height: 16),
                      _sectionLabel('Unit & Tracking'),
                      _row([
                        _dropdownUnit(),
                        _dropdownWarranty(),
                      ]),

                      // Track IMEI toggle
                      Container(
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.03),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: _trackImei
                                  ? DashboardColors.neonGreen
                                      .withValues(alpha: 0.4)
                                  : DashboardColors.glassBorder),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.qr_code_scanner_rounded,
                                color: DashboardColors.neonBlue, size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Track IMEI / Serial Numbers',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600)),
                                  const Text(
                                      'Each unit will require a unique IMEI or serial.',
                                      style: TextStyle(
                                          color: DashboardColors.textMuted,
                                          fontSize: 11)),
                                  if (_trackImei)
                                    const Text(
                                      '(IMEI entry will be required during stock-in — Phase 3)',
                                      style: TextStyle(
                                          color: DashboardColors.neonGreen,
                                          fontSize: 10),
                                    ),
                                ],
                              ),
                            ),
                            Switch(
                              value: _trackImei,
                              activeColor: DashboardColors.neonGreen,
                              onChanged: (v) => setState(() => _trackImei = v),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Save button
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: DashboardColors.neonGreen,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: _isSaving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.black),
                              )
                            : const Icon(Icons.check_circle_rounded, size: 20),
                        label: Text(
                          _isSaving ? 'Registering...' : 'Register & Link to Purchase Line',
                          style: DashboardTypography.poppins(
                              fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                        onPressed: _isSaving ? null : _save,
                      ),
                      const SizedBox(height: 30),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(text,
            style: const TextStyle(
                color: DashboardColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8)),
      );

  Widget _row(List<Widget> children) => Row(
        children: children
            .map((c) => Expanded(
                child: Padding(
                    padding: const EdgeInsets.only(right: 8, bottom: 12),
                    child: c)))
            .toList(),
      );

  Widget _fField(
    String label,
    TextEditingController ctrl, {
    TextInputType keyboardType = TextInputType.text,
    String? hint,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: ctrl,
        keyboardType: keyboardType,
        validator: validator,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        inputFormatters: keyboardType == TextInputType.number ||
                keyboardType ==
                    const TextInputType.numberWithOptions(decimal: true)
            ? [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))]
            : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(
              color: DashboardColors.textMuted, fontSize: 12),
          hintStyle: const TextStyle(
              color: DashboardColors.textDarkMuted, fontSize: 11),
          isDense: true,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.04),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: DashboardColors.glassBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: DashboardColors.glassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(
                color: DashboardColors.neonBlue, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: DashboardColors.alertRed),
          ),
        ),
      ),
    );
  }

  Widget _dropdownGst() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<double>(
        value: _gstRate,
        dropdownColor: const Color(0xFF0B1030),
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          labelText: 'GST Rate %',
          labelStyle: const TextStyle(
              color: DashboardColors.textMuted, fontSize: 12),
          isDense: true,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.04),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: DashboardColors.glassBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: DashboardColors.glassBorder),
          ),
        ),
        items: _gstRates
            .map((r) => DropdownMenuItem(
                value: r,
                child: Text('${r.toStringAsFixed(r == r.truncateToDouble() ? 0 : 1)}%')))
            .toList(),
        onChanged: (v) {
          if (v != null) setState(() => _gstRate = v);
        },
      ),
    );
  }

  Widget _dropdownUnit() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: _unit,
        dropdownColor: const Color(0xFF0B1030),
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          labelText: 'Unit',
          labelStyle: const TextStyle(
              color: DashboardColors.textMuted, fontSize: 12),
          isDense: true,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.04),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: DashboardColors.glassBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: DashboardColors.glassBorder),
          ),
        ),
        items: _units
            .map((u) => DropdownMenuItem(value: u, child: Text(u)))
            .toList(),
        onChanged: (v) {
          if (v != null) setState(() => _unit = v);
        },
      ),
    );
  }

  Widget _dropdownWarranty() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: _warrantyCtrl.text.isNotEmpty ? _warrantyCtrl.text : 'No Warranty',
        dropdownColor: const Color(0xFF0B1030),
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          labelText: 'Default Warranty',
          labelStyle: const TextStyle(
              color: DashboardColors.textMuted, fontSize: 12),
          isDense: true,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.04),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: DashboardColors.glassBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: DashboardColors.glassBorder),
          ),
        ),
        items: const [
          'No Warranty',
          '1 Month',
          '3 Months',
          '6 Months',
          '12 Months',
          '24 Months',
        ].map((w) => DropdownMenuItem(value: w, child: Text(w))).toList(),
        onChanged: (v) {
          if (v != null) setState(() => _warrantyCtrl.text = v);
        },
      ),
    );
  }
}

