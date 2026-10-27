import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../main.dart' show Db, toast;
import '../ui/dashboard/dashboard_tokens.dart';
import 'purchase_models.dart';
import 'purchase_bill_service.dart';

/// Comprehensive Vendor Account Ledger Screen.
/// Displays overall outstanding balance, chronological debit/credit ledger,
/// transaction references, running balances, and allows recording payments or advances.
class VendorLedgerScreen extends StatefulWidget {
  final dynamic vendorKey;
  final String? vendorName;

  const VendorLedgerScreen({
    super.key,
    dynamic vendorKey,
    this.vendorName,
    dynamic initialVendorKey,
  }) : vendorKey = vendorKey ?? initialVendorKey;

  @override
  State<VendorLedgerScreen> createState() => _VendorLedgerScreenState();
}

class _VendorLedgerScreenState extends State<VendorLedgerScreen> {
  final _dateFormat = DateFormat('dd MMM yyyy, hh:mm a');
  final _shortDateFormat = DateFormat('dd MMM yyyy');

  dynamic _activeVendorKey;
  String _activeVendorName = '';

  String _filterType = 'All';
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  void initState() {
    super.initState();
    _initVendor();
  }

  void _initVendor() {
    final vendors = PurchaseBillService.instance.getVendors();
    if (widget.vendorKey != null) {
      _activeVendorKey = widget.vendorKey;
      final found = vendors.firstWhere(
        (v) => v['key'] == widget.vendorKey || '${v['key']}' == '${widget.vendorKey}',
        orElse: () => {},
      );
      _activeVendorName = found['name'] ?? widget.vendorName ?? 'Vendor';
    } else if (vendors.isNotEmpty) {
      _activeVendorKey = vendors.first['key'];
      _activeVendorName = vendors.first['name'];
    }
  }

  @override
  Widget build(BuildContext context) {
    final vendors = PurchaseBillService.instance.getVendors();
    if (_activeVendorKey == null && vendors.isNotEmpty) {
      _activeVendorKey = vendors.first['key'];
      _activeVendorName = vendors.first['name'];
    }

    if (_activeVendorKey == null) {
      return Scaffold(
        backgroundColor: DashboardColors.bgDarkNavyStart,
        appBar: AppBar(
          backgroundColor: const Color(0xFF0C1236),
          title: const Text('Vendor Ledgers'),
        ),
        body: const Center(
          child: Text('No vendors found. Please add a vendor first.',
              style: TextStyle(color: Colors.white)),
        ),
      );
    }

    final ledger = PurchaseBillService.instance.getVendorLedger(_activeVendorKey);
    final vendorData = Db.parties.get(_activeVendorKey) as Map?;
    final vendorPhone = vendorData?['phone']?.toString() ?? '';
    final vendorGst = vendorData?['gst']?.toString() ?? '';
    final vendorAddress = vendorData?['address']?.toString() ?? '';
    final outstandingBalance = PurchaseBillService.instance.getVendorOutstandingBalance(_activeVendorKey);

    // Apply filters
    final filtered = ledger.where((e) {
      if (_filterType != 'All' && e.type != _filterType) return false;
      if (_startDate != null && e.date.isBefore(_startDate!)) return false;
      if (_endDate != null && e.date.isAfter(_endDate!.add(const Duration(days: 1)))) return false;
      return true;
    }).toList();

    return Scaffold(
      backgroundColor: DashboardColors.bgDarkNavyStart,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0C1236),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: DashboardColors.activePillGradient,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.account_balance_wallet_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonHideUnderline(
                  child: DropdownButton<dynamic>(
                    value: _activeVendorKey,
                    dropdownColor: const Color(0xFF101846),
                    style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    icon: const Icon(Icons.arrow_drop_down, color: DashboardColors.neonBlue),
                    items: vendors.map((v) {
                      return DropdownMenuItem<dynamic>(
                        value: v['key'],
                        child: Text('${v['name']}', style: const TextStyle(color: Colors.white)),
                      );
                    }).toList(),
                    onChanged: (k) {
                      final found = vendors.firstWhere((v) => v['key'] == k, orElse: () => {});
                      setState(() {
                        _activeVendorKey = k;
                        _activeVendorName = found['name'] ?? 'Vendor';
                      });
                    },
                  ),
                ),
                Text(
                  'Complete chronological statement of purchase bills, payments and balance',
                  style: DashboardTypography.inter(fontSize: 11.5, color: DashboardColors.textMuted),
                ),
              ],
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: DashboardColors.neonGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => _showRecordAdvancePaymentDialog(),
              icon: const Icon(Icons.payment_rounded, color: Colors.black, size: 18),
              label: Text(
                'Record Payment / Advance',
                style: DashboardTypography.poppins(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: DashboardColors.backgroundGradient),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Vendor Summary Card
              _buildVendorSummaryCard(
                phone: vendorPhone,
                gst: vendorGst,
                address: vendorAddress,
                outstandingBalance: outstandingBalance,
                totalTransactions: ledger.length,
              ),

              const SizedBox(height: 20),

              // 2. Filter Toolbar
              _buildFilterToolbar(),

              const SizedBox(height: 16),

              // 3. Ledger Table
              _buildLedgerTable(filtered),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // VENDOR SUMMARY CARD
  // ---------------------------------------------------------------------------

  Widget _buildVendorSummaryCard({
    required String phone,
    required String gst,
    required String address,
    required double outstandingBalance,
    required int totalTransactions,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashboardColors.glassCard(
        glow: outstandingBalance > 0,
        glowColor: DashboardColors.alertOrange,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: DashboardColors.primaryBlue.withValues(alpha: 0.2),
            child: const Icon(Icons.store_rounded, color: DashboardColors.neonBlue, size: 30),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _activeVendorName,
                      style: DashboardTypography.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0x3300D4FF),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Verified Supplier',
                        style: DashboardTypography.inter(fontSize: 11, fontWeight: FontWeight.bold, color: DashboardColors.neonBlue),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    if (phone.isNotEmpty)
                      _buildInfoSnippet(Icons.phone_rounded, 'Phone: $phone'),
                    if (gst.isNotEmpty)
                      _buildInfoSnippet(Icons.receipt_rounded, 'GST: $gst'),
                    if (address.isNotEmpty)
                      _buildInfoSnippet(Icons.location_on_rounded, address),
                    _buildInfoSnippet(Icons.history_rounded, '$totalTransactions recorded entries'),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: outstandingBalance > 0
                  ? const Color(0x26EF4444)
                  : const Color(0x2610B981),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: outstandingBalance > 0 ? const Color(0x80EF4444) : const Color(0x8010B981),
                width: 1.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'Total Outstanding Balance',
                  style: DashboardTypography.inter(fontSize: 11.5, color: DashboardColors.textLight),
                ),
                const SizedBox(height: 4),
                Text(
                  '₹${outstandingBalance.toStringAsFixed(2)}',
                  style: DashboardTypography.poppins(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: outstandingBalance > 0 ? DashboardColors.alertOrange : DashboardColors.neonGreen,
                  ),
                ),
                Text(
                  outstandingBalance > 0 ? 'Payable Debt' : 'All Dues Settled',
                  style: DashboardTypography.inter(
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    color: outstandingBalance > 0 ? const Color(0xFFF87171) : DashboardColors.neonGreen,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoSnippet(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: DashboardColors.textMuted),
        const SizedBox(width: 4),
        Text(
          text,
          style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textLight),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // FILTER TOOLBAR
  // ---------------------------------------------------------------------------

  Widget _buildFilterToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: DashboardColors.glassCard(radius: 12),
      child: Row(
        children: [
          const Icon(Icons.filter_list_rounded, color: DashboardColors.neonBlue, size: 18),
          const SizedBox(width: 8),
          Text(
            'Filter Ledger:',
            style: DashboardTypography.inter(fontSize: 12.5, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(width: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'All', label: Text('All')),
              ButtonSegment(value: 'Purchase Bill', label: Text('Bills')),
              ButtonSegment(value: 'Bill Payment', label: Text('Payments')),
              ButtonSegment(value: 'Advance Payment', label: Text('Advances')),
            ],
            selected: {_filterType},
            onSelectionChanged: (set) => setState(() => _filterType = set.first),
            style: SegmentedButton.styleFrom(
              backgroundColor: const Color(0x26000000),
              selectedBackgroundColor: DashboardColors.primaryBlue,
              foregroundColor: Colors.white70,
              selectedForegroundColor: Colors.white,
              textStyle: DashboardTypography.inter(fontSize: 11),
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: _startDate != null ? DashboardColors.neonBlue : DashboardColors.textLight,
              side: BorderSide(color: _startDate != null ? DashboardColors.neonBlue : const Color(0x33FFFFFF)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onPressed: () async {
              final picked = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2020),
                lastDate: DateTime.now().add(const Duration(days: 30)),
                initialDateRange: _startDate != null && _endDate != null
                    ? DateTimeRange(start: _startDate!, end: _endDate!)
                    : null,
                builder: (context, child) => Theme(
                  data: ThemeData.dark().copyWith(
                    colorScheme: const ColorScheme.dark(
                      primary: DashboardColors.primaryBlue,
                      surface: Color(0xFF0F172A),
                    ),
                  ),
                  child: child!,
                ),
              );
              if (picked != null) {
                setState(() {
                  _startDate = picked.start;
                  _endDate = picked.end;
                });
              }
            },
            icon: const Icon(Icons.calendar_today_rounded, size: 14),
            label: Text(
              _startDate != null
                  ? '${_shortDateFormat.format(_startDate!)} - ${_shortDateFormat.format(_endDate!)}'
                  : 'Date Range',
              style: DashboardTypography.inter(fontSize: 11.5),
            ),
          ),
          if (_startDate != null) ...[
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.clear_rounded, size: 16, color: DashboardColors.textMuted),
              onPressed: () => setState(() {
                _startDate = null;
                _endDate = null;
              }),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // LEDGER TABLE
  // ---------------------------------------------------------------------------

  Widget _buildLedgerTable(List<VendorLedgerEntry> entries) {
    if (entries.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(48),
        decoration: DashboardColors.glassCard(),
        child: Column(
          children: [
            const Icon(Icons.account_balance_wallet_outlined, size: 48, color: DashboardColors.textMuted),
            const SizedBox(height: 14),
            Text(
              'No Transactions Recorded in Ledger',
              style: DashboardTypography.poppins(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(
              'Purchase bills and payments for this vendor will appear here in real-time.',
              style: DashboardTypography.inter(fontSize: 12.5, color: DashboardColors.textMuted),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: DashboardColors.glassCard(radius: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            horizontalMargin: 20,
            columnSpacing: 24,
            headingRowHeight: 46,
            dataRowMaxHeight: 56,
            headingRowColor: WidgetStateProperty.all(const Color(0xFF0C1236)),
            columns: [
              DataColumn(label: Text('DATE', style: _headerStyle)),
              DataColumn(label: Text('TRANSACTION TYPE', style: _headerStyle)),
              DataColumn(label: Text('REFERENCE', style: _headerStyle)),
              DataColumn(label: Text('VENDOR INVOICE', style: _headerStyle)),
              DataColumn(label: Text('DEBIT (BILLS)', style: _headerStyle)),
              DataColumn(label: Text('CREDIT (PAID)', style: _headerStyle)),
              DataColumn(label: Text('RUNNING BALANCE', style: _headerStyle)),
              DataColumn(label: Text('NOTES', style: _headerStyle)),
            ],
            rows: entries.map((e) {
              final isBill = e.type == 'Purchase Bill';
              final isAdvance = e.type == 'Advance Payment';

              return DataRow(
                cells: [
                  // Date
                  DataCell(Text(_dateFormat.format(e.date), style: DashboardTypography.inter(fontSize: 12, color: Colors.white))),

                  // Type
                  DataCell(
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isBill
                            ? DashboardColors.primaryBlue.withValues(alpha: 0.15)
                            : (isAdvance ? DashboardColors.neonPurple.withValues(alpha: 0.15) : DashboardColors.neonGreen.withValues(alpha: 0.15)),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isBill
                              ? DashboardColors.primaryBlue.withValues(alpha: 0.5)
                              : (isAdvance ? DashboardColors.neonPurple.withValues(alpha: 0.5) : DashboardColors.neonGreen.withValues(alpha: 0.5)),
                        ),
                      ),
                      child: Text(
                        e.type,
                        style: DashboardTypography.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isBill
                              ? DashboardColors.neonBlue
                              : (isAdvance ? DashboardColors.neonPurple : DashboardColors.neonGreen),
                        ),
                      ),
                    ),
                  ),

                  // Reference
                  DataCell(Text(e.reference, style: DashboardTypography.inter(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white))),

                  // Vendor Invoice #
                  DataCell(Text(e.vendorInvoiceNumber ?? '—', style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textLight))),

                  // Debit (Bills amount)
                  DataCell(
                    Text(
                      e.debit > 0 ? '₹${e.debit.toStringAsFixed(2)}' : '—',
                      style: DashboardTypography.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: e.debit > 0 ? DashboardColors.alertOrange : DashboardColors.textMuted,
                      ),
                    ),
                  ),

                  // Credit (Payments made)
                  DataCell(
                    Text(
                      e.credit > 0 ? '₹${e.credit.toStringAsFixed(2)}' : '—',
                      style: DashboardTypography.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: e.credit > 0 ? DashboardColors.neonGreen : DashboardColors.textMuted,
                      ),
                    ),
                  ),

                  // Running Balance
                  DataCell(
                    Text(
                      '₹${e.runningBalance.toStringAsFixed(2)}',
                      style: DashboardTypography.poppins(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: e.runningBalance > 0 ? DashboardColors.alertOrange : DashboardColors.neonGreen,
                      ),
                    ),
                  ),

                  // Notes
                  DataCell(
                    SizedBox(
                      width: 180,
                      child: Text(
                        e.notes ?? '—',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DashboardTypography.inter(fontSize: 11.5, color: DashboardColors.textMuted),
                      ),
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

  TextStyle get _headerStyle => DashboardTypography.poppins(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: DashboardColors.textLight,
      );

  // ---------------------------------------------------------------------------
  // MODAL: RECORD ADVANCE / DIRECT PAYMENT
  // ---------------------------------------------------------------------------

  void _showRecordAdvancePaymentDialog() {
    final amountCtrl = TextEditingController();
    final refCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    String method = 'UPI';
    DateTime payDate = DateTime.now();
    bool submitting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0x3310B981)),
          ),
          title: Row(
            children: [
              const Icon(Icons.payment_rounded, color: DashboardColors.neonGreen),
              const SizedBox(width: 10),
              Text(
                'Record Vendor Payment / Advance',
                style: DashboardTypography.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Record a direct payment or advance payment to $_activeVendorName. This automatically updates the vendor ledger and cash/bank account.',
                  style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textMuted),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: amountCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(
                    labelText: 'Payment Amount (₹) *',
                    labelStyle: TextStyle(color: Colors.white70),
                    prefixText: '₹ ',
                    prefixStyle: TextStyle(color: DashboardColors.neonGreen, fontWeight: FontWeight.bold),
                    filled: true,
                    fillColor: Color(0x26000000),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Payment Mode *', style: DashboardTypography.inter(fontSize: 12, color: DashboardColors.textLight)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0x26000000),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0x33FFFFFF)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1E293B),
                      value: method,
                      items: ['Cash', 'UPI', 'Bank Transfer', 'Card', 'Cheque', 'Other'].map((m) {
                        return DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(color: Colors.white)));
                      }).toList(),
                      onChanged: (val) => setD(() => method = val ?? 'UPI'),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: refCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Transaction Reference / UTR # *',
                    labelStyle: TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: Color(0x26000000),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    labelStyle: TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: Color(0x26000000),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(ctx),
              child: Text('Cancel', style: DashboardTypography.inter(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: DashboardColors.neonGreen),
              onPressed: submitting
                  ? null
                  : () async {
                      final amt = double.tryParse(amountCtrl.text.trim()) ?? 0.0;
                      if (amt <= 0) {
                        toast(context, 'Please enter a valid amount', error: true);
                        return;
                      }
                      if (refCtrl.text.trim().isEmpty) {
                        toast(context, 'Please enter transaction reference / UTR', error: true);
                        return;
                      }

                      setD(() => submitting = true);
                      try {
                        await PurchaseBillService.instance.recordAdvancePayment(
                          vendorKey: _activeVendorKey,
                          vendorName: _activeVendorName,
                          amount: amt,
                          paymentDate: payDate,
                          paymentMethod: method,
                          transactionReference: refCtrl.text.trim(),
                          notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                          staffId: 'staff_1',
                          staffName: 'Staff User',
                        );
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          toast(context, 'Payment of ₹$amt recorded in vendor ledger');
                          setState(() {});
                        }
                      } catch (e) {
                        setD(() => submitting = false);
                        if (ctx.mounted) toast(context, 'Failed: $e', error: true);
                      }
                    },
              child: submitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                  : Text('Save Payment', style: DashboardTypography.inter(fontWeight: FontWeight.bold, color: Colors.black)),
            ),
          ],
        ),
      ),
    );
  }
}
