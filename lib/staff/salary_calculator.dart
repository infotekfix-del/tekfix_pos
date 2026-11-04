/// Utility for dynamic monthly salary calculation based on the days in the current/selected month.
class SalaryCalculator {
  SalaryCalculator._();

  /// Returns the exact number of days in the month of the given date.
  /// (e.g. 28 or 29 for February, 30 for April/June/Sept/Nov, 31 for Jan/Mar/May/July/Aug/Oct/Dec).
  static int getDaysInMonth(DateTime date) {
    return DateTime(date.year, date.month + 1, 0).day;
  }

  /// Extracts the staff's daily rate.
  /// Checks `dailyRate` / `daily_rate`, or derives from `monthlySalary / daysInMonth`, defaulting to 350.0.
  static double getDailyRate(Map<String, dynamic> staff, [DateTime? date]) {
    final explicitDaily = (staff['dailyRate'] as num?)?.toDouble() ??
        (staff['daily_rate'] as num?)?.toDouble();
    if (explicitDaily != null && explicitDaily > 0) {
      return explicitDaily;
    }

    final monthly = (staff['monthlySalary'] as num?)?.toDouble();
    if (monthly != null && monthly > 0) {
      final days = getDaysInMonth(date ?? DateTime.now());
      return double.parse((monthly / days).toStringAsFixed(2));
    }

    return 350.0;
  }

  /// Dynamically computes monthly salary by multiplying daily rate by the number of days in the month.
  /// e.g. 30 days * 350 = 10,500
  ///      31 days * 350 = 10,850
  ///      28 days * 350 = 9,800
  static double calculateMonthlySalary({
    required double dailyRate,
    DateTime? date,
    int? customDaysInMonth,
  }) {
    final days = customDaysInMonth ?? getDaysInMonth(date ?? DateTime.now());
    return double.parse((dailyRate * days).toStringAsFixed(2));
  }

  /// Calculates earned amount for days worked: `daysWorked * dailyRate`.
  static double calculateEarnedSalary({
    required double dailyRate,
    required num daysWorked,
  }) {
    return double.parse((dailyRate * daysWorked).toStringAsFixed(2));
  }
}
