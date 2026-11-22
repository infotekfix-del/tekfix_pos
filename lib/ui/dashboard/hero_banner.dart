import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'dashboard_tokens.dart';

/// Dashboard header (v2).
///
/// Replaces the old full-width purple gradient banner with a compact greeting
/// row: date, time-of-day greeting with the user's name, a one-line summary of
/// today, and the primary "New Sale" action. Takes ~90px instead of ~180px and
/// shows information the owner actually uses.
///
/// The old constructor parameters (title, subtitle, customDateNote) are kept so
/// existing call sites keep compiling.
class TekHeroBanner extends StatelessWidget {
  final String title;
  final String subtitle;

  /// Optional note shown next to the date, e.g. shop hours.
  /// Nothing is shown when null/empty (the old banner showed fake hours).
  final String? customDateNote;

  /// Name used in the greeting. Falls back to [title] when empty.
  final String? userName;

  /// One-line summary of today, e.g. "ഇന്ന് ₹4,200 വിൽപ്പന · 2 റിപ്പയർ".
  final String? summary;

  /// Primary call to action (New Sale). Hidden when null.
  final VoidCallback? onPrimaryAction;
  final String primaryActionLabel;

  const TekHeroBanner({
    super.key,
    this.title = 'TEKFIX ERP',
    this.subtitle = 'Smarter Business. Greater Growth.',
    this.customDateNote,
    this.userName,
    this.summary,
    this.onPrimaryAction,
    this.primaryActionLabel = 'New Sale',
  });

  static String greetingFor(DateTime now) {
    final h = now.hour;
    if (h < 12) return 'സുപ്രഭാതം';
    if (h < 16) return 'നമസ്കാരം';
    return 'ശുഭ സായാഹ്നം';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dateStr = DateFormat('EEEE, d MMM yyyy').format(now);
    final name = (userName ?? '').trim();
    final note = (customDateNote ?? '').trim();

    final textBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                dateStr,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DashboardTypography.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: DashboardColors.textMuted,
                ),
              ),
            ),
            if (note.isNotEmpty) ...[
              const SizedBox(width: 10),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: DashboardColors.neonGreen,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DashboardTypography.inter(
                    fontSize: 13,
                    color: DashboardColors.textMuted,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          name.isEmpty ? title : '${greetingFor(now)}, $name',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DashboardTypography.malayalam(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: DashboardColors.textWhite,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          (summary ?? '').trim().isNotEmpty ? summary!.trim() : subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: DashboardTypography.malayalam(
            fontSize: 13.5,
            color: DashboardColors.textMuted,
            height: 1.4,
          ),
        ),
      ],
    );

    final button = onPrimaryAction == null
        ? null
        : FilledButton.icon(
            onPressed: () {
              HapticFeedback.lightImpact();
              onPrimaryAction!();
            },
            style: FilledButton.styleFrom(
              backgroundColor: DashboardColors.primaryBlue,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.add_rounded, size: 20),
            label: Text(
              primaryActionLabel,
              style: DashboardTypography.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 560;
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              textBlock,
              if (button != null) ...[
                const SizedBox(height: 14),
                button,
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: textBlock),
            if (button != null) ...[
              const SizedBox(width: 16),
              button,
            ],
          ],
        );
      },
    );
  }
}
