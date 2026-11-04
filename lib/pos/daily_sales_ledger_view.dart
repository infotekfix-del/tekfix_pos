import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show Db, toast, printInvoice, sendInvoiceWhatsApp;
import '../returns/customer_returns_screen.dart';
import '../theme/tek_tokens.dart';
import '../expenses/expense_models.dart';
import '../expenses/expense_service.dart';
import '../rent/rent_service.dart';
import '../rent/daily_rent_payment_dialog.dart';
import '../owner/owner_finance_models.dart';
import '../owner/owner_finance_service.dart';
import 'daily_register_models.dart';
import 'daily_register_service.dart';

class DailySalesLedgerView extends StatefulWidget {
  final String? shopId;
  final String? currentStaffId;
  final String? currentStaffName;

  const DailySalesLedgerView({
    super.key,
    this.shopId,
    this.currentStaffId,
    this.currentStaffName,
  });

  // Static helper to open the EOD Closing Modal from anywhere in the app
  static Future<void> showEodClosingModal(
    BuildContext context, {
    String? shopId,
    String? currentStaffId,
    String? currentStaffName,
    DateTime? date,
    VoidCallback? onClosed,
  }) async {
    final targetDate = date ?? DateTime.now();
    final resolvedShop = shopId ?? Db.setting('shop_id', '');
    final s = await DailyRegisterService.instance.getSalesForDate(
      targetDate,
      shopId: resolvedShop,
    );
    final dateStr = DailyRegisterService.toDateString(targetDate);
    final closed = await DailyRegisterService.instance.getClosedRegister(
      dateStr,
      shopId: resolvedShop,
    );
    final exps = await ExpenseService.instance.getExpensesForDate(
      targetDate,
      shopId: resolvedShop,
    );
    final dateKey = RentService.toDateKey(targetDate);
    final rentRec = await RentService.instance
        .getRentRecordForDate(dateKey, shopId: resolvedShop);
    final rentSettings =
        await RentService.instance.getSettings(shopId: resolvedShop);
    final double cashRent =
        (rentRec != null && rentRec.isPaid && rentRec.isCash)
            ? rentRec.paidAmount
            : 0.0;
    final double bankRent =
        (rentRec != null && rentRec.isPaid && rentRec.isBank)
            ? rentRec.paidAmount
            : 0.0;
    final bool rentPending = rentSettings.isScheduledForDate(targetDate) &&
        (rentRec == null || !rentRec.isPaid);

    final ownerWth = await OwnerFinanceService.instance
        .computeDailyOwnerWithdrawals(targetDate, shopId: resolvedShop);

    double cExp = 0.0;
    double bExp = 0.0;
    bool rentInExpenses = false;
    bool ownerSalInExpenses = false;
    for (final e in exps) {
      if (!e.isVoided) {
        if (e.id == 'EXP_RENT_$dateKey') {
          rentInExpenses = true;
        }
        if (e.id.startsWith('EXP_OWN_SAL_') || e.isOwnerWithdrawal == true) {
          ownerSalInExpenses = true;
        }
        if (e.paymentMode == ExpensePaymentMode.cash) {
          cExp += e.amount;
        } else {
          bExp += e.amount;
        }
      }
    }
    if (!rentInExpenses && cashRent > 0) cExp += cashRent;
    if (!rentInExpenses && bankRent > 0) bExp += bankRent;
    if (!ownerSalInExpenses && ownerWth.cashSalary > 0)
      cExp += ownerWth.cashSalary;
    if (!ownerSalInExpenses && ownerWth.bankSalary > 0)
      bExp += ownerWth.bankSalary;

    final summary = closed ??
        DailyRegisterService.instance.computeDailySummary(
          sales: s,
          date: targetDate,
          totalCashExpenses: cExp,
          totalBankExpenses: bExp,
          cashRentPaid: cashRent,
          bankRentPaid: bankRent,
          rentPendingWarning: rentPending,
          ownerSalaryDrawnToday: ownerWth.totalSalary,
          ownerExcessDrawingsToday: ownerWth.totalDrawings,
          ownerCashSalaryDrawn: ownerWth.cashSalary,
          ownerCashDrawingsDrawn: ownerWth.cashDrawings,
          ownerBankSalaryDrawn: ownerWth.bankSalary,
          ownerBankDrawingsDrawn: ownerWth.bankDrawings,
          closedByStaffId: currentStaffId ?? '',
          closedByStaffName: currentStaffName ?? '',
        );

    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _EodClosingSheet(
        initialSummary: summary,
        shopId: resolvedShop,
        currentStaffId: currentStaffId ?? 'staff',
        currentStaffName: currentStaffName ?? 'Staff',
        onClosed: onClosed,
      ),
    );
  }

  @override
  State<DailySalesLedgerView> createState() => _DailySalesLedgerViewState();
}

class _DailySalesLedgerViewState extends State<DailySalesLedgerView> {
  DateTime _selectedDate = DateTime.now();
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  bool _loading = false;
  List<Map<String, dynamic>> _sales = [];
  DailyRegisterSummary? _closedRegister;
  double _cashExpenses = 0.0;
  double _bankExpenses = 0.0;
  double _cashRent = 0.0;
  double _bankRent = 0.0;
  bool _rentPending = false;
  DailyOwnerWithdrawalBreakdown _ownerWth =
      const DailyOwnerWithdrawalBreakdown();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      final s = await DailyRegisterService.instance.getSalesForDate(
        _selectedDate,
        shopId: widget.shopId,
      );
      final dateStr = DailyRegisterService.toDateString(_selectedDate);
      final closed = await DailyRegisterService.instance.getClosedRegister(
        dateStr,
        shopId: widget.shopId,
      );

      final exps = await ExpenseService.instance.getExpensesForDate(
        _selectedDate,
        shopId: widget.shopId,
      );
      final dateKey = RentService.toDateKey(_selectedDate);
      final rentRec = await RentService.instance
          .getRentRecordForDate(dateKey, shopId: widget.shopId);
      final rentSettings =
          await RentService.instance.getSettings(shopId: widget.shopId);
      final double cRent = (rentRec != null && rentRec.isPaid && rentRec.isCash)
          ? rentRec.paidAmount
          : 0.0;
      final double bRent = (rentRec != null && rentRec.isPaid && rentRec.isBank)
          ? rentRec.paidAmount
          : 0.0;
      final bool rPending = rentSettings.isScheduledForDate(_selectedDate) &&
          (rentRec == null || !rentRec.isPaid);

      final ownerWth = await OwnerFinanceService.instance
          .computeDailyOwnerWithdrawals(_selectedDate, shopId: widget.shopId);

      double cExp = 0.0;
      double bExp = 0.0;
      bool rentInExpenses = false;
      bool ownerSalInExpenses = false;
      for (final e in exps) {
        if (!e.isVoided) {
          if (e.id == 'EXP_RENT_$dateKey') {
            rentInExpenses = true;
          }
          if (e.id.startsWith('EXP_OWN_SAL_') || e.isOwnerWithdrawal == true) {
            ownerSalInExpenses = true;
          }
          if (e.paymentMode == ExpensePaymentMode.cash) {
            cExp += e.amount;
          } else {
            bExp += e.amount;
          }
        }
      }
      if (!rentInExpenses && cRent > 0) cExp += cRent;
      if (!rentInExpenses && bRent > 0) bExp += bRent;
      if (!ownerSalInExpenses && ownerWth.cashSalary > 0)
        cExp += ownerWth.cashSalary;
      if (!ownerSalInExpenses && ownerWth.bankSalary > 0)
        bExp += ownerWth.bankSalary;

      if (mounted) {
        setState(() {
          _sales = s;
          _closedRegister = closed;
          _cashExpenses = cExp;
          _bankExpenses = bExp;
          _cashRent = cRent;
          _bankRent = bRent;
          _rentPending = rPending;
          _ownerWth = ownerWth;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  DailyRegisterSummary get _currentSummary {
    if (_closedRegister != null) return _closedRegister!;
    return DailyRegisterService.instance.computeDailySummary(
      sales: _sales,
      date: _selectedDate,
      totalCashExpenses: _cashExpenses,
      totalBankExpenses: _bankExpenses,
      cashRentPaid: _cashRent,
      bankRentPaid: _bankRent,
      rentPendingWarning: _rentPending,
      ownerSalaryDrawnToday: _ownerWth.totalSalary,
      ownerExcessDrawingsToday: _ownerWth.totalDrawings,
      ownerCashSalaryDrawn: _ownerWth.cashSalary,
      ownerCashDrawingsDrawn: _ownerWth.cashDrawings,
      ownerBankSalaryDrawn: _ownerWth.bankSalary,
      ownerBankDrawingsDrawn: _ownerWth.bankDrawings,
      closedByStaffId: widget.currentStaffId ?? '',
      closedByStaffName: widget.currentStaffName ?? '',
    );
  }

  List<Map<String, dynamic>> get _filteredSales {
    if (_searchQuery.isEmpty) return _sales;
    final q = _searchQuery.toLowerCase();
    return _sales.where((s) {
      final inv = s['invoice']?.toString().toLowerCase() ?? '';
      final cust = s['customerName']?.toString().toLowerCase() ?? '';
      final phone = s['customerPhone']?.toString().toLowerCase() ?? '';
      final staff = s['staffName']?.toString().toLowerCase() ?? '';

      bool itemMatch = false;
      final items = (s['items'] as List?) ?? [];
      for (final it in items) {
        if (it is Map) {
          final n = it['name']?.toString().toLowerCase() ?? '';
          final imei = it['imei']?.toString().toLowerCase() ?? '';
          if (n.contains(q) || imei.contains(q)) {
            itemMatch = true;
            break;
          }
        }
      }

      return inv.contains(q) ||
          cust.contains(q) ||
          phone.contains(q) ||
          staff.contains(q) ||
          itemMatch;
    }).toList();
  }

  bool get _isToday {
    final now = DateTime.now();
    return _selectedDate.year == now.year &&
        _selectedDate.month == now.month &&
        _selectedDate.day == now.day;
  }

  bool get _isYesterday {
    final yest = DateTime.now().subtract(const Duration(days: 1));
    return _selectedDate.year == yest.year &&
        _selectedDate.month == yest.month &&
        _selectedDate.day == yest.day;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2022),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: TekColors.primary,
              onPrimary: Colors.white,
              surface: TekColors.bgCard,
              onSurface: TekColors.textPrimary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
      await _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _currentSummary;
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      backgroundColor: TekColors.bgMain,
      body: RefreshIndicator(
        onRefresh: _loadData,
        color: TekColors.primary,
        backgroundColor: TekColors.bgCard,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // Top App Bar / Title area
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeaderBar(summary),
                    const SizedBox(height: 14),
                    _buildDateSelectorRow(),
                    const SizedBox(height: 14),
                    _buildSummaryMetricsGrid(summary, isDesktop),
                    const SizedBox(height: 16),
                    _buildSearchAndFilterBar(),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),

            // Sales Orders List
            if (_loading)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(color: TekColors.primary),
                ),
              )
            else if (_filteredSales.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: TekColors.bgCard,
                            shape: BoxShape.circle,
                            border: Border.all(color: TekColors.border),
                          ),
                          child: const Icon(
                            Icons.receipt_long_outlined,
                            size: 48,
                            color: TekColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _searchQuery.isNotEmpty
                              ? 'തിരഞ്ഞ ഫലങ്ങൾ ഒന്നും കണ്ടെത്തിയില്ല'
                              : '${DailyRegisterService.toDisplayDate(_selectedDate)}-ൽ ബില്ലുകൾ ഒന്നും ലഭ്യമല്ല',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: TekColors.textPrimary,
                            fontFamilyFallback: TekTypography.malayalamFallback,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'No sales orders recorded for the selected date filter',
                          style: TextStyle(
                              fontSize: 12.5, color: TekColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final sale = _filteredSales[index];
                      return _buildSaleCard(sale);
                    },
                    childCount: _filteredSales.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Header with Title and EOD Close Action
  Widget _buildHeaderBar(DailyRegisterSummary summary) {
    final isClosed = _closedRegister != null;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: TekColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border:
                    Border.all(color: TekColors.primary.withValues(alpha: 0.3)),
              ),
              child: const Icon(Icons.receipt_long_rounded,
                  color: TekColors.primary, size: 22),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Daily Sales Ledger & Orders',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: TekColors.textPrimary,
                  ),
                ),
                Text(
                  'ദിവസേനയുള്ള വിൽപന രജിസ്റ്റർ • ${DailyRegisterService.toDisplayDate(_selectedDate)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: TekColors.textSecondary,
                    fontFamilyFallback: TekTypography.malayalamFallback,
                  ),
                ),
              ],
            ),
          ],
        ),

        // EOD Close / Register Status Button
        GestureDetector(
          onTap: () => _openEodClosingDialog(summary),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              gradient: isClosed
                  ? const LinearGradient(
                      colors: [Color(0xFF0F766E), Color(0xFF0D9488)])
                  : TekColors.primaryGradient,
              borderRadius: BorderRadius.circular(12),
              boxShadow: isClosed ? null : TekColors.primaryGlow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isClosed ? Icons.verified_rounded : Icons.nights_stay_rounded,
                  color: Colors.white,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  isClosed
                      ? 'EOD Closed (ക്ലോസ്ഡ്)'
                      : 'End of Day (EOD) Close (10 PM)',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontFamilyFallback: TekTypography.malayalamFallback,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Date Filter Quick Chips (Today, Yesterday, Custom Calendar)
  Widget _buildDateSelectorRow() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TekColors.border),
      ),
      child: Row(
        children: [
          _buildDateChip(
            label: 'ഇന്ന് (Today)',
            isSelected: _isToday,
            onTap: () {
              setState(() => _selectedDate = DateTime.now());
              _loadData();
            },
          ),
          const SizedBox(width: 6),
          _buildDateChip(
            label: 'ഇന്നലെ (Yesterday)',
            isSelected: _isYesterday,
            onTap: () {
              setState(() => _selectedDate =
                  DateTime.now().subtract(const Duration(days: 1)));
              _loadData();
            },
          ),
          const Spacer(),
          InkWell(
            onTap: _pickDate,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: TekColors.bgSecondary,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: TekColors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.calendar_month_rounded,
                      size: 16, color: TekColors.secondary),
                  const SizedBox(width: 8),
                  Text(
                    DailyRegisterService.toDisplayDate(_selectedDate),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: TekColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down,
                      size: 18, color: TekColors.textSecondary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? TekColors.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? TekColors.primary : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? TekColors.primary : TekColors.textSecondary,
            fontFamilyFallback: TekTypography.malayalamFallback,
          ),
        ),
      ),
    );
  }

  // Summary Metrics Bar (Revenue, Orders, Cash, UPI, Card, Due)
  Widget _buildSummaryMetricsGrid(
      DailyRegisterSummary summary, bool isDesktop) {
    final metrics = [
      _MetricItem(
        label: 'Net Revenue (തുക)',
        value: '₹${summary.netRevenue.toStringAsFixed(0)}',
        sub: 'Gross: ₹${summary.grossSales.toStringAsFixed(0)}',
        icon: Icons.account_balance_wallet_rounded,
        color: TekColors.success,
      ),
      _MetricItem(
        label: 'Total Orders',
        value: '${summary.totalOrdersCount}',
        sub: 'Discounts: ₹${summary.totalDiscounts.toStringAsFixed(0)}',
        icon: Icons.receipt_rounded,
        color: TekColors.primary,
      ),
      _MetricItem(
        label: 'Cash in Register',
        value: '₹${summary.totalCash.toStringAsFixed(0)}',
        sub: summary.isClosed
            ? 'Counted: ₹${summary.physicalCashCount.toStringAsFixed(0)}'
            : 'System Cash',
        icon: Icons.payments_rounded,
        color: Colors.amber,
      ),
      _MetricItem(
        label: 'UPI / Digital',
        value: '₹${summary.totalUpi.toStringAsFixed(0)}',
        sub: 'GPay / PhonePe / QR',
        icon: Icons.qr_code_scanner_rounded,
        color: TekColors.secondary,
      ),
      _MetricItem(
        label: 'Card / POS',
        value: '₹${summary.totalCard.toStringAsFixed(0)}',
        sub: 'Swipe / Tap',
        icon: Icons.credit_card_rounded,
        color: TekColors.info,
      ),
      _MetricItem(
        label: 'Customer Dues',
        value: '₹${summary.totalDue.toStringAsFixed(0)}',
        sub: 'Credit Sales',
        icon: Icons.person_off_rounded,
        color: summary.totalDue > 0 ? TekColors.error : TekColors.textSecondary,
      ),
    ];

    if (isDesktop) {
      return Row(
        children: metrics
            .map((m) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _buildMetricCard(m),
                  ),
                ))
            .toList(),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: metrics.map((m) {
            final w = (constraints.maxWidth - 16) / 2;
            return SizedBox(
              width: w > 160 ? w : constraints.maxWidth,
              child: _buildMetricCard(m),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildMetricCard(_MetricItem item) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TekColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  item.label,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: TekColors.textSecondary,
                    fontFamilyFallback: TekTypography.malayalamFallback,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Icon(item.icon, size: 16, color: item.color),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            item.value,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: item.color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            item.sub,
            style: const TextStyle(fontSize: 10.5, color: TekColors.textMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // Search Bar
  Widget _buildSearchAndFilterBar() {
    return TextField(
      controller: _searchCtrl,
      onChanged: (v) => setState(() => _searchQuery = v.trim()),
      style: const TextStyle(color: TekColors.textPrimary, fontSize: 13.5),
      decoration: InputDecoration(
        hintText: 'Search by Invoice #, Customer, Phone, or Item name...',
        hintStyle: TextStyle(
            color: TekColors.textSecondary.withValues(alpha: 0.6),
            fontSize: 13),
        prefixIcon: const Icon(Icons.search_rounded,
            color: TekColors.textSecondary, size: 20),
        suffixIcon: _searchQuery.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.close_rounded,
                    size: 18, color: TekColors.textSecondary),
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _searchQuery = '');
                },
              )
            : null,
        filled: true,
        fillColor: TekColors.bgCard,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: TekColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: TekColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: TekColors.primary, width: 1.5),
        ),
      ),
    );
  }

  // Individual Sale Card
  Widget _buildSaleCard(Map<String, dynamic> sale) {
    final inv = sale['invoice']?.toString() ?? 'N/A';
    final createdStr = sale['createdAt']?.toString() ?? '';
    final dt = DateTime.tryParse(createdStr);
    final timeStr = dt != null ? DateFormat('hh:mm a').format(dt) : '';
    final isReturned = sale['status'] == 'RETURNED';

    final custName = sale['customerName']?.toString().trim();
    final displayCust = (custName != null && custName.isNotEmpty)
        ? custName
        : 'Walk-in Customer';
    final custPhone = sale['customerPhone']?.toString().trim() ?? '';

    final items = (sale['items'] as List?) ?? [];
    final total = (sale['total'] as num?)?.toDouble() ?? 0.0;
    final discount = (sale['discount'] as num?)?.toDouble() ?? 0.0;

    final cash = (sale['cash'] as num?)?.toDouble() ?? 0.0;
    final upi = (sale['upi'] as num?)?.toDouble() ?? 0.0;
    final card = (sale['card'] as num?)?.toDouble() ?? 0.0;
    final due = (sale['due'] as num?)?.toDouble() ?? 0.0;
    final staff = sale['staffName']?.toString() ?? 'Staff';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isReturned
              ? TekColors.error.withValues(alpha: 0.4)
              : TekColors.border,
          width: 1.2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Ribbon: Invoice #, Time, Status
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              color: TekColors.bgSecondary,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: TekColors.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          inv,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                            color: TekColors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '| $timeStr',
                        style: const TextStyle(
                            fontSize: 12, color: TekColors.textSecondary),
                      ),
                    ],
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isReturned
                          ? TekColors.error.withValues(alpha: 0.15)
                          : TekColors.success.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isReturned ? TekColors.error : TekColors.success,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      isReturned ? 'RETURNED' : 'PAID',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: isReturned ? TekColors.error : TekColors.success,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Customer Info & Phone
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: TekColors.secondary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.person_rounded,
                        size: 20, color: TekColors.secondary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayCust,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: TekColors.textPrimary,
                          ),
                        ),
                        if (custPhone.isNotEmpty)
                          Text(
                            custPhone,
                            style: const TextStyle(
                                fontSize: 12, color: TekColors.textSecondary),
                          ),
                      ],
                    ),
                  ),
                  if (custPhone.isNotEmpty) ...[
                    IconButton(
                      icon: const Icon(Icons.phone_outlined,
                          size: 18, color: TekColors.primary),
                      tooltip: 'Call Customer',
                      onPressed: () => launchUrl(Uri.parse('tel:$custPhone')),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chat_bubble_outline_rounded,
                          size: 18, color: Color(0xFF22C55E)),
                      tooltip: 'WhatsApp',
                      onPressed: () =>
                          launchUrl(Uri.parse('https://wa.me/91$custPhone')),
                    ),
                  ],
                ],
              ),
            ),

            const Divider(height: 1, color: TekColors.border),

            // Items Breakdown List
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Items Breakdown (ഇനങ്ങൾ):',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: TekColors.textSecondary,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...items.map((rawIt) {
                    if (rawIt is! Map) return const SizedBox.shrink();
                    final it = Map<String, dynamic>.from(rawIt);
                    final name = it['name']?.toString() ??
                        it['itemName']?.toString() ??
                        'Item';
                    final cat = it['category']?.toString() ?? '';
                    final qty = (it['qty'] as num?)?.toInt() ?? 1;
                    final price = (it['price'] as num?)?.toDouble() ??
                        (it['unitPrice'] as num?)?.toDouble() ??
                        0.0;
                    final imei = it['imei']?.toString() ??
                        it['serial']?.toString() ??
                        '';

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: TekColors.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        name,
                                        style: const TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                          color: TekColors.textPrimary,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (cat.isNotEmpty)
                                      Container(
                                        margin: const EdgeInsets.only(left: 6),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: TekColors.bgSecondary,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          border: Border.all(
                                              color: TekColors.border),
                                        ),
                                        child: Text(
                                          cat,
                                          style: const TextStyle(
                                              fontSize: 9.5,
                                              color: TekColors.textSecondary),
                                        ),
                                      ),
                                  ],
                                ),
                                if (imei.isNotEmpty)
                                  Text(
                                    'IMEI / SN: $imei',
                                    style: const TextStyle(
                                        fontSize: 10.5,
                                        color: TekColors.secondary),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '$qty x ₹${price.toStringAsFixed(0)}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: TekColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),

            const Divider(height: 1, color: TekColors.border),

            // Payment Split Badges & Total
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Payment Badges
                  Wrap(
                    spacing: 6,
                    children: [
                      if (cash > 0)
                        _buildPaymentBadge('Cash', cash, Colors.amber),
                      if (upi > 0)
                        _buildPaymentBadge('UPI', upi, TekColors.secondary),
                      if (card > 0)
                        _buildPaymentBadge('Card', card, TekColors.info),
                      if (due > 0)
                        _buildPaymentBadge('Due', due, TekColors.error),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: TekColors.bgSecondary,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: TekColors.border),
                        ),
                        child: Text(
                          '👤 $staff',
                          style: const TextStyle(
                              fontSize: 10, color: TekColors.textSecondary),
                        ),
                      ),
                    ],
                  ),

                  // Total Bill
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '₹${total.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color:
                              isReturned ? TekColors.error : TekColors.success,
                          decoration:
                              isReturned ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      if (discount > 0)
                        Text(
                          'Disc: -₹${discount.toStringAsFixed(0)}',
                          style: const TextStyle(
                              fontSize: 10.5, color: TekColors.textSecondary),
                        ),
                    ],
                  ),
                ],
              ),
            ),

            // Action Buttons: View Receipt, Print Thermal, Return/Refund
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              color: TekColors.bgSecondary,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        side: const BorderSide(color: TekColors.border),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => _viewInvoiceReceiptModal(sale),
                      icon: const Icon(Icons.remove_red_eye_outlined,
                          size: 14, color: TekColors.textPrimary),
                      label: const Text(
                        'View Receipt',
                        style: TextStyle(
                            fontSize: 11.5, color: TekColors.textPrimary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        side: const BorderSide(color: TekColors.primary),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => printInvoice(context, sale, a4: false),
                      icon: const Icon(Icons.print_outlined,
                          size: 14, color: TekColors.primary),
                      label: const Text(
                        'Thermal Bill',
                        style:
                            TextStyle(fontSize: 11.5, color: TekColors.primary),
                      ),
                    ),
                  ),
                  if (!isReturned) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          side: BorderSide(
                              color: TekColors.error.withValues(alpha: 0.6)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () => _handleReturnItem(sale),
                        icon: const Icon(Icons.assignment_return_outlined,
                            size: 14, color: TekColors.error),
                        label: const Text(
                          'Return',
                          style:
                              TextStyle(fontSize: 11.5, color: TekColors.error),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentBadge(String mode, double amount, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.8),
      ),
      child: Text(
        '$mode: ₹${amount.toStringAsFixed(0)}',
        style:
            TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }

  // View Receipt Modal
  void _viewInvoiceReceiptModal(Map<String, dynamic> sale) {
    final inv = sale['invoice']?.toString() ?? 'N/A';
    final items = (sale['items'] as List?) ?? [];
    final total = (sale['total'] as num?)?.toDouble() ?? 0.0;
    final subtotal = (sale['subtotal'] as num?)?.toDouble() ?? total;
    final discount = (sale['discount'] as num?)?.toDouble() ?? 0.0;
    final phone = sale['customerPhone']?.toString() ?? '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: TekColors.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: TekColors.border, width: 1.5)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: TekColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Invoice #$inv',
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: TekColors.textPrimary),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: TekColors.textSecondary),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(color: TekColors.border),
              const SizedBox(height: 8),
              _receiptRow('Customer:',
                  sale['customerName']?.toString() ?? 'Walk-in Customer'),
              if (phone.isNotEmpty) _receiptRow('Phone:', phone),
              _receiptRow('Date:', sale['createdAt']?.toString() ?? ''),
              _receiptRow(
                  'Billed By:', sale['staffName']?.toString() ?? 'Staff'),
              const SizedBox(height: 12),
              const Text('Items Sold:',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: TekColors.textSecondary)),
              const SizedBox(height: 6),
              ...items.map((raw) {
                if (raw is! Map) return const SizedBox.shrink();
                final it = Map<String, dynamic>.from(raw);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.5),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '${it['name']} x ${it['qty']}',
                          style: const TextStyle(
                              fontSize: 12.5, color: TekColors.textPrimary),
                        ),
                      ),
                      Text(
                        '₹${((it['price'] ?? 0) * (it['qty'] ?? 1)).toStringAsFixed(0)}',
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                            color: TekColors.textPrimary),
                      ),
                    ],
                  ),
                );
              }),
              const Divider(color: TekColors.border),
              _receiptRow('Subtotal:', '₹${subtotal.toStringAsFixed(2)}'),
              if (discount > 0)
                _receiptRow('Discount:', '-₹${discount.toStringAsFixed(2)}'),
              _receiptRow('Total Billed:', '₹${total.toStringAsFixed(2)}',
                  isBold: true),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        printInvoice(context, sale, a4: true);
                      },
                      icon: const Icon(Icons.print, size: 16),
                      label: const Text('Print A4'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        printInvoice(context, sale, a4: false);
                      },
                      icon: const Icon(Icons.receipt, size: 16),
                      label: const Text('Thermal Roll'),
                    ),
                  ),
                  if (phone.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      style: IconButton.styleFrom(
                        backgroundColor:
                            const Color(0xFF22C55E).withValues(alpha: 0.15),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.share, color: Color(0xFF22C55E)),
                      onPressed: () {
                        Navigator.pop(ctx);
                        sendInvoiceWhatsApp(context, sale);
                      },
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _receiptRow(String k, String v, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k,
              style: TextStyle(
                  fontSize: 12.5,
                  color:
                      isBold ? TekColors.textPrimary : TekColors.textSecondary,
                  fontWeight: isBold ? FontWeight.bold : FontWeight.normal)),
          Text(v,
              style: TextStyle(
                  fontSize: 12.5,
                  color: isBold ? TekColors.primary : TekColors.textPrimary,
                  fontWeight: isBold ? FontWeight.bold : FontWeight.w600)),
        ],
      ),
    );
  }

  // Return / Refund Item Flow
  void _handleReturnItem(Map<String, dynamic> sale) {
    final phone = sale['customerPhone']?.toString() ?? '';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CustomerReturnsScreen(
            initialPhone: phone.isNotEmpty ? phone : null),
      ),
    ).then((_) => _loadData());
  }

  // End-of-Day (10:00 PM) Closing Report Modal
  void _openEodClosingDialog(DailyRegisterSummary currentSummary) {
    DailySalesLedgerView.showEodClosingModal(
      context,
      shopId: widget.shopId,
      currentStaffId: widget.currentStaffId,
      currentStaffName: widget.currentStaffName,
      date: _selectedDate,
      onClosed: _loadData,
    );
  }
}

class _MetricItem {
  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final Color color;

  const _MetricItem({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    required this.color,
  });
}

class _EodClosingSheet extends StatefulWidget {
  final DailyRegisterSummary initialSummary;
  final String shopId;
  final String currentStaffId;
  final String currentStaffName;
  final VoidCallback? onClosed;

  const _EodClosingSheet({
    required this.initialSummary,
    required this.shopId,
    required this.currentStaffId,
    required this.currentStaffName,
    this.onClosed,
  });

  @override
  State<_EodClosingSheet> createState() => _EodClosingSheetState();
}

class _EodClosingSheetState extends State<_EodClosingSheet> {
  late final TextEditingController _cashCountCtrl;
  late final TextEditingController _openingCashCtrl;
  late double _enteredCash;
  late double _openingCash;
  bool _isSaving = false;
  bool _dismissedRentReminder = false;

  @override
  void initState() {
    super.initState();
    _enteredCash = widget.initialSummary.physicalCashCount;
    _openingCash = widget.initialSummary.openingCash;
    _cashCountCtrl = TextEditingController(
      text: _enteredCash > 0 ? _enteredCash.toStringAsFixed(0) : '',
    );
    _openingCashCtrl = TextEditingController(
      text: _openingCash > 0 ? _openingCash.toStringAsFixed(0) : '',
    );
  }

  @override
  void dispose() {
    _cashCountCtrl.dispose();
    _openingCashCtrl.dispose();
    super.dispose();
  }

  Widget _sheetRow(String k, String v,
      {bool isBold = false, Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            k,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w500,
              color: isBold ? TekColors.textPrimary : TekColors.textSecondary,
            ),
          ),
          Text(
            v,
            style: TextStyle(
              fontSize: isBold ? 14 : 12.5,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
              color: valueColor ??
                  (isBold ? TekColors.primary : TekColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.initialSummary;
    final expectedClosingCash = (_openingCash +
            summary.cashCollection -
            summary.refunds -
            summary.totalCashExpenses)
        .clamp(0.0, double.infinity);
    final liveDiscrepancy = _enteredCash - expectedClosingCash;
    final closedByDisplay = summary.closedBy.isNotEmpty
        ? summary.closedBy
        : widget.currentStaffName;

    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        top: 20,
        left: 20,
        right: 20,
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
            // Handle
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: TekColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: TekColors.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.lock_clock_rounded,
                          color: TekColors.primary, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'End-of-Day (EOD) Register Close',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: TekColors.textPrimary,
                          ),
                        ),
                        Text(
                          'Business Date: ${summary.dateString} • Hours: ${summary.openingTime} - ${summary.closingTime}',
                          style: const TextStyle(
                              fontSize: 12, color: TekColors.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: TekColors.textSecondary),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),

            if (summary.isClosed) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F766E).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF0F766E)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.verified_rounded,
                        color: Color(0xFF2DD4BF), size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Already Closed by $closedByDisplay (സൂക്ഷിക്കുക: ഈ തീയതിയിലെ ക്ലോസിംഗ് പൂർത്തിയായതാണ്)',
                        style: const TextStyle(
                          color: Color(0xFF2DD4BF),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Daily Rent EOD Reminder (Requirement 9)
            if (summary.rentPendingWarning && !_dismissedRentReminder) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFF59E0B)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.store_mall_directory_rounded,
                            color: Color(0xFFF59E0B), size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Daily rent has not been recorded for today. Did you pay rent today? (ഇന്നത്തെ കട വാടക രേഖപ്പെടുത്തിയിട്ടില്ല)',
                            style: TextStyle(
                              color: Color(0xFFF59E0B),
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () =>
                              setState(() => _dismissedRentReminder = true),
                          child: const Text('Skip for Now',
                              style: TextStyle(
                                  color: TekColors.textMuted, fontSize: 12)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFF59E0B),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () async {
                            final paid = await DailyRentPaymentDialog.show(
                              context,
                              shopId: widget.shopId,
                              initialDate: summary.date,
                            );
                            if (paid == true) {
                              widget.onClosed?.call();
                              if (context.mounted) Navigator.pop(context);
                            }
                          },
                          icon: const Icon(Icons.add_circle_outline_rounded,
                              size: 14),
                          label: const Text('Yes, Record Rent',
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),

            // 1. Gross Sales & Collections Overview (Requirements from Step 3)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: TekColors.bgSecondary,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: TekColors.border),
              ),
              child: Column(
                children: [
                  _sheetRow('Total Orders:',
                      '${summary.totalOrdersCount} completed orders'),
                  _sheetRow('Gross Sales:',
                      '₹${summary.grossSales.toStringAsFixed(2)}'),
                  _sheetRow('Discounts:',
                      '-₹${summary.totalDiscounts.toStringAsFixed(2)}'),
                  _sheetRow('Refunds / Returns:',
                      '-₹${summary.refunds.toStringAsFixed(2)}',
                      valueColor: summary.refunds > 0 ? TekColors.error : null),
                  const Divider(color: TekColors.border),
                  _sheetRow('Net Sales Revenue:',
                      '₹${summary.netSales.toStringAsFixed(2)}',
                      isBold: true, valueColor: TekColors.success),
                  _sheetRow('Closed By (Staff/User):', closedByDisplay,
                      isBold: true),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // 2. Payment Method Collections
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: TekColors.bgSecondary,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: TekColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Payment Collections Breakdown:',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: TekColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _sheetRow('Cash Collection:',
                      '₹${summary.cashCollection.toStringAsFixed(2)}',
                      valueColor: Colors.amber),
                  _sheetRow('UPI Collection:',
                      '₹${summary.upiCollection.toStringAsFixed(2)}',
                      valueColor: TekColors.secondary),
                  _sheetRow('Card Collection:',
                      '₹${summary.cardCollection.toStringAsFixed(2)}',
                      valueColor: TekColors.info),
                  if (summary.bankRentPaid > 0)
                    _sheetRow('Daily Rent Paid (Bank/UPI):',
                        '₹${summary.bankRentPaid.toStringAsFixed(2)}',
                        valueColor: const Color(0xFFF59E0B)),
                  if (summary.totalBankExpenses > 0)
                    _sheetRow('Bank Expenses Paid:',
                        '-₹${summary.totalBankExpenses.toStringAsFixed(2)}',
                        valueColor: TekColors.error),
                  _sheetRow('Credit / Due Sales:',
                      '₹${summary.creditSales.toStringAsFixed(2)}',
                      valueColor: summary.creditSales > 0
                          ? TekColors.warning
                          : TekColors.textSecondary),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // 3. Cash Drawer Reconciliation & Verification (Step 3 Requirements)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: TekColors.bgSecondary,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: liveDiscrepancy == 0 && _enteredCash > 0
                      ? TekColors.success.withValues(alpha: 0.6)
                      : (liveDiscrepancy < 0
                          ? TekColors.error.withValues(alpha: 0.6)
                          : TekColors.border),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.point_of_sale_rounded,
                          size: 16, color: Colors.amber),
                      SizedBox(width: 8),
                      Text(
                        'Cash Drawer Verification (പണപ്പെട്ടി പരിശോധന):',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: TekColors.textPrimary,
                          fontFamilyFallback: TekTypography.malayalamFallback,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _sheetRow(
                      'Opening Cash:', '₹${_openingCash.toStringAsFixed(2)}'),
                  _sheetRow('Cash Inflow (Sales):',
                      '+₹${summary.cashCollection.toStringAsFixed(2)}',
                      valueColor: TekColors.success),
                  if (summary.cashRentPaid > 0)
                    _sheetRow('Daily Rent Paid (കട വാടക):',
                        '-₹${summary.cashRentPaid.toStringAsFixed(2)}',
                        valueColor: const Color(0xFFF59E0B)),
                  if (summary.ownerSalaryDrawnToday > 0)
                    _sheetRow('Owner Salary Drawn (ശമ്പളം):',
                        '-₹${summary.ownerSalaryDrawnToday.toStringAsFixed(2)}',
                        valueColor: const Color(0xFF8B5CF6)),
                  if (summary.ownerExcessDrawingsToday > 0)
                    _sheetRow('Owner Excess Drawings (പിൻവലിക്കൽ):',
                        '-₹${summary.ownerExcessDrawingsToday.toStringAsFixed(2)}',
                        valueColor: const Color(0xFFA78BFA)),
                  if (summary.otherCashExpenses > 0)
                    _sheetRow('Other Cash Expenses:',
                        '-₹${summary.otherCashExpenses.toStringAsFixed(2)}',
                        valueColor: TekColors.error),
                  if (summary.refunds > 0)
                    _sheetRow('Refunds / Returns:',
                        '-₹${summary.refunds.toStringAsFixed(2)}',
                        valueColor: TekColors.error),
                  _sheetRow('Total Cash Outflows:',
                      '-₹${summary.totalCashOutflows.toStringAsFixed(2)}',
                      valueColor: TekColors.error),
                  const Divider(color: TekColors.border),
                  _sheetRow('Expected Closing Cash:',
                      '₹${expectedClosingCash.toStringAsFixed(2)}',
                      isBold: true, valueColor: Colors.amber),
                  const SizedBox(height: 10),

                  // Input for Actual Cash Count
                  TextField(
                    controller: _cashCountCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: TekColors.textPrimary),
                    onChanged: (v) {
                      setState(() {
                        _enteredCash = double.tryParse(v.trim()) ?? 0.0;
                      });
                    },
                    decoration: InputDecoration(
                      labelText:
                          'Actual Cash Count in Drawer (എണ്ണിയെടുത്ത പണം)',
                      labelStyle: const TextStyle(
                        color: TekColors.textSecondary,
                        fontSize: 12.5,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                      prefixText: '₹ ',
                      prefixStyle: const TextStyle(
                          color: Colors.amber,
                          fontWeight: FontWeight.bold,
                          fontSize: 16),
                      filled: true,
                      fillColor: TekColors.bgCard,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: Colors.amber, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Cash Over / Short Indicator
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: (liveDiscrepancy == 0
                              ? TekColors.success
                              : (liveDiscrepancy > 0
                                  ? TekColors.primary
                                  : TekColors.error))
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          liveDiscrepancy == 0
                              ? Icons.check_circle_rounded
                              : (liveDiscrepancy > 0
                                  ? Icons.info_rounded
                                  : Icons.warning_rounded),
                          size: 14,
                          color: liveDiscrepancy == 0
                              ? TekColors.success
                              : (liveDiscrepancy > 0
                                  ? TekColors.primary
                                  : TekColors.error),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            liveDiscrepancy == 0
                                ? 'Cash Drawer Balanced (തുല്യമാണ് - Exact Match)'
                                : (liveDiscrepancy > 0
                                    ? 'Cash Over: +₹${liveDiscrepancy.toStringAsFixed(2)}'
                                    : 'Cash Shortage: -₹${liveDiscrepancy.abs().toStringAsFixed(2)}'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: liveDiscrepancy == 0
                                  ? TekColors.success
                                  : (liveDiscrepancy > 0
                                      ? TekColors.primary
                                      : TekColors.error),
                              fontFamilyFallback:
                                  TekTypography.malayalamFallback,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // 4. Action Buttons (Print Slip, WhatsApp, Confirm EOD Close)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: const BorderSide(color: TekColors.primary),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
                      DailyRegisterService.instance.printThermalEodSlip(
                        context,
                        summary.copyWith(
                          openingCash: _openingCash,
                          physicalCashCount: _enteredCash,
                          cashDiscrepancy: liveDiscrepancy,
                        ),
                      );
                    },
                    icon: const Icon(Icons.print_rounded,
                        size: 16, color: TekColors.primary),
                    label: const Text('Print Slip',
                        style: TextStyle(
                            color: TekColors.primary, fontSize: 12.5)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: const BorderSide(color: Color(0xFF22C55E)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
                      DailyRegisterService.instance.shareEodWhatsApp(
                        context,
                        summary.copyWith(
                          openingCash: _openingCash,
                          physicalCashCount: _enteredCash,
                          cashDiscrepancy: liveDiscrepancy,
                        ),
                      );
                    },
                    icon: const Icon(Icons.chat_bubble_outline_rounded,
                        size: 16, color: Color(0xFF22C55E)),
                    label: const Text('WhatsApp',
                        style: TextStyle(
                            color: Color(0xFF22C55E), fontSize: 12.5)),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Confirm & Close Button
            SizedBox(
              height: 50,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: summary.isClosed
                      ? const Color(0xFF0F766E)
                      : TekColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                onPressed: _isSaving
                    ? null
                    : () async {
                        setState(() => _isSaving = true);
                        HapticFeedback.heavyImpact();
                        try {
                          final finalSummary = summary.copyWith(
                            openingCash: _openingCash,
                            physicalCashCount: _enteredCash,
                            cashDiscrepancy: liveDiscrepancy,
                            closedByStaffId: widget.currentStaffId,
                            closedByStaffName: widget.currentStaffName,
                          );

                          await DailyRegisterService.instance
                              .closeDailyRegister(
                            summary: finalSummary,
                            shopId: widget.shopId.isNotEmpty
                                ? widget.shopId
                                : Db.setting('shop_id', ''),
                            staffId: widget.currentStaffId,
                            staffName: widget.currentStaffName,
                          );

                          if (mounted) {
                            Navigator.pop(context);
                            toast(context,
                                'End-of-Day Register closed successfully for ${summary.dateString}!');
                            widget.onClosed?.call();
                          }
                        } catch (e) {
                          setState(() => _isSaving = false);
                          if (mounted) {
                            toast(context, 'Save failed: $e', error: true);
                          }
                        }
                      },
                icon: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.lock_rounded, size: 18),
                label: Text(
                  _isSaving
                      ? 'Closing Register...'
                      : (summary.isClosed
                          ? 'Re-Confirm & Save EOD Record'
                          : 'Confirm & Close Register (10:00 PM)'),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
