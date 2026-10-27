import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import '../../attendance/attendance_service.dart';
import '../../attendance/attendance_models.dart';
import '../../attendance/owner_attendance_approvals_view.dart';
import '../../auth/auth_controller.dart';
import '../../notifications/notification_service.dart';
import '../../notifications/tek_notification_panel.dart';
import '../../reminders/reminder_service.dart';
import '../../reminders/reminders_screen.dart';
import '../../reminders/followups_screen.dart';
import '../../update/app_update_management_view.dart';
import '../../utils/tek_helpers.dart';
import '../../main.dart'
    show
        Db,
        rs,
        SaleView,
        ItemsView,
        ServicesView,
        StaffView,
        PartiesView,
        CashBankView,
        ReportsView,
        SettingsView,
        AuditLogView,
        BackupSyncView,
        showItemForm,
        showServiceJobForm,
        showPartyForm;

import '../tek_global_search_dialog.dart';
import 'dashboard_tokens.dart';
import 'sidebar.dart';
import 'top_bar.dart';
import 'hero_banner.dart';
import 'alert_banner.dart';
import 'stat_card.dart';
import 'sales_chart.dart';
import 'quick_actions.dart';
import 'recent_activity.dart';
import 'service_summary.dart';
import 'weather_card.dart';

/// Pixel-faithful Home / Dashboard Screen for TekFix ERP.
/// Responsive desktop 3-area layout (Fixed Sidebar, Top Bar, Scrollable Content)
/// and phone Drawer layout with 2-column cards.
/// Live updates from Hive with zero main-thread freezing.
class TekDashboardScreen extends StatefulWidget {
  final Function(int moduleIndex)? onNavigateModule;

  const TekDashboardScreen({
    super.key,
    this.onNavigateModule,
  });

  @override
  State<TekDashboardScreen> createState() => _TekDashboardScreenState();
}

class _TekDashboardScreenState extends State<TekDashboardScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  String _activeMenu = 'Dashboard';

  void _navigateTo(Widget page, [String? menuLabel]) {
    if (menuLabel != null) setState(() => _activeMenu = menuLabel);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _handleSidebarSelect(String item) {
    setState(() => _activeMenu = item);

    if (widget.onNavigateModule != null) {
      final idx = _mapSidebarItemToIndex(item);
      if (idx != null) {
        widget.onNavigateModule!(idx);
        return;
      }
    }

    switch (item) {
      case 'Dashboard':
        break;
      case 'Sale / POS':
        _navigateTo(const SaleView(), item);
        break;
      case 'Items / Stock':
        _navigateTo(const ItemsView(), item);
        break;
      case 'Services / Repairs':
        _navigateTo(const ServicesView(), item);
        break;
      case 'Staff Management':
        _navigateTo(const StaffView(), item);
        break;
      case 'Customer Management':
        _navigateTo(const PartiesView(), item);
        break;
      case 'Payment Reminders':
        _navigateTo(const RemindersScreen(), item);
        break;
      case 'After-Sales Follow-ups':
        _navigateTo(const FollowupsScreen(), item);
        break;
      case 'Settings & Print':
        _navigateTo(const SettingsView(), item);
        break;
      case 'App Updates & Releases':
        _navigateTo(const AppUpdateManagementView(), item);
        break;
      case 'Backup & Sync':
        _navigateTo(const BackupSyncView(), item);
        break;
      case 'Audit / Change History':
        _navigateTo(const AuditLogView(), item);
        break;
      case 'System Settings':
        _navigateTo(const SettingsView(), item);
        break;
      default:
        break;
    }
  }

  int? _mapSidebarItemToIndex(String item) {
    switch (item) {
      case 'Dashboard':
        return 0;
      case 'Sale / POS':
        return 1;
      case 'Items / Stock':
        return 2;
      case 'Services / Repairs':
        return 3;
      case 'Customer Management':
        return 5;
      case 'Staff Management':
        return 8;
      case 'Payment Reminders':
        return 14;
      case 'After-Sales Follow-ups':
        return 15;
      case 'App Updates & Releases':
        return 16;
      case 'Backup & Sync':
        return 17;
      case 'Audit / Change History':
        return 18;
      case 'Settings & Print':
      case 'System Settings':
        return 19;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final isOwner = auth.isOwner;
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= 980;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
          TekGlobalSearchDialog.show(
            context,
            onNavigate: widget.onNavigateModule,
          );
        },
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () {
          TekGlobalSearchDialog.show(
            context,
            onNavigate: widget.onNavigateModule,
          );
        },
      },
      child: Focus(
        autofocus: true,
        child: StreamBuilder<List<AttendanceRecord>>(
          stream: AttendanceService.instance.streamPendingApprovals(auth.shopId),
          builder: (context, attendanceSnap) {
            final pendingAttendance = attendanceSnap.data?.length ?? 0;

            return StreamBuilder<int>(
              stream: NotificationService.instance.streamUnreadCount(auth.shopId, auth.uid),
              builder: (context, notifSnap) {
                final unreadNotifs = notifSnap.data ?? 0;

                // Live Hive DB listener for overdue reminders count
                return ValueListenableBuilder(
                  valueListenable: Db.parties.listenable(),
                  builder: (context, Box partiesBox, _) {
                    int dueRemindersCount = 0;
                    for (final v in partiesBox.values) {
                      if (v is! Map) continue;
                      final p = tekM(v);
                      if (tekD(p['balance']) > 0) {
                        final eval = ReminderService.instance.evaluateCustomerReminder(p);
                        if (eval['isDue'] == true) dueRemindersCount++;
                      }
                    }

                    // Top Bar component
                    final topBar = TekTopBar(
                      showMenuButton: !isDesktop,
                      onMenuTap: () => _scaffoldKey.currentState?.openDrawer(),
                      unreadNotificationsCount: unreadNotifs,
                      userName: auth.name.isNotEmpty ? auth.name : 'Tekfix',
                      shopName: Db.setting('shop_name', 'TEKFIX DIGITAL'),
                      onSearchTap: () => TekGlobalSearchDialog.show(
                        context,
                        onNavigate: widget.onNavigateModule,
                      ),
                      onNotificationsTap: () => TekNotificationPanel.show(
                        context,
                        shopId: auth.shopId,
                        staffId: auth.uid,
                        onNavigateModule: widget.onNavigateModule,
                      ),
                      onProfileTap: () => _navigateTo(const SettingsView()),
                      onSignOut: () => auth.signOut(),
                    );

                    // Sidebar component
                    final sidebar = TekSidebar(
                      activeItem: _activeMenu,
                      onItemSelected: (item) {
                        if (!isDesktop) Navigator.of(context).pop();
                        _handleSidebarSelect(item);
                      },
                      pendingAttendanceCount: pendingAttendance,
                      overdueRemindersCount: dueRemindersCount,
                    );

                    return Scaffold(
                      key: _scaffoldKey,
                      drawer: isDesktop
                          ? null
                          : Drawer(backgroundColor: const Color(0xFF0C1236), child: sidebar),
                      body: Container(
                        decoration: const BoxDecoration(
                          gradient: DashboardColors.backgroundGradient,
                        ),
                        child: isDesktop
                            ? Row(
                                children: [
                                  // 1. Fixed Left Sidebar
                                  sidebar,

                                  // 2. Main Right Area (Top Bar + Scrollable Content)
                                  Expanded(
                                    child: Column(
                                      children: [
                                        topBar,
                                        Expanded(
                                          child: TekDashboardContent(
                                            onNavigateModule: widget.onNavigateModule,
                                            onNavigateTo: _navigateTo,
                                            isDesktop: true,
                                            isOwner: isOwner,
                                            pendingAttendance: pendingAttendance,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                children: [
                                  topBar,
                                  Expanded(
                                    child: TekDashboardContent(
                                      onNavigateModule: widget.onNavigateModule,
                                      onNavigateTo: _navigateTo,
                                      isDesktop: false,
                                      isOwner: isOwner,
                                      pendingAttendance: pendingAttendance,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// Standalone, reusable Dashboard Content widget.
/// Renders Hero Banner, Alert Banner, 4 Stat Cards with Sparklines,
/// Sales Overview Line Chart, Quick Actions 3x2 Grid, Weather Card,
/// Service Summary, and Recent Activity.
class TekDashboardContent extends StatelessWidget {
  final Function(int moduleIndex)? onNavigateModule;
  final Function(Widget page, [String? label])? onNavigateTo;
  final bool? isDesktop;
  final bool isOwner;
  final int? pendingAttendance;

  const TekDashboardContent({
    super.key,
    this.onNavigateModule,
    this.onNavigateTo,
    this.isDesktop,
    this.isOwner = true,
    this.pendingAttendance,
  });

  void _nav(BuildContext context, Widget page, [String? label]) {
    if (onNavigateTo != null) {
      onNavigateTo!(page, label);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final isDesktopResolved = isDesktop ?? (MediaQuery.of(context).size.width >= 980);

    return ListenableBuilder(
      listenable: Listenable.merge([
        Db.sales.listenable(),
        Db.items.listenable(),
        Db.parties.listenable(),
        Db.bank.listenable(),
        Db.services.listenable(),
        Db.audit.listenable(),
        Db.stockMoves.listenable(),
      ]),
      builder: (context, _) {
        double cashInHand = Db.cash;
        double bankBalance = Db.bankBalance;
        double receivablesTotal = 0;
        int dueRemindersCount = 0;

        for (final v in Db.parties.values) {
          if (v is! Map) continue;
          final p = tekM(v);
          final bal = tekD(p['balance']);
          if (bal > 0) {
            receivablesTotal += bal;
            final eval = ReminderService.instance.evaluateCustomerReminder(p);
            if (eval['isDue'] == true) dueRemindersCount++;
          }
        }

        // 4 Stat Cards
        final statCards = [
          TekStatCard(
            title: 'Cash in Hand',
            subtitle: 'കയ്യിലുള്ള പണം',
            amount: rs(cashInHand),
            icon: Icons.payments_rounded,
            accentColor: DashboardColors.neonBlue,
            changeText: '12.5%',
            isPositive: true,
            sparklineData: const [25, 30, 42, 38, 55, 48, 65, 78],
            onTap: () => _nav(context, const CashBankView()),
          ),
          TekStatCard(
            title: 'Bank Balance',
            subtitle: 'ബാങ്ക് അക്കൗണ്ട്',
            amount: rs(bankBalance),
            icon: Icons.account_balance_rounded,
            accentColor: DashboardColors.neonGreen,
            changeText: '8.2%',
            isPositive: true,
            sparklineData: const [40, 45, 42, 50, 58, 62, 70, 85],
            onTap: () => _nav(context, const CashBankView()),
          ),
          TekStatCard(
            title: 'Receivable',
            subtitle: 'കിട്ടാനുള്ള തുക',
            amount: rs(receivablesTotal),
            icon: Icons.call_received_rounded,
            accentColor: DashboardColors.neonPurple,
            changeText: '3.1%',
            isPositive: false,
            sparklineData: const [70, 65, 68, 55, 52, 48, 42, 38],
            onTap: () => _nav(context, const PartiesView()),
          ),
          TekStatCard(
            title: 'Reminders Due',
            subtitle: 'ഓർമ്മപ്പെടുത്തലുകൾ',
            amount: dueRemindersCount > 0 ? '$dueRemindersCount Due' : 'All Clear',
            icon: Icons.notification_important_rounded,
            accentColor: dueRemindersCount > 0 ? DashboardColors.neonPink : DashboardColors.neonGreen,
            changeText: dueRemindersCount > 0 ? '$dueRemindersCount Due' : 'Clear',
            isPositive: dueRemindersCount == 0,
            sparklineData: dueRemindersCount > 0
                ? const [10, 20, 15, 30, 25, 45, 60, 75]
                : const [60, 50, 40, 30, 20, 15, 10, 5],
            onTap: () => _nav(context, const RemindersScreen()),
          ),
        ];

        return StreamBuilder<List<AttendanceRecord>>(
          stream: AttendanceService.instance.streamPendingApprovals(auth.shopId),
          builder: (context, snap) {
            final pendingCount = pendingAttendance ?? (snap.data?.length ?? 0);

            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
              children: [
                // 1. Hero Banner
                const TekHeroBanner(
                  title: 'TEKFIX ERP',
                  subtitle: 'Smarter Business. Greater Growth.',
                ),

                // 2. Alert Banner (Orange gradient, attendance approvals pending)
                if (isOwner)
                  TekAlertBanner(
                    pendingCount: pendingCount,
                    onReview: () => _nav(
                      context,
                      OwnerAttendanceApprovalsView(shopId: auth.shopId),
                    ),
                  ),

                const SizedBox(height: 20),

                // 3. 4 Stat Cards (Responsive Grid: 4 in row on wide, 2x2 on phone/tablet)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final count = constraints.maxWidth >= 900 ? 4 : 2;
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: statCards.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: count,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                        childAspectRatio: constraints.maxWidth >= 900 ? 1.55 : 1.35,
                      ),
                      itemBuilder: (_, i) => statCards[i],
                    );
                  },
                ),

                const SizedBox(height: 20),

                // 4. Desktop 2-Column Split vs Mobile Vertical Stack
                if (isDesktopResolved)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Left Column (approx 63%): Sales Overview + Quick Actions
                      Expanded(
                        flex: 63,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const TekSalesOverviewChart(),
                            const SizedBox(height: 20),
                            TekQuickActionsGrid(
                              onNewSale: () => _nav(context, const SaleView()),
                              onAddItem: () => showItemForm(context),
                              onServiceRequest: () => showServiceJobForm(context),
                              onAddCustomer: () => showPartyForm(context),
                              onViewReports: () => _nav(context, const ReportsView()),
                              onOpenSettings: () => _nav(context, const SettingsView()),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 18),

                      // Right Column (approx 37%): Weather Card + Service Summary + Recent Activity
                      Expanded(
                        flex: 37,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const TekWeatherCard(),
                            const SizedBox(height: 18),
                            TekServiceSummary(
                              onSelectFilter: (f) => _nav(context, ServicesView(initialFilter: f)),
                            ),
                            const SizedBox(height: 18),
                            TekRecentActivity(
                              onViewAll: () => _nav(context, const AuditLogView()),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                else
                  // Mobile Stack Layout
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const TekSalesOverviewChart(),
                      const SizedBox(height: 20),
                      TekQuickActionsGrid(
                        onNewSale: () => _nav(context, const SaleView()),
                        onAddItem: () => showItemForm(context),
                        onServiceRequest: () => showServiceJobForm(context),
                        onAddCustomer: () => showPartyForm(context),
                        onViewReports: () => _nav(context, const ReportsView()),
                        onOpenSettings: () => _nav(context, const SettingsView()),
                      ),
                      const SizedBox(height: 20),
                      const TekWeatherCard(),
                      const SizedBox(height: 20),
                      TekServiceSummary(
                        onSelectFilter: (f) => _nav(context, ServicesView(initialFilter: f)),
                      ),
                      const SizedBox(height: 20),
                      TekRecentActivity(
                        onViewAll: () => _nav(context, const AuditLogView()),
                      ),
                    ],
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
