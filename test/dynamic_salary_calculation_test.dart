import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/staff/salary_calculator.dart';

void main() {
  group('Dynamic Monthly Salary Calculation Based on Days in Month', () {
    test('1. Accurately determines days in month for 28, 29, 30, and 31 day months', () {
      // 28 days: Feb 2023 (non-leap)
      expect(SalaryCalculator.getDaysInMonth(DateTime(2023, 2, 1)), 28);

      // 29 days: Feb 2024 (leap year)
      expect(SalaryCalculator.getDaysInMonth(DateTime(2024, 2, 1)), 29);

      // 30 days: April, June, September, November
      expect(SalaryCalculator.getDaysInMonth(DateTime(2026, 4, 15)), 30);
      expect(SalaryCalculator.getDaysInMonth(DateTime(2026, 6, 1)), 30);
      expect(SalaryCalculator.getDaysInMonth(DateTime(2026, 9, 30)), 30);
      expect(SalaryCalculator.getDaysInMonth(DateTime(2026, 11, 2)), 30); // November current month

      // 31 days: January, March, May, July, August, October, December
      expect(SalaryCalculator.getDaysInMonth(DateTime(2026, 1, 10)), 31);
      expect(SalaryCalculator.getDaysInMonth(DateTime(2026, 3, 15)), 31);
      expect(SalaryCalculator.getDaysInMonth(DateTime(2026, 5, 1)), 31);
      expect(SalaryCalculator.getDaysInMonth(DateTime(2026, 7, 20)), 31);
      expect(SalaryCalculator.getDaysInMonth(DateTime(2026, 8, 15)), 31);
      expect(SalaryCalculator.getDaysInMonth(DateTime(2026, 10, 31)), 31);
      expect(SalaryCalculator.getDaysInMonth(DateTime(2026, 12, 25)), 31);
    });

    test('2. Dynamic Monthly Total: daily_rate * total_days_in_current_month', () {
      const dailyRate = 350.0;

      // 30-day month (e.g. November 2026) -> 30 * 350 = 10,500
      final novemberSalary = SalaryCalculator.calculateMonthlySalary(
        dailyRate: dailyRate,
        date: DateTime(2026, 11, 2),
      );
      expect(novemberSalary, 10500.0);

      // 31-day month (e.g. October 2026 or December 2026) -> 31 * 350 = 10,850
      final octoberSalary = SalaryCalculator.calculateMonthlySalary(
        dailyRate: dailyRate,
        date: DateTime(2026, 10, 15),
      );
      expect(octoberSalary, 10850.0);

      final decemberSalary = SalaryCalculator.calculateMonthlySalary(
        dailyRate: dailyRate,
        date: DateTime(2026, 12, 1),
      );
      expect(decemberSalary, 10850.0);

      // 28-day month (Feb 2023) -> 28 * 350 = 9,800
      final febSalary = SalaryCalculator.calculateMonthlySalary(
        dailyRate: dailyRate,
        date: DateTime(2023, 2, 1),
      );
      expect(febSalary, 9800.0);

      // 29-day month (Feb 2024 leap year) -> 29 * 350 = 10,150
      final leapFebSalary = SalaryCalculator.calculateMonthlySalary(
        dailyRate: dailyRate,
        date: DateTime(2024, 2, 1),
      );
      expect(leapFebSalary, 10150.0);
    });

    test('3. Real-time Date Sync: automatically recalculates expected monthly total when month changes', () {
      final staff = {
        'name': 'Rahul Nair',
        'dailyRate': 350.0,
      };

      final dailyRate = SalaryCalculator.getDailyRate(staff);
      expect(dailyRate, 350.0);

      // At start of November (30 days):
      final novDate = DateTime(2026, 11, 1);
      final novDays = SalaryCalculator.getDaysInMonth(novDate);
      final novExpected = SalaryCalculator.calculateMonthlySalary(
        dailyRate: dailyRate,
        date: novDate,
      );
      expect(novDays, 30);
      expect(novExpected, 10500.0);

      // Transition to December (31 days) without manual entry:
      final decDate = DateTime(2026, 12, 1);
      final decDays = SalaryCalculator.getDaysInMonth(decDate);
      final decExpected = SalaryCalculator.calculateMonthlySalary(
        dailyRate: dailyRate,
        date: decDate,
      );
      expect(decDays, 31);
      expect(decExpected, 10850.0);
    });

    test('4. Earned Salary calculation based on days worked (present days and half days)', () {
      const dailyRate = 350.0;

      // Worked 20 full days:
      final earned20 = SalaryCalculator.calculateEarnedSalary(
        dailyRate: dailyRate,
        daysWorked: 20,
      );
      expect(earned20, 7000.0);

      // Worked 25 full days + 1 half day (25.5 days):
      final earned25Half = SalaryCalculator.calculateEarnedSalary(
        dailyRate: dailyRate,
        daysWorked: 25.5,
      );
      expect(earned25Half, 8925.0);

      // Worked 0 days:
      expect(
        SalaryCalculator.calculateEarnedSalary(
          dailyRate: dailyRate,
          daysWorked: 0,
        ),
        0.0,
      );
    });

    test('5. getDailyRate extraction with backward compatibility fallback', () {
      // 1. Explicit dailyRate:
      expect(
        SalaryCalculator.getDailyRate({'dailyRate': 400.0}),
        400.0,
      );

      // 2. Explicit daily_rate:
      expect(
        SalaryCalculator.getDailyRate({'daily_rate': 450.0}),
        450.0,
      );

      // 3. Derived from legacy monthlySalary in 30-day month (10,500 / 30 = 350):
      expect(
        SalaryCalculator.getDailyRate(
          {'monthlySalary': 10500.0},
          DateTime(2026, 11, 1),
        ),
        350.0,
      );

      // 4. Default fallback when no salary data is present:
      expect(SalaryCalculator.getDailyRate({}), 350.0);
    });
  });
}

