import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../main.dart' show Db, rs;
import '../../utils/tek_helpers.dart';
import 'dashboard_tokens.dart';

/// Pixel-faithful Recent Activity widget for TekFix ERP.
/// Displays list with icon, title, date/time, and status chip
/// (Returned, In Progress, Payment Received ₹, Stock Updated +qty),
/// with a "View All" link.
class TekRecentActivity extends StatelessWidget {
  final VoidCallback? onViewAll;

  const TekRecentActivity({
    super.key,
    this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    // 1. Gather recent activity items from real Hive data
    final items = <_ActivityItemModel>[];

    // Recent Sales
    for (var i = Db.sales.length - 1; i >= 0 && items.length < 8; i--) {
      final s = tekM(Db.sales.getAt(i));
      final isRet = isSaleReturned(s);
      final inv = s['invoice'] ?? 'INV';
      // Sales store the customer as 'partyName' (older bills: 'customerName').
      final rawCust = '${s['partyName'] ?? s['customerName'] ?? ''}'.trim();
      final cust = rawCust.isEmpty ? 'Walk-in Customer' : rawCust;
      // createdAt is a UTC ISO string — show it in local time.
      final dt = tekDt(s['createdAt']).toLocal();
      final total = tekD(s['total']);
      final due = tekD(s['due']);

      items.add(
        _ActivityItemModel(
          title: '$inv • $cust',
          subtitle: DateFormat('dd MMM yyyy, hh:mm a').format(dt),
          icon: isRet
              ? Icons.assignment_return_rounded
              : Icons.receipt_long_rounded,
          iconColor:
              isRet ? DashboardColors.neonPink : DashboardColors.neonGreen,
          statusLabel: isRet
              ? 'Returned'
              : (due > 0.005 ? 'Credit ${rs(due)}' : 'Paid ${rs(total)}'),
          statusColor: isRet
              ? DashboardColors.neonPink
              : (due > 0.005
                  ? DashboardColors.neonOrange
                  : DashboardColors.neonGreen),
          date: dt,
        ),
      );
    }

    // Recent Stock Moves
    for (var i = Db.stockMoves.length - 1; i >= 0 && items.length < 12; i--) {
      final sm = tekM(Db.stockMoves.getAt(i));
      final name = sm['itemName'] ?? 'Item';
      final delta = tekI(sm['delta']);
      final dt = tekDt(sm['date']).toLocal();

      items.add(
        _ActivityItemModel(
          title: '$name • Stock ${delta >= 0 ? 'In' : 'Out'}',
          subtitle: DateFormat('dd MMM yyyy, hh:mm a').format(dt),
          icon: Icons.inventory_2_rounded,
          iconColor: DashboardColors.neonBlue,
          statusLabel: delta >= 0 ? '+$delta' : '$delta',
          statusColor:
              delta >= 0 ? DashboardColors.neonBlue : DashboardColors.textMuted,
          date: dt,
        ),
      );
    }

    // Recent Audit Logs
    for (var i = Db.audit.length - 1; i >= 0 && items.length < 15; i--) {
      final a = tekM(Db.audit.getAt(i));
      final action = a['action'] ?? 'Action';
      final entity = a['entity'] ?? 'System';
      final dt = tekDt(a['date'] ?? a['timestamp']).toLocal();
      final user = a['user'] ?? 'Owner';
      final status = _auditStatus('$action');

      items.add(
        _ActivityItemModel(
          title: '$action • $entity',
          subtitle: '$user • ${DateFormat('dd MMM yyyy, hh:mm a').format(dt)}',
          icon: Icons.history_rounded,
          iconColor: DashboardColors.neonPurple,
          // Old code labelled every audit entry "In Progress", even
          // confirmed bills. Derive a real label from the action instead.
          statusLabel: status.$1,
          statusColor: status.$2,
          date: dt,
        ),
      );
    }

    // Sort by date descending
    items.sort((a, b) => b.date.compareTo(a.date));

    // Drop exact duplicates logged within 2 minutes of each other
    // (e.g. a purchase bill confirmed twice by a double tap).
    final displayItems = <_ActivityItemModel>[];
    for (final it in items) {
      final dup = displayItems.any((d) =>
          d.title == it.title &&
          d.statusLabel == it.statusLabel &&
          d.date.difference(it.date).inSeconds.abs() < 120);
      if (!dup) displayItems.add(it);
      if (displayItems.length >= 6) break;
    }

    return Container(
      decoration: BoxDecoration(
        color: DashboardColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DashboardColors.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header with Title & "View All" link
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Recent Activity',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DashboardTypography.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onViewAll,
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'View All',
                        style: DashboardTypography.inter(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: DashboardColors.neonBlue,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.arrow_forward_rounded,
                        size: 13,
                        color: DashboardColors.neonBlue,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1, thickness: 1, color: DashboardColors.border),

          // Items List using ListView.builder
          if (displayItems.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  'No recent activities recorded yet.',
                  style: DashboardTypography.inter(
                    color: DashboardColors.textMuted,
                    fontSize: 13,
                  ),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: displayItems.length,
              separatorBuilder: (_, __) => const Divider(
                height: 1,
                thickness: 1,
                color: DashboardColors.border,
                indent: 64,
              ),
              itemBuilder: (context, idx) {
                final item = displayItems[idx];
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  child: Row(
                    children: [
                      // Squircle Icon Badge
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: item.iconColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          item.icon,
                          color: item.iconColor,
                          size: 19,
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Title & Date
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DashboardTypography.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: DashboardColors.textWhite,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DashboardTypography.inter(
                                fontSize: 11.5,
                                color: DashboardColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 10),

                      // Status Chip
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: item.statusColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          item.statusLabel,
                          style: DashboardTypography.inter(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: item.statusColor,
                          ),
                        ),
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
}

class _ActivityItemModel {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final String statusLabel;
  final Color statusColor;
  final DateTime date;

  _ActivityItemModel({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.statusLabel,
    required this.statusColor,
    required this.date,
  });
}

/// Maps an audit action name to a short status label + colour.
(String, Color) _auditStatus(String action) {
  final a = action.toLowerCase();
  if (a.contains('delete') || a.contains('cancel')) {
    return ('Cancelled', DashboardColors.neonPink);
  }
  if (a.contains('return') || a.contains('refund')) {
    return ('Returned', DashboardColors.neonPink);
  }
  if (a.contains('confirm') ||
      a.contains('created') ||
      a.contains('paid') ||
      a.contains('received') ||
      a.contains('money in')) {
    return ('Done', DashboardColors.neonGreen);
  }
  if (a.contains('pending') || a.contains('draft')) {
    return ('Pending', DashboardColors.neonOrange);
  }
  return ('Updated', DashboardColors.neonBlue);
}
