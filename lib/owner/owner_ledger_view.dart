import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db, toast;
import '../theme/tek_tokens.dart';
import 'owner_finance_models.dart';
import 'owner_finance_service.dart';
import 'owner_withdrawal_dialog.dart';

class OwnerLedgerView extends StatefulWidget {
  final String? shopId;

  const OwnerLedgerView({super.key, this.shopId});

  @override
  State<OwnerLedgerView> createState() => _OwnerLedgerViewState();
}

class _OwnerLedgerViewState extends State<OwnerLedgerView> {
  DateTime _selectedMonth =
      DateTime(DateTime.now().year, DateTime.now().month, 1);
  bool _loading = true;
  OwnerSalarySettings? _settings;
  OwnerMonthlyQuotaMetrics _metrics =
      OwnerMonthlyQuotaMetrics.empty(DateTime.now());
  List<OwnerWithdrawalItem> _withdrawals = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    final sId = widget.shopId ?? Db.setting('shop_id', 'tekfix');

    try {
      final s = await OwnerFinanceService.instance.getSettings(shopId: sId);
      final q = await OwnerFinanceService.instance.getQuotaMetrics(
        shopId: sId,
        forDate: _selectedMonth,
      );
      final list = await OwnerFinanceService.instance.getWithdrawalsForMonth(
        _selectedMonth,
        shopId: sId,
        includeVoided: true,
      );

      if (mounted) {
        setState(() {
          _settings = s;
          _metrics = q;
          _withdrawals = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _changeMonth(int offset) {
    setState(() {
      _selectedMonth =
          DateTime(_selectedMonth.year, _selectedMonth.month + offset, 1);
      _loading = true;
    });
    _loadData();
  }

  Future<void> _showSettingsDialog() async {
    final auth = context.read<AuthController>();
    if (!auth.isOwner) {
      toast(context,
          'ഉടമയ്ക്ക് മാത്രമേ സെറ്റിംഗ്സ് മാറ്റാൻ അനുവാദമുള്ളൂ (Owner permission required)',
          error: true);
      return;
    }

    final limitCtrl = TextEditingController(
      text: (_settings?.monthlySalaryLimit ?? 20000.0).toStringAsFixed(0),
    );

    final updated = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.mainBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.settings_rounded, color: Color(0xFF8B5CF6)),
            SizedBox(width: 8),
            Text(
              'Owner Salary Limit',
              style: TextStyle(color: TekColors.textPrimary, fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set the monthly base salary limit. Any withdrawal above this amount will be categorized as Owner Excess Drawings (Equity).',
              style: TextStyle(color: TekColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: limitCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                labelText: 'Monthly Salary Cap (മാസ ശമ്പള പരിധി)',
                prefixText: '₹ ',
                prefixStyle: const TextStyle(
                    color: Color(0xFF8B5CF6), fontWeight: FontWeight.bold),
                filled: true,
                fillColor: TekColors.cardBg,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: TekColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B5CF6)),
            onPressed: () async {
              final newLimit =
                  double.tryParse(limitCtrl.text.trim()) ?? 20000.0;
              final current = _settings ??
                  OwnerSalarySettings(effectiveDate: DateTime.now());
              final toSave = current.copyWith(
                monthlySalaryLimit: newLimit,
                monthlySalaryLimitPaise: (newLimit * 100).round(),
              );
              await OwnerFinanceService.instance.saveSettings(
                shopId: widget.shopId ?? auth.shopId,
                newSettings: toSave,
                staffId: auth.uid,
                staffName: auth.name,
              );
              if (ctx.mounted) Navigator.pop(ctx, true);
            },
            child: const Text('Save Limit'),
          ),
        ],
      ),
    );

    if (updated == true) {
      _loadData();
    }
  }

  Future<void> _voidWithdrawal(OwnerWithdrawalItem item) async {
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.mainBg,
        title: const Text('Void Owner Withdrawal',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to void this withdrawal of ₹${item.totalAmount.toStringAsFixed(0)}?',
              style:
                  const TextStyle(color: TekColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Text(
              '• ${item.isCash ? "Cash in Hand" : "Bank Balance"} will be restored (+₹${item.totalAmount.toStringAsFixed(0)}).\n• Linked salary expense and drawings will be reversed.',
              style: const TextStyle(color: Color(0xFF10B981), fontSize: 11.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Void Reason (കാരണം)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: TekColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: TekColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Void'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final auth = context.read<AuthController>();
      try {
        await OwnerFinanceService.instance.voidWithdrawal(
          shopId: widget.shopId ?? auth.shopId,
          withdrawalId: item.id,
          voidedByUid: auth.uid,
          voidedByName: auth.name,
          voidReason: reasonCtrl.text.trim().isNotEmpty
              ? reasonCtrl.text.trim()
              : 'Voided by user',
        );
        if (mounted) {
          toast(context,
              'Withdrawal reversed and balance restored successfully!');
          _loadData();
        }
      } catch (e) {
        if (mounted) toast(context, 'Void failed: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final monthDisplay = DateFormat('MMMM yyyy').format(_selectedMonth);
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      backgroundColor: TekColors.mainBg,
      appBar: AppBar(
        backgroundColor: TekColors.sidebarBg,
        elevation: 0,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Owner Salary & Drawings Ledger',
              style: TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            Text(
              'ഉടമയുടെ ശമ്പളവും പിൻവലിക്കലുകളും • Base ₹20,000 Quota',
              style: TextStyle(fontSize: 11, color: TekColors.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            tooltip: 'Configure Salary Quota',
            onPressed: _showSettingsDialog,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            onPressed: _loadData,
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF8B5CF6),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New Withdrawal (പിൻവലിക്കൽ)'),
        onPressed: () async {
          final res =
              await OwnerWithdrawalDialog.show(context, shopId: widget.shopId);
          if (res == true) _loadData();
        },
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF8B5CF6)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. Month Navigation Header
                  _buildMonthBar(monthDisplay),

                  const SizedBox(height: 16),

                  // 2. Metric Summary Cards (4 Cards)
                  _buildMetricCards(isDesktop),

                  const SizedBox(height: 16),

                  // 3. P&L vs Balance Sheet Breakdown Card
                  _buildPnLEquityExplainerCard(),

                  const SizedBox(height: 20),

                  // 4. Withdrawal Transaction List
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'WITHDRAWAL TRANSACTIONS (${_withdrawals.length})',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                          color: TekColors.textSecondary,
                        ),
                      ),
                      Text(
                        'Total: ₹${_metrics.totalWithdrawnThisMonth.toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF8B5CF6),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  if (_withdrawals.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        color: TekColors.cardBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: TekColors.border),
                      ),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(Icons.account_balance_wallet_outlined,
                                size: 48,
                                color: TekColors.textSecondary
                                    .withValues(alpha: 0.5)),
                            const SizedBox(height: 10),
                            Text(
                              '$monthDisplay-ൽ പിൻവലിക്കലുകൾ ഒന്നും രേഖപ്പെടുത്തിയിട്ടില്ല.',
                              style: const TextStyle(
                                  color: TekColors.textSecondary, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _withdrawals.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (ctx, i) =>
                          _buildWithdrawalCard(_withdrawals[i]),
                    ),

                  const SizedBox(height: 80), // Padding for FAB
                ],
              ),
            ),
    );
  }

  Widget _buildMonthBar(String monthDisplay) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TekColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded, color: Colors.white),
            onPressed: () => _changeMonth(-1),
          ),
          Row(
            children: [
              const Icon(Icons.calendar_month_rounded,
                  size: 18, color: Color(0xFF8B5CF6)),
              const SizedBox(width: 8),
              Text(
                monthDisplay,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded, color: Colors.white),
            onPressed: () => _changeMonth(1),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCards(bool isDesktop) {
    final count = isDesktop ? 4 : 2;
    return GridView.count(
      crossAxisCount: count,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: isDesktop ? 2.1 : 1.7,
      children: [
        _metricCard(
          title: 'Monthly Salary Cap',
          subtitle: '₹${_metrics.monthlyLimit.toStringAsFixed(0)}',
          badgeText: 'Base Limit',
          badgeColor: const Color(0xFF8B5CF6),
          icon: Icons.shield_outlined,
          color: const Color(0xFF8B5CF6),
        ),
        _metricCard(
          title: 'Owner Salary (OPEX)',
          subtitle: '₹${_metrics.usedSalaryThisMonth.toStringAsFixed(0)}',
          badgeText: 'P&L Expense',
          badgeColor: const Color(0xFF10B981),
          icon: Icons.account_balance_wallet_rounded,
          color: const Color(0xFF10B981),
        ),
        _metricCard(
          title: 'Remaining Quota',
          subtitle: '₹${_metrics.remainingSalaryThisMonth.toStringAsFixed(0)}',
          badgeText: _metrics.isQuotaFull ? 'Exhausted' : 'Available',
          badgeColor: _metrics.isQuotaFull
              ? const Color(0xFFF59E0B)
              : const Color(0xFF00D4FF),
          icon: Icons.hourglass_bottom_rounded,
          color: _metrics.isQuotaFull
              ? const Color(0xFFF59E0B)
              : const Color(0xFF00D4FF),
        ),
        _metricCard(
          title: 'Excess Drawings (Equity)',
          subtitle: '₹${_metrics.excessDrawingsThisMonth.toStringAsFixed(0)}',
          badgeText: 'Non-Expense',
          badgeColor: const Color(0xFFA78BFA),
          icon: Icons.trending_down_rounded,
          color: const Color(0xFFA78BFA),
        ),
      ],
    );
  }

  Widget _metricCard({
    required String title,
    required String subtitle,
    required String badgeText,
    required Color badgeColor,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TekColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 11.5, color: TekColors.textSecondary)),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: badgeColor.withValues(alpha: 0.4), width: 0.8),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: badgeColor),
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              Icon(icon, size: 22, color: color.withValues(alpha: 0.7)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPnLEquityExplainerCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: const Color(0xFF8B5CF6).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_graph_rounded,
              color: Color(0xFF8B5CF6), size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Financial Accounting Classification (അക്കൗണ്ടിംഗ് തരംതിരിവ്)',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12.5,
                      color: Colors.white),
                ),
                const SizedBox(height: 3),
                RichText(
                  text: TextSpan(
                    style: const TextStyle(
                        fontSize: 11, color: TekColors.textSecondary),
                    children: [
                      const TextSpan(text: '• '),
                      TextSpan(
                        text:
                            '₹${_metrics.usedSalaryThisMonth.toStringAsFixed(0)} Owner Salary: ',
                        style: const TextStyle(
                            color: Color(0xFF10B981),
                            fontWeight: FontWeight.w600),
                      ),
                      const TextSpan(
                          text:
                              'Included in P&L as Operating Expense (OPEX).\n'),
                      const TextSpan(text: '• '),
                      TextSpan(
                        text:
                            '₹${_metrics.excessDrawingsThisMonth.toStringAsFixed(0)} Excess Drawings: ',
                        style: const TextStyle(
                            color: Color(0xFFA78BFA),
                            fontWeight: FontWeight.w600),
                      ),
                      const TextSpan(
                          text:
                              'Treated as Owner Equity withdrawal (does NOT reduce Store Net Profit).'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWithdrawalCard(OwnerWithdrawalItem item) {
    final isVoided = item.isVoided;
    final dateDisplay = DateFormat('dd MMM yyyy, hh:mm a').format(item.date);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isVoided
              ? TekColors.error.withValues(alpha: 0.4)
              : TekColors.border,
        ),
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
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: item.isCash
                          ? const Color(0xFF10B981).withValues(alpha: 0.15)
                          : const Color(0xFF00D4FF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      item.isCash
                          ? Icons.money_rounded
                          : Icons.account_balance_rounded,
                      size: 16,
                      color: item.isCash
                          ? const Color(0xFF10B981)
                          : const Color(0xFF00D4FF),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dateDisplay,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white),
                      ),
                      Text(
                        item.isCash
                            ? 'Cash in Hand (ക്യാഷ്)'
                            : 'Bank / UPI (ബാങ്ക്)',
                        style: const TextStyle(
                            fontSize: 10.5, color: TekColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
              Row(
                children: [
                  Text(
                    '₹${item.totalAmount.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      decoration: isVoided ? TextDecoration.lineThrough : null,
                      color: isVoided ? TekColors.textSecondary : Colors.white,
                    ),
                  ),
                  if (!isVoided) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded,
                          size: 18, color: TekColors.textSecondary),
                      tooltip: 'Void Withdrawal',
                      onPressed: () => _voidWithdrawal(item),
                    ),
                  ],
                ],
              ),
            ],
          ),

          const SizedBox(height: 10),
          const Divider(height: 1, color: TekColors.border),
          const SizedBox(height: 10),

          // Classification Breakdown Row
          Row(
            children: [
              if (item.hasSalary)
                Expanded(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color:
                              const Color(0xFF10B981).withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Owner Salary (OPEX)',
                            style: TextStyle(
                                fontSize: 9.5,
                                color: Color(0xFF10B981),
                                fontWeight: FontWeight.bold)),
                        Text('₹${item.salaryPortion.toStringAsFixed(0)}',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              if (item.isSplit) const SizedBox(width: 8),
              if (item.hasDrawings)
                Expanded(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFA78BFA).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color:
                              const Color(0xFFA78BFA).withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Owner Excess Drawings',
                            style: TextStyle(
                                fontSize: 9.5,
                                color: Color(0xFFA78BFA),
                                fontWeight: FontWeight.bold)),
                        Text('₹${item.drawingsPortion.toStringAsFixed(0)}',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white)),
                      ],
                    ),
                  ),
                ),
            ],
          ),

          if (item.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Notes: ${item.notes}',
              style: const TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: TekColors.textSecondary),
            ),
          ],

          if (isVoided) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: TekColors.error.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'VOIDED: ${item.voidReason ?? "Reversed"}',
                style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    color: TekColors.error),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
