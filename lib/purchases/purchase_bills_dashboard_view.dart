import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show boxPurchaseBills;
import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
import 'manual_purchase_draft_service.dart';
import 'manual_purchase_entry_screen.dart';
import 'purchase_bill_details_screen.dart';
import 'purchase_bill_service.dart';
import 'purchase_bill_upload_screen.dart';
import 'purchase_models.dart';
import 'vendor_ledger_screen.dart';

class PurchaseBillsDashboardView extends StatefulWidget {
  const PurchaseBillsDashboardView({super.key});

  @override
  State<PurchaseBillsDashboardView> createState() =>
      _PurchaseBillsDashboardViewState();
}

class _PurchaseBillsDashboardViewState
    extends State<PurchaseBillsDashboardView> {
  final _searchCtrl = TextEditingController();

  String _statusFilter = 'All';
  dynamic _selectedVendorKey;
  DateTimeRange? _selectedDateRange;
  String _dateRangePreset = 'All Time';
  int _vendorSubTab = 0; // 0 = Bills, 1 = Payment History

  int _currentPage = 0;
  static const int _pageSize = 15;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _clearFilters() {
    setState(() {
      _searchCtrl.clear();
      _statusFilter = 'All';
      _selectedVendorKey = null;
      _selectedDateRange = null;
      _dateRangePreset = 'All Time';
      _vendorSubTab = 0;
      _currentPage = 0;
    });
  }

  void _applyDatePreset(String preset) {
    final now = DateTime.now();
    setState(() {
      _dateRangePreset = preset;
      _currentPage = 0;
      switch (preset) {
        case 'Today':
          final start = DateTime(now.year, now.month, now.day);
          final end = DateTime(now.year, now.month, now.day, 23, 59, 59);
          _selectedDateRange = DateTimeRange(start: start, end: end);
          break;
        case 'This Week':
          final start = now.subtract(Duration(days: now.weekday - 1));
          final sDate = DateTime(start.year, start.month, start.day);
          _selectedDateRange = DateTimeRange(start: sDate, end: now);
          break;
        case 'This Month':
          final start = DateTime(now.year, now.month, 1);
          _selectedDateRange = DateTimeRange(start: start, end: now);
          break;
        default:
          _selectedDateRange = null;
          break;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Advance Payment Modal
  // ---------------------------------------------------------------------------

  void _showRecordAdvancePaymentDialog({dynamic preselectedVendorKey}) {
    final vendors = PurchaseBillService.instance.getVendors();
    dynamic selVendorKey = preselectedVendorKey;
    String selVendorName = '';
    if (preselectedVendorKey != null) {
      final found = vendors.cast<Map<String, dynamic>?>().firstWhere(
            (v) => v?['key'] == preselectedVendorKey,
            orElse: () => null,
          );
      if (found != null) {
        selVendorName = found['name']?.toString() ?? '';
      }
    }
    final amountCtrl = TextEditingController();
    final refCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    String payMethod = 'Bank Transfer';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF101846),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: DashboardColors.glassBorderHover),
            ),
            title: Row(
              children: [
                const Icon(Icons.outbox_rounded,
                    color: DashboardColors.neonGreen),
                const SizedBox(width: 10),
                Text('Record Advance Payment to Vendor',
                    style: DashboardTypography.poppins(
                        fontSize: 18, fontWeight: FontWeight.w700)),
              ],
            ),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<dynamic>(
                      value: selVendorKey,
                      dropdownColor: const Color(0xFF101846),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Select Vendor *',
                        labelStyle:
                            const TextStyle(color: DashboardColors.textMuted),
                        prefixIcon: const Icon(Icons.business_rounded,
                            color: DashboardColors.neonBlue),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: DashboardColors.glassBorder),
                        ),
                      ),
                      items: vendors.map((v) {
                        return DropdownMenuItem<dynamic>(
                          value: v['key'],
                          child: Text('${v['name']} (${v['phone']})',
                              overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (k) {
                        final found = vendors.firstWhere((v) => v['key'] == k,
                            orElse: () => {});
                        setModalState(() {
                          selVendorKey = k;
                          selVendorName = found['name'] ?? '';
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: amountCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Advance Amount (₹) *',
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
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: payMethod,
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
                          borderSide: const BorderSide(
                              color: DashboardColors.glassBorder),
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
                        return DropdownMenuItem<String>(
                            value: m, child: Text(m));
                      }).toList(),
                      onChanged: (v) {
                        if (v != null) setModalState(() => payMethod = v);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: refCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Transaction Reference / Cheque No.',
                        labelStyle:
                            const TextStyle(color: DashboardColors.textMuted),
                        prefixIcon: const Icon(Icons.tag_rounded,
                            color: DashboardColors.neonBlue),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: DashboardColors.glassBorder),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: notesCtrl,
                      maxLines: 2,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Notes / Remarks (Optional)',
                        labelStyle:
                            const TextStyle(color: DashboardColors.textMuted),
                        prefixIcon: const Icon(Icons.notes_rounded,
                            color: DashboardColors.neonBlue),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: DashboardColors.glassBorder),
                        ),
                      ),
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
                  backgroundColor: DashboardColors.neonGreen,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  if (selVendorKey == null) {
                    TekFeedback.error('Please select a vendor');
                    return;
                  }
                  final amt = double.tryParse(amountCtrl.text) ?? 0.0;
                  if (amt <= 0) {
                    TekFeedback.error('Please enter a valid amount');
                    return;
                  }

                  final auth =
                      Provider.of<AuthController>(context, listen: false);
                  try {
                    await PurchaseBillService.instance.recordAdvancePayment(
                      vendorKey: selVendorKey,
                      vendorName: selVendorName,
                      amount: amt,
                      paymentMethod: payMethod,
                      transactionReference: refCtrl.text.trim(),
                      notes: notesCtrl.text.trim(),
                      staffId: auth.uid,
                      staffName: auth.name.isNotEmpty ? auth.name : 'Owner',
                    );
                    Navigator.pop(ctx);
                    TekFeedback.success(
                        'Advance payment of ₹${amt.toStringAsFixed(2)} recorded for $selVendorName');
                  } catch (e) {
                    TekFeedback.error('$e');
                  }
                },
                child: const Text('Confirm Payment',
                    style: TextStyle(
                        color: Colors.black, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build Main Dashboard
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!Hive.isBoxOpen(boxPurchaseBills)) {
      return const Center(
        child: CircularProgressIndicator(color: DashboardColors.neonBlue),
      );
    }

    final billsBox = Hive.box(boxPurchaseBills);

    return ValueListenableBuilder(
      valueListenable: billsBox.listenable(),
      builder: (context, Box box, _) {
        final metrics = PurchaseBillService.instance.getDashboardMetrics();
        final vendors = PurchaseBillService.instance.getVendors();

        // Filter bills
        final filteredBills = PurchaseBillService.instance.searchPurchaseBills(
          query: _searchCtrl.text,
          vendorKey: _selectedVendorKey,
          status: _statusFilter,
          startDate: _selectedDateRange?.start,
          endDate: _selectedDateRange?.end,
        );

        final totalPages = (filteredBills.length / _pageSize).ceil();
        final startIndex = _currentPage * _pageSize;
        final endIndex = (startIndex + _pageSize).clamp(0, filteredBills.length);
        final pageBills = startIndex < filteredBills.length
            ? filteredBills.sublist(startIndex, endIndex)
            : <PurchaseBill>[];

        return Container(
          color: DashboardColors.bgDarkNavyStart,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. TOP HEADER & ACTION BUTTONS
                _buildHeader(context),
                const SizedBox(height: 20),

                // 2. 9 KPI SUMMARY METRIC CARDS
                _buildSummaryCards(metrics),
                const SizedBox(height: 24),

                // 3. FILTER BAR
                _buildFilterBar(vendors),
                const SizedBox(height: 16),

                // 3B. VENDOR SUMMARY & PROFILE CARD (When a vendor is selected)
                if (_selectedVendorKey != null) ...[
                  _buildVendorProfileCard(vendors, filteredBills),
                  const SizedBox(height: 16),
                ],

                // 4. BILLS TABLE OR PAYMENTS TABLE (Vendor sub-tab)
                if (_selectedVendorKey != null && _vendorSubTab == 1)
                  _buildVendorPaymentsTable()
                else
                  _buildBillsTable(pageBills, filteredBills.length),
                const SizedBox(height: 16),

                // 5. PAGINATION (for bills)
                if (_vendorSubTab == 0 && totalPages > 1) _buildPagination(totalPages),
                const SizedBox(height: 40),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 1. Header
  // ---------------------------------------------------------------------------

  Widget _buildHeader(BuildContext context) {
    final titleWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            gradient: DashboardColors.activePillGradient,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.receipt_long_rounded,
              color: Colors.white, size: 24),
        ),
        const SizedBox(width: 14),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Purchase Bills & Vendor Payments',
                style: DashboardTypography.poppins(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                'Manage supplier invoices, document uploads, inventory updates & vendor ledgers',
                style: DashboardTypography.inter(
                  fontSize: 12.5,
                  color: DashboardColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final buttonsWidget = Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
            // Advance Payment Button
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: DashboardColors.neonGreen,
                side: const BorderSide(color: DashboardColors.neonGreen),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.outbox_rounded, size: 18),
              label: const Text('Record Advance Payment',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onPressed: _showRecordAdvancePaymentDialog,
            ),
            const SizedBox(width: 12),

            // Vendor Ledgers Button
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: DashboardColors.neonPurple,
                side: const BorderSide(color: DashboardColors.neonPurple),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.menu_book_rounded, size: 18),
              label: const Text('Vendor Ledgers',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const VendorLedgerScreen()),
                );
              },
            ),
            const SizedBox(width: 12),

            // Resume Draft Button (if draft exists)
            if (ManualPurchaseDraftService.instance.hasDraft()) ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: DashboardColors.neonOrange,
                  side: const BorderSide(color: DashboardColors.neonOrange),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: const Text('Resume Draft',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ManualPurchaseEntryScreen()),
                  );
                },
              ),
              const SizedBox(width: 12),
            ],

            // Choice A: [ Upload / Capture Bill ]
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: DashboardColors.neonBlue,
                side: const BorderSide(color: DashboardColors.neonBlue, width: 1.5),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.document_scanner_rounded, size: 18),
              label: Text(
                'Upload / Capture Bill',
                style: DashboardTypography.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: DashboardColors.neonBlue,
                ),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const PurchaseBillUploadScreen(),
                  ),
                );
              },
            ),
            const SizedBox(width: 12),

            // Choice B: [ Manual Purchase Entry ]
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: DashboardColors.neonGreen,
                foregroundColor: Colors.black,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 4,
                shadowColor: DashboardColors.neonGreen.withValues(alpha: 0.4),
              ),
              icon: const Icon(Icons.edit_note_rounded,
                  color: Colors.black, size: 20),
              label: Text(
                'Manual Purchase Entry',
                style: DashboardTypography.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.black,
                ),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ManualPurchaseEntryScreen(),
                  ),
                );
              },
            ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 1350) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleWidget,
              const SizedBox(height: 14),
              buttonsWidget,
            ],
          );
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: titleWidget),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerRight,
                child: buttonsWidget,
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 2. Summary Metric Cards (9 Cards)
  // ---------------------------------------------------------------------------

  Widget _buildSummaryCards(Map<String, dynamic> m) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = (constraints.maxWidth - (8 * 14)) / 9;
        final safeWidth = cardWidth < 140 ? 140.0 : cardWidth;

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildMetricCard(
                title: 'Total Bills',
                value: '${m['totalBills'] ?? 0}',
                subtitle: 'All saved bills',
                icon: Icons.receipt_rounded,
                color: DashboardColors.neonBlue,
                width: safeWidth,
                isSelected: _statusFilter == 'All',
                onTap: () => setState(() {
                  _statusFilter = 'All';
                  _currentPage = 0;
                }),
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'Total Value',
                value: '₹${(m['totalPurchaseValue'] ?? 0.0).toStringAsFixed(0)}',
                subtitle: 'Gross purchases',
                icon: Icons.currency_rupee_rounded,
                color: DashboardColors.neonGreen,
                width: safeWidth,
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'Total Paid',
                value: '₹${(m['totalPaid'] ?? 0.0).toStringAsFixed(0)}',
                subtitle: 'Disbursed to vendors',
                icon: Icons.payments_rounded,
                color: DashboardColors.neonGreen,
                width: safeWidth,
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'Outstanding Payables',
                value: '₹${(m['totalOutstanding'] ?? 0.0).toStringAsFixed(0)}',
                subtitle: 'Debt due to suppliers',
                icon: Icons.pending_actions_rounded,
                color: DashboardColors.alertOrange,
                width: safeWidth,
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'Fully Paid',
                value: '${m['fullyPaidBills'] ?? 0}',
                subtitle: 'Tap to filter',
                icon: Icons.check_circle_rounded,
                color: DashboardColors.neonGreen,
                width: safeWidth,
                isSelected: _statusFilter == BillPaymentStatus.paid,
                onTap: () => setState(() {
                  _statusFilter = _statusFilter == BillPaymentStatus.paid ? 'All' : BillPaymentStatus.paid;
                  _currentPage = 0;
                }),
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'Partially Paid',
                value: '${m['partiallyPaidBills'] ?? 0}',
                subtitle: 'Tap to filter',
                icon: Icons.timelapse_rounded,
                color: DashboardColors.neonBlue,
                width: safeWidth,
                isSelected: _statusFilter == BillPaymentStatus.partiallyPaid,
                onTap: () => setState(() {
                  _statusFilter = _statusFilter == BillPaymentStatus.partiallyPaid ? 'All' : BillPaymentStatus.partiallyPaid;
                  _currentPage = 0;
                }),
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'Unpaid Bills',
                value: '${m['unpaidBills'] ?? 0}',
                subtitle: 'Tap to filter unpaid',
                icon: Icons.hourglass_top_rounded,
                color: DashboardColors.alertOrange,
                width: safeWidth,
                isSelected: _statusFilter == BillPaymentStatus.unpaid,
                onTap: () => setState(() {
                  _statusFilter = _statusFilter == BillPaymentStatus.unpaid ? 'All' : BillPaymentStatus.unpaid;
                  _currentPage = 0;
                }),
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'Uploaded Today',
                value: '${m['billsUploadedToday'] ?? 0}',
                subtitle: 'New entries today',
                icon: Icons.today_rounded,
                color: DashboardColors.neonPurple,
                width: safeWidth,
                isSelected: _dateRangePreset == 'Today',
                onTap: () => setState(() {
                  _dateRangePreset = _dateRangePreset == 'Today' ? 'All Time' : 'Today';
                  _applyDatePreset(_dateRangePreset);
                  _currentPage = 0;
                }),
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'This Month',
                value: '₹${(m['purchasesThisMonth'] ?? 0.0).toStringAsFixed(0)}',
                subtitle: 'Current month total',
                icon: Icons.calendar_month_rounded,
                color: DashboardColors.neonPink,
                width: safeWidth,
                isSelected: _dateRangePreset == 'This Month',
                onTap: () => setState(() {
                  _dateRangePreset = _dateRangePreset == 'This Month' ? 'All Time' : 'This Month';
                  _applyDatePreset(_dateRangePreset);
                  _currentPage = 0;
                }),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    required double width,
    VoidCallback? onTap,
    bool isSelected = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? color : color.withValues(alpha: 0.25),
            width: isSelected ? 2 : 1,
          ),
        ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: DashboardColors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 4),
              Icon(icon, color: color, size: 16),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: DashboardTypography.poppins(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: color,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(
                color: DashboardColors.textDarkMuted, fontSize: 10),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    ),
  );
}

  // ---------------------------------------------------------------------------
  // 3. Filter Bar
  // ---------------------------------------------------------------------------

  Widget _buildFilterBar(List<Map<String, dynamic>> vendors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: Row(
        children: [
          // Search box
          Expanded(
            flex: 3,
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText:
                    'Search by Bill #, Invoice #, Vendor Name, or Item Name...',
                hintStyle: const TextStyle(
                    color: DashboardColors.textMuted, fontSize: 13),
                prefixIcon: const Icon(Icons.search_rounded,
                    color: DashboardColors.neonBlue, size: 18),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded,
                            size: 16, color: DashboardColors.textMuted),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _currentPage = 0);
                        },
                      )
                    : null,
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.04),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (_) => setState(() => _currentPage = 0),
            ),
          ),
          const SizedBox(width: 12),

          // Vendor Filter Dropdown
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<dynamic>(
              isExpanded: true,
              value: _selectedVendorKey,
              dropdownColor: const Color(0xFF101846),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.04),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              hint: const Text('All Vendors',
                  style: TextStyle(
                      color: DashboardColors.textMuted, fontSize: 13)),
              items: [
                const DropdownMenuItem<dynamic>(
                  value: null,
                  child: Text('All Vendors'),
                ),
                ...vendors.map((v) {
                  return DropdownMenuItem<dynamic>(
                    value: v['key'],
                    child: Text(v['name'], overflow: TextOverflow.ellipsis),
                  );
                }),
              ],
              onChanged: (k) => setState(() {
                _selectedVendorKey = k;
                _currentPage = 0;
              }),
            ),
          ),
          const SizedBox(width: 12),

          // Status Filter
          DropdownButton<String>(
            value: _statusFilter,
            dropdownColor: const Color(0xFF101846),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            underline: const SizedBox(),
            items: [
              'All',
              BillPaymentStatus.paid,
              BillPaymentStatus.partiallyPaid,
              BillPaymentStatus.unpaid,
              BillPaymentStatus.draft,
            ].map<DropdownMenuItem<String>>((s) {
              return DropdownMenuItem<String>(value: s, child: Text('Status: $s'));
            }).toList(),
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _statusFilter = val;
                  _currentPage = 0;
                });
              }
            },
          ),
          const SizedBox(width: 12),

          // Date Presets
          DropdownButton<String>(
            value: _dateRangePreset,
            dropdownColor: const Color(0xFF101846),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            underline: const SizedBox(),
            items: ['All Time', 'Today', 'This Week', 'This Month', 'Custom']
                .map((p) {
              return DropdownMenuItem(value: p, child: Text(p));
            }).toList(),
            onChanged: (val) async {
              if (val == 'Custom') {
                final range = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now().add(const Duration(days: 30)),
                );
                if (range != null) {
                  setState(() {
                    _dateRangePreset = 'Custom';
                    _selectedDateRange = range;
                    _currentPage = 0;
                  });
                }
              } else if (val != null) {
                _applyDatePreset(val);
              }
            },
          ),
          const SizedBox(width: 12),

          // Reset button
          IconButton(
            icon: const Icon(Icons.refresh_rounded,
                color: DashboardColors.neonBlue, size: 20),
            tooltip: 'Reset Filters',
            onPressed: _clearFilters,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 3B. Vendor Profile & Drill-down Card (Vyapar-like tracking)
  // ---------------------------------------------------------------------------

  Widget _buildVendorProfileCard(
      List<Map<String, dynamic>> vendors, List<PurchaseBill> filteredBills) {
    final vendor = vendors.cast<Map<String, dynamic>?>().firstWhere(
          (v) => v?['key'] == _selectedVendorKey,
          orElse: () => null,
        );

    final vendorName = vendor?['name']?.toString() ?? 'Selected Vendor';
    final vendorPhone = vendor?['phone']?.toString() ?? '';
    final vendorGst = vendor?['gst']?.toString() ?? '';
    final vendorAddress = vendor?['address']?.toString() ?? '';

    final summary =
        PurchaseBillService.instance.getVendorSummary(_selectedVendorKey);
    final vendorPayments =
        PurchaseBillService.instance.getPaymentsForVendor(_selectedVendorKey);

    final billsCount = summary['billsCount'] as int? ?? filteredBills.length;
    final totalPurchases = summary['totalPurchases'] as double? ?? 0.0;
    final totalPaid = summary['totalPaid'] as double? ?? 0.0;
    final totalOutstanding = summary['totalOutstanding'] as double? ?? 0.0;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF101846),
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: DashboardColors.neonBlue.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Vendor Header info & action buttons
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: DashboardColors.activePillGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    vendorName.isNotEmpty ? vendorName[0].toUpperCase() : 'V',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            vendorName,
                            style: DashboardTypography.poppins(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: DashboardColors.neonBlue
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: DashboardColors.neonBlue
                                    .withValues(alpha: 0.3)),
                          ),
                          child: const Text(
                            'SUPPLIER',
                            style: TextStyle(
                              color: DashboardColors.neonBlue,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if (vendorPhone.isNotEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.phone_rounded,
                                  size: 13, color: DashboardColors.textMuted),
                              const SizedBox(width: 4),
                              Text(vendorPhone,
                                  style: const TextStyle(
                                      color: DashboardColors.textMuted,
                                      fontSize: 12)),
                            ],
                          ),
                        if (vendorGst.isNotEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.badge_rounded,
                                  size: 13, color: DashboardColors.neonBlue),
                              const SizedBox(width: 4),
                              Text('GSTIN: $vendorGst',
                                  style: const TextStyle(
                                      color: DashboardColors.neonBlue,
                                      fontSize: 12)),
                            ],
                          ),
                        if (vendorAddress.isNotEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.location_on_rounded,
                                  size: 13, color: DashboardColors.textMuted),
                              const SizedBox(width: 4),
                              Text(vendorAddress,
                                  style: const TextStyle(
                                      color: DashboardColors.textMuted,
                                      fontSize: 12)),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Action buttons for vendor
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  // Full Ledger button
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: DashboardColors.neonPurple
                          .withValues(alpha: 0.15),
                      foregroundColor: DashboardColors.neonPurple,
                      side: const BorderSide(color: DashboardColors.neonPurple),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.menu_book_rounded, size: 16),
                    label: const Text('View Full Ledger',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12)),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => VendorLedgerScreen(
                            vendorKey: _selectedVendorKey,
                            vendorName: vendorName,
                          ),
                        ),
                      );
                    },
                  ),
                  // Record payment button
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          DashboardColors.neonGreen.withValues(alpha: 0.15),
                      foregroundColor: DashboardColors.neonGreen,
                      side: const BorderSide(color: DashboardColors.neonGreen),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.payment_rounded, size: 16),
                    label: const Text('Record Payment',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12)),
                    onPressed: () => _showRecordAdvancePaymentDialog(
                        preselectedVendorKey: _selectedVendorKey),
                  ),
                  // New Bill for Vendor button
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          DashboardColors.neonBlue.withValues(alpha: 0.15),
                      foregroundColor: DashboardColors.neonBlue,
                      side: const BorderSide(color: DashboardColors.neonBlue),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon:
                        const Icon(Icons.add_circle_outline_rounded, size: 16),
                    label: const Text('+ New Bill',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12)),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ManualPurchaseEntryScreen(
                            initialVendorKey: _selectedVendorKey,
                            initialVendorName: vendorName,
                          ),
                        ),
                      );
                    },
                  ),
                  // Close filter
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: DashboardColors.textMuted, size: 18),
                    tooltip: 'Clear vendor filter',
                    onPressed: () {
                      setState(() {
                        _selectedVendorKey = null;
                        _vendorSubTab = 0;
                        _currentPage = 0;
                      });
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: DashboardColors.glassBorderHover, height: 1),
          const SizedBox(height: 14),

          // Row 2: Vendor KPI chips
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              _buildVendorKpiPill(
                  'Total Bills',
                  '$billsCount',
                  Icons.receipt_rounded,
                  DashboardColors.neonBlue),
              _buildVendorKpiPill(
                  'Purchases',
                  '₹${NumberFormat('#,##0.00').format(totalPurchases)}',
                  Icons.shopping_bag_rounded,
                  DashboardColors.neonGreen),
              _buildVendorKpiPill(
                  'Total Paid',
                  '₹${NumberFormat('#,##0.00').format(totalPaid)}',
                  Icons.check_circle_outline_rounded,
                  DashboardColors.neonGreen),
              _buildVendorKpiPill(
                'Balance Due',
                '₹${NumberFormat('#,##0.00').format(totalOutstanding)}',
                Icons.pending_actions_rounded,
                totalOutstanding > 0
                    ? DashboardColors.alertOrange
                    : DashboardColors.neonGreen,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Row 3: Sub-tab toggle (Bills vs Payment History)
          Row(
            children: [
              _buildVendorSubTabButton(
                index: 0,
                title: 'Purchase Bills ($billsCount)',
                icon: Icons.receipt_long_rounded,
              ),
              const SizedBox(width: 8),
              _buildVendorSubTabButton(
                index: 1,
                title: 'Payment History (${vendorPayments.length})',
                icon: Icons.history_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVendorKpiPill(
      String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: DashboardColors.textMuted, fontSize: 10)),
              Text(value,
                  style: DashboardTypography.poppins(
                      fontSize: 14, fontWeight: FontWeight.w700, color: color)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVendorSubTabButton({
    required int index,
    required String title,
    required IconData icon,
  }) {
    final isSel = _vendorSubTab == index;
    return InkWell(
      onTap: () => setState(() => _vendorSubTab = index),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSel
              ? DashboardColors.neonBlue.withValues(alpha: 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSel
                ? DashboardColors.neonBlue
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 15,
                color: isSel
                    ? DashboardColors.neonBlue
                    : DashboardColors.textMuted),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                color: isSel ? Colors.white : DashboardColors.textMuted,
                fontSize: 12,
                fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVendorPaymentsTable() {
    final payments =
        PurchaseBillService.instance.getPaymentsForVendor(_selectedVendorKey);
    if (payments.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 40),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x1AFFFFFF)),
        ),
        child: Center(
          child: Column(
            children: [
              const Icon(Icons.payment_rounded,
                  size: 48, color: DashboardColors.textMuted),
              const SizedBox(height: 12),
              const Text('No payment vouchers recorded for this vendor yet.',
                  style: TextStyle(
                      color: DashboardColors.textMuted, fontSize: 14)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: DashboardColors.neonGreen,
                  side: const BorderSide(color: DashboardColors.neonGreen),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Record Payment Now'),
                onPressed: () => _showRecordAdvancePaymentDialog(
                    preselectedVendorKey: _selectedVendorKey),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Payment Vouchers (${payments.length})',
                  style: DashboardTypography.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: DashboardColors.neonGreen,
                    foregroundColor: Colors.black,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.add_rounded,
                      size: 16, color: Colors.black),
                  label: const Text('Record Payment',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 12)),
                  onPressed: () => _showRecordAdvancePaymentDialog(
                      preselectedVendorKey: _selectedVendorKey),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor:
                  WidgetStateProperty.all(Colors.white.withValues(alpha: 0.04)),
              columns: const [
                DataColumn(
                    label: Text('DATE',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: DashboardColors.textMuted))),
                DataColumn(
                    label: Text('PAYMENT REF',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: DashboardColors.textMuted))),
                DataColumn(
                    label: Text('BILL #',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: DashboardColors.textMuted))),
                DataColumn(
                    label: Text('METHOD',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: DashboardColors.textMuted))),
                DataColumn(
                    label: Text('AMOUNT (₹)',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: DashboardColors.textMuted))),
                DataColumn(
                    label: Text('NOTES',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: DashboardColors.textMuted))),
                DataColumn(
                    label: Text('RECORDED BY',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: DashboardColors.textMuted))),
              ],
              rows: payments.map((p) {
                return DataRow(
                  cells: [
                    DataCell(Text(
                        DateFormat('dd MMM yyyy').format(p.paymentDate),
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12.5))),
                    DataCell(Text(
                        p.transactionReference.isNotEmpty
                            ? p.transactionReference
                            : p.paymentId,
                        style: const TextStyle(
                            color: DashboardColors.neonBlue,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600))),
                    DataCell(Text(
                        p.billNumber.isNotEmpty ? p.billNumber : '—',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12))),
                    DataCell(Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(p.paymentMethod,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11.5)),
                    )),
                    DataCell(Text(
                        '₹${NumberFormat('#,##0.00').format(p.amount)}',
                        style: const TextStyle(
                            color: DashboardColors.neonGreen,
                            fontSize: 13,
                            fontWeight: FontWeight.w700))),
                    DataCell(Text(p.notes ?? '—',
                        style: const TextStyle(
                            color: DashboardColors.textMuted, fontSize: 12))),
                    DataCell(Text(p.recordedByName,
                        style: const TextStyle(
                            color: DashboardColors.textDarkMuted,
                            fontSize: 11.5))),
                  ],
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 4. Bills Table
  // ---------------------------------------------------------------------------

  Widget _buildBillsTable(List<PurchaseBill> bills, int totalCount) {
    if (bills.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 60),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x1AFFFFFF)),
        ),
        child: Center(
          child: Column(
            children: [
              const Icon(Icons.receipt_long_outlined,
                  size: 54, color: DashboardColors.textMuted),
              const SizedBox(height: 14),
              const Text('No purchase bills found matching your criteria',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text(
                  'Upload a new purchase bill or adjust search/filter settings',
                  style:
                      TextStyle(color: DashboardColors.textMuted, fontSize: 13)),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: DashboardColors.neonBlue,
                      side: const BorderSide(color: DashboardColors.neonBlue),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    ),
                    icon: const Icon(Icons.document_scanner_rounded, size: 18),
                    label: const Text('Upload / Capture Bill',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const PurchaseBillUploadScreen(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 14),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: DashboardColors.neonGreen,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                    ),
                    icon: const Icon(Icons.edit_note_rounded, size: 18),
                    label: const Text('Manual Purchase Entry',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ManualPurchaseEntryScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final isNarrow = MediaQuery.of(context).size.width < 768;
    if (isNarrow) {
      return _buildBillsCardList(bills);
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor:
                WidgetStateProperty.all(Colors.white.withValues(alpha: 0.06)),
            dataRowColor: WidgetStateProperty.all(Colors.transparent),
            columnSpacing: 24,
            columns: const [
              DataColumn(
                  label: Text('Bill #',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
              DataColumn(
                  label: Text('Vendor Details',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
              DataColumn(
                  label: Text('Invoice #',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
              DataColumn(
                  label: Text('Purchase Date',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
              DataColumn(
                  label: Text('Grand Total',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
              DataColumn(
                  label: Text('Paid',
                      style: TextStyle(
                          color: DashboardColors.neonGreen,
                          fontWeight: FontWeight.bold))),
              DataColumn(
                  label: Text('Balance Due',
                      style: TextStyle(
                          color: DashboardColors.alertOrange,
                          fontWeight: FontWeight.bold))),
              DataColumn(
                  label: Text('Payment Status',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
              DataColumn(
                  label: Text('Items',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
              DataColumn(
                  label: Text('Attachment',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
              DataColumn(
                  label: Text('Actions',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
            ],
            rows: bills.map((b) {
              return DataRow(
                onSelectChanged: (_) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PurchaseBillDetailsScreen(bill: b),
                    ),
                  );
                },
                cells: [
                  DataCell(
                    InkWell(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PurchaseBillDetailsScreen(bill: b),
                          ),
                        );
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            b.billNumber,
                            style: const TextStyle(
                              color: DashboardColors.neonBlue,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 3),
                          _buildSourceChip(b.entrySource),
                        ],
                      ),
                    ),
                  ),
                  DataCell(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(b.vendorName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                        if (b.vendorPhone.isNotEmpty)
                          Text(b.vendorPhone,
                              style: const TextStyle(
                                  color: DashboardColors.textMuted,
                                  fontSize: 11)),
                      ],
                    ),
                  ),
                  DataCell(Text(b.vendorInvoiceNumber,
                      style: const TextStyle(color: Colors.white))),
                  DataCell(
                    Text(
                      DateFormat('dd MMM yyyy, hh:mm a').format(b.purchaseDate),
                      style: const TextStyle(
                          color: DashboardColors.textLight, fontSize: 12),
                    ),
                  ),
                  DataCell(
                    Text('₹${b.grandTotal.toStringAsFixed(2)}',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                  DataCell(
                    Text('₹${b.paidAmount.toStringAsFixed(2)}',
                        style: const TextStyle(
                            color: DashboardColors.neonGreen,
                            fontWeight: FontWeight.bold)),
                  ),
                  DataCell(
                    Text('₹${b.balanceDue.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: b.balanceDue > 0
                              ? DashboardColors.alertOrange
                              : DashboardColors.neonGreen,
                          fontWeight: FontWeight.bold,
                        )),
                  ),
                  DataCell(_buildStatusBadge(b.paymentStatus)),
                  DataCell(
                    Text('${b.items.length} items (${b.totalQuantity} units)',
                        style: const TextStyle(
                            color: DashboardColors.textLight, fontSize: 12)),
                  ),
                  DataCell(
                    b.attachment != null
                        ? Icon(
                            b.attachment!.isPdf
                                ? Icons.picture_as_pdf_rounded
                                : Icons.image_rounded,
                            size: 18,
                            color: b.attachment!.isPdf
                                ? Colors.redAccent
                                : DashboardColors.neonBlue,
                          )
                        : const Text('-',
                            style:
                                TextStyle(color: DashboardColors.textMuted)),
                  ),
                  DataCell(
                    Row(
                      children: [
                        // View Details Button
                        IconButton(
                          icon: const Icon(Icons.visibility_rounded,
                              color: DashboardColors.neonBlue, size: 18),
                          tooltip: 'View Details',
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    PurchaseBillDetailsScreen(bill: b),
                              ),
                            );
                          },
                        ),

                        // View Ledger
                        IconButton(
                          icon: const Icon(Icons.menu_book_rounded,
                              color: DashboardColors.neonPurple, size: 18),
                          tooltip: 'View Vendor Ledger',
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => VendorLedgerScreen(
                                    vendorKey: b.vendorKey,
                                    vendorName: b.vendorName),
                              ),
                            );
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
      ),
    );
  }

  Widget _buildBillsCardList(List<PurchaseBill> bills) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: bills.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final b = bills[index];
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PurchaseBillDetailsScreen(bill: b),
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0x1AFFFFFF)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text(
                          b.billNumber,
                          style: const TextStyle(
                            color: DashboardColors.neonBlue,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildSourceChip(b.entrySource),
                      ],
                    ),
                    _buildStatusBadge(b.paymentStatus),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            b.vendorName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          if (b.vendorInvoiceNumber.isNotEmpty)
                            Text(
                              'Inv: ${b.vendorInvoiceNumber}',
                              style: const TextStyle(
                                color: DashboardColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      DateFormat('dd MMM yyyy').format(b.purchaseDate),
                      style: const TextStyle(color: DashboardColors.textLight, fontSize: 12),
                    ),
                  ],
                ),
                const Divider(color: Color(0x1AFFFFFF), height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Grand Total', style: TextStyle(color: DashboardColors.textMuted, fontSize: 11)),
                        Text('₹${b.grandTotal.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Text('Paid', style: TextStyle(color: DashboardColors.textMuted, fontSize: 11)),
                        Text('₹${b.paidAmount.toStringAsFixed(2)}', style: const TextStyle(color: DashboardColors.neonGreen, fontWeight: FontWeight.bold, fontSize: 14)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text('Balance Due', style: TextStyle(color: DashboardColors.textMuted, fontSize: 11)),
                        Text(
                          '₹${b.balanceDue.toStringAsFixed(2)}',
                          style: TextStyle(
                            color: b.balanceDue > 0 ? DashboardColors.alertOrange : DashboardColors.neonGreen,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 5. Pagination
  // ---------------------------------------------------------------------------

  Widget _buildPagination(int totalPages) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          'Page ${_currentPage + 1} of $totalPages',
          style: const TextStyle(color: DashboardColors.textMuted, fontSize: 13),
        ),
        const SizedBox(width: 14),
        IconButton(
          icon: const Icon(Icons.chevron_left_rounded, color: Colors.white),
          onPressed: _currentPage > 0
              ? () => setState(() => _currentPage--)
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right_rounded, color: Colors.white),
          onPressed: _currentPage < totalPages - 1
              ? () => setState(() => _currentPage++)
              : null,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Helper Widgets
  // ---------------------------------------------------------------------------

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
      case BillPaymentStatus.draft:
        bg = DashboardColors.neonOrange.withValues(alpha: 0.15);
        border = DashboardColors.neonOrange;
        text = DashboardColors.neonOrange;
        break;
      default:
        bg = DashboardColors.alertOrange.withValues(alpha: 0.15);
        border = DashboardColors.alertOrange;
        text = DashboardColors.alertOrange;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(color: text, fontWeight: FontWeight.bold, fontSize: 11),
      ),
    );
  }

  Widget _buildSourceChip(String source) {
    final isManual = source == EntrySource.manual;
    final color = isManual ? DashboardColors.neonGreen : DashboardColors.neonPurple;
    final label = isManual ? 'Manual' : 'Auto';
    final icon = isManual ? Icons.edit_note_rounded : Icons.document_scanner_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
