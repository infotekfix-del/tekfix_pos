import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dashboard_tokens.dart';

/// KPI card (v2): flat surface, small icon + label, large tabular amount,
/// and a footer that shows either a real change pill, the subtitle, or both.
///
/// [changeText] and [sparklineData] are optional now. The old card always drew
/// a hard-coded "+12.5%" and a made-up sparkline, which looked like real data
/// but was not. Pass them only when they are computed from real records.
class TekStatCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final String amount;
  final IconData icon;
  final Color accentColor;
  final String? changeText;
  final bool isPositive;
  final List<double>? sparklineData;
  final VoidCallback? onTap;

  const TekStatCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.icon,
    required this.accentColor,
    this.changeText,
    this.isPositive = true,
    this.sparklineData,
    this.onTap,
  });

  @override
  State<TekStatCard> createState() => _TekStatCardState();
}

class _TekStatCardState extends State<TekStatCard> {
  bool _isHovered = false;

  bool get _hasSparkline {
    final d = widget.sparklineData;
    if (d == null || d.length < 2) return false;
    return d.any((v) => v != d.first);
  }

  @override
  Widget build(BuildContext context) {
    final change = (widget.changeText ?? '').trim();
    final pillColor = widget.isPositive
        ? DashboardColors.neonGreen
        : DashboardColors.neonPink;

    return MouseRegion(
      cursor:
          widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, _isHovered ? -2 : 0, 0),
        decoration: BoxDecoration(
          color:
              _isHovered ? DashboardColors.surfaceAlt : DashboardColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _isHovered
                ? DashboardColors.glassBorderHover
                : DashboardColors.border,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _isHovered ? 0.28 : 0.16),
              blurRadius: _isHovered ? 16 : 8,
              offset: Offset(0, _isHovered ? 6 : 2),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onTap != null
                ? () {
                    HapticFeedback.lightImpact();
                    widget.onTap!();
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Label row
                  Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: widget.accentColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          widget.icon,
                          color: widget.accentColor,
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DashboardTypography.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: DashboardColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  // Amount
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.amount,
                      style: DashboardTypography.poppins(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: DashboardColors.textWhite,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Footer: change pill (if real) + subtitle, sparkline on the right.
                  // On narrow cards (small phones) the sparkline is dropped and
                  // the pill may shrink, so the row never overflows.
                  LayoutBuilder(builder: (context, box) {
                    final showSpark = _hasSparkline && box.maxWidth >= 200;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (change.isNotEmpty) ...[
                          Flexible(
                            flex: 0,
                            fit: FlexFit.loose,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color: pillColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    widget.isPositive
                                        ? Icons.arrow_upward_rounded
                                        : Icons.arrow_downward_rounded,
                                    size: 11,
                                    color: pillColor,
                                  ),
                                  const SizedBox(width: 2),
                                  Flexible(
                                    child: Text(
                                      change,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: DashboardTypography.inter(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: pillColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            widget.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DashboardTypography.malayalam(
                              fontSize: 12,
                              color: DashboardColors.textMuted,
                              height: 1.35,
                            ),
                          ),
                        ),
                        if (showSpark) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 72,
                            height: 24,
                            child: CustomPaint(
                              painter: _MiniSparklinePainter(
                                color: widget.accentColor,
                                data: widget.sparklineData!,
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Custom painter for the glowing mini sparkline
class _MiniSparklinePainter extends CustomPainter {
  final Color color;
  final List<double> data;

  _MiniSparklinePainter({required this.color, required this.data});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;

    final minVal = data.reduce((a, b) => a < b ? a : b);
    final maxVal = data.reduce((a, b) => a > b ? a : b);
    final range = (maxVal - minVal) == 0 ? 1.0 : (maxVal - minVal);

    final points = <Offset>[];
    for (int i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final normalized = (data[i] - minVal) / range;
      final y = size.height - (normalized * (size.height - 6)) - 3;
      points.add(Offset(x, y));
    }

    final path = Path();
    path.moveTo(points.first.dx, points.first.dy);

    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final controlPoint1 = Offset(p0.dx + (p1.dx - p0.dx) / 2, p0.dy);
      final controlPoint2 = Offset(p0.dx + (p1.dx - p0.dx) / 2, p1.dy);
      path.cubicTo(
        controlPoint1.dx,
        controlPoint1.dy,
        controlPoint2.dx,
        controlPoint2.dy,
        p1.dx,
        p1.dy,
      );
    }

    // Fill under curve
    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final fillPaint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        Offset(0, size.height),
        [
          color.withValues(alpha: 0.22),
          color.withValues(alpha: 0.0),
        ],
      );
    canvas.drawPath(fillPath, fillPaint);

    // Glowing stroke
    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _MiniSparklinePainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.data != data;
  }
}
