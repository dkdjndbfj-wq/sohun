#ifndef RUNNER_DESKTOP_RFID_SERIAL_CHANNEL_H_
#define RUNNER_DESKTOP_RFID_SERIAL_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <map>
#include <memory>

#include "desktop_rfid_serial_transport.h"

class DesktopRfidSerialChannel {
 public:
  static constexpr UINT kCompletionMessage = WM_APP + 0x534;

  DesktopRfidSerialChannel(
      flutter::BinaryMessenger* messenger, HWND window,
      std::unique_ptr<sohun::rfid::SerialBackend> backend =
          sohun::rfid::MakeWin32SerialBackend());
  ~DesktopRfidSerialChannel();
  DesktopRfidSerialChannel(const DesktopRfidSerialChannel&) = delete;
  DesktopRfidSerialChannel& operator=(const DesktopRfidSerialChannel&) = delete;

  // Called exclusively by the owning Flutter window/platform thread.
  void DrainResponses();

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<Result> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<sohun::rfid::AsyncSerialTransport> transport_;
  std::map<uint64_t, std::unique_ptr<Result>> pending_results_;
  uint64_t next_request_id_ = 0;
};

#endif  // RUNNER_DESKTOP_RFID_SERIAL_CHANNEL_H_
