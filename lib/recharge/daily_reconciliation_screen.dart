import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../theme/tek_tokens.dart';
import 'recharge_models.dart';
import 'recharge_service.dart';

/// ============================================================================
/// TEKFIX ERP - PHASE 12: DAILY OPERATOR OPENING & CLOSING RECONCILIATION SCREEN
/// ============================================================================

class DailyReconciliationScreen extends StatefulWidget {
  final String shopId;
  final int initialTab;

  const DailyReconciliationScreen({
    super.key,
    required this.shopId,
    this.initialTab = 0,
  });

  static Future<void> show(
    BuildContext context, {
    required String shopId,
    int initialTab = 0,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DailyReconciliationScreen(
          shopId: shopId,
          initialTab: initialTab,
        ),
      ),
    );
  }

  @override
  State<DailyReconciliationScreen> createState() =>
      _DailyReconciliationScreenState();
}

class _DailyReconciliationScreenState extends State<DailyReconciliationScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final RechargeService _service = RechargeService.instance;
  final NumberFormat _currencyFormat = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 2,
  );

  bool _isLoading = true;
  String _todayDate = '';
  DailyReconciliationRecord? _currentRecord;
  List<DailyReconciliationRecord> _historyRecords = [];

  // Opening Controllers
  final Map<RechargeOperator, TextEditingController> _openingControllers = {};
  // Closing Controllers
  final Map<RechargeOperator, TextEditingController> _closingControllers = {};
  final Map<RechargeOperator, TextEditingController> _reasonControllers = {};
  final Map<RechargeOperator, TextEditingController> _remarksControllers = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab,
    );
    _todayDate = RechargeService.getBusinessDate();

    for (final op in RechargeService.requiredDailyOperators) {
      _openingControllers[op] = TextEditingController();
      _closingControllers[op] = TextEditingController();
      _reasonControllers[op] = TextEditingController();
      _remarksControllers[op] = TextEditingController();
    }

    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final c in _openingControllers.values) {
      c.dispose();
    }
    for (final c in _closingControllers.values) {
      c.dispose();
    }
    for (final c in _reasonControllers.values) {
      c.dispose();
    }
    for (final c in _remarksControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final updatedRec = await _service.calculateAutomaticReconciliation(
        shopId: widget.shopId,
        businessDate: _todayDate,
      );

      // Populate text controllers if already entered
      for (final op in RechargeService.requiredDailyOperators) {
        final opEntry = updatedRec.operators[op.name];
        if (opEntry != null) {
          if (opEntry.isOpeningCompleted &&
              _openingControllers[op]!.text.isEmpty) {
            _openingControllers[op]!.text =
                opEntry.openingBalance.toStringAsFixed(2);
          }
          if (opEntry.isClosingCompleted &&
              _closingControllers[op]!.text.isEmpty) {
            _closingControllers[op]!.text =
                opEntry.actualClosingBalance.toStringAsFixed(2);
          }
          if (opEntry.mismatchReason != null &&
              _reasonControllers[op]!.text.isEmpty) {
            _reasonControllers[op]!.text = opEntry.mismatchReason!;
          }
          if (opEntry.remarks != null &&
              _remarksControllers[op]!.text.isEmpty) {
            _remarksControllers[op]!.text = opEntry.remarks!;
          }
        }
      }

      final hist = await _service.getDailyReconciliationHistory(
        shopId: widget.shopId,
      );

      if (mounted) {
        setState(() {
          _currentRecord = updatedRec;
          _historyRecords = hist;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading reconciliation: $e'),
            backgroundColor: TekColors.error,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // OPERATOR COLOR & BADGE HELPERS
  // ---------------------------------------------------------------------------
  Color _getOperatorColor(RechargeOperator op) {
    switch (op) {
      case RechargeOperator.jio:
        return const Color(0xFF0F3E99);
      case RechargeOperator.airtel:
        return const Color(0xFFE40000);
      case RechargeOperator.vi:
        return const Color(0xFFED1C24);
      case RechargeOperator.bsnl:
        return const Color(0xFF0056B3);
      case RechargeOperator.other:
        return TekColors.electricCyan;
    }
  }

  IconData _getOperatorIcon(RechargeOperator op) {
    switch (op) {
      case RechargeOperator.jio:
        return Icons.bolt_rounded;
      case RechargeOperator.airtel:
        return Icons.signal_cellular_alt_rounded;
      case RechargeOperator.vi:
        return Icons.cell_tower_rounded;
      case RechargeOperator.bsnl:
        return Icons.phone_in_talk_rounded;
      case RechargeOperator.other:
        return Icons.devices_other_rounded;
    }
  }

  // ---------------------------------------------------------------------------
  // SAVE MORNING OPENING BALANCE
  // ---------------------------------------------------------------------------
  Future<void> _saveOpeningBalance() async {
    final Map<RechargeOperator, double> balances = {};

    for (final op in RechargeService.requiredDailyOperators) {
      final text = _openingControllers[op]!.text.trim();
      final val = double.tryParse(text);
      if (val == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '${op.displayName} ഓപ്പണിംഗ് ബാലൻസ് നൽകുക (Enter valid opening balance for ${op.displayName})'),
            backgroundColor: TekColors.warning,
          ),
        );
        return;
      }
      balances[op] = val;
    }

    try {
      setState(() => _isLoading = true);
      final auth = context.read<AuthController>();
      final staffId = auth.uid.isNotEmpty ? auth.uid : 'STAFF';
      final staffName = auth.name.isNotEmpty ? auth.name : 'Staff Member';

      final rec = await _service.recordMorningOpeningBalance(
        shopId: widget.shopId,
        businessDate: _todayDate,
        openingBalances: balances,
        staffId: staffId,
        staffName: staffName,
      );

      setState(() {
        _currentRecord = rec;
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                '✅ മോർണിംഗ് ഓപ്പണിംഗ് ബാലൻസ് വിജയകരമായി രേഖപ്പെടുത്തി (Opening balance saved successfully)'),
            backgroundColor: TekColors.success,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception: ', '')),
            backgroundColor: TekColors.error,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // SAVE NIGHT CLOSING BALANCE
  // ---------------------------------------------------------------------------
  Future<void> _saveClosingBalance() async {
    final Map<RechargeOperator, double> actualBalances = {};
    final Map<RechargeOperator, String> reasons = {};
    final Map<RechargeOperator, String> remarks = {};

    for (final op in RechargeService.requiredDailyOperators) {
      final text = _closingControllers[op]!.text.trim();
      final val = double.tryParse(text);
      if (val == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '${op.displayName} ക്ലോസിംഗ് ബാലൻസ് നൽകുക (Enter valid closing balance for ${op.displayName})'),
            backgroundColor: TekColors.warning,
          ),
        );
        return;
      }
      actualBalances[op] = val;
      if (_reasonControllers[op]!.text.isNotEmpty) {
        reasons[op] = _reasonControllers[op]!.text.trim();
      }
      if (_remarksControllers[op]!.text.isNotEmpty) {
        remarks[op] = _remarksControllers[op]!.text.trim();
      }
    }

    try {
      setState(() => _isLoading = true);
      final auth = context.read<AuthController>();
      final staffId = auth.uid.isNotEmpty ? auth.uid : 'STAFF';
      final staffName = auth.name.isNotEmpty ? auth.name : 'Staff Member';

      final rec = await _service.recordNightClosingBalance(
        shopId: widget.shopId,
        businessDate: _todayDate,
        actualClosingBalances: actualBalances,
        mismatchReasons: reasons,
        remarks: remarks,
        staffId: staffId,
        staffName: staffName,
      );

      setState(() {
        _currentRecord = rec;
        _isLoading = false;
      });

      if (mounted) {
        if (rec.hasMismatch) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  '⚠️ ക്ലോസിംഗ് ബാലൻസിൽ വ്യത്യാസമുണ്ട് (Closing saved with Mismatch Warning. Owner review required.)'),
              backgroundColor: TekColors.warning,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  '✅ നൈറ്റ് ക്ലോസിംഗ് വിജയകരമായി പൂർത്തിയായി (Closing balanced perfectly!)'),
              backgroundColor: TekColors.success,
            ),
          );
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception: ', '')),
            backgroundColor: TekColors.error,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // OWNER REVIEW DIALOG
  // ---------------------------------------------------------------------------
  Future<void> _showOwnerReviewDialog() async {
    final noteCtrl = TextEditingController();
    bool markImmutable = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: TekColors.cardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: TekColors.border, width: 1.2),
          ),
          title: const Row(
            children: [
              Icon(Icons.verified_user_rounded, color: TekColors.electricCyan),
              SizedBox(width: 10),
              Text('Owner Reconciliation Review',
                  style: TextStyle(color: TekColors.textPrimary, fontSize: 18)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter authorized review notes and approval for this day\'s reconciliation:',
                style: TextStyle(color: TekColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: noteCtrl,
                maxLines: 3,
                style: const TextStyle(color: TekColors.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'e.g. Verified operator commission delay & cash variance.',
                  hintStyle: const TextStyle(color: TekColors.textMuted),
                  filled: true,
                  fillColor: TekColors.mainBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TekColors.border),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: TekColors.electricCyan,
                title: const Text(
                  'Mark day\'s record as permanent & immutable',
                  style: TextStyle(color: TekColors.textPrimary, fontSize: 13),
                ),
                subtitle: const Text(
                  'Locks previous records against staff modification',
                  style: TextStyle(color: TekColors.textMuted, fontSize: 11),
                ),
                value: markImmutable,
                onChanged: (v) => setDialogState(() => markImmutable = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel', style: TextStyle(color: TekColors.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: TekColors.electricCyan,
                foregroundColor: TekColors.mainBg,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                Navigator.of(ctx).pop();
                try {
                  final auth = context.read<AuthController>();
                  if (!auth.isOwner) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              '❌ ഉടമയ്ക്ക് മാത്രമേ റീകൺസിലിയേഷൻ അംഗീകരിക്കാൻ അനുവാദമുള്ളൂ (Only verified shop owner can approve reconciliation mismatches)'),
                          backgroundColor: TekColors.error,
                        ),
                      );
                    }
                    return;
                  }

                  setState(() => _isLoading = true);
                  final updated = await _service.reviewReconciliationMismatch(
                    shopId: widget.shopId,
                    businessDate: _todayDate,
                    ownerId: auth.uid,
                    ownerName: auth.name.isNotEmpty ? auth.name : 'Shop Owner',
                    reviewNotes: noteCtrl.text.trim().isEmpty
                        ? 'Reconciliation reviewed and approved'
                        : noteCtrl.text.trim(),
                    markImmutable: markImmutable,
                  );
                  setState(() {
                    _currentRecord = updated;
                    _isLoading = false;
                  });
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            '✅ ഓണർ റിവ്യൂ രേഖപ്പെടുത്തി (Owner review recorded successfully)'),
                        backgroundColor: TekColors.success,
                      ),
                    );
                  }
                } catch (e) {
                  setState(() => _isLoading = false);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: $e'), backgroundColor: TekColors.error),
                    );
                  }
                }
              },
              child: const Text('Confirm Review'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // MAIN BUILD
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 980;

    return Scaffold(
      backgroundColor: TekColors.mainBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopAppBar(context),
            _buildTabBar(),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: TekColors.electricCyan),
                    )
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildOpeningBalanceTab(isDesktop),
                        _buildClosingBalanceTab(isDesktop),
                        _buildHistoryTab(isDesktop),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

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
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_rounded,
                color: TekColors.textPrimary),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              gradient: TekColors.cyanBlueGradient,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.account_balance_rounded,
                color: TekColors.mainBg, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Daily Operator Balance & Reconciliation',
                  style: TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'ദിവസേനയുള്ള ഓപ്പറേറ്റർ ഓപ്പണിംഗ് / ക്ലോസിംഗ് റീകൺസിലിയേഷൻ • Date: $_todayDate',
                  style: const TextStyle(
                    color: TekColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (_currentRecord?.isImmutable == true)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: TekColors.electricCyan.withAlpha(25),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: TekColors.electricCyan.withAlpha(120)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lock_rounded, size: 14, color: TekColors.electricCyan),
                  SizedBox(width: 6),
                  Text('IMMUTABLE AUDIT RECORD',
                      style: TextStyle(
                          color: TekColors.electricCyan,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      color: TekColors.sidebarBg,
      child: TabBar(
        controller: _tabController,
        indicatorColor: TekColors.electricCyan,
        indicatorWeight: 3,
        labelColor: TekColors.electricCyan,
        unselectedLabelColor: TekColors.textSecondary,
        tabs: const [
          Tab(
            icon: Icon(Icons.wb_sunny_rounded, size: 20),
            text: 'Morning Opening',
          ),
          Tab(
            icon: Icon(Icons.nightlight_round, size: 20),
            text: 'Night Closing & Reconciliation',
          ),
          Tab(
            icon: Icon(Icons.history_rounded, size: 20),
            text: 'Daily History',
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 1: MORNING OPENING BALANCE
  // ===========================================================================
  Widget _buildOpeningBalanceTab(bool isDesktop) {
    final isComplete = _currentRecord?.isOpeningComplete == true;

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 24 : 16,
        vertical: 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status Header
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: isComplete
                  ? TekColors.success.withAlpha(20)
                  : TekColors.warning.withAlpha(20),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isComplete
                    ? TekColors.success.withAlpha(100)
                    : TekColors.warning.withAlpha(100),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isComplete
                      ? Icons.check_circle_rounded
                      : Icons.warning_amber_rounded,
                  color: isComplete
                      ? TekColors.success
                      : TekColors.warning,
                  size: 28,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isComplete
                            ? 'Morning Opening Complete'
                            : 'Morning Opening Incomplete',
                        style: TextStyle(
                          color: isComplete
                              ? TekColors.success
                              : TekColors.warning,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isComplete
                            ? 'All four operators (Jio, Airtel, Vi, BSNL) opening balances are safely recorded.'
                            : 'Enter the actual balance displayed inside each operator app before starting recharge accounting.',
                        style: const TextStyle(
                          color: TekColors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 4 Operator Cards Grid
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: isDesktop ? 4 : 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: isDesktop ? 1.05 : 0.88,
            ),
            itemCount: RechargeService.requiredDailyOperators.length,
            itemBuilder: (ctx, i) {
              final op = RechargeService.requiredDailyOperators[i];
              return _buildOpeningOperatorCard(op);
            },
          ),
          const SizedBox(height: 28),

          // Save Button
          if (!isComplete)
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: TekColors.electricCyan,
                  foregroundColor: TekColors.mainBg,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 4,
                ),
                icon: const Icon(Icons.save_rounded),
                label: const Text(
                  'SAVE OPENING BALANCE (ഓപ്പണിംഗ് സേവ് ചെയ്യുക)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                onPressed: _saveOpeningBalance,
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: TekColors.cardBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: TekColors.border),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lock_rounded, size: 16, color: TekColors.textSecondary),
                  SizedBox(width: 8),
                  Text(
                    'Opening balance is confirmed and locked against duplicate entries for today.',
                    style: TextStyle(color: TekColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOpeningOperatorCard(RechargeOperator op) {
    final entry = _currentRecord?.operators[op.name];
    final color = _getOperatorColor(op);
    final icon = _getOperatorIcon(op);
    final isDone = entry?.isOpeningCompleted == true;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDone ? color.withAlpha(160) : TekColors.border,
          width: 1.4,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      op.displayName,
                      style: const TextStyle(
                        color: TekColors.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      op.malayalam,
                      style: const TextStyle(
                        color: TekColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (isDone)
                const Icon(Icons.check_circle_rounded,
                    color: TekColors.success, size: 20)
              else
                const Icon(Icons.radio_button_unchecked_rounded,
                    color: TekColors.textMuted, size: 20),
            ],
          ),
          const Spacer(),
          const Text(
            'Actual App Balance (₹):',
            style: TextStyle(color: TekColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _openingControllers[op],
            enabled: !isDone,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(
              color: TekColors.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
            decoration: InputDecoration(
              prefixText: '₹ ',
              prefixStyle:
                  const TextStyle(color: TekColors.electricCyan, fontSize: 16),
              hintText: '0.00',
              hintStyle: const TextStyle(color: TekColors.textMuted),
              filled: true,
              fillColor: isDone ? TekColors.mainBg.withAlpha(120) : TekColors.mainBg,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: TekColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: TekColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: color, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (isDone && entry?.openingEnteredAt != null)
            Text(
              'Entered: ${DateFormat('hh:mm a').format(entry!.openingEnteredAt!)} by ${entry.openingEnteredBy}',
              style: const TextStyle(color: TekColors.textMuted, fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 2: NIGHT CLOSING & AUTOMATIC RECONCILIATION
  // ===========================================================================
  Widget _buildClosingBalanceTab(bool isDesktop) {
    final hasMismatch = _currentRecord?.hasMismatch == true;
    final isClosed = _currentRecord?.isClosingComplete == true;

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 24 : 16,
        vertical: 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 10:30 PM Reminder Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1B4B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF6366F1).withAlpha(100)),
            ),
            child: const Row(
              children: [
                Icon(Icons.alarm_rounded, color: Color(0xFF818CF8), size: 22),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Default Closing Time: 10:30 PM • Enter actual balances from operator apps for automatic reconciliation.',
                    style: TextStyle(color: Color(0xFFC7D2FE), fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // Incomplete Ledger Alert if detected
          if (_currentRecord?.hasIncompleteLedger == true) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: TekColors.warning.withAlpha(25),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: TekColors.warning.withAlpha(160), width: 1.4),
              ),
              child: const Row(
                children: [
                  Icon(Icons.sync_problem_rounded, color: TekColors.warning, size: 26),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'RECONCILIATION DATA INCOMPLETE (ഡാറ്റ അപൂർണ്ണമാണ്)',
                          style: TextStyle(
                            color: TekColors.warning,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Wallet ledger records cannot be fully verified from device or server. Expected balance cannot be confirmed.',
                          style: TextStyle(color: TekColors.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],

          // Prominent Mismatch Alert if detected
          if (hasMismatch) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: TekColors.error.withAlpha(20),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: TekColors.error.withAlpha(120), width: 1.4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.report_problem_rounded,
                          color: TekColors.error, size: 26),
                      SizedBox(width: 12),
                      Text(
                        'MISMATCH DETECTED (റീകൺസിലിയേഷൻ വ്യത്യാസം)',
                        style: TextStyle(
                          color: TekColors.error,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Actual closing balance from one or more operator apps differs from expected balance calculated from financial ledger entries. Provide mandatory reason and remarks.',
                    style: TextStyle(color: TekColors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: TekColors.electricCyan,
                      foregroundColor: TekColors.mainBg,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.verified_user_rounded, size: 18),
                    label: const Text('Review by Owner (ഓണർ അംഗീകാരം)'),
                    onPressed: _showOwnerReviewDialog,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Dedicated Recharge Accounting Separation Summary & 3 Totals
          _buildRechargeAccountingSeparationSummary(isDesktop),

          // Operator-Wise Recharge Summary (Airtel, Jio, Vi, BSNL)
          _buildOperatorWiseRechargeTable(isDesktop),

          // 4 Operator Closing Cards
          Column(
            children: RechargeService.requiredDailyOperators.map((op) {
              return _buildClosingOperatorRow(op, isDesktop);
            }).toList(),
          ),
          const SizedBox(height: 24),

          // Save Closing Balance Button
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isClosed)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: TekColors.electricCyan,
                      side: const BorderSide(color: TekColors.electricCyan),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.verified_user_rounded),
                    label: const Text('Owner Review Dialog'),
                    onPressed: _showOwnerReviewDialog,
                  ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: TekColors.electricCyan,
                    foregroundColor: TekColors.mainBg,
                    padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.check_circle_outline_rounded),
                  label: const Text(
                    'SAVE CLOSING BALANCE (ക്ലോസിംഗ് സേവ് ചെയ്യുക)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  onPressed: _saveClosingBalance,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SEPARATE RECHARGE ACCOUNTING TOTALS & OPERATOR-WISE SUMMARY
  // ---------------------------------------------------------------------------
  Widget _buildRechargeAccountingSeparationSummary(bool isDesktop) {
    final totalRecharge = _currentRecord?.totalRechargeAmount ?? 0.0;
    final totalWallet = _currentRecord?.totalRechargeWalletBalance ?? 0.0;
    final totalCommission = _currentRecord?.totalRechargeCommission ?? 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TekColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: TekColors.electricCyan.withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.account_balance_wallet_rounded,
                    color: TekColors.electricCyan, size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SEPARATE RECHARGE ACCOUNTING TOTALS',
                      style: TextStyle(
                        color: TekColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.4,
                      ),
                    ),
                    Text(
                      'റീചാർജ് തുകകൾ പ്രത്യേക ലഡ്ജറിലാണ് - സാധാരണ ക്യാഷ്/ബാങ്കുമായി കലരില്ല (Isolated from Cash/Bank)',
                      style: TextStyle(
                        color: TekColors.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 720;
              final cards = [
                _buildSeparationTotalCard(
                  title: 'Total Recharge Amount',
                  malayalam: 'ആകെ റീചാർജ് തുക',
                  amount: totalRecharge,
                  color: TekColors.electricCyan,
                  icon: Icons.payments_rounded,
                  badge: 'Gross Debits',
                ),
                _buildSeparationTotalCard(
                  title: 'Total Recharge Wallet Balance',
                  malayalam: 'ആകെ വാലറ്റ് ബാക്കി',
                  amount: totalWallet,
                  color: const Color(0xFF10B981),
                  icon: Icons.savings_rounded,
                  badge: 'Float Balance',
                ),
                _buildSeparationTotalCard(
                  title: 'Total Recharge Commission',
                  malayalam: 'ലഭിച്ച കമ്മീഷൻ (യഥാർത്ഥ വരുമാനം)',
                  amount: totalCommission,
                  color: const Color(0xFFF59E0B),
                  icon: Icons.monetization_on_rounded,
                  badge: 'Actual Income Only',
                ),
              ];
              if (isWide) {
                return Row(
                  children: cards.map((c) => Expanded(child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: c,
                  ))).toList(),
                );
              } else {
                return Column(
                  children: cards.map((c) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: c,
                  )).toList(),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSeparationTotalCard({
    required String title,
    required String malayalam,
    required double amount,
    required Color color,
    required IconData icon,
    required String badge,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TekColors.mainBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(80), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withAlpha(25),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _currencyFormat.format(amount),
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
              color: TekColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            malayalam,
            style: const TextStyle(
              color: TekColors.textMuted,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOperatorWiseRechargeTable(bool isDesktop) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TekColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'OPERATOR-WISE RECHARGE SUMMARY (ഓപ്പറേറ്റർ തിരിച്ചുള്ള കണക്കുകൾ)',
            style: TextStyle(
              color: TekColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 600;
              final opCards = [
                _buildOperatorSummaryMiniCard(
                  operatorName: 'Airtel',
                  rechargeAmount: _currentRecord?.airtelRechargeAmount ?? 0.0,
                  closingBalance: _currentRecord?.operators[RechargeOperator.airtel.name]?.actualClosingBalance ?? 0.0,
                  commission: _currentRecord?.operators[RechargeOperator.airtel.name]?.totalCommission ?? 0.0,
                  color: const Color(0xFFE40000),
                ),
                _buildOperatorSummaryMiniCard(
                  operatorName: 'Jio',
                  rechargeAmount: _currentRecord?.jioRechargeAmount ?? 0.0,
                  closingBalance: _currentRecord?.operators[RechargeOperator.jio.name]?.actualClosingBalance ?? 0.0,
                  commission: _currentRecord?.operators[RechargeOperator.jio.name]?.totalCommission ?? 0.0,
                  color: const Color(0xFF0F3E99),
                ),
                _buildOperatorSummaryMiniCard(
                  operatorName: 'Vi',
                  rechargeAmount: _currentRecord?.viRechargeAmount ?? 0.0,
                  closingBalance: _currentRecord?.operators[RechargeOperator.vi.name]?.actualClosingBalance ?? 0.0,
                  commission: _currentRecord?.operators[RechargeOperator.vi.name]?.totalCommission ?? 0.0,
                  color: const Color(0xFFED1C24),
                ),
                _buildOperatorSummaryMiniCard(
                  operatorName: 'BSNL',
                  rechargeAmount: _currentRecord?.bsnlRechargeAmount ?? 0.0,
                  closingBalance: _currentRecord?.operators[RechargeOperator.bsnl.name]?.actualClosingBalance ?? 0.0,
                  commission: _currentRecord?.operators[RechargeOperator.bsnl.name]?.totalCommission ?? 0.0,
                  color: const Color(0xFF0056B3),
                ),
              ];
              if (isWide) {
                return Row(
                  children: opCards.map((c) => Expanded(child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: c,
                  ))).toList(),
                );
              } else {
                return Column(
                  children: opCards.map((c) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: c,
                  )).toList(),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildOperatorSummaryMiniCard({
    required String operatorName,
    required double rechargeAmount,
    required double closingBalance,
    required double commission,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TekColors.mainBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withAlpha(70)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
              const SizedBox(width: 6),
              Text(
                operatorName,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$operatorName Recharge Amount:',
            style: const TextStyle(color: TekColors.textSecondary, fontSize: 10),
          ),
          Text(
            _currencyFormat.format(rechargeAmount),
            style: const TextStyle(
              color: TekColors.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Wallet: ${_currencyFormat.format(closingBalance)}',
                style: const TextStyle(color: TekColors.textMuted, fontSize: 9.5),
              ),
              Text(
                'Comm: ${_currencyFormat.format(commission)}',
                style: const TextStyle(color: TekColors.success, fontSize: 9.5, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildClosingOperatorRow(RechargeOperator op, bool isDesktop) {
    final entry = _currentRecord?.operators[op.name];
    final color = _getOperatorColor(op);
    final diff = entry?.difference ?? 0.0;
    final isMismatch = entry?.isMismatch == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isMismatch ? TekColors.error : TekColors.border,
          width: isMismatch ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(_getOperatorIcon(op), color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                op.displayName,
                style: const TextStyle(
                  color: TekColors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const Spacer(),
              if (isMismatch)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: TekColors.error.withAlpha(25),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: TekColors.error),
                  ),
                  child: const Text(
                    'MISMATCH',
                    style: TextStyle(
                        color: TekColors.error,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                )
              else if (entry?.isClosingCompleted == true)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: TekColors.success.withAlpha(25),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: TekColors.success),
                  ),
                  child: const Text(
                    'BALANCED',
                    style: TextStyle(
                        color: TekColors.success,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),

          // Ledger Breakdown Grid
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              _buildMiniMetric('Opening', entry?.openingBalance ?? 0.0, TekColors.textPrimary),
              _buildMiniMetric('+ Top-ups', entry?.totalTopups ?? 0.0, TekColors.electricCyan),
              _buildMiniMetric('+ Credits', entry?.totalCredits ?? 0.0, TekColors.success),
              _buildMiniMetric('- ${op.displayName} Recharge', entry?.totalDebits ?? 0.0, TekColors.warning),
              _buildMiniMetric('+ Rev (Net)', (entry?.totalDebitReversals ?? 0.0) - (entry?.totalCreditReversals ?? 0.0), TekColors.textSecondary),
              _buildMiniMetric('Comm Earned', entry?.totalCommission ?? 0.0, TekColors.success),
              _buildMiniMetric('Expected Closing', entry?.expectedClosingBalance ?? 0.0, const Color(0xFF818CF8), isBold: true),
            ],
          ),
          const SizedBox(height: 16),

          // Actual Input & Difference
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Actual App Closing Balance (₹):',
                        style: TextStyle(color: TekColors.textSecondary, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _closingControllers[op],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(
                          color: TekColors.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                      decoration: InputDecoration(
                        prefixText: '₹ ',
                        prefixStyle: const TextStyle(color: TekColors.electricCyan),
                        hintText: '0.00',
                        filled: true,
                        fillColor: TekColors.mainBg,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onChanged: (val) {
                        setState(() {
                          // trigger recalculation preview
                        });
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Difference (₹):',
                        style: TextStyle(color: TekColors.textSecondary, fontSize: 12)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        color: diff == 0
                            ? TekColors.mainBg
                            : (diff < 0 ? TekColors.error.withAlpha(25) : TekColors.warning.withAlpha(25)),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: diff == 0 ? TekColors.border : (diff < 0 ? TekColors.error : TekColors.warning),
                        ),
                      ),
                      child: Text(
                        _currencyFormat.format(diff),
                        style: TextStyle(
                          color: diff == 0 ? TekColors.textPrimary : (diff < 0 ? TekColors.error : TekColors.warning),
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Mismatch Reason & Remarks Inputs if difference != 0
          if (diff != 0 || isMismatch) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _reasonControllers[op],
                    style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Mismatch Reason (e.g. Uncredited operator top-up delay)',
                      labelStyle: const TextStyle(color: TekColors.error, fontSize: 12),
                      filled: true,
                      fillColor: TekColors.mainBg,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _remarksControllers[op],
                    style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Remarks / Action Plan',
                      labelStyle: const TextStyle(color: TekColors.textSecondary, fontSize: 12),
                      filled: true,
                      fillColor: TekColors.mainBg,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMiniMetric(String label, double val, Color color, {bool isBold = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: TekColors.mainBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TekColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: TekColors.textMuted, fontSize: 10)),
          const SizedBox(height: 2),
          Text(
            _currencyFormat.format(val),
            style: TextStyle(
              color: color,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 3: DAILY HISTORY
  // ===========================================================================
  Widget _buildHistoryTab(bool isDesktop) {
    if (_historyRecords.isEmpty) {
      return const Center(
        child: Text(
          'No reconciliation history recorded yet.',
          style: TextStyle(color: TekColors.textSecondary),
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 24 : 16,
        vertical: 20,
      ),
      itemCount: _historyRecords.length,
      itemBuilder: (ctx, idx) {
        final r = _historyRecords[idx];
        final isMatch = r.reconciliationStatus == 'balanced';
        final isMismatch = r.reconciliationStatus == 'mismatch';

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: TekColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isMismatch ? TekColors.error.withAlpha(120) : TekColors.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.calendar_today_rounded,
                      size: 16, color: TekColors.electricCyan),
                  const SizedBox(width: 8),
                  Text(
                    r.businessDate,
                    style: const TextStyle(
                      color: TekColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isMatch
                          ? TekColors.success.withAlpha(20)
                          : (isMismatch ? TekColors.error.withAlpha(20) : TekColors.border),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      r.reconciliationStatus.toUpperCase(),
                      style: TextStyle(
                        color: isMatch
                            ? TekColors.success
                            : (isMismatch ? TekColors.error : TekColors.textSecondary),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (r.isImmutable)
                    const Row(
                      children: [
                        Icon(Icons.lock_rounded, size: 14, color: TekColors.textMuted),
                        SizedBox(width: 4),
                        Text('IMMUTABLE',
                            style: TextStyle(
                                color: TekColors.textMuted,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                ],
              ),
              const Divider(color: TekColors.border, height: 20),
              // Operators List Table
              ...r.operators.values.map((opEntry) {
                final diff = opEntry.difference;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 100,
                        child: Text(
                          opEntry.operator.displayName,
                          style: const TextStyle(
                              color: TekColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 12.5),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'Open: ${_currencyFormat.format(opEntry.openingBalance)} | Exp: ${_currencyFormat.format(opEntry.expectedClosingBalance)} | Act: ${_currencyFormat.format(opEntry.actualClosingBalance)}',
                          style: const TextStyle(
                              color: TekColors.textSecondary, fontSize: 11.5),
                        ),
                      ),
                      Text(
                        'Diff: ${_currencyFormat.format(diff)}',
                        style: TextStyle(
                          color: diff == 0 ? TekColors.success : TekColors.error,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                );
              }),
              if (r.auditNotes.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'Audit Trail: ${r.auditNotes.last}',
                  style: const TextStyle(
                      color: TekColors.textMuted,
                      fontSize: 11,
                      fontStyle: FontStyle.italic),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
