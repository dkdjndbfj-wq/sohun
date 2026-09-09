#include "desktop_rfid_serial_channel.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <utility>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace sohun::rfid;

namespace {

int checks = 0;
const DWORD kPlatformThread = GetCurrentThreadId();
HWND test_window = nullptr;

void Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAILED: " << message << '\n';
    std::exit(1);
  }
  ++checks;
}

struct Reply {
  int count = 0;
  bool success = false;
  bool not_implemented = false;
  EncodableValue value;
  std::string error;
  EncodableValue details;
};

class FakeMessenger final : public flutter::BinaryMessenger {
 public:
  void Send(const std::string&, const uint8_t*, size_t,
            flutter::BinaryReply) const override {
    Expect(false, "adapter must not initiate unsolicited engine messages");
  }

  void SetMessageHandler(const std::string& channel,
                         flutter::BinaryMessageHandler handler) override {
    Expect(GetCurrentThreadId() == kPlatformThread,
           "handler registration stays on platform thread");
    Expect(channel == "top.sohun/desktop_rfid_serial",
           "adapter registers the production channel name");
    handler_ = std::move(handler);
  }

  std::shared_ptr<Reply> Call(const std::string& method,
                              EncodableValue args = EncodableValue()) {
    Expect(static_cast<bool>(handler_), "channel handler is registered");
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    const auto message = codec.EncodeMethodCall(
        flutter::MethodCall<EncodableValue>(
            method, std::make_unique<EncodableValue>(std::move(args))));
    auto output = std::make_shared<Reply>();
    handler_(message->data(), message->size(),
             [output, &codec](const uint8_t* bytes, size_t size) {
               Expect(GetCurrentThreadId() == kPlatformThread,
                      "all replies are delivered on platform thread");
               ++output->count;
               Expect(output->count == 1, "method replies exactly once");
               if (size == 0) {
                 output->not_implemented = true;
                 return;
               }
               flutter::MethodResultFunctions<EncodableValue> result(
                   [output](const EncodableValue* value) {
                     output->success = true;
                     if (value != nullptr) {
                       output->value = *value;
                     }
                   },
                   [output](const std::string& code, const std::string&,
                            const EncodableValue* details) {
                     output->error = code;
                     if (details != nullptr) {
                       output->details = *details;
                     }
                   },
                   [output]() { output->not_implemented = true; });
               Expect(codec.DecodeAndProcessResponseEnvelope(bytes, size,
                                                              &result),
                      "reply decodes with the real Flutter standard codec");
             });
    return output;
  }

  bool has_handler() const { return static_cast<bool>(handler_); }

 private:
  flutter::BinaryMessageHandler handler_;
};

struct FakeState {
  int opens = 0;
  int reads = 0;
  int writes = 0;
  std::vector<uint8_t> written;
  SerialError write_error;
};

class FakeBackend final : public SerialBackend {
 public:
  explicit FakeBackend(std::shared_ptr<FakeState> state)
      : state_(std::move(state)) {}

  SerialError ListPorts(std::vector<SerialPortInfo>* ports) override {
    *ports = {{"COM5", "USB-SERIAL CH340 (COM5)", "USB\\VID_1A86&PID_7523"},
              {"COM7", "Serial device (COM7)", ""}};
    return {};
  }
  SerialError Open(const std::string&, HANDLE) override {
    ++state_->opens;
    return {};
  }
  SerialError Read(std::vector<uint8_t>* bytes, HANDLE) override {
    ++state_->reads;
    *bytes = {0, 128, 255};
    return {};
  }
  SerialError Write(const std::vector<uint8_t>& bytes, HANDLE) override {
    ++state_->writes;
    state_->written = bytes;
    return state_->write_error;
  }
  void Close() override {}

 private:
  std::shared_ptr<FakeState> state_;
};

void Wait(DesktopRfidSerialChannel* channel, const std::shared_ptr<Reply>& reply) {
  const auto deadline = GetTickCount64() + 3000;
  while (reply->count == 0 && GetTickCount64() < deadline) {
    MSG message{};
    while (PeekMessageW(&message, test_window,
                        DesktopRfidSerialChannel::kCompletionMessage,
                        DesktopRfidSerialChannel::kCompletionMessage,
                        PM_REMOVE)) {
      Expect(message.wParam == 0 && message.lParam == 0,
             "completion notification carries no worker-owned pointers");
      channel->DrainResponses();
    }
    if (reply->count == 0) {
      Sleep(1);
    }
  }
  Expect(reply->count == 1, "asynchronous method completes within test deadline");
}

EncodableMap Connection(const std::string& id) {
  return {{EncodableValue("connectionId"), EncodableValue(id)}};
}

void TestChannelContract() {
  // Message-only window is never visible and does not start the app or engine.
  test_window = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0,
                                 HWND_MESSAGE, nullptr, nullptr, nullptr);
  Expect(test_window != nullptr, "platform message-only window can be created");
  FakeMessenger messenger;
  auto state = std::make_shared<FakeState>();
  auto channel = std::make_unique<DesktopRfidSerialChannel>(
      &messenger, test_window, std::make_unique<FakeBackend>(state));

  auto reply = messenger.Call("unknown");
  Expect(reply->not_implemented, "unknown method returns NotImplemented");
  for (auto args : {EncodableValue(), EncodableValue("COM5"),
                    EncodableValue(EncodableMap{{EncodableValue("port"),
                                                 EncodableValue(5)}}),
                    EncodableValue(EncodableMap{{EncodableValue("port"),
                                                 EncodableValue("\\\\.\\COM5")}})}) {
    reply = messenger.Call("open", std::move(args));
    Expect(reply->error == "invalid_arguments" && state->opens == 0,
           "malformed or path-like open argument cannot reach backend");
  }
  for (const auto* method : {"read", "write", "close"}) {
    reply = messenger.Call(method);
    Expect(reply->error == "invalid_arguments",
           "connection-scoped operations require a connection ID");
  }

  reply = messenger.Call("listPorts");
  Wait(channel.get(), reply);
  const auto& ports = std::get<EncodableList>(reply->value);
  Expect(reply->success && ports.size() == 2 && state->opens == 0,
         "listPorts returns metadata without opening a device");
  const auto& first_port = std::get<EncodableMap>(ports[0]);
  Expect(std::get<std::string>(first_port.at(EncodableValue("port"))) == "COM5" &&
             first_port.count(EncodableValue("label")) == 1 &&
             first_port.count(EncodableValue("hardwareId")) == 1,
         "port metadata has the exact Dart field names");
  Expect(std::get<EncodableMap>(ports[1]).count(EncodableValue("hardwareId")) == 0,
         "unknown hardwareId remains absent rather than fabricated");

  const EncodableValue port_args(
      EncodableMap{{EncodableValue("port"), EncodableValue("COM5")}});
  reply = messenger.Call("open", port_args);
  Wait(channel.get(), reply);
  const auto id = std::get<std::string>(
      std::get<EncodableMap>(reply->value).at(EncodableValue("connectionId")));
  Expect(reply->success && !id.empty() && state->opens == 1,
         "open result contains the connectionId map expected by Dart");
  reply = messenger.Call("open", port_args);
  Wait(channel.get(), reply);
  Expect(reply->error == "busy", "second open cannot replace an active session");

  reply = messenger.Call("read", EncodableValue(Connection(id)));
  Wait(channel.get(), reply);
  Expect(reply->success && std::get<std::vector<uint8_t>>(reply->value) ==
                                std::vector<uint8_t>({0, 128, 255}),
         "read result is a typed Uint8List with binary bytes preserved");
  auto write_args = Connection(id);
  write_args.emplace(EncodableValue("bytes"),
                      EncodableValue(EncodableList{EncodableValue(1)}));
  reply = messenger.Call("write", EncodableValue(write_args));
  Expect(reply->error == "invalid_arguments" && state->writes == 0,
         "ordinary Dart List cannot masquerade as Uint8List");
  write_args[EncodableValue("bytes")] =
      EncodableValue(std::vector<uint8_t>(kMaxSerialTransfer + 1, 0));
  reply = messenger.Call("write", EncodableValue(write_args));
  Expect(reply->error == "invalid_arguments" && state->writes == 0,
         "oversized typed byte payload is rejected before dispatch");
  write_args[EncodableValue("bytes")] =
      EncodableValue(std::vector<uint8_t>{0, 128, 255});
  reply = messenger.Call("write", EncodableValue(write_args));
  Wait(channel.get(), reply);
  Expect(reply->success && reply->value.IsNull() &&
             state->written == std::vector<uint8_t>({0, 128, 255}),
         "write returns null only after the complete fake transfer");

  reply = messenger.Call("close", EncodableValue(Connection("stale")));
  Wait(channel.get(), reply);
  Expect(reply->error == "stale_connection",
         "old generation cannot close the current connection");
  state->write_error = {"serial_timeout", "Fake partial write", WAIT_TIMEOUT};
  reply = messenger.Call("write", EncodableValue(write_args));
  Wait(channel.get(), reply);
  Expect(reply->error == "serial_timeout" &&
             std::get<int64_t>(reply->details) == WAIT_TIMEOUT,
         "native I/O failure preserves code and Windows details");
  reply = messenger.Call("read", EncodableValue(Connection(id)));
  Wait(channel.get(), reply);
  Expect(reply->error == "stale_connection",
         "partial-transfer failure invalidates subsequent reads");

  reply = messenger.Call("listPorts");
  channel.reset();
  Expect(reply->error == "disconnected" && reply->count == 1,
         "teardown settles a pending method once before messenger destruction");
  Expect(!messenger.has_handler(), "teardown unregisters the method handler");
  Expect(DestroyWindow(test_window) != FALSE,
         "message-only test window is destroyed after channel shutdown");
  test_window = nullptr;
}

}  // namespace

int main() {
  TestChannelContract();
  std::cout << "Desktop RFID Flutter channel: " << checks
            << " checks passed; real codec, fake messenger and serial backend.\n";
  return 0;
}
