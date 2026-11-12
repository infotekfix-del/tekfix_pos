import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../theme/tek_tokens.dart';
import 'commission_dialogs.dart';
import 'daily_reconciliation_screen.dart';
import 'quick_recharge_dialog.dart';
import 'recharge_reports_screen.dart';
import 'recharge_service.dart';
import 'wallet_distributor_dialogs.dart';

/// ============================================================================
/// TEKFIX ERP - QUICK RECHARGE & UTILITY ACCOUNTING DASHBOARD
/// PHASE 1: UI & Navigation Framework (Read-Only / Placeholder Mode)
/// ============================================================================

enum RechargeFundingType {
  ownPrepaidWallet,
  distributorCredit,
}

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
  RechargeOperatorBrand _selectedOperator = RechargeOperatorBrand.jio;
  final currencyFormat = NumberFormat.currency(locale: 'en_IN', symbol: '₹');

  // Placeholder Data for Phase 1 UI Showcase
  final double _todayRechargeTotal = 4850.00;
  final double _todayCashCollection = 3600.00;
  final double _todayUpiCollection = 1250.00;
  final int _totalTransactionsCount = 18;
  final double _totalDistributorOutstanding = 8450.00;
  final double _totalAvailableWalletBalance = 12800.00;

  // Distributor Settlement Summary Placeholder
  final double _distributorTotalPayable = 18450.00;
  final double _distributorAmountPaid = 10000.00;
  final double _distributorRemainingDue = 8450.00;
  final String _lastPaymentDate = '05 Nov 2026';

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
                'Recharge Accounting is restricted to Shop Owner / Admin.',
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
            _buildTopAppBar(context),
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
                      title: 'Telecom & Utility Operators',
                      malayalam: 'റീചാർജ് ഓപ്പറേറ്റർമാർ',
                      icon: Icons.cell_tower_rounded,
                      accentColor: TekColors.electricCyan,
                    ),
                    const SizedBox(height: 12),
                    _buildOperatorCards(isDesktop),
                    const SizedBox(height: 26),
                    _buildDistributorSettlementCard(isDesktop),
                    const SizedBox(height: 26),
                    _buildSectionHeader(
                      title: 'Quick Operations & Management',
                      malayalam: 'മാനേജ്‌മെന്റ് ഓപ്ഷനുകൾ',
                      icon: Icons.grid_view_rounded,
                      accentColor: TekColors.premiumPurple,
                    ),
                    const SizedBox(height: 12),
                    _buildNavigationOptionsGrid(isDesktop),
                    const SizedBox(height: 26),
                    _buildRecentTransactionsPlaceholder(isDesktop),
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
                onPressed: () => DailyReconciliationScreen.show(context, shopId: 'tekfix', initialTab: 0),
                child: const Text('Enter Opening', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 1. TOP APP BAR
  // ---------------------------------------------------------------------------
  Widget _buildTopAppBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: const BoxDecoration(
        color: TekColors.sidebarBg,
        border: Border(bottom: BorderSide(color: TekColors.border, width: 1.2)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to Dashboard',
            icon: const Icon(Icons.arrow_back_rounded,
                color: TekColors.textPrimary),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 8),
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
            child: const Icon(Icons.flash_on_rounded,
                color: Colors.white, size: 22),
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
                      'Recharge & Utility Management',
                      style: TextStyle(
                        color: TekColors.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: TekColors.electricCyan.withValues(alpha: 0.15),
                        border: Border.all(
                            color:
                                TekColors.electricCyan.withValues(alpha: 0.5)),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'PHASE 1 PREVIEW',
                        style: TextStyle(
                          color: TekColors.electricCyan,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                const Text(
                  'റീചാർജ്, യൂട്ടിലിറ്റി ബില്ലുകൾ & ഡിസ്ട്രിബ്യൂട്ടർ ലഡ്ജർ',
                  style: TextStyle(
                    color: TekColors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: TekColors.cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: TekColors.border),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(radius: 4, backgroundColor: TekColors.success),
                SizedBox(width: 8),
                Text(
                  'Live Float Active',
                  style: TextStyle(
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

  // ---------------------------------------------------------------------------
  // 2. FUNDING MODE SELECTOR (OWN PREPAID vs DISTRIBUTOR CREDIT)
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
                        RechargeFundingType.ownPrepaidWallet,
                    onTap: () {
                      setState(() => _selectedFundingType =
                          RechargeFundingType.ownPrepaidWallet);
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
  // 3. 6-CARD DASHBOARD KPI GRID
  // ---------------------------------------------------------------------------
  Widget _buildKpiMetricsGrid(bool isDesktop) {
    final cards = [
      _buildMetricCard(
        title: "Today's Recharge",
        malayalam: 'ഇന്നത്തെ റീചാർജ്',
        value: currencyFormat.format(_todayRechargeTotal),
        icon: Icons.payments_rounded,
        gradient: TekColors.cyanBlueGradient,
        subtext: 'Gross Turnover Handled',
      ),
      _buildMetricCard(
        title: 'Cash Collection',
        malayalam: 'ക്യാഷ് ലഭിച്ചത്',
        value: currencyFormat.format(_todayCashCollection),
        icon: Icons.account_balance_wallet_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFF22C55E), Color(0xFF15803D)]),
        subtext: 'In Physical Counter Drawer',
      ),
      _buildMetricCard(
        title: 'UPI Collection',
        malayalam: 'യു.പി.ഐ ലഭിച്ചത്',
        value: currencyFormat.format(_todayUpiCollection),
        icon: Icons.qr_code_scanner_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFF38BDF8), Color(0xFF0284C7)]),
        subtext: 'Direct to Bank Account',
      ),
      _buildMetricCard(
        title: 'Total Transactions',
        malayalam: 'ആകെ ഇടപാടുകൾ',
        value: '$_totalTransactionsCount Txns',
        icon: Icons.receipt_long_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFFA855F7), Color(0xFF7E22CE)]),
        subtext: '100% Success Rate Today',
      ),
      _buildMetricCard(
        title: 'Distributor Due',
        malayalam: 'ഡിസ്ട്രിബ്യൂട്ടർ ബാധ്യത',
        value: currencyFormat.format(_totalDistributorOutstanding),
        icon: Icons.warning_amber_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFFF59E0B), Color(0xFFB45309)]),
        subtext: 'Payable on next visit',
      ),
      _buildMetricCard(
        title: 'Available Float',
        malayalam: 'ലഭ്യമായ വാലറ്റ് തുക',
        value: currencyFormat.format(_totalAvailableWalletBalance),
        icon: Icons.account_balance_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFF10B981), Color(0xFF047857)]),
        subtext: 'Across all 5 operator portals',
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
  // 4. OPERATOR CARDS (AIRTEL, JIO, VI, BSNL, OTHER)
  // ---------------------------------------------------------------------------
  Widget _buildOperatorCards(bool isDesktop) {
    const operators = [
      _OperatorInfo(
        brand: RechargeOperatorBrand.jio,
        name: 'Reliance Jio',
        malayalam: 'ജിയോ പ്രീപെയ്ഡ് & പോസ്റ്റ്പെയ്ഡ്',
        icon: Icons.signal_cellular_alt_rounded,
        balance: 5200.00,
        marginText: '3.0% Commission',
        primaryColor: Color(0xFF0070F3),
        gradient: LinearGradient(
            colors: [Color(0xFF0070F3), Color(0xFF0044A8)]),
      ),
      _OperatorInfo(
        brand: RechargeOperatorBrand.airtel,
        name: 'Bharti Airtel',
        malayalam: 'എയർടെൽ പ്രീപെയ്ഡ് & ഡിടിഎച്ച്',
        icon: Icons.network_cell_rounded,
        balance: 3450.00,
        marginText: '2.5% Commission',
        primaryColor: Color(0xFFE50914),
        gradient: LinearGradient(
            colors: [Color(0xFFE50914), Color(0xFF990000)]),
      ),
      _OperatorInfo(
        brand: RechargeOperatorBrand.vi,
        name: 'Vodafone Idea (Vi)',
        malayalam: 'വി പ്രീപെയ്ഡ് റീചാർജ്',
        icon: Icons.cell_tower_rounded,
        balance: 2150.00,
        marginText: '3.5% Commission',
        primaryColor: Color(0xFFFF5252),
        gradient: LinearGradient(
            colors: [Color(0xFFFF5252), Color(0xFFFFB300)]),
      ),
      _OperatorInfo(
        brand: RechargeOperatorBrand.bsnl,
        name: 'BSNL Mobile',
        malayalam: 'ബി.എസ്.എൻ.എൽ പ്രീപെയ്ഡ്',
        icon: Icons.signal_wifi_4_bar_rounded,
        balance: 1200.00,
        marginText: '4.0% Commission',
        primaryColor: Color(0xFF16A34A),
        gradient: LinearGradient(
            colors: [Color(0xFF16A34A), Color(0xFF0D9488)]),
      ),
      _OperatorInfo(
        brand: RechargeOperatorBrand.otherUtilities,
        name: 'DTH & Utilities',
        malayalam: 'കെഎസ്ഇബി, ഡിടിഎച്ച്, ഫാസ്ടാഗ്',
        icon: Icons.bolt_rounded,
        balance: 800.00,
        marginText: '₹10 Flat Service Fee',
        primaryColor: Color(0xFF8B5CF6),
        gradient: LinearGradient(
            colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)]),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        int cols = 5;
        if (constraints.maxWidth < 650) {
          cols = 2;
        } else if (constraints.maxWidth < 1050) {
          cols = 3;
        }

        return GridView.builder(
          itemCount: operators.length,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: isDesktop ? 1.55 : 1.35,
          ),
          itemBuilder: (context, i) {
            final op = operators[i];
            final isSelected = _selectedOperator == op.brand;

            return InkWell(
              onTap: () {
                setState(() => _selectedOperator = op.brand);
                _showOperatorPreviewDialog(op);
              },
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: TekColors.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isSelected ? op.primaryColor : TekColors.border,
                    width: isSelected ? 2.0 : 1.0,
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: op.primaryColor.withValues(alpha: 0.35),
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : TekColors.cardShadow,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            gradient: op.gradient,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child:
                              Icon(op.icon, color: Colors.white, size: 18),
                        ),
                        if (isSelected)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: op.primaryColor.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'SELECTED',
                              style: TextStyle(
                                color: op.primaryColor,
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          op.name,
                          style: const TextStyle(
                            color: TekColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          currencyFormat.format(op.balance),
                          style: TextStyle(
                            color: op.primaryColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          op.marginText,
                          style: const TextStyle(
                            color: TekColors.textMuted,
                            fontSize: 9.5,
                          ),
                        ),
                      ],
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
  // 5. DISTRIBUTOR SETTLEMENT SECTION
  // ---------------------------------------------------------------------------
  Widget _buildDistributorSettlementCard(bool isDesktop) {
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
              FilledButton.icon(
                onPressed: _showDistributorPayoutModal,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFF59E0B),
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.payment_rounded, size: 16),
                label: const Text(
                  'Pay Distributor',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                ),
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
                  value: currencyFormat.format(_distributorTotalPayable),
                  valueColor: TekColors.textPrimary,
                ),
                _buildSettlementStat(
                  label: 'Amount Settled / Paid',
                  malayalam: 'ഇതുവരെ നൽകിയത്',
                  value: currencyFormat.format(_distributorAmountPaid),
                  valueColor: TekColors.success,
                ),
                _buildSettlementStat(
                  label: 'Remaining Outstanding',
                  malayalam: 'ഇനി നൽകാനുള്ള ബാക്കി',
                  value: currencyFormat.format(_distributorRemainingDue),
                  valueColor: const Color(0xFFF59E0B),
                  isAlert: true,
                ),
                _buildSettlementStat(
                  label: 'Last Payment Date',
                  malayalam: 'അവസാന പേയ്‌മെന്റ്',
                  value: _lastPaymentDate,
                  valueColor: TekColors.electricCyan,
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
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 6),
                                  child: m,
                                ),
                              ))
                          .toList(),
                    );
            },
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
          color: isAlert
              ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
              : TekColors.borderSubtle,
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
          Text(
            malayalam,
            style: const TextStyle(color: TekColors.textMuted, fontSize: 9.5),
          ),
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
  // 6. 8-OPTION NAVIGATION GRID
  // ---------------------------------------------------------------------------
  Widget _buildNavigationOptionsGrid(bool isDesktop) {
    final navItems = [
      _NavItem(
        title: 'Quick Recharge',
        malayalam: 'ക്വിക്ക് റീചാർജ് എൻട്രി',
        icon: Icons.dialpad_rounded,
        gradient: TekColors.cyanBlueGradient,
        onTap: () => QuickRechargeDialog.show(context),
      ),
      _NavItem(
        title: 'Wallet Management',
        malayalam: 'വാലറ്റ് മാനേജ്‌മെന്റ്',
        icon: Icons.account_balance_wallet_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)]),
        onTap: () => WalletLedgerSheet.show(context, shopId: 'tekfix'),
      ),
      _NavItem(
        title: 'Distributor Directory',
        malayalam: 'ഡിസ്ട്രിബ്യൂട്ടർ ലിസ്റ്റ്',
        icon: Icons.people_alt_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFFF59E0B), Color(0xFFD97706)]),
        onTap: () => _showPhasePreviewSheet('Distributor Management',
            'Distributor contact profiles, GSTINs, and credit terms.'),
      ),
      _NavItem(
        title: 'Distributor Ledger',
        malayalam: 'ഡിസ്ട്രിബ്യൂട്ടർ ലഡ്ജർ',
        icon: Icons.menu_book_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFFEC4899), Color(0xFFBE185D)]),
        onTap: () => DistributorLedgerSheet.show(context, shopId: 'tekfix'),
      ),
      _NavItem(
        title: 'Distributor Payment',
        malayalam: 'ഡിസ്ട്രിബ്യൂട്ടർ പേയ്‌മെന്റ്',
        icon: Icons.payments_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFF22C55E), Color(0xFF15803D)]),
        onTap: _showDistributorPayoutModal,
      ),
      _NavItem(
        title: 'Recharge History',
        malayalam: 'റിപ്പോർട്ടുകൾ & ചരിത്രം',
        icon: Icons.analytics_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFF38BDF8), Color(0xFF0369A1)]),
        onTap: () => RechargeReportsScreen.show(context, shopId: 'tekfix'),
      ),
      _NavItem(
        title: 'Commission Report',
        malayalam: 'കമ്മീഷൻ റിപ്പോർട്ട്',
        icon: Icons.trending_up_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFF10B981), Color(0xFF0F766E)]),
        onTap: () => CommissionReportDialog.show(context, shopId: 'tekfix'),
      ),
      _NavItem(
        title: 'Float Recovery (Contra)',
        malayalam: 'ക്യാഷ് ബാങ്ക് ഡെപ്പോസിറ്റ്',
        icon: Icons.sync_alt_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFFA855F7), Color(0xFF6B21A8)]),
        onTap: () => RechargeFloatRecoveryDialog.show(context,
            shopId: 'tekfix', staffId: 'staff', staffName: 'Staff'),
      ),
      _NavItem(
        title: 'Daily Reconciliation',
        malayalam: 'ഓപ്പണിംഗ് & ക്ലോസിംഗ്',
        icon: Icons.account_balance_rounded,
        gradient: const LinearGradient(
            colors: [Color(0xFF06B6D4), Color(0xFF0E7490)]),
        onTap: () => DailyReconciliationScreen.show(context, shopId: 'tekfix'),
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
  // 7. RECENT TRANSACTIONS PLACEHOLDER TABLE
  // ---------------------------------------------------------------------------
  Widget _buildRecentTransactionsPlaceholder(bool isDesktop) {
    const recentTxns = [
      _TxnPlaceholder(
        operator: 'Jio Prepaid',
        number: '98471 23456',
        amount: 299.00,
        mode: 'CASH',
        commission: 8.97,
        time: '10:45 AM',
        status: 'SUCCESS',
      ),
      _TxnPlaceholder(
        operator: 'Airtel Unlimited',
        number: '94470 98765',
        amount: 719.00,
        mode: 'UPI',
        commission: 17.98,
        time: '11:15 AM',
        status: 'SUCCESS',
      ),
      _TxnPlaceholder(
        operator: 'KSEB Electricity Bill',
        number: 'Consumer: 115542',
        amount: 1420.00,
        mode: 'CASH',
        commission: 10.00,
        time: '12:30 PM',
        status: 'SUCCESS',
      ),
      _TxnPlaceholder(
        operator: 'Vi Hero Unlimited',
        number: '97455 11223',
        amount: 239.00,
        mode: 'CASH',
        commission: 8.36,
        time: '02:10 PM',
        status: 'SUCCESS',
      ),
    ];

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
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent Recharge Activity (ഇന്നത്തെ ഇടപാടുകൾ)',
                style: TextStyle(
                  color: TekColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Placeholder Preview',
                style: TextStyle(
                  color: TekColors.electricCyan,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: TekColors.borderSubtle),
          const SizedBox(height: 8),
          ListView.separated(
            itemCount: recentTxns.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            separatorBuilder: (_, __) =>
                const Divider(height: 12, color: TekColors.borderSubtle),
            itemBuilder: (context, i) {
              final t = recentTxns[i];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: CircleAvatar(
                  backgroundColor: t.mode == 'CASH'
                      ? TekColors.success.withValues(alpha: 0.15)
                      : TekColors.electricCyan.withValues(alpha: 0.15),
                  child: Icon(
                    t.mode == 'CASH'
                        ? Icons.payments_rounded
                        : Icons.qr_code_rounded,
                    color: t.mode == 'CASH'
                        ? TekColors.success
                        : TekColors.electricCyan,
                    size: 18,
                  ),
                ),
                title: Text(
                  '${t.operator} • ${t.number}',
                  style: const TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  '${t.time} • Payment: ${t.mode} • Earned Commission: ${currencyFormat.format(t.commission)}',
                  style: const TextStyle(
                    color: TekColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
                trailing: Text(
                  currencyFormat.format(t.amount),
                  style: const TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 14,
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

  void _showOperatorPreviewDialog(_OperatorInfo op) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(op.icon, color: op.primaryColor),
            const SizedBox(width: 10),
            Text(op.name,
                style: const TextStyle(color: TekColors.textPrimary)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Malayalam: ${op.malayalam}',
                style: const TextStyle(
                    color: TekColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 8),
            Text('Available Wallet Balance: ${currencyFormat.format(op.balance)}',
                style: TextStyle(
                    color: op.primaryColor,
                    fontSize: 15,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Margin / Commission: ${op.marginText}',
                style: const TextStyle(
                    color: TekColors.textMuted, fontSize: 12)),
            const SizedBox(height: 14),
            const Text(
              'Phase 2 will activate the numeric recharge keypad and live operator plan lookup.',
              style: TextStyle(
                  color: TekColors.electricCyan, fontSize: 11.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close',
                style: TextStyle(color: TekColors.textSecondary)),
          ),
        ],
      ),
    );
  }

  void _showDistributorPayoutModal() {
    DistributorPaymentDialog.show(
      context,
      shopId: 'tekfix',
      staffId: 'staff_1',
      staffName: 'Staff',
    );
  }

  void _showPhasePreviewSheet(String title, String description) {
    showModalBottomSheet(
      context: context,
      backgroundColor: TekColors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: TekColors.premiumPurple.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'PHASE PREVIEW',
                    style: TextStyle(
                      color: TekColors.premiumPurple,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              description,
              style: const TextStyle(
                color: TekColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx),
                style: FilledButton.styleFrom(
                  backgroundColor: TekColors.primaryBlue,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Got it'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// INTERNAL PLACEHOLDER MODELS FOR PHASE 1 UI
// -----------------------------------------------------------------------------
class _OperatorInfo {
  final RechargeOperatorBrand brand;
  final String name;
  final String malayalam;
  final IconData icon;
  final double balance;
  final String marginText;
  final Color primaryColor;
  final LinearGradient gradient;

  const _OperatorInfo({
    required this.brand,
    required this.name,
    required this.malayalam,
    required this.icon,
    required this.balance,
    required this.marginText,
    required this.primaryColor,
    required this.gradient,
  });
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

class _TxnPlaceholder {
  final String operator;
  final String number;
  final double amount;
  final String mode;
  final double commission;
  final String time;
  final String status;

  const _TxnPlaceholder({
    required this.operator,
    required this.number,
    required this.amount,
    required this.mode,
    required this.commission,
    required this.time,
    required this.status,
  });
}

