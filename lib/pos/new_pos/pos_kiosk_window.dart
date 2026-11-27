// Customer View on a single monitor: make THIS app's window full screen and
// always on top while the customer looks at the bill, then put it back
// exactly as it was. Best effort: Windows itself still allows Alt+Tab /
// the Windows key, which an app cannot block.
//
// Only a window owned by this process is ever touched (never another
// program's window, and nothing during `flutter test`).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class PosKioskWindow {
  PosKioskWindow._();

  static const _kClass = 'FLUTTER_RUNNER_WIN32_WINDOW';
  static int _hwnd = 0;
  static int _style = 0;
  static Pointer<WINDOWPLACEMENT>? _place;
  static bool _active = false;

  static bool get active => _active;

  static bool get _supported =>
      Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

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

  static bool _isFlutterWindow(int hwnd) {
    final buf = wsalloc(64);
    try {
      return GetClassName(hwnd, buf, 64) > 0 && buf.toDartString() == _kClass;
    } finally {
      free(buf);
    }
  }

  static int _ourWindow() {
    final fg = GetForegroundWindow();
    if (_ours(fg) && _isFlutterWindow(fg)) return fg;
    final cls = _kClass.toNativeUtf16();
    try {
      final w = FindWindow(cls, nullptr);
      return _ours(w) ? w : 0;
    } finally {
      free(cls);
    }
  }

  /// Full screen + always on top. Returns false when not possible.
  static bool enter() {
    if (_active) return true;
    if (!_supported) return false;
    try {
      final hwnd = _ourWindow();
      if (hwnd == 0) return false;
      final place = calloc<WINDOWPLACEMENT>();
      place.ref.length = sizeOf<WINDOWPLACEMENT>();
      if (GetWindowPlacement(hwnd, place) == 0) {
        free(place);
        return false;
      }
      final style = GetWindowLongPtr(hwnd, GWL_STYLE);
      final mi = calloc<MONITORINFO>();
      mi.ref.cbSize = sizeOf<MONITORINFO>();
      try {
        final mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        if (GetMonitorInfo(mon, mi) == 0) {
          free(place);
          return false;
        }
        SetWindowLongPtr(
            hwnd, GWL_STYLE, style & ~(WS_CAPTION | WS_THICKFRAME));
        final r = mi.ref.rcMonitor;
        SetWindowPos(hwnd, HWND_TOPMOST, r.left, r.top, r.right - r.left,
            r.bottom - r.top, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
      } finally {
        free(mi);
      }
      _hwnd = hwnd;
      _style = style;
      _place = place;
      _active = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Back to the normal window (same size, position and state as before).
  static void exit() {
    if (!_active) return;
    try {
      SetWindowLongPtr(_hwnd, GWL_STYLE, _style);
      final p = _place;
      if (p != null) SetWindowPlacement(_hwnd, p);
      SetWindowPos(_hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    } catch (_) {
      // best effort
    } finally {
      final p = _place;
      if (p != null) free(p);
      _place = null;
      _hwnd = 0;
      _active = false;
    }
  }
}
