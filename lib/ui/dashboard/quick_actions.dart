import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dashboard_tokens.dart';

/// Quick Actions grid (v2): flat tiles with one accent colour.
/// "New Sale" lives in the dashboard header as the primary button, so it is
/// no longer duplicated here ([onNewSale] is kept for API compatibility).
class TekQuickActionsGrid extends StatelessWidget {
  final VoidCallback onNewSale;
  final VoidCallback onAddItem;
  final VoidCallback onServiceRequest;
  final VoidCallback onAddCustomer;
  final VoidCallback onViewReports;
  final VoidCallback onOpenSettings;
  final VoidCallback? onAddExpense;
  final VoidCallback? onDailyRent;
  final VoidCallback? onOwnerWithdrawal;
  final VoidCallback? onRecharge;

  const TekQuickActionsGrid({
    super.key,
    required this.onNewSale,
    required this.onAddItem,
    required this.onServiceRequest,
    required this.onAddCustomer,
    required this.onViewReports,
    required this.onOpenSettings,
    this.onAddExpense,
    this.onDailyRent,
    this.onOwnerWithdrawal,
    this.onRecharge,
  });

  @override
  Widget build(BuildContext context) {
    final actions = [
      if (onRecharge != null)
        _ActionTileData(
          title: 'Recharge',
          subtitle: 'റീചാർജ്',
          icon: Icons.phone_android_rounded,
          gradient: const LinearGradient(
            colors: [Color(0xFF06B6D4), Color(0xFF0891B2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          glowColor: const Color(0xFF06B6D4),
          onTap: onRecharge!,
        ),
      _ActionTileData(
        title: 'Add Item',
        subtitle: 'സാധനം ചേർക്കുക',
        icon: Icons.add_box_rounded,
        gradient: const LinearGradient(
          colors: [Color(0xFF10B981), Color(0xFF059669)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        glowColor: DashboardColors.neonGreen,
        onTap: onAddItem,
      ),
      if (onAddExpense != null)
        _ActionTileData(
          title: 'Add Expense',
          subtitle: 'ചിലവുകൾ രേഖപ്പെടുത്തുക',
          icon: Icons.receipt_long_rounded,
          gradient: const LinearGradient(
            colors: [Color(0xFFF43F5E), Color(0xFFBE123C)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          glowColor: const Color(0xFFF43F5E),
          onTap: onAddExpense!,
        ),
      if (onDailyRent != null)
        _ActionTileData(
          title: 'Daily Rent',
          subtitle: 'കട വാടക',
          icon: Icons.store_mall_directory_rounded,
          gradient: const LinearGradient(
            colors: [Color(0xFFF59E0B), Color(0xFFB45309)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          glowColor: const Color(0xFFF59E0B),
          onTap: onDailyRent!,
        ),
      if (onOwnerWithdrawal != null)
        _ActionTileData(
          title: 'Owner Withdrawal',
          subtitle: 'ഉടമയുടെ പിൻവലിക്കൽ',
          icon: Icons.account_balance_wallet_rounded,
          gradient: const LinearGradient(
            colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          glowColor: const Color(0xFF8B5CF6),
          onTap: onOwnerWithdrawal!,
        ),
      _ActionTileData(
        title: 'Service Request',
        subtitle: 'സർവീസ് റിപ്പയർ',
        icon: Icons.build_circle_rounded,
        gradient: const LinearGradient(
          colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        glowColor: DashboardColors.neonOrange,
        onTap: onServiceRequest,
      ),
      _ActionTileData(
        title: 'Customer',
        subtitle: 'കസ്റ്റമർ ചേർക്കുക',
        icon: Icons.person_add_alt_1_rounded,
        gradient: const LinearGradient(
          colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        glowColor: DashboardColors.neonPurple,
        onTap: onAddCustomer,
      ),
      _ActionTileData(
        title: 'Reports',
        subtitle: 'റിപ്പോർട്ടുകൾ',
        icon: Icons.bar_chart_rounded,
        gradient: const LinearGradient(
          colors: [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        glowColor: const Color(0xFF3B82F6),
        onTap: onViewReports,
      ),
      _ActionTileData(
        title: 'Settings',
        subtitle: 'ക്രമീകരണങ്ങൾ',
        icon: Icons.settings_suggest_rounded,
        gradient: const LinearGradient(
          colors: [Color(0xFF64748B), Color(0xFF475569)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        glowColor: const Color(0xFF94A3B8),
        onTap: onOpenSettings,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Title
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Quick Actions',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DashboardTypography.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'ദ്രുത പ്രവർത്തനങ്ങൾ',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DashboardTypography.malayalam(
                      fontSize: 11,
                      color: DashboardColors.textMuted,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),

        // 3x2 Grid (responsive)
        LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final count = w >= 1000 ? 4 : (w >= 600 ? 3 : 2);
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: actions.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: count,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                mainAxisExtent: 66,
              ),
              itemBuilder: (context, idx) {
                return _QuickActionCard(data: actions[idx]);
              },
            );
          },
        ),
      ],
    );
  }
}

class _ActionTileData {
  final String title;
  final String subtitle;
  final IconData icon;
  final LinearGradient gradient;
  final Color glowColor;
  final VoidCallback onTap;

  _ActionTileData({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    required this.glowColor,
    required this.onTap,
  });
}

class _QuickActionCard extends StatefulWidget {
  final _ActionTileData data;

  const _QuickActionCard({required this.data});

  @override
  State<_QuickActionCard> createState() => _QuickActionCardState();
}

class _QuickActionCardState extends State<_QuickActionCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, _isHovered ? -1 : 0, 0),
        decoration: BoxDecoration(
          color: _isHovered
              ? DashboardColors.surfaceAlt
              : DashboardColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _isHovered
                ? DashboardColors.glassBorderHover
                : DashboardColors.border,
            width: 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              HapticFeedback.lightImpact();
              widget.data.onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: DashboardColors.accentBg,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      widget.data.icon,
                      color: DashboardColors.neonBlue,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.data.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DashboardTypography.inter(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: DashboardColors.textWhite,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          widget.data.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DashboardTypography.malayalam(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w400,
                            color: DashboardColors.textMuted,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
