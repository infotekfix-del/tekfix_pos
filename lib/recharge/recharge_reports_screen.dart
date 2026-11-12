import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../main.dart' show Db;
import '../theme/tek_tokens.dart';
import 'recharge_models.dart';
import 'recharge_service.dart';

/// Master Recharge Reports & Financial Reconciliation Dashboard
class RechargeReportsScreen extends StatefulWidget {
  final String shopId;

  const RechargeReportsScreen({
    super.key,
    required this.shopId,
  });

  static Future<void> show(BuildContext context, {required String shopId}) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RechargeReportsScreen(shopId: shopId),
      ),
    );
  }

  @override
  State<RechargeReportsScreen> createState() => _RechargeReportsScreenState();
}

class _RechargeReportsScreenState extends State<RechargeReportsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final RechargeService _service = RechargeService.instance;
  final NumberFormat _currencyFormat = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 2,
  );

  DateRangeFilterType _activeFilterType = DateRangeFilterType.today;
  DateTime _startDate = DateTime.now();
  DateTime _endDate = DateTime.now();
  RechargeOperator? _selectedOperatorFilter;
  RechargePaymentMode? _selectedPaymentModeFilter;

  bool _isLoading = true;
  RechargeFinancialReport? _report;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _applyFilterType(DateRangeFilterType.today, reload: false);
    _loadReport();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _applyFilterType(DateRangeFilterType type, {bool reload = true}) {
    final (s, e) = type.getRange(_startDate, _endDate);
    setState(() {
      _activeFilterType = type;
      _startDate = s;
      _endDate = e;
    });
    if (reload) {
      _loadReport();
    }
  }

  Future<void> _pickCustomDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2025, 1, 1),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: TekColors.primaryBlue,
              onPrimary: Colors.white,
              surface: TekColors.cardBg,
              onSurface: TekColors.textPrimary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _activeFilterType = DateRangeFilterType.custom;
        _startDate = DateTime(picked.start.year, picked.start.month, picked.start.day);
        _endDate = DateTime(picked.end.year, picked.end.month, picked.end.day, 23, 59, 59, 999);
      });
      _loadReport();
    }
  }

  Future<void> _loadReport() async {
    setState(() => _isLoading = true);
    try {
      final filter = RechargeReportFilter(
        filterType: _activeFilterType,
        startDate: _startDate,
        endDate: _endDate,
        operator: _selectedOperatorFilter,
        paymentMode: _selectedPaymentModeFilter,
      );

      final report = await _service.generateFinancialReport(
        shopId: widget.shopId,
        filter: filter,
      );

      setState(() {
        _report = report;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('റിപ്പോർട്ട് ലോഡ് ചെയ്യുന്നതിൽ പിശക്: $e'),
            backgroundColor: TekColors.error,
          ),
        );
      }
    }
  }

  Future<void> _exportPdf() async {
    if (_report == null) return;
    try {
      final shopName = Db.setting('shop_name', 'TEKFIX DIGITAL HUB');
      final shopAddress = Db.setting('shop_address', 'Calicut, Kerala');
      final shopPhone = Db.setting('shop_phone', '');

      final pdfBytes = await _service.generateReportPdf(
        _report!,
        shopName: shopName,
        shopAddress: shopAddress,
        shopPhone: shopPhone,
      );

      await Printing.layoutPdf(
        name: 'Recharge_Financial_Report_${_report!.filter.filterType.name}',
        onLayout: (_) async => pdfBytes,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PDF ജനറേഷൻ പരാജയപ്പെട്ടു: $e'),
            backgroundColor: TekColors.error,
          ),
        );
      }
    }
  }

  void _exportCsv({bool excel = false}) {
    if (_report == null) return;
    final shopName = Db.setting('shop_name', 'TEKFIX DIGITAL HUB');
    final csvContent = excel
        ? _service.generateReportExcelCsv(_report!, shopName: shopName)
        : _service.generateReportCsv(_report!, shopName: shopName);

    Clipboard.setData(ClipboardData(text: csvContent));

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.cardBg,
        title: Row(
          children: [
            Icon(
              excel ? Icons.table_view_rounded : Icons.file_copy_rounded,
              color: excel ? TekColors.success : TekColors.electricCyan,
            ),
            const SizedBox(width: 8),
            Text(
              excel ? 'Excel Export (CSV Copied)' : 'CSV Export Copied',
              style: const TextStyle(color: TekColors.textPrimary, fontSize: 16),
            ),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                excel
                    ? 'റിപ്പോർട്ട് ഡാറ്റ UTF-8 Excel ഫോർമാറ്റിൽ ക്ലിപ്പ്ബോർഡിലേക്ക് കോപ്പി ചെയ്തു. Excel അല്ലെങ്കിൽ Google Sheets തുറന്ന് Paste (Ctrl+V) ചെയ്യുക.'
                    : 'CSV ഡാറ്റ ക്ലിപ്പ്ബോർഡിലേക്ക് കോപ്പി ചെയ്തു.',
                style: const TextStyle(color: TekColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Container(
                height: 140,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: TekColors.mainBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: TekColors.border),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    csvContent,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: TekColors.textMuted,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK', style: TextStyle(color: TekColors.primaryBlue)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TekColors.mainBg,
      appBar: _buildAppBar(),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: TekColors.electricCyan),
            )
          : RefreshIndicator(
              onRefresh: _loadReport,
              color: TekColors.electricCyan,
              backgroundColor: TekColors.cardBg,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFilterBar(),
                    const SizedBox(height: 16),
                    if (_report != null) ...[
                      _buildExecutiveSummaryCards(),
                      const SizedBox(height: 20),
                      _buildNonRevenueNoticeCard(),
                      const SizedBox(height: 20),
                      _buildTabsSection(),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: TekColors.sidebarBg,
      elevation: 0,
      title: const Row(
        children: [
          Icon(Icons.analytics_rounded, color: TekColors.electricCyan, size: 22),
          SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Recharge Audit & Financial Reports',
                style: TextStyle(
                  color: TekColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'റീചാർജ് കളക്ഷൻ, കമ്മീഷൻ ലാഭം & ഫിനാൻഷ്യൽ ഓഡിറ്റ്',
                style: TextStyle(color: TekColors.textSecondary, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh_rounded, color: TekColors.textSecondary),
          onPressed: _loadReport,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.file_download_outlined, color: TekColors.electricCyan),
          tooltip: 'Export Report',
          color: TekColors.elevatedSurface,
          onSelected: (val) {
            if (val == 'pdf') _exportPdf();
            if (val == 'excel') _exportCsv(excel: true);
            if (val == 'csv') _exportCsv(excel: false);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'pdf',
              child: Row(
                children: [
                  Icon(Icons.picture_as_pdf_rounded, color: TekColors.error, size: 18),
                  SizedBox(width: 8),
                  Text('Export PDF Report', style: TextStyle(color: TekColors.textPrimary, fontSize: 13)),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'excel',
              child: Row(
                children: [
                  Icon(Icons.table_view_rounded, color: TekColors.success, size: 18),
                  SizedBox(width: 8),
                  Text('Export to Excel', style: TextStyle(color: TekColors.textPrimary, fontSize: 13)),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'csv',
              child: Row(
                children: [
                  Icon(Icons.code_rounded, color: TekColors.electricCyan, size: 18),
                  SizedBox(width: 8),
                  Text('Export CSV', style: TextStyle(color: TekColors.textPrimary, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TekColors.sidebarBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TekColors.border),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...DateRangeFilterType.values.map((type) {
            final isSel = _activeFilterType == type;
            return ChoiceChip(
              label: Text(type.label),
              selected: isSel,
              selectedColor: TekColors.primaryBlue,
              backgroundColor: TekColors.cardBg,
              labelStyle: TextStyle(
                color: isSel ? Colors.white : TekColors.textSecondary,
                fontSize: 12,
                fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
              ),
              onSelected: (_) {
                if (type == DateRangeFilterType.custom) {
                  _pickCustomDateRange();
                } else {
                  _applyFilterType(type);
                }
              },
            );
          }),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: TekColors.cardBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: TekColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.date_range_rounded, color: TekColors.electricCyan, size: 16),
                const SizedBox(width: 6),
                Text(
                  _report?.filter.dateRangeDisplay ?? '',
                  style: const TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExecutiveSummaryCards() {
    final rep = _report!;
    final isDesktop = MediaQuery.of(context).size.width >= 1000;

    final cards = [
      _buildMetricCard(
        title: 'Successful Recharges',
        malayalam: 'വിജയകരമായ റീചാർജ്',
        amount: rep.totalRechargeAmount,
        subtitle: '${rep.successfulCount} ഇടപാടുകൾ',
        icon: Icons.check_circle_outline_rounded,
        color: TekColors.success,
        gradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF059669)]),
      ),
      _buildMetricCard(
        title: 'Customer Collections',
        malayalam: 'ആകെ കളക്ഷൻ',
        amount: rep.totalCustomerCollection,
        subtitle: 'Cash: ${_currencyFormat.format(rep.cashCollection)} | UPI: ${_currencyFormat.format(rep.upiCollection)}',
        icon: Icons.account_balance_wallet_rounded,
        color: TekColors.primaryBlue,
        gradient: TekColors.cyanBlueGradient,
      ),
      _buildMetricCard(
        title: 'Net Commission Income',
        malayalam: 'യഥാർത്ഥ കമ്മീഷൻ ലാഭം',
        amount: rep.netCommissionIncome,
        subtitle: 'Gross: ${_currencyFormat.format(rep.confirmedCommissionEarned)} - Rev: ${_currencyFormat.format(rep.confirmedCommissionReversed)}',
        icon: Icons.trending_up_rounded,
        color: TekColors.warning,
        gradient: const LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFD97706)]),
        highlight: true,
      ),
      _buildMetricCard(
        title: 'Customer Refunds',
        malayalam: 'ഉപഭോക്താവിന് നൽകിയ റീഫണ്ട്',
        amount: rep.refundedAmount,
        subtitle: '${rep.refundedCount} റീഫണ്ടുകൾ',
        icon: Icons.undo_rounded,
        color: TekColors.error,
        gradient: const LinearGradient(colors: [Color(0xFFEF4444), Color(0xFFB91C1C)]),
      ),
    ];

    return isDesktop
        ? Row(
            children: cards
                .map((c) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: c,
                      ),
                    ))
                .toList(),
          )
        : Column(
            children: cards
                .map((c) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: c,
                    ))
                .toList(),
          );
  }

  Widget _buildMetricCard({
    required String title,
    required String malayalam,
    required double amount,
    required String subtitle,
    required IconData icon,
    required Color color,
    required LinearGradient gradient,
    bool highlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlight ? color.withValues(alpha: 0.6) : TekColors.border,
          width: highlight ? 1.6 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: TekColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: Colors.white, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            malayalam,
            style: const TextStyle(color: TekColors.textMuted, fontSize: 10),
          ),
          const SizedBox(height: 8),
          Text(
            _currencyFormat.format(amount),
            style: TextStyle(
              color: color,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: TekColors.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildNonRevenueNoticeCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TekColors.sidebarBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TekColors.electricCyan.withValues(alpha: 0.3)),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline_rounded, color: TekColors.electricCyan, size: 20),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'അക്കൗണ്ടിംഗ് ചട്ടം: റീചാർജ് തുക (Principal) റീട്ടെയിൽ വരുമാനമല്ല. യഥാർത്ഥത്തിൽ ലഭിച്ച കമ്മീഷൻ മാത്രമേ കടയുടെ അറ്റാദായമായി (Net Profit) കണക്കാക്കൂ. കസ്റ്റമർ കളക്ഷൻ പണം കടയുടെ കയ്യിലുള്ള പാസ്-ത്രൂ ഫണ്ട് ആണ്.',
              style: TextStyle(
                color: TekColors.textSecondary,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabsSection() {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: TekColors.sidebarBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: TekColors.border),
          ),
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            labelColor: TekColors.electricCyan,
            unselectedLabelColor: TekColors.textSecondary,
            indicatorColor: TekColors.electricCyan,
            indicatorWeight: 3,
            tabs: const [
              Tab(text: 'Operator Breakdown'),
              Tab(text: 'Commission & Profit'),
              Tab(text: 'Wallet Balances'),
              Tab(text: 'Distributor Outstandings'),
              Tab(text: 'Cash & Bank Reconciliation'),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 600,
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildOperatorBreakdownTab(),
              _buildCommissionProfitTab(),
              _buildWalletBalancesTab(),
              _buildDistributorOutstandingsTab(),
              _buildCashBankReconciliationTab(),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _buildTransactionTableSection(),
      ],
    );
  }

  Widget _buildOperatorBreakdownTab() {
    final rep = _report!;
    return ListView(
      children: RechargeOperator.values.map((op) {
        final s = rep.operatorReports[op];
        if (s == null) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: TekColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: TekColors.border),
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
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _getOperatorColor(op),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        op.displayName,
                        style: const TextStyle(
                          color: TekColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    _currencyFormat.format(s.successfulAmount),
                    style: const TextStyle(
                      color: TekColors.success,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _statPill('Transactions', '${s.successfulCount}'),
                  _statPill('Cash', _currencyFormat.format(s.cashCollection)),
                  _statPill('UPI', _currencyFormat.format(s.upiCollection)),
                  _statPill('Card', _currencyFormat.format(s.cardCollection)),
                  _statPill('Commission', _currencyFormat.format(s.actualCommissionEarned), highlight: true),
                  if (s.refundedCount > 0)
                    _statPill('Refunded', _currencyFormat.format(s.refundedAmount), isNegative: true),
                  if (s.failedCount > 0)
                    _statPill('Failed', _currencyFormat.format(s.failedAmount), isNegative: true),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCommissionProfitTab() {
    final rep = _report!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TekColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Profit & Commission Accounting Summary',
            style: TextStyle(
              color: TekColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'യഥാർത്ഥത്തിൽ ലഭിച്ച അറ്റ കമ്മീഷൻ ലാഭം (Net Margin Recognized)',
            style: TextStyle(color: TekColors.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 18),
          _reconRow('Confirmed Commission Earned (Gross Margin)', _currencyFormat.format(rep.confirmedCommissionEarned), TekColors.success),
          _reconRow('Confirmed Commission Clawbacks (Reversed)', '-${_currencyFormat.format(rep.confirmedCommissionReversed)}', TekColors.error),
          const Divider(color: TekColors.border, thickness: 1.2),
          _reconRow('NET COMMISSION INCOME (RETAIL PROFIT)', _currencyFormat.format(rep.netCommissionIncome), TekColors.warning, isBold: true),
          const SizedBox(height: 20),
          const Text(
            'Operator Commission Split:',
            style: TextStyle(color: TekColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ...RechargeOperator.values.map((op) {
            final s = rep.operatorReports[op];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(op.displayName, style: const TextStyle(color: TekColors.textSecondary, fontSize: 12)),
                  Text(
                    _currencyFormat.format(s?.actualCommissionEarned ?? 0.0),
                    style: const TextStyle(color: TekColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildWalletBalancesTab() {
    final rep = _report!;
    return ListView(
      children: RechargeOperator.values.map((op) {
        final w = rep.walletReports[op];
        if (w == null) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: TekColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: TekColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${op.displayName} Wallet',
                    style: const TextStyle(
                      color: TekColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'Closing: ${_currencyFormat.format(w.closingBalance)}',
                    style: const TextStyle(
                      color: TekColors.electricCyan,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _statPill('Opening', _currencyFormat.format(w.openingBalance)),
                  _statPill('Own Top-Up', _currencyFormat.format(w.ownTopUp)),
                  _statPill('Dist. Credit', _currencyFormat.format(w.distributorCredit)),
                  _statPill('Debits', _currencyFormat.format(w.rechargeDebits), isNegative: true),
                  _statPill('Reversals', _currencyFormat.format(w.reversals)),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDistributorOutstandingsTab() {
    final rep = _report!;
    return ListView(
      children: rep.distributorReports.map((d) {
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: TekColors.cardBg,
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.distributorName,
                          style: const TextStyle(
                            color: TekColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Operator: ${d.defaultOperator.displayName}',
                          style: const TextStyle(color: TekColors.textMuted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text('Outstanding Debt', style: TextStyle(color: TekColors.textMuted, fontSize: 10)),
                      Text(
                        _currencyFormat.format(d.closingOutstanding),
                        style: const TextStyle(
                          color: TekColors.warning,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _statPill('Opening Payable', _currencyFormat.format(d.openingPayable)),
                  _statPill('Credit Received', _currencyFormat.format(d.creditReceived)),
                  _statPill('Total Paid', _currencyFormat.format(d.paymentsMade)),
                  _statPill('Cash Paid', _currencyFormat.format(d.cashPayments)),
                  _statPill('UPI Paid', _currencyFormat.format(d.upiPayments)),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCashBankReconciliationTab() {
    final rep = _report!;
    final recon = rep.reconciliation;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TekColors.border),
      ),
      child: ListView(
        children: [
          const Text(
            'Physical Cash Drawer & Bank Reconciliation',
            style: TextStyle(
              color: TekColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'ഫിസിക്കൽ ക്യാഷ് ഡ്രോയറും ബാങ്ക് UPI ഇൻഫ്ലോയും തമ്മിലുള്ള ഒത്തുനോക്കൽ',
            style: TextStyle(color: TekColors.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 18),
          _reconRow('Recharge Physical Cash Inflow', '+${_currencyFormat.format(recon.rechargeCashCollected)}', TekColors.success),
          _reconRow('Customer Cash Refunds Outflow', '-${_currencyFormat.format(recon.customerCashRefunds)}', TekColors.error),
          _reconRow('Distributor Cash Settlements Outflow', '-${_currencyFormat.format(recon.distributorCashPayments)}', TekColors.error),
          _reconRow('Contra Bank Cash Deposits (Float Recovery)', '-${_currencyFormat.format(recon.actualCashDepositedToBank)}', TekColors.premiumPurple),
          const Divider(color: TekColors.border, thickness: 1.2),
          _reconRow('NET PHYSICAL CASH DRAWER FLOW', _currencyFormat.format(recon.netPhysicalCashFlow), TekColors.primaryBlue, isBold: true),
          const SizedBox(height: 20),
          const Text(
            'Digital & Bank Account Reconciliation:',
            style: TextStyle(color: TekColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _reconRow('Recharge UPI Collections (Bank Inflow)', _currencyFormat.format(recon.rechargeUpiCollected), TekColors.textPrimary),
          _reconRow('Recharge Card Collections (Bank Inflow)', _currencyFormat.format(recon.rechargeCardCollected), TekColors.textPrimary),
          _reconRow('Distributor UPI Settlements (Bank Outflow)', '-${_currencyFormat.format(recon.distributorUpiPayments)}', TekColors.textMuted),
        ],
      ),
    );
  }

  Widget _buildTransactionTableSection() {
    final rep = _report!;
    final filtered = rep.transactions.where((t) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return t.rechargeId.toLowerCase().contains(q) ||
          t.customerMobile.contains(q) ||
          t.operator.displayName.toLowerCase().contains(q) ||
          t.staffName.toLowerCase().contains(q);
    }).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TekColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Detailed Transaction Log',
                style: TextStyle(
                  color: TekColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  style: const TextStyle(color: TekColors.textPrimary, fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'Search Mobile / ID...',
                    hintStyle: const TextStyle(color: TekColors.textMuted, fontSize: 12),
                    prefixIcon: const Icon(Icons.search, color: TekColors.textMuted, size: 16),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    filled: true,
                    fillColor: TekColors.sidebarBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: TekColors.border),
                    ),
                  ),
                  onChanged: (val) => setState(() => _searchQuery = val),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: Text('ഇടപാടുകൾ കണ്ടെത്തിയില്ല (No transactions found)', style: TextStyle(color: TekColors.textMuted)),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(TekColors.sidebarBg),
                columns: const [
                  DataColumn(label: Text('Txn ID', style: TextStyle(color: TekColors.textSecondary))),
                  DataColumn(label: Text('Date & Time', style: TextStyle(color: TekColors.textSecondary))),
                  DataColumn(label: Text('Operator', style: TextStyle(color: TekColors.textSecondary))),
                  DataColumn(label: Text('Mobile', style: TextStyle(color: TekColors.textSecondary))),
                  DataColumn(label: Text('Amount', style: TextStyle(color: TekColors.textSecondary))),
                  DataColumn(label: Text('Payment', style: TextStyle(color: TekColors.textSecondary))),
                  DataColumn(label: Text('Status', style: TextStyle(color: TekColors.textSecondary))),
                  DataColumn(label: Text('Staff', style: TextStyle(color: TekColors.textSecondary))),
                ],
                rows: filtered.map((t) {
                  return DataRow(
                    cells: [
                      DataCell(Text(t.rechargeId, style: const TextStyle(color: TekColors.textPrimary, fontSize: 11))),
                      DataCell(Text(DateFormat('dd/MM hh:mm a').format(t.createdAt), style: const TextStyle(color: TekColors.textMuted, fontSize: 11))),
                      DataCell(Text(t.operator.displayName, style: const TextStyle(color: TekColors.textPrimary, fontSize: 11))),
                      DataCell(Text(t.customerMobile, style: const TextStyle(color: TekColors.textPrimary, fontSize: 11))),
                      DataCell(Text(_currencyFormat.format(t.amount), style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.w700, fontSize: 11))),
                      DataCell(Text(t.paymentMode.label, style: const TextStyle(color: TekColors.textSecondary, fontSize: 11))),
                      DataCell(_buildStatusBadge(t.status)),
                      DataCell(Text(t.staffName, style: const TextStyle(color: TekColors.textMuted, fontSize: 11))),
                    ],
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(RechargeStatus status) {
    Color bg;
    Color fg;
    switch (status) {
      case RechargeStatus.success:
        bg = TekColors.success.withValues(alpha: 0.15);
        fg = TekColors.success;
        break;
      case RechargeStatus.pending:
        bg = TekColors.warning.withValues(alpha: 0.15);
        fg = TekColors.warning;
        break;
      case RechargeStatus.failed:
        bg = TekColors.error.withValues(alpha: 0.15);
        fg = TekColors.error;
        break;
      case RechargeStatus.refunded:
        bg = TekColors.premiumPurple.withValues(alpha: 0.15);
        fg = TekColors.premiumPurple;
        break;
      case RechargeStatus.disputed:
        bg = Colors.orange.withValues(alpha: 0.15);
        fg = Colors.orange;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status.name.toUpperCase(),
        style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _statPill(String label, String value, {bool highlight = false, bool isNegative = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: TekColors.sidebarBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: highlight ? TekColors.warning.withValues(alpha: 0.4) : TekColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: TekColors.textMuted, fontSize: 9.5)),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: isNegative
                  ? TekColors.error
                  : (highlight ? TekColors.warning : TekColors.textPrimary),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _reconRow(String label, String value, Color color, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: isBold ? TekColors.textPrimary : TekColors.textSecondary,
                fontSize: isBold ? 13 : 12,
                fontWeight: isBold ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: isBold ? 14 : 12,
              fontWeight: isBold ? FontWeight.w800 : FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Color _getOperatorColor(RechargeOperator op) {
    switch (op) {
      case RechargeOperator.airtel:
        return Colors.redAccent;
      case RechargeOperator.jio:
        return Colors.blueAccent;
      case RechargeOperator.vi:
        return Colors.amber;
      case RechargeOperator.bsnl:
        return Colors.orangeAccent;
      case RechargeOperator.other:
        return TekColors.electricCyan;
    }
  }
}
