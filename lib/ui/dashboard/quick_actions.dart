import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dashboard_tokens.dart';

/// Pixel-faithful Quick Actions grid for TekFix ERP.
/// Features 6 gradient tiles in a 3x2 grid:
/// New Sale, Add Item, Service Request, Customer, Reports, Settings.
class TekQuickActionsGrid extends StatelessWidget {
  final VoidCallback onNewSale;
  final VoidCallback onAddItem;
  final VoidCallback onServiceRequest;
  final VoidCallback onAddCustomer;
  final VoidCallback onViewReports;
  final VoidCallback onOpenSettings;

  const TekQuickActionsGrid({
    super.key,
    required this.onNewSale,
    required this.onAddItem,
    required this.onServiceRequest,
    required this.onAddCustomer,
    required this.onViewReports,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final actions = [
      _ActionTileData(
        title: 'New Sale',
        subtitle: 'പുതിയ വിൽപന',
        icon: Icons.point_of_sale_rounded,
        gradient: const LinearGradient(
          colors: [Color(0xFF00D4FF), Color(0xFF1677FF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        glowColor: DashboardColors.neonBlue,
        onTap: onNewSale,
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
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: DashboardColors.neonBlue.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.bolt_rounded,
                color: DashboardColors.neonBlue,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Quick Actions',
              style: DashboardTypography.poppins(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'ദ്രുത പ്രവർത്തനങ്ങൾ',
              style: DashboardTypography.inter(
                fontSize: 11.5,
                color: DashboardColors.textMuted,
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),

        // 3x2 Grid (responsive)
        LayoutBuilder(
          builder: (context, constraints) {
            final count = constraints.maxWidth >= 600 ? 3 : 2;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: actions.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: count,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: constraints.maxWidth >= 600 ? 2.4 : 1.8,
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
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: _isHovered ? const Color(0x2E1E2D5A) : const Color(0x1F182652),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isHovered
                ? widget.data.glowColor.withValues(alpha: 0.6)
                : const Color(0x2BFFFFFF),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
            if (_isHovered)
              BoxShadow(
                color: widget.data.glowColor.withValues(alpha: 0.3),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              HapticFeedback.lightImpact();
              widget.data.onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: widget.data.gradient,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: widget.data.glowColor.withValues(alpha: 0.4),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      widget.data.icon,
                      color: Colors.white,
                      size: 22,
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
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          widget.data.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DashboardTypography.inter(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w400,
                            color: DashboardColors.textMuted,
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
