import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../main.dart' show Db, rs;
import '../utils/tek_helpers.dart';
import '../theme/tek_tokens.dart';

/// Interactive Sales Analytics Chart with Daily/Weekly toggle and period comparison
class TekSalesChart extends StatefulWidget {
  const TekSalesChart({super.key});

  @override
  State<TekSalesChart> createState() => _TekSalesChartState();
}

class _TekSalesChartState extends State<TekSalesChart> {
  int _selectedPeriod = 0; // 0 = Last 7 Days, 1 = Last 30 Days

  @override
  Widget build(BuildContext context) {
    // 1. Calculate sales per day from Hive Db.sales
    final daysCount = _selectedPeriod == 0 ? 7 : 30;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final dailyTotals = <DateTime, double>{};
    for (int i = 0; i < daysCount; i++) {
      final date = today.subtract(Duration(days: i));
      dailyTotals[date] = 0.0;
    }

    double currentPeriodTotal = 0;
    double previousPeriodTotal = 0;

    final prevStart = today.subtract(Duration(days: daysCount * 2));
    final prevEnd = today.subtract(Duration(days: daysCount));

    for (final v in Db.sales.values) {
      if (v is! Map) continue;
      final s = tekM(v);
      if (isSaleReturned(s)) continue;

      final dt = tekDt(s['createdAt']);
      final saleDate = DateTime(dt.year, dt.month, dt.day);
      final total = tekD(s['total']);

      if (dailyTotals.containsKey(saleDate)) {
        dailyTotals[saleDate] = (dailyTotals[saleDate] ?? 0) + total;
        currentPeriodTotal += total;
      } else if (saleDate.isAfter(prevStart) && (saleDate.isBefore(prevEnd) || saleDate == prevEnd)) {
        previousPeriodTotal += total;
      }
    }

    final sortedEntries = dailyTotals.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    final maxSale = sortedEntries.fold<double>(
      0.0,
      (max, e) => math.max(max, e.value),
    );

    // Percentage change
    double percentChange = 0;
    if (previousPeriodTotal > 0) {
      percentChange = ((currentPeriodTotal - previousPeriodTotal) / previousPeriodTotal) * 100;
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: TekColors.border, width: 1.2),
        boxShadow: TekColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header with Title & Period Selector
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.insights_rounded, color: TekColors.electricCyan, size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Sales Overview (വിൽപന അവലോകനം)',
                        style: TextStyle(
                          color: TekColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          fontFamilyFallback: TekTypography.malayalamFallback,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        rs(currentPeriodTotal),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (previousPeriodTotal > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (percentChange >= 0 ? TekColors.success : TekColors.error)
                                .withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                percentChange >= 0
                                    ? Icons.arrow_upward_rounded
                                    : Icons.arrow_downward_rounded,
                                size: 11,
                                color: percentChange >= 0 ? TekColors.success : TekColors.error,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '${percentChange.abs().toStringAsFixed(1)}%',
                                style: TextStyle(
                                  color: percentChange >= 0 ? TekColors.success : TekColors.error,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),

              // Period Selector Tabs
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: TekColors.sidebarBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: TekColors.border),
                ),
                child: Row(
                  children: [
                    _buildPeriodTab('7 Days', 0),
                    _buildPeriodTab('30 Days', 1),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // Chart Graphic
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (int i = 0; i < sortedEntries.length; i++) ...[
                  Expanded(
                    child: _buildBar(
                      date: sortedEntries[i].key,
                      amount: sortedEntries[i].value,
                      maxAmount: maxSale > 0 ? maxSale : 1000,
                      isLast: i == sortedEntries.length - 1,
                    ),
                  ),
                  if (i < sortedEntries.length - 1)
                    SizedBox(width: _selectedPeriod == 0 ? 8 : 2),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeriodTab(String label, int index) {
    final isSelected = _selectedPeriod == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedPeriod = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? TekColors.primaryBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : TekColors.textSecondary,
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildBar({
    required DateTime date,
    required double amount,
    required double maxAmount,
    required bool isLast,
  }) {
    final ratio = (amount / maxAmount).clamp(0.06, 1.0);
    final dayLabel = _selectedPeriod == 0
        ? (isLast ? 'Today' : DateFormat('E').format(date))
        : (date.day % 5 == 0 ? '${date.day}' : '');

    return Tooltip(
      message: '${DateFormat('dd MMM').format(date)}: ${rs(amount)}',
      waitDuration: const Duration(milliseconds: 100),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: ratio,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: isLast ? TekColors.cyanBlueGradient : TekColors.primaryGradient,
                    borderRadius: BorderRadius.circular(5),
                    boxShadow: isLast ? TekColors.primaryGlow : null,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            dayLabel,
            style: TextStyle(
              color: isLast ? TekColors.electricCyan : TekColors.textMuted,
              fontSize: 10,
              fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
