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
  String _selectedPeriod = 'This Week'; // 'This Week', 'This Month', 'Last 7 Days'

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
      // 'This Month' - group into days up to today
      final daysInMonth = today.day;
      final step = math.max(1, (daysInMonth / 7).ceil());
      for (int d = 1; d <= daysInMonth; d += step) {
        days.add(DateTime(now.year, now.month, d));
      }
      if (!days.contains(today)) days.add(today);
    }

    final dailyTotals = <DateTime, double>{};
    for (final d in days) {
      dailyTotals[d] = 0.0;
    }

    double periodTotal = 0;

    for (final v in Db.sales.values) {
      if (v is! Map) continue;
      final s = tekM(v);
      if (isSaleReturned(s)) continue;

      final dt = tekDt(s['createdAt']);
      final saleDate = DateTime(dt.year, dt.month, dt.day);
      final total = tekD(s['total']);

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
      padding: const EdgeInsets.all(20),
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
          // Header Row: Title, Period Total, and Dropdown
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                          Icons.show_chart_rounded,
                          color: DashboardColors.neonBlue,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Sales Overview',
                        style: DashboardTypography.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'വിൽപന അവലോകനം',
                        style: DashboardTypography.inter(
                          fontSize: 11.5,
                          color: DashboardColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    rs(periodTotal),
                    style: DashboardTypography.poppins(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: DashboardColors.neonBlue,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),

              // "This Month" / Period Selector Dropdown
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0x261E293B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x33FFFFFF)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedPeriod,
                    dropdownColor: const Color(0xFF131D45),
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: DashboardColors.neonBlue,
                      size: 18,
                    ),
                    style: DashboardTypography.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'This Week',
                        child: Text('This Week (തിങ്കൾ - ഞായർ)'),
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
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: (days.length - 1).toDouble(),
                minY: 0,
                maxY: adjustedMaxY,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: adjustedMaxY / 4,
                  getDrawingHorizontalLine: (value) => const FlLine(
                    color: Color(0x14FFFFFF),
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
                        if (idx < 0 || idx >= days.length) return const SizedBox.shrink();
                        final d = days[idx];
                        final dayName = DateFormat('E').format(d); // Mon, Tue...
                        final isToday = d.year == today.year && d.month == today.month && d.day == today.day;
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            dayName,
                            style: DashboardTypography.inter(
                              fontSize: 11,
                              fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                              color: isToday ? DashboardColors.neonBlue : DashboardColors.textMuted,
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
                    getTooltipColor: (_) => const Color(0xFF0F1A3A),
                    tooltipBorderRadius: BorderRadius.circular(12),
                    tooltipBorder: const BorderSide(
                      color: Color(0x4000D4FF),
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
                    barWidth: 3.5,
                    isStrokeCapRound: true,
                    gradient: const LinearGradient(
                      colors: [
                        DashboardColors.neonBlue,
                        DashboardColors.neonPurple,
                      ],
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          DashboardColors.neonBlue.withValues(alpha: 0.3),
                          DashboardColors.neonPurple.withValues(alpha: 0.0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, percent, barData, index) {
                        return FlDotCirclePainter(
                          radius: 4.5,
                          color: const Color(0xFF0B1030),
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
        ],
      ),
    );
  }
}
