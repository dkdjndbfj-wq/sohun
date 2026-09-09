#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "desktop_rfid_serial_channel.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
 LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void PrepareStartupReveal(int corner_radius);
  void StartStartupReveal(int duration_ms);
  void UpdateStartupReveal();
  void FinishStartupReveal(bool jump_to_end);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      security_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      startup_window_channel_;
  std::unique_ptr<DesktopRfidSerialChannel> desktop_rfid_serial_channel_;

  bool startup_reveal_prepared_ = false;
  bool startup_reveal_running_ = false;
  int startup_reveal_duration_ms_ = 820;
  int startup_reveal_corner_radius_ = 14;
  ULONGLONG startup_reveal_started_at_ = 0;
  SIZE startup_reveal_start_size_{};
  SIZE startup_reveal_target_size_{};
  POINT startup_reveal_start_position_{};
  POINT startup_reveal_target_position_{};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
