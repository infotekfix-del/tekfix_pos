import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show toast;
import '../theme/tek_tokens.dart';
import 'expense_cleanup_service.dart';

class _CleanupColors {
  static const Color neonOrange = Color(0xFFF59E0B);
  static const Color neonGreen = Color(0xFF10B981);
}

class ExpenseCleanupDialog extends StatefulWidget {
  final String shopId;

  const ExpenseCleanupDialog({super.key, required this.shopId});

  static Future<void> show(BuildContext context, {required String shopId}) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 800),
          child: ExpenseCleanupDialog(shopId: shopId),
        ),
      ),
    );
  }

  @override
  State<ExpenseCleanupDialog> createState() => _ExpenseCleanupDialogState();
}

class _ExpenseCleanupDialogState extends State<ExpenseCleanupDialog> {
  bool _scanning = true;
  bool _executing = false;
  List<ExpenseDuplicateGroup> _duplicateGroups = [];
  final Set<String> _selectedToDelete = {};
  CleanupExecutionResult? _result;

  @override
  void initState() {
    super.initState();
    _runDryScan();
  }

  Future<void> _runDryScan() async {
    setState(() {
      _scanning = true;
      _result = null;
      _selectedToDelete.clear();
    });

    try {
      final groups = await ExpenseCleanupService.instance
          .scanDuplicates(shopId: widget.shopId);

      // By default, select all duplicate items (skip the oldest item in each group)
      for (final g in groups) {
        for (final dup in g.duplicateItems) {
          _selectedToDelete.add(dup.id);
        }
      }

      if (mounted) {
        setState(() {
          _duplicateGroups = groups;
          _scanning = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _scanning = false);
        toast(context, 'Scan failed: $e', error: true);
      }
    }
  }

  Future<void> _confirmAndExecute() async {
    if (_selectedToDelete.isEmpty) {
      toast(context, 'No duplicate records selected for deletion.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: TekColors.border),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: _CleanupColors.neonOrange, size: 24),
            SizedBox(width: 10),
            Text('Confirm Cleanup & Backup'),
          ],
        ),
        content: Text(
          'You are about to delete ${_selectedToDelete.length} duplicate expense records.\n\n'
          '• Selected documents will be exported to "expense_cleanup_backup" first.\n'
          '• Duplicate debits in the accounting ledger will be cleaned.\n'
          '• This action is permanent and audited under your account.',
          style: const TextStyle(fontSize: 13, color: TekColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: TekColors.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TekColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Backup & Delete Duplicates'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _executing = true);

    try {
      final auth = context.read<AuthController>();
      final res = await ExpenseCleanupService.instance.executeCleanup(
        shopId: widget.shopId,
        duplicateDocIdsToDelete: _selectedToDelete.toList(),
        deletedByUid: auth.uid,
        deletedByName: auth.name.isNotEmpty ? auth.name : 'Owner',
      );

      if (mounted) {
        setState(() {
          _result = res;
          _executing = false;
        });
        toast(
          context,
          'Cleanup complete: ${res.documentsDeleted} duplicate records removed.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _executing = false);
        toast(context, 'Cleanup failed: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: TekColors.mainBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: TekColors.border, width: 1.5),
        boxShadow: TekColors.cardShadow,
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _CleanupColors.neonOrange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.cleaning_services_rounded,
                    color: _CleanupColors.neonOrange, size: 22),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Expense Deduplication & Cleanup',
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.bold,
                        color: TekColors.textPrimary,
                      ),
                    ),
                    Text(
                      'Owner-only tool: Scans & eliminates duplicate entries with automatic backup',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: TekColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: TekColors.textSecondary),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(color: TekColors.border, height: 1),
          const SizedBox(height: 14),

          // Body
          Expanded(
            child: _scanning
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: TekColors.primary),
                        SizedBox(height: 16),
                        Text('Scanning expenses for duplicate entries...',
                            style: TextStyle(color: TekColors.textSecondary)),
                      ],
                    ),
                  )
                : _result != null
                    ? _buildResultView()
                    : _buildScanResultsList(),
          ),

          // Footer Actions
          if (!_scanning && _result == null) ...[
            const SizedBox(height: 14),
            const Divider(color: TekColors.border, height: 1),
            const SizedBox(height: 14),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _executing ? null : _runDryScan,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Re-scan'),
                ),
                const Spacer(),
                TextButton(
                  onPressed:
                      _executing ? null : () => Navigator.pop(context),
                  child: const Text('Cancel',
                      style: TextStyle(color: TekColors.textSecondary)),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _selectedToDelete.isNotEmpty
                        ? TekColors.error
                        : TekColors.primary,
                  ),
                  onPressed: (_executing || _selectedToDelete.isEmpty)
                      ? null
                      : _confirmAndExecute,
                  icon: _executing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_sweep_rounded, size: 18),
                  label: Text(_executing
                      ? 'Cleaning up...'
                      : 'Delete ${_selectedToDelete.length} Duplicates'),
                ),
              ],
            ),
          ] else if (_result != null) ...[
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Done'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScanResultsList() {
    if (_duplicateGroups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _CleanupColors.neonGreen.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.verified_rounded,
                  color: _CleanupColors.neonGreen, size: 48),
            ),
            const SizedBox(height: 16),
            const Text(
              'No Duplicate Expenses Found!',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: TekColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'All expense records have unique timestamps and document IDs.',
              style: TextStyle(fontSize: 12.5, color: TekColors.textSecondary),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _duplicateGroups.length,
      itemBuilder: (ctx, i) {
        final group = _duplicateGroups[i];
        final oldest = group.oldestItem;
        final timeFormat = DateFormat('dd MMM yyyy, hh:mm:ss a');

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: TekColors.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: TekColors.border),
          ),
          child: ExpansionTile(
            initiallyExpanded: true,
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            title: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: TekColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    group.category,
                    style: const TextStyle(
                        fontSize: 11,
                        color: TekColors.primary,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    group.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: TekColors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '₹${group.amount.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14.5,
                    color: Color(0xFFF43F5E),
                  ),
                ),
              ],
            ),
            subtitle: Text(
              '${group.items.length} duplicate entries created within 5s • Recorded by: ${group.recordedByName}',
              style: const TextStyle(
                  fontSize: 11.5, color: TekColors.textSecondary),
            ),
            children: [
              const Divider(color: TekColors.border, height: 1),
              // Oldest entry (preserved by default)
              ListTile(
                dense: true,
                leading: const Icon(Icons.lock_clock_rounded,
                    color: _CleanupColors.neonGreen, size: 20),
                title: Text(
                  'Keep Oldest: Doc ID ${oldest.id}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12.5,
                      color: _CleanupColors.neonGreen),
                ),
                subtitle: Text(
                  'Created: ${timeFormat.format(oldest.createdAt ?? oldest.expenseDate)}',
                  style: const TextStyle(
                      fontSize: 11, color: TekColors.textSecondary),
                ),
                trailing: const Chip(
                  label: Text('PRESERVED',
                      style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                          color: _CleanupColors.neonGreen)),
                  backgroundColor: Color(0x1F10B981),
                  padding: EdgeInsets.zero,
                ),
              ),
              // Duplicate newer entries with checkboxes
              for (final dup in group.duplicateItems)
                CheckboxListTile(
                  dense: true,
                  activeColor: TekColors.error,
                  value: _selectedToDelete.contains(dup.id),
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        _selectedToDelete.add(dup.id);
                      } else {
                        _selectedToDelete.remove(dup.id);
                      }
                    });
                  },
                  secondary: const Icon(Icons.copy_rounded,
                      color: TekColors.error, size: 18),
                  title: Text(
                    'Duplicate: Doc ID ${dup.id}',
                    style: const TextStyle(
                        fontSize: 12, color: TekColors.textPrimary),
                  ),
                  subtitle: Text(
                    'Created: ${timeFormat.format(dup.createdAt ?? dup.expenseDate)} (+${((dup.createdAt ?? dup.expenseDate).difference(oldest.createdAt ?? oldest.expenseDate).inMilliseconds / 1000).toStringAsFixed(1)}s)',
                    style: const TextStyle(
                        fontSize: 11, color: TekColors.textSecondary),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildResultView() {
    final r = _result!;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _CleanupColors.neonGreen.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  color: _CleanupColors.neonGreen, size: 54),
            ),
            const SizedBox(height: 14),
            const Text(
              'Deduplication Successfully Executed!',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: TekColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${r.documentsDeleted} duplicate documents backed up and deleted safely.',
              style: const TextStyle(
                  fontSize: 13, color: TekColors.textSecondary),
            ),
            const SizedBox(height: 20),

            // Summary Table
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: TekColors.bgCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: TekColors.border),
              ),
              child: Column(
                children: [
                  _summaryRow(
                    'Cleaned Duplicate Amount',
                    '₹${r.amountCleaned.toStringAsFixed(2)}',
                    isHighlight: true,
                  ),
                  const Divider(color: TekColors.border, height: 16),
                  _summaryRow(
                    'Today\'s Expenses (Before → After)',
                    '₹${r.beforeMetrics.todayTotal.toStringAsFixed(2)} → ₹${r.afterMetrics.todayTotal.toStringAsFixed(2)}',
                  ),
                  const Divider(color: TekColors.border, height: 16),
                  _summaryRow(
                    'This Month\'s Expenses (Before → After)',
                    '₹${r.beforeMetrics.thisMonthTotal.toStringAsFixed(2)} → ₹${r.afterMetrics.thisMonthTotal.toStringAsFixed(2)}',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(String label, String value, {bool isHighlight = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            color: isHighlight
                ? _CleanupColors.neonOrange
                : TekColors.textSecondary,
            fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.bold,
            color: isHighlight
                ? _CleanupColors.neonOrange
                : TekColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

