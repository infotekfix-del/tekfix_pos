// =============================================================================
// TEKFIX ERP — SUPPLIER SEARCH & QUICK ADD BOTTOM SHEET
// Reusable sheet for selecting an existing supplier or quickly adding a new one.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
import 'purchase_bill_service.dart';

class SupplierSearchSheet extends StatefulWidget {
  const SupplierSearchSheet({super.key});

  /// Opens the supplier search sheet. Returns a Map with vendor details,
  /// or null if the user dismissed without selecting.
  static Future<Map<String, dynamic>?> show(BuildContext context) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SupplierSearchSheet(),
    );
  }

  @override
  State<SupplierSearchSheet> createState() => _SupplierSearchSheetState();
}

class _SupplierSearchSheetState extends State<SupplierSearchSheet> {
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _vendors = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _showAddForm = false;

  // Quick Add form
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _gstCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  String _stateCode = '';
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _vendors = PurchaseBillService.instance.getVendors();
    _filtered = List.from(_vendors);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _gstCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  void _filter(String q) {
    final lq = q.toLowerCase();
    setState(() {
      _filtered = _vendors.where((v) {
        return v['name'].toString().toLowerCase().contains(lq) ||
            v['phone'].toString().contains(lq) ||
            (v['gst'] ?? '').toString().toLowerCase().contains(lq);
      }).toList();
    });
  }

  void _onGstChanged(String val) {
    final clean = val.trim().toUpperCase();
    if (clean.length >= 2) {
      final code = clean.substring(0, 2);
      // Derive state from GSTIN prefix
      final stateMap = {
        '01': 'Jammu & Kashmir', '02': 'Himachal Pradesh',
        '03': 'Punjab', '04': 'Chandigarh', '05': 'Uttarakhand',
        '06': 'Haryana', '07': 'Delhi', '08': 'Rajasthan',
        '09': 'Uttar Pradesh', '10': 'Bihar', '11': 'Sikkim',
        '12': 'Arunachal Pradesh', '13': 'Nagaland', '14': 'Manipur',
        '15': 'Mizoram', '16': 'Tripura', '17': 'Meghalaya',
        '18': 'Assam', '19': 'West Bengal', '20': 'Jharkhand',
        '21': 'Odisha', '22': 'Chhattisgarh', '23': 'Madhya Pradesh',
        '24': 'Gujarat', '25': 'Daman & Diu', '26': 'Dadra & Nagar Haveli',
        '27': 'Maharashtra', '28': 'Andhra Pradesh', '29': 'Karnataka',
        '30': 'Goa', '31': 'Lakshadweep', '32': 'Kerala',
        '33': 'Tamil Nadu', '34': 'Puducherry', '35': 'Andaman & Nicobar',
        '36': 'Telangana', '37': 'Andhra Pradesh (New)',
      };
      setState(() {
        _stateCode = code;
        if (stateMap.containsKey(code)) {
          // Optionally pre-fill state field with label
        }
      });
    }
  }

  Future<void> _saveNewVendor() async {
    if (_nameCtrl.text.trim().isEmpty) {
      TekFeedback.error('Supplier name is required');
      return;
    }

    // Validate GSTIN if entered
    final gst = _gstCtrl.text.trim().toUpperCase();
    if (gst.isNotEmpty) {
      final gstRegex = RegExp(r'^\d{2}[A-Z]{5}\d{4}[A-Z]{1}[A-Z\d]{1}[Z]{1}[A-Z\d]{1}$');
      if (!gstRegex.hasMatch(gst)) {
        TekFeedback.error('Invalid GSTIN format. Expected: 22AAAAA0000A1Z5');
        return;
      }
    }

    setState(() => _isSaving = true);
    try {
      final result = await PurchaseBillService.instance.addNewVendor(
        name: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        gst: gst,
        address: _addressCtrl.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) TekFeedback.error('$e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0B1030),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: DashboardColors.glassBorderHover, width: 1.5),
            ),
          ),
          child: Column(
            children: [
              // Handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 8),
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: DashboardColors.glassBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.business_rounded,
                        color: DashboardColors.neonBlue, size: 22),
                    const SizedBox(width: 10),
                    Text(
                      _showAddForm ? 'Quick Add Supplier' : 'Select Supplier',
                      style: DashboardTypography.poppins(
                          fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    if (!_showAddForm)
                      TextButton.icon(
                        icon: const Icon(Icons.add_rounded,
                            color: DashboardColors.neonGreen, size: 18),
                        label: const Text('New Supplier',
                            style: TextStyle(
                                color: DashboardColors.neonGreen,
                                fontWeight: FontWeight.w600)),
                        onPressed: () => setState(() => _showAddForm = true),
                      )
                    else
                      TextButton(
                        onPressed: () => setState(() => _showAddForm = false),
                        child: const Text('Back to Search',
                            style: TextStyle(color: DashboardColors.textMuted)),
                      ),
                  ],
                ),
              ),

              const Divider(
                  height: 1, color: DashboardColors.glassBorder, indent: 16, endIndent: 16),
              const SizedBox(height: 8),

              if (_showAddForm)
                Expanded(child: _buildAddForm())
              else
                Expanded(child: _buildSearchList(scrollCtrl)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSearchList(ScrollController scrollCtrl) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _searchCtrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search by name, phone, or GSTIN...',
              hintStyle: const TextStyle(
                  color: DashboardColors.textMuted, fontSize: 13),
              prefixIcon: const Icon(Icons.search_rounded,
                  color: DashboardColors.neonBlue, size: 18),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: DashboardColors.glassBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: DashboardColors.glassBorder),
              ),
            ),
            onChanged: _filter,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.search_off_rounded,
                          color: DashboardColors.textMuted, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        _searchCtrl.text.isEmpty
                            ? 'No suppliers found.\nTap "New Supplier" to add one.'
                            : 'No match for "${_searchCtrl.text}"',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: DashboardColors.textMuted, fontSize: 14),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _filtered.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: DashboardColors.glassBorder),
                  itemBuilder: (ctx, i) {
                    final v = _filtered[i];
                    final balance = (v['balance'] as num?)?.toDouble() ?? 0.0;
                    return ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                      leading: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          gradient: DashboardColors.activePillGradient,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(
                            (v['name'] as String).isNotEmpty
                                ? (v['name'] as String)[0].toUpperCase()
                                : 'S',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 17),
                          ),
                        ),
                      ),
                      title: Text(
                        v['name']?.toString() ?? '',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if ((v['phone'] ?? '').toString().isNotEmpty)
                            Text(v['phone'].toString(),
                                style: const TextStyle(
                                    color: DashboardColors.textMuted,
                                    fontSize: 12)),
                          if ((v['gst'] ?? '').toString().isNotEmpty)
                            Text('GSTIN: ${v['gst']}',
                                style: const TextStyle(
                                    color: DashboardColors.neonBlue,
                                    fontSize: 11)),
                        ],
                      ),
                      trailing: balance > 0
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: DashboardColors.alertOrange
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'Due: ₹${NumberFormat('#,##0', 'en_IN').format(balance)}',
                                style: const TextStyle(
                                    color: DashboardColors.alertOrange,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700),
                              ),
                            )
                          : null,
                      onTap: () => Navigator.of(context).pop(v),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildAddForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          _field(_nameCtrl, 'Supplier Name *', Icons.store_rounded),
          const SizedBox(height: 12),
          _field(_phoneCtrl, 'Phone Number *', Icons.phone_rounded,
              keyboardType: TextInputType.phone),
          const SizedBox(height: 12),
          _field(
            _gstCtrl,
            'GSTIN (optional)',
            Icons.numbers_rounded,
            hint: '22AAAAA0000A1Z5',
            onChanged: _onGstChanged,
          ),
          if (_stateCode.isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text('State Code: $_stateCode',
                    style: const TextStyle(
                        color: DashboardColors.neonBlue, fontSize: 12)),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _field(_addressCtrl, 'Address (optional)', Icons.location_on_rounded,
              maxLines: 2),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: DashboardColors.neonGreen,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
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
                  : const Icon(Icons.save_rounded, size: 18),
              label: Text(
                _isSaving ? 'Saving...' : 'Save Supplier',
                style: DashboardTypography.poppins(
                    fontSize: 14, fontWeight: FontWeight.w700),
              ),
              onPressed: _isSaving ? null : _saveNewVendor,
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    TextInputType keyboardType = TextInputType.text,
    String? hint,
    int maxLines = 1,
    void Function(String)? onChanged,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboardType,
      maxLines: maxLines,
      onChanged: onChanged,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: DashboardColors.textMuted),
        hintText: hint,
        hintStyle: const TextStyle(
            color: DashboardColors.textDarkMuted, fontSize: 12),
        prefixIcon: Icon(icon, color: DashboardColors.neonBlue, size: 18),
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

