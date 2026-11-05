import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/expenses/expense_cleanup_service.dart';
import 'package:tekfix_erp_pos/expenses/expense_models.dart';
import 'package:tekfix_erp_pos/expenses/expense_service.dart';

void main() {
  group('Phase 1 - Expense Duplicate Cleanup Logic Test', () {
    test('ExpenseDuplicateGroup separates oldest item and duplicate items correctly', () {
      final now = DateTime.now();
      final item1 = ExpenseItem(
        id: 'EXP_001',
        shopId: 'tekfix',
        title: 'Tea & Snacks',
        category: ExpenseCategory.refreshmentsAndFood,
        amount: 20.0,
        amountPaise: 2000,
        paymentMode: 'CASH',
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff 1',
        notes: 'Evening tea',
        createdAt: now,
      );

      final item2 = ExpenseItem(
        id: 'EXP_002',
        shopId: 'tekfix',
        title: 'Tea & Snacks',
        category: ExpenseCategory.refreshmentsAndFood,
        amount: 20.0,
        amountPaise: 2000,
        paymentMode: 'CASH',
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff 1',
        notes: 'Evening tea',
        createdAt: now.add(const Duration(milliseconds: 200)),
      );

      final group = ExpenseDuplicateGroup(
        groupKey: '20.00|refreshments & food|staff_1|evening tea',
        items: [item1, item2],
      );

      expect(group.oldestItem.id, 'EXP_001');
      expect(group.duplicateItems.length, 1);
      expect(group.duplicateItems.first.id, 'EXP_002');
      expect(group.amount, 20.0);
    });

    test('CleanupExecutionResult holds before and after metrics accurately', () {
      const before = ExpenseMetrics(
        todayTotal: 100.0,
        thisMonthTotal: 500.0,
        todayCashTotal: 60.0,
        todayBankTotal: 40.0,
        todayCount: 5,
      );

      const after = ExpenseMetrics(
        todayTotal: 80.0,
        thisMonthTotal: 480.0,
        todayCashTotal: 40.0,
        todayBankTotal: 40.0,
        todayCount: 4,
      );

      final res = CleanupExecutionResult(
        groupsFound: 1,
        documentsDeleted: 1,
        amountCleaned: 20.0,
        beforeMetrics: before,
        afterMetrics: after,
      );

      expect(res.documentsDeleted, 1);
      expect(res.amountCleaned, 20.0);
      expect(res.beforeMetrics.todayTotal - res.afterMetrics.todayTotal, 20.0);
    });
  });
}
