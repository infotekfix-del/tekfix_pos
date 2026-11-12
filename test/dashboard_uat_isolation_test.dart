import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/attendance/attendance_models.dart';
import 'package:tekfix_erp_pos/attendance/attendance_service.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/firebase_options.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/notifications/notification_service.dart';
import 'package:tekfix_erp_pos/pos/daily_register_service.dart';
import 'package:tekfix_erp_pos/pos/pos_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_dashboard_uat_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      if (!Hive.isBoxOpen(b)) {
        await Hive.openBox(b);
      }
    }
  });

  tearDownAll(() async {
    try {
      await Hive.close().timeout(const Duration(seconds: 2), onTimeout: () => null);
    } catch (_) {}
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('TEKFIX ERP — Phase 15.4.5 Physical Android Runtime Crash & Dashboard Isolation', () {
    test('1. UAT mode detection or zero-Firebase fallback active', () {
      expect(DefaultFirebaseOptions.isUatMode || Firebase.apps.isEmpty, isTrue);
    });

    test('2. AttendanceService streamPendingApprovals returns safe empty stream in UAT mode', () async {
      final approvalsStream = AttendanceService.instance.streamPendingApprovals('shop_staging_001');
      final approvals = await approvalsStream.first;
      expect(approvals, isEmpty);
    });

    test('3. AttendanceService streamTodayAttendance returns null/cached in UAT mode without throwing', () async {
      final todayStream = AttendanceService.instance.streamTodayAttendance('shop_staging_001', 'staff_1');
      final today = await todayStream.first;
      expect(today, isNull);
    });

    test('4. AttendanceService streamAllTodayAttendance returns empty stream in UAT mode', () async {
      final allTodayStream = AttendanceService.instance.streamAllTodayAttendance('shop_staging_001');
      final allToday = await allTodayStream.first;
      expect(allToday, isEmpty);
    });

    test('5. AttendanceService streamMonthAttendance returns empty stream in UAT mode', () async {
      final monthStream = AttendanceService.instance.streamMonthAttendance('shop_staging_001', '2026-11');
      final month = await monthStream.first;
      expect(month, isEmpty);
    });

    test('6. PosService streamCatalogItems returns local catalog in UAT mode without Firestore calls', () async {
      final stream = PosService.instance.streamCatalogItems('shop_staging_001');
      final items = await stream.first;
      expect(items, isNotNull);
    });

    test('7. DailyRegisterService reads sales, opening cash, and closed register locally in UAT mode', () async {
      final sales = await DailyRegisterService.instance.getSalesForDate(
        DateTime.now(),
        shopId: 'shop_staging_001',
      );
      expect(sales, isNotNull);

      final openingCash = await DailyRegisterService.instance.getOpeningCashForDate(
        DateTime.now(),
        shopId: 'shop_staging_001',
      );
      expect(openingCash, isNotNull);

      final closed = await DailyRegisterService.instance.getClosedRegister(
        '2026_11_11',
        shopId: 'shop_staging_001',
      );
      expect(closed, isNull);
    });

    test('8. NotificationService streamUnreadCount is a multi-subscription broadcast stream', () async {
      final stream = NotificationService.instance.streamUnreadCount('shop_staging_001', 'staff_1');
      expect(stream.isBroadcast, isTrue);

      // Verify two listeners can subscribe simultaneously without "Stream has already been listened to" error
      final sub1 = stream.listen((_) {});
      final sub2 = stream.listen((_) {});
      await Future.delayed(const Duration(milliseconds: 50));
      await sub1.cancel();
      await sub2.cancel();
    });

    test('9. AttendanceService streams are multi-subscription broadcast streams', () async {
      final stream = AttendanceService.instance.streamPendingApprovals('shop_staging_001');
      expect(stream.isBroadcast, isTrue);

      final sub1 = stream.listen((_) {});
      final sub2 = stream.listen((_) {});
      await Future.delayed(const Duration(milliseconds: 50));
      await sub1.cancel();
      await sub2.cancel();
    });

    test('10. AttendanceService recordAttendance and saveShiftConfig operate cleanly in UAT mode', () async {
      // Shift config save without Firestore throw
      await AttendanceService.instance.saveShiftConfig(
        'shop_staging_001',
        const ShiftConfig(),
      );

      // Record attendance locally in UAT mode
      final result = await AttendanceService.instance.recordAttendance(
        shopId: 'shop_staging_001',
        staffId: 'staff_101',
        staffName: 'Test Staff',
      );
      expect(result.isCheckIn, isTrue);
      expect(result.record.staffId, equals('staff_101'));
      expect(result.record.approvalStatus, equals('approved'));
    });
  });
}
