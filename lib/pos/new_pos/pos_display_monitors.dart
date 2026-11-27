// Second-monitor helpers (Windows): find a monitor other than the one the
// POS window is on, and put the customer display window there full screen,
// without a frame or taskbar button and without taking the cashier's focus.
//
// Only windows owned by this process are touched; nothing during tests.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

typedef PosMonitor = ({
  int handle,
  int left,
  int top,
  int right,
  int bottom,
  bool primary
});

final List<PosMonitor> _found = [];

int _enumProc(int hMonitor, int hdc, Pointer lpRect, int lParam) {
  final mi = calloc<MONITORINFO>();
  mi.ref.cbSize = sizeOf<MONITORINFO>();
  try {
    if (GetMonitorInfo(hMonitor, mi) != 0) {
      final r = mi.ref.rcMonitor;
      _found.add((
        handle: hMonitor,
        left: r.left,
        top: r.top,
        right: r.right,
        bottom: r.bottom,
        primary: (mi.ref.dwFlags & MONITORINFOF_PRIMARY) != 0,
      ));
    }
  } finally {
    free(mi);
  }
  return TRUE;
}

class PosDisplayMonitors {
  PosDisplayMonitors._();

  static const _mainClass = 'FLUTTER_RUNNER_WIN32_WINDOW';
  static const _subClass = 'FLUTTER_MULTI_WINDOW_WIN32_WINDOW';

  static bool get supported =>
      Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

  static List<PosMonitor> monitors() {
    if (!supported) return const [];
    _found.clear();
    final cb = Pointer.fromFunction<MONITORENUMPROC>(_enumProc, 0);
    EnumDisplayMonitors(NULL, nullptr, cb, 0);
    return List.of(_found);
  }

  static bool _ours(int hwnd) {
    if (hwnd == 0) return false;
    final pid = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hwnd, pid);
      return pid.value == GetCurrentProcessId();
    } finally {
      free(pid);
    }
  }

  static int _find(String cls) {
    final c = cls.toNativeUtf16();
    try {
      final w = FindWindow(c, nullptr);
      return _ours(w) ? w : 0;
    } finally {
      free(c);
    }
  }

  /// The monitor for the customer: not the one the POS window is on
  /// (a non-primary one when there are several). Null = no second monitor.
  static PosMonitor? customerMonitor() {
    final all = monitors();
    // Developer check on a one-monitor PC: TEKFIX_DISPLAY_TEST=1 puts the
    // customer window in a 640x480 box at the right of the screen.
    if (all.length == 1 && Platform.environment['TEKFIX_DISPLAY_TEST'] == '1') {
      final p = all.first;
      return (
        handle: -1,
        left: p.right - 660,
        top: p.top + 80,
        right: p.right - 20,
        bottom: p.top + 560,
        primary: false,
      );
    }
    if (all.length < 2) return null;
    final main = _find(_mainClass);
    final mainMon =
        main == 0 ? 0 : MonitorFromWindow(main, MONITOR_DEFAULTTONEAREST);
    final others = all.where((m) => m.handle != mainMon).toList();
    if (others.isEmpty) return null;
    others.sort((a, b) => (a.primary ? 1 : 0).compareTo(b.primary ? 1 : 0));
    return others.first;
  }

  /// Full screen on [m], no frame, no taskbar button, on top, no focus.
  static bool placeCustomerWindow(PosMonitor m) {
    if (!supported) return false;
    final hwnd = _find(_subClass);
    if (hwnd == 0) return false;
    SetWindowLongPtr(hwnd, GWL_STYLE, WS_POPUP | WS_VISIBLE);
    final ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    SetWindowLongPtr(
        hwnd, GWL_EXSTYLE, (ex | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
    SetWindowPos(hwnd, HWND_TOPMOST, m.left, m.top, m.right - m.left,
        m.bottom - m.top, SWP_FRAMECHANGED | SWP_SHOWWINDOW | SWP_NOACTIVATE);
    return true;
  }

  static void hideCustomerWindow() {
    if (!supported) return;
    final hwnd = _find(_subClass);
    if (hwnd != 0) ShowWindow(hwnd, SW_HIDE);
  }
}
