import '../../reports/profit_loss_view.dart';
import 'dart:io' show Platform;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import '../../firebase_options.dart';
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
import '../../update/windows_update_service.dart';
import '../../update/windows_update_banner.dart';
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
import '../../expenses/add_expense_dialog.dart';
import '../../rent/daily_rent_payment_dialog.dart';
import '../../owner/owner_withdrawal_dialog.dart';
import '../../owner/owner_ledger_view.dart';
import '../../owner/owner_trusted_devices_screen.dart';
import '../../recharge/quick_recharge_screen.dart';
import '../../recharge/quick_recharge_dialog.dart';
import '../../returns/returns_dashboard_view.dart';
import '../../purchases/purchase_bills_dashboard_view.dart';
import '../../expenses/expense_management_screen.dart';
import '../../rent/daily_rent_history_view.dart';
import '../../pos/daily_sales_ledger_view.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!kIsWeb && Platform.isWindows) {
        final winService = WindowsUpdateService.instance;
        winService.initialize().then((_) {
          if (winService.settings.checkOnStartup) {
            winService.checkForUpdates();
          }
        });
      }
    });
  }

  void _navigateTo(Widget page, [String? menuLabel]) {
    if (menuLabel != null) setState(() => _activeMenu = menuLabel);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _handleSidebarSelect(String item) {
    setState(() => _activeMenu = item);

    // Pages are opened directly. The old numeric index map sent several
    // items to the wrong module (e.g. 'Customer Management' -> 6, which is
    // 'Customer Returns' in AppShell) and some items did nothing at all.
    final shopId = AuthController.instance.shopId;
    switch (item) {
      case 'Dashboard':
        break;
      case 'Daily Sales & EOD':
        _navigateTo(DailySalesLedgerView(shopId: shopId), item);
        break;
      case 'Customer Returns':
        _navigateTo(const ReturnsDashboardView(), item);
        break;
      case 'Purchase Bills':
        _navigateTo(const PurchaseBillsDashboardView(), item);
        break;
      case 'Expenses':
        _navigateTo(ExpenseManagementScreen(shopId: shopId), item);
        break;
      case 'Daily Rent Ledger':
        _navigateTo(DailyRentHistoryView(shopId: shopId), item);
        break;
      case 'Sale / POS':
        _navigateTo(const SaleView(), item);
        break;
      case 'Quick Recharge':
        // Phase 13.3.0 Owner-Only Recharge Policy enforcement
        if (!AuthController.instance.isOwner) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                '❌ അനധികൃത പ്രവേശനം: ഉടമയ്ക്ക് മാത്രമേ റീച്ചാർജ് അക്കൗണ്ടിംഗ് ഉപയോഗിക്കാൻ അനുവാദമുള്ളൂ (Owner only).',
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
          break;
        }
        _navigateTo(const QuickRechargeScreen(), item);
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
        _navigateTo(const PartiesView(initialType: 'customer'), item);
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
      case 'Owner Salary & Drawings':
        _navigateTo(OwnerLedgerView(shopId: shopId), item);
        break;
      case 'Profit & Loss':
        if (!AuthController.instance.isOwner) break;
        _navigateTo(const ProfitLossView(), item);
        break;
      case 'Trusted Devices':
        if (!AuthController.instance.isOwner) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('❌ ഉടമയ്ക്ക് മാത്രമേ വിശ്വസനീയ ഉപകരണങ്ങൾ കാണാൻ അനുവാദമുള്ളൂ (Owner only).'),
              backgroundColor: Colors.redAccent,
            ),
          );
          break;
        }
        _navigateTo(const OwnerTrustedDevicesScreen(), item);
        break;
      case 'System Settings':
        _navigateTo(const SettingsView(), item);
        break;
      default:
        break;
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
          stream: (DefaultFirebaseOptions.isUatMode || Firebase.apps.isEmpty)
              ? const Stream.empty()
              : AttendanceService.instance.streamPendingApprovals(auth.shopId),
          builder: (context, attendanceSnap) {
            final pendingAttendance = attendanceSnap.data?.length ?? 0;

            return StreamBuilder<int>(
              stream: NotificationService.instance
                  .streamUnreadCount(auth.shopId, auth.uid),
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
                        final eval = ReminderService.instance
                            .evaluateCustomerReminder(p);
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
                          : Drawer(
                              backgroundColor: const Color(0xFF0E131D),
                              child: sidebar),
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
                                            onNavigateModule:
                                                widget.onNavigateModule,
                                            onNavigateTo: _navigateTo,
                                            isDesktop: true,
                                            isOwner: isOwner,
                                            pendingAttendance:
                                                pendingAttendance,
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
    final isDesktopResolved =
        isDesktop ?? (MediaQuery.of(context).size.width >= 980);
    // HomeView builds `const TekDashboardContent()`, so the `isOwner` field
    // defaulted to true for staff too. Always confirm with the auth state.
    final ownerView = isOwner && auth.isOwner;

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
        double payablesTotal = 0;
        int dueRemindersCount = 0;

        for (final v in Db.parties.values) {
          if (v is! Map) continue;
          final p = tekM(v);
          final isSupplier = p['type'] == 'Supplier';
          final bal = tekD(p['balance']);
          if (!isSupplier) {
            // Customer receivables (amount owed to shop)
            if (bal > 0.005) {
              receivablesTotal += bal;
              final eval = ReminderService.instance.evaluateCustomerReminder(p);
              if (eval['isDue'] == true) dueRemindersCount++;
            }
          } else {
            // Supplier payables (amount shop owes to supplier)
            if (bal < -0.005) {
              payablesTotal += (-bal);
            } else if (bal > 0.005) {
              payablesTotal += bal;
            }
          }
        }

        // ---- Real figures for the header + KPI cards ----
        final now = DateTime.now();
        final todayKey = DateTime(now.year, now.month, now.day);
        final last7 = <DateTime, double>{
          for (int i = 6; i >= 0; i--)
            todayKey.subtract(Duration(days: i)): 0.0,
        };
        int todayBills = 0;
        for (final v in Db.sales.values) {
          if (v is! Map) continue;
          final s = tekM(v);
          if (isSaleReturned(s)) continue;
          final day = _businessDay(s);
          if (day == null || !last7.containsKey(day)) continue;
          final amt = tekD(s['total']) - tekD(s['returnedAmount']);
          last7[day] = (last7[day] ?? 0) + (amt > 0 ? amt : 0);
          if (day == todayKey) todayBills++;
        }
        final todaySales = last7[todayKey] ?? 0;
        final yesterdaySales =
            last7[todayKey.subtract(const Duration(days: 1))] ?? 0;
        String? salesChange;
        if (yesterdaySales > 0) {
          final pct = (todaySales - yesterdaySales) / yesterdaySales * 100;
          salesChange = '${pct.abs().toStringAsFixed(0)}% vs ഇന്നലെ';
        }

        int activeJobs = 0;
        for (final v in Db.services.values) {
          if (v is! Map) continue;
          final st = '${v['status'] ?? ''}';
          if (st == 'In Progress' ||
              st == 'Diagnosing' ||
              st == 'Received' ||
              st == 'Waiting for Parts') {
            activeJobs++;
          }
        }

        final summaryParts = <String>[
          'ഇന്ന് ${rs(todaySales)} വിൽപ്പന ($todayBills ബിൽ)',
          if (activeJobs > 0) '$activeJobs റിപ്പയർ നടക്കുന്നു',
          if (dueRemindersCount > 0) '$dueRemindersCount റിമൈൻഡർ',
        ];

        // 4 KPI cards — every number here comes from real records.
        final statCards = [
          TekStatCard(
            title: "Today's Sales",
            subtitle: todayBills == 1 ? '1 ബിൽ ഇന്ന്' : '$todayBills ബില്ലുകൾ ഇന്ന്',
            amount: rs(todaySales),
            icon: Icons.trending_up_rounded,
            accentColor: DashboardColors.neonBlue,
            changeText: salesChange,
            isPositive: todaySales >= yesterdaySales,
            sparklineData: last7.values.toList(),
            onTap: () => _nav(
              context,
              DailySalesLedgerView(shopId: auth.shopId),
            ),
          ),
          TekStatCard(
            title: 'Cash in Hand',
            subtitle: 'Bank: ${rs(bankBalance)}',
            amount: rs(cashInHand),
            icon: Icons.payments_rounded,
            accentColor: DashboardColors.neonGreen,
            onTap: () => _nav(context, const CashBankView()),
          ),
          TekStatCard(
            title: 'Receivable',
            subtitle: payablesTotal > 0
                ? 'Payable: ${rs(payablesTotal)}'
                : 'കിട്ടാനുള്ള തുക',
            amount: rs(receivablesTotal),
            icon: Icons.call_received_rounded,
            accentColor: DashboardColors.neonPurple,
            onTap: () => _nav(
              context,
              const PartiesView(initialType: 'customer', filterDueOnly: true),
            ),
          ),
          TekStatCard(
            title: 'Reminders Due',
            subtitle: dueRemindersCount > 0
                ? 'ഓർമ്മപ്പെടുത്തേണ്ടവർ'
                : 'എല്ലാം ക്ലിയർ',
            amount: dueRemindersCount > 0 ? '$dueRemindersCount' : '0',
            icon: Icons.notification_important_rounded,
            accentColor: dueRemindersCount > 0
                ? DashboardColors.neonPink
                : DashboardColors.neonGreen,
            onTap: () => _nav(context, const RemindersScreen()),
          ),
        ];

        Widget quickActions() => TekQuickActionsGrid(
              onNewSale: () => _nav(context, const SaleView()),
              onAddItem: () => showItemForm(context),
              onAddExpense: () => AddExpenseDialog.show(context),
              onDailyRent: () => DailyRentPaymentDialog.show(context),
              // Owner-only actions are hidden for staff accounts
              // (previously shown to everyone).
              onOwnerWithdrawal:
                  ownerView ? () => OwnerWithdrawalDialog.show(context) : null,
              onRecharge:
                  ownerView ? () => QuickRechargeDialog.show(context) : null,
              onServiceRequest: () => showServiceJobForm(context),
              onAddCustomer: () => showPartyForm(context),
              onViewReports: () => _nav(context, const ReportsView()),
              onOpenSettings: () => _nav(context, const SettingsView()),
            );

        Widget kpiGrid() => LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final count = w >= 900 ? 4 : 2;
                final gap = w < 380 ? 10.0 : 14.0;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: statCards.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    crossAxisSpacing: gap,
                    mainAxisSpacing: gap,
                    // Fixed height instead of an aspect ratio, so cards never
                    // clip on narrow phones or stretch on wide monitors.
                    mainAxisExtent: w < 380 ? 148 : 144,
                  ),
                  itemBuilder: (_, i) => statCards[i],
                );
              },
            );

        return StreamBuilder<List<AttendanceRecord>>(
          stream: (DefaultFirebaseOptions.isUatMode || Firebase.apps.isEmpty)
              ? const Stream.empty()
              : AttendanceService.instance.streamPendingApprovals(auth.shopId),
          builder: (context, snap) {
            final pendingCount = pendingAttendance ?? (snap.data?.length ?? 0);
            return LayoutBuilder(
              builder: (context, box) {
                // Centre the content at max 1360px on very wide monitors while
                // keeping the whole area scrollable.
                final basePad = isDesktopResolved ? 28.0 : 16.0;
                final extra = (box.maxWidth - 1360) / 2;
                final hPad = extra > basePad ? extra : basePad;
                return ListView(
                  padding: EdgeInsets.fromLTRB(
                    hPad,
                    isDesktopResolved ? 24.0 : 14.0,
                    hPad,
                    isDesktopResolved
                        ? 32.0
                        : (MediaQuery.of(context).padding.bottom + 85.0),
                  ),
                  children: [
                    if (!kIsWeb && Platform.isWindows)
                      const WindowsUpdateBanner(),

                    // 1. Greeting header + primary action
                    TekHeroBanner(
                      title: 'TekFix ERP',
                      userName: auth.name.isNotEmpty ? auth.name : null,
                      summary: summaryParts.join(' · '),
                      customDateNote: Db.setting('shop_hours', ''),
                      onPrimaryAction: () => _nav(context, const SaleView()),
                    ),

                    // 2. Attendance approvals alert (owner)
                    if (ownerView)
                      TekAlertBanner(
                        pendingCount: pendingCount,
                        onReview: () => _nav(
                          context,
                          OwnerAttendanceApprovalsView(shopId: auth.shopId),
                        ),
                      ),

                    const SizedBox(height: 20),

                    // 3. Quick actions — the most used things, near the top
                    quickActions(),

                    const SizedBox(height: 20),

                    // 4. KPI cards
                    kpiGrid(),

                    const SizedBox(height: 20),

                    // 5. Chart + service/activity
                    if (isDesktopResolved)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Expanded(
                            flex: 63,
                            child: TekSalesOverviewChart(),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 37,
                            child: TekServiceSummary(
                              onSelectFilter: (f) =>
                                  _nav(context, ServicesView(initialFilter: f)),
                            ),
                          ),
                        ],
                      )
                    else ...[
                      const TekSalesOverviewChart(),
                      const SizedBox(height: 16),
                      TekServiceSummary(
                        onSelectFilter: (f) =>
                            _nav(context, ServicesView(initialFilter: f)),
                      ),
                    ],

                    const SizedBox(height: 16),

                    TekRecentActivity(
                      onViewAll: () => _nav(context, const AuditLogView()),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Business day of a sale in local time: backdated bills carry 'saleDate',
/// older bills only 'createdAt'. Both are stored as ISO strings (often UTC).
DateTime? _businessDay(Map<String, dynamic> s) {
  final raw = s['saleDate'] ?? s['createdAt'];
  if (raw == null) return null;
  final parsed = DateTime.tryParse('$raw');
  if (parsed == null) return null;
  final l = parsed.toLocal();
  return DateTime(l.year, l.month, l.day);
}
