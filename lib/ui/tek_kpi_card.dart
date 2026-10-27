import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tek_tokens.dart';

/// Enterprise KPI Stat Card with hover effects, gradient badge, and click-through navigation
class TekKpiCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final String value;
  final IconData icon;
  final Color accentColor;
  final LinearGradient? customGradient;
  final VoidCallback? onTap;

  const TekKpiCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.icon,
    required this.accentColor,
    this.customGradient,
    this.onTap,
  });

  @override
  State<TekKpiCard> createState() => _TekKpiCardState();
}

class _TekKpiCardState extends State<TekKpiCard> {
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
          color: _isHovered ? TekColors.elevatedSurface : TekColors.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isHovered
                ? widget.accentColor.withValues(alpha: 0.6)
                : TekColors.border,
            width: 1.3,
          ),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: widget.accentColor.withValues(alpha: 0.25),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ]
              : TekColors.cardShadow,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: widget.onTap != null
                ? () {
                    HapticFeedback.lightImpact();
                    widget.onTap!();
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Top row: Icon Badge and optional click chevron
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          gradient: widget.customGradient ??
                              LinearGradient(
                                colors: [
                                  widget.accentColor,
                                  widget.accentColor.withValues(alpha: 0.7),
                                ],
                              ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: widget.accentColor.withValues(alpha: 0.35),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(widget.icon, color: Colors.white, size: 20),
                      ),
                      if (widget.onTap != null)
                        Icon(
                          Icons.arrow_outward_rounded,
                          size: 16,
                          color: _isHovered ? widget.accentColor : TekColors.textMuted,
                        ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  // Value Display
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.value,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        shadows: _isHovered
                            ? [
                                Shadow(
                                  color: widget.accentColor.withValues(alpha: 0.4),
                                  blurRadius: 8,
                                )
                              ]
                            : null,
                      ),
                    ),
                  ),

                  const SizedBox(height: 4),

                  // Title and Malayalam subtitle
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: TekColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        widget.subtitle,
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
