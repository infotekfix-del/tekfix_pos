import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../main.dart' show Db, rs;
import '../../utils/tek_helpers.dart';
import 'dashboard_tokens.dart';

/// Pixel-faithful Sales Overview Chart for TekFix ERP.
/// Uses fl_chart for gradient line chart, glowing points, interactive tooltip
/// showing the exact amount, Mon-Sun x-axis, and "This Month" dropdown.
/// Real-time live data from Hive Db.sales.
class TekSalesOverviewChart extends StatefulWidget {
  const TekSalesOverviewChart({super.key});

  @override
  State<TekSalesOverviewChart> createState() => _TekSalesOverviewChartState();
}

class _TekSalesOverviewChartState extends State<TekSalesOverviewChart> {
  String _selectedPeriod =
      'This Week'; // 'This Week', 'This Month', 'Last 7 Days'

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    List<DateTime> days = [];
    if (_selectedPeriod == 'This Week') {
      // Find Monday of current week
      final currentWeekday = today.weekday; // 1 = Monday, 7 = Sunday
      final monday = today.subtract(Duration(days: currentWeekday - 1));
      for (int i = 0; i < 7; i++) {
        days.add(monday.add(Duration(days: i)));
      }
    } else if (_selectedPeriod == 'Last 7 Days') {
      for (int i = 6; i >= 0; i--) {
        days.add(today.subtract(Duration(days: i)));
      }
    } else {
      // 'This Month' — every day from the 1st up to today.
      // (Old code sampled every Nth day, so sales on skipped days were
      // silently dropped from both the line and the period total.)
      for (int d = 1; d <= today.day; d++) {
        days.add(DateTime(now.year, now.month, d));
      }
    }
    final isMonth = _selectedPeriod == 'This Month';

    final dailyTotals = <DateTime, double>{};
    for (final d in days) {
      dailyTotals[d] = 0.0;
    }

    double periodTotal = 0;

    for (final v in Db.sales.values) {
      if (v is! Map) continue;
      final s = tekM(v);
      if (isSaleReturned(s)) continue;

      // Business date: backdated bills carry 'saleDate'. Stored as UTC ISO
      // strings, so convert to local (IST) before taking the calendar day —
      // otherwise bills made between 00:00 and 05:30 land on the previous day.
      final rawDate = s['saleDate'] ?? s['createdAt'];
      if (rawDate == null) continue;
      final parsed = DateTime.tryParse('$rawDate');
      if (parsed == null) continue;
      final dt = parsed.toLocal();
      final saleDate = DateTime(dt.year, dt.month, dt.day);
      // Partial returns reduce the bill's real value.
      final total =
          math.max(0.0, tekD(s['total']) - tekD(s['returnedAmount']));

      if (dailyTotals.containsKey(saleDate)) {
        dailyTotals[saleDate] = (dailyTotals[saleDate] ?? 0) + total;
        periodTotal += total;
      }
    }

    final spots = <FlSpot>[];
    for (int i = 0; i < days.length; i++) {
      final amt = dailyTotals[days[i]] ?? 0.0;
      spots.add(FlSpot(i.toDouble(), amt));
    }

    final maxY = spots.fold<double>(0.0, (m, s) => math.max(m, s.y));
    final adjustedMaxY = maxY == 0 ? 1000.0 : maxY * 1.25;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: BoxDecoration(
        color: DashboardColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DashboardColors.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Row: Title, Period Total, and Dropdown
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: DashboardColors.neonBlue
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.show_chart_rounded,
                            color: DashboardColors.neonBlue,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Sales Overview',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DashboardTypography.poppins(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                'വിൽപ്പന അവലോകനം',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DashboardTypography.malayalam(
                                  fontSize: 11,
                                  height: 1.3,
                                  color: DashboardColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        rs(periodTotal),
                        style: DashboardTypography.poppins(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: DashboardColors.textWhite,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),

              // "This Month" / Period Selector Dropdown
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: DashboardColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: DashboardColors.border),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedPeriod,
                    isDense: true,
                    dropdownColor: DashboardColors.surfaceAlt,
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: DashboardColors.neonBlue,
                      size: 18,
                    ),
                    style: DashboardTypography.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'This Week',
                        child: Text('This Week'),
                      ),
                      DropdownMenuItem(
                        value: 'Last 7 Days',
                        child: Text('Last 7 Days'),
                      ),
                      DropdownMenuItem(
                        value: 'This Month',
                        child: Text('This Month'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedPeriod = val);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // fl_chart Gradient Line Chart
          SizedBox(
            height: 220,
            child: Stack(
              children: [
                Positioned.fill(
                  child: LineChart(
              LineChartData(
                minX: 0,
                maxX: math.max(1, days.length - 1).toDouble(),
                minY: 0,
                maxY: adjustedMaxY,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: adjustedMaxY / 4,
                  getDrawingHorizontalLine: (value) => const FlLine(
                    color: DashboardColors.border,
                    strokeWidth: 1,
                    dashArray: [4, 4],
                  ),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 42,
                      interval: adjustedMaxY / 4,
                      getTitlesWidget: (value, meta) {
                        if (value == 0) return const SizedBox.shrink();
                        String label = '';
                        if (value >= 100000) {
                          label = '₹${(value / 100000).toStringAsFixed(1)}L';
                        } else if (value >= 1000) {
                          label = '₹${(value / 1000).toStringAsFixed(0)}k';
                        } else {
                          label = '₹${value.toInt()}';
                        }
                        return Text(
                          label,
                          style: DashboardTypography.inter(
                            fontSize: 10,
                            color: DashboardColors.textDarkMuted,
                          ),
                        );
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: 1,
                      getTitlesWidget: (value, meta) {
                        final idx = value.toInt();
                        if (idx < 0 || idx >= days.length)
                          return const SizedBox.shrink();
                        final d = days[idx];
                        // Month view: label every 5th day + today only.
                        final isLast = idx == days.length - 1;
                        if (isMonth && d.day % 5 != 1 && !isLast) {
                          return const SizedBox.shrink();
                        }
                        final dayName = isMonth
                            ? '${d.day}'
                            : DateFormat('E').format(d); // Mon, Tue...
                        final isToday = d.year == today.year &&
                            d.month == today.month &&
                            d.day == today.day;
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            dayName,
                            style: DashboardTypography.inter(
                              fontSize: 11,
                              fontWeight:
                                  isToday ? FontWeight.w700 : FontWeight.w500,
                              color: isToday
                                  ? DashboardColors.neonBlue
                                  : DashboardColors.textMuted,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => DashboardColors.surfaceAlt,
                    tooltipBorderRadius: BorderRadius.circular(12),
                    tooltipBorder: const BorderSide(
                      color: DashboardColors.border,
                      width: 1,
                    ),
                    getTooltipItems: (touchedSpots) {
                      return touchedSpots.map((spot) {
                        final idx = spot.x.toInt();
                        final dateStr = (idx >= 0 && idx < days.length)
                            ? DateFormat('EEE, dd MMM').format(days[idx])
                            : '';
                        return LineTooltipItem(
                          '$dateStr\n',
                          DashboardTypography.inter(
                            fontSize: 11,
                            color: DashboardColors.textMuted,
                          ),
                          children: [
                            TextSpan(
                              text: rs(spot.y),
                              style: DashboardTypography.poppins(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: DashboardColors.neonBlue,
                              ),
                            ),
                          ],
                        );
                      }).toList();
                    },
                  ),
                  handleBuiltInTouches: true,
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.35,
                    barWidth: 2.5,
                    isStrokeCapRound: true,
                    color: DashboardColors.neonBlue,
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          DashboardColors.neonBlue.withValues(alpha: 0.22),
                          DashboardColors.neonBlue.withValues(alpha: 0.0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                    dotData: FlDotData(
                      show: !isMonth,
                      getDotPainter: (spot, percent, barData, index) {
                        return FlDotCirclePainter(
                          radius: 3.5,
                          color: DashboardColors.surface,
                          strokeColor: DashboardColors.neonBlue,
                          strokeWidth: 2.5,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
                ),
                if (periodTotal <= 0)
                  Positioned.fill(
                    bottom: 28,
                    child: _EmptySalesState(period: _selectedPeriod),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown over the empty grid when the selected period has no sales,
/// instead of a flat line stuck at ₹0.
class _EmptySalesState extends StatelessWidget {
  final String period;
  const _EmptySalesState({required this.period});

  @override
  Widget build(BuildContext context) {
    final label = switch (period) {
      'This Month' => 'ഈ മാസം',
      'Last 7 Days' => 'കഴിഞ്ഞ 7 ദിവസം',
      _ => 'ഈ ആഴ്ച',
    };
    return IgnorePointer(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: DashboardColors.accentBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.show_chart_rounded,
                color: DashboardColors.neonBlue,
                size: 22,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '$label ഇതുവരെ വിൽപ്പനയില്ല',
              textAlign: TextAlign.center,
              style: DashboardTypography.malayalam(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: DashboardColors.textLight,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'ആദ്യ ബിൽ ചെയ്യുമ്പോൾ ഇവിടെ ഗ്രാഫ് വരും',
              textAlign: TextAlign.center,
              style: DashboardTypography.malayalam(
                fontSize: 12,
                color: DashboardColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
