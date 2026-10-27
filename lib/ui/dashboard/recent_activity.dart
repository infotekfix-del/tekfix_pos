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
      final cust = s['customerName'] ?? 'Walk-in Customer';
      final dt = tekDt(s['createdAt']);
      final total = tekD(s['total']);

      items.add(
        _ActivityItemModel(
          title: '$inv • $cust',
          subtitle: DateFormat('dd MMM yyyy, hh:mm a').format(dt),
          icon: isRet ? Icons.assignment_return_rounded : Icons.receipt_long_rounded,
          iconColor: isRet ? DashboardColors.neonPink : DashboardColors.neonGreen,
          statusLabel: isRet ? 'Returned' : 'Payment Received ${rs(total)}',
          statusColor: isRet ? DashboardColors.neonPink : DashboardColors.neonGreen,
          date: dt,
        ),
      );
    }

    // Recent Stock Moves
    for (var i = Db.stockMoves.length - 1; i >= 0 && items.length < 12; i--) {
      final sm = tekM(Db.stockMoves.getAt(i));
      final name = sm['itemName'] ?? 'Item';
      final delta = tekI(sm['delta']);
      final dt = tekDt(sm['date']);

      items.add(
        _ActivityItemModel(
          title: '$name • Stock Move',
          subtitle: DateFormat('dd MMM yyyy, hh:mm a').format(dt),
          icon: Icons.inventory_2_rounded,
          iconColor: DashboardColors.neonBlue,
          statusLabel: delta >= 0 ? 'Stock Updated +$delta' : 'Stock Updated $delta',
          statusColor: DashboardColors.neonBlue,
          date: dt,
        ),
      );
    }

    // Recent Audit Logs
    for (var i = Db.audit.length - 1; i >= 0 && items.length < 15; i--) {
      final a = tekM(Db.audit.getAt(i));
      final action = a['action'] ?? 'Action';
      final entity = a['entity'] ?? 'System';
      final dt = tekDt(a['date']);
      final user = a['user'] ?? 'Owner';

      items.add(
        _ActivityItemModel(
          title: '$action • $entity',
          subtitle: '$user • ${DateFormat('dd MMM yyyy, hh:mm a').format(dt)}',
          icon: Icons.history_rounded,
          iconColor: DashboardColors.neonPurple,
          statusLabel: 'In Progress',
          statusColor: DashboardColors.neonOrange,
          date: dt,
        ),
      );
    }

    // Sort by date descending
    items.sort((a, b) => b.date.compareTo(a.date));
    final displayItems = items.take(6).toList();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0x1F182652),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0x2BFFFFFF),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
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
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: DashboardColors.neonBlue.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.access_time_filled_rounded,
                        color: DashboardColors.neonBlue,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Recent Activity',
                      style: DashboardTypography.poppins(
                        fontSize: 15.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: onViewAll,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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

          const Divider(height: 1, thickness: 1, color: Color(0x14FFFFFF)),

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
                color: Color(0x14FFFFFF),
                indent: 64,
              ),
              itemBuilder: (context, idx) {
                final item = displayItems[idx];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  child: Row(
                    children: [
                      // Squircle Icon Badge
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: item.iconColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: item.iconColor.withValues(alpha: 0.3),
                            width: 1,
                          ),
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
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.subtitle,
                              style: DashboardTypography.inter(
                                fontSize: 11,
                                color: DashboardColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 10),

                      // Status Chip
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: item.statusColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: item.statusColor.withValues(alpha: 0.35),
                            width: 1,
                          ),
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
