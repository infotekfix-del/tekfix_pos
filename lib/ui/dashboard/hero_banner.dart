import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dashboard_tokens.dart';

/// Pixel-faithful Hero Banner for TekFix ERP.
/// Features a rich purple-to-blue gradient, title, subtitle,
/// live date chip, schedule note, and modern device illustration art.
class TekHeroBanner extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? customDateNote;

  const TekHeroBanner({
    super.key,
    this.title = 'TEKFIX ERP',
    this.subtitle = 'Smarter Business. Greater Growth.',
    this.customDateNote,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final todayStr = DateFormat('EEEE, dd MMMM yyyy').format(now);
    final tomorrow = now.add(const Duration(days: 1));
    final tomorrowDay = DateFormat('EEEE').format(tomorrow);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [
            Color(0xFF4C1D95), // Deep royal purple
            Color(0xFF2563EB), // Rich vivid blue
            Color(0xFF0284C7), // Bright cyan blue
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: const Color(0x3D60A5FA),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2563EB).withValues(alpha: 0.35),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            // Background glowing ambient circles
            Positioned(
              right: -30,
              top: -30,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
            ),
            Positioned(
              left: 120,
              bottom: -40,
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: DashboardColors.neonBlue.withValues(alpha: 0.12),
                ),
              ),
            ),

            // Content Layout
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
              child: Row(
                children: [
                  // Left: Titles and Date Chip
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Date Chip + Tomorrow note
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.2),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.calendar_month_rounded,
                                    size: 13,
                                    color: DashboardColors.neonBlue,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    todayStr,
                                    style: DashboardTypography.inter(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.25),
                                ),
                              ),
                              child: Text(
                                customDateNote ?? '$tomorrowDay: 9:30 AM - 9:00 PM',
                                style: DashboardTypography.inter(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  color: const Color(0xFFE0E7FF),
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 14),

                        // Title
                        Text(
                          title,
                          style: DashboardTypography.poppins(
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),

                        const SizedBox(height: 4),

                        // Subtitle
                        Text(
                          subtitle,
                          style: DashboardTypography.inter(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFFE2E8F0),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 16),

                  // Right: Stylized Phone, AirPods, and Smartwatch cluster
                  _buildDeviceCluster(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCluster() {
    return Container(
      width: 124,
      height: 94,
      alignment: Alignment.center,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Smartwatch (left rear)
          Positioned(
            left: 0,
            bottom: 4,
            child: Container(
              width: 36,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DashboardColors.neonPurple, width: 1.2),
                boxShadow: [
                  BoxShadow(
                    color: DashboardColors.neonPurple.withValues(alpha: 0.4),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: const Icon(
                Icons.watch_rounded,
                color: DashboardColors.neonPurple,
                size: 22,
              ),
            ),
          ),

          // Smartphone (center prominent)
          Positioned(
            left: 32,
            bottom: 0,
            child: Container(
              width: 48,
              height: 84,
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: DashboardColors.neonBlue, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: DashboardColors.neonBlue.withValues(alpha: 0.5),
                    blurRadius: 14,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 14,
                    height: 2.5,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Icon(
                    Icons.bolt_rounded,
                    color: DashboardColors.neonBlue,
                    size: 26,
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: 28,
                    height: 3,
                    decoration: BoxDecoration(
                      color: Colors.white38,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // AirPods Case (right foreground)
          Positioned(
            right: 2,
            bottom: 6,
            child: Container(
              width: 40,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: DashboardColors.neonGreen, width: 1.2),
                boxShadow: [
                  BoxShadow(
                    color: DashboardColors.neonGreen.withValues(alpha: 0.4),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: const Center(
                child: Icon(
                  Icons.headphones_rounded,
                  color: DashboardColors.neonGreen,
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
