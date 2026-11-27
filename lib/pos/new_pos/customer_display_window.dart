// Customer Display on a second monitor (Windows).
//
// The display is a second window of THIS app (desktop_multi_window: its
// own small Flutter engine in the same process). It never opens Hive,
// Firebase or a login: it only renders the CustomerDisplayState maps the
// POS sends it. If the second monitor is unplugged the window is hidden and
// the POS keeps working (single-monitor Customer View still available).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'customer_display.dart';
import 'pos_display_monitors.dart';
import 'pos_theme.dart';

const String kCustomerDisplayArg = 'tekfix_customer_display_v1';
const String kCustomerDisplaySetting = 'pos_customer_display';

enum CustomerDisplayMode { auto, second, off }

extension CustomerDisplayModeLabel on CustomerDisplayMode {
  String get label => switch (this) {
        CustomerDisplayMode.auto => 'Auto (ഓട്ടോ)',
        CustomerDisplayMode.second => 'Second monitor (രണ്ടാം സ്ക്രീൻ)',
        CustomerDisplayMode.off => 'Off (ഓഫ്)',
      };
}

CustomerDisplayMode customerDisplayModeFrom(String v) =>
    CustomerDisplayMode.values
        .firstWhere((m) => m.name == v, orElse: () => CustomerDisplayMode.auto);

// ------------------------------------------------- the display window app
/// Called at the very start of main(): when this engine is the customer
/// display window, runs the display app and returns true (the POS start-up
/// with Firebase / Hive is then skipped for this window).
Future<bool> runCustomerDisplayWindowIfNeeded() async {
  if (kIsWeb || !Platform.isWindows) return false;
  try {
    final c = await WindowController.fromCurrentEngine()
        .timeout(const Duration(seconds: 3));
    if (c.arguments != kCustomerDisplayArg) return false;
    runApp(_CustomerDisplayWindowApp(controller: c));
    return true;
  } catch (_) {
    return false; // not a multi-window engine: the normal POS window
  }
}

class _CustomerDisplayWindowApp extends StatefulWidget {
  final WindowController controller;
  const _CustomerDisplayWindowApp({required this.controller});

  @override
  State<_CustomerDisplayWindowApp> createState() =>
      _CustomerDisplayWindowAppState();
}

class _CustomerDisplayWindowAppState extends State<_CustomerDisplayWindowApp> {
  final _state = ValueNotifier<CustomerDisplayState>(const CustomerDisplayState(
      phase: DisplayPhase.idle, message: kDisplayWelcome));

  @override
  void initState() {
    super.initState();
    widget.controller.setWindowMethodHandler((call) async {
      if (call.method == 'state' && call.arguments is String) {
        try {
          final m = jsonDecode(call.arguments as String);
          if (m is Map) _state.value = CustomerDisplayState.fromMap(m);
        } catch (_) {/* ignore a bad message, keep the last screen */}
        return true;
      }
      return null;
    });
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'TEKFIX Customer Display',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: PosTokens.primary),
          scaffoldBackgroundColor: PosTokens.bg,
        ),
        home: Scaffold(
          body: ValueListenableBuilder<CustomerDisplayState>(
            valueListenable: _state,
            builder: (_, v, __) => CustomerDisplayView(state: v),
          ),
        ),
      );
}

// ------------------------------------------------------ the POS side host
/// Opens / places / hides the display window and sends it the state.
class CustomerDisplayHost {
  CustomerDisplayHost._();
  static final CustomerDisplayHost instance = CustomerDisplayHost._();

  /// True while the customer window is showing on a second monitor.
  final ValueNotifier<bool> showing = ValueNotifier(false);

  /// True when the mode is "Second monitor" but none is connected.
  final ValueNotifier<bool> missing = ValueNotifier(false);

  CustomerDisplayMode _mode = CustomerDisplayMode.auto;
  WindowController? _ctrl;
  Timer? _poll;
  String? _lastJson;
  bool _syncing = false;

  bool get _supported => !kIsWeb && PosDisplayMonitors.supported;

  CustomerDisplayMode get mode => _mode;

  void start(CustomerDisplayMode mode) {
    _mode = mode;
    if (!_supported) return;
    _poll?.cancel();
    // Monitor plugged / unplugged is picked up within ~1.5 s.
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _sync());
    _sync();
  }

  void setMode(CustomerDisplayMode mode) {
    _mode = mode;
    _sync();
  }

  /// POS screen closed: stop watching (the window keeps the idle screen).
  void stop() {
    _poll?.cancel();
    _poll = null;
  }

  void push(CustomerDisplayState s) {
    _lastJson = jsonEncode(s.toMap());
    if (showing.value) _send();
  }

  Future<void> _sync() async {
    if (_syncing || !_supported) return;
    _syncing = true;
    try {
      final target = _mode == CustomerDisplayMode.off
          ? null
          : PosDisplayMonitors.customerMonitor();
      missing.value = _mode == CustomerDisplayMode.second && target == null;
      if (target == null) {
        _hide();
        return;
      }
      final c = await _ensureWindow();
      if (c == null || !PosDisplayMonitors.placeCustomerWindow(target)) {
        _hide();
        return;
      }
      showing.value = true;
      await _send(); // also re-sends in case the window started late
    } catch (_) {
      _hide(); // never let the display break billing
    } finally {
      _syncing = false;
    }
  }

  Future<WindowController?> _ensureWindow() async {
    if (_ctrl != null) return _ctrl;
    try {
      _ctrl = await WindowController.create(const WindowConfiguration(
          arguments: kCustomerDisplayArg, hiddenAtLaunch: true));
    } catch (_) {
      _ctrl = null;
    }
    return _ctrl;
  }

  void _hide() {
    if (!showing.value) return;
    PosDisplayMonitors.hideCustomerWindow();
    showing.value = false;
  }

  Future<void> _send() async {
    final c = _ctrl;
    final j = _lastJson;
    if (c == null || j == null) return;
    try {
      await c.invokeMethod('state', j).timeout(const Duration(seconds: 2));
    } catch (_) {/* window still starting: the next sync re-sends */}
  }
}
