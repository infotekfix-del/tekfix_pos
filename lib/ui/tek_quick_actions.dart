import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tek_tokens.dart';

/// Modern Quick Actions grid with press feedback and direct routing
class TekQuickActions extends StatelessWidget {
  final VoidCallback onNewSale;
  final VoidCallback onAddItem;
  final VoidCallback onServiceRequest;
  final VoidCallback onAddCustomer;
  final VoidCallback onViewReports;
  final VoidCallback onOpenSettings;

  const TekQuickActions({
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
      _ActionItem(
        title: 'New Sale',
        malayalam: 'പുതിയ വിൽപന',
        icon: Icons.point_of_sale_rounded,
        gradient: TekColors.cyanBlueGradient,
        onTap: onNewSale,
      ),
      _ActionItem(
        title: 'Add Item',
        malayalam: 'സാധനം ചേർക്കുക',
        icon: Icons.add_box_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF22C55E), Color(0xFF16A34A)]),
        onTap: onAddItem,
      ),
      _ActionItem(
        title: 'Service Request',
        malayalam: 'സർവീസ് റിപ്പയർ',
        icon: Icons.build_circle_rounded,
        gradient: const LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFD97706)]),
        onTap: onServiceRequest,
      ),
      _ActionItem(
        title: 'Add Customer',
        malayalam: 'കസ്റ്റമർ ചേർക്കുക',
        icon: Icons.person_add_alt_1_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)]),
        onTap: onAddCustomer,
      ),
      _ActionItem(
        title: 'View Reports',
        malayalam: 'റിപ്പോർട്ടുകൾ',
        icon: Icons.bar_chart_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF0284C7), Color(0xFF0369A1)]),
        onTap: onViewReports,
      ),
      _ActionItem(
        title: 'Settings',
        malayalam: 'ക്രമീകരണങ്ങൾ',
        icon: Icons.settings_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF475569), Color(0xFF334155)]),
        onTap: onOpenSettings,
      ),
    ];

    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth >= 720;
      final crossAxisCount = isWide ? 6 : (constraints.maxWidth >= 480 ? 3 : 2);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.bolt_rounded, size: 18, color: TekColors.electricCyan),
                SizedBox(width: 8),
                Text(
                  'Quick Actions (ദ്രുത പ്രവർത്തനങ്ങൾ)',
                  style: TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    fontFamilyFallback: TekTypography.malayalamFallback,
                  ),
                ),
              ],
            ),
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: actions.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: isWide ? 1.55 : 1.35,
            ),
            itemBuilder: (ctx, i) => _buildActionButton(actions[i]),
          ),
        ],
      );
    });
  }

  Widget _buildActionButton(_ActionItem item) {
    return _PressableActionCard(item: item);
  }
}

class _ActionItem {
  final String title;
  final String malayalam;
  final IconData icon;
  final LinearGradient gradient;
  final VoidCallback onTap;

  const _ActionItem({
    required this.title,
    required this.malayalam,
    required this.icon,
    required this.gradient,
    required this.onTap,
  });
}

class _PressableActionCard extends StatefulWidget {
  final _ActionItem item;
  const _PressableActionCard({required this.item});

  @override
  State<_PressableActionCard> createState() => _PressableActionCardState();
}

class _PressableActionCardState extends State<_PressableActionCard> {
  bool _isPressed = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.95 : (_isHovered ? 1.02 : 1.0),
        duration: const Duration(milliseconds: 150),
        child: Container(
          decoration: BoxDecoration(
            color: TekColors.cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _isHovered ? TekColors.primaryBlue.withValues(alpha: 0.6) : TekColors.border,
              width: 1.2,
            ),
            boxShadow: _isHovered ? TekColors.primaryGlow : TekColors.cardShadow,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onHighlightChanged: (val) => setState(() => _isPressed = val),
              onTap: () {
                HapticFeedback.lightImpact();
                widget.item.onTap();
              },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        gradient: widget.item.gradient,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(widget.item.icon, color: Colors.white, size: 20),
                    ),
                    const Spacer(),
                    Text(
                      widget.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: TekColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      widget.item.malayalam,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: TekColors.textSecondary,
                        fontSize: 11,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
