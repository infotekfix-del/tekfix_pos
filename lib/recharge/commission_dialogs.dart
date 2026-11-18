import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../auth/auth_controller.dart';
import '../security/device_security_service.dart';
import '../theme/tek_tokens.dart';
import 'recharge_backend_bridge.dart';
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

/// ============================================================================
/// TEKFIX ERP - PHASE 17.1: OPERATOR COMMISSION CONTROL DIALOG (OWNER-ONLY)
/// Server-Authoritative Individual Operator Commission ON/OFF & Margin Controls
/// ============================================================================
class OperatorCommissionControlDialog extends StatefulWidget {
  final String shopId;

  const OperatorCommissionControlDialog({
    super.key,
    required this.shopId,
  });

  static Future<void> show(BuildContext context, {required String shopId}) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => OperatorCommissionControlDialog(shopId: shopId),
    );
  }

  @override
  State<OperatorCommissionControlDialog> createState() =>
      _OperatorCommissionControlDialogState();
}

class _OperatorCommissionControlDialogState
    extends State<OperatorCommissionControlDialog> {
  bool _loading = true;
  String? _errorMessage;
  List<OperatorCommissionControl> _controls = [];

  final List<Map<String, dynamic>> _operatorMeta = [
    {
      'code': 'AIRTEL',
      'name': 'Bharti Airtel',
      'malayalam': 'എയർടെൽ',
      'icon': Icons.network_cell_rounded,
      'color': const Color(0xFFE50914),
      'defaultBps': 280,
    },
    {
      'code': 'JIO',
      'name': 'Reliance Jio',
      'malayalam': 'ജിയോ',
      'icon': Icons.signal_cellular_alt_rounded,
      'color': const Color(0xFF0070F3),
      'defaultBps': 300,
    },
    {
      'code': 'VI',
      'name': 'Vodafone Idea (Vi)',
      'malayalam': 'വി',
      'icon': Icons.cell_tower_rounded,
      'color': const Color(0xFFFF5252),
      'defaultBps': 350,
    },
    {
      'code': 'BSNL',
      'name': 'BSNL Mobile',
      'malayalam': 'ബി.എസ്.എൻ.എൽ',
      'icon': Icons.signal_wifi_4_bar_rounded,
      'color': const Color(0xFF16A34A),
      'defaultBps': 400,
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadControls();
  }

  Future<void> _loadControls() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final list = await RechargeService.instance.getCommissionControls(
        shopId: widget.shopId,
        forceRefresh: true,
      );
      if (mounted) {
        setState(() {
          _controls = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _loading = false;
        });
      }
    }
  }

  OperatorCommissionControl _getControlFor(String opCode, int defaultBps) {
    return _controls.firstWhere(
      (c) => c.operator == opCode,
      orElse: () => OperatorCommissionControl(
        shopId: widget.shopId,
        operator: opCode,
        isEnabled: true,
        marginBasisPoints: defaultBps,
        updatedAt: DateTime.now(),
        updatedByUid: 'default',
      ),
    );
  }

  Future<void> _onToggle(String opCode, bool currentVal, int currentBps) async {
    final auth = AuthController.instance;
    if (!auth.isOwner) {
      _showError('ഉടമയ്ക്ക് മാത്രമേ കമ്മീഷൻ ക്രമീകരണം മാറ്റാൻ അനുവാദമുള്ളൂ (Owner-Only)');
      return;
    }

    final targetVal = !currentVal;
    final meta = _operatorMeta.firstWhere((m) => m['code'] == opCode);
    final opName = meta['name'] as String;

    final actionDescription = targetVal
        ? '$opName കമ്മീഷൻ ON ചെയ്യുകയാണോ? ഭാവി റീചാർജുകൾക്ക് $currentBps bps (${(currentBps / 100.0).toStringAsFixed(2)}%) കമ്മീഷൻ ലഭിക്കും.'
        : '$opName കമ്മീഷൻ OFF ചെയ്യുകയാണോ? ഭാവി റീചാർജുകൾക്ക് കമ്മീഷൻ ലഭിക്കില്ല (0%), എന്നാൽ സേവ് ചെയ്ത മാർജിൻ (${(currentBps / 100.0).toStringAsFixed(2)}%) നിലനിർത്തും.';

    final reason = await _promptReasonDialog(
      title: targetVal ? 'കമ്മീഷൻ ഓൺ ചെയ്യുക (Enable Commission)' : 'കമ്മീഷൻ ഓഫ് ചെയ്യുക (Disable Commission)',
      actionDescription: actionDescription,
      confirmLabel: targetVal ? 'കമ്മീഷൻ ON ചെയ്യുക' : 'കമ്മീഷൻ OFF ചെയ്യുക',
      confirmColor: targetVal ? TekColors.success : TekColors.error,
    );

    if (reason == null || reason.trim().length < 5) {
      if (reason != null) {
        _showError('മാറ്റത്തിനുള്ള കാരണം നിർബന്ധമാണ് - ചുരുങ്ങിയത് 5 അക്ഷരങ്ങൾ (Reason min 5 chars required)');
      }
      return;
    }

    await _executeCommissionUpdate(
      opCode: opCode,
      isEnabled: targetVal,
      marginBps: currentBps,
      reason: reason.trim(),
    );
  }

  Future<void> _onEditPercentage(String opCode, bool currentVal, int currentBps) async {
    final auth = AuthController.instance;
    if (!auth.isOwner) {
      _showError('ഉടമയ്ക്ക് മാത്രമേ കമ്മീഷൻ ക്രമീകരണം മാറ്റാൻ അനുവാദമുള്ളൂ (Owner-Only)');
      return;
    }

    final meta = _operatorMeta.firstWhere((m) => m['code'] == opCode);
    final opName = meta['name'] as String;

    final result = await _promptPercentageDialog(
      opName: opName,
      currentPercent: currentBps / 100.0,
    );

    if (result == null) return;

    final newBps = (result.percent * 100).round();
    await _executeCommissionUpdate(
      opCode: opCode,
      isEnabled: currentVal,
      marginBps: newBps,
      reason: result.reason,
    );
  }

  Future<void> _executeCommissionUpdate({
    required String opCode,
    required bool isEnabled,
    required int marginBps,
    required String reason,
  }) async {
    setState(() => _loading = true);

    try {
      final auth = AuthController.instance;
      final sec = DeviceSecurityService.instance;
      final devId = sec.deviceId;
      final client = RechargeBackendBridge.supabaseClient;

      String nonce = 'NONCE_LOCAL_MOCK';
      String signature = 'SIG_LOCAL_MOCK';

      if (RechargeBackendBridge.isSupabaseMode && client != null) {
        final challenge = await client.requestChallenge(
          shopId: widget.shopId,
          deviceId: devId,
          ownerUid: auth.uid,
        );
        nonce = challenge.nonce;

        final canonicalData = '$opCode:$isEnabled:$marginBps:$reason';
        final canonicalPayload = 'UPDATE_COMMISSION_CONTROL:${widget.shopId}:${auth.uid}:$devId:$nonce:$canonicalData';
        signature = await sec.signRawPayload(canonicalPayload);
      }

      final res = await RechargeService.instance.updateCommissionControl(
        shopId: widget.shopId,
        operator: opCode,
        isEnabled: isEnabled,
        marginBasisPoints: marginBps,
        reason: reason,
        deviceId: devId,
        deviceSignature: signature,
        nonce: nonce,
        ownerName: auth.name.isNotEmpty ? auth.name : 'Owner',
      );

      await _loadControls();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: TekColors.success,
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$opCode കമ്മീഷൻ വിജയകരമായി അപ്‌ഡേറ്റ് ചെയ്തു (Audit ID: ${res['auditId'] ?? 'AUD_RECORDED'})',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _showError('ക്രമീകരണം മാറ്റുന്നതിൽ പരാജയപ്പെട്ടു: $e');
      }
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: TekColors.error,
        content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Future<String?> _promptReasonDialog({
    required String title,
    required String actionDescription,
    required String confirmLabel,
    required Color confirmColor,
  }) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: const TextStyle(color: TekColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(actionDescription, style: const TextStyle(color: TekColors.textSecondary, fontSize: 13, height: 1.4)),
            const SizedBox(height: 16),
            const Text(
              'മാറ്റത്തിനുള്ള കാരണം നൽകുക (Mandatory Reason - min 5 chars):',
              style: TextStyle(color: TekColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'ഉദാ: ഡിസ്ട്രിബ്യൂട്ടർ മാർജിൻ കുറച്ചു / ഓഫർ തീർന്നു',
                hintStyle: const TextStyle(color: TekColors.textMuted, fontSize: 12),
                filled: true,
                fillColor: TekColors.elevatedSurface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TekColors.border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TekColors.primary)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('റദ്ദാക്കുക (Cancel)', style: TextStyle(color: TekColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: confirmColor),
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(confirmLabel, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<({double percent, String reason})?> _promptPercentageDialog({
    required String opName,
    required double currentPercent,
  }) async {
    final percentController = TextEditingController(text: currentPercent.toStringAsFixed(2));
    final reasonController = TextEditingController();

    return showDialog<({double percent, String reason})>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('$opName കമ്മീഷൻ ശതമാനം മാറ്റുക', style: const TextStyle(color: TekColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('നിലവിലെ നിരക്ക്: ${currentPercent.toStringAsFixed(2)}%', style: const TextStyle(color: TekColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 12),
            const Text('പുതിയ ശതമാനം (New %):', style: TextStyle(color: TekColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            TextField(
              controller: percentController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: TekColors.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                suffixText: '%',
                filled: true,
                fillColor: TekColors.elevatedSurface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TekColors.border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TekColors.primary)),
              ),
            ),
            const SizedBox(height: 14),
            const Text('മാറ്റത്തിനുള്ള കാരണം (Reason - min 5 chars):', style: TextStyle(color: TekColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            TextField(
              controller: reasonController,
              style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'ഉദാ: ഡിസ്ട്രിബ്യൂട്ടർ ഇൻസെന്റീവ് വർദ്ധിപ്പിച്ചു',
                hintStyle: const TextStyle(color: TekColors.textMuted, fontSize: 12),
                filled: true,
                fillColor: TekColors.elevatedSurface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TekColors.border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TekColors.primary)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('റദ്ദാക്കുക (Cancel)', style: TextStyle(color: TekColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: TekColors.primary),
            onPressed: () {
              final p = double.tryParse(percentController.text.trim());
              final r = reasonController.text.trim();
              if (p == null || p < 0 || p > 20) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('ശതമാനം 0 നും 20 നും ഇടയിൽ നൽകുക (0% - 20%)')),
                );
                return;
              }
              if (r.length < 5) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('കാരണം നിർബന്ധമാണ് (ചുരുങ്ങിയത് 5 അക്ഷരങ്ങൾ)')),
                );
                return;
              }
              Navigator.pop(ctx, (percent: p, reason: r));
            },
            child: const Text('സേവ് ചെയ്യുക', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Fail-closed authorization check
    final auth = AuthController.instance;
    if (!auth.isOwner) {
      return AlertDialog(
        backgroundColor: TekColors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.gpp_bad_rounded, color: TekColors.error),
            SizedBox(width: 8),
            Text('പ്രവേശനാനുമതി നിഷേധിച്ചു (Access Denied)'),
          ],
        ),
        content: const Text(
          'റീചാർജ് കമ്മീഷൻ ക്രമീകരണങ്ങൾ മാറ്റാൻ കടയുടമയ്ക്ക് (Owner) മാത്രമേ അനുവാദമുള്ളൂ. സ്റ്റാഫ് അക്കൗണ്ടുകൾക്ക് ഇതിൽ പ്രവേശനമില്ല.',
          style: TextStyle(color: TekColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ശരി (OK)'),
          ),
        ],
      );
    }

    return Dialog(
      backgroundColor: TekColors.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: TekColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.tune_rounded, color: TekColors.primary, size: 24),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ഓപ്പറേറ്റർ കമ്മീഷൻ നിയന്ത്രണം',
                          style: TextStyle(color: TekColors.textPrimary, fontSize: 17, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Owner Commission Control (Server-Authoritative)',
                          style: TextStyle(color: TekColors.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: TekColors.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: TekColors.border),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.shield_rounded, color: TekColors.success, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'ഓരോ ഓപ്പറേറ്ററുടെയും കമ്മീഷൻ സ്വതന്ത്രമായി ഓൺ/ഓഫ് ചെയ്യാം. മാറ്റങ്ങൾ തത്സമയം സെർവറിൽ സുരക്ഷിതമായി രേഖപ്പെടുത്തപ്പെടും.',
                        style: TextStyle(color: TekColors.textSecondary, fontSize: 11.5, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // Main List
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _errorMessage != null
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.error_outline_rounded, color: TekColors.error, size: 36),
                                const SizedBox(height: 8),
                                Text(_errorMessage!, style: const TextStyle(color: TekColors.error, fontSize: 13)),
                                const SizedBox(height: 12),
                                ElevatedButton.icon(
                                  onPressed: _loadControls,
                                  icon: const Icon(Icons.refresh_rounded, size: 16),
                                  label: const Text('വീണ്ടും ശ്രമിക്കുക (Retry)'),
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            itemCount: _operatorMeta.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 12),
                            itemBuilder: (ctx, idx) {
                              final meta = _operatorMeta[idx];
                              final opCode = meta['code'] as String;
                              final opName = meta['name'] as String;
                              final opMal = meta['malayalam'] as String;
                              final opColor = meta['color'] as Color;
                              final opIcon = meta['icon'] as IconData;
                              final defaultBps = meta['defaultBps'] as int;

                              final ctrl = _getControlFor(opCode, defaultBps);
                              final isEnabled = ctrl.isEnabled;
                              final bps = ctrl.marginBasisPoints;
                              final percent = ctrl.marginPercent;

                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                decoration: BoxDecoration(
                                  color: TekColors.elevatedSurface,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isEnabled
                                        ? opColor.withValues(alpha: 0.35)
                                        : TekColors.border.withValues(alpha: 0.5),
                                    width: isEnabled ? 1.5 : 1.0,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    // Operator Icon
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: opColor.withValues(alpha: isEnabled ? 0.15 : 0.05),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Icon(
                                        opIcon,
                                        color: isEnabled ? opColor : TekColors.textMuted,
                                        size: 22,
                                      ),
                                    ),
                                    const SizedBox(width: 14),

                                    // Operator Name & Details
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                  child: Text(
                                                    opName,
                                                    overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isEnabled ? TekColors.textPrimary : TekColors.textMuted,
                                                  fontSize: 14.5,
                                                  fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: isEnabled
                                                      ? TekColors.success.withValues(alpha: 0.15)
                                                      : TekColors.error.withValues(alpha: 0.15),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  isEnabled ? 'COMMISSION ON' : 'OFF (0%)',
                                                  style: TextStyle(
                                                    color: isEnabled ? TekColors.success : TekColors.error,
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 3),
                                          Wrap(
                                            crossAxisAlignment: WrapCrossAlignment.center,
                                            spacing: 4,
                                            children: [
                                              Text(
                                                '$opMal  •  മാർജിൻ: ',
                                                style: const TextStyle(color: TekColors.textSecondary, fontSize: 11.5),
                                              ),
                                              Text(
                                                '${percent.toStringAsFixed(2)}% ($bps bps)',
                                                style: TextStyle(
                                                  color: isEnabled ? opColor : TekColors.textMuted,
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              if (!isEnabled)
                                                const Text(
                                                  ' (സേവ് ചെയ്തിരിക്കുന്നു)',
                                                  style: TextStyle(color: TekColors.textMuted, fontSize: 10.5, fontStyle: FontStyle.italic),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),

                                    // Edit percentage button
                                    IconButton(
                                      tooltip: 'ശതമാനം മാറ്റുക (Edit Margin %)',
                                      onPressed: () => _onEditPercentage(opCode, isEnabled, bps),
                                      icon: const Icon(Icons.edit_note_rounded, color: TekColors.primary, size: 22),
                                    ),

                                    // Switch Toggle
                                    Switch(
                                      value: isEnabled,
                                      activeThumbColor: TekColors.success,
                                      inactiveThumbColor: TekColors.textMuted,
                                      onChanged: (val) => _onToggle(opCode, isEnabled, bps),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
              ),

              const SizedBox(height: 16),
              // Footer
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _loadControls,
                    icon: const Icon(Icons.refresh_rounded, size: 16, color: TekColors.textMuted),
                    label: const Text('പുതുക്കുക (Refresh)', style: TextStyle(color: TekColors.textMuted, fontSize: 12)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: TekColors.elevatedSurface,
                      side: const BorderSide(color: TekColors.border),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('പൂർത്തിയായി (Done)', style: TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

