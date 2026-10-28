import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../main.dart' show Db, rs;
import '../../utils/tek_helpers.dart';
import 'dashboard_tokens.dart';

/// Pixel-faithful Service Summary widget for TekFix ERP.
/// Displays live counts for:
/// - New Today (ഇന്ന് ലഭിച്ചത്)
/// - In Progress (വർക്ക് നടക്കുന്നു)
/// - Ready (ഡെലിവറിക്ക് തയ്യാർ)
/// - Pending Payments (പിരിഞ്ഞു കിട്ടാനുള്ളത്)
class TekServiceSummary extends StatelessWidget {
  final Function(String filter)? onSelectFilter;

  const TekServiceSummary({super.key, this.onSelectFilter});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Db.services.listenable(),
      builder: (context, Box box, _) {
        final jobs = entriesOf(box).map((e) => e.value).toList();

        final now = DateTime.now();
        int newTodayCount = 0;
        int inProgressCount = 0;
        int readyCount = 0;
        double pendingPaymentsTotal = 0;

        for (final j in jobs) {
          final dt = tekDt(j['createdAt']);
          if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
            newTodayCount++;
          }

          final status = '${j['status'] ?? ''}';
          if (status == 'In Progress' || status == 'Diagnosing' || status == 'Received') {
            inProgressCount++;
          } else if (status == 'Ready') {
            readyCount++;
          }

          if (j['billCreated'] != true && status != 'Cancelled') {
            final finalAmt = tekD(j['finalAmount']);
            final adv = tekD(j['advance']);
            final bal = (finalAmt - adv).clamp(0, double.infinity).toDouble();
            pendingPaymentsTotal += bal;
          }
        }

        final cards = [
          _ServiceStatItem(
            title: 'New Today',
            subtitle: 'ഇന്ന് ലഭിച്ചത്',
            value: '$newTodayCount',
            icon: Icons.build_rounded,
            accentColor: DashboardColors.neonBlue,
            onTap: () => onSelectFilter?.call('Today'),
          ),
          _ServiceStatItem(
            title: 'In Progress',
            subtitle: 'വർക്ക് നടക്കുന്നു',
            value: '$inProgressCount',
            icon: Icons.handyman_rounded,
            accentColor: DashboardColors.neonOrange,
            onTap: () => onSelectFilter?.call('Active'),
          ),
          _ServiceStatItem(
            title: 'Ready',
            subtitle: 'ഡെലിവറിക്ക് തയ്യാർ',
            value: '$readyCount',
            icon: Icons.task_alt_rounded,
            accentColor: DashboardColors.neonGreen,
            onTap: () => onSelectFilter?.call('Ready'),
          ),
          _ServiceStatItem(
            title: 'Pending Payments',
            subtitle: 'പിരിഞ്ഞു കിട്ടാനുള്ളത്',
            value: rs(pendingPaymentsTotal),
            icon: Icons.payments_rounded,
            accentColor: DashboardColors.neonPurple,
            onTap: () => onSelectFilter?.call('Unpaid'),
          ),
        ];

        return Container(
          padding: const EdgeInsets.all(18),
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
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: DashboardColors.neonPurple.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.build_circle_rounded,
                            color: DashboardColors.neonPurple,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Service & Repair Center',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DashboardTypography.poppins(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${jobs.length} total jobs',
                    style: DashboardTypography.inter(
                      fontSize: 11.5,
                      color: DashboardColors.textMuted,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // 2x2 or 4x1 responsive row
              LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 540;
                  final ratio = isWide
                      ? 1.6
                      : (constraints.maxWidth <= 360 ? 1.25 : 1.35);
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: cards.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: isWide ? 4 : 2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: ratio,
                    ),
                    itemBuilder: (context, i) => _buildStatTile(cards[i]),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatTile(_ServiceStatItem item) {
    return Material(
      color: const Color(0x1F22325E),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          HapticFeedback.lightImpact();
          item.onTap();
        },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: item.accentColor.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DashboardTypography.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70,
                    ),
                  ),
                  Icon(
                    item.icon,
                    size: 16,
                    color: item.accentColor,
                  ),
                ],
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  item.value,
                  style: DashboardTypography.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: item.accentColor,
                  ),
                ),
              ),
              Text(
                item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DashboardTypography.malayalam(
                  fontSize: 10,
                  color: DashboardColors.textMuted,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServiceStatItem {
  final String title;
  final String subtitle;
  final String value;
  final IconData icon;
  final Color accentColor;
  final VoidCallback onTap;

  _ServiceStatItem({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.icon,
    required this.accentColor,
    required this.onTap,
  });
}
