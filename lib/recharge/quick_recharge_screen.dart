import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db, toast;
import '../theme/tek_tokens.dart';
import 'commission_dialogs.dart';
import 'daily_reconciliation_screen.dart';
import 'recharge_reset_point.dart';
import 'quick_recharge_dialog.dart';
import 'recharge_accounting_backend.dart';
import 'recharge_accounting_service.dart';
import 'recharge_period_accounting.dart';
import 'recharge_edit_dialog.dart';
import 'recharge_period_widgets.dart';
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
  // One balance per operator (petty-cash style): every recharge uses the
  // operator wallet's own balance; no Mode A / Mode B choice is shown.
  // Distributor dues are tracked separately in the settlement table.
  static const bool _showFundingModeSelector = false;
  RechargeFundingType _selectedFundingType = RechargeFundingType.ownMoney;
  final currencyFormat = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);

  bool _isLoading = true;
  RechargeFinancialReport? _report;
  DailyReconciliationRecord? _reconciliation;
  final Map<RechargeOperator, OperatorWallet> _wallets = {};
  List<DistributorProfile> _distributors = [];
  AgentPendingReturnSummary? _pendingReturns;
  DateTime _lastUpdated = DateTime.now();

  // Period reconciliation & operator-wise settlement (server-authoritative)
  Map<RechargeOperator, OperatorPeriodState>? _period;
  String? _periodError;
  SettlementSummary? _settlement;
  String? _settlementError;
  ExcessSummary? _excess; // separate Excess account (morning + closing)
  TopUpCommissionSummary? _topUpCommission; // distributor refill commission (profit)
  final Set<RechargeOperator> _closedOperatorsToday = {};

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
      // 0. Always re-read wallets from the server and load saved recharges from local storage
      RechargeService.instance.invalidateWalletCache(shopId: sId);
      RechargeResetStore.current(sId); // owner's last reset, if any
      await RechargeService.instance.rehydrateFromHive(defaultShopId: sId);
      RechargeService.instance.applyResetPointToLocalCache(shopId: sId);

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

      // 5. Period state & operator-wise settlement (read-only server calls)
      Map<RechargeOperator, OperatorPeriodState>? period;
      String? periodError;
      SettlementSummary? settlement;
      String? settlementError;
      ExcessSummary? excess;
      TopUpCommissionSummary? topUpCommission;
      // No default-shop fallback for accounting: the real shop id is required.
      final accShop = auth.shopId;
      if (accShop.isEmpty) {
        periodError = settlementError = 'Shop not selected (ഷോപ്പ് ഇല്ല)';
      } else {
        try {
          period = await RechargeAccountingService.instance.periodState(accShop);
        } catch (e) {
          periodError = accountingErrorText(e);
        }
        try {
          settlement = await RechargeAccountingService.instance.settlement(accShop);
        } catch (e) {
          settlementError = accountingErrorText(e);
        }
        try {
          excess = await RechargeAccountingService.instance.excessSummary(accShop);
        } catch (_) {
          excess = null; // card shows "—" until the server route is deployed
        }
        try {
          topUpCommission = await RechargeAccountingService.instance.topUpCommissionSummary(accShop);
        } catch (_) {
          topUpCommission = null;
        }
      }

      if (mounted) {
        setState(() {
          _report = report;
          _reconciliation = reconciliation;
          _distributors = dists;
          _pendingReturns = pendingSummary;
          _period = period;
          _periodError = periodError;
          _settlement = settlement;
          _settlementError = settlementError;
          _excess = excess;
          _topUpCommission = topUpCommission;
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
                    if (_showFundingModeSelector) ...[
                      _buildFundingModeSelector(),
                      const SizedBox(height: 20),
                    ],
                    _buildKpiMetricsGrid(isDesktop),
                    const SizedBox(height: 26),
                    _buildSectionHeader(
                      title: 'Telecom Operator Wallets',
                      malayalam: 'ഓപ്പറേറ്റർ വാലറ്റുകൾ (Airtel, Jio, Vi, BSNL)',
                      icon: Icons.cell_tower_rounded,
                      accentColor: TekColors.electricCyan,
                    ),
                    const SizedBox(height: 12),
                    if (_periodError != null) ...[
                      _buildPeriodUnavailableNotice(_periodError!),
                      const SizedBox(height: 12),
                    ],
                    _buildOperatorCards(isDesktop, auth),
                    const SizedBox(height: 26),
                    OperatorRechargeBreakdown(shopId: auth.shopId),
                    const SizedBox(height: 26),
                    DistributorSettlementTable(
                      summary: _settlement,
                      error: _friendlySettlementError,
                      onPay: _openDistributorPayment,
                      onClearOld: _clearOldDues,
                      onOpeningDues: _openingDues,
                    ),
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

  String? get _friendlySettlementError {
    final e = _settlementError;
    if (e == null) return null;
    return e.contains('Unknown endpoint')
        ? 'Server update not deployed yet (സെർവർ അപ്ഡേറ്റ് ആയിട്ടില്ല)'
        : e;
  }

  /// Shown once (not per card) when period data cannot be loaded.
  Widget _buildPeriodUnavailableNotice(String error) {
    final notDeployed = error.contains('Unknown endpoint');
    return Container(
      key: const ValueKey('period-unavailable-notice'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: kPeriodOrange.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kPeriodOrange.withAlpha(110)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: kPeriodOrange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              notDeployed
                  ? 'Morning / closing and distributor settlement need the new server update, which is not deployed yet. Old daily figures are shown below. (സെർവർ അപ്ഡേറ്റ് ആയിട്ടില്ല)'
                  : 'Period data unavailable: $error',
              style: const TextStyle(color: kPeriodOrange, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// Period workflow banner: operators whose morning balance is not entered
  /// (or whose previous verified closing is missing) for the open period.
  Widget _buildPeriodMorningBanner(Map<RechargeOperator, OperatorPeriodState> period) {
    final missing = [
      for (final op in kPeriodOperators)
        if (period[op] != null && (period[op]!.previousClosing == null || period[op]!.morning == null)) op,
    ];
    if (missing.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('period-morning-banner'),
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: kPeriodOrange.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kPeriodOrange.withAlpha(120)),
      ),
      child: Row(
        children: [
          const Icon(Icons.wb_sunny_rounded, color: kPeriodOrange, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'രാവിലെ ബാലൻസ് ബാക്കി (Morning balance not entered): ${missing.map(operatorShortName).join(', ')}',
              style: const TextStyle(color: kPeriodOrange, fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: kPeriodOrange,
              foregroundColor: TekColors.mainBg,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => _openMorning(missing.first),
            child: Text('Enter ${operatorShortName(missing.first)}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildOpeningStatusBanner() {
    final period = _period;
    if (period != null) return _buildPeriodMorningBanner(period);
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
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
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
          const SizedBox(width: 12),
          // Buttons wrap onto a second line on smaller windows instead of
          // squeezing the title (no overflow stripe).
          Flexible(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
              // Refresh Button
              IconButton(
                tooltip: 'Refresh Live Balances (പുതുക്കുക)',
                icon: const Icon(Icons.refresh_rounded, color: TekColors.electricCyan),
                onPressed: _loadLiveDashboardData,
              ),
              if (auth.isOwner) ...[
                OutlinedButton.icon(
                  key: const ValueKey('qr-reset-start-new'),
                  onPressed: () => _confirmAndResetQuickRecharge(context, auth),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: TekColors.warning,
                    side: const BorderSide(color: TekColors.warning),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.restart_alt_rounded, size: 17),
                  label: const Text('പുതിയ തുടക്കം (Reset)',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                ),
              ],
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
          ),
        ],
      ),
    );
  }

  /// Owner password (admin_pass) or, when one was set, the owner PIN.
  static bool _ownerSecretMatches(String entered) {
    if (entered.isEmpty) return false;
    if (entered == Db.setting('admin_pass', 'admin123')) return true;
    final pin = Db.setting('owner_pin', '');
    return pin.isNotEmpty && entered == pin;
  }

  /// "Reset / start new": everything the owner pays or counts restarts from
  /// ₹0. Nothing is deleted; see recharge_reset_point.dart.
  Future<void> _confirmAndResetQuickRecharge(
      BuildContext context, AuthController auth) async {
    final shop = auth.shopId;
    if (shop.isEmpty) {
      toast(context, 'ഷോപ്പ് തിരഞ്ഞെടുത്തിട്ടില്ല (Shop not selected)');
      return;
    }
    final pwCtrl = TextEditingController();
    String? err;
    void submit(BuildContext ctx, void Function(void Function()) setD) {
      if (_ownerSecretMatches(pwCtrl.text.trim())) {
        Navigator.pop(ctx, true);
      } else {
        setD(() => err = 'പാസ്‌വേഡ് തെറ്റാണ് (Wrong password)');
      }
    }

    Widget line(IconData i, Color c, String t) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 16, color: c),
            const SizedBox(width: 8),
            Expanded(child: Text(t, style: const TextStyle(fontSize: 12.5, color: Colors.white70))),
          ]),
        );

    final verified = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: TekColors.cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.restart_alt_rounded, color: TekColors.warning, size: 22),
              SizedBox(width: 8),
              Expanded(
                child: Text('ക്വിക്ക് റീചാർജ് പുതിയതായി തുടങ്ങുക',
                    style: TextStyle(fontSize: 15, color: Colors.white)),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('ഇത് അമർത്തിയാൽ ഇപ്പോൾ മുതൽ എല്ലാം ₹0 ൽ നിന്ന് വീണ്ടും തുടങ്ങും:',
                    style: TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                line(Icons.check_circle_rounded, TekColors.success,
                    'ഷോപ്പിൽ നിന്നും എയർടെൽ, ജിയോ, വിഐ, ബിഎസ്എൻഎൽ ആളുകൾക്ക് കൊടുക്കാനുള്ള പേയ്മെൻ്റ് എല്ലാം ₹0'),
                line(Icons.check_circle_rounded, TekColors.success,
                    'അവർക്ക് കൊടുത്ത പേയ്മെൻ്റും അഡ്വാൻസും ₹0'),
                line(Icons.check_circle_rounded, TekColors.success,
                    'ഇതുവരെയുള്ള റീചാർജ് തുക, കമ്മീഷൻ, എക്സസ് എല്ലാം ₹0'),
                line(Icons.info_outline_rounded, TekColors.electricCyan,
                    'ഓപ്പറേറ്റർ ആപ്പിലുള്ള വാലറ്റ് ബാലൻസ് മാറില്ല (അത് ശരിക്കുമുള്ള പണം ആണ്). തെറ്റുണ്ടെങ്കിൽ "Align wallet" / Closing വഴി ശരിയാക്കുക.'),
                line(Icons.info_outline_rounded, TekColors.electricCyan,
                    'പഴയ കണക്കുകൾ ഡിലീറ്റ് ആവില്ല, പഴയ റിപ്പോർട്ടിൽ ഉണ്ടാകും. ഇനിയും ബാക്കി ഉണ്ടെങ്കിൽ "Opening dues" വഴി ചേർക്കാം.'),
                const SizedBox(height: 10),
                const Text('തുടരാൻ Owner Password / PIN നൽകുക:',
                    style: TextStyle(fontSize: 12.5, color: Colors.white70)),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('qr-reset-password'),
                  controller: pwCtrl,
                  obscureText: true,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Password / PIN',
                    labelStyle: const TextStyle(color: Colors.white70),
                    errorText: err,
                    filled: true,
                    fillColor: const Color(0x26000000),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => submit(ctx, setD),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('വേണ്ട (Cancel)'),
            ),
            FilledButton.icon(
              key: const ValueKey('qr-reset-confirm'),
              style: FilledButton.styleFrom(backgroundColor: TekColors.error),
              onPressed: () => submit(ctx, setD),
              icon: const Icon(Icons.restart_alt_rounded, size: 16),
              label: const Text('എല്ലാം ₹0 ആക്കുക (Reset)'),
            ),
          ],
        ),
      ),
    );
    if (verified != true || !mounted) return;

    setState(() => _isLoading = true);
    try {
      // The dues as the server holds them now become the zero line.
      final raw = await RechargeAccountingService.instance.rawSettlement(shop);
      await RechargeResetStore.save(
          shop, RechargeResetPoint.fromSettlement(raw, DateTime.now().toUtc()));
      RechargeService.instance.applyResetPointToLocalCache(shopId: shop);
      await Db.logAction(
          action: 'QUICK_RECHARGE_RESET',
          entity: 'recharge',
          entityId: shop,
          reason: 'Owner started a new recharge account (dues and totals from ₹0)',
          user: auth.name);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        toast(this.context,
            'റീസെറ്റ് നടന്നില്ല — ഇൻ്റർനെറ്റ് നോക്കി വീണ്ടും ശ്രമിക്കുക. (${accountingErrorText(e)})');
      }
      return;
    }
    await _loadLiveDashboardData();
    if (mounted) {
      toast(this.context, 'ക്വിക്ക് റീചാർജ് ₹0 ൽ നിന്ന് പുതിയതായി തുടങ്ങി.');
    }
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
  // 3. LIVE SUMMARY KPI GRID (volume, wallet, settlement, commission)
  // ---------------------------------------------------------------------------
  Widget _buildKpiMetricsGrid(bool isDesktop) {
    final shop = AuthController.instance.shopId;
    final acc = RechargeAccountingService.instance;

    // A. Recharge volume (face value of successful recharges, IST dates)
    final today = acc.volume(shop, istRangeFor(RechargePeriodFilter.today));
    final cumulative = acc.volume(shop, istRangeFor(RechargePeriodFilter.allTime));

    // B. Operator wallet balance from the fresh start: verified openings plus
    //    the new ledger. Falls back to the old live wallets only when period
    //    data cannot be loaded.
    final period = _period;
    final freshWalletPaise = period?.values
        .where((st) => st.previousClosing != null)
        .fold<int>(0, (a, st) => a + st.closing().expectedClosingPaise);
    final walletPaise = freshWalletPaise ??
        _wallets.values.fold<int>(0, (a, w) => a + w.totalBalancePaise);
    final openingPaise =
        period?.values.fold<int>(0, (a, st) => a + (st.previousClosing?.actualPaise ?? 0));

    // C. Distributor settlement (operator-wise, never netted)
    final st = _settlement;

    final todayCommission = _report?.netCommissionIncomePaise ?? 0;
    final successfulCount = _report?.successfulCount ?? 0;
    final failedOrPendingCount = (_report?.failedCount ?? 0) + (_report?.pendingCount ?? 0);

    final cards = [
      _buildMetricCard(
        title: "Today's Total Recharge",
        malayalam: 'ഇന്നത്തെ റീചാർജ് തുക',
        value: formatInrPaise(today.grossPaise),
        icon: Icons.payments_rounded,
        gradient: TekColors.cyanBlueGradient,
        subtext: 'Refunds ${formatInrPaise(today.refundsPaise)} • Net ${formatInrPaise(today.netPaise)}',
      ),
      _buildMetricCard(
        title: 'Cumulative Total Recharge',
        malayalam: 'ഇതുവരെയുള്ള ആകെ റീചാർജ്',
        value: formatInrPaise(cumulative.grossPaise),
        icon: Icons.all_inclusive_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF4F46E5)]),
        subtext: 'Since $rechargeFreshStartLabel • Net ${formatInrPaise(cumulative.netPaise)}',
      ),
      _buildMetricCard(
        title: 'Total Operator Wallet Balance',
        malayalam: 'ഓപ്പറേറ്റർ വാലറ്റ് ആകെ',
        value: formatInrPaise(walletPaise),
        icon: Icons.account_balance_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF047857)]),
        subtext: openingPaise == null
            ? 'Live: Airtel + Jio + Vi + BSNL'
            : 'From new start • Openings ${formatInrPaise(openingPaise)}',
      ),
      _buildMetricCard(
        title: 'Distributor Outstanding',
        malayalam: 'ഡിസ്ട്രിബ്യൂട്ടർക്ക് നൽകാനുള്ളത്',
        value: st == null ? '—' : formatInrPaise(st.outstandingPaise),
        icon: Icons.warning_amber_rounded,
        gradient: const LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFB45309)]),
        subtext: st == null ? (_friendlySettlementError ?? 'Loading…') : 'Operator-wise, not netted',
      ),
      _buildMetricCard(
        title: 'Distributor Advance / Excess',
        malayalam: 'മുൻകൂർ / അധികം നൽകിയത്',
        value: st == null ? '—' : formatInrPaise(st.advancePaise),
        icon: Icons.savings_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF60A5FA), Color(0xFF2563EB)]),
        subtext: st == null ? (_friendlySettlementError ?? 'Loading…') : 'Net position ${formatInrPaise(st.netPositionPaise)} (info)',
      ),
      _buildMetricCard(
        title: 'Top-up Commission (Profit)',
        malayalam: 'ടോപ്പ്-അപ്പ് കമ്മീഷൻ (ലാഭം)',
        value: _topUpCommission == null
            ? '—'
            : formatInrPaise(_topUpCommission!.inRange(istRangeFor(RechargePeriodFilter.today))),
        icon: Icons.percent_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF22C55E), Color(0xFF15803D)]),
        subtext: _topUpCommission == null
            ? 'Not loaded'
            : 'Today • Total ${formatInrPaise(_topUpCommission!.totalPaise)} (₹39 per ₹1,000 refill)',
      ),
      _buildMetricCard(
        title: 'Recharge Excess',
        malayalam: 'എക്സസ് (പ്രത്യേക കണക്ക്)',
        value: _excess == null ? '—' : formatInrPaise(_excess!.totalPaise),
        icon: Icons.add_card_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF14B8A6), Color(0xFF0F766E)]),
        subtext: _excess == null
            ? 'Not loaded'
            : 'Morning ${formatInrPaise(_excess!.bySource(ExcessSource.morning))} • Closing ${formatInrPaise(_excess!.bySource(ExcessSource.closing))} • not profit',
      ),
      if (kRechargeCommissionInEntry)
        _buildMetricCard(
          title: "Today's Commission",
          malayalam: 'ഇന്നത്തെ യഥാർത്ഥ വരുമാനം',
          value: formatInrPaise(todayCommission),
          icon: Icons.trending_up_rounded,
          gradient: const LinearGradient(
              colors: [Color(0xFF22C55E), Color(0xFF15803D)]),
          subtext: 'Recognized Business Income',
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
        int cols = 4;
        if (constraints.maxWidth < 680) {
          cols = 1;
        } else if (constraints.maxWidth < 1100) {
          cols = 2;
        } else if (constraints.maxWidth < 1400) {
          cols = 3;
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
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        malayalam,
                        style: const TextStyle(
                          color: TekColors.textMuted,
                          fontSize: 10,
                        ),
                        overflow: TextOverflow.ellipsis,
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

        // Cards size to their content (no fixed aspect ratio), so extra
        // period rows or notices can never overflow the card.
        final itemWidth = (constraints.maxWidth - 14 * (cols - 1)) / cols - 0.5;
        Widget cardFor(int i) {
            final opDef = operators[i];
            final op = opDef.operator;
            final wallet = _wallets[op];
            final opRecon = _reconciliation?.operators[op.name];

            // From the fresh start: the balance follows the verified opening
            // and the new ledger (not the old system wallet figure).
            final freshBalancePaise = _period?[op]?.previousClosing == null
                ? null
                : _period![op]!.closing().expectedClosingPaise;
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

            // Period figures (server-authoritative period state)
            final pst = _period?[op];
            final pClosing = pst?.closing();
            final pMorning = pst?.morning;
            final isMorningDone = (pst != null && pst.morning != null) ||
                (pst == null && (opRecon?.openingBalancePaise ?? 0) > 0);
            final prevClosing = pst?.previousClosing;
            final isClosingDone = _closedOperatorsToday.contains(op) ||
                isClosed ||
                (prevClosing != null &&
                    prevClosing.at.toLocal().year == DateTime.now().year &&
                    prevClosing.at.toLocal().month == DateTime.now().month &&
                    prevClosing.at.toLocal().day == DateTime.now().day &&
                    pst!.movements.isEmpty &&
                    isMorningDone);
            final todayOpPaise = RechargeAccountingService.instance
                .volume(AuthController.instance.shopId, istRangeFor(RechargePeriodFilter.today))
                .of(op)
                .grossPaise;

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
                      // Commission is not used by this shop: chip hidden.
                      if (kRechargeCommissionInEntry)
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
                          freshBalancePaise != null
                              ? formatInrPaise(freshBalancePaise)
                              : (_period != null ? '—' : currencyFormat.format(currentBalance)),
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
                    child: pst == null
                        ? Column(
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
                          )
                        : Column(
                            children: [
                              Align(
                                alignment: Alignment.centerLeft,
                                child: PeriodStatusChip(
                                  pst.previousClosing == null
                                      ? MorningStatus.previousClosingMissing.label
                                      : (pMorning?.status ?? MorningStatus.notEntered).label,
                                  pst.previousClosing == null
                                      ? kPeriodRed
                                      : morningStatusColor(pMorning?.status ?? MorningStatus.notEntered),
                                ),
                              ),
                              const SizedBox(height: 4),
                              _buildOpDataRow('Opening (prev. verified closing):',
                                  pst.previousClosing == null ? 'Missing' : formatInrPaise(pClosing!.openingPaise),
                                  valueColor: pst.previousClosing == null ? TekColors.error : null),
                              _buildOpDataRow('Morning balance:',
                                  pMorning == null ? 'Not entered' : formatInrPaise(pMorning.morningActualPaise)),
                              _buildOpDataRow('Net top-up (confirmed):',
                                  pMorning == null ? '-' : formatInrPaise(pMorning.classifiedPaise),
                                  valueColor: TekColors.success),
                              _buildOpDataRow("Today's recharge:", formatInrPaise(todayOpPaise),
                                  valueColor: TekColors.warning),
                              const Divider(height: 8, color: TekColors.borderSubtle),
                              // No verified opening yet: nothing can be expected.
                              _buildOpDataRow('Expected closing:',
                                  pst.previousClosing == null
                                      ? '—'
                                      : formatInrPaise(pClosing!.expectedClosingPaise),
                                  isBold: true),
                              if (pClosing!.pendingDebitsPaise != 0)
                                _buildOpDataRow('Pending (debited):', formatInrPaise(pClosing.pendingDebitsPaise),
                                    valueColor: kPeriodOrange),
                              _buildOpDataRow('Actual closing / variance:', 'At night closing',
                                  valueColor: TekColors.textMuted),
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
                      // Morning Entry Button (period workflow)
                      isMorningDone
                          ? FilledButton.icon(
                              key: ValueKey('op-morning-${op.name}'),
                              onPressed: null,
                              style: FilledButton.styleFrom(
                                disabledBackgroundColor:
                                    TekColors.success.withValues(alpha: 0.15),
                                disabledForegroundColor: TekColors.success,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: BorderSide(
                                      color: TekColors.success
                                          .withValues(alpha: 0.4)),
                                ),
                              ),
                              icon: const Icon(Icons.check_circle_rounded,
                                  size: 13, color: TekColors.success),
                              label: const Text('Morning ✓',
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                      color: TekColors.success)),
                            )
                          : OutlinedButton.icon(
                              key: ValueKey('op-morning-${op.name}'),
                              onPressed: () => _openMorning(op),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: kPeriodOrange,
                                side: const BorderSide(color: kPeriodOrange),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              icon: const Icon(Icons.wb_sunny_rounded, size: 13),
                              label: Text(
                                  pst != null && pst.previousClosing == null
                                      ? 'Reference'
                                      : 'Morning',
                                  style: const TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold)),
                            ),
                      // Fresh start: system wallet differs from the verified balance
                      if (freshBalancePaise != null &&
                          wallet != null &&
                          wallet.totalBalancePaise != freshBalancePaise)
                        FilledButton.icon(
                          key: ValueKey('op-align-${op.name}'),
                          onPressed: () => _alignWallet(op),
                          style: FilledButton.styleFrom(
                            backgroundColor: kPeriodOrange,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.sync_alt_rounded, size: 13),
                          label: const Text('Align wallet', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold)),
                        ),
                      // Night Closing Button (period workflow)
                      isClosingDone
                          ? FilledButton.icon(
                              key: ValueKey('op-closing-${op.name}'),
                              onPressed: null,
                              style: FilledButton.styleFrom(
                                disabledBackgroundColor:
                                    TekColors.success.withValues(alpha: 0.15),
                                disabledForegroundColor: TekColors.success,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: BorderSide(
                                      color: TekColors.success
                                          .withValues(alpha: 0.4)),
                                ),
                              ),
                              icon: const Icon(Icons.check_circle_rounded,
                                  size: 13, color: TekColors.success),
                              label: const Text('Closing ✓',
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                      color: TekColors.success)),
                            )
                          : OutlinedButton.icon(
                              key: ValueKey('op-closing-${op.name}'),
                              onPressed: () => _openClosing(op),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: TekColors.electricCyan,
                                side: const BorderSide(
                                    color: TekColors.electricCyan),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              icon: const Icon(Icons.logout_rounded, size: 13),
                              label: const Text('Closing',
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold)),
                            ),
                      // Fix a top-up saved as own money that came from a distributor
                      IconButton(
                        key: ValueKey('op-reclass-${op.name}'),
                        tooltip: 'Change top-up source: Own → Distributor (സോഴ്സ് മാറ്റുക)',
                        icon: const Icon(Icons.swap_horiz_rounded, size: 16, color: kPeriodOrange),
                        onPressed: () => _openReclassify(op),
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
        }

        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (var i = 0; i < operators.length; i++)
              SizedBox(width: itemWidth, child: cardFor(i)),
          ],
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
    // Totals now live in the operator-wise Distributor Settlement table above.

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
                final isCorrected = t.status == RechargeStatus.corrected;
                if (isCorrected) statusColor = TekColors.textMuted;

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
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        currencyFormat.format(t.amount),
                        style: TextStyle(
                          color: isCorrected ? TekColors.textMuted : TekColors.textPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          decoration: isCorrected ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      if (t.status == RechargeStatus.success)
                        IconButton(
                          key: ValueKey('edit-recharge-${t.rechargeId}'),
                          tooltip: 'Edit (തിരുത്തുക)',
                          icon: const Icon(Icons.edit_rounded, size: 18, color: TekColors.electricCyan),
                          onPressed: () => _editRecharge(t),
                        ),
                      if (t.status == RechargeStatus.pending)
                        IconButton(
                          key: ValueKey('cancel-recharge-${t.rechargeId}'),
                          tooltip: 'Wrong entry - cancel (തെറ്റായ എൻട്രി റദ്ദാക്കുക)',
                          icon: const Icon(Icons.undo_rounded, size: 18, color: TekColors.error),
                          onPressed: () => _cancelWrongRecharge(t),
                        ),
                    ],
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

  // ---------------------------------------------------------------------------
  // PERIOD RECONCILIATION & OPERATOR-WISE SETTLEMENT ACTIONS (owner, online)
  // ---------------------------------------------------------------------------
  AccountingActor get _actor {
    final a = AuthController.instance;
    return AccountingActor(uid: a.uid, name: a.name, isOwner: a.isOwner);
  }

  bool _accountingReady() {
    final shop = AuthController.instance.shopId;
    if (shop.isEmpty || _period == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(_periodError ?? 'Period data is still loading (കാത്തിരിക്കുക)'),
        behavior: SnackBarBehavior.floating,
      ));
      return false;
    }
    return true;
  }

  Future<void> _openMorning(RechargeOperator op) async {
    if (!_accountingReady()) return;
    final st = _period![op]!;
    final shop = AuthController.instance.shopId;
    final changed = st.previousClosing == null
        ? await ReferenceBalanceDialog.show(context, shopId: shop, actor: _actor, operator: op)
        : await MorningEntryDialog.show(context,
            shopId: shop, actor: _actor, state: st, distributors: _distributors);
    if (changed == true) _loadLiveDashboardData();
  }

  Future<void> _openReclassify(RechargeOperator op) async {
    if (!_accountingReady()) return;
    final shop = AuthController.instance.shopId;
    final changed = await ReclassifyTopUpDialog.show(context,
        shopId: shop, actor: _actor, operator: op, distributors: _distributors);
    if (changed == true) _loadLiveDashboardData();
  }

  Future<void> _openClosing(RechargeOperator op) async {
    if (!_accountingReady()) return;
    final st = _period![op]!;
    final shop = AuthController.instance.shopId;
    final changed = st.previousClosing == null
        ? await ReferenceBalanceDialog.show(context, shopId: shop, actor: _actor, operator: op)
        : await ClosingEntryDialog.show(context, shopId: shop, actor: _actor, state: st);
    if (changed == true) {
      if (mounted) {
        setState(() {
          _closedOperatorsToday.add(op);
        });
      }
      _loadLiveDashboardData();
    }
  }

  Future<void> _openDistributorPayment([SettlementAccount? account]) async {
    final shop = AuthController.instance.shopId;
    if (shop.isEmpty) return;
    final ok = await DistributorPaymentV2Dialog.show(
      context,
      shopId: shop,
      actor: _actor,
      distributors: _distributors,
      summary: _settlement,
      initialDistributorId: account?.distributorId,
      initialOperator: account == null || account.operator == RechargeOperator.other
          ? null
          : account.operator,
    );
    if (ok == true) _loadLiveDashboardData();
  }

  /// Fresh start: records (on the server, with a reason) that an account's old
  /// dues were settled outside the system. A credit reversal: no cash, wallet
  /// or recharge figure changes; the entry stays in the audit trail.
  Future<void> _clearOldDues(SettlementAccount a) async {
    final shop = AuthController.instance.shopId;
    if (shop.isEmpty || a.outstandingPaise <= 0 || a.operator == RechargeOperator.other) return;
    const reason =
        'Old dues settled outside the system before fresh start ($kRechargeFreshStartIstDate)';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.cardBg,
        title: Text('Clear old dues – ${a.distributorName}',
            style: const TextStyle(color: TekColors.textPrimary, fontSize: 16)),
        content: Text(
          '${operatorShortName(a.operator)}: ${formatInrPaise(a.outstandingPaise)} will be marked as settled before the new start.\n'
          'No cash, bank or wallet balance changes. It is saved with this reason:\n"$reason"\n\n'
          'പഴയ ബാക്കി തീർത്തതായി രേഖപ്പെടുത്തും. പണമോ വാലറ്റോ മാറില്ല.',
          style: const TextStyle(color: TekColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel (വേണ്ട)')),
          FilledButton(
            key: const ValueKey('clear-old-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear (തീർക്കുക)'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await RechargeAccountingService.instance.distributorCreditReversal(
        shopId: shop,
        actor: _actor,
        distributorId: a.distributorId,
        operator: a.operator,
        amountPaise: a.outstandingPaise,
        reason: reason,
        referenceNo: 'FRESH_START_$kRechargeFreshStartIstDate',
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text('${a.distributorName}: old dues cleared'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      _loadLiveDashboardData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(accountingErrorText(e)),
          backgroundColor: kPeriodRed,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  /// Wrong entry (e.g. wrong operator): marks the recharge failed on the
  /// server, which returns the debit to that operator's wallet. The customer's
  /// money is untouched (recharge money is kept out of ERP cash); a Credit/Due
  /// entry's customer due is reversed. Then the correct recharge is entered
  /// again as usual.
  /// Owner edit of a saved recharge: details on the server, or a correction
  /// followed by the New Recharge form pre-filled with the old values.
  Future<void> _editRecharge(RechargeEntry t) async {
    final shop = AuthController.instance.shopId;
    if (shop.isEmpty) return;
    final prefill = RechargeEntryEditor.prefillFor(t);
    final outcome = await RechargeEditDialog.show(context, shopId: shop, actor: _actor, entry: t);
    if (!mounted) return;
    if (outcome == RechargeEditOutcome.detailsSaved) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text('Saved (സേവ് ചെയ്തു)'),
        behavior: SnackBarBehavior.floating,
      ));
      _loadLiveDashboardData();
    } else if (outcome == RechargeEditOutcome.corrected) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text('Corrected. ${formatInrPaise(t.amountPaise)} returned to the wallet. Now save the correct recharge. '
            '(ഇനി ശരിയായ റീചാർജ് സേവ് ചെയ്യുക)'),
        behavior: SnackBarBehavior.floating,
      ));
      _loadLiveDashboardData();
      await QuickRechargeDialog.show(context, fundingType: _selectedFundingType, prefill: prefill);
      if (mounted) _loadLiveDashboardData();
    }
  }

  Future<void> _cancelWrongRecharge(RechargeEntry t) async {
    final shop = AuthController.instance.shopId;
    if (shop.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.cardBg,
        title: const Text('Cancel wrong entry? (തെറ്റായ എൻട്രി റദ്ദാക്കണോ?)',
            style: TextStyle(color: TekColors.textPrimary, fontSize: 16)),
        content: Text(
          '${t.operator.displayName} - ${t.customerMobile} - ${formatInrPaise(t.amountPaise)}\n\n'
          'This entry is marked failed and ${formatInrPaise(t.amountPaise)} goes back to the ${operatorShortName(t.operator)} wallet. '
          'Then enter the recharge again with the correct operator.\n\n'
          'ഈ എൻട്രി റദ്ദാകും, തുക ${operatorShortName(t.operator)} വാലറ്റിലേക്ക് തിരികെ വരും. '
          'ശേഷം ശരിയായ ഓപ്പറേറ്റർ തിരഞ്ഞെടുത്ത് വീണ്ടും റീചാർജ് ചേർക്കുക.',
          style: const TextStyle(color: TekColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No (വേണ്ട)')),
          FilledButton(
            key: const ValueKey('cancel-recharge-confirm'),
            style: FilledButton.styleFrom(backgroundColor: TekColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel entry (റദ്ദാക്കുക)'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await RechargeAccountingService.instance.failedRechargeReversal(
        shopId: shop,
        actor: _actor,
        rechargeId: t.rechargeId,
        reason: 'Wrong entry cancelled by owner (wrong operator / details)',
      );
      // Local copy follows the server: status FAILED.
      final raw = Db.recharges.get(t.rechargeId);
      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        map['status'] = 'FAILED';
        map['notes'] = '${map['notes'] ?? ''} [Cancelled: wrong entry]'.trim();
        map['updatedAt'] = DateTime.now().toIso8601String();
        await Db.recharges.put(t.rechargeId, map);
        RechargeService.instance.registerConfirmedRecharge(map, t.rechargeId);
        // A Credit/Due entry had added the amount to the customer's due.
        final partyKey = map['partyKey'];
        if ((map['paymentMode']?.toString() ?? '') == 'Credit / Due' &&
            partyKey != null &&
            Db.parties.containsKey(partyKey)) {
          await Db.adjustParty(partyKey, -t.amount);
        }
      }
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text('Cancelled. ${formatInrPaise(t.amountPaise)} returned to ${operatorShortName(t.operator)} wallet. Now enter the correct recharge.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      _loadLiveDashboardData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(accountingErrorText(e)),
          backgroundColor: kPeriodRed,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  /// Fresh start: sets the system wallet (used to check recharge debits) to
  /// the verified balance, split into own money and distributor credit.
  Future<void> _alignWallet(RechargeOperator op) async {
    final shop = AuthController.instance.shopId;
    final st = _period?[op];
    if (shop.isEmpty || st == null || st.previousClosing == null) return;
    final verified = st.closing().expectedClosingPaise;
    final owed = _settlement?.accounts
            .where((a) => a.operator == op)
            .fold<int>(0, (a, x) => a + x.outstandingPaise) ??
        0;
    // Single-balance mode: the whole verified balance is the wallet balance.
    final defaultCredit = _showFundingModeSelector ? (owed < verified ? owed : verified) : 0;
    String rs(int p) => '${p ~/ 100}.${(p % 100).toString().padLeft(2, '0')}';
    final creditCtl = TextEditingController(text: rs(defaultCredit));
    String? error;
    final credit = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final c = parseRupeesToPaise(creditCtl.text);
        final own = c == null ? null : verified - c;
        return AlertDialog(
          backgroundColor: TekColors.cardBg,
          title: Text('Align wallet - ${operatorShortName(op)}',
              style: const TextStyle(color: TekColors.textPrimary, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'System wallet now: ${formatInrPaise(_wallets[op]?.totalBalancePaise ?? 0)} (old figure)\n'
                'Verified balance: ${formatInrPaise(verified)}\n\n'
                'The system wallet is set to the verified balance so recharges are checked against the real amount. '
                'This is not a top-up: expected closing and recharge totals do not change.\n'
                'സിസ്റ്റം വാലറ്റ് യഥാർത്ഥ ബാലൻസിലേക്ക് ശരിയാക്കും. ഇത് top-up അല്ല.',
                style: const TextStyle(color: TekColors.textSecondary, fontSize: 12.5),
              ),
              if (_showFundingModeSelector) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('align-credit'),
                controller: creditCtl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: TekColors.textPrimary),
                decoration: const InputDecoration(
                    labelText: 'Of which distributor credit (ഡിസ്ട്രിബ്യൂട്ടർ ക്രെഡിറ്റ്)', prefixText: 'Rs '),
                onChanged: (_) => setLocal(() {}),
              ),
              const SizedBox(height: 8),
              Text(
                own == null || own < 0
                    ? 'Own money: -'
                    : 'Own money (സ്വന്തം പണം): ${formatInrPaise(own)}',
                style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.w700),
              ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!, style: const TextStyle(color: kPeriodRed, fontSize: 12)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel (വേണ്ട)')),
            FilledButton(
              key: const ValueKey('align-save'),
              onPressed: () {
                final cc = parseRupeesToPaise(creditCtl.text);
                if (cc == null || cc < 0 || cc > verified) {
                  setLocal(() => error = 'Credit must be between 0 and ${formatInrPaise(verified)}');
                  return;
                }
                Navigator.pop(ctx, cc);
              },
              child: const Text('Align (ശരിയാക്കുക)'),
            ),
          ],
        );
      }),
    );
    _disposeAfterDialog([creditCtl]);
    if (credit == null || !mounted) return;
    try {
      await RechargeAccountingService.instance.alignWallet(
        shopId: shop,
        actor: _actor,
        operator: op,
        ownPaise: verified - credit,
        creditPaise: credit,
        reason: 'Fresh start ($kRechargeFreshStartIstDate): system wallet set to the verified balance',
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text('${operatorShortName(op)} wallet aligned to ${formatInrPaise(verified)}'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      _loadLiveDashboardData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(accountingErrorText(e)),
          backgroundColor: kPeriodRed,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  /// A closed dialog still uses its text fields during the exit animation;
  /// disposing them at once trips a framework assertion (red error screen in
  /// debug builds). Dispose them after the animation instead.
  static void _disposeAfterDialog(List<TextEditingController> ctls) {
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      for (final c in ctls) {
        c.dispose();
      }
    });
  }

  /// Fresh start: dues still owed to a distributor from before the new start.
  /// Payable only: the wallet credit is already in the verified opening.
  Future<void> _openingDues(SettlementAccount a) async {
    final shop = AuthController.instance.shopId;
    if (shop.isEmpty || a.operator == RechargeOperator.other) return;
    final amountCtl = TextEditingController();
    final reasonCtl = TextEditingController(
        text: 'Owed before fresh start ($kRechargeFreshStartIstDate); wallet already in opening balance');
    String? error;
    final paise = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: TekColors.cardBg,
          title: Text('Opening dues - ${a.distributorName} (${operatorShortName(a.operator)})',
              style: const TextStyle(color: TekColors.textPrimary, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Amount you still owe this distributor from before the new start. '
                'Only the distributor balance goes up. The wallet does not change, because this credit is already in your opening balance.\n'
                'പുതിയ തുടക്കത്തിന് മുമ്പുള്ള, ഇപ്പോഴും കൊടുക്കാനുള്ള തുക. വാലറ്റ് മാറില്ല.',
                style: TextStyle(color: TekColors.textSecondary, fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('opening-dues-amount'),
                controller: amountCtl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: TekColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Amount owed', prefixText: 'Rs '),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: reasonCtl,
                style: const TextStyle(color: TekColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Reason (കാരണം)'),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!, style: const TextStyle(color: kPeriodRed, fontSize: 12)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel (വേണ്ട)')),
            FilledButton(
              key: const ValueKey('opening-dues-save'),
              onPressed: () {
                final p = parseRupeesToPaise(amountCtl.text);
                if (p == null || p <= 0) {
                  setLocal(() => error = 'Enter a valid amount (സാധുവായ തുക നൽകുക)');
                  return;
                }
                if (reasonCtl.text.trim().isEmpty) {
                  setLocal(() => error = 'Reason is required (കാരണം നിർബന്ധം)');
                  return;
                }
                Navigator.pop(ctx, p);
              },
              child: const Text('Save (സേവ്)'),
            ),
          ],
        ),
      ),
    );
    final reason = reasonCtl.text.trim();
    _disposeAfterDialog([amountCtl, reasonCtl]);
    if (paise == null || !mounted) return;
    try {
      await RechargeAccountingService.instance.distributorOpeningDues(
        shopId: shop,
        actor: _actor,
        distributorId: a.distributorId,
        operator: a.operator,
        amountPaise: paise,
        reason: reason,
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text('${a.distributorName}: opening dues ${formatInrPaise(paise)} saved'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      _loadLiveDashboardData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(accountingErrorText(e)),
          backgroundColor: kPeriodRed,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  /// "Direct Pay" now records an operator-wise payment on the server.
  void _showDistributorPayoutModal() => _openDistributorPayment();

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
