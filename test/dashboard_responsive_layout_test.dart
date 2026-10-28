import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/theme/tek_tokens.dart';
import 'package:tekfix_erp_pos/ui/dashboard/dashboard_tokens.dart';
import 'package:tekfix_erp_pos/ui/dashboard/hero_banner.dart';
import 'package:tekfix_erp_pos/ui/dashboard/quick_actions.dart';
import 'package:tekfix_erp_pos/ui/dashboard/recent_activity.dart';
import 'package:tekfix_erp_pos/ui/dashboard/sales_chart.dart';
import 'package:tekfix_erp_pos/ui/dashboard/service_summary.dart';
import 'package:tekfix_erp_pos/ui/dashboard/stat_card.dart';
import 'package:tekfix_erp_pos/ui/dashboard/top_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final tempDir = Directory.systemTemp.createTempSync('dashboard_test_hive_');
    Hive.init(tempDir.path);
    for (final box in allBoxes) {
      if (!Hive.isBoxOpen(box)) {
        await Hive.openBox(box);
      }
    }
  });

  tearDownAll(() async {
    await Hive.close();
  });

  Widget createTestHost(Widget child, Size size) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: child,
          ),
        ),
      ),
    );
  }

  group('Mobile Dashboard Responsiveness Tests (360x800 & 390x844)', () {
    const resolutions = [
      Size(360, 800), // Standard Android Mobile
      Size(390, 844), // Standard Modern Mobile DPI
    ];

    for (final resolution in resolutions) {
      testWidgets('TekSalesOverviewChart renders without overflow on ${resolution.width}x${resolution.height}', (tester) async {
        tester.view.physicalSize = Size(resolution.width, resolution.height);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          createTestHost(
            const SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: TekSalesOverviewChart(),
            ),
            resolution,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Sales Overview'), findsOneWidget);
        expect(find.text('വിൽപ്പന അവലോകനം'), findsOneWidget);
        expect(find.text('This Week'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Stat Cards Grid renders without overflow on ${resolution.width}x${resolution.height}', (tester) async {
        tester.view.physicalSize = Size(resolution.width, resolution.height);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        final statCards = [
          TekStatCard(
            title: 'Cash in Hand',
            subtitle: 'കയ്യിലുള്ള പണം',
            amount: '₹45,280',
            icon: Icons.account_balance_wallet_rounded,
            accentColor: DashboardColors.neonGreen,
            changeText: '+12.4%',
            isPositive: true,
            sparklineData: const [20, 30, 45, 40, 60, 75],
          ),
          TekStatCard(
            title: 'Bank Balance',
            subtitle: 'ബാങ്ക് അക്കൗണ്ട്',
            amount: '₹1,24,500',
            icon: Icons.account_balance_rounded,
            accentColor: DashboardColors.neonBlue,
            changeText: '+4.2%',
            isPositive: true,
            sparklineData: const [30, 40, 50, 48, 65, 80],
          ),
          TekStatCard(
            title: 'Pending Dues',
            subtitle: 'കിട്ടാനുള്ള തുക',
            amount: '₹18,400',
            icon: Icons.receipt_long_rounded,
            accentColor: DashboardColors.neonOrange,
            changeText: '-2.1%',
            isPositive: false,
            sparklineData: const [50, 40, 35, 45, 30, 25],
          ),
          TekStatCard(
            title: 'Reminders Due',
            subtitle: 'ഓർമ്മപ്പെടുത്തലുകൾ',
            amount: '3 Due',
            icon: Icons.notification_important_rounded,
            accentColor: DashboardColors.neonPink,
            changeText: '3 Due',
            isPositive: false,
            sparklineData: const [10, 20, 15, 30, 25, 45],
          ),
        ];

        await tester.pumpWidget(
          createTestHost(
            SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: statCards.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: resolution.width < 380 ? 10 : 14,
                  mainAxisSpacing: resolution.width < 380 ? 10 : 14,
                  childAspectRatio: resolution.width <= 360 ? 0.84 : 0.88,
                ),
                itemBuilder: (_, i) => statCards[i],
              ),
            ),
            resolution,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Cash in Hand'), findsOneWidget);
        expect(find.text('കയ്യിലുള്ള പണം'), findsOneWidget);
        expect(find.text('ബാങ്ക് അക്കൗണ്ട്'), findsOneWidget);
        expect(find.text('കിട്ടാനുള്ള തുക'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('TekQuickActionsGrid renders without overflow on ${resolution.width}x${resolution.height}', (tester) async {
        tester.view.physicalSize = Size(resolution.width, resolution.height);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          createTestHost(
            SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: TekQuickActionsGrid(
                onNewSale: () {},
                onAddItem: () {},
                onServiceRequest: () {},
                onAddCustomer: () {},
                onViewReports: () {},
                onOpenSettings: () {},
              ),
            ),
            resolution,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Quick Actions'), findsOneWidget);
        expect(find.text('ദ്രുത പ്രവർത്തനങ്ങൾ'), findsOneWidget);
        expect(find.text('New Sale'), findsOneWidget);
        expect(find.text('Add Item'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('TekHeroBanner renders without overflow on ${resolution.width}x${resolution.height}', (tester) async {
        tester.view.physicalSize = Size(resolution.width, resolution.height);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          createTestHost(
            const SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: TekHeroBanner(
                title: 'TEKFIX ERP',
                subtitle: 'Smarter Business. Greater Growth.',
              ),
            ),
            resolution,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('TEKFIX ERP'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('TekTopBar renders without overflow on ${resolution.width}x${resolution.height}', (tester) async {
        tester.view.physicalSize = Size(resolution.width, resolution.height);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          createTestHost(
            TekTopBar(
              userName: 'Nabeel',
              shopName: 'TekFix Digital',
              showMenuButton: true,
              unreadNotificationsCount: 3,
            ),
            resolution,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Search anything...'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('Malayalam Typography Tests', () {
    test('TekTypography.malayalam returns style with line-height >= 1.3', () {
      final style = TekTypography.malayalam(fontSize: 12);
      expect(style.height, greaterThanOrEqualTo(1.3));
    });

    test('DashboardTypography.malayalam returns style with line-height >= 1.3', () {
      final style = DashboardTypography.malayalam(fontSize: 11);
      expect(style.height, greaterThanOrEqualTo(1.3));
    });
  });
}
