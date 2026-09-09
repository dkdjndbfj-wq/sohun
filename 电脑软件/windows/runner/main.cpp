#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

#ifdef SOHUN_FARM_PRODUCT
constexpr wchar_t kSingleInstanceMutex[] =
    L"Local\\sohun-farm-desktop-05f685a9-4f66-4f9e-9a6b-5e9131cd7317";
constexpr wchar_t kWindowTitle[] = L"sohun 农场";
#else
constexpr wchar_t kSingleInstanceMutex[] =
    L"Local\\sohun-desktop-4bf123ad-8fb7-4ba9-a035-c0323928bb52";
constexpr wchar_t kWindowTitle[] = L"sohun";
#endif
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

bool AllowsMultipleInstances() {
  return wcsstr(GetCommandLineW(), L"--allow-multiple-instances") != nullptr;
}

void ActivateExistingInstance() {
  HWND existing = nullptr;
  for (int attempt = 0; attempt < 40 && existing == nullptr; ++attempt) {
    existing = FindWindowW(kWindowClassName, kWindowTitle);
    if (existing == nullptr) {
      Sleep(50);
    }
  }
  if (existing == nullptr) {
    return;
  }

  if (IsIconic(existing)) {
    ShowWindow(existing, SW_RESTORE);
  } else {
    ShowWindow(existing, SW_SHOW);
  }
  SetForegroundWindow(existing);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  HANDLE single_instance_mutex = nullptr;
  if (!AllowsMultipleInstances()) {
    single_instance_mutex = CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
    if (single_instance_mutex != nullptr &&
        GetLastError() == ERROR_ALREADY_EXISTS) {
      ActivateExistingInstance();
      CloseHandle(single_instance_mutex);
      return EXIT_SUCCESS;
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Start with the same compact surface used by the Flutter splash. The
  // native host remains hidden until Flutter's first frame, so the normal
  // 1440x900 application frame is never flashed behind the logo animation.
  Win32Window::Point origin(120, 80);
  Win32Window::Size size(520, 292);
  if (!window.Create(kWindowTitle, origin, size)) {
    ::CoUninitialize();
    if (single_instance_mutex != nullptr) {
      CloseHandle(single_instance_mutex);
    }
    return EXIT_FAILURE;
  }
  // window_manager 接管窗口生命周期：关闭=隐藏到托盘，不退出进程
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
