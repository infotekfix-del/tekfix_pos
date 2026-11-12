import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme/tek_tokens.dart';
import 'recharge_models.dart';
import 'recharge_service.dart';

/// Modal Dialog to Enter / Record Recharge Commission
class CommissionEntryDialog extends StatefulWidget {
  final String shopId;
  final String staffId;
  final String staffName;
  final RechargeOperator? initialOperator;

  const CommissionEntryDialog({
    super.key,
    required this.shopId,
    required this.staffId,
    required this.staffName,
    this.initialOperator,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String shopId,
    required String staffId,
    required String staffName,
    RechargeOperator? initialOperator,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => CommissionEntryDialog(
        shopId: shopId,
        staffId: staffId,
        staffName: staffName,
        initialOperator: initialOperator,
      ),
    );
  }

  @override
  State<CommissionEntryDialog> createState() => _CommissionEntryDialogState();
}

class _CommissionEntryDialogState extends State<CommissionEntryDialog> {
  late RechargeOperator _operator;
  RechargeCommissionType _commissionType = RechargeCommissionType.postpaid;
  CommissionStatus _status = CommissionStatus.confirmed;
  CommissionSettlementMethod _settlementMethod =
      CommissionSettlementMethod.distributorDiscount;

  final _amountController = TextEditingController();
  final _refController = TextEditingController();
  final _rechargeIdController = TextEditingController();
  final _notesController = TextEditingController();

  String _selectedDistId = 'DIST_APEX_AIRTEL';
  bool _submitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _operator = widget.initialOperator ?? RechargeOperator.airtel;
  }

  @override
  void dispose() {
    _amountController.dispose();
    _refController.dispose();
    _rechargeIdController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amt = double.tryParse(_amountController.text.trim()) ?? 0.0;
    if (amt <= 0) {
      setState(() =>
          _errorMessage = 'സാധുവായ കമ്മീഷൻ തുക നൽകുക (Enter valid commission amount)');
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final dist = DistributorItem.defaultPresets.firstWhere(
        (d) => d.id == _selectedDistId,
        orElse: () => DistributorItem.defaultPresets.first,
      );

      await RechargeService.instance.recordPostpaidCommission(
        shopId: widget.shopId,
        operator: _operator,
        amount: amt,
        status: _status,
        staffId: widget.staffId,
        staffName: widget.staffName,
        distributorId: dist.id,
        distributorName: dist.name,
        rechargeId: _rechargeIdController.text.trim().isNotEmpty
            ? _rechargeIdController.text.trim()
            : null,
        referenceNumber: _refController.text.trim().isNotEmpty
            ? _refController.text.trim()
            : null,
        settlementMethod: _settlementMethod,
        notes: _notesController.text.trim().isNotEmpty
            ? _notesController.text.trim()
            : 'Commission from ${dist.name}',
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '₹${amt.toStringAsFixed(2)} കമ്മീഷൻ രേഖപ്പെടുത്തി (Commission recorded)',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: TekColors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _errorMessage = e.toString().replaceAll('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: TekColors.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Row(
        children: [
          Icon(Icons.percent_rounded, color: TekColors.electricCyan),
          SizedBox(width: 10),
          Text(
            'Record Recharge Commission',
            style: TextStyle(
              color: TekColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Operator Selection
              const Text('Operator / ടെലികോം ഓപ്പറേറ്റർ:',
                  style:
                      TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: TekColors.borderSubtle),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<RechargeOperator>(
                    value: _operator,
                    isExpanded: true,
                    dropdownColor: TekColors.cardBg,
                    items: RechargeOperator.values.map((op) {
                      return DropdownMenuItem(
                        value: op,
                        child: Text(
                          '${op.displayName} (${op.malayalam})',
                          style: const TextStyle(
                              color: TekColors.textPrimary, fontSize: 13),
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _operator = val);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Distributor Selection
              const Text('Distributor / വിതരണക്കാരൻ:',
                  style:
                      TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: TekColors.borderSubtle),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedDistId,
                    isExpanded: true,
                    dropdownColor: TekColors.cardBg,
                    items: DistributorItem.defaultPresets.map((d) {
                      return DropdownMenuItem(
                        value: d.id,
                        child: Text(
                          d.name,
                          style: const TextStyle(
                              color: TekColors.textPrimary, fontSize: 12.5),
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedDistId = val);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Commission Type Selector
              const Text('Commission Type / കമ്മീഷൻ തരം:',
                  style:
                      TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              Row(
                children: [
                  _buildTypeChip(RechargeCommissionType.postpaid,
                      'Postpaid Margin', TekColors.electricCyan),
                  const SizedBox(width: 8),
                  _buildTypeChip(RechargeCommissionType.prepaid,
                      'Prepaid Load', TekColors.primaryLight),
                ],
              ),
              const SizedBox(height: 14),

              // Commission Amount
              const Text('Commission Amount / കമ്മീഷൻ തുക (₹):',
                  style:
                      TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: _amountController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  prefixText: '₹ ',
                  prefixStyle: const TextStyle(
                      color: TekColors.electricCyan,
                      fontWeight: FontWeight.bold),
                  filled: true,
                  fillColor: TekColors.elevatedSurface,
                  hintText: 'e.g. 50',
                  hintStyle: const TextStyle(color: TekColors.textMuted),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TekColors.borderSubtle),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Status Selector
              const Text('Commission Recognition Status:',
                  style:
                      TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              Row(
                children: [
                  _buildStatusChip(CommissionStatus.confirmed, 'Confirmed Income',
                      TekColors.success),
                  const SizedBox(width: 8),
                  _buildStatusChip(CommissionStatus.pending, 'Pending Accrual',
                      TekColors.warning),
                ],
              ),
              const SizedBox(height: 14),

              // Settlement Method
              const Text('Realization Method / ലഭിക്കുന്ന വഴി:',
                  style:
                      TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: TekColors.borderSubtle),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<CommissionSettlementMethod>(
                    value: _settlementMethod,
                    isExpanded: true,
                    dropdownColor: TekColors.cardBg,
                    items: CommissionSettlementMethod.values.map((m) {
                      return DropdownMenuItem(
                        value: m,
                        child: Text(
                          '${m.label} (${m.malayalam})',
                          style: const TextStyle(
                              color: TekColors.textPrimary, fontSize: 12.5),
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _settlementMethod = val);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Reference / Voucher
              TextField(
                controller: _refController,
                style:
                    const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Voucher / Settlement Ref No (Optional)',
                  labelStyle: const TextStyle(
                      color: TekColors.textSecondary, fontSize: 12),
                  filled: true,
                  fillColor: TekColors.elevatedSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),

              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: TekColors.error, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel',
              style: TextStyle(color: TekColors.textSecondary)),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: TekColors.electricCyan,
            foregroundColor: Colors.black,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: _submitting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black),
                )
              : const Text('Save Commission'),
        ),
      ],
    );
  }

  Widget _buildTypeChip(
      RechargeCommissionType type, String label, Color activeColor) {
    final isSelected = _commissionType == type;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _commissionType = type),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? activeColor.withValues(alpha: 0.15)
                : TekColors.elevatedSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? activeColor : TekColors.borderSubtle,
              width: isSelected ? 1.6 : 1.0,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: isSelected ? activeColor : TekColors.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(
      CommissionStatus status, String label, Color activeColor) {
    final isSelected = _status == status;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _status = status),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? activeColor.withValues(alpha: 0.15)
                : TekColors.elevatedSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? activeColor : TekColors.borderSubtle,
              width: isSelected ? 1.6 : 1.0,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: isSelected ? activeColor : TekColors.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Comprehensive Commission Reporting Dialog
class CommissionReportDialog extends StatefulWidget {
  final String shopId;

  const CommissionReportDialog({super.key, required this.shopId});

  static void show(BuildContext context, {required String shopId}) {
    showDialog<void>(
      context: context,
      builder: (ctx) => CommissionReportDialog(shopId: shopId),
    );
  }

  @override
  State<CommissionReportDialog> createState() => _CommissionReportDialogState();
}

class _CommissionReportDialogState extends State<CommissionReportDialog> {
  bool _loading = true;
  CommissionDashboardSummary? _summary;
  List<RechargeCommissionEntry> _entries = [];
  RechargeOperator? _selectedOperatorFilter;
  CommissionStatus? _selectedStatusFilter;

  final currency = NumberFormat.currency(locale: 'en_IN', symbol: '₹');
  final dateFormat = DateFormat('dd MMM yyyy, hh:mm a');

  @override
  void initState() {
    super.initState();
    _loadReport();
  }

  Future<void> _loadReport() async {
    setState(() => _loading = true);
    final summary = await RechargeService.instance
        .getCommissionDashboardSummary(shopId: widget.shopId);
    final list = await RechargeService.instance.getCommissionReport(
      shopId: widget.shopId,
      operator: _selectedOperatorFilter,
      status: _selectedStatusFilter,
    );

    if (mounted) {
      setState(() {
        _summary = summary;
        _entries = list;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: TekColors.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.trending_up_rounded,
                          color: TekColors.electricCyan, size: 24),
                      SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Recharge Commission & Margin Report',
                            style: TextStyle(
                              color: TekColors.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'റീചാർജ് ലാഭവിഹിതം & കമ്മീഷൻ വരുമാന റിപ്പോർട്ട്',
                            style: TextStyle(
                              color: TekColors.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'Commission report exported to PDF & Excel queue!'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        icon: const Icon(Icons.download_rounded, size: 16),
                        label: const Text('Export PDF / Excel',
                            style: TextStyle(fontSize: 12)),
                        style: FilledButton.styleFrom(
                          backgroundColor: TekColors.elevatedSurface,
                          foregroundColor: TekColors.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded,
                            color: TekColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 18),

              // KPI Cards Grid
              Row(
                children: [
                  _buildKpiCard("Today's Commission",
                      currency.format(_summary?.todayConfirmed ?? 0.0),
                      TekColors.success, Icons.today_rounded),
                  const SizedBox(width: 10),
                  _buildKpiCard("Monthly Commission",
                      currency.format(_summary?.monthlyConfirmed ?? 0.0),
                      TekColors.electricCyan, Icons.calendar_month_rounded),
                  const SizedBox(width: 10),
                  _buildKpiCard("Pending Commission",
                      currency.format(_summary?.pendingCommission ?? 0.0),
                      TekColors.warning, Icons.hourglass_top_rounded),
                  const SizedBox(width: 10),
                  _buildKpiCard("Total Confirmed",
                      currency.format(_summary?.confirmedCommission ?? 0.0),
                      const Color(0xFFA855F7), Icons.check_circle_rounded),
                ],
              ),
              const SizedBox(height: 16),

              // Operator Breakdown Row
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: TekColors.borderSubtle),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildOperatorStat('Airtel', _summary?.airtelCommission ?? 0.0,
                        const Color(0xFFEF4444)),
                    _buildOperatorStat(
                        'Jio', _summary?.jioCommission ?? 0.0, const Color(0xFF3B82F6)),
                    _buildOperatorStat(
                        'Vi', _summary?.viCommission ?? 0.0, const Color(0xFFF59E0B)),
                    _buildOperatorStat(
                        'BSNL', _summary?.bsnlCommission ?? 0.0, const Color(0xFF10B981)),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Filter Row
              Row(
                children: [
                  const Text('Filter by Operator:',
                      style: TextStyle(
                          color: TekColors.textSecondary, fontSize: 11)),
                  const SizedBox(width: 8),
                  DropdownButton<RechargeOperator?>(
                    value: _selectedOperatorFilter,
                    dropdownColor: TekColors.cardBg,
                    hint: const Text('All Operators',
                        style: TextStyle(
                            color: TekColors.textMuted, fontSize: 11)),
                    items: [
                      const DropdownMenuItem(
                          value: null,
                          child: Text('All Operators',
                              style: TextStyle(
                                  color: TekColors.textPrimary,
                                  fontSize: 11))),
                      ...RechargeOperator.values.map((op) => DropdownMenuItem(
                          value: op,
                          child: Text(op.displayName,
                              style: const TextStyle(
                                  color: TekColors.textPrimary,
                                  fontSize: 11)))),
                    ],
                    onChanged: (val) {
                      setState(() => _selectedOperatorFilter = val);
                      _loadReport();
                    },
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _loadReport,
                    icon: const Icon(Icons.refresh_rounded,
                        color: TekColors.electricCyan, size: 20),
                    tooltip: 'Refresh Data',
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Ledger Table / List
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _entries.isEmpty
                        ? const Center(
                            child: Text(
                              'കമ്മീഷൻ എൻട്രികൾ ലഭ്യമല്ല (No commission entries found)',
                              style: TextStyle(color: TekColors.textMuted),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _entries.length,
                            separatorBuilder: (_, __) => const Divider(
                                height: 10, color: TekColors.borderSubtle),
                            itemBuilder: (context, i) {
                              final item = _entries[i];
                              final isConfirmed =
                                  item.status != CommissionStatus.pending;

                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: CircleAvatar(
                                  backgroundColor: isConfirmed
                                      ? TekColors.success
                                          .withValues(alpha: 0.15)
                                      : TekColors.warning
                                          .withValues(alpha: 0.15),
                                  child: Icon(
                                    isConfirmed
                                        ? Icons.check_circle_rounded
                                        : Icons.hourglass_top_rounded,
                                    color: isConfirmed
                                        ? TekColors.success
                                        : TekColors.warning,
                                    size: 18,
                                  ),
                                ),
                                title: Text(
                                  '${item.operator.displayName}: ${item.notes.isNotEmpty ? item.notes : item.commissionType.label}',
                                  style: const TextStyle(
                                      color: TekColors.textPrimary,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700),
                                ),
                                subtitle: Text(
                                  '${dateFormat.format(item.receivedDate)} • ${item.settlementMethod.label}',
                                  style: const TextStyle(
                                      color: TekColors.textMuted,
                                      fontSize: 10.5),
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      '+${currency.format(item.amount)}',
                                      style: TextStyle(
                                        color: isConfirmed
                                            ? TekColors.success
                                            : TekColors.warning,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 13.5,
                                      ),
                                    ),
                                    Text(
                                      item.status.label,
                                      style: TextStyle(
                                        color: isConfirmed
                                            ? TekColors.success
                                            : TekColors.warning,
                                        fontSize: 9.5,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKpiCard(
      String title, String value, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: TekColors.elevatedSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: TekColors.textSecondary, fontSize: 10.5)),
                Icon(icon, color: color, size: 14),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                  color: color, fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOperatorStat(String name, double val, Color color) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text('$name: ',
            style:
                const TextStyle(color: TekColors.textSecondary, fontSize: 11)),
        Text(
          currency.format(val),
          style: TextStyle(
              color: color, fontSize: 11.5, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
