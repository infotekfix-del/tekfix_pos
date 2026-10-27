// =============================================================================
// TEKFIX ERP & POS  —  single-file Flutter app (Hive storage)  •  v2
// (Dark-theme fixed: all text/background colors now follow the active theme)
// =============================================================================
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'auth/auth_controller.dart';
import 'auth/login_gate.dart';
import 'core/device.dart';
import 'staff/activity_log.dart';
import 'staff/staff_accounts_view.dart';
import 'staff/staff_tracking_view.dart';
import 'sync/sync_engine.dart';
import 'ui/sync_status_icon.dart';
import 'attendance/attendance_models.dart';
import 'attendance/attendance_service.dart';
import 'attendance/owner_attendance_dashboard.dart';
import 'attendance/owner_attendance_approvals_view.dart';
import 'attendance/staff_attendance_screen.dart';
import 'orders/owner_orders_view.dart';
import 'reminders/reminder_service.dart';
import 'reminders/reminders_screen.dart';
import 'reminders/followups_screen.dart';
import 'package:geolocator/geolocator.dart';
import 'update/app_update_management_view.dart';
import 'utils/tek_helpers.dart';
import 'utils/timestamp_adapter.dart';
import 'theme/tek_tokens.dart';
import 'orders/order_service.dart';
import 'orders/order_models.dart';
import 'ui/tek_feedback.dart';
import 'ui/tek_global_search_dialog.dart';
import 'ui/tek_top_nav_bar.dart';
import 'ui/tek_sales_chart.dart';
import 'ui/tek_quick_actions.dart';
import 'ui/tek_kpi_card.dart';
export 'utils/tek_helpers.dart';
export 'theme/tek_tokens.dart';

// -----------------------------------------------------------------------------
// CONSTANTS, FORMATTERS & SMALL HELPERS
// -----------------------------------------------------------------------------
const String boxItems = 'tek_items';
const String boxParties = 'tek_parties';
const String boxSales = 'tek_sales';
const String boxPurchases = 'tek_purchases';
const String boxExpenses = 'tek_expenses';
const String boxBank = 'tek_bank';
const String boxStaff = 'tek_staff';
const String boxSettings = 'tek_settings';
const String boxAudit = 'tek_audit_logs';
const String boxServices = 'tek_service_jobs';
const String boxStockMoves = 'tek_stock_movements';
const String boxSyncQueue = 'tek_sync_queue';
const List<String> allBoxes = [
  boxItems,
  boxParties,
  boxSales,
  boxPurchases,
  boxExpenses,
  boxBank,
  boxStaff,
  boxSettings,
  boxAudit,
  boxServices,
  boxStockMoves,
  boxSyncQueue,
];

const Color kPrimary = Color(0xFF1E3A8A);
const Color kInk = Color(0xFF111827);
const Color kBorder = Color(0xFFE5E7EB);

/// Theme-aware colors (work in both light and dark mode).
Color _muted(BuildContext c) => Theme.of(c).colorScheme.onSurfaceVariant;
Color _line(BuildContext c) => Theme.of(c).colorScheme.outlineVariant;
Color _surface(BuildContext c) => Theme.of(c).colorScheme.surface;

final _rs0 =
    NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
final _rs2 =
    NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
final _plain = NumberFormat('#,##0.00', 'en_IN');
final dtFormat = DateFormat('dd MMM yyyy, hh:mm a');
final dayFormat = DateFormat('dd MMM yyyy');
final _keyDay = DateFormat('yyyy-MM-dd');
final _keyMonth = DateFormat('yyyy-MM');

String rs(num v) =>
    (v - v.roundToDouble()).abs() < 0.005 ? _rs0.format(v) : _rs2.format(v);
double _d(dynamic v) => tekD(v);
int _i(dynamic v) => tekI(v);
double _r2(double v) => tekR2(v);
DateTime _dt(dynamic v) => tekDt(v);
Map<String, dynamic> _m(dynamic v) => tekM(v);

String _numText(dynamic v) {
  if (v == null) return '';
  final x = _d(v);
  return x == x.roundToDouble() ? x.toStringAsFixed(0) : x.toString();
}

bool _isToday(DateTime d) {
  final n = DateTime.now();
  return d.year == n.year && d.month == n.month && d.day == n.day;
}

bool _isReturned(Map s) => isSaleReturned(s);

/// Cash / UPI actually collected on an invoice (legacy invoices had no split).
double _billCash(Map s) =>
    s.containsKey('cash') ? _d(s['cash']) : _d(s['total']);

// -----------------------------------------------------------------------------
// DATABASE LAYER
// -----------------------------------------------------------------------------
class Db {
  static Box get items => Hive.box(boxItems);
  static Box get parties => Hive.box(boxParties);
  static Box get sales => Hive.box(boxSales);
  static Box get purchases => Hive.box(boxPurchases);
  static Box get expenses => Hive.box(boxExpenses);
  static Box get bank => Hive.box(boxBank);
  static Box get staff => Hive.box(boxStaff);
  static Box get settings => Hive.box(boxSettings);
  static Box get audit => Hive.box(boxAudit);
  static Box get services => Hive.box(boxServices);
  static Box get stockMoves => Hive.box(boxStockMoves);
  static Box get syncQueue => Hive.box(boxSyncQueue);

  // ---- Cross-device references ---------------------------------------------
  // Hive keys (0,1,2...) differ on every device; the `_id` stamped by the sync
  // engine is the same everywhere, so references are stored and resolved by it.
  static String? uidAt(Box b, dynamic key) {
    if (key == null) return null;
    final r = b.get(key);
    return r is Map ? r['_id'] as String? : null;
  }

  static dynamic keyByUid(Box b, dynamic uid) {
    if (uid == null) return null;
    for (final k in b.keys) {
      final r = b.get(k);
      if (r is Map && r['_id'] == uid) return k;
    }
    return null;
  }

  /// uuid first; the old local key is used only for records that have no uuid.
  static dynamic refKey(Box b, Map rec, String keyField, String uidField) {
    if (rec[uidField] != null) return keyByUid(b, rec[uidField]);
    return rec[keyField];
  }

  /// Every significant action is recorded with timestamp, staff, role,
  /// action type, device and details (see staff/activity_log.dart).
  static Future<void> logAction({
    required String action,
    required String entity,
    String entityId = '',
    dynamic oldValue,
    dynamic newValue,
    String reason = '',
    String user = '',
  }) =>
      ActivityLog.record(
          action: action,
          entity: entity,
          entityId: entityId,
          oldValue: oldValue,
          newValue: newValue,
          reason: reason,
          user: user);

  static double get cash => _d(bank.get('cash_in_hand'));
  static double get bankBalance => _d(bank.get('bank_balance'));

  static String setting(String key, [String def = '']) =>
      (settings.get(key, defaultValue: def) ?? def).toString();

  static Future<void> moveMoney(String mode, double amount, String note) async {
    if (amount == 0) return;
    final isCash = mode == 'Cash';
    final key = isCash ? 'cash_in_hand' : 'bank_balance';
    await bank.put(key, _r2(_d(bank.get(key)) + amount));
    final log = ((bank.get('txn_log') as List?) ?? []).toList();
    log.add({
      'date': DateTime.now().toIso8601String(),
      'account': isCash ? 'Cash' : 'Bank',
      'amount': amount,
      'note': note,
    });
    if (log.length > 500) log.removeRange(0, log.length - 500);
    await bank.put('txn_log', log);
    await logAction(
        action: amount >= 0 ? 'Money In' : 'Money Out',
        entity: 'Account',
        entityId: isCash ? 'Cash' : 'Bank',
        newValue: {'amount': amount, 'note': note});
  }

  static Future<void> adjustParty(dynamic key, double delta) async {
    if (key == null) return;
    final raw = parties.get(key);
    if (raw == null) return;
    final p = _m(raw);
    p['balance'] = _r2(_d(p['balance']) + delta);
    await parties.put(key, p);
  }

  static Future<void> stockMove(
      dynamic itemKey, String name, int delta, String reason) async {
    if (delta == 0) return;
    await stockMoves.add({
      'date': DateTime.now().toIso8601String(),
      'itemKey': itemKey,
      'itemId': uidAt(items, itemKey),
      'itemName': name,
      'delta': delta,
      'reason': reason,
    });
  }

  static Future<String> nextInvoice() async {
    final n = _i(settings.get('invoice_seq', defaultValue: 0)) + 1;
    await settings.put('invoice_seq', n);
    return '${setting('invoice_prefix', 'INV')}-${DeviceInfo.counterCode}${n.toString().padLeft(4, '0')}';
  }

  static Future<String> nextJobId() async {
    final n = _i(settings.get('job_seq', defaultValue: 0)) + 1;
    await settings.put('job_seq', n);
    return 'SRV-${DateFormat('yyyyMMdd').format(DateTime.now())}-${DeviceInfo.counterCode}${n.toString().padLeft(3, '0')}';
  }

  static Future<void> _restoreStock(
      Map<String, dynamic> s, String reason) async {
    for (final e in (s['items'] as List?) ?? const []) {
      final line = _m(e);
      final k = refKey(items, line, 'key', 'itemId');
      if (k == null) continue;
      final cur = items.get(k);
      if (cur != null) {
        final it = _m(cur);
        it['stock'] = _i(it['stock']) + _i(line['qty']);
        await items.put(k, it);
        await stockMove(k, '${it['name']}', _i(line['qty']), reason);
      }
    }
  }

  static Future<void> _refundSale(Map<String, dynamic> s, String note) async {
    final cash = _billCash(s);
    final upi = _d(s['upi']);
    if (cash > 0) await moveMoney('Cash', -cash, '$note ${s['invoice']}');
    if (upi > 0) await moveMoney('UPI', -upi, '$note ${s['invoice']}');
    if (_d(s['due']) > 0) {
      await adjustParty(
          refKey(parties, s, 'partyKey', 'partyId'), -_d(s['due']));
    }
  }

  static Future<void> cancelSale(dynamic key) async {
    final raw = sales.get(key);
    if (raw == null) return;
    final s = _m(raw);
    final alreadyReturned = _isReturned(s);
    // A returned bill has already had stock + money reversed.
    if (!alreadyReturned) {
      await _restoreStock(s, 'Cancelled ${s['invoice']}');
      await _refundSale(s, 'Cancelled');
    }
    await logAction(
        action: 'Invoice Deleted/Cancelled',
        entity: 'Invoice',
        entityId: '${s['invoice'] ?? key}',
        oldValue: s,
        reason: 'Admin-approved invoice deletion');
    await sales.delete(key);
  }

  static Future<void> returnSale(dynamic key) async {
    final raw = sales.get(key);
    if (raw == null) return;
    final s = _m(raw);
    if (_isReturned(s)) return;

    await _restoreStock(s, 'Sales return ${s['invoice']}');
    await _refundSale(s, 'Sales return');

    s['returned'] = true;
    s['status'] = 'RETURNED';
    s['returnedAt'] = DateTime.now().toIso8601String();
    await sales.put(key, s);
    await logAction(
        action: 'Sales Return',
        entity: 'Invoice',
        entityId: '${s['invoice'] ?? key}',
        oldValue: {'status': 'SOLD', 'total': s['total']},
        newValue: {'status': 'RETURNED', 'total': s['total']});
  }

  // ---- Backup / restore ----------------------------------------------------
  static String exportAll() {
    final boxes = <String, dynamic>{};
    for (final name in allBoxes) {
      if (name == boxSyncQueue) continue;
      final b = Hive.box(name);
      boxes[name] = [
        for (final k in b.keys) {'k': k, 'v': b.get(k)}
      ];
    }
    return const JsonEncoder.withIndent(' ').convert({
      'app': 'tekfix',
      'version': 2,
      'exportedAt': DateTime.now().toIso8601String(),
      'boxes': boxes,
    });
  }

  /// Returns number of records restored. Validates everything before touching data.
  static Future<int> importAll(String text) async {
    final data = jsonDecode(text);
    if (data is! Map || data['app'] != 'tekfix' || data['boxes'] is! Map) {
      throw const FormatException('ഇത് സാധുവായ TekFix ബാക്കപ്പ് അല്ല');
    }
    final boxes = data['boxes'] as Map;
    for (final name in allBoxes) {
      if (name == boxSyncQueue) continue;
      if (boxes[name] is! List) {
        throw FormatException('ബാക്കപ്പിൽ "$name" ഇല്ല');
      }
    }
    var n = 0;
    for (final name in allBoxes) {
      if (name == boxSyncQueue) continue;
      final b = Hive.box(name);
      final entries = <dynamic, dynamic>{};
      for (final e in boxes[name] as List) {
        final m = _m(e);
        if (m['k'] == null) continue;
        entries[m['k']] = m['v'];
        n++;
      }
      await b.clear();
      await b.putAll(entries);
    }
    return n;
  }
}

/// Confirm + admin password. Use for every destructive action.
Future<bool> guardedDelete(BuildContext c, String msg,
    {String yes = 'ഡിലീറ്റ്'}) async {
  if (!await confirm(c, msg, yes: yes)) return false;
  if (!c.mounted) return false;
  return askPin(c);
}

// -----------------------------------------------------------------------------
// APP ENTRY
// -----------------------------------------------------------------------------
Future<void> _openBoxWithRecovery(String b) async {
  try {
    if (Hive.isBoxOpen(b)) return;
    await Hive.openBox(b);
  } catch (e) {
    debugPrint('[TekFix Startup] Corrupted/unopenable Hive box detected: $b ($e). Recovering...');
    try {
      await Hive.deleteBoxFromDisk(b);
      debugPrint('[TekFix Startup] Cleared corrupted box file from disk: $b');
      await Hive.openBox(b);
      debugPrint('[TekFix Startup] Reopened fresh box: $b');
    } catch (e2) {
      debugPrint('[TekFix Startup] Fatal: Unable to recreate box $b: $e2');
    }
  }
}

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // 1. Hook FlutterError.onError so errors show on screen / in logs instead of crashing
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      debugPrint('[TekFix FlutterError] ${details.exceptionAsString()}');
      debugPrint('[TekFix FlutterError Stack] ${details.stack}');
    };

    // PlatformDispatcher error hook for uncaught async platform errors
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('[TekFix PlatformError] $error');
      debugPrint('[TekFix PlatformError Stack] $stack');
      return true; // prevent app process termination
    };

    debugPrint('[TekFix Startup] 1. Flutter engine binding initialized');

    // 2. Firebase Initialization (Optional, offline-first app starts even without it)
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      ).timeout(const Duration(seconds: 3));

      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: 100 * 1024 * 1024,
      );
      debugPrint('[TekFix Startup] 2. Firebase initialized with offline persistence');
    } catch (e) {
      debugPrint('[TekFix Startup] 2. Firebase init skipped or failed: $e');
    }

    // 3. Hive Initialization with Corrupt Box Recovery
    debugPrint('[TekFix Startup] 3. Initializing Hive storage...');
    try {
      await Hive.initFlutter();
      if (!Hive.isAdapterRegistered(42)) {
        Hive.registerAdapter(TimestampAdapter());
      }
    } catch (e) {
      debugPrint('[TekFix Startup] Hive.initFlutter warning: $e');
    }

    final allTargetBoxes = [
      ...allBoxes,
      'tek_sync_meta',
      'tek_sync_outbox',
    ];

    for (final b in allTargetBoxes) {
      await _openBoxWithRecovery(b);
    }

    try {
      await SyncEngine.instance.openBoxes();
    } catch (e) {
      debugPrint('[TekFix Startup] SyncEngine.openBoxes error: $e');
    }

    debugPrint('[TekFix Startup] 3. Hive initialized & all boxes verified');

    // 4. Default Settings Seeding
    const defaults = <String, dynamic>{
      'shop_name': 'TEKFIX',
      'shop_address': 'Irumbuzhi, Kerala 676509',
      'shop_phone': '7034093101',
      'shop_email': 'INFOTEKFIX@GMAIL.COM',
      'admin_pass': 'admin123',
      'active_user': 'Admin',
      'invoice_prefix': 'INV',
      'gst_rate': '0',
      'gstin': '',
      'invoice_footer': 'Thank you for your business!',
    };
    try {
      if (Hive.isBoxOpen(boxSettings)) {
        final s = Hive.box(boxSettings);
        for (final e in defaults.entries) {
          if (!s.containsKey(e.key)) await s.put(e.key, e.value);
        }
      }
    } catch (e) {
      debugPrint('[TekFix Startup] Settings seeding warning: $e');
    }

    // 5. AuthController Init
    debugPrint('[TekFix Startup] 4. Initializing AuthController...');
    try {
      await AuthController.instance.init().timeout(const Duration(seconds: 4));
    } catch (e) {
      debugPrint('[TekFix Startup] AuthController init warning: $e');
    }

    // 6. Custom on-screen error builder
    ErrorWidget.builder = (details) => Material(
          color: const Color(0xFF0F172A),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.error_outline_rounded, size: 52, color: Colors.amberAccent),
                  const SizedBox(height: 12),
                  const Text(
                    'ഒരു തകരാർ സംഭവിച്ചു (An Error Occurred)',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          '${details.exception}\n\n${details.stack}',
                          style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('ആപ്പ് വീണ്ടും തുറക്കുക (Reload App)'),
                    onPressed: () => runApp(const TekFixApp()),
                  ),
                ],
              ),
            ),
          ),
        );

    debugPrint('[TekFix Startup] 5. Launching TekFixApp UI...');
    runApp(const TekFixApp());
  }, (error, stack) {
    debugPrint('[TekFix FATAL Uncaught Zone Error] $error');
    debugPrint('[TekFix FATAL StackTrace] $stack');
  });
}

ThemeData _buildTheme([Brightness b = Brightness.light]) {
  if (b == Brightness.dark) {
    return TekTheme.darkTheme;
  }
  final dark = b == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(seedColor: kPrimary, brightness: b).copyWith(
    surface: dark ? const Color(0xFF1A2438) : Colors.white,
    onSurface: dark ? Colors.white : kInk,
    onSurfaceVariant: dark ? Colors.white70 : Colors.black54,
    outline: dark ? Colors.white38 : Colors.black26,
    outlineVariant: dark ? const Color(0xFF334155) : kBorder,
  );
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide(color: scheme.outlineVariant),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor:
        dark ? const Color(0xFF0B1220) : const Color(0xFFF4F6FA),
    textTheme: ThemeData(brightness: b).textTheme.apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: TextStyle(
          color: scheme.onSurface, fontSize: 18, fontWeight: FontWeight.w700),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    navigationBarTheme:
        NavigationBarThemeData(backgroundColor: scheme.surface, height: 66),
  );
}

class TekFixApp extends StatelessWidget {
  const TekFixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: AuthController.instance),
        ChangeNotifierProvider.value(value: SyncEngine.instance),
      ],
      child: MaterialApp(
        title: 'TekFix ERP & POS',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(),
        darkTheme: _buildTheme(Brightness.dark),
        // Enterprise dark theme as primary
        themeMode: ThemeMode.dark,
        home: const AuthGate(),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SHARED UI WIDGETS & DIALOG HELPERS
// -----------------------------------------------------------------------------
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final VoidCallback? onTap;
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin = EdgeInsets.zero,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: _surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _line(context)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class StatCard extends StatelessWidget {
  final String title, value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  const StatCard(this.title, this.value, this.icon, this.color,
      {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                    color: color.withAlpha(28),
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(icon, color: color, size: 18),
              ),
              const Spacer(),
              if (onTap != null)
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: _muted(context)),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: TextStyle(
                    color: color, fontSize: 19, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 2),
          Text(title, style: TextStyle(color: _muted(context), fontSize: 12.5)),
        ],
      ),
    );
  }
}

Widget statGrid(List<Widget> cards) => LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 900 ? 4 : (c.maxWidth >= 560 ? 3 : 2);
      final w = (c.maxWidth - 12 * (cols - 1)) / cols;
      return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final s in cards) SizedBox(width: w, child: s)]);
    });

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  const EmptyState(this.icon, this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted(context))),
          ],
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
      child: Row(
        children: [
          Expanded(
              child: Text(text,
                  style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.onSurface))),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class Pill extends StatelessWidget {
  final String text;
  final Color color;
  const Pill(this.text, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
          color: color.withAlpha(28), borderRadius: BorderRadius.circular(20)),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

class ModeSelector extends StatelessWidget {
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  const ModeSelector(
      {super.key,
      required this.value,
      required this.onChanged,
      this.options = const ['Cash', 'UPI']});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      showSelectedIcon: false,
      segments: [
        for (final o in options) ButtonSegment(value: o, label: Text(o))
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

void toast(BuildContext c, String msg, {bool error = false}) {
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
}

Widget tf(
  TextEditingController c,
  String label, {
  bool number = false,
  bool phone = false,
  bool obscure = false,
  int lines = 1,
  String? prefix,
  ValueChanged<String>? onChanged,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: c,
      obscureText: obscure,
      maxLines: obscure ? 1 : lines,
      onChanged: onChanged,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : phone
              ? TextInputType.phone
              : null,
      decoration: InputDecoration(labelText: label, prefixText: prefix),
    ),
  );
}

Future<bool> confirm(BuildContext c, String msg,
    {String yes = 'ഡിലീറ്റ്'}) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: const Text('ഉറപ്പാണോ?'),
      content: Text(msg),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('വേണ്ട')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
      ],
    ),
  );
  return r ?? false;
}

Future<bool> askPin(BuildContext c) async {
  final ctrl = TextEditingController();
  String? err;
  final ok = await showDialog<bool>(
    context: c,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('അഡ്മിൻ പാസ്‌വേഡ്'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration:
                  InputDecoration(labelText: 'Password', errorText: err),
              onSubmitted: (_) {
                if (ctrl.text == Db.setting('admin_pass', 'admin123')) {
                  Navigator.pop(ctx, true);
                } else {
                  set(() => err = 'പാസ്‌വേഡ് തെറ്റാണ്');
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('റദ്ദാക്കുക')),
          FilledButton(
            onPressed: () {
              if (ctrl.text == Db.setting('admin_pass', 'admin123')) {
                Navigator.pop(ctx, true);
              } else {
                set(() => err = 'പാസ്‌വേഡ് തെറ്റാണ്');
              }
            },
            child: const Text('ശരി'),
          ),
        ],
      ),
    ),
  );
  ctrl.dispose();
  return ok ?? false;
}

Future<void> formDialog(
  BuildContext context, {
  required String title,
  required Widget Function(StateSetter set) body,
  required Future<String?> Function() onSave,
  String saveLabel = 'സേവ്',
}) {
  String? error;
  return showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                body(set),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(error!,
                        style: TextStyle(
                            color: Colors.red.shade400, fontSize: 13)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('റദ്ദാക്കുക')),
          FilledButton(
            onPressed: () async {
              final e = await onSave();
              if (e == null) {
                if (ctx.mounted) Navigator.pop(ctx);
              } else {
                set(() => error = e);
              }
            },
            child: Text(saveLabel),
          ),
        ],
      ),
    ),
  );
}

// -----------------------------------------------------------------------------
// APP SHELL
// -----------------------------------------------------------------------------
class AppModule {
  final String label;
  final IconData icon;
  final Widget view;
  const AppModule(this.label, this.icon, this.view);
}

class NavCategory {
  final String title;
  final IconData icon;
  final List<AppModule> items;
  const NavCategory({
    required this.title,
    required this.icon,
    required this.items,
  });
}

List<NavCategory> _getNavCategories(String shopId) => [
  const NavCategory(
    title: 'Core POS & Operations',
    icon: Icons.storefront_rounded,
    items: [
      AppModule('Home', Icons.dashboard_rounded, HomeView()),
      AppModule('Sale / POS', Icons.point_of_sale_rounded, SaleView()),
      AppModule('Items / Stock', Icons.inventory_2_rounded, ItemsView()),
      AppModule('Services / Repairs', Icons.build_circle_rounded, ServicesView()),
    ],
  ),
  const NavCategory(
    title: 'Finance & Accounts',
    icon: Icons.account_balance_wallet_rounded,
    items: [
      AppModule('Purchase & Expense', Icons.shopping_bag_rounded, PurchaseExpenseView()),
      AppModule('Parties', Icons.groups_rounded, PartiesView()),
      AppModule('Cash & Bank', Icons.account_balance_rounded, CashBankView()),
      AppModule('Reports', Icons.bar_chart_rounded, ReportsView()),
    ],
  ),
  NavCategory(
    title: 'Staff Management',
    icon: Icons.people_alt_rounded,
    items: [
      const AppModule('Staff & Attendance', Icons.badge_rounded, StaffView()),
      AppModule('Attendance Approvals', Icons.fact_check_rounded,
          OwnerAttendanceApprovalsView(shopId: shopId)),
      AppModule('Attendance Dashboard', Icons.co_present_rounded,
          OwnerAttendanceDashboard(shopId: shopId)),
      const AppModule('Staff Live Tracking', Icons.monitor_heart_rounded, StaffTrackingView()),
      const AppModule('Staff Logins', Icons.manage_accounts_rounded, StaffAccountsView()),
      AppModule('Staff Orders', Icons.shopping_basket_rounded,
          OwnerOrdersView(shopId: shopId)),
    ],
  ),
  const NavCategory(
    title: 'Customer Management',
    icon: Icons.support_agent_rounded,
    items: [
      AppModule('Payment Reminders', Icons.notification_important_rounded,
          RemindersScreen()),
      AppModule('After-Sales Follow-ups', Icons.mark_chat_read_rounded,
          FollowupsScreen()),
    ],
  ),
  const NavCategory(
    title: 'Settings & System',
    icon: Icons.settings_suggest_rounded,
    items: [
      AppModule('App Updates & Releases', Icons.system_update_rounded,
          AppUpdateManagementView()),
      AppModule('Backup & Sync', Icons.cloud_sync_rounded, BackupSyncView()),
      AppModule('Audit / Change History', Icons.history_rounded, AuditLogView()),
      AppModule('Settings & Print', Icons.settings_rounded, SettingsView()),
    ],
  ),
];

class _AppShellPendingBadge extends StatefulWidget {
  final String shopId;
  final bool iconOnly;
  const _AppShellPendingBadge({required this.shopId, this.iconOnly = false});

  @override
  State<_AppShellPendingBadge> createState() => _AppShellPendingBadgeState();
}

class _AppShellPendingBadgeState extends State<_AppShellPendingBadge> {
  late Stream<List<AttendanceRecord>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = AttendanceService.instance.streamPendingApprovals(widget.shopId);
  }

  @override
  void didUpdateWidget(covariant _AppShellPendingBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shopId != widget.shopId) {
      _stream = AttendanceService.instance.streamPendingApprovals(widget.shopId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<AttendanceRecord>>(
      stream: _stream,
      builder: (context, snap) {
        final count = snap.data?.length ?? 0;
        if (count == 0) return const SizedBox.shrink();
        if (widget.iconOnly) {
          return const TekRedSignalBadge(count: 1, pulse: true, size: 8);
        }
        return TekRedSignalBadge(count: count, pulse: true, size: 18);
      },
    );
  }
}

class _AppShellOrdersBadge extends StatefulWidget {
  final String shopId;
  final bool iconOnly;
  const _AppShellOrdersBadge({required this.shopId, this.iconOnly = false});

  @override
  State<_AppShellOrdersBadge> createState() => _AppShellOrdersBadgeState();
}

class _AppShellOrdersBadgeState extends State<_AppShellOrdersBadge> {
  late Stream<List<StaffOrder>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = OrderService.instance.streamAllOrders(widget.shopId);
  }

  @override
  void didUpdateWidget(covariant _AppShellOrdersBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shopId != widget.shopId) {
      _stream = OrderService.instance.streamAllOrders(widget.shopId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<StaffOrder>>(
      stream: _stream,
      builder: (context, snap) {
        final orders = snap.data ?? [];
        final count = orders.where((o) =>
            o.status == StaffOrderStatus.submitted ||
            o.status == StaffOrderStatus.pending).length;
        if (count == 0) return const SizedBox.shrink();
        if (widget.iconOnly) {
          return const TekRedSignalBadge(count: 1, pulse: true, size: 8);
        }
        return TekRedSignalBadge(count: count, pulse: true, size: 18);
      },
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _sidebarCollapsed = false;
  final Set<String> _expandedCategories = {};

  @override
  void initState() {
    super.initState();
    _sidebarCollapsed = Db.setting('sidebar_collapsed', 'false') == 'true';
    final saved = Db.settings.get('expanded_nav_categories');
    if (saved is List && saved.isNotEmpty) {
      _expandedCategories.addAll(saved.cast<String>());
    } else {
      _expandedCategories.addAll([
        'Core POS & Operations',
        'Finance & Accounts',
        'Staff Management',
        'Customer Management',
        'Settings & System',
      ]);
    }
  }

  void _toggleCategory(String catTitle) {
    setState(() {
      if (_expandedCategories.contains(catTitle)) {
        _expandedCategories.remove(catTitle);
      } else {
        _expandedCategories.add(catTitle);
      }
      Db.settings.put('expanded_nav_categories', _expandedCategories.toList());
    });
  }

  void _toggleSidebar() {
    setState(() {
      _sidebarCollapsed = !_sidebarCollapsed;
      Db.settings.put('sidebar_collapsed', _sidebarCollapsed ? 'true' : 'false');
    });
  }

  Widget _buildPendingBadge(String shopId, {bool iconOnly = false}) {
    return _AppShellPendingBadge(shopId: shopId, iconOnly: iconOnly);
  }

  Widget _buildOrdersBadge(String shopId, {bool iconOnly = false}) {
    return _AppShellOrdersBadge(shopId: shopId, iconOnly: iconOnly);
  }

  Widget _buildRemindersBadge({bool iconOnly = false}) {
    int overdueCount = 0;
    for (final v in Db.parties.values) {
      if (v is Map && _d(v['balance']) > 0) {
        final eval = ReminderService.instance.evaluateCustomerReminder(v);
        if (eval['isDue'] == true) overdueCount++;
      }
    }
    if (overdueCount == 0) return const SizedBox.shrink();
    if (iconOnly) {
      return const TekRedSignalBadge(count: 1, pulse: false, size: 8);
    }
    return TekRedSignalBadge(count: overdueCount, pulse: false, size: 18);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final owner = auth.isOwner;
    if (!owner) {
      return StaffAttendanceScreen(
        shopId: auth.shopId,
        staffId: auth.uid,
        staffName: auth.name,
      );
    }

    final categories = _getNavCategories(auth.shopId);
    final mods = categories.expand((c) => c.items).toList();
    final wide = MediaQuery.of(context).size.width >= 900;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
          TekGlobalSearchDialog.show(context, onNavigate: (idx) => setState(() => _index = idx));
        },
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () {
          TekGlobalSearchDialog.show(context, onNavigate: (idx) => setState(() => _index = idx));
        },
      },
      child: Focus(
        autofocus: true,
        child: wide ? _wideLayout(mods, categories) : _mobileLayout(mods),
      ),
    );
  }

  Widget _mobileLayout(List<AppModule> mods) {
    final tabs = [mods[0], mods[1], mods[2], mods[8]]; // Home, Sale, Stock, Staff Tracking
    final more = mods.where((m) => !tabs.contains(m)).toList();
    final idx = _index >= tabs.length ? tabs.length : _index;

    return Scaffold(
      backgroundColor: TekColors.mainBg,
      body: IndexedStack(
        index: idx,
        children: [
          for (final m in tabs) m.view,
          MoreView(modules: more),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: TekColors.sidebarBg,
        selectedIndex: idx,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final m in tabs)
            NavigationDestination(
              icon: Icon(m.icon),
              label: m.label.split(' ').first,
            ),
          const NavigationDestination(
            icon: Icon(Icons.apps_rounded),
            label: 'More',
          ),
        ],
      ),
    );
  }

  Widget _wideLayout(List<AppModule> mods, List<NavCategory> categories) {
    final safeIndex = _index < mods.length ? _index : 0;
    final activeModule = mods[safeIndex];
    final auth = context.watch<AuthController>();

    // Automatically expand the section containing the active page
    for (final cat in categories) {
      if (cat.items.any((m) => m.label == activeModule.label)) {
        if (!_expandedCategories.contains(cat.title)) {
          _expandedCategories.add(cat.title);
          Db.settings.put('expanded_nav_categories', _expandedCategories.toList());
        }
        break;
      }
    }

    return Scaffold(
      backgroundColor: TekColors.mainBg,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Premium Collapsible Sidebar
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            width: _sidebarCollapsed ? 72 : 260,
            decoration: const BoxDecoration(
              color: TekColors.sidebarBg,
              border: Border(right: BorderSide(color: TekColors.border, width: 1.2)),
            ),
            child: Column(
              children: [
                // Brand Header
                Container(
                  padding: EdgeInsets.symmetric(
                    vertical: 18,
                    horizontal: _sidebarCollapsed ? 12 : 16,
                  ),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: TekColors.border, width: 1.0)),
                  ),
                  child: _sidebarCollapsed
                      ? Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                gradient: TekColors.cyanBlueGradient,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: TekColors.primaryGlow,
                              ),
                              child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 22),
                            ),
                            const SizedBox(height: 10),
                            IconButton(
                              tooltip: 'Expand Sidebar',
                              icon: const Icon(Icons.menu_rounded, color: TekColors.electricCyan, size: 20),
                              onPressed: _toggleSidebar,
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                gradient: TekColors.cyanBlueGradient,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: TekColors.primaryGlow,
                              ),
                              child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 22),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'TEKFIX ERP',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                  Text(
                                    'Smarter Business. Greater Growth.',
                                    style: TextStyle(
                                      color: TekColors.textSecondary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    'Irumbuzhi, Kerala',
                                    style: TextStyle(
                                      color: TekColors.textMuted,
                                      fontSize: 9.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Collapse Sidebar',
                              icon: const Icon(Icons.menu_open_rounded, color: TekColors.textSecondary, size: 19),
                              onPressed: _toggleSidebar,
                            ),
                          ],
                        ),
                ),

                // Navigation Items Accordion
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: categories.length,
                    itemBuilder: (context, catIdx) {
                      final cat = categories[catIdx];
                      final isExpanded = _expandedCategories.contains(cat.title);

                      if (_sidebarCollapsed) {
                        return Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Tooltip(
                                message: cat.title,
                                waitDuration: const Duration(milliseconds: 200),
                                child: Container(
                                  height: 1,
                                  width: 32,
                                  color: TekColors.border,
                                ),
                              ),
                            ),
                            for (final item in cat.items) ...[
                              Builder(builder: (context) {
                                final itemIdx = mods.indexOf(item);
                                final isSelected = safeIndex == itemIdx;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
                                  child: Tooltip(
                                    message: '${cat.title} • ${item.label}',
                                    waitDuration: const Duration(milliseconds: 200),
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        Material(
                                          color: isSelected
                                              ? TekColors.primaryBlue.withValues(alpha: 0.25)
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(10),
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(10),
                                            onTap: () => setState(() => _index = itemIdx),
                                            child: Container(
                                              width: double.infinity,
                                              padding: const EdgeInsets.symmetric(vertical: 10),
                                              child: Center(
                                                child: Icon(
                                                  item.icon,
                                                  size: 20,
                                                  color: isSelected
                                                      ? TekColors.electricCyan
                                                      : TekColors.textSecondary,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        if (item.label == 'Attendance Approvals')
                                          Positioned(
                                            top: 4,
                                            right: 4,
                                            child: _buildPendingBadge(auth.shopId, iconOnly: true),
                                          ),
                                        if (item.label == 'Staff Orders')
                                          Positioned(
                                            top: 4,
                                            right: 4,
                                            child: _buildOrdersBadge(auth.shopId, iconOnly: true),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ],
                        );
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          InkWell(
                            onTap: () => _toggleCategory(cat.title),
                            borderRadius: BorderRadius.circular(6),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(14, 12, 10, 6),
                              child: Row(
                                children: [
                                  Icon(cat.icon, size: 14, color: TekColors.textMuted),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      cat.title.toUpperCase(),
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.8,
                                        color: TekColors.textMuted,
                                      ),
                                    ),
                                  ),
                                  AnimatedRotation(
                                    turns: isExpanded ? 0.25 : 0.0,
                                    duration: const Duration(milliseconds: 200),
                                    child: const Icon(
                                      Icons.chevron_right_rounded,
                                      color: TekColors.textMuted,
                                      size: 16,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          AnimatedCrossFade(
                            crossFadeState: isExpanded
                                ? CrossFadeState.showFirst
                                : CrossFadeState.showSecond,
                            duration: const Duration(milliseconds: 200),
                            firstChild: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Column(
                                children: [
                                  for (final item in cat.items) ...[
                                    Builder(builder: (context) {
                                      final itemIdx = mods.indexOf(item);
                                      final isSelected = safeIndex == itemIdx;
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 1.5),
                                        child: Material(
                                          color: isSelected
                                              ? TekColors.cardBg
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(10),
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(10),
                                            onTap: () => setState(() => _index = itemIdx),
                                            child: Container(
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border(
                                                  left: BorderSide(
                                                    color: isSelected
                                                        ? TekColors.electricCyan
                                                        : Colors.transparent,
                                                    width: 3.5,
                                                  ),
                                                ),
                                              ),
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 8,
                                              ),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    item.icon,
                                                    size: 18,
                                                    color: isSelected
                                                        ? TekColors.electricCyan
                                                        : TekColors.textSecondary,
                                                  ),
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                    child: Text(
                                                      item.label,
                                                      style: TextStyle(
                                                        color: isSelected
                                                            ? Colors.white
                                                            : TekColors.textSecondary,
                                                        fontSize: 13,
                                                        fontWeight: isSelected
                                                            ? FontWeight.bold
                                                            : FontWeight.normal,
                                                      ),
                                                    ),
                                                  ),
                                                  if (item.label == 'Attendance Approvals')
                                                    _buildPendingBadge(auth.shopId),
                                                  if (item.label == 'Staff Orders')
                                                    _buildOrdersBadge(auth.shopId),
                                                  if (item.label == 'Payment Reminders')
                                                    _buildRemindersBadge(),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    }),
                                  ],
                                ],
                              ),
                            ),
                            secondChild: const SizedBox.shrink(),
                          ),
                          const SizedBox(height: 4),
                        ],
                      );
                    },
                  ),
                ),

                // User Profile Footer
                if (!_sidebarCollapsed)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: const BoxDecoration(
                      color: TekColors.cardBg,
                      border: Border(top: BorderSide(color: TekColors.border)),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: TekColors.primaryBlue.withValues(alpha: 0.3),
                          child: Text(
                            auth.name.isNotEmpty ? auth.name[0].toUpperCase() : 'O',
                            style: const TextStyle(
                              color: TekColors.electricCyan,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                auth.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Text(
                                'OWNER • Irumbuzhi',
                                style: TextStyle(
                                  color: TekColors.electricCyan,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Sign out',
                          icon: const Icon(Icons.logout_rounded, color: TekColors.error, size: 18),
                          onPressed: () => auth.signOut(),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // Main Column with Top Navigation + Active View
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Enterprise Top Navigation Bar
                TekTopNavBar(
                  isSidebarCollapsed: _sidebarCollapsed,
                  onToggleSidebar: _toggleSidebar,
                  onNavigateModule: (idx) => setState(() => _index = idx),
                ),

                // Active View Content
                Expanded(
                  child: ClipRect(
                    child: KeyedSubtree(
                      key: ValueKey('page_${mods[safeIndex].label}'),
                      child: mods[safeIndex].view,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MoreView extends StatelessWidget {
  final List<AppModule> modules;
  const MoreView({super.key, required this.modules});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: TekAppBar(
        title: const Text('More modules'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                'TEKFIX ERP & POS',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final m in modules)
            AppCard(
              margin: const EdgeInsets.only(bottom: 10),
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => m.view)),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: kPrimary.withAlpha(25),
                    child: Icon(m.icon,
                        color: Theme.of(context).colorScheme.primary),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                      child: Text(m.label,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15))),
                  Icon(Icons.chevron_right_rounded, color: _muted(context)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 1. HOME DASHBOARD
// -----------------------------------------------------------------------------

/// Navigation helper. GoRouter-ലേക്ക് മാറിയാൽ ഇവിടെ മാത്രം മാറ്റിയാൽ മതി.
void _open(BuildContext context, Widget page) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
}

Widget _buildUrgentBanner({
  required BuildContext context,
  required IconData icon,
  required int badgeCount,
  required Color badgeColor,
  required String title,
  required String subtitle,
  required String actionLabel,
  required VoidCallback onTap,
}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: TekColors.elevatedSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: badgeColor.withValues(alpha: 0.4), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: badgeColor.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                TekRedSignalBadge(
                  count: badgeCount,
                  showPulse: true,
                  badgeColor: badgeColor,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: badgeColor, size: 22),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: TekColors.textPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: TekColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        actionLabel,
                        style: TextStyle(
                          color: badgeColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.arrow_forward_rounded, color: badgeColor, size: 14),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

class _HomePendingApprovalsBanner extends StatefulWidget {
  final String shopId;
  const _HomePendingApprovalsBanner({required this.shopId});

  @override
  State<_HomePendingApprovalsBanner> createState() => _HomePendingApprovalsBannerState();
}

class _HomePendingApprovalsBannerState extends State<_HomePendingApprovalsBanner> {
  late Stream<List<AttendanceRecord>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = AttendanceService.instance.streamPendingApprovals(widget.shopId);
  }

  @override
  void didUpdateWidget(covariant _HomePendingApprovalsBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shopId != widget.shopId) {
      _stream = AttendanceService.instance.streamPendingApprovals(widget.shopId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<AttendanceRecord>>(
      stream: _stream,
      builder: (context, snap) {
        final pendingCount = snap.data?.length ?? 0;
        if (pendingCount == 0) return const SizedBox.shrink();
        return _buildUrgentBanner(
          context: context,
          icon: Icons.fact_check_rounded,
          badgeCount: pendingCount,
          badgeColor: TekColors.error,
          title: 'അറ്റൻഡൻസ് അംഗീകാരം ($pendingCount പെൻഡിംഗ്)',
          subtitle: 'Staff attendance clock-in requests awaiting verification',
          actionLabel: 'Review Approvals',
          onTap: () => _open(
            context,
            OwnerAttendanceApprovalsView(shopId: widget.shopId),
          ),
        );
      },
    );
  }
}

class _HomeOrdersBanner extends StatefulWidget {
  final String shopId;
  const _HomeOrdersBanner({required this.shopId});

  @override
  State<_HomeOrdersBanner> createState() => _HomeOrdersBannerState();
}

class _HomeOrdersBannerState extends State<_HomeOrdersBanner> {
  late Stream<List<StaffOrder>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = OrderService.instance.streamAllOrders(widget.shopId);
  }

  @override
  void didUpdateWidget(covariant _HomeOrdersBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shopId != widget.shopId) {
      _stream = OrderService.instance.streamAllOrders(widget.shopId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<StaffOrder>>(
      stream: _stream,
      builder: (context, snap) {
        final pendingOrders = (snap.data ?? [])
            .where((o) =>
                o.status == StaffOrderStatus.pending ||
                o.status == StaffOrderStatus.submitted)
            .length;
        if (pendingOrders == 0) return const SizedBox.shrink();
        return _buildUrgentBanner(
          context: context,
          icon: Icons.shopping_bag_rounded,
          badgeCount: pendingOrders,
          badgeColor: TekColors.warning,
          title: 'സ്റ്റാഫ് ഓർഡറുകൾ ($pendingOrders പുതിയത്)',
          subtitle: 'Staff supply & customer item orders awaiting review',
          actionLabel: 'Review Orders',
          onTap: () => _open(
            context,
            OwnerOrdersView(shopId: widget.shopId),
          ),
        );
      },
    );
  }
}

class HomeView extends StatelessWidget {
  const HomeView({super.key});

  Widget _buildHeroSection({
    required BuildContext context,
    required String shopName,
    required String userName,
    required double todaySales,
    required double todayProfit,
    required int todayBills,
    required bool isOwner,
  }) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : (hour < 17 ? 'Good afternoon' : 'Good evening');

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: TekColors.heroGradient,
        border: Border.all(
          color: TekColors.electricCyan.withValues(alpha: 0.25),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: TekColors.primaryBlue.withValues(alpha: 0.2),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Brand & Location Header Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: TekColors.electricCyan.withValues(alpha: 0.4),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: TekColors.electricCyan,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'TEKFIX ERP • Irumbuzhi, Kerala',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.calendar_today_rounded,
                        size: 13, color: TekColors.electricCyan),
                    const SizedBox(width: 8),
                    Text(
                      DateFormat('EEEE, dd MMM yyyy').format(DateTime.now()),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Shop Name & Greeting
          Text(
            shopName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Smarter Business. Greater Growth. • $greeting, $userName',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),

          const SizedBox(height: 20),

          // Metrics Row inside Hero Banner
          Wrap(
            spacing: 24,
            runSpacing: 14,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "ഇന്നത്തെ വിൽപന (Today's Sales)",
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    rs(todaySales),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.receipt_long_rounded,
                        color: TekColors.electricCyan, size: 20),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "ഇന്നത്തെ ബില്ലുകൾ",
                          style: TextStyle(color: Colors.white70, fontSize: 10.5),
                        ),
                        Text(
                          '$todayBills Bills',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (isOwner)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: TekColors.success.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: TekColors.success.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.trending_up_rounded,
                          color: TekColors.success, size: 20),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "ഇന്നത്തെ ലാഭം (Today's Profit)",
                            style: TextStyle(color: Colors.white70, fontSize: 10.5),
                          ),
                          Text(
                            rs(todayProfit),
                            style: const TextStyle(
                              color: TekColors.success,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TekColors.mainBg,
      body: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          Db.sales.listenable(),
          Db.items.listenable(),
          Db.parties.listenable(),
          Db.bank.listenable(),
        ]),
        builder: (context, _) {
          double todaySales = 0,
              todayProfit = 0,
              recv = 0,
              pay = 0,
              stockVal = 0;
          int todayBills = 0;
          for (final v in Db.sales.values) {
            final s = _m(v);
            if (_isReturned(s)) continue;
            if (_isToday(_dt(s['createdAt']))) {
              todaySales += _d(s['total']);
              todayProfit += _d(s['profit']);
              todayBills++;
            }
          }
          for (final v in Db.parties.values) {
            final b = _d(_m(v)['balance']);
            if (b > 0) {
              recv += b;
            } else {
              pay += -b;
            }
          }
          int overduePartiesCount = 0;
          for (final v in Db.parties.values) {
            final p = _m(v);
            if (_d(p['balance']) > 0) {
              final eval =
                  ReminderService.instance.evaluateCustomerReminder(p);
              if (eval['isDue'] == true) overduePartiesCount++;
            }
          }
          final lowItems = <Map<String, dynamic>>[];
          for (final v in Db.items.values) {
            final it = _m(v);
            final st = _i(it['stock']);
            stockVal += _d(it['costPrice']) * st;
            if (st <= _i(it['minStock'] ?? 3)) lowItems.add(it);
          }

          final auth = context.watch<AuthController>();
          final isOwner = auth.isOwner;

          // Financial KPI Cards (Section 7)
          final kpiCards = <Widget>[
            TekKpiCard(
              title: 'Cash In Hand',
              subtitle: 'കയ്യിലുള്ള പണം',
              value: rs(Db.cash),
              icon: Icons.payments_rounded,
              accentColor: TekColors.warning,
              onTap: () => _open(context, const CashBankView()),
            ),
            TekKpiCard(
              title: 'Bank Balance',
              subtitle: 'ബാങ്ക് അക്കൗണ്ട്',
              value: rs(Db.bankBalance),
              icon: Icons.account_balance_rounded,
              accentColor: TekColors.primaryBlue,
              onTap: () => _open(context, const CashBankView()),
            ),
            TekKpiCard(
              title: 'Total Receivables',
              subtitle: 'കിട്ടാനുള്ള തുക (Receivable)',
              value: rs(recv),
              icon: Icons.south_west_rounded,
              accentColor: TekColors.success,
              onTap: () => _open(context, const PartiesView()),
            ),
            TekKpiCard(
              title: 'Payment Reminders',
              subtitle: overduePartiesCount > 0
                  ? '$overduePartiesCount Customers Due'
                  : 'എല്ലാം കൃത്യം (Up to date)',
              value: overduePartiesCount > 0 ? '$overduePartiesCount Due' : 'All Clear',
              icon: Icons.notification_important_rounded,
              accentColor: overduePartiesCount > 0 ? TekColors.error : TekColors.warning,
              onTap: () => _open(context, const RemindersScreen()),
            ),
            TekKpiCard(
              title: 'Total Payables',
              subtitle: 'കൊടുക്കാനുള്ള തുക (Payable)',
              value: rs(pay),
              icon: Icons.north_east_rounded,
              accentColor: TekColors.error,
              onTap: () => _open(context, const PartiesView()),
            ),
            TekKpiCard(
              title: 'Stock Value',
              subtitle: 'ഇൻവെന്ററി മൂല്യം',
              value: rs(stockVal),
              icon: Icons.inventory_2_rounded,
              accentColor: TekColors.premiumPurple,
              onTap: () => _open(context, const ItemsView()),
            ),
            TekKpiCard(
              title: 'Low Stock Items',
              subtitle: lowItems.isNotEmpty
                  ? '${lowItems.length} സാധനങ്ങൾ കുറവ്'
                  : 'സ്റ്റോക്ക് സുരക്ഷിതം',
              value: '${lowItems.length} Items',
              icon: Icons.warning_amber_rounded,
              accentColor: lowItems.isNotEmpty ? TekColors.error : TekColors.success,
              onTap: () => _open(context, const ItemsView(initialLowOnly: true)),
            ),
            TekKpiCard(
              title: "Today's Profit",
              subtitle: 'ഇന്നത്തെ അറ്റാദായം',
              value: rs(todayProfit),
              icon: Icons.trending_up_rounded,
              accentColor: TekColors.electricCyan,
              onTap: isOwner
                  ? () => _open(context, const ReportsView(initialPreset: 'Today'))
                  : null,
            ),
          ];

          if (!isOwner) {
            kpiCards.removeWhere((w) =>
                w is TekKpiCard &&
                const [
                  'Cash In Hand',
                  'Bank Balance',
                  "Today's Profit",
                  'Stock Value',
                  'Total Receivables',
                  'Total Payables',
                ].contains(w.title));
          }

          final recent = <Map<String, dynamic>>[];
          for (var i = Db.sales.length - 1;
              i >= 0 && recent.length < 5;
              i--) {
            recent.add(_m(Db.sales.getAt(i)));
          }

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Premium Hero Header Section
              _buildHeroSection(
                context: context,
                shopName: Db.setting('shop_name', 'TEKFIX DIGITAL'),
                userName: auth.name.isNotEmpty ? auth.name : 'Tekfix Owner',
                todaySales: todaySales,
                todayProfit: todayProfit,
                todayBills: todayBills,
                isOwner: isOwner,
              ),

              // Smart Red Signal Urgent Alert 1: Attendance Approvals
              if (isOwner)
                _HomePendingApprovalsBanner(shopId: auth.shopId),

              // Smart Red Signal Urgent Alert 2: Staff Orders
              if (isOwner)
                _HomeOrdersBanner(shopId: auth.shopId),

              // Quick Actions Bar (Section 9)
              TekQuickActions(
                onNewSale: () => _open(context, const SaleView()),
                onAddItem: () => showItemForm(context),
                onServiceRequest: () => showServiceJobForm(context),
                onAddCustomer: () => showPartyForm(context),
                onViewReports: () => _open(context, const ReportsView()),
                onOpenSettings: () => _open(context, const SettingsView()),
              ),

              const SizedBox(height: 10),

              // Financial KPI Cards (Section 7)
              const SectionTitle('സാമ്പത്തിക സംഗ്രഹം (Financial KPIs)'),
              statGrid(kpiCards),

              const SizedBox(height: 10),

              // Sales Analytics Overview (Section 8)
              const SectionTitle('വിൽപന അനലിറ്റിക്സ് (Sales Analytics Overview)'),
              const TekSalesChart(),

              const SizedBox(height: 10),

              // Service & Repair Summary (Section 11)
              const SectionTitle('സർവീസ് സംഗ്രഹം (Service & Repair Center)'),
              ListenableBuilder(
                listenable: Db.services.listenable(),
                builder: (context, _) {
                  final jobs =
                      entriesOf(Db.services).map((e) => e.value).toList();
                  int count(String status) =>
                      jobs.where((j) => '${j['status']}' == status).length;
                  final pendingPay = jobs
                      .where((j) =>
                          j['billCreated'] != true &&
                          '${j['status']}' != 'Cancelled')
                      .fold<double>(
                          0,
                          (acc, j) =>
                              acc +
                              (_d(j['finalAmount']) - _d(j['advance']))
                                  .clamp(0, double.infinity)
                                  .toDouble());
                  final serviceCards = <Widget>[
                    TekKpiCard(
                      title: 'New Today',
                      subtitle: 'ഇന്ന് ലഭിച്ച റിപ്പയർ',
                      value: '${jobs.where((j) => _isToday(_dt(j['createdAt']))).length}',
                      icon: Icons.build_rounded,
                      accentColor: TekColors.primaryBlue,
                      onTap: () => _open(context,
                          const ServicesView(initialFilter: 'Today')),
                    ),
                    TekKpiCard(
                      title: 'In Progress',
                      subtitle: 'വർക്ക് നടക്കുന്നു',
                      value: '${count('In Progress') + count('Diagnosing') + count('Received')}',
                      icon: Icons.handyman_rounded,
                      accentColor: TekColors.warning,
                      onTap: () => _open(context,
                          const ServicesView(initialFilter: 'Active')),
                    ),
                    TekKpiCard(
                      title: 'Ready for Delivery',
                      subtitle: 'ഡെലിവറിക്ക് തയ്യാർ',
                      value: '${count('Ready')}',
                      icon: Icons.check_circle_rounded,
                      accentColor: TekColors.success,
                      onTap: () => _open(context,
                          const ServicesView(initialFilter: 'Ready')),
                    ),
                    TekKpiCard(
                      title: 'Pending Payments',
                      subtitle: 'പിരിഞ്ഞു കിട്ടാനുള്ളത്',
                      value: rs(pendingPay),
                      icon: Icons.payments_rounded,
                      accentColor: TekColors.error,
                      onTap: () => _open(context,
                          const ServicesView(initialFilter: 'Unpaid')),
                    ),
                  ];
                  return statGrid(serviceCards);
                },
              ),

              const SizedBox(height: 10),

              // Recent Invoices (Section 10)
              const SectionTitle('സമീപകാല വിൽപനകൾ (Recent Invoices)'),
              if (recent.isEmpty)
                Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: TekColors.cardBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: TekColors.border),
                  ),
                  child: const EmptyState(
                      Icons.receipt_long_outlined, 'ബില്ലുകൾ ലഭ്യമല്ല.'),
                )
              else
                Container(
                  decoration: BoxDecoration(
                    color: TekColors.cardBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: TekColors.border),
                    boxShadow: TekColors.cardShadow,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < recent.length; i++) ...[
                        if (i > 0) const Divider(height: 1, color: TekColors.border),
                        ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: _isReturned(recent[i])
                                  ? TekColors.error.withValues(alpha: 0.15)
                                  : TekColors.success.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.receipt_rounded,
                              color: _isReturned(recent[i])
                                  ? TekColors.error
                                  : TekColors.success,
                              size: 20,
                            ),
                          ),
                          title: Text(
                            '${recent[i]['invoice']} • ${recent[i]['customerName'] ?? 'Walk-in Customer'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: TekColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13.5,
                            ),
                          ),
                          subtitle: Text(
                            dtFormat.format(_dt(recent[i]['createdAt'])),
                            style: const TextStyle(
                              color: TekColors.textSecondary,
                              fontSize: 11.5,
                            ),
                          ),
                          trailing: _isReturned(recent[i])
                              ? const Pill('Returned', TekColors.error)
                              : Text(
                                  rs(_d(recent[i]['total'])),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14.5,
                                    color: TekColors.success,
                                  ),
                                ),
                        ),
                      ],
                    ],
                  ),
                ),

              const SizedBox(height: 10),

              // Recent Activity (Section 10)
              const SectionTitle('സമീപകാല പ്രവർത്തനങ്ങൾ (Recent System Activity)'),
              ListenableBuilder(
                listenable: Db.audit.listenable(),
                builder: (context, _) {
                  final rows = entriesOf(Db.audit).reversed.take(5).toList();
                  if (rows.isEmpty) {
                    return Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: TekColors.cardBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: TekColors.border),
                      ),
                      child: const Center(
                        child: Text(
                          'ഇതുവരെ പ്രവർത്തന രേഖകളില്ല.',
                          style: TextStyle(color: TekColors.textSecondary),
                        ),
                      ),
                    );
                  }
                  return Container(
                    decoration: BoxDecoration(
                      color: TekColors.cardBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: TekColors.border),
                      boxShadow: TekColors.cardShadow,
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const Divider(height: 1, color: TekColors.border),
                          ListTile(
                            dense: true,
                            leading: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: TekColors.primaryBlue.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.history_rounded,
                                  color: TekColors.electricCyan, size: 18),
                            ),
                            title: Text(
                              '${rows[i].value['action']} • ${rows[i].value['entity']}',
                              style: const TextStyle(
                                color: TekColors.textPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            subtitle: Text(
                              '${rows[i].value['user']} • ${dtFormat.format(_dt(rows[i].value['date']))}',
                              style: const TextStyle(
                                color: TekColors.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),

              // Low Stock Alert (Section 16)
              if (lowItems.isNotEmpty) ...[
                const SizedBox(height: 10),
                SectionTitle(
                  'സ്റ്റോക്ക് മുന്നറിയിപ്പ് (Critical Low Stock Alerts)',
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: TekColors.error.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: TekColors.error.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      '${lowItems.length} Items Low',
                      style: const TextStyle(
                        color: TekColors.error,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: TekColors.cardBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: TekColors.border),
                    boxShadow: TekColors.cardShadow,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < lowItems.length && i < 6; i++) ...[
                        if (i > 0) const Divider(height: 1, color: TekColors.border),
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.warning_amber_rounded,
                              color: TekColors.error, size: 20),
                          title: Text(
                            '${lowItems[i]['name']}',
                            style: const TextStyle(
                              color: TekColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          trailing: Pill(
                            '${_i(lowItems[i]['stock'])} left',
                            TekColors.error,
                          ),
                          onTap: () => _open(
                            context,
                            const ItemsView(initialLowOnly: true),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 2. SALE / POS
// -----------------------------------------------------------------------------
class SaleView extends StatefulWidget {
  const SaleView({super.key});

  @override
  State<SaleView> createState() => _SaleViewState();
}

class _SaleViewState extends State<SaleView> {
  final _search = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _discount = TextEditingController();
  final _cashCtrl = TextEditingController();
  final _upiCtrl = TextEditingController();
  final List<Map<String, dynamic>> _cart = [];
  dynamic _partyKey;
  dynamic _partyId;
  String _q = '';
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_search, _name, _phone, _discount, _cashCtrl, _upiCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  double get _subtotal =>
      _cart.fold<double>(0, (s, i) => s + _d(i['price']) * _i(i['qty']));
  double get _cost =>
      _cart.fold<double>(0, (s, i) => s + _d(i['cost']) * _i(i['qty']));
  double get _discountAmt {
    final d = _d(_discount.text);
    if (d < 0) return 0;
    return d > _subtotal ? _subtotal : d;
  }

  double get _total => _r2(_subtotal - _discountAmt);
  int get _qtyCount => _cart.fold<int>(0, (s, i) => s + _i(i['qty']));

  void _addToCart(dynamic key, Map<String, dynamic> item) {
    final stock = _i(item['stock']);
    final idx = _cart.indexWhere((e) => e['key'] == key);
    if (idx >= 0) {
      if (_i(_cart[idx]['qty']) >= stock) {
        toast(context, 'സ്റ്റോക്ക് തീർന്നു (Only $stock available)',
            error: true);
        return;
      }
      setState(() => _cart[idx]['qty'] = _i(_cart[idx]['qty']) + 1);
    } else {
      if (stock <= 0) {
        toast(context, 'സ്റ്റോക്ക് ഇല്ല', error: true);
        return;
      }
      setState(() => _cart.add({
            'key': key,
            'itemId': item['_id'],
            'name': item['name'],
            'imei': item['imei'] ?? '',
            'price': _d(item['sellingPrice']),
            'cost': _d(item['costPrice']),
            'warranty': '${item['warranty'] ?? 'No Warranty'}',
            'qty': 1,
          }));
    }
  }

  Future<void> _pickCustomer(StateSetter? sheet) async {
    final customers = entriesOf(Db.parties)
        .where((e) => e.value['type'] != 'Supplier')
        .toList();
    final picked =
        await showModalBottomSheet<MapEntry<dynamic, Map<String, dynamic>>?>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('കസ്റ്റമറെ തിരഞ്ഞെടുക്കുക',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            Expanded(
              child: customers.isEmpty
                  ? const EmptyState(Icons.group_off_outlined,
                      'കസ്റ്റമർമാരെ ചേർത്തിട്ടില്ല (Parties ടാബിൽ ചേർക്കുക)')
                  : ListView(
                      children: [
                        for (final e in customers)
                          ListTile(
                            leading:
                                const CircleAvatar(child: Icon(Icons.person)),
                            title: Text('${e.value['name']}'),
                            subtitle: Text('${e.value['phone'] ?? ''}'),
                            trailing: _d(e.value['balance']) > 0
                                ? Pill('Due ${rs(_d(e.value['balance']))}',
                                    Colors.red)
                                : null,
                            onTap: () => Navigator.pop(ctx, e),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      _partyKey = picked.key;
      _partyId = picked.value['_id'];
      _name.text = '${picked.value['name']}';
      _phone.text = '${picked.value['phone'] ?? ''}';
    });
    sheet?.call(() {});
  }

  Future<void> _editPrice(int i, VoidCallback refresh) async {
    final ctrl = TextEditingController(text: _numText(_cart[i]['price']));
    await formDialog(
      context,
      title: '${_cart[i]['name']}',
      body: (set) =>
          tf(ctrl, 'വിൽപന വില (Unit Price)', number: true, prefix: '₹ '),
      onSave: () async {
        final v = double.tryParse(ctrl.text.trim());
        if (v == null || v < 0) return 'ശരിയായ വില നൽകുക';
        _cart[i]['price'] = v;
        return null;
      },
    );
    ctrl.dispose();
    refresh();
  }

  Future<Map<String, dynamic>?> _checkout() async {
    if (_busy) return null;
    if (_cart.isEmpty) {
      toast(context, 'കാർട്ട് ശൂന്യമാണ്', error: true);
      return null;
    }
    final total = _total;
    final cash = _r2(_d(_cashCtrl.text));
    final upi = _r2(_d(_upiCtrl.text));
    if (cash < 0 || upi < 0) {
      toast(context, 'തുക നെഗറ്റീവ് ആകരുത്', error: true);
      return null;
    }
    final due = _r2(total - cash - upi);
    if (due < 0) {
      toast(context, 'ലഭിച്ച തുക ബില്ലിനേക്കാൾ കൂടുതലാണ്', error: true);
      return null;
    }
    if (due > 0 && _partyKey == null) {
      toast(context,
          'ബാക്കി തുകയുണ്ട് — Cash/UPI നൽകുക, അല്ലെങ്കിൽ കസ്റ്റമറെ തിരഞ്ഞെടുക്കുക (Credit)',
          error: true);
      return null;
    }
    for (final line in _cart) {
      final cur = Db.items.get(line['key']);
      if (cur == null || _i(_m(cur)['stock']) < _i(line['qty'])) {
        toast(context, '${line['name']} — സ്റ്റോക്ക് ലഭ്യമല്ല', error: true);
        return null;
      }
    }

    _busy = true;
    try {
      final invoice = await Db.nextInvoice();
      for (final line in _cart) {
        final it = _m(Db.items.get(line['key']));
        it['stock'] = _i(it['stock']) - _i(line['qty']);
        await Db.items.put(line['key'], it);
        await Db.stockMove(
            line['key'], '${it['name']}', -_i(line['qty']), 'Sale $invoice');
      }
      final bill = <String, dynamic>{
        'invoice': invoice,
        'createdAt': DateTime.now().toIso8601String(),
        'customerName':
            _name.text.trim().isEmpty ? 'Walk-in Customer' : _name.text.trim(),
        'customerPhone': _phone.text.trim(),
        'partyKey': _partyKey,
        'partyId': _partyId,
        'items': _cart.map((e) => Map<String, dynamic>.from(e)).toList(),
        'subtotal': _r2(_subtotal),
        'discount': _r2(_discountAmt),
        'total': total,
        'cash': cash,
        'upi': upi,
        'due': due,
        'profit': _r2(total - _cost),
        'gstRate': double.tryParse(Db.setting('gst_rate', '0')) ?? 0.0,
        'status': 'SOLD',
        ...ActivityLog.stamp(),
      };
      await Db.sales.add(bill);
      await Db.logAction(
          action: 'Sale Created',
          entity: 'Invoice',
          entityId: invoice,
          newValue: bill);
      if (cash > 0) await Db.moveMoney('Cash', cash, 'Sale $invoice');
      if (upi > 0) await Db.moveMoney('UPI', upi, 'Sale $invoice');
      if (due > 0) await Db.adjustParty(_partyKey, due);

      if (mounted) {
        setState(() {
          _cart.clear();
          _partyKey = null;
          _partyId = null;
          for (final c in [_name, _phone, _discount, _cashCtrl, _upiCtrl]) {
            c.clear();
          }
        });
      }
      return bill;
    } finally {
      _busy = false;
    }
  }

  Future<void> _finish({BuildContext? sheetCtx}) async {
    final bill = await _checkout();
    if (bill == null) return;
    if (sheetCtx != null && sheetCtx.mounted) Navigator.pop(sheetCtx);
    if (mounted) _showBillOptions(bill);
  }

  void _showBillOptions(Map<String, dynamic> bill) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.check_circle_rounded,
            color: Colors.green.shade600, size: 44),
        title: const Text('ബില്ലിംഗ് പൂർത്തിയായി!'),
        content: Text(
            'ഇൻവോയ്സ്: ${bill['invoice']}\nതുക: ${rs(_d(bill['total']))}'
            '${_d(bill['due']) > 0 ? '\nബാക്കി (Due): ${rs(_d(bill['due']))}' : ''}'),
        actionsAlignment: MainAxisAlignment.center,
        actionsOverflowButtonSpacing: 4,
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.print),
            label: const Text('A4 പ്രിന്റ്'),
            onPressed: () {
              Navigator.pop(ctx);
              printInvoice(context, bill, a4: true);
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.receipt),
            label: const Text('തെർമൽ റോൾ'),
            onPressed: () {
              Navigator.pop(ctx);
              printInvoice(context, bill, a4: false);
            },
          ),
          if ('${bill['customerPhone']}'.trim().isNotEmpty)
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.green),
              icon: const Icon(Icons.send),
              label: const Text('WhatsApp'),
              onPressed: () {
                Navigator.pop(ctx);
                sendInvoiceWhatsApp(context, bill);
              },
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('അടയ്ക്കുക')),
        ],
      ),
    );
  }

  Widget _cartPanel({StateSetter? sheet, BuildContext? sheetCtx}) {
    void upd(VoidCallback f) {
      setState(f);
      sheet?.call(() {});
    }

    final total = _total;
    final cash = _d(_cashCtrl.text);
    final upi = _d(_upiCtrl.text);
    final due = _r2(total - cash - upi);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(
                child: Text('ബിൽ (Cart)',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
            if (_cart.isNotEmpty)
              TextButton(
                  onPressed: () => upd(() => _cart.clear()),
                  child: const Text('Clear')),
          ],
        ),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: () => _pickCustomer(sheet),
          icon: Icon(
              _partyKey == null ? Icons.person_add_alt_1 : Icons.verified_user,
              size: 18),
          label: Text(_partyKey == null
              ? 'കസ്റ്റമറെ തിരഞ്ഞെടുക്കുക (Credit-ന്)'
              : 'Linked: ${_name.text}'),
        ),
        const SizedBox(height: 10),
        tf(_name, 'കസ്റ്റമർ പേര്', onChanged: (_) => upd(() {})),
        tf(_phone, 'മൊബൈൽ നമ്പർ', phone: true, onChanged: (_) => upd(() {})),
        const Divider(),
        if (_cart.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: EmptyState(
                  Icons.shopping_cart_outlined, 'ഇനങ്ങൾ തിരഞ്ഞെടുക്കുക'))
        else
          for (var i = 0; i < _cart.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              onTap: () => _editPrice(i, () => upd(() {})),
              title: Text('${_cart[i]['name']}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                  '${rs(_d(_cart[i]['price']))} × ${_cart[i]['qty']} = ${rs(_d(_cart[i]['price']) * _i(_cart[i]['qty']))}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => upd(() {
                      if (_i(_cart[i]['qty']) > 1) {
                        _cart[i]['qty'] = _i(_cart[i]['qty']) - 1;
                      } else {
                        _cart.removeAt(i);
                      }
                    }),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () {
                      final cur = Db.items.get(_cart[i]['key']);
                      if (cur != null) {
                        upd(() => _addToCart(_cart[i]['key'], _m(cur)));
                      }
                    },
                  ),
                ],
              ),
            ),
        const Divider(),
        tf(_discount, 'കിഴിവ് (Discount ₹)',
            number: true, onChanged: (_) => upd(() {})),
        _row('ഉപതുക (Subtotal)', rs(_subtotal)),
        if (_discountAmt > 0) _row('കിഴിവ്', '- ${rs(_discountAmt)}'),
        _row('ആകെ തുക', rs(total), big: true, color: Colors.green.shade500),
        const SizedBox(height: 12),
        const Text('പേയ്മെന്റ് (Payment)',
            style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ActionChip(
              avatar: const Icon(Icons.payments, size: 16),
              label: const Text('Full Cash'),
              onPressed: () => upd(() {
                _cashCtrl.text = _numText(total);
                _upiCtrl.clear();
              }),
            ),
            ActionChip(
              avatar: const Icon(Icons.qr_code_2, size: 16),
              label: const Text('Full UPI'),
              onPressed: () => upd(() {
                _upiCtrl.text = _numText(total);
                _cashCtrl.clear();
              }),
            ),
            ActionChip(
              avatar: const Icon(Icons.schedule, size: 16),
              label: const Text('Credit'),
              onPressed: () => upd(() {
                _cashCtrl.clear();
                _upiCtrl.clear();
              }),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
                child: tf(_cashCtrl, 'Cash ₹',
                    number: true, onChanged: (_) => upd(() {}))),
            const SizedBox(width: 10),
            Expanded(
                child: tf(_upiCtrl, 'UPI / Card ₹',
                    number: true, onChanged: (_) => upd(() {}))),
          ],
        ),
        _row(due < 0 ? 'കൂടുതൽ (Excess)' : 'ബാക്കി (Due / Credit)',
            rs(due.abs()),
            color: due == 0 ? null : Colors.red.shade400),
        const SizedBox(height: 14),
        SizedBox(
          height: 48,
          child: FilledButton.icon(
            icon: const Icon(Icons.check_rounded),
            onPressed: _cart.isEmpty ? null : () => _finish(sheetCtx: sheetCtx),
            label: const Text('ബിൽ പൂർത്തിയാക്കുക',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }

  Widget _row(String k, String v, {bool big = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k,
                style: TextStyle(
                    fontSize: big ? 16 : 14,
                    fontWeight: big ? FontWeight.w800 : FontWeight.normal)),
            Text(v,
                style: TextStyle(
                    fontSize: big ? 20 : 14,
                    fontWeight: FontWeight.w800,
                    color: color)),
          ],
        ),
      );

  void _openCartSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.88,
            child: _cartPanel(sheet: set, sheetCtx: ctx),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final primary = Theme.of(context).colorScheme.primary;

    final catalog = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            decoration: InputDecoration(
              hintText: 'പേര് / IMEI തിരയുക',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _search.clear();
                        _q = '';
                      }),
                    ),
            ),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: Db.items.listenable(),
            builder: (ctx, box, _) {
              final list = entriesOf(Db.items).where((e) {
                if (_q.isEmpty) return true;
                return '${e.value['name']}'.toLowerCase().contains(_q) ||
                    '${e.value['imei'] ?? ''}'.toLowerCase().contains(_q);
              }).toList();
              if (list.isEmpty) {
                return const EmptyState(
                    Icons.inventory_2_outlined, 'ഉൽപ്പന്നങ്ങൾ ലഭ്യമല്ല.');
              }
              return GridView.builder(
                padding: EdgeInsets.fromLTRB(16, 8, 16, wide ? 16 : 90),
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: wide ? 280 : 700,
                  mainAxisExtent: 96,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: list.length,
                itemBuilder: (ctx, i) {
                  final e = list[i];
                  final stock = _i(e.value['stock']);
                  final inCart = _cart.indexWhere((c) => c['key'] == e.key);
                  final low = stock <= _i(e.value['minStock'] ?? 3);
                  return AppCard(
                    onTap: stock > 0 ? () => _addToCart(e.key, e.value) : null,
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: stock > 0
                              ? kPrimary.withAlpha(40)
                              : Colors.grey.withAlpha(50),
                          child: Icon(Icons.smartphone_rounded,
                              color: stock > 0 ? primary : Colors.grey),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${e.value['name']}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              if ('${e.value['imei'] ?? ''}'.isNotEmpty)
                                Text('IMEI ${e.value['imei']}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 11.5, color: _muted(ctx))),
                              Text(rs(_d(e.value['sellingPrice'])),
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: primary)),
                            ],
                          ),
                        ),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Pill(stock > 0 ? 'Stock $stock' : 'Out',
                                low ? Colors.red : Colors.green),
                            if (inCart >= 0) ...[
                              const SizedBox(height: 4),
                              Pill('In cart ${_cart[inCart]['qty']}', primary),
                            ],
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: const TekAppBar(title: Text('സെയിൽ & ബില്ലിംഗ് (Sale POS)')),
      body: wide
          ? Row(
              children: [
                Expanded(child: catalog),
                Container(
                  width: 390,
                  decoration: BoxDecoration(
                      color: _surface(context),
                      border: Border(left: BorderSide(color: _line(context)))),
                  child: _cartPanel(),
                ),
              ],
            )
          : catalog,
      bottomNavigationBar: wide || _cart.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                decoration: BoxDecoration(
                    color: _surface(context),
                    border: Border(top: BorderSide(color: _line(context)))),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('$_qtyCount ഇനങ്ങൾ',
                              style: TextStyle(
                                  color: _muted(context), fontSize: 12.5)),
                          Text(rs(_total),
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: primary)),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _openCartSheet,
                      icon: const Icon(Icons.shopping_cart_checkout_rounded),
                      label: const Text('കാർട്ട് / ബിൽ'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

// -----------------------------------------------------------------------------
// 3. ITEMS & STOCK
// -----------------------------------------------------------------------------
void showItemForm(BuildContext context,
    [dynamic key, Map<String, dynamic>? item]) {
  final name = TextEditingController(text: '${item?['name'] ?? ''}');
  final category = TextEditingController(text: '${item?['category'] ?? ''}');
  final imei = TextEditingController(text: '${item?['imei'] ?? ''}');
  final cost = TextEditingController(text: _numText(item?['costPrice']));
  final sell = TextEditingController(text: _numText(item?['sellingPrice']));
  final stock =
      TextEditingController(text: item == null ? '' : '${_i(item['stock'])}');
  final minStock = TextEditingController(
      text: '${item == null ? 3 : _i(item['minStock'] ?? 3)}');
  String warranty = '${item?['warranty'] ?? 'No Warranty'}';
  const warrantyOptions = ['No Warranty', '3 Months', '6 Months', '1 Year'];
  bool followUpEnabled = item?['followUpEnabled'] ??
      (warranty != 'No Warranty' ||
          category.text.toLowerCase().contains('charger') ||
          category.text.toLowerCase().contains('cable') ||
          category.text.toLowerCase().contains('earphone') ||
          category.text.toLowerCase().contains('power') ||
          category.text.toLowerCase().contains('phone') ||
          category.text.toLowerCase().contains('mobile'));

  formDialog(
    context,
    title: item == null ? 'പുതിയ സാധനം ചേർക്കുക' : 'ഇനം മാറ്റുക',
    body: (set) => Column(
      children: [
        tf(name, 'ഇനത്തിന്റെ പേര് *'),
        tf(category, 'വിഭാഗം (Mobile / Accessory / Spare...)'),
        tf(imei, 'IMEI / Serial (optional)'),
        DropdownButtonFormField<String>(
          initialValue:
              warrantyOptions.contains(warranty) ? warranty : 'No Warranty',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Warranty Duration'),
          items: [
            for (final w in warrantyOptions)
              DropdownMenuItem(value: w, child: Text(w))
          ],
          onChanged: (v) {
            set(() {
              warranty = v ?? 'No Warranty';
              if (warranty != 'No Warranty') followUpEnabled = true;
            });
          },
        ),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Follow-up enabled (ക്ഷേമാന്വേഷണ SMS)'),
          subtitle: const Text('വാങ്ങി ദിവസങ്ങൾക്കകം കംപ്ലയിന്റ് അന്വേഷണം'),
          value: followUpEnabled,
          onChanged: (v) => set(() => followUpEnabled = v),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: tf(cost, 'വാങ്ങിയ വില', number: true)),
          const SizedBox(width: 10),
          Expanded(child: tf(sell, 'വിൽക്കുന്ന വില', number: true)),
        ]),
        Row(children: [
          Expanded(child: tf(stock, 'എണ്ണം (Stock)', number: true)),
          const SizedBox(width: 10),
          Expanded(child: tf(minStock, 'Low-stock alert', number: true)),
        ]),
      ],
    ),
    onSave: () async {
      if (name.text.trim().isEmpty) return 'ഇനത്തിന്റെ പേര് നൽകുക';
      final c = double.tryParse(cost.text.trim()) ?? 0.0;
      final s = double.tryParse(sell.text.trim()) ?? 0.0;
      final st = int.tryParse(stock.text.trim().split('.').first) ?? 0;
      if (c < 0 || s < 0 || st < 0) return 'തുകയും എണ്ണവും നെഗറ്റീവ് ആകരുത്';
      final im = imei.text.trim();
      if (im.isNotEmpty) {
        final dup = entriesOf(Db.items)
            .any((e) => e.key != key && '${e.value['imei'] ?? ''}' == im);
        if (dup) return 'ഈ IMEI മുമ്പേ ചേർത്തിട്ടുണ്ട്';
      }
      final payload = {
        'name': name.text.trim(),
        'category': category.text.trim(),
        'imei': im,
        'costPrice': c,
        'sellingPrice': s,
        'warranty': warranty,
        'followUpEnabled': followUpEnabled,
        'stock': st,
        'minStock': int.tryParse(minStock.text.trim()) ?? 3,
      };
      if (item == null) {
        final newKey = await Db.items.add(payload);
        await Db.logAction(
            action: 'Product Added',
            entity: 'Product',
            entityId: '$newKey',
            newValue: payload);
        await Db.stockMove(newKey, '${payload['name']}', st, 'Opening stock');
      } else {
        final oldItem = _m(Db.items.get(key));
        await Db.items.put(key, payload);
        await Db.logAction(
            action: 'Product Updated',
            entity: 'Product',
            entityId: '$key',
            oldValue: oldItem,
            newValue: payload);
        final delta = st - _i(oldItem['stock']);
        if (delta != 0) {
          await Db.stockMove(
              key, '${payload['name']}', delta, 'Stock correction');
          await Db.logAction(
              action: 'Stock Updated',
              entity: 'Stock',
              entityId: '$key',
              oldValue: oldItem['stock'],
              newValue: st,
              reason: 'Stock correction');
        }
      }
      return null;
    },
  );
}

class ItemsView extends StatefulWidget {
  final bool initialLowOnly;
  const ItemsView({super.key, this.initialLowOnly = false});

  @override
  State<ItemsView> createState() => _ItemsViewState();
}

class _ItemsViewState extends State<ItemsView> {
  String _q = '';
  late bool _lowOnly = widget.initialLowOnly;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar:
          const TekAppBar(title: Text('ഇനങ്ങൾ & സ്റ്റോക്ക് (Items & Stock)')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showItemForm(context),
        icon: const Icon(Icons.add),
        label: const Text('ഇനം ചേർക്കുക'),
      ),
      body: ValueListenableBuilder(
        valueListenable: Db.items.listenable(),
        builder: (ctx, box, _) {
          final all = entriesOf(Db.items);
          double stockVal = 0;
          int units = 0;
          for (final e in all) {
            stockVal += _d(e.value['costPrice']) * _i(e.value['stock']);
            units += _i(e.value['stock']);
          }
          final list = all.where((e) {
            final it = e.value;
            if (_lowOnly && _i(it['stock']) > _i(it['minStock'] ?? 3)) {
              return false;
            }
            if (_q.isEmpty) return true;
            final hay =
                '${it['name']} ${it['imei'] ?? ''} ${it['category'] ?? ''}'
                    .toLowerCase();
            return hay.contains(_q);
          }).toList();

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                        child: _mini('Models', '${all.length}', Colors.indigo)),
                    const SizedBox(width: 10),
                    Expanded(child: _mini('Units', '$units', Colors.teal)),
                    const SizedBox(width: 10),
                    Expanded(
                        child: _mini(
                            'Stock Value', rs(stockVal), Colors.deepPurple)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        onChanged: (v) =>
                            setState(() => _q = v.trim().toLowerCase()),
                        decoration: const InputDecoration(
                            hintText: 'പേര് / IMEI / വിഭാഗം തിരയുക',
                            prefixIcon: Icon(Icons.search)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('Low stock'),
                      selected: _lowOnly,
                      onSelected: (v) => setState(() => _lowOnly = v),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? const EmptyState(Icons.inventory_2_outlined,
                        'സ്റ്റോക്കിൽ ഇനങ്ങൾ ലഭ്യമല്ല.')
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 90),
                        itemCount: list.length,
                        itemBuilder: (ctx, i) {
                          final e = list[i];
                          final it = e.value;
                          final stock = _i(it['stock']);
                          final low = stock <= _i(it['minStock'] ?? 3);
                          final margin =
                              _d(it['sellingPrice']) - _d(it['costPrice']);
                          return AppCard(
                            margin: const EdgeInsets.only(bottom: 8),
                            onTap: () => showItemForm(context, e.key, it),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  backgroundColor: kPrimary.withAlpha(40),
                                  child: Icon(Icons.smartphone_rounded,
                                      color: primary),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text('${it['name']}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      if ('${it['category'] ?? ''}'
                                              .isNotEmpty ||
                                          '${it['imei'] ?? ''}'.isNotEmpty)
                                        Text(
                                          [
                                            if ('${it['category'] ?? ''}'
                                                .isNotEmpty)
                                              '${it['category']}',
                                            if ('${it['imei'] ?? ''}'
                                                .isNotEmpty)
                                              'IMEI ${it['imei']}',
                                          ].join(' • '),
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: _muted(context)),
                                        ),
                                      Text(
                                        'വാങ്ങിയ ${rs(_d(it['costPrice']))} → വിൽപന ${rs(_d(it['sellingPrice']))}  (ലാഭം ${rs(margin)})',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Pill('Stock $stock',
                                        low ? Colors.red : Colors.green),
                                    InkWell(
                                      onTap: () async {
                                        if (await guardedDelete(context,
                                            '"${it['name']}" ഡിലീറ്റ് ചെയ്യണോ?')) {
                                          await Db.logAction(
                                              action: 'Product Deleted',
                                              entity: 'Product',
                                              entityId: '${e.key}',
                                              oldValue: it);
                                          await Db.items.delete(e.key);
                                        }
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                            top: 6, left: 6),
                                        child: Icon(Icons.delete_outline,
                                            size: 20, color: _muted(context)),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _mini(String t, String v, Color c) => AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t, style: TextStyle(fontSize: 12, color: _muted(context))),
            const SizedBox(height: 2),
            FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(v,
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800, color: c))),
          ],
        ),
      );
}

// -----------------------------------------------------------------------------
// 4. PARTIES
// -----------------------------------------------------------------------------
void showPartyForm(BuildContext context,
    [dynamic key, Map<String, dynamic>? party]) {
  final name = TextEditingController(text: '${party?['name'] ?? ''}');
  final phone = TextEditingController(text: '${party?['phone'] ?? ''}');
  final balance = TextEditingController(
      text: party == null ? '' : _numText(_d(party['balance']).abs()));
  String type = '${party?['type'] ?? 'Customer'}';
  bool remindersDisabled = party?['remindersDisabled'] == true;
  String promisedDate = '${party?['promisedDate'] ?? ''}';
  final customInterval = TextEditingController(
      text: party?['customIntervalDays'] != null
          ? '${party!['customIntervalDays']}'
          : '');

  formDialog(
    context,
    title: party == null ? 'പാർട്ടി ചേർക്കുക' : 'പാർട്ടി മാറ്റുക',
    body: (set) => Column(
      children: [
        DropdownButtonFormField<String>(
          initialValue: type,
          items: const [
            DropdownMenuItem(
                value: 'Customer', child: Text('Customer (കസ്റ്റമർ)')),
            DropdownMenuItem(
                value: 'Supplier', child: Text('Supplier (സപ്ലയർ)')),
          ],
          onChanged: (v) => set(() => type = v!),
          decoration: const InputDecoration(labelText: 'ഇനം'),
        ),
        const SizedBox(height: 10),
        tf(name, 'പേര് / സ്ഥാപനം *'),
        tf(phone, 'ഫോൺ നമ്പർ', phone: true),
        tf(
            balance,
            type == 'Supplier'
                ? 'ഇപ്പോഴത്തെ കൊടുക്കാനുള്ള തുക ₹'
                : 'ഇപ്പോഴത്തെ കിട്ടാനുള്ള തുക ₹',
            number: true),
        if (type == 'Customer') ...[
          const Divider(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto Reminders വേണ്ട (Disable)'),
            value: remindersDisabled,
            onChanged: (v) => set(() => remindersDisabled = v),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('തുക തരാമെന്ന് പറഞ്ഞ തീയതി (Promised Date)'),
            subtitle: Text(
                promisedDate.isNotEmpty ? promisedDate : 'തിരഞ്ഞെടുത്തിട്ടില്ല'),
            trailing: const Icon(Icons.event),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: promisedDate.isNotEmpty
                    ? (DateTime.tryParse(promisedDate) ?? DateTime.now())
                    : DateTime.now().add(const Duration(days: 7)),
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (d != null) {
                set(() => promisedDate = DateFormat('yyyy-MM-dd').format(d));
              }
            },
          ),
          tf(customInterval, 'Custom Interval (ദിവസങ്ങൾ - optional)',
              number: true),
        ],
      ],
    ),
    onSave: () async {
      if (name.text.trim().isEmpty) return 'പേര് നൽകുക';
      final amt = double.tryParse(balance.text.trim()) ?? 0.0;
      final payload = {
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        'type': type,
        'balance': type == 'Supplier' ? -amt.abs() : amt,
        'remindersDisabled': remindersDisabled,
        'promisedDate': promisedDate,
        'customIntervalDays': int.tryParse(customInterval.text.trim()),
        'reminderCount': party?['reminderCount'] ?? 0,
        'lastReminderAt': party?['lastReminderAt'],
      };
      if (party == null) {
        final k = await Db.parties.add(payload);
        await Db.logAction(
            action: 'Party Added',
            entity: 'Party',
            entityId: '$k',
            newValue: payload);
      } else {
        await Db.parties.put(key, payload);
        await Db.logAction(
            action: 'Party Updated',
            entity: 'Party',
            entityId: '$key',
            oldValue: party,
            newValue: payload);
      }
      return null;
    },
  );
}

void showPartyPayment(
    BuildContext context, dynamic key, Map<String, dynamic> party) {
  final isSupplier = party['type'] == 'Supplier';
  final bal = _d(party['balance']);
  final outstanding = bal.abs();
  final amt = TextEditingController(text: _numText(outstanding));
  String mode = 'Cash';

  formDialog(
    context,
    title:
        isSupplier ? 'സപ്ലയർക്ക് പണം നൽകുക' : 'കസ്റ്റമറിൽ നിന്ന് പണം വാങ്ങുക',
    body: (set) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${party['name']} — ബാക്കി: ${rs(outstanding)}',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        tf(amt, 'തുക ₹', number: true),
        ModeSelector(value: mode, onChanged: (v) => set(() => mode = v)),
      ],
    ),
    onSave: () async {
      final a = _r2(double.tryParse(amt.text.trim()) ?? 0);
      if (a <= 0) return 'ശരിയായ തുക നൽകുക';
      if (a > outstanding + 0.009) {
        return 'ബാക്കി തുകയേക്കാൾ കൂടുതൽ നൽകാൻ പറ്റില്ല';
      }
      if (isSupplier) {
        await Db.adjustParty(key, a);
        await Db.moveMoney(mode, -a, 'Paid to ${party['name']}');
      } else {
        await Db.adjustParty(key, -a);
        await Db.moveMoney(mode, a, 'Received from ${party['name']}');
      }
      await Db.logAction(
          action: isSupplier ? 'Supplier Payment' : 'Customer Payment',
          entity: 'Party',
          entityId: '$key',
          newValue: {'amount': a, 'mode': mode});
      return null;
    },
  );
}

class PartiesView extends StatefulWidget {
  const PartiesView({super.key});

  @override
  State<PartiesView> createState() => _PartiesViewState();
}

class _PartiesViewState extends State<PartiesView> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: const TekAppBar(
          title: Text('പാർട്ടികൾ (Parties Ledger)'),
          bottom: TabBar(tabs: [
            Tab(text: 'All'),
            Tab(text: 'Customers'),
            Tab(text: 'Suppliers')
          ]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => showPartyForm(context),
          icon: const Icon(Icons.person_add),
          label: const Text('പാർട്ടി ചേർക്കുക'),
        ),
        body: ValueListenableBuilder(
          valueListenable: Db.parties.listenable(),
          builder: (ctx, box, _) {
            final all = entriesOf(Db.parties).where((e) {
              if (_q.isEmpty) return true;
              return '${e.value['name']} ${e.value['phone']}'
                  .toLowerCase()
                  .contains(_q);
            }).toList();
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    onChanged: (v) =>
                        setState(() => _q = v.trim().toLowerCase()),
                    decoration: const InputDecoration(
                        hintText: 'പേര് / ഫോൺ തിരയുക',
                        prefixIcon: Icon(Icons.search)),
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _list(all),
                      _list(all
                          .where((e) => e.value['type'] != 'Supplier')
                          .toList()),
                      _list(all
                          .where((e) => e.value['type'] == 'Supplier')
                          .toList()),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _list(List<MapEntry<dynamic, Map<String, dynamic>>> list) {
    if (list.isEmpty) {
      return const EmptyState(
          Icons.groups_outlined, 'പാർട്ടികൾ ചേർത്തിട്ടില്ല.');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
      itemCount: list.length,
      itemBuilder: (ctx, i) {
        final e = list[i];
        final p = e.value;
        final isSupplier = p['type'] == 'Supplier';
        final bal = _d(p['balance']);
        return AppCard(
          margin: const EdgeInsets.only(bottom: 8),
          onTap: () => showPartyForm(context, e.key, p),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor:
                    (isSupplier ? Colors.orange : Colors.blue).withAlpha(40),
                child: Icon(isSupplier ? Icons.local_shipping : Icons.person,
                    color: isSupplier
                        ? Colors.orange.shade600
                        : Colors.blue.shade400),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${p['name']}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                        '${isSupplier ? 'Supplier' : 'Customer'} • ${p['phone'] ?? ''}',
                        style: TextStyle(fontSize: 12, color: _muted(context))),
                  ],
                ),
              ),
              if (bal.abs() < 0.005)
                const Pill('Settled', Colors.grey)
              else
                Pill(bal > 0 ? 'To receive ${rs(bal)}' : 'To pay ${rs(-bal)}',
                    bal > 0 ? Colors.green : Colors.red),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'pay') {
                    showPartyPayment(context, e.key, p);
                  } else if (v == 'edit') {
                    showPartyForm(context, e.key, p);
                  } else if (v == 'remind') {
                    sendDueReminder(context, p);
                  } else if (v == 'delete') {
                    final warn = bal.abs() > 0.005
                        ? '\n(ബാക്കി തുക ${rs(bal.abs())} ഉണ്ട്!)'
                        : '';
                    if (await guardedDelete(
                        context, '"${p['name']}" ഡിലീറ്റ് ചെയ്യണോ?$warn')) {
                      await Db.logAction(
                          action: 'Party Deleted',
                          entity: 'Party',
                          entityId: '${e.key}',
                          oldValue: p);
                      await Db.parties.delete(e.key);
                    }
                  }
                },
                itemBuilder: (_) => [
                  if (bal.abs() > 0.005)
                    PopupMenuItem(
                        value: 'pay',
                        child: Text(isSupplier
                            ? 'പണം നൽകുക (Pay)'
                            : 'പണം വാങ്ങുക (Receive)')),
                  if (!isSupplier && bal > 0.005)
                    const PopupMenuItem(
                        value: 'remind', child: Text('WhatsApp reminder')),
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// 5. PURCHASE & EXPENSES
// -----------------------------------------------------------------------------
const List<String> expenseCategories = [
  'Shop Owner Salary',
  'Shop Rent',
  'Staff Salary',
  'Electricity',
  'Other',
];

class PurchaseExpenseView extends StatelessWidget {
  const PurchaseExpenseView({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: TekAppBar(
          title: Text('പർച്ചേസ് & ചെലവുകൾ'),
          bottom: TabBar(tabs: [
            Tab(text: 'Purchases (വാങ്ങൽ)'),
            Tab(text: 'Expenses (ചെലവ്)')
          ]),
        ),
        body: TabBarView(children: [_PurchaseTab(), _ExpenseTab()]),
      ),
    );
  }
}

class _PurchaseTab extends StatelessWidget {
  const _PurchaseTab();

  void _addPurchase(BuildContext context) {
    final items = entriesOf(Db.items);
    final suppliers = entriesOf(Db.parties)
        .where((e) => e.value['type'] == 'Supplier')
        .toList();
    if (items.isEmpty) {
      toast(context, 'ആദ്യം Items ടാബിൽ ഇനം ചേർക്കുക', error: true);
      return;
    }
    dynamic itemKey = items.first.key;
    dynamic supplierKey;
    final qty = TextEditingController(text: '1');
    final cost =
        TextEditingController(text: _numText(items.first.value['costPrice']));
    final sell = TextEditingController();
    String mode = 'Cash';

    formDialog(
      context,
      title: 'സ്റ്റോക്ക് വാങ്ങൽ (Purchase)',
      body: (set) => Column(
        children: [
          DropdownButtonFormField<dynamic>(
            initialValue: supplierKey,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'സപ്ലയർ (optional)'),
            items: [
              const DropdownMenuItem<dynamic>(
                  value: null, child: Text('— None —')),
              for (final s in suppliers)
                DropdownMenuItem<dynamic>(
                    value: s.key, child: Text('${s.value['name']}')),
            ],
            onChanged: (v) => set(() => supplierKey = v),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<dynamic>(
            initialValue: itemKey,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'ഇനം'),
            items: [
              for (final it in items)
                DropdownMenuItem<dynamic>(
                    value: it.key,
                    child: Text('${it.value['name']}',
                        overflow: TextOverflow.ellipsis))
            ],
            onChanged: (v) => set(() {
              itemKey = v;
              cost.text = _numText(Db.items.get(v) == null
                  ? 0
                  : _m(Db.items.get(v))['costPrice']);
            }),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: tf(qty, 'എണ്ണം', number: true)),
            const SizedBox(width: 10),
            Expanded(child: tf(cost, 'യൂണിറ്റ് വില ₹', number: true)),
          ]),
          tf(sell, 'പുതിയ വിൽപന വില (optional)', number: true),
          Align(
            alignment: Alignment.centerLeft,
            child: ModeSelector(
                value: mode,
                options: const ['Cash', 'UPI', 'Credit'],
                onChanged: (v) => set(() => mode = v)),
          ),
        ],
      ),
      onSave: () async {
        final q = int.tryParse(qty.text.trim()) ?? 0;
        final c = double.tryParse(cost.text.trim()) ?? 0;
        if (q <= 0) return 'എണ്ണം നൽകുക';
        if (c <= 0) return 'യൂണിറ്റ് വില നൽകുക';
        if (mode == 'Credit' && supplierKey == null) {
          return 'Credit-ന് സപ്ലയറെ തിരഞ്ഞെടുക്കുക';
        }
        final raw = Db.items.get(itemKey);
        if (raw == null) return 'ഇനം കണ്ടെത്തിയില്ല';
        final it = _m(raw);
        final oldStock = _i(it['stock']);
        final total = _r2(q * c);
        it['stock'] = oldStock + q;
        it['costPrice'] = c;
        final ns = double.tryParse(sell.text.trim());
        if (ns != null && ns > 0) it['sellingPrice'] = ns;
        await Db.items.put(itemKey, it);
        await Db.stockMove(itemKey, '${it['name']}', q, 'Purchase');
        await Db.logAction(
            action: 'Stock Increased',
            entity: 'Stock',
            entityId: '$itemKey',
            oldValue: oldStock,
            newValue: it['stock'],
            reason: 'Purchase $q units');

        final sup = supplierKey == null ? null : Db.parties.get(supplierKey);
        final purchaseKey = await Db.purchases.add({
          'createdAt': DateTime.now().toIso8601String(),
          'supplierKey': supplierKey,
          'supplierName': sup == null ? '-' : _m(sup)['name'],
          'itemKey': itemKey,
          'itemName': it['name'],
          'qty': q,
          'unitCost': c,
          'total': total,
          'mode': mode,
        });
        await Db.logAction(
            action: 'Purchase Created',
            entity: 'Purchase',
            entityId: '$purchaseKey',
            newValue: {
              'item': it['name'],
              'qty': q,
              'total': total,
              'mode': mode
            });
        if (mode == 'Credit') {
          await Db.adjustParty(supplierKey, -total);
        } else {
          await Db.moveMoney(mode, -total, 'Purchase ${it['name']}');
        }
        return null;
      },
    );
  }

  Future<void> _delete(
      BuildContext context, dynamic key, Map<String, dynamic> p) async {
    if (!await guardedDelete(context,
        'ഈ പർച്ചേസ് ഡിലീറ്റ് ചെയ്താൽ സ്റ്റോക്കും പണവും തിരിച്ചാക്കും.')) {
      return;
    }
    final raw = Db.items.get(p['itemKey']);
    if (raw != null) {
      final it = _m(raw);
      if (_i(it['stock']) < _i(p['qty'])) {
        if (context.mounted) {
          toast(context, 'സ്റ്റോക്ക് മതിയാവില്ല — ഇതിനകം വിറ്റിട്ടുണ്ട്',
              error: true);
        }
        return;
      }
      it['stock'] = _i(it['stock']) - _i(p['qty']);
      await Db.items.put(p['itemKey'], it);
      await Db.stockMove(
          p['itemKey'], '${it['name']}', -_i(p['qty']), 'Purchase removed');
    }
    if (p['mode'] == 'Credit') {
      await Db.adjustParty(p['supplierKey'], _d(p['total']));
    } else {
      await Db.moveMoney('${p['mode']}', _d(p['total']), 'Purchase removed');
    }
    await Db.logAction(
        action: 'Purchase Deleted',
        entity: 'Purchase',
        entityId: '$key',
        oldValue: p);
    await Db.purchases.delete(key);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addPurchase(context),
        icon: const Icon(Icons.add_shopping_cart),
        label: const Text('പർച്ചേസ് ചേർക്കുക'),
      ),
      body: ValueListenableBuilder(
        valueListenable: Db.purchases.listenable(),
        builder: (ctx, box, _) {
          final list = entriesOf(Db.purchases).reversed.toList();
          if (list.isEmpty) {
            return const EmptyState(
                Icons.shopping_bag_outlined, 'പർച്ചേസുകൾ ഇല്ല.');
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
            itemCount: list.length,
            itemBuilder: (ctx, i) {
              final p = list[i].value;
              return AppCard(
                margin: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    CircleAvatar(
                        backgroundColor: Colors.indigo.withAlpha(40),
                        child: Icon(Icons.local_shipping,
                            color: Colors.indigo.shade300)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${p['itemName']} × ${p['qty']}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                              '${p['supplierName']} • ${dtFormat.format(_dt(p['createdAt']))}',
                              style: TextStyle(
                                  fontSize: 12, color: _muted(context))),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(rs(_d(p['total'])),
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                        Pill('${p['mode']}',
                            p['mode'] == 'Credit' ? Colors.red : Colors.green),
                      ],
                    ),
                    IconButton(
                        icon:
                            Icon(Icons.delete_outline, color: _muted(context)),
                        onPressed: () => _delete(context, list[i].key, p)),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ExpenseTab extends StatefulWidget {
  const _ExpenseTab();

  @override
  State<_ExpenseTab> createState() => _ExpenseTabState();
}

class _ExpenseTabState extends State<_ExpenseTab> {
  String _catFilter = 'All';
  String _dateFilter = 'All'; // 'All', 'Today', 'This Week', 'This Month'

  void _addExpense(BuildContext context) {
    final title = TextEditingController();
    final amt = TextEditingController();
    String category = expenseCategories.first;
    String mode = 'Cash';
    DateTime selectedDate = DateTime.now();

    formDialog(
      context,
      title: 'ചെലവ് രേഖപ്പെടുത്തുക (Add Expense)',
      body: (set) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            initialValue: category,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'വിഭാഗം (Category) *'),
            items: [
              for (final c in expenseCategories)
                DropdownMenuItem(value: c, child: Text(c))
            ],
            onChanged: (v) => set(() => category = v!),
          ),
          const SizedBox(height: 10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('തീയതി (Date)'),
            subtitle: Text(dayFormat.format(selectedDate)),
            trailing: const Icon(Icons.calendar_today_rounded),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: selectedDate,
                firstDate: DateTime(2020),
                lastDate: DateTime.now(),
              );
              if (d != null) set(() => selectedDate = d);
            },
          ),
          const SizedBox(height: 6),
          tf(title, 'കുറിപ്പ് / വിവരണം (Note)'),
          tf(amt, 'തുക ₹ (Amount) *', number: true),
          const SizedBox(height: 6),
          const Text('പേയ്മെന്റ് രീതി (Payment Mode):',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          ModeSelector(
            value: mode,
            options: const ['Cash', 'Bank', 'UPI'],
            onChanged: (v) => set(() => mode = v),
          ),
        ],
      ),
      onSave: () async {
        final a = _r2(double.tryParse(amt.text.trim()) ?? 0);
        if (a <= 0) return 'ശരിയായ തുക നൽകുക';
        final t = title.text.trim().isEmpty ? category : title.text.trim();
        final expenseKey = await Db.expenses.add({
          'category': category,
          'title': t,
          'amount': a,
          'mode': mode,
          'createdAt': selectedDate.toIso8601String(),
        });
        await Db.logAction(
            action: 'Expense Created',
            entity: 'Expense',
            entityId: '$expenseKey',
            newValue: {
              'category': category,
              'title': t,
              'amount': a,
              'mode': mode,
              'createdAt': selectedDate.toIso8601String(),
            });
        await Db.moveMoney(mode, -a, 'Expense ($category): $t');
        return null;
      },
    );
  }

  bool _matchesDateFilter(DateTime dt) {
    final now = DateTime.now();
    if (_dateFilter == 'Today') {
      return dt.year == now.year && dt.month == now.month && dt.day == now.day;
    } else if (_dateFilter == 'This Week') {
      final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
      return dt.isAfter(startOfWeek.subtract(const Duration(days: 1)));
    } else if (_dateFilter == 'This Month') {
      return dt.year == now.year && dt.month == now.month;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addExpense(context),
        icon: const Icon(Icons.add),
        label: const Text('ചെലവ് ചേർക്കുക'),
      ),
      body: ValueListenableBuilder(
        valueListenable: Db.expenses.listenable(),
        builder: (ctx, box, _) {
          final all = entriesOf(Db.expenses).reversed.toList();
          final filtered = all.where((e) {
            final cat = '${e.value['category'] ?? 'Other'}';
            if (_catFilter != 'All' && cat != _catFilter) return false;
            final dt = _dt(e.value['createdAt']);
            return _matchesDateFilter(dt);
          }).toList();

          double totalFiltered = filtered.fold(0.0, (a, b) => a + _d(b.value['amount']));

          return Column(
            children: [
              // Filters Bar
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Text('Date: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        DropdownButton<String>(
                          value: _dateFilter,
                          isDense: true,
                          items: const [
                            DropdownMenuItem(value: 'All', child: Text('All Time')),
                            DropdownMenuItem(value: 'Today', child: Text('Today')),
                            DropdownMenuItem(value: 'This Week', child: Text('This Week')),
                            DropdownMenuItem(value: 'This Month', child: Text('This Month')),
                          ],
                          onChanged: (v) => setState(() => _dateFilter = v!),
                        ),
                        const Spacer(),
                        Text('ആകെ: ${rs(totalFiltered)}',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ChoiceChip(
                            label: const Text('All Categories'),
                            selected: _catFilter == 'All',
                            onSelected: (_) => setState(() => _catFilter = 'All'),
                          ),
                          for (final c in expenseCategories) ...[
                            const SizedBox(width: 6),
                            ChoiceChip(
                              label: Text(c),
                              selected: _catFilter == c,
                              onSelected: (_) => setState(() => _catFilter = c),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 12),
              Expanded(
                child: filtered.isEmpty
                    ? const EmptyState(
                        Icons.money_off_outlined, 'ചെലവുകൾ കണ്ടെത്തിയില്ല.')
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
                        itemCount: filtered.length,
                        itemBuilder: (ctx, i) {
                          final e = filtered[i].value;
                          final cat = '${e['category'] ?? 'Other'}';
                          final mode = '${e['mode'] ?? 'Cash'}';

                          Color catColor = Colors.blueGrey;
                          if (cat == 'Shop Owner Salary') catColor = Colors.purple;
                          if (cat == 'Shop Rent') catColor = Colors.deepOrange;
                          if (cat == 'Staff Salary') catColor = Colors.teal;
                          if (cat == 'Electricity') catColor = Colors.amber.shade800;

                          return AppCard(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  backgroundColor: Colors.red.withAlpha(35),
                                  child: Icon(Icons.money_off_rounded,
                                      color: Colors.red.shade400),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('${e['title']}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      const SizedBox(height: 3),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 2,
                                        children: [
                                          Chip(
                                            visualDensity: VisualDensity.compact,
                                            label: Text(cat,
                                                style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                    color: catColor)),
                                            backgroundColor: catColor.withAlpha(25),
                                            padding: EdgeInsets.zero,
                                          ),
                                          Chip(
                                            visualDensity: VisualDensity.compact,
                                            label: Text(mode,
                                                style: const TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w600)),
                                            padding: EdgeInsets.zero,
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.only(top: 4),
                                            child: Text(
                                              dayFormat.format(_dt(e['createdAt'])),
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: _muted(context)),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                Text(rs(_d(e['amount'])),
                                    style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        color: Colors.red.shade400,
                                        fontSize: 15)),
                                IconButton(
                                  icon: Icon(Icons.delete_outline,
                                      color: _muted(context)),
                                  onPressed: () async {
                                    if (!await guardedDelete(context,
                                        'ചെലവ് ഡിലീറ്റ് ചെയ്യണോ? (തുക തിരികെ ചേർക്കും)')) {
                                      return;
                                    }
                                    if (e['mode'] != null) {
                                      await Db.moveMoney(
                                          '${e['mode']}',
                                          _d(e['amount']),
                                          'Expense refunded: ${e['title']}');
                                    }
                                    await Db.logAction(
                                        action: 'Expense Deleted',
                                        entity: 'Expense',
                                        entityId: '${filtered[i].key}',
                                        oldValue: e);
                                    await Db.expenses.delete(filtered[i].key);
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 6. STAFF, ATTENDANCE & SALARY
// -----------------------------------------------------------------------------
class StaffView extends StatelessWidget {
  const StaffView({super.key});

  void _staffForm(BuildContext context,
      [dynamic key, Map<String, dynamic>? staff]) {
    final name = TextEditingController(text: '${staff?['name'] ?? ''}');
    final role = TextEditingController(text: '${staff?['role'] ?? ''}');
    final phone = TextEditingController(text: '${staff?['phone'] ?? ''}');
    final salary =
        TextEditingController(text: _numText(staff?['monthlySalary'] ?? 15000));
    final loc = TextEditingController(
        text: '${staff?['lastLocation'] ?? 'Store Desk'}');
    final pin = TextEditingController(text: '${staff?['pin'] ?? ''}');

    formDialog(
      context,
      title: staff == null ? 'പുതിയ ജീവനക്കാരനെ ചേർക്കുക' : 'വിവരങ്ങൾ മാറ്റുക',
      body: (set) => Column(
        children: [
          tf(name, 'ജീവനക്കാരന്റെ പേര് *'),
          tf(role, 'തസ്തിക (Designation)'),
          tf(phone, 'ഫോൺ നമ്പർ *', phone: true),
          tf(salary, 'പ്രതിമാസ ശമ്പളം ₹', number: true),
          tf(pin, '4-Digit Login PIN *', number: true),
          tf(loc, 'ഡ്യൂട്ടി ലൊക്കേഷൻ / റൂട്ട്'),
        ],
      ),
      onSave: () async {
        if (name.text.trim().isEmpty) return 'പേര് നൽകുക';
        final pText = pin.text.trim();
        if (pText.length != 4) return '4 അക്ക ലോഗിൻ PIN നൽകുക (Enter 4-digit PIN)';
        final sal = double.tryParse(salary.text.trim());
        if (sal == null || sal < 0) return 'ശരിയായ ശമ്പളം നൽകുക';
        final payload = {
          'name': name.text.trim(),
          'role': role.text.trim(),
          'phone': phone.text.trim(),
          'monthlySalary': sal,
          'pin': pText,
          'lastLocation': loc.text.trim(),
          'attendance': staff?['attendance'] ?? <String, dynamic>{},
          'payments': staff?['payments'] ?? <dynamic>[],
          'lastUpdated': DateTime.now().toIso8601String(),
        };
        dynamic staffKey = key;
        if (staff == null) {
          final k = await Db.staff.add(payload);
          staffKey = k;
          await Db.logAction(
              action: 'Staff Added',
              entity: 'Staff',
              entityId: '$k',
              newValue: {'name': payload['name']});
        } else {
          await Db.staff.put(key, payload);
          await Db.logAction(
              action: 'Staff Updated',
              entity: 'Staff',
              entityId: '$key',
              newValue: {'name': payload['name'], 'salary': sal});
        }

        // Sync to Firestore under shops/{shopId}/staff/{id} so staff can log in using PIN
        final shopId = Db.setting('shop_id');
        if (shopId.isNotEmpty) {
          try {
            final staffDocId = phone.text.trim().isNotEmpty
                ? phone.text.trim()
                : '$staffKey';
            await FirebaseFirestore.instance
                .collection('shops')
                .doc(shopId)
                .collection('staff')
                .doc(staffDocId)
                .set({
              'name': payload['name'],
              'role': payload['role'],
              'phone': payload['phone'],
              'pin': pText,
              'monthlySalary': sal,
              'active': true,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          } catch (_) {}
        }
        return null;
      },
    );
  }

  void _markAttendance(
      BuildContext context, dynamic key, Map<String, dynamic> staff) {
    DateTime date = DateTime.now();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          Future<void> mark(String status) async {
            final att =
                Map<String, dynamic>.from((staff['attendance'] as Map?) ?? {});
            att[_keyDay.format(date)] = status;
            staff['attendance'] = att;
            await Db.staff.put(key, staff);
            if (ctx.mounted) Navigator.pop(ctx);
          }

          return AlertDialog(
            title: Text('ഹാജർ: ${staff['name']}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text(dayFormat.format(date)),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (d != null) set(() => date = d);
                  },
                ),
                const SizedBox(height: 12),
                SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.green),
                        onPressed: () => mark('Present'),
                        child: const Text('Present (ഹാജർ)'))),
                const SizedBox(height: 8),
                SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.orange),
                        onPressed: () => mark('Half Day'),
                        child: const Text('Half Day'))),
                const SizedBox(height: 8),
                SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                        style:
                            FilledButton.styleFrom(backgroundColor: Colors.red),
                        onPressed: () => mark('Absent'),
                        child: const Text('Absent (ലീവ്)'))),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('അടയ്ക്കുക'))
            ],
          );
        },
      ),
    );
  }

  void _paySalary(
      BuildContext context, dynamic key, Map<String, dynamic> staff) {
    final amt = TextEditingController();
    final note = TextEditingController();
    String mode = 'Cash';

    formDialog(
      context,
      title: 'ശമ്പളം / അഡ്വാൻസ്: ${staff['name']}',
      body: (set) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          tf(amt, 'നൽകുന്ന തുക ₹', number: true),
          tf(note, 'കുറിപ്പ് (Salary / Advance)'),
          ModeSelector(value: mode, onChanged: (v) => set(() => mode = v)),
        ],
      ),
      onSave: () async {
        final a = _r2(double.tryParse(amt.text.trim()) ?? 0);
        if (a <= 0) return 'ശരിയായ തുക നൽകുക';
        final pays = ((staff['payments'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        pays.add({
          'date': DateTime.now().toIso8601String(),
          'month': _keyMonth.format(DateTime.now()),
          'amount': a,
          'mode': mode,
          'note': note.text.trim(),
        });
        staff['payments'] = pays;
        await Db.staff.put(key, staff);
        await Db.expenses.add({
          'category': 'Staff Salary',
          'title': 'Salary to ${staff['name']}',
          'amount': a,
          'mode': mode,
          'createdAt': DateTime.now().toIso8601String(),
        });
        await Db.moveMoney(mode, -a, 'Salary: ${staff['name']}');
        await Db.logAction(
            action: 'Salary Paid',
            entity: 'Staff',
            entityId: '$key',
            newValue: {'amount': a, 'mode': mode});
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TekAppBar(title: Text('സ്റ്റാഫ് & അറ്റൻഡൻസ് (Staff)')),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'live_att_fab',
            backgroundColor: Colors.teal,
            foregroundColor: Colors.white,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    OwnerAttendanceDashboard(shopId: Db.setting('shop_id')),
              ),
            ),
            icon: const Icon(Icons.co_present_rounded),
            label: const Text('Live Attendance'),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            heroTag: 'add_staff_fab',
            onPressed: () => _staffForm(context),
            icon: const Icon(Icons.person_add),
            label: const Text('ജീവനക്കാരൻ'),
          ),
        ],
      ),
      body: ValueListenableBuilder(
        valueListenable: Db.staff.listenable(),
        builder: (ctx, box, _) {
          final list = entriesOf(Db.staff);
          if (list.isEmpty) {
            return const EmptyState(
                Icons.badge_outlined, 'ജീവനക്കാരെ ചേർത്തിട്ടില്ല.');
          }
          final now = DateTime.now();
          final today = _keyDay.format(now);
          final month = _keyMonth.format(now);
          final daysInMonth = DateTime(now.year, now.month + 1, 0).day;

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
            itemCount: list.length,
            itemBuilder: (ctx, i) {
              final k = list[i].key;
              final s = list[i].value;
              final att =
                  Map<String, dynamic>.from((s['attendance'] as Map?) ?? {});
              final todayStatus = '${att[today] ?? 'Not Marked'}';
              int p = 0, h = 0, a = 0;
              att.forEach((d, st) {
                if (d.startsWith(month)) {
                  if (st == 'Present') p++;
                  if (st == 'Half Day') h++;
                  if (st == 'Absent') a++;
                }
              });
              final monthly = _d(s['monthlySalary']);
              final earned = _r2(monthly / daysInMonth * (p + 0.5 * h));
              final paid = ((s['payments'] as List?) ?? [])
                  .where((e) => '${(e as Map)['month']}' == month)
                  .fold<double>(0, (acc, e) => acc + _d((e as Map)['amount']));
              final balance = _r2(earned - paid);
              final stColor = todayStatus == 'Present'
                  ? Colors.green
                  : todayStatus == 'Absent'
                      ? Colors.red
                      : todayStatus == 'Half Day'
                          ? Colors.orange
                          : Colors.grey;

              return AppCard(
                margin: const EdgeInsets.only(bottom: 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                            backgroundColor: Colors.indigo.withAlpha(40),
                            child: Icon(Icons.person,
                                color: Colors.indigo.shade300)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '${s['name']}${'${s['role']}'.isEmpty ? '' : ' (${s['role']})'}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15.5)),
                              Text('Ph: ${s['phone']}  •  ${s['lastLocation']}',
                                  style: TextStyle(
                                      fontSize: 12, color: _muted(context))),
                            ],
                          ),
                        ),
                        Pill(todayStatus, stColor),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Pill('Present $p', Colors.green),
                        Pill('Half $h', Colors.orange),
                        Pill('Absent $a', Colors.red),
                      ],
                    ),
                    const Divider(height: 22),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _kv(context, 'മാസ ശമ്പളം', rs(monthly), null),
                        _kv(context, 'നേടിയത് (Earned)', rs(earned),
                            Colors.indigo.shade300),
                        _kv(context, 'നൽകിയത്', rs(paid),
                            Colors.green.shade500),
                        _kv(
                            context,
                            balance < 0 ? 'അഡ്വാൻസ്' : 'ബാക്കി',
                            rs(balance.abs()),
                            balance < 0
                                ? Colors.orange.shade600
                                : Colors.red.shade400),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      alignment: WrapAlignment.end,
                      children: [
                        TextButton.icon(
                            icon: const Icon(Icons.check_circle_outline,
                                size: 18),
                            label: const Text('ഹാജർ'),
                            onPressed: () => _markAttendance(context, k, s)),
                        TextButton.icon(
                            icon: const Icon(Icons.currency_rupee, size: 18),
                            label: const Text('ശമ്പളം'),
                            onPressed: () => _paySalary(context, k, s)),
                        IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _staffForm(context, k, s)),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.red),
                          onPressed: () async {
                            if (await guardedDelete(
                                context, '"${s['name']}" ഡിലീറ്റ് ചെയ്യണോ?')) {
                              await Db.logAction(
                                  action: 'Staff Deleted',
                                  entity: 'Staff',
                                  entityId: '$k',
                                  oldValue: {'name': s['name']});
                              await Db.staff.delete(k);
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v, Color? c) => Expanded(
        child: Column(
          children: [
            FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(k,
                    style: TextStyle(fontSize: 11, color: _muted(context)))),
            const SizedBox(height: 2),
            FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(v,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: c,
                        fontSize: 13.5))),
          ],
        ),
      );
}

// -----------------------------------------------------------------------------
// 7. CASH & BANK
// -----------------------------------------------------------------------------
class CashBankView extends StatelessWidget {
  const CashBankView({super.key});

  Future<void> _record(BuildContext context, {required bool incoming}) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    String mode = 'Cash';
    await formDialog(
      context,
      title: incoming ? 'പണം ലഭിച്ചു (Money In)' : 'പണം നൽകി (Money Out)',
      body: (set) => Column(
        children: [
          tf(amount, 'തുക ₹', number: true),
          tf(note, 'വിവരണം'),
          ModeSelector(value: mode, onChanged: (v) => set(() => mode = v)),
        ],
      ),
      onSave: () async {
        final value = _r2(double.tryParse(amount.text.trim()) ?? 0);
        if (value <= 0) return 'ശരിയായ തുക നൽകുക';
        await Db.moveMoney(
            mode,
            incoming ? value : -value,
            note.text.trim().isEmpty
                ? (incoming ? 'Money received' : 'Money paid')
                : note.text.trim());
        return null;
      },
    );
    amount.dispose();
    note.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TekAppBar(title: Text('ക്യാഷ് & ബാങ്ക് (Cash & Bank)')),
      body: ValueListenableBuilder(
        valueListenable: Db.bank.listenable(),
        builder: (context, box, _) {
          final log = ((Db.bank.get('txn_log') as List?) ?? [])
              .reversed
              .map((e) => _m(e))
              .toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(children: [
                Expanded(
                    child: StatCard('Cash In Hand', rs(Db.cash), Icons.payments,
                        Colors.amber.shade800)),
                const SizedBox(width: 10),
                Expanded(
                    child: StatCard('Bank Balance', rs(Db.bankBalance),
                        Icons.account_balance, Colors.blue)),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: FilledButton.icon(
                        onPressed: () => _record(context, incoming: true),
                        icon: const Icon(Icons.add),
                        label: const Text('പണം വരവ്'))),
                const SizedBox(width: 10),
                Expanded(
                    child: OutlinedButton.icon(
                        onPressed: () => _record(context, incoming: false),
                        icon: const Icon(Icons.remove),
                        label: const Text('പണം ചെലവ്'))),
              ]),
              const SectionTitle('ഇടപാടുകളുടെ ചരിത്രം (Transactions)'),
              if (log.isEmpty)
                const AppCard(
                    child: EmptyState(
                        Icons.receipt_long_outlined, 'ഇടപാടുകൾ ലഭ്യമല്ല.'))
              else
                for (final t in log)
                  AppCard(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor:
                            (_d(t['amount']) >= 0 ? Colors.green : Colors.red)
                                .withAlpha(40),
                        child: Icon(
                            _d(t['amount']) >= 0
                                ? Icons.south_west
                                : Icons.north_east,
                            color: _d(t['amount']) >= 0
                                ? Colors.green
                                : Colors.red),
                      ),
                      title: Text('${t['note'] ?? 'Transaction'}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                          '${t['account'] ?? ''} • ${dtFormat.format(_dt(t['date']))}'),
                      trailing: Text(
                        '${_d(t['amount']) >= 0 ? '+' : '-'}${rs(_d(t['amount']).abs())}',
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: _d(t['amount']) >= 0
                                ? Colors.green.shade500
                                : Colors.red.shade400),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SERVICES / REPAIR MANAGEMENT
// -----------------------------------------------------------------------------
const List<String> serviceStatuses = [
  'Received',
  'Diagnosing',
  'Waiting for Parts',
  'In Progress',
  'Ready',
  'Delivered',
  'Cancelled',
];

class ServicesView extends StatefulWidget {
  /// 'All', 'Today', 'Active', 'Unpaid', അല്ലെങ്കിൽ serviceStatuses-ലെ ഏതെങ്കിലും മൂല്യം
  final String initialFilter;
  const ServicesView({super.key, this.initialFilter = 'All'});

  @override
  State<ServicesView> createState() => _ServicesViewState();
}

Future<void> showServiceJobForm(BuildContext context,
    [dynamic key, Map<String, dynamic>? old]) =>
    _ServicesViewState.showJobForm(context, key, old);

class _ServicesViewState extends State<ServicesView> {
  late String _filter = widget.initialFilter;
  String _q = '';

  bool _matchesFilter(Map<String, dynamic> j) {
    final status = '${j['status']}';
    switch (_filter) {
      case 'All':
        return true;
      case 'Today': // ഡാഷ്ബോർഡിലെ "New Today"
        return _isToday(_dt(j['createdAt']));
      case 'Active': // ഡാഷ്ബോർഡിലെ "In Progress"
        return const ['Received', 'Diagnosing', 'In Progress'].contains(status);
      case 'Unpaid': // ഡാഷ്ബോർഡിലെ "Pending Payments"
        return j['billCreated'] != true && status != 'Cancelled';
      default:
        return status == _filter;
    }
  }

  Future<void> _jobForm(BuildContext context,
      [dynamic key, Map<String, dynamic>? old]) =>
      showJobForm(context, key, old);

  static Future<void> showJobForm(BuildContext context,
      [dynamic key, Map<String, dynamic>? old]) async {
    final name = TextEditingController(text: '${old?['customerName'] ?? ''}');
    final phone = TextEditingController(text: '${old?['phone'] ?? ''}');
    final product =
        TextEditingController(text: '${old?['productType'] ?? 'Mobile'}');
    final model = TextEditingController(text: '${old?['brandModel'] ?? ''}');
    final serial = TextEditingController(text: '${old?['serial'] ?? ''}');
    final complaint = TextEditingController(text: '${old?['complaint'] ?? ''}');
    final condition = TextEditingController(text: '${old?['condition'] ?? ''}');
    final accessories =
        TextEditingController(text: '${old?['accessories'] ?? ''}');
    final technician =
        TextEditingController(text: '${old?['technician'] ?? ''}');
    final estimate =
        TextEditingController(text: _numText(old?['estimatedCost'] ?? 0));
    final advance = TextEditingController(text: _numText(old?['advance'] ?? 0));
    final delivery =
        TextEditingController(text: '${old?['expectedDelivery'] ?? ''}');
    final warrantyDays =
        TextEditingController(text: '${old?['warrantyDays'] ?? 0}');
    final notes = TextEditingController(text: '${old?['notes'] ?? ''}');
    String status = '${old?['status'] ?? 'Received'}';
    String advanceMode = 'Cash';
    final billed = old?['billCreated'] == true;
    await formDialog(
      context,
      title: old == null ? 'പുതിയ Service Job Card' : 'Service Job തിരുത്തുക',
      body: (set) =>
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Job ID: ${old?['jobId'] ?? '(auto)'}',
            style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.primary)),
        const SizedBox(height: 10),
        tf(name, 'Customer Name *'),
        tf(phone, 'Phone Number', phone: true),
        Row(children: [
          Expanded(child: tf(product, 'Product Type')),
          const SizedBox(width: 8),
          Expanded(child: tf(model, 'Brand & Model'))
        ]),
        tf(serial, 'IMEI / Serial Number'),
        tf(complaint, 'Customer Complaint *', lines: 2),
        tf(condition, 'Device Condition / Existing Damage', lines: 2),
        tf(accessories, 'Accessories Received (cover, charger, SIM tray...)'),
        tf(technician, 'Technician Name'),
        Row(children: [
          Expanded(child: tf(estimate, 'Estimated Cost ₹', number: true)),
          const SizedBox(width: 8),
          Expanded(
              child: tf(advance, billed ? 'Advance (locked)' : 'Advance ₹',
                  number: true))
        ]),
        const Align(
            alignment: Alignment.centerLeft,
            child: Text('Advance payment method')),
        ModeSelector(
            value: advanceMode, onChanged: (v) => set(() => advanceMode = v)),
        const SizedBox(height: 10),
        tf(delivery, 'Expected Delivery (YYYY-MM-DD)'),
        Row(children: [
          Expanded(
              child: tf(warrantyDays, 'Service Warranty Days', number: true)),
          const SizedBox(width: 8),
          Expanded(
              child: DropdownButtonFormField<String>(
            initialValue:
                serviceStatuses.contains(status) ? status : 'Received',
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Status'),
            items: [
              for (final x in serviceStatuses)
                DropdownMenuItem(
                    value: x, child: Text(x, overflow: TextOverflow.ellipsis))
            ],
            onChanged: (v) => set(() => status = v ?? 'Received'),
          ))
        ]),
        const SizedBox(height: 10),
        tf(notes, 'Internal Notes', lines: 2),
      ]),
      onSave: () async {
        if (name.text.trim().isEmpty || complaint.text.trim().isEmpty) {
          return 'Customer Name, Complaint എന്നിവ നൽകുക';
        }
        final est = _r2(double.tryParse(estimate.text) ?? 0);
        var adv = _r2(double.tryParse(advance.text) ?? 0);
        if (est < 0 || adv < 0 || adv > est) {
          return 'Advance തുക Estimate-നേക്കാൾ കൂടുതലാകരുത്';
        }
        final oldAdv = _d(old?['advance']);
        if (billed) adv = oldAdv; // advance already applied on the invoice
        final jobId =
            old?['jobId'] != null ? '${old!['jobId']}' : await Db.nextJobId();
        final prior =
            old == null ? <String, dynamic>{} : Map<String, dynamic>.from(old);
        final payload = <String, dynamic>{
          ...prior,
          'jobId': jobId,
          'customerName': name.text.trim(),
          'phone': phone.text.trim(),
          'productType': product.text.trim(),
          'brandModel': model.text.trim(),
          'serial': serial.text.trim(),
          'complaint': complaint.text.trim(),
          'condition': condition.text.trim(),
          'accessories': accessories.text.trim(),
          'technician': technician.text.trim(),
          'estimatedCost': est,
          'advance': adv,
          'expectedDelivery': delivery.text.trim(),
          'warrantyDays': int.tryParse(warrantyDays.text) ?? 0,
          'status': status,
          'notes': notes.text.trim(),
          'createdAt': old?['createdAt'] ?? DateTime.now().toIso8601String(),
          'updatedAt': DateTime.now().toIso8601String(),
          'finalAmount': billed ? old!['finalAmount'] : est,
          'billCreated': old?['billCreated'] ?? false,
          'parts': old?['parts'] ?? <dynamic>[],
          'statusHistory': old?['statusHistory'] ?? <dynamic>[],
        };
        final history = (payload['statusHistory'] as List).toList();
        if (old == null || '${old['status']}' != status) {
          history.add({
            'date': DateTime.now().toIso8601String(),
            'status': status,
            'user': Db.setting('active_user', 'Admin')
          });
          payload['statusHistory'] = history;
        }
        if (old == null) {
          await Db.services.add(payload);
          if (adv > 0) {
            await Db.moveMoney(advanceMode, adv, 'Service advance $jobId');
          }
          await Db.logAction(
              action: 'Service Created',
              entity: 'Service Job',
              entityId: jobId,
              newValue: payload);
        } else {
          await Db.services.put(key, payload);
          final delta = _r2(adv - oldAdv);
          if (delta != 0) {
            await Db.moveMoney(
                advanceMode, delta, 'Service advance adjusted $jobId');
          }
          await Db.logAction(
              action: 'Service Updated',
              entity: 'Service Job',
              entityId: jobId,
              oldValue: old,
              newValue: payload);
          if ('${old['status']}' != status) {
            await Db.logAction(
                action: 'Service Status Changed',
                entity: 'Service Job',
                entityId: jobId,
                oldValue: old['status'],
                newValue: status);
          }
        }
        return null;
      },
    );
    for (final c in [
      name,
      phone,
      product,
      model,
      serial,
      complaint,
      condition,
      accessories,
      technician,
      estimate,
      advance,
      delivery,
      warrantyDays,
      notes
    ]) {
      c.dispose();
    }
  }

  Future<void> _changeStatus(BuildContext context, dynamic key,
      Map<String, dynamic> job, String status) async {
    final oldStatus = '${job['status'] ?? 'Received'}';
    if (oldStatus == status) return;
    final next = Map<String, dynamic>.from(job);
    next['status'] = status;
    next['updatedAt'] = DateTime.now().toIso8601String();
    final history = ((job['statusHistory'] as List?) ?? []).toList();
    history.add({
      'date': DateTime.now().toIso8601String(),
      'status': status,
      'user': Db.setting('active_user', 'Admin')
    });
    next['statusHistory'] = history;
    await Db.services.put(key, next);
    await Db.logAction(
        action: 'Service Status Changed',
        entity: 'Service Job',
        entityId: '${job['jobId']}',
        oldValue: oldStatus,
        newValue: status);
  }

  Future<void> _billNow(
      BuildContext context, dynamic key, Map<String, dynamic> job) async {
    if (job['billCreated'] == true) {
      toast(context, 'ഈ Job-ന് ബിൽ ഇതിനകം സൃഷ്ടിച്ചിട്ടുണ്ട്', error: true);
      return;
    }
    if ('${job['status']}' != 'Ready') {
      toast(context, 'Bill Now ചെയ്യുന്നതിന് മുമ്പ് status Ready ആക്കുക',
          error: true);
      return;
    }
    final serviceCharge =
        TextEditingController(text: _numText(job['estimatedCost'] ?? 0));
    final partsCharge = TextEditingController(text: '0');
    final labour = TextEditingController(text: '0');
    final discount = TextEditingController(text: '0');
    final partsUsage = TextEditingController();
    String mode = 'Cash';
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Service Bill • ${job['jobId']}'),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            tf(serviceCharge, 'Service Charge ₹', number: true),
            tf(partsCharge, 'Spare Parts Charge ₹', number: true),
            tf(labour, 'Labour Charge ₹', number: true),
            tf(discount, 'Discount ₹', number: true),
            tf(partsUsage,
                'Stock parts used (Product Name:Qty, comma-separated)',
                lines: 2),
            const SizedBox(height: 8),
            ModeSelector(value: mode, onChanged: (v) => set(() => mode = v)),
            const SizedBox(height: 8),
            Text('Advance already received: ${rs(_d(job['advance']))}'),
          ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () {
                  final gross = _d(serviceCharge.text) +
                      _d(partsCharge.text) +
                      _d(labour.text) -
                      _d(discount.text);
                  if (gross < 0 || _d(discount.text) < 0) {
                    toast(ctx, 'തുക ശരിയാക്കുക', error: true);
                    return;
                  }
                  Navigator.pop(ctx, {'total': _r2(gross), 'mode': mode});
                },
                child: const Text('Create Bill')),
          ],
        ),
      ),
    );
    final partsText = partsUsage.text;
    for (final c in [
      serviceCharge,
      partsCharge,
      labour,
      discount,
      partsUsage
    ]) {
      c.dispose();
    }
    if (result == null || !context.mounted) return;
    final total = _d(result['total']);
    final advance = _d(job['advance']);
    final requestedParts = <MapEntry<dynamic, int>>[];
    for (final token in partsText.split(',')) {
      if (token.trim().isEmpty) continue;
      final split = token.split(':');
      if (split.length != 2 || (int.tryParse(split.last.trim()) ?? 0) <= 0) {
        toast(context, 'Spare parts format: Product Name:Qty', error: true);
        return;
      }
      final name = split.first.trim().toLowerCase();
      final match = entriesOf(Db.items)
          .where((e) => '${e.value['name']}'.trim().toLowerCase() == name)
          .toList();
      if (match.isEmpty) {
        toast(context, 'Stock item കണ്ടെത്തിയില്ല: ${split.first.trim()}',
            error: true);
        return;
      }
      requestedParts
          .add(MapEntry(match.first.key, int.parse(split.last.trim())));
    }
    // Aggregate duplicates, then verify stock.
    final need = <dynamic, int>{};
    for (final p in requestedParts) {
      need[p.key] = (need[p.key] ?? 0) + p.value;
    }
    for (final n in need.entries) {
      final item = _m(Db.items.get(n.key));
      if (_i(item['stock']) < n.value) {
        toast(context, '${item['name']} stock മതിയാകില്ല', error: true);
        return;
      }
    }
    if (total < advance) {
      toast(context, 'Final bill advance-നേക്കാൾ കുറവാണ്.', error: true);
      return;
    }
    final due = _r2((total - advance).clamp(0, double.infinity).toDouble());
    final appliedAdvance = _r2(total < advance ? total : advance);
    final invoice = await Db.nextInvoice();
    final usedParts = <Map<String, dynamic>>[];
    double partsCost = 0;
    for (final n in need.entries) {
      final item = _m(Db.items.get(n.key));
      item['stock'] = _i(item['stock']) - n.value;
      await Db.items.put(n.key, item);
      partsCost += _d(item['costPrice']) * n.value;
      usedParts.add({'key': n.key, 'name': item['name'], 'qty': n.value});
      await Db.stockMove(
          n.key, '${item['name']}', -n.value, 'Service ${job['jobId']}');
    }
    final bill = <String, dynamic>{
      'invoice': invoice,
      'createdAt': DateTime.now().toIso8601String(),
      'customerName': job['customerName'],
      'customerPhone': job['phone'],
      'partyKey': null,
      'items': [
        {
          'name': 'Service ${job['jobId']} • ${job['brandModel']}',
          'qty': 1,
          'price': total,
          'costPrice': partsCost,
          'warranty': '${_i(job['warrantyDays'])} days'
        }
      ],
      'subtotal': total,
      'discount': 0,
      'total': total,
      'cash': result['mode'] == 'Cash' ? due : 0,
      'upi': result['mode'] == 'Cash' ? 0 : due,
      'due': 0,
      'profit': _r2(total - partsCost),
      'gstRate': double.tryParse(Db.setting('gst_rate', '0')) ?? 0.0,
      'serviceJobId': job['jobId'],
      'serviceAdvanceApplied': appliedAdvance,
      'serviceBill': true,
      'status': 'SOLD',
      ...ActivityLog.stamp(),
    };
    await Db.sales.add(bill);
    await Db.logAction(
        action: 'Service Billed',
        entity: 'Invoice',
        entityId: invoice,
        newValue: {'job': job['jobId'], 'total': total});
    if (due > 0) {
      await Db.moveMoney('${result['mode']}', due, 'Service bill $invoice');
    }
    final next = Map<String, dynamic>.from(job);
    next['finalAmount'] = total;
    next['paidAmount'] = total;
    next['advanceApplied'] = appliedAdvance;
    next['billCreated'] = true;
    next['invoice'] = invoice;
    next['parts'] = usedParts;
    next['status'] = 'Ready';
    next['warrantyStart'] = DateTime.now().toIso8601String();
    next['warrantyEnd'] = DateTime.now()
        .add(Duration(days: _i(job['warrantyDays'])))
        .toIso8601String();
    await Db.services.put(key, next);
    if (context.mounted) {
      toast(context, 'Service invoice $invoice സൃഷ്ടിച്ചു.');
      await printInvoice(context, bill, a4: true);
    }
  }

  Future<void> _notify(
      BuildContext context, Map<String, dynamic> job, String message) async {
    final text =
        'TekFix Service ${job['jobId']}: $message. Status: ${job['status']}.';
    await _openWhatsApp(context, '${job['phone'] ?? ''}', text);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: const TekAppBar(title: Text('Services / Repairs (സർവീസ്)')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _jobForm(context),
        icon: const Icon(Icons.add),
        label: const Text('New Job Card'),
      ),
      body: ListenableBuilder(
        listenable: Db.services.listenable(),
        builder: (context, _) {
          final all = entriesOf(Db.services).reversed.toList();
          final jobs = all.where((e) {
            final j = e.value;
            if (!_matchesFilter(j)) return false;
            if (_q.isEmpty) return true;
            return '${j['jobId']} ${j['customerName']} ${j['phone']} ${j['brandModel']} ${j['serial']}'
                .toLowerCase()
                .contains(_q);
          }).toList();
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                decoration: const InputDecoration(
                    hintText: 'Job ID / പേര് / ഫോൺ / മോഡൽ തിരയുക',
                    prefixIcon: Icon(Icons.search)),
              ),
            ),
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final f in [
                    'All',
                    'Today',
                    'Active',
                    'Unpaid',
                    ...serviceStatuses
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 6),
                      child: ChoiceChip(
                          label: Text(f),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f)),
                    ),
                ],
              ),
            ),
            Expanded(
              child: jobs.isEmpty
                  ? const EmptyState(
                      Icons.build_circle_outlined, 'Service Job Cards ഇല്ല.')
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
                      itemCount: jobs.length,
                      itemBuilder: (context, index) {
                        final e = jobs[index];
                        final j = e.value;
                        final status = '${j['status'] ?? 'Received'}';
                        final color = status == 'Ready' || status == 'Delivered'
                            ? Colors.green
                            : status == 'Cancelled'
                                ? Colors.red
                                : status == 'Waiting for Parts'
                                    ? Colors.orange
                                    : primary;
                        return AppCard(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Icon(Icons.build_circle, color: primary),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text(
                                          '${j['jobId']} • ${j['customerName']}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w800))),
                                  Pill(status, color),
                                ]),
                                const SizedBox(height: 8),
                                Text(
                                    '${j['productType']} • ${j['brandModel']}'),
                                Text(
                                    'Phone: ${j['phone']} • Serial: ${j['serial']}'),
                                Text('Complaint: ${j['complaint']}'),
                                Text(
                                    'Technician: ${j['technician']} • Estimate: ${rs(_d(j['estimatedCost']))} • Advance: ${rs(_d(j['advance']))}'),
                                if ('${j['expectedDelivery'] ?? ''}'.isNotEmpty)
                                  Text('Expected: ${j['expectedDelivery']}'),
                                if (j['invoice'] != null)
                                  Text(
                                      'Invoice: ${j['invoice']} • Warranty till ${j['warrantyEnd'] == null ? '-' : dayFormat.format(_dt(j['warrantyEnd']))}'),
                                const SizedBox(height: 8),
                                Wrap(spacing: 4, runSpacing: 4, children: [
                                  OutlinedButton.icon(
                                      onPressed: () =>
                                          _jobForm(context, e.key, j),
                                      icon: const Icon(Icons.edit, size: 16),
                                      label: const Text('Edit')),
                                  PopupMenuButton<String>(
                                    tooltip: 'Change status',
                                    onSelected: (v) =>
                                        _changeStatus(context, e.key, j, v),
                                    itemBuilder: (_) => [
                                      for (final x in serviceStatuses)
                                        PopupMenuItem(value: x, child: Text(x))
                                    ],
                                    child: const Chip(
                                        avatar: Icon(Icons.sync, size: 16),
                                        label: Text('Status')),
                                  ),
                                  if (status == 'Ready' &&
                                      j['billCreated'] != true)
                                    FilledButton.icon(
                                        onPressed: () =>
                                            _billNow(context, e.key, j),
                                        icon: const Icon(Icons.receipt_long,
                                            size: 16),
                                        label: const Text('Bill Now')),
                                  OutlinedButton.icon(
                                      onPressed: () =>
                                          _notify(context, j, 'Service update'),
                                      icon: const Icon(Icons.message, size: 16),
                                      label: const Text('WhatsApp')),
                                  if (status == 'Ready' &&
                                      j['billCreated'] == true)
                                    OutlinedButton.icon(
                                        onPressed: () => _changeStatus(
                                            context, e.key, j, 'Delivered'),
                                        icon: const Icon(Icons.check_circle,
                                            size: 16),
                                        label: const Text('Delivered')),
                                ]),
                              ]),
                        );
                      },
                    ),
            ),
          ]);
        },
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// AUDIT / CHANGE HISTORY
// -----------------------------------------------------------------------------
class AuditLogView extends StatefulWidget {
  const AuditLogView({super.key});
  @override
  State<AuditLogView> createState() => _AuditLogViewState();
}

class _AuditLogViewState extends State<AuditLogView> {
  final _search = TextEditingController();
  String _action = 'All';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: TekAppBar(
        title: const Text('Audit / Change History'),
        actions: [
          IconButton(
            tooltip: 'Copy CSV',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () {
              final rows = entriesOf(Db.audit).map((e) => e.value).toList();
              String esc(dynamic v) =>
                  '"${'${v ?? ''}'.replaceAll('"', '""')}"';
              final csv = <String>[
                'Date,User,Action,Entity,ID,Old Value,New Value,Reason'
              ];
              for (final r in rows) {
                csv.add([
                  r['date'],
                  r['user'],
                  r['action'],
                  r['entity'],
                  r['entityId'],
                  r['oldValue'],
                  r['newValue'],
                  r['reason']
                ].map(esc).join(','));
              }
              Clipboard.setData(ClipboardData(text: csv.join('\n')));
              toast(context, 'Audit CSV clipboard-ലേക്ക് കോപ്പി ചെയ്തു');
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Db.audit.listenable(),
        builder: (context, _) {
          final all = entriesOf(Db.audit).reversed.map((e) => e.value).toList();
          final actions =
              <String>{'All', ...all.map((r) => '${r['action']}')}.toList();
          final q = _search.text.toLowerCase();
          final rows = all.where((r) {
            final matches = [
              'user',
              'action',
              'entity',
              'entityId',
              'reason',
              'oldValue',
              'newValue'
            ].any((k) => '${r[k] ?? ''}'.toLowerCase().contains(q));
            return (q.isEmpty || matches) &&
                (_action == 'All' || '${r['action']}' == _action);
          }).toList();
          return Column(children: [
            Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  TextField(
                      controller: _search,
                      decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          labelText: 'Search user, action, product, reason'),
                      onChanged: (_) => setState(() {})),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: actions.contains(_action) ? _action : 'All',
                    decoration:
                        const InputDecoration(labelText: 'Action filter'),
                    items: [
                      for (final a in actions)
                        DropdownMenuItem(value: a, child: Text(a))
                    ],
                    onChanged: (v) => setState(() => _action = v ?? 'All'),
                  ),
                ])),
            Expanded(
                child: rows.isEmpty
                    ? const EmptyState(Icons.history, 'Audit records ഇല്ല.')
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        itemCount: rows.length > 300 ? 300 : rows.length,
                        itemBuilder: (context, i) {
                          final r = rows[i];
                          return AppCard(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ExpansionTile(
                                tilePadding: EdgeInsets.zero,
                                leading: Icon(Icons.history, color: primary),
                                title: Text('${r['action']} • ${r['entity']}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                subtitle: Text(
                                    '${r['user']} • ${dtFormat.format(_dt(r['date']))} • ${r['entityId']}'),
                                children: [
                                  Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text('Reason: ${r['reason']}')),
                                  Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text('Old: ${r['oldValue']}')),
                                  Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text('New: ${r['newValue']}')),
                                ],
                              ));
                        },
                      )),
          ]);
        },
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// BACKUP & SYNC
// -----------------------------------------------------------------------------
class BackupSyncView extends StatefulWidget {
  const BackupSyncView({super.key});
  @override
  State<BackupSyncView> createState() => _BackupSyncViewState();
}

class _BackupSyncViewState extends State<BackupSyncView> {
  bool _busy = false;

  Future<void> _backup() async {
    final json = Db.exportAll();
    await Clipboard.setData(ClipboardData(text: json));
    await Db.logAction(
        action: 'Backup Exported',
        entity: 'Backup',
        reason: '${json.length} chars copied');
    if (mounted) {
      toast(context,
          'ബാക്കപ്പ് clipboard-ലേക്ക് കോപ്പി ചെയ്തു — ഒരു ടെക്സ്റ്റ് ഫയലിൽ സൂക്ഷിക്കുക');
    }
  }

  Future<void> _restore() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (!mounted) return;
      toast(context,
          'Clipboard ശൂന്യമാണ് — ബാക്കപ്പ് കോപ്പി ചെയ്ത ശേഷം ശ്രമിക്കുക',
          error: true);
      return;
    }
    if (!mounted) return;
    if (!await guardedDelete(context,
        'നിലവിലുള്ള എല്ലാ ഡാറ്റയും clipboard-ലെ ബാക്കപ്പ് കൊണ്ട് മാറ്റപ്പെടും. തുടരണോ?',
        yes: 'Restore')) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final n = await Db.importAll(text);
      await Db.logAction(
          action: 'Backup Restored', entity: 'Backup', reason: '$n records');
      if (mounted) toast(context, '$n റെക്കോർഡുകൾ Restore ചെയ്തു');
    } on FormatException catch (e) {
      if (mounted) toast(context, e.message, error: true);
    } catch (e) {
      if (mounted) toast(context, 'Restore പരാജയപ്പെട്ടു: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: const TekAppBar(title: Text('Backup & Sync')),
        body: ListenableBuilder(
          listenable: Db.syncQueue.listenable(),
          builder: (context, _) {
            final eng = context.watch<SyncEngine>();
            final pending = eng.pending;
            return ListView(padding: const EdgeInsets.all(16), children: [
              AppCard(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Icon(Icons.cloud_off,
                        size: 34, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 8),
                    const Text('Offline-first + Cloud sync',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    const Text(
                        'POS, stock, service jobs, audit history എന്നിവ ഈ ഉപകരണത്തിൽ സൂക്ഷിക്കുന്നു. സ്ഥിരമായി ബാക്കപ്പ് എടുക്കുക.'),
                  ])),
              const SectionTitle('ബാക്കപ്പ് (Backup)'),
              AppCard(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text(
                        'എല്ലാ ഡാറ്റയും JSON ആയി clipboard-ലേക്ക് കോപ്പി ചെയ്യും. ഇത് Notes / WhatsApp / ഇമെയിൽ-ൽ പേസ്റ്റ് ചെയ്ത് സൂക്ഷിക്കുക.'),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                          child: FilledButton.icon(
                              onPressed: _busy ? null : _backup,
                              icon: const Icon(Icons.copy_all_rounded),
                              label: const Text('Backup എടുക്കുക'))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: OutlinedButton.icon(
                              onPressed: _busy ? null : _restore,
                              icon: const Icon(Icons.restore_rounded),
                              label: const Text('Restore'))),
                    ]),
                  ])),
              const SectionTitle('Cloud Sync Queue'),
              AppCard(
                  child: Row(children: [
                Icon(pending == 0 ? Icons.check_circle : Icons.sync,
                    color: pending == 0 ? Colors.green : Colors.orange),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(pending == 0
                        ? 'എല്ലാം ക്ലൗഡിൽ സിങ്ക് ആണ് (All synced)'
                        : '$pending ഇനങ്ങൾ upload-ന് കാത്തിരിക്കുന്നു (offline-ൽ സുരക്ഷിതം)')),
                TextButton(
                    onPressed: eng.syncNow, child: const Text('Sync now')),
              ])),
            ]);
          },
        ),
      );
}

// -----------------------------------------------------------------------------
// REPORTS
// -----------------------------------------------------------------------------
class ReportsView extends StatefulWidget {
  final String initialPreset; // 'Today' | '7 Days' | 'Month' | 'All'
  final int initialTab; // 0 സംഗ്രഹം, 1 സെയിൽസ്, 2 ചെലവ്, 3 സ്റ്റോക്ക്
  const ReportsView(
      {super.key, this.initialPreset = 'Month', this.initialTab = 0});

  @override
  State<ReportsView> createState() => _ReportsViewState();
}

class _ReportsViewState extends State<ReportsView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  String _preset = 'Month';
  DateTimeRange? _custom;
  String _saleQ = '';

  @override
  void initState() {
    super.initState();
    _preset = widget.initialPreset;
    _tabs =
        TabController(length: 4, vsync: this, initialIndex: widget.initialTab);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  DateTimeRange? get _range {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_preset) {
      case 'Today':
        return DateTimeRange(
            start: today, end: today.add(const Duration(days: 1)));
      case '7 Days':
        return DateTimeRange(
            start: today.subtract(const Duration(days: 6)),
            end: today.add(const Duration(days: 1)));
      case 'Month':
        return DateTimeRange(
            start: DateTime(now.year, now.month, 1),
            end: DateTime(now.year, now.month + 1, 1));
      case 'Custom':
        if (_custom == null) return null;
        final e = _custom!.end;
        return DateTimeRange(
            start: _custom!.start,
            end: DateTime(e.year, e.month, e.day).add(const Duration(days: 1)));
      default:
        return null;
    }
  }

  bool _in(dynamic created) {
    final r = _range;
    if (r == null) return true;
    final d = _dt(created);
    return !d.isBefore(r.start) && d.isBefore(r.end);
  }

  Future<void> _pickPreset(String p) async {
    if (p == 'Custom') {
      final r = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime.now().add(const Duration(days: 1)),
        initialDateRange: _custom,
      );
      if (r == null) return;
      setState(() {
        _custom = r;
        _preset = 'Custom';
      });
    } else {
      setState(() => _preset = p);
    }
  }

  String get _rangeLabel {
    final r = _range;
    if (r == null) return 'All time';
    final end = r.end.subtract(const Duration(days: 1));
    return '${dayFormat.format(r.start)} – ${dayFormat.format(end)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: TekAppBar(
        title: const Text('റിപ്പോർട്ടുകൾ (Reports)'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.dashboard_outlined), text: 'സംഗ്രഹം'),
            Tab(
                icon: Icon(Icons.receipt_long_outlined),
                text: 'സെയിൽസ് & റിട്ടേൺ'),
            Tab(icon: Icon(Icons.money_off_outlined), text: 'ചെലവുകൾ'),
            Tab(icon: Icon(Icons.inventory_2_outlined), text: 'സ്റ്റോക്ക്'),
          ],
        ),
      ),
      body: Column(
        children: [
          SizedBox(
            height: 50,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final p in ['Today', '7 Days', 'Month', 'All', 'Custom'])
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: ChoiceChip(
                        label: Text(p),
                        selected: _preset == p,
                        onSelected: (_) => _pickPreset(p)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(_rangeLabel,
                style: TextStyle(color: _muted(context), fontSize: 12.5)),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[
                Db.sales.listenable(),
                Db.purchases.listenable(),
                Db.expenses.listenable(),
                Db.items.listenable(),
                Db.stockMoves.listenable(),
              ]),
              builder: (context, _) => TabBarView(
                controller: _tabs,
                children: [
                  _summary(),
                  _salesTab(),
                  _expensesTab(),
                  _stockTab()
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Summary ----
  Widget _summary() {
    final sales =
        entriesOf(Db.sales).where((e) => _in(e.value['createdAt'])).toList();
    final sold =
        sales.where((e) => !_isReturned(e.value)).map((e) => e.value).toList();
    final returned =
        sales.where((e) => _isReturned(e.value)).map((e) => e.value).toList();

    double revenue = 0, profit = 0, cash = 0, upi = 0, credit = 0, discount = 0;
    final topQty = <String, int>{};
    final topAmt = <String, double>{};
    for (final s in sold) {
      revenue += _d(s['total']);
      profit += _d(s['profit']);
      cash += _billCash(s);
      upi += _d(s['upi']);
      credit += _d(s['due']);
      discount += _d(s['discount']);
      for (final l in (s['items'] as List?) ?? const []) {
        final line = _m(l);
        final n = '${line['name']}';
        topQty[n] = (topQty[n] ?? 0) + _i(line['qty']);
        topAmt[n] = (topAmt[n] ?? 0) + _d(line['price']) * _i(line['qty']);
      }
    }
    final returnAmt = returned.fold<double>(0, (a, s) => a + _d(s['total']));
    final purchases = entriesOf(Db.purchases)
        .where((e) => _in(e.value['createdAt']))
        .fold<double>(0, (a, e) => a + _d(e.value['total']));
    final expenses = entriesOf(Db.expenses)
        .where((e) => _in(e.value['createdAt']))
        .fold<double>(0, (a, e) => a + _d(e.value['amount']));
    final net = profit - expenses;
    final top = topAmt.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        statGrid([
          StatCard(
              'Sales (വിൽപന)', rs(revenue), Icons.point_of_sale, Colors.green),
          StatCard('Gross Profit', rs(profit), Icons.trending_up, Colors.teal),
          StatCard('Expenses', rs(expenses), Icons.money_off, Colors.redAccent),
          StatCard('Net Profit', rs(net), Icons.account_balance_wallet,
              net >= 0 ? Colors.indigo : Colors.red),
          StatCard('Purchases', rs(purchases), Icons.local_shipping,
              Colors.deepPurple),
          StatCard('Bills', '${sold.length}', Icons.receipt_long, Colors.blue),
          StatCard('Returns (${returned.length})', rs(returnAmt),
              Icons.assignment_return, Colors.orange),
          StatCard('Discounts', rs(discount), Icons.percent, Colors.brown),
        ]),
        const SectionTitle('പേയ്മെന്റ് വിവരം (Payment Split)'),
        AppCard(
          child: Column(children: [
            _line2('Cash', rs(cash)),
            _line2('UPI / Card', rs(upi)),
            _line2('Credit (ബാക്കി)', rs(credit)),
          ]),
        ),
        const SectionTitle('Top Selling (ഏറ്റവും കൂടുതൽ വിറ്റത്)'),
        if (top.isEmpty)
          const AppCard(child: Text('ഈ കാലയളവിൽ വിൽപന ഇല്ല.'))
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (var i = 0; i < top.length && i < 8; i++) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                      radius: 14,
                      child: Text('${i + 1}',
                          style: const TextStyle(fontSize: 12))),
                  title: Text(top[i].key,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${topQty[top[i].key]} units'),
                  trailing: Text(rs(top[i].value),
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
              ],
            ]),
          ),
      ],
    );
  }

  Widget _line2(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      );

  // ---- Sales & returns ----
  Future<void> _return(dynamic key, Map<String, dynamic> s) async {
    if (s['serviceBill'] == true) {
      toast(context,
          'Service ബിൽ റിട്ടേൺ ചെയ്യാൻ പറ്റില്ല — Service job നേരിട്ട് കൈകാര്യം ചെയ്യുക',
          error: true);
      return;
    }
    if (!await guardedDelete(context,
        '${s['invoice']} റിട്ടേൺ ചെയ്യണോ? സ്റ്റോക്കും പണവും തിരിച്ചാക്കും.',
        yes: 'റിട്ടേൺ')) {
      return;
    }
    await Db.returnSale(key);
    if (mounted) toast(context, '${s['invoice']} റിട്ടേൺ ചെയ്തു');
  }

  Future<void> _deleteSale(dynamic key, Map<String, dynamic> s) async {
    if (s['serviceBill'] == true) {
      toast(context, 'Service ബിൽ ഡിലീറ്റ് ചെയ്യാൻ പറ്റില്ല', error: true);
      return;
    }
    if (!await guardedDelete(context,
        '${s['invoice']} പൂർണ്ണമായി ഡിലീറ്റ് ചെയ്യണോ? (സ്റ്റോക്കും പണവും തിരിച്ചാക്കും)')) {
      return;
    }
    await Db.cancelSale(key);
    if (mounted) toast(context, '${s['invoice']} ഡിലീറ്റ് ചെയ്തു');
  }

  Widget _salesTab() {
    final all = entriesOf(Db.sales)
        .reversed
        .where((e) => _in(e.value['createdAt']))
        .where((e) {
      if (_saleQ.isEmpty) return true;
      return '${e.value['invoice']} ${e.value['customerName']} ${e.value['customerPhone']}'
          .toLowerCase()
          .contains(_saleQ);
    }).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: TextField(
            onChanged: (v) => setState(() => _saleQ = v.trim().toLowerCase()),
            decoration: const InputDecoration(
                hintText: 'Invoice / കസ്റ്റമർ / ഫോൺ തിരയുക',
                prefixIcon: Icon(Icons.search)),
          ),
        ),
        Expanded(
          child: all.isEmpty
              ? const EmptyState(
                  Icons.receipt_long_outlined, 'ഈ കാലയളവിൽ ബില്ലുകൾ ഇല്ല.')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                  itemCount: all.length,
                  itemBuilder: (context, i) {
                    final e = all[i];
                    final s = e.value;
                    final ret = _isReturned(s);
                    return AppCard(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        CircleAvatar(
                          backgroundColor:
                              (ret ? Colors.red : Colors.green).withAlpha(40),
                          child: Icon(
                              ret
                                  ? Icons.assignment_return
                                  : Icons.receipt_rounded,
                              color: ret ? Colors.red : Colors.green.shade500),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${s['invoice']} • ${s['customerName']}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                Text(dtFormat.format(_dt(s['createdAt'])),
                                    style: TextStyle(
                                        fontSize: 12, color: _muted(context))),
                                if (_d(s['due']) > 0)
                                  Text('Due ${rs(_d(s['due']))}',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.red.shade400)),
                              ]),
                        ),
                        Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(rs(_d(s['total'])),
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      decoration: ret
                                          ? TextDecoration.lineThrough
                                          : null)),
                              if (ret) const Pill('Returned', Colors.red),
                            ]),
                        PopupMenuButton<String>(
                          onSelected: (v) {
                            switch (v) {
                              case 'a4':
                                printInvoice(context, s, a4: true);
                              case 'roll':
                                printInvoice(context, s, a4: false);
                              case 'wa':
                                sendInvoiceWhatsApp(context, s);
                              case 'return':
                                _return(e.key, s);
                              case 'delete':
                                _deleteSale(e.key, s);
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                                value: 'a4', child: Text('Print A4')),
                            const PopupMenuItem(
                                value: 'roll', child: Text('Print Thermal')),
                            if ('${s['customerPhone'] ?? ''}'.trim().isNotEmpty)
                              const PopupMenuItem(
                                  value: 'wa', child: Text('WhatsApp')),
                            if (!ret)
                              const PopupMenuItem(
                                  value: 'return',
                                  child: Text('Return (റിട്ടേൺ)')),
                            const PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete (ഡിലീറ്റ്)')),
                          ],
                        ),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---- Expenses ----
  Widget _expensesTab() {
    final rows = entriesOf(Db.expenses)
        .reversed
        .where((e) => _in(e.value['createdAt']))
        .toList();
    if (rows.isEmpty) {
      return const EmptyState(
          Icons.money_off_outlined, 'ഈ കാലയളവിൽ ചെലവുകൾ ഇല്ല.');
    }
    final byCat = <String, double>{
      'Shop Owner Salary': 0.0,
      'Shop Rent': 0.0,
      'Staff Salary': 0.0,
      'Electricity': 0.0,
      'Other': 0.0,
    };
    double total = 0;
    for (final r in rows) {
      final a = _d(r.value['amount']);
      total += a;
      final raw = '${r.value['category'] ?? ''}';
      final c = expenseCategories.contains(raw) ? raw : 'Other';
      byCat[c] = (byCat[c] ?? 0) + a;
    }
    final cats = byCat.entries.toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        StatCard('ആകെ ചെലവ്', rs(total), Icons.money_off, Colors.redAccent),
        const SectionTitle('വിഭാഗം തിരിച്ച് (By Category)'),
        AppCard(
          child: Column(children: [
            for (final c in cats)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(c.key),
                            Text(
                                '${rs(c.value)}  (${(c.value / total * 100).toStringAsFixed(0)}%)',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                          ]),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                            value: c.value / total,
                            minHeight: 7,
                            backgroundColor: _line(context),
                            color: Colors.redAccent),
                      ),
                    ]),
              ),
          ]),
        ),
        const SectionTitle('എല്ലാ ചെലവുകളും'),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              ListTile(
                dense: true,
                title: Text('${rows[i].value['title']}'),
                subtitle: Text(
                    '${rows[i].value['category']} • ${dtFormat.format(_dt(rows[i].value['createdAt']))}'),
                trailing: Text(rs(_d(rows[i].value['amount'])),
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Colors.red.shade400)),
              ),
            ],
          ]),
        ),
      ],
    );
  }

  // ---- Stock ----
  Widget _stockTab() {
    final items = entriesOf(Db.items).map((e) => e.value).toList()
      ..sort((a, b) => _i(a['stock']).compareTo(_i(b['stock'])));
    double costVal = 0, sellVal = 0;
    int units = 0, low = 0, out = 0;
    for (final it in items) {
      final st = _i(it['stock']);
      units += st;
      costVal += _d(it['costPrice']) * st;
      sellVal += _d(it['sellingPrice']) * st;
      if (st <= 0) {
        out++;
      } else if (st <= _i(it['minStock'] ?? 3)) {
        low++;
      }
    }
    final moves = entriesOf(Db.stockMoves)
        .reversed
        .where((e) => _in(e.value['date']))
        .take(40)
        .toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        statGrid([
          StatCard('Units', '$units', Icons.inventory_2, Colors.teal),
          StatCard('Cost Value', rs(costVal), Icons.inventory, Colors.indigo),
          StatCard('Retail Value', rs(sellVal), Icons.sell, Colors.green),
          StatCard('Low / Out', '$low / $out', Icons.warning_amber,
              Colors.deepOrange),
        ]),
        const SectionTitle('സ്റ്റോക്ക് നില (Lowest first)'),
        if (items.isEmpty)
          const AppCard(child: Text('ഇനങ്ങൾ ഇല്ല.'))
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  dense: true,
                  title: Text('${items[i]['name']}'),
                  subtitle: Text(
                      'Value ${rs(_d(items[i]['costPrice']) * _i(items[i]['stock']))}'),
                  trailing: Pill(
                      _i(items[i]['stock']) <= 0
                          ? 'Out'
                          : '${_i(items[i]['stock'])}',
                      _i(items[i]['stock']) <= _i(items[i]['minStock'] ?? 3)
                          ? Colors.red
                          : Colors.green),
                ),
              ],
            ]),
          ),
        const SectionTitle('സ്റ്റോക്ക് ചലനങ്ങൾ (Recent Movements)'),
        if (moves.isEmpty)
          const AppCard(child: Text('ചലനങ്ങൾ ഇല്ല.'))
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (var i = 0; i < moves.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  dense: true,
                  title: Text('${moves[i].value['itemName']}'),
                  subtitle: Text(
                      '${moves[i].value['reason']} • ${dtFormat.format(_dt(moves[i].value['date']))}'),
                  trailing: Text(
                      '${_i(moves[i].value['delta']) > 0 ? '+' : ''}${_i(moves[i].value['delta'])}',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: _i(moves[i].value['delta']) >= 0
                              ? Colors.green.shade500
                              : Colors.red.shade400)),
                ),
              ],
            ]),
          ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// SETTINGS
// -----------------------------------------------------------------------------
class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late final Map<String, TextEditingController> _c;
  final _oldPw = TextEditingController();
  final _newPw = TextEditingController();
  bool _blockOutsideCheckIn = false;
  bool _locLoading = false;

  static const _fields = [
    'shop_name',
    'shop_address',
    'shop_phone',
    'shop_email',
    'gstin',
    'gst_rate',
    'invoice_prefix',
    'invoice_footer',
    'active_user',
    'shop_latitude',
    'shop_longitude',
    'shop_allowed_radius',
  ];

  @override
  void initState() {
    super.initState();
    _c = {
      for (final k in _fields)
        k: TextEditingController(
          text: Db.setting(
            k,
            k == 'shop_allowed_radius'
                ? '100'
                : (k == 'shop_latitude' || k == 'shop_longitude' ? '0.0' : ''),
          ),
        )
    };
    _blockOutsideCheckIn =
        Db.setting('block_outside_checkin', 'false') == 'true';
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _oldPw.dispose();
    _newPw.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _locLoading = true);
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          toast(context, 'ഫോണിലെ GPS ഓഫ് ആണ്. ഓൺ ചെയ്യുക.', error: true);
        }
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            toast(context, 'ലൊക്കേഷൻ പെർമിഷൻ ലഭിച്ചില്ല.', error: true);
          }
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          toast(context, 'ലൊക്കേഷൻ പെർമിഷൻ ഫോൺ സെറ്റിംഗ്സിൽ നൽകുക.',
              error: true);
        }
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _c['shop_latitude']!.text = pos.latitude.toStringAsFixed(6);
      _c['shop_longitude']!.text = pos.longitude.toStringAsFixed(6);
      if (mounted) {
        toast(
            context,
            'ലൊക്കേഷൻ എടുത്തു (${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)})');
      }
    } catch (e) {
      if (mounted) toast(context, 'Error: $e', error: true);
    } finally {
      if (mounted) setState(() => _locLoading = false);
    }
  }

  Future<void> _save() async {
    final gst = double.tryParse(_c['gst_rate']!.text.trim());
    if (gst == null || gst < 0 || gst > 100) {
      toast(context, 'GST % 0 മുതൽ 100 വരെ ആയിരിക്കണം', error: true);
      return;
    }
    if (_c['shop_name']!.text.trim().isEmpty) {
      toast(context, 'സ്ഥാപനത്തിന്റെ പേര് നൽകുക', error: true);
      return;
    }
    for (final k in _fields) {
      var v = _c[k]!.text.trim();
      if (k == 'invoice_prefix' && v.isEmpty) v = 'INV';
      if (k == 'active_user' && v.isEmpty) v = 'Admin';
      await Db.settings.put(k, v);
    }
    await Db.settings
        .put('block_outside_checkin', _blockOutsideCheckIn.toString());
    await Db.logAction(action: 'Settings Updated', entity: 'Settings');
    if (mounted) toast(context, 'സെറ്റിംഗ്സ് സേവ് ചെയ്തു!');
  }

  Future<void> _changePassword() async {
    if (_oldPw.text != Db.setting('admin_pass', 'admin123')) {
      toast(context, 'നിലവിലെ പാസ്‌വേഡ് തെറ്റാണ്', error: true);
      return;
    }
    if (_newPw.text.length < 4) {
      toast(context, 'പുതിയ പാസ്‌വേഡ് കുറഞ്ഞത് 4 അക്ഷരം വേണം', error: true);
      return;
    }
    await Db.settings.put('admin_pass', _newPw.text);
    await Db.logAction(action: 'Password Changed', entity: 'Settings');
    _oldPw.clear();
    _newPw.clear();
    if (mounted) toast(context, 'പാസ്‌വേഡ് മാറ്റി');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TekAppBar(title: Text('സെറ്റിംഗ്സ് & പ്രിന്റ് (Settings)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SectionTitle('ബിസിനസ് വിവരങ്ങൾ'),
          AppCard(
            child: Column(
              children: [
                tf(_c['shop_name']!, 'സ്ഥാപനത്തിന്റെ പേര്'),
                tf(_c['shop_address']!, 'വിലാസം', lines: 2),
                tf(_c['shop_phone']!, 'ഫോൺ നമ്പർ', phone: true),
                tf(_c['shop_email']!, 'ഇമെയിൽ'),
              ],
            ),
          ),
          const SectionTitle('ഇൻവോയ്സ് & GST'),
          AppCard(
            child: Column(
              children: [
                tf(_c['gstin']!, 'GSTIN (ഇല്ലെങ്കിൽ ഒഴിച്ചിടുക)'),
                tf(_c['gst_rate']!, 'GST % (വിലയിൽ ഉൾപ്പെട്ടത്)', number: true),
                tf(_c['invoice_prefix']!, 'ഇൻവോയ്സ് പ്രിഫിക്സ് (INV)'),
                tf(_c['invoice_footer']!, 'ഇൻവോയ്സ് ഫൂട്ടർ', lines: 2),
              ],
            ),
          ),
          const SectionTitle('ഷോപ്പ് ലൊക്കേഷൻ & ഹാജർ (Location & Geofence)'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: tf(_c['shop_latitude']!, 'Latitude', number: true),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: tf(_c['shop_longitude']!, 'Longitude', number: true),
                    ),
                  ],
                ),
                tf(_c['shop_allowed_radius']!,
                    'അനുവദിച്ച ദൂരം മീറ്ററിൽ (Radius in meters, e.g. 100)',
                    number: true),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _locLoading ? null : _useCurrentLocation,
                    icon: _locLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location_rounded),
                    label: const Text(
                        'എന്റെ ഇപ്പോഴത്തെ ലൊക്കേഷൻ എടുക്കുക (Use Current Location)'),
                  ),
                ),
                const Divider(height: 24),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                      'ഷോപ്പിന് പുറത്താണെങ്കിൽ ഹാജർ ബ്ലോക്ക് ചെയ്യുക'),
                  subtitle: Text(
                    _blockOutsideCheckIn
                        ? 'ബ്ലോക്ക് ചെയ്യും (Block outside-shop check-in)'
                        : 'മാർക്ക് ചെയ്യുക മാത്രം ചെയ്യും (Flagged as Outside shop)',
                    style: TextStyle(
                      fontSize: 12,
                      color: _blockOutsideCheckIn
                          ? Colors.red
                          : Colors.grey.shade600,
                    ),
                  ),
                  value: _blockOutsideCheckIn,
                  onChanged: (v) => setState(() => _blockOutsideCheckIn = v),
                ),
              ],
            ),
          ),
          const SectionTitle('ഉപയോക്താവ്'),
          AppCard(
              child: tf(
                  _c['active_user']!, 'Active user (Audit log-ൽ കാണിക്കും)')),
          const SizedBox(height: 14),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_rounded),
                label: const Text('സേവ് ചെയ്യുക')),
          ),
          const SectionTitle('അഡ്മിൻ പാസ്‌വേഡ് മാറ്റുക'),
          AppCard(
            child: Column(
              children: [
                tf(_oldPw, 'നിലവിലെ പാസ്‌വേഡ്', obscure: true),
                tf(_newPw, 'പുതിയ പാസ്‌വേഡ്', obscure: true),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                      onPressed: _changePassword,
                      icon: const Icon(Icons.lock_reset),
                      label: const Text('മാറ്റുക')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// PRINT & WHATSAPP ENGINE  (PDF is always printed on white paper)
// -----------------------------------------------------------------------------
String _pdfMoney(num v) => 'Rs. ${_plain.format(v)}';

String _lineName(Map line) {
  final imei = '${line['imei'] ?? ''}';
  return imei.isEmpty ? '${line['name']}' : '${line['name']} (IMEI: $imei)';
}

Future<void> printInvoice(BuildContext context, Map invoice,
    {required bool a4}) async {
  try {
    final shopName = Db.setting('shop_name', 'TEKFIX');
    final shopAddress = Db.setting('shop_address');
    final shopPhone = Db.setting('shop_phone');
    final shopEmail = Db.setting('shop_email');
    final gstin = Db.setting('gstin');
    final footer = Db.setting('invoice_footer', 'Thank you for your business!');

    final items = ((invoice['items'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final total = _d(invoice['total']);
    final subtotal =
        invoice.containsKey('subtotal') ? _d(invoice['subtotal']) : total;
    final discount = _d(invoice['discount']);
    final gstRate = _d(invoice['gstRate']);
    final taxable = gstRate > 0 ? total / (1 + gstRate / 100) : total;
    final gstAmt = total - taxable;
    final cash = _billCash(invoice);
    final upi = _d(invoice['upi']);
    final due = _d(invoice['due']);
    final advance = _d(invoice['serviceAdvanceApplied']);
    final date = _dt(invoice['createdAt']);
    final returned = _isReturned(invoice);

    // Malayalam names need a Unicode font; fall back to the built-in one if offline.
    pw.ThemeData? theme;
    try {
      final base = await PdfGoogleFonts.notoSansMalayalamRegular();
      final bold = await PdfGoogleFonts.notoSansMalayalamBold();
      theme = pw.ThemeData.withFont(base: base, bold: bold);
    } catch (_) {
      theme = null;
    }

    final fs = a4 ? 10.5 : 9.0;

    pw.Widget kv(String k, String v, {bool bold = false, double? size}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(k,
                  style: pw.TextStyle(
                      fontSize: size ?? fs,
                      fontWeight:
                          bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
              pw.Text(v,
                  style: pw.TextStyle(
                      fontSize: size ?? fs,
                      fontWeight:
                          bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
            ],
          ),
        );

    pw.Widget cell(String t,
            {bool bold = false, pw.TextAlign align = pw.TextAlign.left}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.all(4),
          child: pw.Text(t,
              textAlign: align,
              style: pw.TextStyle(
                  fontSize: fs,
                  fontWeight:
                      bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        );

    String lineTitle(Map l) {
      final w = '${l['warranty'] ?? ''}';
      final base = _lineName(l);
      if (w.isEmpty || w == 'No Warranty') return base;
      DateTime? end;
      if (w.contains('1 Year')) {
        end = DateTime(date.year + 1, date.month, date.day);
      } else if (w.contains('6 Months')) {
        end = DateTime(date.year, date.month + 6, date.day);
      } else if (w.contains('3 Months')) {
        end = DateTime(date.year, date.month + 3, date.day);
      }
      final endStr =
          end != null ? ' (Valid until ${dayFormat.format(end)})' : '';
      return '$base\nWarranty: $w$endStr';
    }

    final header = <pw.Widget>[
      pw.Center(
          child: pw.Text(shopName,
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: a4 ? 20 : 14))),
      if (shopAddress.isNotEmpty)
        pw.Center(
            child: pw.Text(shopAddress,
                style: pw.TextStyle(fontSize: fs - 1),
                textAlign: pw.TextAlign.center)),
      pw.Center(
          child: pw.Text(
              'Ph: $shopPhone${shopEmail.isEmpty ? '' : '  |  $shopEmail'}',
              style: pw.TextStyle(fontSize: fs - 1),
              textAlign: pw.TextAlign.center)),
      if (gstin.isNotEmpty)
        pw.Center(
            child: pw.Text('GSTIN: $gstin',
                style: pw.TextStyle(fontSize: fs - 1))),
      pw.SizedBox(height: 4),
      pw.Center(
          child: pw.Text(gstRate > 0 ? 'TAX INVOICE' : 'INVOICE',
              style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold, fontSize: fs + 1))),
      if (returned)
        pw.Center(
            child: pw.Text('** RETURNED **',
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: fs + 2))),
      pw.Divider(),
      kv('Invoice: ${invoice['invoice']}', dayFormat.format(date)),
      pw.Text('Customer: ${invoice['customerName']}',
          style: pw.TextStyle(fontSize: fs)),
      if ('${invoice['customerPhone'] ?? ''}'.isNotEmpty)
        pw.Text('Phone: ${invoice['customerPhone']}',
            style: pw.TextStyle(fontSize: fs)),
      pw.SizedBox(height: 4),
    ];

    final lines = <pw.Widget>[
      if (a4)
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          columnWidths: {
            0: const pw.FlexColumnWidth(5),
            1: const pw.FixedColumnWidth(36),
            2: const pw.FlexColumnWidth(1.6),
            3: const pw.FlexColumnWidth(1.8),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                cell('Item', bold: true),
                cell('Qty', bold: true, align: pw.TextAlign.right),
                cell('Rate', bold: true, align: pw.TextAlign.right),
                cell('Amount', bold: true, align: pw.TextAlign.right),
              ],
            ),
            for (final l in items)
              pw.TableRow(children: [
                cell(lineTitle(l)),
                cell('${_i(l['qty'])}', align: pw.TextAlign.right),
                cell(_plain.format(_d(l['price'])), align: pw.TextAlign.right),
                cell(_plain.format(_d(l['price']) * _i(l['qty'])),
                    align: pw.TextAlign.right),
              ]),
          ],
        )
      else ...[
        pw.Divider(),
        for (final l in items) ...[
          pw.Text(lineTitle(l),
              style:
                  pw.TextStyle(fontSize: fs, fontWeight: pw.FontWeight.bold)),
          kv('${_i(l['qty'])} x ${_plain.format(_d(l['price']))}',
              _plain.format(_d(l['price']) * _i(l['qty']))),
        ],
        pw.Divider(),
      ],
    ];

    final totals = <pw.Widget>[
      pw.SizedBox(height: 6),
      if (discount > 0) kv('Subtotal', _pdfMoney(subtotal)),
      if (discount > 0) kv('Discount', '- ${_pdfMoney(discount)}'),
      if (gstRate > 0) kv('Taxable value', _pdfMoney(taxable)),
      if (gstRate > 0)
        kv('GST @ ${gstRate.toStringAsFixed(gstRate == gstRate.roundToDouble() ? 0 : 1)}% (incl.)',
            _pdfMoney(gstAmt)),
      pw.Divider(),
      kv('TOTAL', _pdfMoney(total), bold: true, size: fs + 2),
      pw.SizedBox(height: 2),
      if (advance > 0) kv('Advance received', _pdfMoney(advance)),
      if (cash > 0) kv('Paid (Cash)', _pdfMoney(cash)),
      if (upi > 0) kv('Paid (UPI/Card)', _pdfMoney(upi)),
      if (due > 0) kv('BALANCE DUE', _pdfMoney(due), bold: true),
      pw.Divider(),
      pw.Center(
          child: pw.Text(footer,
              style: pw.TextStyle(fontSize: fs - 1),
              textAlign: pw.TextAlign.center)),
    ];

    final doc = pw.Document(theme: theme);
    if (a4) {
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(28),
          build: (pw.Context ctx) => [...header, ...lines, ...totals],
        ),
      );
    } else {
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.roll80,
          margin: const pw.EdgeInsets.all(8),
          build: (pw.Context ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [...header, ...lines, ...totals],
          ),
        ),
      );
    }

    await Printing.layoutPdf(
        name: '${invoice['invoice']}',
        onLayout: (PdfPageFormat format) async => doc.save());
  } catch (e) {
    if (context.mounted) {
      toast(context, 'പ്രിന്റ് പരാജയപ്പെട്ടു: $e', error: true);
    }
  }
}

String _waNumber(String phone) {
  final clean = phone.replaceAll(RegExp(r'\D'), '');
  return clean.length == 10 ? '91$clean' : clean;
}

Future<void> _openWhatsApp(
    BuildContext context, String phone, String message) async {
  final number = _waNumber(phone);
  if (number.isEmpty) {
    toast(context, 'ഫോൺ നമ്പർ ഇല്ല', error: true);
    return;
  }
  final url = Uri.https('wa.me', '/$number', {'text': message});
  try {
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      toast(context, 'WhatsApp തുറക്കാൻ പറ്റിയില്ല', error: true);
    }
  } catch (_) {
    if (context.mounted) {
      toast(context, 'WhatsApp തുറക്കാൻ പറ്റിയില്ല', error: true);
    }
  }
}

Future<void> sendInvoiceWhatsApp(BuildContext context, Map invoice) async {
  final items = (invoice['items'] as List?) ?? [];
  final lines = items
      .map((e) =>
          '${e['name']} x ${e['qty']} = ₹${_numText(_d(e['price']) * _i(e['qty']))}')
      .join('\n');
  final due = _d(invoice['due']);
  final msg = 'നമസ്കാരം ${invoice['customerName']},\n\n'
      '${Db.setting('shop_name', 'TEKFIX')} — ഇൻവോയ്സ് ${invoice['invoice']}\n'
      '$lines\n\n'
      '*ആകെ തുക: ₹${_numText(_d(invoice['total']))}*'
      '${due > 0 ? '\nബാക്കി: ₹${_numText(due)}' : ''}\n\n'
      'നന്ദി!';
  await _openWhatsApp(context, '${invoice['customerPhone'] ?? ''}', msg);
}

Future<void> sendDueReminder(BuildContext context, Map party) async {
  final msg = 'നമസ്കാരം ${party['name']},\n'
      '${Db.setting('shop_name', 'TEKFIX')}-ൽ നിങ്ങളുടെ ₹${_numText(_d(party['balance']))} കുടിശ്ശിക ബാക്കിയുണ്ട്. '
      'ദയവായി അടയ്ക്കുക. നന്ദി!';
  await _openWhatsApp(context, '${party['phone'] ?? ''}', msg);
}
