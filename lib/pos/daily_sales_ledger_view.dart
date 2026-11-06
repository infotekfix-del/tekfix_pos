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
import 'cash_denomination_calculator.dart';
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
    if (!rentInExpenses && cashRent > 0) {
      cExp += cashRent;
    }
    if (!rentInExpenses && bankRent > 0) {
      bExp += bankRent;
    }
    if (!ownerSalInExpenses && ownerWth.cashSalary > 0) {
      cExp += ownerWth.cashSalary;
    }
    if (!ownerSalInExpenses && ownerWth.bankSalary > 0) {
      bExp += ownerWth.bankSalary;
    }

    final openCash = await DailyRegisterService.instance.getOpeningCashForDate(
      targetDate,
      shopId: resolvedShop,
    );
    final isBackdated = !DateUtils.isSameDay(targetDate, DateTime.now());

    final summary = closed ??
        DailyRegisterService.instance.computeDailySummary(
          sales: s,
          date: targetDate,
          openingCash: openCash,
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
          isBackdated: isBackdated,
          closingStatus: isBackdated ? 'BACKDATED' : 'PENDING',
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
        isBackdated: isBackdated,
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
  double _openingCashForDate = 1000.0;
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

      final openCash = await DailyRegisterService.instance.getOpeningCashForDate(
        _selectedDate,
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
      if (!rentInExpenses && cRent > 0) {
        cExp += cRent;
      }
      if (!rentInExpenses && bRent > 0) {
        bExp += bRent;
      }
      if (!ownerSalInExpenses && ownerWth.cashSalary > 0) {
        cExp += ownerWth.cashSalary;
      }
      if (!ownerSalInExpenses && ownerWth.bankSalary > 0) {
        bExp += ownerWth.bankSalary;
      }

      if (mounted) {
        setState(() {
          _sales = s;
          _closedRegister = closed;
          _openingCashForDate = openCash;
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
    final isBackdated = !_isToday;
    return DailyRegisterService.instance.computeDailySummary(
      sales: _sales,
      date: _selectedDate,
      openingCash: _openingCashForDate,
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
      isBackdated: isBackdated,
      closingStatus: isBackdated ? 'BACKDATED' : 'PENDING',
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
                    _buildEodStatusBanner(summary),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 750;

        final titleSection = Row(
          mainAxisSize: MainAxisSize.min,
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
        );

        final actionButtons = Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Close Previous Day Action Button
            InkWell(
              onTap: _showPastDaysStatusSheet,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: TekColors.bgSecondary,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: TekColors.secondary.withValues(alpha: 0.5)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history_toggle_off_rounded,
                        size: 16, color: TekColors.secondary),
                    SizedBox(width: 6),
                    Text(
                      'Close Previous Day',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: TekColors.secondary,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // EOD Close / Register Status Button
            GestureDetector(
              onTap: () => _openEodClosingDialog(summary),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
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
                      isClosed
                          ? Icons.verified_rounded
                          : Icons.nights_stay_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isClosed
                          ? 'EOD Closed (ക്ലോസ്ഡ്)'
                          : 'End of Day (EOD) Close',
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

        if (isNarrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleSection,
              const SizedBox(height: 10),
              actionButtons,
            ],
          );
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            titleSection,
            actionButtons,
          ],
        );
      },
    );
  }

  // EOD Register Status Banner (Requirement 6: Badges & EOD Dashboard Status)
  Widget _buildEodStatusBanner(DailyRegisterSummary summary) {
    final status = summary.resolvedClosingStatus;
    Color statusColor;
    String statusTitle;
    String statusMalayalam;
    IconData statusIcon;

    switch (status) {
      case 'CLOSED':
        statusColor = const Color(0xFF10B981); // Emerald
        statusTitle = 'CLOSED & FINALIZED';
        statusMalayalam = 'ക്ലോസിംഗ് പൂർത്തിയായി';
        statusIcon = Icons.check_circle_rounded;
        break;
      case 'BACKDATED':
        statusColor = const Color(0xFF3B82F6); // Blue
        statusTitle = 'BACKDATED CLOSURE';
        statusMalayalam = 'ബാക്ക്ഡേറ്റഡ് ക്ലോസിംഗ്';
        statusIcon = Icons.history_rounded;
        break;
      case 'DISCREPANCY':
        statusColor = const Color(0xFFEF4444); // Red
        statusTitle = 'CLOSED WITH DISCREPANCY';
        statusMalayalam = 'വ്യത്യാസമുണ്ട് (Discrepancy)';
        statusIcon = Icons.warning_rounded;
        break;
      case 'PENDING':
      default:
        statusColor = const Color(0xFFF59E0B); // Amber
        statusTitle = 'REGISTER OPEN / PENDING';
        statusMalayalam = 'ക്ലോസിംഗ് പെൻഡിങ്';
        statusIcon = Icons.pending_actions_rounded;
        break;
    }

    final isClosed = summary.isClosed;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: statusColor.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(statusIcon, size: 14, color: statusColor),
                    const SizedBox(width: 6),
                    Text(
                      '$statusTitle • $statusMalayalam',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: statusColor,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                  ],
                ),
              ),
              if (isClosed)
                Text(
                  'Closed by ${summary.closedByStaffName.isNotEmpty ? summary.closedByStaffName : summary.closedBy}',
                  style: const TextStyle(
                      fontSize: 11, color: TekColors.textSecondary),
                )
              else
                InkWell(
                  onTap: () => _openEodClosingDialog(summary),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: TekColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Close Register (ക്ലോസ് ചെയ്യുക) →',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: TekColors.primary,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // 4 Key EOD metrics in a row
          Row(
            children: [
              Expanded(
                child: _eodMiniStat(
                  label: 'Opening Cash',
                  value: '₹${summary.openingCash.toStringAsFixed(0)}',
                  color: TekColors.secondary,
                ),
              ),
              Expanded(
                child: _eodMiniStat(
                  label: 'Expected Cash',
                  value:
                      '₹${summary.expectedCashInRegister.toStringAsFixed(0)}',
                  color: Colors.amber,
                ),
              ),
              Expanded(
                child: _eodMiniStat(
                  label: isClosed ? 'Counted Cash' : 'Retained Float',
                  value: isClosed
                      ? '₹${summary.physicalCashCount.toStringAsFixed(0)}'
                      : '₹${summary.retainedCashFloat.toStringAsFixed(0)}',
                  color: isClosed ? TekColors.primary : const Color(0xFF06B6D4),
                ),
              ),
              Expanded(
                child: _eodMiniStat(
                  label: isClosed ? 'Net Handover' : 'Next Day Opening',
                  value: isClosed
                      ? '₹${summary.netCashHandover.toStringAsFixed(0)}'
                      : '₹${summary.nextDayOpeningCash.toStringAsFixed(0)}',
                  color: TekColors.success,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _eodMiniStat(
      {required String label, required String value, required Color color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style:
              const TextStyle(fontSize: 10.5, color: TekColors.textSecondary),
          maxLines: 1,
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.bold, color: color),
        ),
      ],
    );
  }

  void _showPastDaysStatusSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PastDaysStatusSheet(
        shopId: widget.shopId ?? Db.setting('shop_id', ''),
        currentStaffId: widget.currentStaffId ?? 'staff',
        currentStaffName: widget.currentStaffName ?? 'Staff',
        onSelectedDate: (date) {
          Navigator.pop(ctx);
          setState(() => _selectedDate = date);
          _loadData();
        },
        onCloseDate: (date) {
          Navigator.pop(ctx);
          DailySalesLedgerView.showEodClosingModal(
            context,
            shopId: widget.shopId,
            currentStaffId: widget.currentStaffId,
            currentStaffName: widget.currentStaffName,
            date: date,
            onClosed: _loadData,
          );
        },
      ),
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
  final bool isBackdated;
  final VoidCallback? onClosed;

  const _EodClosingSheet({
    required this.initialSummary,
    required this.shopId,
    required this.currentStaffId,
    required this.currentStaffName,
    this.isBackdated = false,
    this.onClosed,
  });

  @override
  State<_EodClosingSheet> createState() => _EodClosingSheetState();
}

class _EodClosingSheetState extends State<_EodClosingSheet> {
  late final TextEditingController _cashCountCtrl;
  late final TextEditingController _openingCashCtrl;
  late final TextEditingController _retainedFloatCtrl;
  late final TextEditingController _ownerCashCtrl;
  late final TextEditingController _bankDepositCtrl;
  late final TextEditingController _otherHandoverCtrl;
  late final TextEditingController _otherRecipientCtrl;
  late final TextEditingController _notesCtrl;

  late double _enteredCash;
  late double _openingCash;
  late double _retainedFloat;
  late double _ownerCash;
  late double _bankDeposit;
  late double _otherHandover;
  late CashDenominations _denominations;

  bool _showDenominations = false;
  bool _isSaving = false;
  bool _dismissedRentReminder = false;

  @override
  void initState() {
    super.initState();
    final init = widget.initialSummary;
    _enteredCash = init.physicalCashCount;
    _openingCash = init.openingCash;
    _retainedFloat =
        init.retainedCashFloat > 0 ? init.retainedCashFloat : 1000.0;
    _denominations = init.denominations;
    if (_denominations.totalCash > 0 && _enteredCash == 0) {
      _enteredCash = _denominations.totalCash;
    }
    _showDenominations = !_denominations.isEmpty;

    _ownerCash = init.handoverSplit.ownerCash;
    _bankDeposit = init.handoverSplit.bankDeposit;
    _otherHandover = init.handoverSplit.otherHandover;

    final netHandover =
        (_enteredCash - _retainedFloat).clamp(0.0, double.infinity);
    if (_ownerCash == 0 &&
        _bankDeposit == 0 &&
        _otherHandover == 0 &&
        netHandover > 0) {
      _ownerCash = netHandover;
    }

    _cashCountCtrl = TextEditingController(
      text: _enteredCash > 0 ? _enteredCash.toStringAsFixed(0) : '',
    );
    _openingCashCtrl = TextEditingController(
      text: _openingCash > 0 ? _openingCash.toStringAsFixed(0) : '',
    );
    _retainedFloatCtrl = TextEditingController(
      text: _retainedFloat > 0 ? _retainedFloat.toStringAsFixed(0) : '1000',
    );
    _ownerCashCtrl = TextEditingController(
      text: _ownerCash > 0 ? _ownerCash.toStringAsFixed(0) : '',
    );
    _bankDepositCtrl = TextEditingController(
      text: _bankDeposit > 0 ? _bankDeposit.toStringAsFixed(0) : '',
    );
    _otherHandoverCtrl = TextEditingController(
      text: _otherHandover > 0 ? _otherHandover.toStringAsFixed(0) : '',
    );
    _otherRecipientCtrl = TextEditingController(
      text: init.handoverSplit.otherRecipientName,
    );
    _notesCtrl = TextEditingController(text: init.notes);
  }

  @override
  void dispose() {
    _cashCountCtrl.dispose();
    _openingCashCtrl.dispose();
    _retainedFloatCtrl.dispose();
    _ownerCashCtrl.dispose();
    _bankDepositCtrl.dispose();
    _otherHandoverCtrl.dispose();
    _otherRecipientCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _setAllToOwner(double netHandover) {
    setState(() {
      _ownerCash = netHandover;
      _bankDeposit = 0.0;
      _otherHandover = 0.0;
      _ownerCashCtrl.text =
          _ownerCash > 0 ? _ownerCash.toStringAsFixed(0) : '';
      _bankDepositCtrl.clear();
      _otherHandoverCtrl.clear();
    });
  }

  void _setAllToBank(double netHandover) {
    setState(() {
      _ownerCash = 0.0;
      _bankDeposit = netHandover;
      _otherHandover = 0.0;
      _ownerCashCtrl.clear();
      _bankDepositCtrl.text =
          _bankDeposit > 0 ? _bankDeposit.toStringAsFixed(0) : '';
      _otherHandoverCtrl.clear();
    });
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

  Widget _settlementCard({
    required String title,
    required String subtitle,
    required double amount,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Icon(icon, size: 14, color: color),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '₹${amount.toStringAsFixed(0)}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 9.5, color: TekColors.textMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Future<bool> _showConfirmationDialog({
    required double actualCash,
    required double retainedFloat,
    required double netHandover,
    required double liveDiscrepancy,
    required CashHandoverSplit split,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: TekColors.bgCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: TekColors.border),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: TekColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.verified_user_rounded,
                      color: TekColors.primary, size: 20),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Confirm EOD Register Close',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: TekColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Business Date: ${widget.initialSummary.dateString}${widget.isBackdated ? " (Backdated)" : ""}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: TekColors.secondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _sheetRow('Physical Cash Count:',
                      '₹${actualCash.toStringAsFixed(2)}',
                      isBold: true, valueColor: Colors.amber),
                  _sheetRow('Retained Cash Float:',
                      '₹${retainedFloat.toStringAsFixed(2)}',
                      valueColor: const Color(0xFF06B6D4)),
                  _sheetRow('Net Cash to Handover:',
                      '₹${netHandover.toStringAsFixed(2)}',
                      isBold: true, valueColor: TekColors.success),
                  const Divider(color: TekColors.border),
                  if (split.ownerCash > 0)
                    _sheetRow('  • Owner Cash:',
                        '₹${split.ownerCash.toStringAsFixed(2)}'),
                  if (split.bankDeposit > 0)
                    _sheetRow('  • Bank Deposit:',
                        '₹${split.bankDeposit.toStringAsFixed(2)}'),
                  if (split.otherHandover > 0)
                    _sheetRow(
                        '  • Other (${split.otherRecipientName.isNotEmpty ? split.otherRecipientName : "Staff"}):',
                        '₹${split.otherHandover.toStringAsFixed(2)}'),
                  const Divider(color: TekColors.border),
                  _sheetRow(
                    'Cash Discrepancy:',
                    liveDiscrepancy == 0
                        ? '₹0.00 (Balanced)'
                        : (liveDiscrepancy > 0
                            ? '+₹${liveDiscrepancy.toStringAsFixed(2)} (Over)'
                            : '-₹${liveDiscrepancy.abs().toStringAsFixed(2)} (Short)'),
                    valueColor: liveDiscrepancy == 0
                        ? TekColors.success
                        : (liveDiscrepancy > 0
                            ? TekColors.primary
                            : TekColors.error),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: TekColors.bgSecondary,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: TekColors.border),
                    ),
                    child: Text(
                      'Retained Cash Float of ₹${retainedFloat.toStringAsFixed(0)} will be stored as opening cash for the next business day. Register close cannot be duplicated.',
                      style: const TextStyle(
                          fontSize: 11.5, color: TekColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel',
                    style: TextStyle(color: TekColors.textMuted)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: TekColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Confirm & Finalize',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _showSuccessDialog(DailyRegisterSummary finalSummary) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: TekColors.success, width: 1.5),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: TekColors.success.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: TekColors.success,
                size: 44,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Register Closed Successfully!',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: TekColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'EOD register finalized for ${finalSummary.dateString}.\nNext day opening cash set to ₹${finalSummary.retainedCashFloat.toStringAsFixed(0)}.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12.5, color: TekColors.textSecondary),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      side: const BorderSide(color: TekColors.primary),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      DailyRegisterService.instance
                          .printThermalEodSlip(context, finalSummary);
                    },
                    icon: const Icon(Icons.print_rounded,
                        size: 16, color: TekColors.primary),
                    label: const Text('Print Slip',
                        style:
                            TextStyle(color: TekColors.primary, fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      side: const BorderSide(color: Color(0xFF22C55E)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      DailyRegisterService.instance
                          .shareEodWhatsApp(context, finalSummary);
                    },
                    icon: const Icon(Icons.chat_bubble_outline_rounded,
                        size: 16, color: Color(0xFF22C55E)),
                    label: const Text('WhatsApp',
                        style: TextStyle(
                            color: Color(0xFF22C55E), fontSize: 12)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: TekColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
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
    final netCashToHandover =
        (_enteredCash - _retainedFloat).clamp(0.0, double.infinity);
    final totalHandoverSplit = _ownerCash + _bankDeposit + _otherHandover;
    final isHandoverBalanced = netCashToHandover <= 0 ||
        (totalHandoverSplit - netCashToHandover).abs() < 0.5;

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

            if (widget.isBackdated) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF3B82F6)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.history_rounded,
                        color: Color(0xFF60A5FA), size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Backdated Closing for ${summary.dateString} (കഴിഞ്ഞ ദിവസത്തെ ക്ലോസിംഗ്). Next business day opening cash will be updated safely.',
                        style: const TextStyle(
                          color: Color(0xFF93C5FD),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFamilyFallback: TekTypography.malayalamFallback,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

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
                          fontFamilyFallback: TekTypography.malayalamFallback,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Daily Rent EOD Reminder
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
                              fontFamilyFallback:
                                  TekTypography.malayalamFallback,
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

            // 1. Gross Sales & Collections Overview
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

            // 3. Cash Drawer Reconciliation & Verification
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

                  // Denomination Calculator Toggle Header
                  InkWell(
                    onTap: () =>
                        setState(() => _showDenominations = !_showDenominations),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: TekColors.bgCard,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: _showDenominations
                                ? TekColors.primary
                                : TekColors.border),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.calculate_rounded,
                                  size: 16, color: TekColors.primary),
                              SizedBox(width: 8),
                              Text(
                                'Cash Denomination Calculator (നോട്ടുകൾ എണ്ണുക)',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: TekColors.textPrimary,
                                  fontFamilyFallback:
                                      TekTypography.malayalamFallback,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              if (_denominations.totalCash > 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: TekColors.primary
                                        .withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '₹${_denominations.totalCash.toStringAsFixed(0)}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: TekColors.primary,
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 4),
                              Icon(
                                _showDenominations
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                                color: TekColors.textSecondary,
                                size: 18,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Embedded Denomination Calculator
                  if (_showDenominations) ...[
                    const SizedBox(height: 10),
                    CashDenominationCalculator(
                      initialDenominations: _denominations,
                      onChanged: (d) {
                        setState(() {
                          _denominations = d;
                          _enteredCash = d.totalCash;
                          _cashCountCtrl.text = _enteredCash > 0
                              ? _enteredCash.toStringAsFixed(0)
                              : '';
                          final net = (_enteredCash - _retainedFloat)
                              .clamp(0.0, double.infinity);
                          if (_bankDeposit == 0 && _otherHandover == 0) {
                            _ownerCash = net;
                            _ownerCashCtrl.text = _ownerCash > 0
                                ? _ownerCash.toStringAsFixed(0)
                                : '';
                          }
                        });
                      },
                    ),
                  ],

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
                        final net = (_enteredCash - _retainedFloat)
                            .clamp(0.0, double.infinity);
                        if (_bankDeposit == 0 && _otherHandover == 0) {
                          _ownerCash = net;
                          _ownerCashCtrl.text = _ownerCash > 0
                              ? _ownerCash.toStringAsFixed(0)
                              : '';
                        }
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
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

            // 4. Daily Cash Float & 3-Card Settlement Display (Requirement 1 & 4)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: TekColors.bgSecondary,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: const Color(0xFF06B6D4).withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.savings_rounded,
                          size: 16, color: Color(0xFF06B6D4)),
                      SizedBox(width: 8),
                      Text(
                        'Daily Cash Float (അടുത്ത ദിവസത്തേക്ക് മാറ്റിവെക്കുന്ന പണം):',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: TekColors.textPrimary,
                          fontFamilyFallback: TekTypography.malayalamFallback,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Editable Retained Cash Float input (default: ₹1,000)
                  TextField(
                    controller: _retainedFloatCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF06B6D4)),
                    onChanged: (v) {
                      setState(() {
                        _retainedFloat =
                            double.tryParse(v.trim()) ?? 1000.0;
                        final net = (_enteredCash - _retainedFloat)
                            .clamp(0.0, double.infinity);
                        if (_bankDeposit == 0 && _otherHandover == 0) {
                          _ownerCash = net;
                          _ownerCashCtrl.text = _ownerCash > 0
                              ? _ownerCash.toStringAsFixed(0)
                              : '';
                        }
                      });
                    },
                    decoration: InputDecoration(
                      labelText:
                          'Retained Cash Float (Next Day Opening Cash) - Default ₹1,000',
                      labelStyle: const TextStyle(
                          color: TekColors.textSecondary, fontSize: 12),
                      prefixText: '₹ ',
                      prefixStyle: const TextStyle(
                          color: Color(0xFF06B6D4),
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                      filled: true,
                      fillColor: TekColors.bgCard,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(
                            color: Color(0xFF06B6D4), width: 1.5),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Prominent 3-Card Display
                  Row(
                    children: [
                      Expanded(
                        child: _settlementCard(
                          title: 'Actual Count',
                          subtitle: 'Physical Cash',
                          amount: _enteredCash,
                          color: Colors.amber,
                          icon: Icons.payments_rounded,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _settlementCard(
                          title: 'Retained Float',
                          subtitle: 'Next Day Opening',
                          amount: _retainedFloat,
                          color: const Color(0xFF06B6D4),
                          icon: Icons.savings_rounded,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _settlementCard(
                          title: 'Net Handover',
                          subtitle: 'Count - Float',
                          amount: netCashToHandover,
                          color: TekColors.success,
                          icon: Icons.handshake_rounded,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF06B6D4).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded,
                            size: 14, color: Color(0xFF06B6D4)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Retained float stays in the drawer as Next Day Opening Cash (₹${_retainedFloat.toStringAsFixed(0)}). It is NOT an expense and does not reduce profit.',
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF06B6D4)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // 5. Handover Destination Recording (Requirement 4)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: TekColors.bgSecondary,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isHandoverBalanced
                      ? TekColors.border
                      : TekColors.warning.withValues(alpha: 0.6),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.handshake_rounded,
                              size: 16, color: TekColors.primary),
                          SizedBox(width: 8),
                          Text(
                            'Handover Destination Recording:',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: TekColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          InkWell(
                            onTap: () => _setAllToOwner(netCashToHandover),
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: TekColors.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text('All to Owner',
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      color: TekColors.primary,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: () => _setAllToBank(netCashToHandover),
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F766E)
                                    .withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text('All to Bank',
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      color: Color(0xFF2DD4BF),
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _ownerCashCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: TekColors.textPrimary),
                          onChanged: (v) => setState(() =>
                              _ownerCash = double.tryParse(v.trim()) ?? 0.0),
                          decoration: InputDecoration(
                            labelText: 'Owner Cash (ഉടമ)',
                            labelStyle: const TextStyle(
                              fontSize: 12,
                              fontFamilyFallback:
                                  TekTypography.malayalamFallback,
                            ),
                            prefixText: '₹ ',
                            filled: true,
                            fillColor: TekColors.bgCard,
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _bankDepositCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: TekColors.textPrimary),
                          onChanged: (v) => setState(() =>
                              _bankDeposit = double.tryParse(v.trim()) ?? 0.0),
                          decoration: InputDecoration(
                            labelText: 'Bank Deposit (ബാങ്ക്)',
                            labelStyle: const TextStyle(
                              fontSize: 12,
                              fontFamilyFallback:
                                  TekTypography.malayalamFallback,
                            ),
                            prefixText: '₹ ',
                            filled: true,
                            fillColor: TekColors.bgCard,
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  Row(
                    children: [
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: _otherHandoverCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: TekColors.textPrimary),
                          onChanged: (v) => setState(() => _otherHandover =
                              double.tryParse(v.trim()) ?? 0.0),
                          decoration: InputDecoration(
                            labelText: 'Other Handover (മറ്റുള്ളവർ)',
                            labelStyle: const TextStyle(
                              fontSize: 12,
                              fontFamilyFallback:
                                  TekTypography.malayalamFallback,
                            ),
                            prefixText: '₹ ',
                            filled: true,
                            fillColor: TekColors.bgCard,
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: _otherRecipientCtrl,
                          style: const TextStyle(
                              fontSize: 14, color: TekColors.textPrimary),
                          decoration: InputDecoration(
                            labelText: 'Recipient Name (ആർക്ക് നൽകി)',
                            labelStyle: const TextStyle(
                              fontSize: 12,
                              fontFamilyFallback:
                                  TekTypography.malayalamFallback,
                            ),
                            filled: true,
                            fillColor: TekColors.bgCard,
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  // Handover Match Indicator
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: (isHandoverBalanced
                              ? TekColors.success
                              : TekColors.warning)
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: isHandoverBalanced
                              ? TekColors.success
                              : TekColors.warning),
                    ),
                    child: Row(
                      children: [
                        Icon(
                            isHandoverBalanced
                                ? Icons.check_circle_rounded
                                : Icons.error_outline_rounded,
                            size: 16,
                            color: isHandoverBalanced
                                ? TekColors.success
                                : TekColors.warning),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isHandoverBalanced
                                ? 'Handover split matches Net Handover: ₹${totalHandoverSplit.toStringAsFixed(2)}'
                                : 'Split total (₹${totalHandoverSplit.toStringAsFixed(2)}) does not match Net Handover (₹${netCashToHandover.toStringAsFixed(2)}). Discrepancy: ${totalHandoverSplit - netCashToHandover > 0 ? "+₹" : "-₹"}${(totalHandoverSplit - netCashToHandover).abs().toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                              color: isHandoverBalanced
                                  ? TekColors.success
                                  : TekColors.warning,
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

            // 6. Action Buttons (Print Slip, WhatsApp)
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
                      final s = summary.copyWith(
                        openingCash: _openingCash,
                        physicalCashCount: _enteredCash,
                        cashDiscrepancy: liveDiscrepancy,
                        retainedCashFloat: _retainedFloat,
                        denominations: _denominations,
                        handoverSplit: CashHandoverSplit(
                          ownerCash: _ownerCash,
                          bankDeposit: _bankDeposit,
                          otherHandover: _otherHandover,
                          otherRecipientName: _otherRecipientCtrl.text.trim(),
                        ),
                        isBackdated: widget.isBackdated,
                      );
                      DailyRegisterService.instance
                          .printThermalEodSlip(context, s);
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
                      final s = summary.copyWith(
                        openingCash: _openingCash,
                        physicalCashCount: _enteredCash,
                        cashDiscrepancy: liveDiscrepancy,
                        retainedCashFloat: _retainedFloat,
                        denominations: _denominations,
                        handoverSplit: CashHandoverSplit(
                          ownerCash: _ownerCash,
                          bankDeposit: _bankDeposit,
                          otherHandover: _otherHandover,
                          otherRecipientName: _otherRecipientCtrl.text.trim(),
                        ),
                        isBackdated: widget.isBackdated,
                      );
                      DailyRegisterService.instance
                          .shareEodWhatsApp(context, s);
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
                        if (!isHandoverBalanced && netCashToHandover > 0) {
                          toast(
                            context,
                            'Handover split total (₹${totalHandoverSplit.toStringAsFixed(0)}) must match Net Cash to Handover (₹${netCashToHandover.toStringAsFixed(0)})',
                            error: true,
                          );
                          return;
                        }

                        final split = CashHandoverSplit(
                          ownerCash: _ownerCash,
                          bankDeposit: _bankDeposit,
                          otherHandover: _otherHandover,
                          otherRecipientName: _otherRecipientCtrl.text.trim(),
                        );

                        final confirmed = await _showConfirmationDialog(
                          actualCash: _enteredCash,
                          retainedFloat: _retainedFloat,
                          netHandover: netCashToHandover,
                          liveDiscrepancy: liveDiscrepancy,
                          split: split,
                        );

                        if (!confirmed) return;

                        setState(() => _isSaving = true);
                        HapticFeedback.heavyImpact();
                        try {
                          final finalSummary = summary.copyWith(
                            openingCash: _openingCash,
                            physicalCashCount: _enteredCash,
                            cashDiscrepancy: liveDiscrepancy,
                            retainedCashFloat: _retainedFloat,
                            denominations: _denominations,
                            handoverSplit: split,
                            isBackdated: widget.isBackdated,
                            closedByStaffId: widget.currentStaffId,
                            closedByStaffName: widget.currentStaffName,
                            notes: _notesCtrl.text.trim(),
                          );

                          await DailyRegisterService.instance
                              .closeDailyRegister(
                            summary: finalSummary,
                            shopId: widget.shopId.isNotEmpty
                                ? widget.shopId
                                : Db.setting('shop_id', ''),
                            staffId: widget.currentStaffId,
                            staffName: widget.currentStaffName,
                            isBackdated: widget.isBackdated,
                            notes: _notesCtrl.text.trim(),
                          );

                          if (!mounted) return;
                          Navigator.pop(context);
                          await _showSuccessDialog(finalSummary);
                          widget.onClosed?.call();
                        } catch (e) {
                          if (mounted) {
                            setState(() => _isSaving = false);
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

// Past Days Register Status Bottom Sheet (Requirement 5 & 6)
class _PastDaysStatusSheet extends StatelessWidget {
  final String shopId;
  final String currentStaffId;
  final String currentStaffName;
  final ValueChanged<DateTime> onSelectedDate;
  final ValueChanged<DateTime> onCloseDate;

  const _PastDaysStatusSheet({
    required this.shopId,
    required this.currentStaffId,
    required this.currentStaffName,
    required this.onSelectedDate,
    required this.onCloseDate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.78,
      padding: const EdgeInsets.all(18),
      decoration: const BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: TekColors.border, width: 1.5)),
      ),
      child: Column(
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
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.history_rounded,
                      color: TekColors.primary, size: 22),
                  SizedBox(width: 10),
                  Text(
                    'EOD Register Status & Past Days',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: TekColors.textPrimary,
                    ),
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
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<DailyRegisterSummary>>(
              future: DailyRegisterService.instance
                  .getPastDaysRegisterStatus(shopId: shopId, days: 7),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                        color: TekColors.primary),
                  );
                }
                final list = snapshot.data ?? [];
                if (list.isEmpty) {
                  return const Center(
                    child: Text('No register records found',
                        style: TextStyle(color: TekColors.textSecondary)),
                  );
                }

                return ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = list[index];
                    final status = item.resolvedClosingStatus;
                    Color statusColor;
                    IconData statusIcon;

                    switch (status) {
                      case 'CLOSED':
                        statusColor = const Color(0xFF10B981);
                        statusIcon = Icons.check_circle_rounded;
                        break;
                      case 'BACKDATED':
                        statusColor = const Color(0xFF3B82F6);
                        statusIcon = Icons.history_rounded;
                        break;
                      case 'DISCREPANCY':
                        statusColor = const Color(0xFFEF4444);
                        statusIcon = Icons.warning_rounded;
                        break;
                      case 'PENDING':
                      default:
                        statusColor = const Color(0xFFF59E0B);
                        statusIcon = Icons.pending_actions_rounded;
                        break;
                    }

                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: TekColors.bgSecondary,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: statusColor.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                DailyRegisterService.toDisplayDate(item.date),
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.bold,
                                  color: TekColors.textPrimary,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color:
                                          statusColor.withValues(alpha: 0.4)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(statusIcon,
                                        size: 12, color: statusColor),
                                    const SizedBox(width: 4),
                                    Text(
                                      status,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: statusColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Opening: ₹${item.openingCash.toStringAsFixed(0)} • Sales: ₹${item.grossSales.toStringAsFixed(0)}',
                                style: const TextStyle(
                                    fontSize: 11.5,
                                    color: TekColors.textSecondary),
                              ),
                              if (item.isClosed)
                                Text(
                                  'Counted: ₹${item.physicalCashCount.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.amber),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => onSelectedDate(item.date),
                                child: const Text('View Ledger Orders',
                                    style: TextStyle(
                                        fontSize: 11.5,
                                        color: TekColors.secondary)),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: item.isClosed
                                      ? const Color(0xFF0F766E)
                                      : TekColors.primary,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(8)),
                                ),
                                onPressed: () => onCloseDate(item.date),
                                child: Text(
                                  item.isClosed
                                      ? 'View / Print Slip'
                                      : 'Close Register Now',
                                  style: const TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              side: const BorderSide(color: TekColors.primary),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: DateTime.now().subtract(const Duration(days: 1)),
                firstDate: DateTime(2022),
                lastDate: DateTime.now(),
              );
              if (picked != null) {
                onCloseDate(picked);
              }
            },
            icon: const Icon(Icons.date_range_rounded,
                size: 16, color: TekColors.primary),
            label: const Text('Pick Another Past Date to Close (മറ്റൊരു തീയതി)',
                style: TextStyle(color: TekColors.primary, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}
