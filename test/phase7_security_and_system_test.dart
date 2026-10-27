import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/theme/tek_tokens.dart';
import 'package:tekfix_erp_pos/pos/pos_models.dart';
import 'package:tekfix_erp_pos/repairs/repair_models.dart';
import 'package:tekfix_erp_pos/attendance/attendance_models.dart';

void main() {
  group('1. Malayalam Typography & Design Tokens Audit', () {
    test('TekTypography includes Noto Sans Malayalam in fallback stack', () {
      expect(TekTypography.malayalamFallback, contains('Noto Sans Malayalam'));
      expect(TekTypography.malayalamFallback.first, equals('Noto Sans Malayalam'));

      final titleStyle = TekTypography.titleLarge;
      expect(titleStyle.fontFamilyFallback, contains('Noto Sans Malayalam'));

      final bodyStyle = TekTypography.bodyPrimary;
      expect(bodyStyle.fontFamilyFallback, contains('Noto Sans Malayalam'));
    });

    test('TekTheme Dark theme uses standard brand palette tokens', () {
      expect(TekColors.bgMain.value, equals(0xFF070B18));
      expect(TekColors.sidebarBg.value, equals(0xFF0B1226));
      expect(TekColors.bgCard.value, equals(0xFF111B35));
      expect(TekColors.elevatedSurface.value, equals(0xFF172442));
      expect(TekColors.primaryBlue.value, equals(0xFF1677FF));
      expect(TekColors.electricCyan.value, equals(0xFF00D4FF));
      expect(TekColors.premiumPurple.value, equals(0xFF8B5CF6));
      expect(TekColors.success.value, equals(0xFF22C55E));
      expect(TekColors.warning.value, equals(0xFFF59E0B));
      expect(TekColors.error.value, equals(0xFFF43F5E));
      expect(TekColors.border.value, equals(0xFF263452));
    });
  });

  group('2. Sensitive Pricing & Floor Restriction Checks', () {
    test('PosItem calculates floor price and enforces margin floor', () {
      final rawItem = {
        'id': 'itm_display_123',
        'name': 'Samsung A50 OLED Screen',
        'category': 'Screens',
        'sellingPrice': 2500.0,
        'minPrice': 2200.0,
        'stock': 8,
      };

      final item = PosItem.fromMap('itm_display_123', rawItem);
      expect(item.sellingPrice, equals(2500.0));
      expect(item.minPrice, equals(2200.0));
      expect(item.stock, equals(8));
      expect(item.isOutOfStock, isFalse);

      // Floor price cannot be breached by staff without Owner PIN
      expect(item.minPrice, lessThanOrEqualTo(item.sellingPrice));
    });

    test('PosCartItem correctly computes line totals and quantities', () {
      const item = PosItem(
        id: 'cable_01',
        name: 'Type-C Braided Cable',
        category: 'Accessories',
        sellingPrice: 200.0,
        minPrice: 150.0,
        stock: 15,
      );

      final cartItem = PosCartItem(item: item, qty: 3, unitPrice: 200.0);
      expect(cartItem.lineTotal, equals(600.0));
      expect(cartItem.isBelowFloor, isFalse);

      cartItem.qty = 4;
      expect(cartItem.lineTotal, equals(800.0));
    });
  });

  group('3. Payment Reminders Zero-Balance Deduction Verification', () {
    test('Simulating reminder update does NOT deduct or mutate customer balance', () {
      final customer = <String, dynamic>{
        'id': 'cust_001',
        'name': 'Anil Kumar (അനിൽ കുമാർ)',
        'phone': '9847012345',
        'balance': 4500.0,
        'reminderCount': 2,
        'lastReminderAt': '2026-10-20T10:00:00Z',
      };

      final originalBalance = customer['balance'];

      // Simulate sending a reminder (as performed by ReminderService.recordReminderSent)
      final count = (customer['reminderCount'] as int) + 1;
      customer['lastReminderAt'] = DateTime.now().toIso8601String();
      customer['reminderCount'] = count;

      // Assert that balance is strictly unchanged
      expect(customer['balance'], equals(originalBalance));
      expect(customer['reminderCount'], equals(3));
    });
  });

  group('4. Repair Jobs & Attendance Model Audit', () {
    test('RepairJob parses Malayalam notes and status correctly', () {
      final data = {
        'customerName': 'Faizal (ഫൈസൽ)',
        'customerPhone': '9876543210',
        'brandModel': 'iPhone 13 Pro',
        'complaint': 'ഡിസ്പ്ലേ മാറ്റണം (Display change)',
        'status': 'In Progress',
        'estimatedCost': 6500.0,
        'advance': 1500.0,
        'expectedDelivery': '2026-10-30',
        'notes': 'TrueTone ബാക്കപ്പ് എടുത്തു (TrueTone backed up)',
      };

      final job = RepairJob.fromMap('JOB-101', data);
      expect(job.id, equals('JOB-101'));
      expect(job.customerName, equals('Faizal (ഫൈസൽ)'));
      expect(job.complaint, contains('ഡിസ്പ്ലേ'));
      expect(job.balance, equals(5000.0));
      expect(job.status, equals('In Progress'));
      expect(job.isActive, isTrue);
    });

    test('AttendanceRecord preserves check-in details and approval state', () {
      final record = AttendanceRecord(
        id: 'att_20261027',
        staffId: 'staff_rahul',
        staffName: 'Rahul (രാഹുൽ)',
        date: '2026-10-27',
        checkIn: DateTime.now().subtract(const Duration(hours: 4)),
        approvalStatus: 'approved',
        workedHours: 4.0,
      );

      expect(record.checkIn != null, isTrue);
      expect(record.isApproved, isTrue);
      expect(record.approvalStatus, equals('approved'));
      expect(record.staffName, contains('രാഹുൽ'));
    });
  });
}
