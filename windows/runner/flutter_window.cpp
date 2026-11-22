#include "flutter_window.h"

#include <optional>

namespace {
// Reveals the Flutter view if the first frame never reports (safety net).
constexpr UINT_PTR kRevealViewTimer = 0x7E4F;
}  // namespace

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Keep the Flutter view hidden until it has drawn its first frame: the
  // window (dark background brush) is shown at once, and the view appears
  // only with real content, so there is no white flash during Dart startup.
  ::ShowWindow(flutter_controller_->view()->GetNativeWindow(), SW_HIDE);
  ::SetTimer(GetHandle(), kRevealViewTimer, 15000, nullptr);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    RevealFlutterView();
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::RevealFlutterView() {
  ::KillTimer(GetHandle(), kRevealViewTimer);
  if (flutter_controller_ && flutter_controller_->view()) {
    ::ShowWindow(flutter_controller_->view()->GetNativeWindow(), SW_SHOW);
  }
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_TIMER:
      if (wparam == kRevealViewTimer) {
        RevealFlutterView();
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
