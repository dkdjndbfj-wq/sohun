#include "desktop_rfid_serial_channel.h"

#include <flutter/standard_method_codec.h>

#include <utility>

namespace {

const flutter::EncodableValue* Argument(const flutter::EncodableValue* args,
                                        const char* key) {
  const auto* map = args == nullptr
                        ? nullptr
                        : std::get_if<flutter::EncodableMap>(args);
  if (map == nullptr) {
    return nullptr;
  }
  const auto found = map->find(flutter::EncodableValue(key));
  return found == map->end() ? nullptr : &found->second;
}

bool ReadString(const flutter::EncodableValue* args, const char* key,
                  size_t limit, std::string* output) {
  const auto* value = Argument(args, key);
  const auto* string =
      value == nullptr ? nullptr : std::get_if<std::string>(value);
  if (string == nullptr || string->empty() || string->size() > limit) {
    return false;
  }
  *output = *string;
  return true;
}

}  // namespace

DesktopRfidSerialChannel::DesktopRfidSerialChannel(
    flutter::BinaryMessenger* messenger, HWND window,
    std::unique_ptr<sohun::rfid::SerialBackend> backend)
    : channel_(
          std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
              messenger, "top.sohun/desktop_rfid_serial",
              &flutter::StandardMethodCodec::GetInstance())),
      transport_(std::make_unique<sohun::rfid::AsyncSerialTransport>(
          [window]() {
            // No pointers/results cross the thread boundary. A late window
            // message is harmless after teardown: there is no payload to free.
            PostMessageW(window, kCompletionMessage, 0, 0);
          },
          std::move(backend))) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

DesktopRfidSerialChannel::~DesktopRfidSerialChannel() {
  channel_->SetMethodCallHandler(nullptr);
  transport_->Shutdown();
  // MethodResult and BinaryMessenger are only touched on the Flutter thread,
  // while its engine is still alive. Worker teardown owns no Flutter state.
  for (auto& pending : pending_results_) {
    pending.second->Error("disconnected", "The serial window was closed");
  }
  pending_results_.clear();
}

void DesktopRfidSerialChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<Result> result) {
  using namespace sohun::rfid;
  SerialRequest request;
  const auto& method = call.method_name();
  if (method == "listPorts") {
    request.operation = SerialOperation::kListPorts;
  } else if (method == "open") {
    request.operation = SerialOperation::kOpen;
    if (!ReadString(call.arguments(), "port", 8, &request.port) ||
        !IsValidSerialPortName(request.port)) {
      result->Error("invalid_arguments", "Expected COM1 through COM65535");
      return;
    }
  } else if (method == "read" || method == "write" || method == "close") {
    request.operation = method == "read"    ? SerialOperation::kRead
                        : method == "write" ? SerialOperation::kWrite
                                             : SerialOperation::kClose;
    if (!ReadString(call.arguments(), "connectionId", 128,
                     &request.connection_id)) {
      result->Error("invalid_arguments", "Expected a serial connectionId");
      return;
    }
    if (method == "write") {
      const auto* value = Argument(call.arguments(), "bytes");
      const auto* bytes = value == nullptr
                              ? nullptr
                              : std::get_if<std::vector<uint8_t>>(value);
      if (bytes == nullptr || bytes->size() > kMaxSerialTransfer) {
        result->Error("invalid_arguments", "Expected at most 8192 bytes");
        return;
      }
      request.bytes = *bytes;
    }
  } else {
    result->NotImplemented();
    return;
  }
  if (pending_results_.size() >= kMaxPendingSerialRequests) {
    result->Error("busy", "Too many pending serial requests");
    return;
  }
  const auto id = ++next_request_id_;
  request.request_id = id;
  pending_results_.emplace(id, std::move(result));
  if (!transport_->Submit(std::move(request))) {
    const auto pending = pending_results_.find(id);
    pending->second->Error("busy", "Serial transport cannot accept a request");
    pending_results_.erase(pending);
  }
}

void DesktopRfidSerialChannel::DrainResponses() {
  using flutter::EncodableValue;
  using sohun::rfid::SerialOperation;
  for (auto& response : transport_->TakeResponses()) {
    const auto found = pending_results_.find(response.request_id);
    if (found == pending_results_.end()) {
      continue;
    }
    auto result = std::move(found->second);
    pending_results_.erase(found);
    if (!response.error.ok()) {
      result->Error(response.error.code, response.error.message,
                     EncodableValue(static_cast<int64_t>(
                         response.error.windows_error)));
      continue;
    }
    switch (response.operation) {
      case SerialOperation::kListPorts: {
        flutter::EncodableList ports;
        for (const auto& port : response.ports) {
          flutter::EncodableMap item{
              {EncodableValue("port"), EncodableValue(port.port)},
              {EncodableValue("label"), EncodableValue(port.label)}};
          if (!port.hardware_id.empty()) {
            item.emplace(EncodableValue("hardwareId"),
                          EncodableValue(port.hardware_id));
          }
          ports.emplace_back(std::move(item));
        }
        result->Success(EncodableValue(std::move(ports)));
        break;
      }
      case SerialOperation::kOpen:
        result->Success(EncodableValue(flutter::EncodableMap{
            {EncodableValue("connectionId"),
             EncodableValue(response.connection_id)}}));
        break;
      case SerialOperation::kRead:
        result->Success(EncodableValue(std::move(response.bytes)));
        break;
      case SerialOperation::kWrite:
      case SerialOperation::kClose:
        result->Success();
        break;
    }
  }
}
