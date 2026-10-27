import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db, boxPurchaseBills, boxParties;
import '../ui/dashboard/dashboard_tokens.dart';
import '../ui/tek_feedback.dart';
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

  void _showRecordAdvancePaymentDialog() {
    final vendors = PurchaseBillService.instance.getVendors();
    dynamic selVendorKey;
    String selVendorName = '';
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

                // 4. BILLS TABLE
                _buildBillsTable(pageBills, filteredBills.length),
                const SizedBox(height: 16),

                // 5. PAGINATION
                if (totalPages > 1) _buildPagination(totalPages),
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                Column(
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
              ],
            ),
          ],
        ),
        Row(
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
            const SizedBox(width: 14),

            // Prominent "+ Upload Purchase Bill" Button
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: DashboardColors.neonBlue,
                foregroundColor: Colors.black,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 4,
                shadowColor: DashboardColors.neonBlue.withValues(alpha: 0.4),
              ),
              icon: const Icon(Icons.add_circle_rounded,
                  color: Colors.black, size: 20),
              label: Text(
                '+ Upload Purchase Bill',
                style: DashboardTypography.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Colors.black,
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
          ],
        ),
      ],
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
                subtitle: 'Cleared invoices',
                icon: Icons.check_circle_rounded,
                color: DashboardColors.neonGreen,
                width: safeWidth,
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'Partially Paid',
                value: '${m['partiallyPaidBills'] ?? 0}',
                subtitle: 'Part payment done',
                icon: Icons.timelapse_rounded,
                color: DashboardColors.neonBlue,
                width: safeWidth,
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'Unpaid Bills',
                value: '${m['unpaidBills'] ?? 0}',
                subtitle: 'No payment made',
                icon: Icons.hourglass_top_rounded,
                color: DashboardColors.alertOrange,
                width: safeWidth,
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'Uploaded Today',
                value: '${m['billsUploadedToday'] ?? 0}',
                subtitle: 'New entries today',
                icon: Icons.today_rounded,
                color: DashboardColors.neonPurple,
                width: safeWidth,
              ),
              const SizedBox(width: 12),
              _buildMetricCard(
                title: 'This Month',
                value: '₹${(m['purchasesThisMonth'] ?? 0.0).toStringAsFixed(0)}',
                subtitle: 'Current month total',
                icon: Icons.calendar_month_rounded,
                color: DashboardColors.neonPink,
                width: safeWidth,
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
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: DashboardColors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
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
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: DashboardColors.neonBlue,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('+ Upload Purchase Bill',
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
                      child: Text(
                        b.billNumber,
                        style: const TextStyle(
                          color: DashboardColors.neonBlue,
                          fontWeight: FontWeight.bold,
                        ),
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
}
