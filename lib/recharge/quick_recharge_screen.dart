import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../theme/tek_tokens.dart';
import 'commission_dialogs.dart';
import 'daily_reconciliation_screen.dart';
import 'quick_recharge_dialog.dart';
import 'recharge_models.dart';
import 'recharge_reports_screen.dart';
import 'recharge_service.dart';
import 'wallet_distributor_dialogs.dart';

/// ============================================================================
/// TEKFIX ERP - QUICK RECHARGE & UTILITY ACCOUNTING DASHBOARD
/// Fully Live, Real-Time Recharge Accounting, Operator Wallets & Reconciliation
/// ============================================================================

enum RechargeOperatorBrand {
  airtel,
  jio,
  vi,
  bsnl,
  otherUtilities,
}

class QuickRechargeScreen extends StatefulWidget {
  const QuickRechargeScreen({super.key});

  @override
  State<QuickRechargeScreen> createState() => _QuickRechargeScreenState();
}

class _QuickRechargeScreenState extends State<QuickRechargeScreen> {
  RechargeFundingType _selectedFundingType =
      RechargeFundingType.distributorCredit;
  final currencyFormat = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);

  bool _isLoading = true;
  RechargeFinancialReport? _report;
  DailyReconciliationRecord? _reconciliation;
  final Map<RechargeOperator, OperatorWallet> _wallets = {};
  List<DistributorProfile> _distributors = [];
  AgentPendingReturnSummary? _pendingReturns;
  DateTime _lastUpdated = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadLiveDashboardData();
  }

  Future<void> _loadLiveDashboardData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    final auth = AuthController.instance;
    final sId = auth.shopId.isNotEmpty ? auth.shopId : 'tekfix';
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

    try {
      // 1. Generate live daily financial report (transactions, collections, commissions)
      final report = await RechargeService.instance.generateFinancialReport(
        shopId: sId,
        filter: RechargeReportFilter.today(),
      );

      // 2. Fetch today's daily operator reconciliation record
      final reconciliation = await RechargeService.instance.getOrCreateDailyReconciliation(
        shopId: sId,
        businessDate: today,
      );

      // 3. Fetch wallets for all 4 primary operators
      final walletFutures = [
        RechargeOperator.airtel,
        RechargeOperator.jio,
        RechargeOperator.vi,
        RechargeOperator.bsnl,
      ].map((op) async {
        final w = await RechargeService.instance.getWallet(shopId: sId, operator: op);
        return MapEntry(op, w);
      });
      final walletEntries = await Future.wait(walletFutures);
      _wallets.clear();
      for (final e in walletEntries) {
        _wallets[e.key] = e.value;
      }

      // 4. Fetch distributors & agent pending returns
      final dists = await RechargeService.instance.getAllDistributors(sId);
      final pendingSummary = await RechargeService.instance.getAgentPendingReturnsSummary(shopId: sId);

      if (mounted) {
        setState(() {
          _report = report;
          _reconciliation = reconciliation;
          _distributors = dists;
          _pendingReturns = pendingSummary;
          _lastUpdated = DateTime.now();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[QuickRechargeScreen] Dashboard data loading warning: $e');
      if (mounted) {
        setState(() {
          _lastUpdated = DateTime.now();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    if (!auth.isOwner) {
      return Scaffold(
        backgroundColor: TekColors.mainBg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withAlpha(40),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.lock_outline_rounded,
                    size: 48, color: Color(0xFFF59E0B)),
              ),
              const SizedBox(height: 16),
              const Text(
                'ഉടമയ്ക്ക് മാത്രമുള്ള വിവരങ്ങൾ (Owner Only Area)',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Recharge Accounting is strictly restricted to Shop Owner.',
                style: TextStyle(color: TekColors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final isDesktop = MediaQuery.of(context).size.width >= 980;

    return Scaffold(
      backgroundColor: TekColors.mainBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopAppBar(context, auth),
            if (_isLoading)
              const LinearProgressIndicator(
                color: TekColors.electricCyan,
                backgroundColor: TekColors.cardBg,
                minHeight: 2.5,
              ),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.symmetric(
                  horizontal: isDesktop ? 24 : 16,
                  vertical: 18,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildOpeningStatusBanner(),
                    _buildFundingModeSelector(),
                    const SizedBox(height: 20),
                    _buildKpiMetricsGrid(isDesktop),
                    const SizedBox(height: 26),
                    _buildSectionHeader(
                      title: 'Telecom Operator Wallets',
                      malayalam: 'ഓപ്പറേറ്റർ വാലറ്റുകൾ (Airtel, Jio, Vi, BSNL)',
                      icon: Icons.cell_tower_rounded,
                      accentColor: TekColors.electricCyan,
                    ),
                    const SizedBox(height: 12),
                    _buildOperatorCards(isDesktop, auth),
                    const SizedBox(height: 26),
                    _buildDistributorSettlementCard(isDesktop, auth),
                    const SizedBox(height: 26),
                    _buildSectionHeader(
                      title: 'Quick Operations & Management',
                      malayalam: 'മാനേജ്‌മെന്റ് ഓപ്ഷനുകൾ',
                      icon: Icons.grid_view_rounded,
                      accentColor: TekColors.premiumPurple,
                    ),
                    const SizedBox(height: 12),
                    _buildNavigationOptionsGrid(isDesktop, auth),
                    const SizedBox(height: 26),
                    _buildRecentTransactionsSection(isDesktop),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOpeningStatusBanner() {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    return FutureBuilder<bool>(
      future: RechargeService.instance.isOpeningComplete(shopId: 'tekfix', businessDate: today),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data == true) {
          return const SizedBox.shrink();
        }
        return Container(
          margin: const EdgeInsets.only(bottom: 18),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: TekColors.warning.withAlpha(20),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: TekColors.warning.withAlpha(120)),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: TekColors.warning, size: 22),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '⚠️ മോർണിംഗ് ഓപ്പണിംഗ് ബാലൻസ് അപൂർണ്ണമാണ് (Daily opening balance required for Jio, Airtel, Vi, BSNL before recharge)',
                  style: TextStyle(color: TekColors.warning, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: TekColors.warning,
                  foregroundColor: TekColors.mainBg,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () {
                  DailyReconciliationScreen.show(context, shopId: 'tekfix', initialTab: 0)
                      .then((_) => _loadLiveDashboardData());
                },
                child: const Text('Enter Opening', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 1. TOP APP BAR (HEADER + QUICK ACTIONS)
  // ---------------------------------------------------------------------------
  Widget _buildTopAppBar(BuildContext context, AuthController auth) {
    final timeStr = DateFormat('dd MMM yyyy, hh:mm a').format(_lastUpdated);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: TekColors.sidebarBg,
        border: Border(bottom: BorderSide(color: TekColors.border, width: 1.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              gradient: TekColors.cyanBlueGradient,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: TekColors.electricCyan.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: const Icon(Icons.flash_on_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text(
                      'QUICK RECHARGE',
                      style: TextStyle(
                        color: TekColors.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: TekColors.success.withValues(alpha: 0.15),
                        border: Border.all(color: TekColors.success.withValues(alpha: 0.5)),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(radius: 3, backgroundColor: TekColors.success),
                          SizedBox(width: 5),
                          Text(
                            'LIVE ACCOUNTING',
                            style: TextStyle(
                              color: TekColors.success,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Owner: ${auth.name.isNotEmpty ? auth.name : "Authorized Owner"} • $timeStr (IST)',
                  style: const TextStyle(
                    color: TekColors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          // Refresh Button
          IconButton(
            tooltip: 'Refresh Live Balances (പുതുക്കുക)',
            icon: const Icon(Icons.refresh_rounded, color: TekColors.electricCyan),
            onPressed: _loadLiveDashboardData,
          ),
          const SizedBox(width: 8),
          // Add Balance Button - Anytime
          FilledButton.icon(
            onPressed: () {
              WalletTopUpDialog.show(
                context,
                shopId: auth.shopId.isNotEmpty ? auth.shopId : 'tekfix',
                staffId: auth.uid,
                staffName: auth.name,
              ).then((res) {
                if (res == true) _loadLiveDashboardData();
              });
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.add_card_rounded, size: 17),
            label: const Text(
              'Add Balance',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 8),
          // New Quick Recharge Button
          FilledButton.icon(
            onPressed: () {
              QuickRechargeDialog.show(context, fundingType: _selectedFundingType).then((_) => _loadLiveDashboardData());
            },
            style: FilledButton.styleFrom(
              backgroundColor: TekColors.primaryBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.flash_on_rounded, size: 17),
            label: const Text(
              'New Recharge',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 2. FUNDING MODE SELECTOR
  // ---------------------------------------------------------------------------
  Widget _buildFundingModeSelector() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TekColors.border),
        boxShadow: TekColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.account_balance_wallet_rounded,
                  color: TekColors.premiumPurple, size: 20),
              SizedBox(width: 8),
              Text(
                'Active Funding Source / ഫണ്ടിംഗ് രീതി:',
                style: TextStyle(
                  color: TekColors.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 620;
              final buttons = [
                Expanded(
                  flex: isNarrow ? 0 : 1,
                  child: _buildFundingOptionTile(
                    title: 'Distributor Credit (ഡിസ്ട്രിബ്യൂട്ടർ ക്രെഡിറ്റ്)',
                    subtitle:
                        'Stock supplied on credit; settled during distributor visit.',
                    badge: 'MODE A',
                    badgeColor: TekColors.warning,
                    isSelected: _selectedFundingType ==
                        RechargeFundingType.distributorCredit,
                    onTap: () {
                      setState(() => _selectedFundingType =
                          RechargeFundingType.distributorCredit);
                    },
                  ),
                ),
                SizedBox(width: isNarrow ? 0 : 12, height: isNarrow ? 10 : 0),
                Expanded(
                  flex: isNarrow ? 0 : 1,
                  child: _buildFundingOptionTile(
                    title: 'Own Money / Prepaid (സ്വന്തം ബാങ്ക് പണം)',
                    subtitle:
                        'Direct bank/UPI transfer upfront; zero distributor liability.',
                    badge: 'MODE B',
                    badgeColor: TekColors.electricCyan,
                    isSelected: _selectedFundingType ==
                        RechargeFundingType.ownMoney,
                    onTap: () {
                      setState(() => _selectedFundingType =
                          RechargeFundingType.ownMoney);
                    },
                  ),
                ),
              ];

              return isNarrow
                  ? Column(children: buttons)
                  : Row(children: buttons);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFundingOptionTile({
    required String title,
    required String subtitle,
    required String badge,
    required Color badgeColor,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? badgeColor.withValues(alpha: 0.12)
              : TekColors.elevatedSurface.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? badgeColor : TekColors.borderSubtle,
            width: isSelected ? 1.8 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? badgeColor : TekColors.textMuted,
                  width: 2,
                ),
              ),
              child: isSelected
                  ? Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: badgeColor,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: badgeColor.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(
                            color: badgeColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: isSelected
                                ? TekColors.textPrimary
                                : TekColors.textSecondary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: TekColors.textMuted,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 3. LIVE 6-CARD SUMMARY KPI GRID
  // ---------------------------------------------------------------------------
  Widget _buildKpiMetricsGrid(bool isDesktop) {
    // 1. Total Recharge Gross (Principal - NOT business income)
    final todayRecharge = _report?.totalRechargeAmount ?? 0.0;

    // 2. Total Commission (Actual recognized business income)
    final todayCommission = (_report?.netCommissionIncomePaise ?? 0) / 100.0;

    // 3. Total Available Wallet Float across Airtel, Jio, Vi, BSNL
    final totalWalletBalance = _wallets.values.fold(0.0, (acc, w) => acc + w.totalBalance);

    // 4. Total Distributor Outstanding
    final totalDistributorDue = _distributors.fold(0.0, (acc, d) => acc + d.currentOutstanding);

    // 5. Successful Transactions Count
    final successfulCount = _report?.successfulCount ?? 0;

    // 6. Failed & Pending Transactions Count
    final failedOrPendingCount = (_report?.failedCount ?? 0) + (_report?.pendingCount ?? 0);

    final cards = [
      _buildMetricCard(
        title: "Today's Total Recharge",
        malayalam: 'ഇന്നത്തെ റീചാർജ് തുക',
        value: currencyFormat.format(todayRecharge),
        icon: Icons.payments_rounded,
        gradient: TekColors.cyanBlueGradient,
        subtext: 'Gross Turnover (Not Business Income)',
      ),
      _buildMetricCard(
        title: "Today's Commission",
        malayalam: 'ഇന്നത്തെ യഥാർത്ഥ വരുമാനം',
        value: currencyFormat.format(todayCommission),
        icon: Icons.trending_up_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFF22C55E), Color(0xFF15803D)]),
        subtext: 'Recognized Business Income',
      ),
      _buildMetricCard(
        title: 'Available Wallet Float',
        malayalam: 'ലഭ്യമായ വാലറ്റ് തുക',
        value: currencyFormat.format(totalWalletBalance),
        icon: Icons.account_balance_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFF10B981), Color(0xFF047857)]),
        subtext: 'Airtel, Jio, Vi, BSNL Float',
      ),
      _buildMetricCard(
        title: 'Distributor Outstanding',
        malayalam: 'ഡിസ്ട്രിബ്യൂട്ടർ ബാധ്യത',
        value: currencyFormat.format(totalDistributorDue),
        icon: Icons.warning_amber_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFFF59E0B), Color(0xFFB45309)]),
        subtext: 'Payable on distributor settlement',
      ),
      _buildMetricCard(
        title: 'Successful Transactions',
        malayalam: 'വിജയകരമായ ഇടപാടുകൾ',
        value: '$successfulCount Txns',
        icon: Icons.check_circle_outline_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFF38BDF8), Color(0xFF0284C7)]),
        subtext: 'Confirmed Ledger Debits',
      ),
      _buildMetricCard(
        title: 'Failed / Pending Txns',
        malayalam: 'പരാജയപ്പെട്ടവ / റീഫണ്ട്',
        value: '$failedOrPendingCount Txns',
        icon: Icons.error_outline_rounded,
        gradient: failedOrPendingCount > 0
            ? const LinearGradient(colors: [Color(0xFFEF4444), Color(0xFFB91C1C)])
            : const LinearGradient(colors: [Color(0xFF6B7280), Color(0xFF4B5563)]),
        subtext: 'Reversed or in recovery queue',
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        int cols = 3;
        if (constraints.maxWidth < 680) {
          cols = 1;
        } else if (constraints.maxWidth < 1100) {
          cols = 2;
        }

        return GridView.count(
          crossAxisCount: cols,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: isDesktop ? 2.3 : 2.1,
          children: cards,
        );
      },
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String malayalam,
    required String value,
    required IconData icon,
    required LinearGradient gradient,
    required String subtext,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TekColors.border),
        boxShadow: TekColors.cardShadow,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: gradient,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: gradient.colors.first.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: TekColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      malayalam,
                      style: const TextStyle(
                        color: TekColors.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: const TextStyle(
                      color: TekColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtext,
                  style: const TextStyle(
                    color: TekColors.textMuted,
                    fontSize: 10,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 4. OPERATOR WALLET MANAGEMENT CARDS (AIRTEL, JIO, VI, BSNL)
  // ---------------------------------------------------------------------------
  Widget _buildOperatorCards(bool isDesktop, AuthController auth) {
    final operators = [
      (
        operator: RechargeOperator.airtel,
        name: 'Bharti Airtel',
        malayalam: 'എയർടെൽ പ്രീപെയ്ഡ് & ഡിടിഎച്ച്',
        icon: Icons.network_cell_rounded,
        primaryColor: const Color(0xFFE50914),
        gradient: const LinearGradient(colors: [Color(0xFFE50914), Color(0xFF990000)]),
      ),
      (
        operator: RechargeOperator.jio,
        name: 'Reliance Jio',
        malayalam: 'ജിയോ പ്രീപെയ്ഡ് & പോസ്റ്റ്പെയ്ഡ്',
        icon: Icons.signal_cellular_alt_rounded,
        primaryColor: const Color(0xFF0070F3),
        gradient: const LinearGradient(colors: [Color(0xFF0070F3), Color(0xFF0044A8)]),
      ),
      (
        operator: RechargeOperator.vi,
        name: 'Vodafone Idea (Vi)',
        malayalam: 'വി പ്രീപെയ്ഡ് റീചാർജ്',
        icon: Icons.cell_tower_rounded,
        primaryColor: const Color(0xFFFF5252),
        gradient: const LinearGradient(colors: [Color(0xFFFF5252), Color(0xFFFFB300)]),
      ),
      (
        operator: RechargeOperator.bsnl,
        name: 'BSNL Mobile',
        malayalam: 'ബി.എസ്.എൻ.എൽ പ്രീപെയ്ഡ്',
        icon: Icons.signal_wifi_4_bar_rounded,
        primaryColor: const Color(0xFF16A34A),
        gradient: const LinearGradient(colors: [Color(0xFF16A34A), Color(0xFF0D9488)]),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        int cols = 2;
        if (constraints.maxWidth < 750) {
          cols = 1;
        } else if (constraints.maxWidth >= 1400) {
          cols = 4;
        }

        return GridView.builder(
          itemCount: operators.length,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: cols == 1 ? 1.85 : 1.32,
          ),
          itemBuilder: (context, i) {
            final opDef = operators[i];
            final op = opDef.operator;
            final wallet = _wallets[op];
            final opRecon = _reconciliation?.operators[op.name];

            final currentBalance = wallet?.totalBalance ?? 0.0;
            final openingBalance = (opRecon?.openingBalancePaise ?? 0) / 100.0;
            final addedToday = ((opRecon?.totalTopupsPaise ?? 0) + (opRecon?.totalCreditsPaise ?? 0)) / 100.0;
            final debitsToday = (opRecon?.totalDebitsPaise ?? 0) / 100.0;
            final refundsToday = ((opRecon?.totalDebitReversalsPaise ?? 0) + (opRecon?.totalCreditReversalsPaise ?? 0)) / 100.0;
            final isClosed = opRecon?.isClosingCompleted ?? false;
            final closingBalance = isClosed
                ? (opRecon!.actualClosingBalancePaise / 100.0)
                : ((opRecon?.expectedClosingBalancePaise ?? 0) / 100.0);
            final difference = (opRecon?.differencePaise ?? 0) / 100.0;

            final commEnabled = RechargeService.instance.isCommissionEnabled(op.name);
            final commPercent = RechargeService.instance.getOperatorCommissionPercent(op.name);

            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: TekColors.cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: opDef.primaryColor.withValues(alpha: 0.4), width: 1.2),
                boxShadow: TekColors.cardShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Top Title & Icon
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              gradient: opDef.gradient,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(opDef.icon, color: Colors.white, size: 20),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                opDef.name,
                                style: const TextStyle(
                                  color: TekColors.textPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                opDef.malayalam,
                                style: const TextStyle(color: TekColors.textMuted, fontSize: 10),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: commEnabled
                              ? TekColors.success.withValues(alpha: 0.15)
                              : TekColors.error.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: commEnabled ? TekColors.success : TekColors.error,
                          ),
                        ),
                        child: Text(
                          commEnabled ? '${commPercent.toStringAsFixed(1)}% COMM' : 'COMM OFF',
                          style: TextStyle(
                            color: commEnabled ? TekColors.success : TekColors.error,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Available Balance Display
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Available Balance / ലഭ്യമായ ബാലൻസ്:',
                          style: TextStyle(color: TekColors.textSecondary, fontSize: 10.5),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          currencyFormat.format(currentBalance),
                          style: TextStyle(
                            color: opDef.primaryColor,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Daily Movement Mini-Table
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: TekColors.mainBg.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: TekColors.borderSubtle),
                    ),
                    child: Column(
                      children: [
                        _buildOpDataRow('Opening Balance:', currencyFormat.format(openingBalance)),
                        _buildOpDataRow('Added Today (+):', currencyFormat.format(addedToday), valueColor: TekColors.success),
                        _buildOpDataRow('Debited Today (-):', currencyFormat.format(debitsToday), valueColor: TekColors.warning),
                        _buildOpDataRow('Refunds/Reversals:', currencyFormat.format(refundsToday)),
                        const Divider(height: 8, color: TekColors.borderSubtle),
                        _buildOpDataRow(
                          isClosed ? 'Closing Balance (Final):' : 'Expected Closing:',
                          currencyFormat.format(closingBalance),
                          valueColor: isClosed ? TekColors.electricCyan : TekColors.textPrimary,
                          isBold: true,
                        ),
                        if (isClosed && difference != 0.0)
                          _buildOpDataRow(
                            'Diff (Actual - Expected):',
                            '${difference > 0 ? "+" : ""}${currencyFormat.format(difference)}',
                            valueColor: difference >= 0 ? TekColors.success : TekColors.error,
                            isBold: true,
                          ),
                      ],
                    ),
                  ),

                  // Actions Toolbar
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      // Add Balance Button
                      FilledButton.icon(
                        onPressed: () {
                          WalletTopUpDialog.show(
                            context,
                            shopId: auth.shopId.isNotEmpty ? auth.shopId : 'tekfix',
                            staffId: auth.uid,
                            staffName: auth.name,
                            initialOperator: op,
                          ).then((res) {
                            if (res == true) _loadLiveDashboardData();
                          });
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: opDef.primaryColor.withValues(alpha: 0.2),
                          foregroundColor: opDef.primaryColor,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          side: BorderSide(color: opDef.primaryColor),
                        ),
                        icon: const Icon(Icons.add_rounded, size: 14),
                        label: const Text('Add Balance', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                      // Opening Entry Button
                      OutlinedButton.icon(
                        onPressed: () {
                          DailyReconciliationScreen.show(context, shopId: 'tekfix', initialTab: 0)
                              .then((_) => _loadLiveDashboardData());
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: TekColors.textPrimary,
                          side: const BorderSide(color: TekColors.borderSubtle),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.login_rounded, size: 13),
                        label: const Text('Opening', style: TextStyle(fontSize: 10.5)),
                      ),
                      // Closing Entry Button
                      OutlinedButton.icon(
                        onPressed: () {
                          DailyReconciliationScreen.show(context, shopId: 'tekfix', initialTab: 2)
                              .then((_) => _loadLiveDashboardData());
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: TekColors.textPrimary,
                          side: const BorderSide(color: TekColors.borderSubtle),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.logout_rounded, size: 13),
                        label: const Text('Closing', style: TextStyle(fontSize: 10.5)),
                      ),
                      // View Transactions
                      IconButton(
                        tooltip: 'View Operator Transactions',
                        icon: const Icon(Icons.history_rounded, size: 16, color: TekColors.electricCyan),
                        onPressed: () {
                          RechargeReportsScreen.show(context, shopId: auth.shopId.isNotEmpty ? auth.shopId : 'tekfix');
                        },
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildOpDataRow(String label, String value, {Color? valueColor, bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isBold ? TekColors.textPrimary : TekColors.textMuted,
              fontSize: 10.5,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? (isBold ? TekColors.textPrimary : TekColors.textSecondary),
              fontSize: 11,
              fontWeight: isBold ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 5. DISTRIBUTOR & AGENT SETTLEMENT SECTION
  // ---------------------------------------------------------------------------
  Widget _buildDistributorSettlementCard(bool isDesktop, AuthController auth) {
    final totalPayable = _distributors.fold(0.0, (acc, d) => acc + (d.openingPayablePaise / 100.0) + d.totalCreditReceived);
    final totalPaid = _distributors.fold(0.0, (acc, d) => acc + d.totalPaymentsMade);
    final totalDue = _distributors.fold(0.0, (acc, d) => acc + d.currentOutstanding);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFF59E0B).withValues(alpha: 0.4),
          width: 1.2,
        ),
        boxShadow: TekColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.handshake_rounded,
                      color: Color(0xFFF59E0B),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Distributor Settlement & Outstandings',
                        style: TextStyle(
                          color: TekColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        'ഡിസ്ട്രിബ്യൂട്ടർക്ക് നൽകാനുള്ള തുക & മുൻ പേയ്‌മെന്റുകൾ',
                        style: TextStyle(
                          color: TekColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _showAgentSettlementModal,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFF59E0B),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.handshake_rounded, size: 15),
                    label: const Text(
                      'Agent Settlement',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _showRechargeAmountReturnModal,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: TekColors.electricCyan,
                      side: const BorderSide(color: TekColors.electricCyan),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.assignment_return_rounded, size: 15),
                    label: const Text(
                      'Recharge Return',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11.5),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _showDistributorPayoutModal,
                    style: FilledButton.styleFrom(
                      backgroundColor: TekColors.elevatedSurface,
                      foregroundColor: TekColors.textPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.payment_rounded, size: 15),
                    label: const Text(
                      'Direct Pay',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 650;
              final metrics = [
                _buildSettlementStat(
                  label: 'Total Stock Received',
                  malayalam: 'ആകെ ലഭിച്ച സ്റ്റോക്ക്',
                  value: currencyFormat.format(totalPayable),
                  valueColor: TekColors.textPrimary,
                ),
                _buildSettlementStat(
                  label: 'Amount Settled / Paid',
                  malayalam: 'ഇതുവരെ നൽകിയത്',
                  value: currencyFormat.format(totalPaid),
                  valueColor: TekColors.success,
                ),
                _buildSettlementStat(
                  label: 'Remaining Outstanding',
                  malayalam: 'ഇനി നൽകാനുള്ള ബാക്കി',
                  value: currencyFormat.format(totalDue),
                  valueColor: const Color(0xFFF59E0B),
                  isAlert: true,
                ),
              ];

              return isNarrow
                  ? Column(
                      children: metrics
                          .map((m) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: m,
                              ))
                          .toList())
                  : Row(
                      children: metrics
                          .map((m) => Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6),
                                  child: m,
                                ),
                              ))
                          .toList(),
                    );
            },
          ),
          const SizedBox(height: 16),
          _buildPendingReturnBreakdownCard(),
        ],
      ),
    );
  }

  Widget _buildPendingReturnBreakdownCard() {
    final summary = _pendingReturns;
    final totalPending = summary?.totalPendingReturn ?? 0.0;
    final airtelPending = summary?.getOperatorPendingReturn(RechargeOperator.airtel) ?? 0.0;
    final jioPending = summary?.getOperatorPendingReturn(RechargeOperator.jio) ?? 0.0;
    final viPending = summary?.getOperatorPendingReturn(RechargeOperator.vi) ?? 0.0;
    final bsnlPending = summary?.getOperatorPendingReturn(RechargeOperator.bsnl) ?? 0.0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TekColors.mainBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TekColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.pending_actions_rounded, color: Color(0xFFF59E0B), size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Pending Recharge Returns from Operators / Agents (ഏജന്റിൽ നിന്ന് തിരികെ ലഭിക്കാനുള്ള തുക)',
                  style: TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFF59E0B)),
                ),
                child: Text(
                  'Total: ${currencyFormat.format(totalPending)}',
                  style: const TextStyle(
                    color: Color(0xFFF59E0B),
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 600;
              final opPills = [
                _buildOperatorPendingPill('Airtel Agent', airtelPending, const Color(0xFFE40000)),
                _buildOperatorPendingPill('Jio Agent', jioPending, const Color(0xFF0F3E99)),
                _buildOperatorPendingPill('Vi Agent', viPending, const Color(0xFFED1C24)),
                _buildOperatorPendingPill('BSNL Agent', bsnlPending, const Color(0xFF0056B3)),
              ];
              return isWide
                  ? Row(
                      children: opPills
                          .map((p) => Expanded(
                              child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  child: p)))
                          .toList())
                  : Column(
                      children: opPills
                          .map((p) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: p))
                          .toList());
            },
          ),
        ],
      ),
    );
  }

  Widget _buildOperatorPendingPill(String name, double amount, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
              const SizedBox(width: 6),
              Text(name, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
            ],
          ),
          Text(
            currencyFormat.format(amount),
            style: TextStyle(
              color: amount > 0 ? const Color(0xFFF59E0B) : TekColors.textMuted,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettlementStat({
    required String label,
    required String malayalam,
    required String value,
    required Color valueColor,
    bool isAlert = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: TekColors.elevatedSurface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isAlert ? const Color(0xFFF59E0B).withValues(alpha: 0.4) : TekColors.borderSubtle,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: TekColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 1),
          Text(malayalam, style: const TextStyle(color: TekColors.textMuted, fontSize: 9.5)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                color: valueColor,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 6. QUICK OPERATIONS NAVIGATION GRID
  // ---------------------------------------------------------------------------
  Widget _buildNavigationOptionsGrid(bool isDesktop, AuthController auth) {
    final sId = auth.shopId.isNotEmpty ? auth.shopId : 'tekfix';

    final navItems = [
      _NavItem(
        title: 'Quick Recharge',
        malayalam: 'റീചാർജ് എൻട്രി',
        icon: Icons.dialpad_rounded,
        gradient: TekColors.cyanBlueGradient,
        onTap: () {
          QuickRechargeDialog.show(context, fundingType: _selectedFundingType).then((_) => _loadLiveDashboardData());
        },
      ),
      _NavItem(
        title: 'Add Wallet Balance',
        malayalam: 'വാലറ്റ് ലോഡ് (Anytime)',
        icon: Icons.add_card_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF047857)]),
        onTap: () {
          WalletTopUpDialog.show(
            context,
            shopId: sId,
            staffId: auth.uid,
            staffName: auth.name,
          ).then((res) {
            if (res == true) _loadLiveDashboardData();
          });
        },
      ),
      _NavItem(
        title: 'Daily Reconciliation',
        malayalam: 'ഓപ്പണിംഗ് & ക്ലോസിംഗ്',
        icon: Icons.account_balance_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF06B6D4), Color(0xFF0E7490)]),
        onTap: () {
          DailyReconciliationScreen.show(context, shopId: sId)
              .then((_) => _loadLiveDashboardData());
        },
      ),
      _NavItem(
        title: 'Commission Controls',
        malayalam: 'കമ്മീഷൻ ഓൺ/ഓഫ് (Owner)',
        icon: Icons.tune_rounded,
        gradient: const LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFD97706)]),
        onTap: () {
          OperatorCommissionControlDialog.show(context, shopId: sId)
              .then((_) => _loadLiveDashboardData());
        },
      ),
      _NavItem(
        title: 'Recharge Reports & History',
        malayalam: 'റിപ്പോർട്ടുകൾ & ചരിത്രം',
        icon: Icons.analytics_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF38BDF8), Color(0xFF0369A1)]),
        onTap: () => RechargeReportsScreen.show(context, shopId: sId),
      ),
      _NavItem(
        title: 'Wallet Movement Ledger',
        malayalam: 'വാലറ്റ് ലഡ്ജർ ചരിത്രം',
        icon: Icons.account_balance_wallet_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)]),
        onTap: () => WalletLedgerSheet.show(context, shopId: sId),
      ),
      _NavItem(
        title: 'Distributor Directory & Ledger',
        malayalam: 'ഡിസ്ട്രിബ്യൂട്ടർ ലഡ്ജർ',
        icon: Icons.menu_book_rounded,
        gradient: const LinearGradient(colors: [Color(0xFFEC4899), Color(0xFFBE185D)]),
        onTap: () => DistributorLedgerSheet.show(context, shopId: sId),
      ),
      _NavItem(
        title: 'Float Recovery (Contra)',
        malayalam: 'ക്യാഷ് ബാങ്ക് ഡെപ്പോസിറ്റ്',
        icon: Icons.sync_alt_rounded,
        gradient: const LinearGradient(colors: [Color(0xFFA855F7), Color(0xFF6B21A8)]),
        onTap: () => RechargeFloatRecoveryDialog.show(
          context,
          shopId: sId,
          staffId: auth.uid,
          staffName: auth.name,
        ).then((_) => _loadLiveDashboardData()),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        int cols = 4;
        if (constraints.maxWidth < 650) {
          cols = 2;
        } else if (constraints.maxWidth < 1050) {
          cols = 3;
        }

        return GridView.builder(
          itemCount: navItems.length,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: isDesktop ? 2.1 : 1.7,
          ),
          itemBuilder: (context, i) {
            final item = navItems[i];
            return InkWell(
              onTap: item.onTap,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: TekColors.cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: TekColors.borderSubtle),
                  boxShadow: TekColors.cardShadow,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        gradient: item.gradient,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(item.icon, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            item.title,
                            style: const TextStyle(
                              color: TekColors.textPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.malayalam,
                            style: const TextStyle(
                              color: TekColors.textMuted,
                              fontSize: 10,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 7. LIVE RECENT RECHARGE TRANSACTIONS SECTION
  // ---------------------------------------------------------------------------
  Widget _buildRecentTransactionsSection(bool isDesktop) {
    final txns = _report?.transactions ?? [];

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TekColors.border),
        boxShadow: TekColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              const Row(
                children: [
                  Icon(Icons.history_rounded, color: TekColors.electricCyan, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Today\'s Recharge Transactions (ഇന്നത്തെ ഇടപാടുകൾ)',
                    style: TextStyle(
                      color: TekColors.textPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              Text(
                '${txns.length} Recorded Today',
                style: const TextStyle(
                  color: TekColors.electricCyan,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: TekColors.borderSubtle),
          const SizedBox(height: 8),

          if (txns.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  children: [
                    const Icon(Icons.receipt_long_outlined, size: 40, color: TekColors.textMuted),
                    const SizedBox(height: 10),
                    const Text(
                      'ഇന്ന് ഇതുവരെ റീചാർജ് ഇടപാടുകൾ ഒന്നും രേഖപ്പെടുത്തിയിട്ടില്ല',
                      style: TextStyle(color: TekColors.textSecondary, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'No recharge transactions recorded yet today.',
                      style: TextStyle(color: TekColors.textMuted, fontSize: 11),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () {
                        QuickRechargeDialog.show(context, fundingType: _selectedFundingType).then((_) => _loadLiveDashboardData());
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: TekColors.primaryBlue,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: const Text('New Recharge', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            )
          else
            ListView.separated(
              itemCount: txns.take(15).length,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              separatorBuilder: (_, __) => const Divider(height: 12, color: TekColors.borderSubtle),
              itemBuilder: (context, i) {
                final t = txns[i];
                final isCash = t.paymentMode == RechargePaymentMode.cash;
                final isFailed = t.status == RechargeStatus.failed;
                final isRefunded = t.status == RechargeStatus.refunded;

                Color statusColor = TekColors.success;
                if (isFailed) statusColor = TekColors.error;
                if (isRefunded) statusColor = const Color(0xFFF59E0B);
                if (t.status == RechargeStatus.pending) statusColor = TekColors.warning;

                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: CircleAvatar(
                    backgroundColor: isCash
                        ? TekColors.success.withValues(alpha: 0.15)
                        : TekColors.electricCyan.withValues(alpha: 0.15),
                    child: Icon(
                      isCash ? Icons.payments_rounded : Icons.qr_code_rounded,
                      color: isCash ? TekColors.success : TekColors.electricCyan,
                      size: 18,
                    ),
                  ),
                  title: Row(
                    children: [
                      Text(
                        '${t.operator.displayName} • ${t.customerMobile}',
                        style: const TextStyle(
                          color: TekColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: statusColor.withValues(alpha: 0.6)),
                        ),
                        child: Text(
                          t.status.name.toUpperCase(),
                          style: TextStyle(color: statusColor, fontSize: 9.5, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  subtitle: Text(
                    '${DateFormat('hh:mm a').format(t.createdAt)} • Mode: ${t.paymentMode.name.toUpperCase()} • Ref: ${t.referenceNumber.isNotEmpty ? t.referenceNumber : "N/A"}',
                    style: const TextStyle(color: TekColors.textSecondary, fontSize: 11),
                  ),
                  trailing: Text(
                    currencyFormat.format(t.amount),
                    style: const TextStyle(
                      color: TekColors.textPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // HELPER MODALS & PREVIEWS
  // ---------------------------------------------------------------------------
  Widget _buildSectionHeader({
    required String title,
    required String malayalam,
    required IconData icon,
    required Color accentColor,
  }) {
    return Row(
      children: [
        Icon(icon, color: accentColor, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: TekColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '($malayalam)',
          style: const TextStyle(
            color: TekColors.textMuted,
            fontSize: 11.5,
          ),
        ),
      ],
    );
  }

  void _showDistributorPayoutModal() {
    final auth = Provider.of<AuthController>(context, listen: false);
    DistributorPaymentDialog.show(
      context,
      shopId: auth.shopId.isNotEmpty ? auth.shopId : 'tekfix',
      staffId: auth.uid,
      staffName: auth.name,
    ).then((_) => _loadLiveDashboardData());
  }

  void _showAgentSettlementModal() {
    final auth = Provider.of<AuthController>(context, listen: false);
    AgentSettlementDialog.show(
      context,
      shopId: auth.shopId.isNotEmpty ? auth.shopId : 'tekfix',
      staffId: auth.uid,
      staffName: auth.name,
    ).then((_) => _loadLiveDashboardData());
  }

  void _showRechargeAmountReturnModal() {
    final auth = Provider.of<AuthController>(context, listen: false);
    RechargeAmountReturnDialog.show(
      context,
      shopId: auth.shopId.isNotEmpty ? auth.shopId : 'tekfix',
      staffId: auth.uid,
      staffName: auth.name,
    ).then((_) => _loadLiveDashboardData());
  }
}

class _NavItem {
  final String title;
  final String malayalam;
  final IconData icon;
  final LinearGradient gradient;
  final VoidCallback onTap;

  const _NavItem({
    required this.title,
    required this.malayalam,
    required this.icon,
    required this.gradient,
    required this.onTap,
  });
}
