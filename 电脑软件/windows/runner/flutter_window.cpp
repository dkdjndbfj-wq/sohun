#include "flutter_window.h"

#include <algorithm>
#include <cmath>
#include <optional>
#include <vector>
#include <wincrypt.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr UINT_PTR kStartupRevealTimerId = 0x534F4855;

int ReadIntArgument(const flutter::EncodableValue* arguments,
                    const char* name,
                    int fallback) {
  const auto* map =
      arguments == nullptr
          ? nullptr
          : std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    return fallback;
  }
  const auto value = map->find(flutter::EncodableValue(name));
  if (value == map->end()) {
    return fallback;
  }
  if (const auto* number = std::get_if<int32_t>(&value->second)) {
    return static_cast<int>(*number);
  }
  if (const auto* number = std::get_if<int64_t>(&value->second)) {
    return static_cast<int>(*number);
  }
  if (const auto* number = std::get_if<double>(&value->second)) {
    return static_cast<int>(*number);
  }
  return fallback;
}

double EaseOutCubic(double value) {
  const double inverse = 1.0 - value;
  return 1.0 - inverse * inverse * inverse;
}

double EaseInOutCubic(double value) {
  if (value < 0.5) {
    return 4.0 * value * value * value;
  }
  return 1.0 - std::pow(-2.0 * value + 2.0, 3.0) / 2.0;
}

int LerpInt(int start, int end, double progress) {
  return static_cast<int>(
      std::lround(start + (end - start) * progress));
}

}  // namespace

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

#ifndef SOHUN_FARM_PRODUCT
  desktop_rfid_serial_channel_ = std::make_unique<DesktopRfidSerialChannel>(
      flutter_controller_->engine()->messenger(), GetHandle());
#endif

  security_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "consumable_tracker/security",
          &flutter::StandardMethodCodec::GetInstance());
  security_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        const auto* input = std::get_if<std::vector<uint8_t>>(call.arguments());
        if (input == nullptr) {
          result->Error("invalid_arguments", "Expected a byte array");
          return;
        }
        DATA_BLOB in_blob{};
        in_blob.pbData = const_cast<BYTE*>(input->data());
        in_blob.cbData = static_cast<DWORD>(input->size());
        DATA_BLOB out_blob{};
        BOOL ok = FALSE;
        if (call.method_name() == "protect") {
          ok = CryptProtectData(&in_blob, L"Consumable Tracker credential",
                                nullptr, nullptr, nullptr,
                                CRYPTPROTECT_UI_FORBIDDEN, &out_blob);
        } else if (call.method_name() == "unprotect") {
          ok = CryptUnprotectData(&in_blob, nullptr, nullptr, nullptr, nullptr,
                                  CRYPTPROTECT_UI_FORBIDDEN, &out_blob);
        } else {
          result->NotImplemented();
          return;
        }
        if (!ok) {
          result->Error("dpapi_failed", "Windows DPAPI operation failed",
                        flutter::EncodableValue(
                            static_cast<int64_t>(GetLastError())));
          return;
        }
        std::vector<uint8_t> output(out_blob.pbData,
                                    out_blob.pbData + out_blob.cbData);
        LocalFree(out_blob.pbData);
        result->Success(flutter::EncodableValue(output));
      });

  startup_window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "consumable_tracker/startup_window",
          &flutter::StandardMethodCodec::GetInstance());
  startup_window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "prepareReveal") {
          PrepareStartupReveal(
              ReadIntArgument(call.arguments(), "cornerRadius", 14));
          result->Success();
          return;
        }
        if (call.method_name() == "startReveal") {
          StartStartupReveal(
              ReadIntArgument(call.arguments(), "durationMs", 820));
          result->Success();
          return;
        }
        if (call.method_name() == "finishReveal") {
          FinishStartupReveal(true);
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  FinishStartupReveal(false);
  if (flutter_controller_) {
    desktop_rfid_serial_channel_.reset();
    startup_window_channel_.reset();
    security_channel_.reset();
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == DesktopRfidSerialChannel::kCompletionMessage) {
    if (desktop_rfid_serial_channel_) {
      desktop_rfid_serial_channel_->DrainResponses();
    }
    return 0;
  }
  if (message == WM_TIMER && wparam == kStartupRevealTimerId) {
    UpdateStartupReveal();
    return 0;
  }

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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::PrepareStartupReveal(int corner_radius) {
  HWND window = GetHandle();
  if (window == nullptr) {
    return;
  }

  FinishStartupReveal(false);

  RECT bounds{};
  if (!GetWindowRect(window, &bounds)) {
    return;
  }

  startup_reveal_start_size_.cx = bounds.right - bounds.left;
  startup_reveal_start_size_.cy = bounds.bottom - bounds.top;
  startup_reveal_start_position_.x = bounds.left;
  startup_reveal_start_position_.y = bounds.top;

  const UINT dpi = GetDpiForWindow(window);
  startup_reveal_corner_radius_ =
      std::max(1, MulDiv(std::max(1, corner_radius), dpi, 96));

  HRGN region = CreateRoundRectRgn(
      0, 0, startup_reveal_start_size_.cx + 1,
      startup_reveal_start_size_.cy + 1,
      startup_reveal_corner_radius_ * 2,
      startup_reveal_corner_radius_ * 2);
  if (region == nullptr) {
    return;
  }
  if (SetWindowRgn(window, region, TRUE) == 0) {
    DeleteObject(region);
    return;
  }
  // SetWindowRgn owns |region| after a successful call.
  startup_reveal_prepared_ = true;
}

void FlutterWindow::StartStartupReveal(int duration_ms) {
  HWND window = GetHandle();
  if (window == nullptr || !startup_reveal_prepared_) {
    return;
  }

  RECT bounds{};
  if (!GetWindowRect(window, &bounds)) {
    FinishStartupReveal(false);
    return;
  }

  startup_reveal_start_position_.x = bounds.left;
  startup_reveal_start_position_.y = bounds.top;
  startup_reveal_target_size_.cx = bounds.right - bounds.left;
  startup_reveal_target_size_.cy = bounds.bottom - bounds.top;

  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  const HMONITOR monitor =
      MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  if (!GetMonitorInfo(monitor, &monitor_info)) {
    FinishStartupReveal(false);
    return;
  }

  const RECT work = monitor_info.rcWork;
  startup_reveal_target_position_.x =
      work.left +
      ((work.right - work.left) - startup_reveal_target_size_.cx) / 2;
  startup_reveal_target_position_.y =
      work.top +
      ((work.bottom - work.top) - startup_reveal_target_size_.cy) / 2;
  startup_reveal_duration_ms_ = std::max(1, duration_ms);
  startup_reveal_started_at_ = GetTickCount64();
  startup_reveal_running_ = true;

  SetTimer(window, kStartupRevealTimerId, 16, nullptr);
  UpdateStartupReveal();
}

void FlutterWindow::UpdateStartupReveal() {
  HWND window = GetHandle();
  if (window == nullptr || !startup_reveal_running_) {
    return;
  }

  const double elapsed =
      static_cast<double>(GetTickCount64() - startup_reveal_started_at_);
  const double progress =
      std::clamp(elapsed / startup_reveal_duration_ms_, 0.0, 1.0);
  // Ease the top-left anchor into place without the early high-velocity jump
  // that made the compact window appear to stutter. The last 40% is then a
  // clean right-and-bottom expansion, matching the Dart fallback geometry.
  const double position_progress =
      EaseInOutCubic(std::clamp(progress / 0.60, 0.0, 1.0));
  const double size_progress = EaseInOutCubic(progress);

  const int x = LerpInt(startup_reveal_start_position_.x,
                        startup_reveal_target_position_.x,
                        position_progress);
  const int y = LerpInt(startup_reveal_start_position_.y,
                        startup_reveal_target_position_.y,
                        position_progress);
  SetWindowPos(window, nullptr, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_NOOWNERZORDER | SWP_NOREDRAW);

  const int width = LerpInt(startup_reveal_start_size_.cx,
                            startup_reveal_target_size_.cx,
                            size_progress);
  const int height = LerpInt(startup_reveal_start_size_.cy,
                             startup_reveal_target_size_.cy,
                             size_progress);
  HRGN region = CreateRoundRectRgn(
      0, 0, width + 1, height + 1,
      startup_reveal_corner_radius_ * 2,
      startup_reveal_corner_radius_ * 2);
  // Flutter is already producing one composited frame per handoff tick. Do
  // not synchronously invalidate the complete native window as well; that
  // duplicated redraw was the largest source of visible startup hitching.
  if (region != nullptr && SetWindowRgn(window, region, FALSE) == 0) {
    DeleteObject(region);
  }

  if (progress >= 1.0) {
    FinishStartupReveal(true);
  }
}

void FlutterWindow::FinishStartupReveal(bool jump_to_end) {
  HWND window = GetHandle();
  if (window == nullptr) {
    startup_reveal_prepared_ = false;
    startup_reveal_running_ = false;
    return;
  }

  KillTimer(window, kStartupRevealTimerId);
  if (jump_to_end && startup_reveal_running_) {
    SetWindowPos(window, nullptr, startup_reveal_target_position_.x,
                 startup_reveal_target_position_.y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_NOOWNERZORDER);
  }
  if (startup_reveal_prepared_) {
    SetWindowRgn(window, nullptr, TRUE);
  }
  startup_reveal_prepared_ = false;
  startup_reveal_running_ = false;
}
