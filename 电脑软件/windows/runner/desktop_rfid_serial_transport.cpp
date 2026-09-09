#include "desktop_rfid_serial_transport.h"

#include <setupapi.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <utility>

namespace sohun::rfid {
namespace {

std::atomic<uint64_t> g_connection_sequence{0};

SerialError Error(const char* code, const char* message, DWORD error = 0) {
  return {code, message, error};
}

class OwnedHandle {
 public:
  explicit OwnedHandle(HANDLE handle = INVALID_HANDLE_VALUE)
      : handle_(handle) {}
  ~OwnedHandle() { Reset(); }
  OwnedHandle(const OwnedHandle&) = delete;
  OwnedHandle& operator=(const OwnedHandle&) = delete;
  HANDLE get() const { return handle_; }
  bool valid() const {
    return handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE;
  }
  void Reset(HANDLE handle = INVALID_HANDLE_VALUE) {
    if (valid()) {
      CloseHandle(handle_);
    }
    handle_ = handle;
  }

 private:
  HANDLE handle_;
};

std::string Utf8(const wchar_t* value) {
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1,
                                      nullptr, 0, nullptr, nullptr);
  if (size <= 1) {
    return {};
  }
  std::string output(static_cast<size_t>(size), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1,
                          output.data(), size, nullptr, nullptr) == 0) {
    return {};
  }
  output.resize(static_cast<size_t>(size) - 1);
  return output;
}

std::string DeviceProperty(HDEVINFO devices, SP_DEVINFO_DATA* device,
                            DWORD property) {
  std::array<wchar_t, 2048> data{};
  DWORD type = 0;
  if (!SetupDiGetDeviceRegistryPropertyW(
          devices, device, property, &type,
          reinterpret_cast<BYTE*>(data.data()),
          static_cast<DWORD>(sizeof(data) - sizeof(wchar_t)), nullptr) ||
      (type != REG_SZ && type != REG_MULTI_SZ)) {
    return {};
  }
  // Hardware IDs are MULTI_SZ; only the first (most specific) ID is needed.
  return Utf8(data.data());
}

// PnP enumeration does not open a COM handle, toggle control lines or reset
// the ESP32. VID/PID is a candidate hint, never brand or firmware identity.
SerialError EnumeratePorts(std::vector<SerialPortInfo>* ports) {
  ports->clear();
  // GUID_DEVCLASS_PORTS, defined by the Windows device setup class contract.
  constexpr GUID kPortsClass = {0x4d36e978, 0xe325, 0x11ce,
                                 {0xbf, 0xc1, 0x08, 0x00,
                                  0x2b, 0xe1, 0x03, 0x18}};
  const HDEVINFO devices =
      SetupDiGetClassDevsW(&kPortsClass, nullptr, nullptr, DIGCF_PRESENT);
  if (devices == INVALID_HANDLE_VALUE) {
    return Error("serial_unavailable", "Windows serial enumeration failed",
                 GetLastError());
  }

  SerialError error;
  for (DWORD index = 0; index < 65536; ++index) {
    SP_DEVINFO_DATA device{};
    device.cbSize = sizeof(device);
    if (!SetupDiEnumDeviceInfo(devices, index, &device)) {
      const DWORD failure = GetLastError();
      if (failure != ERROR_NO_MORE_ITEMS) {
        error = Error("serial_unavailable", "Windows serial enumeration failed",
                       failure);
      }
      break;
    }
    const HKEY key = SetupDiOpenDevRegKey(
        devices, &device, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_QUERY_VALUE);
    if (key == INVALID_HANDLE_VALUE) {
      continue;
    }
    std::array<wchar_t, 32> value_data{};
    DWORD data_size = static_cast<DWORD>(sizeof(value_data));
    DWORD type = 0;
    const LSTATUS status = RegQueryValueExW(
        key, L"PortName", nullptr, &type,
        reinterpret_cast<BYTE*>(value_data.data()), &data_size);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS) {
      continue;
    }
    if (type != REG_SZ || data_size < sizeof(wchar_t) ||
        data_size % sizeof(wchar_t) != 0) {
      continue;
    }
    // Do not assume registry strings are correctly NUL-terminated.
    const size_t length = data_size / sizeof(wchar_t);
    if (length > value_data.size() || value_data[length - 1] != L'\0') {
      continue;
    }
    std::string port;
    for (size_t i = 0; i + 1 < length; ++i) {
      const auto character = value_data[i];
      if (character > 127 || character == L'\0') {
        port.clear();
        break;
      }
      port.push_back(static_cast<char>(character));
    }
    if (!IsValidSerialPortName(port)) {
      continue;
    }
    std::array<wchar_t, 1024> mapping{};
    if (QueryDosDeviceW(value_data.data(), mapping.data(),
                        static_cast<DWORD>(mapping.size())) == 0 ||
        std::wstring(mapping.data()).rfind(L"\\Device\\", 0) != 0) {
      continue;
    }
    auto label = DeviceProperty(devices, &device, SPDRP_FRIENDLYNAME);
    if (label.empty()) {
      label = DeviceProperty(devices, &device, SPDRP_DEVICEDESC);
    }
    ports->push_back({port, label.empty() ? port : std::move(label),
                      DeviceProperty(devices, &device, SPDRP_HARDWAREID)});
  }
  SetupDiDestroyDeviceInfoList(devices);
  if (!error.ok()) {
    ports->clear();
    return error;
  }
  std::sort(ports->begin(), ports->end(), [](const auto& a, const auto& b) {
    if (a.port.size() != b.port.size()) {
      return a.port.size() < b.port.size();
    }
    return a.port < b.port;
  });
  ports->erase(std::unique(ports->begin(), ports->end(),
                           [](const auto& a, const auto& b) {
                             return a.port == b.port;
                           }),
               ports->end());
  return {};
}

class Win32SerialBackend final : public SerialBackend {
 public:
  SerialError ListPorts(std::vector<SerialPortInfo>* ports) override {
    return EnumeratePorts(ports);
  }

  SerialError Open(const std::string& port, HANDLE stop_event) override {
    if (!IsValidSerialPortName(port)) {
      return Error("invalid_arguments", "Expected a canonical COM port name");
    }
    if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0) {
      return Error("disconnected", "Serial transport is shutting down");
    }
    std::vector<SerialPortInfo> ports;
    auto error = EnumeratePorts(&ports);
    if (!error.ok()) {
      return error;
    }
    if (std::none_of(ports.begin(), ports.end(), [&port](const auto& item) {
          return item.port == port;
        })) {
      return Error("disconnected", "The selected COM port is no longer present");
    }
    const std::wstring path = L"\\\\.\\" + std::wstring(port.begin(), port.end());
    port_.Reset(CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                            nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED,
                            nullptr));
    if (!port_.valid()) {
      const DWORD failure = GetLastError();
      return Error(failure == ERROR_ACCESS_DENIED ||
                            failure == ERROR_SHARING_VIOLATION
                        ? "port_busy"
                        : "disconnected",
                   "Cannot open the selected COM port", failure);
    }

    DCB config{};
    config.DCBlength = sizeof(config);
    if (!GetCommState(port_.get(), &config)) {
      return ConfigurationFailed();
    }
    config.BaudRate = CBR_115200;
    config.ByteSize = 8;
    config.Parity = NOPARITY;
    config.StopBits = ONESTOPBIT;
    config.fBinary = TRUE;
    config.fParity = FALSE;
    config.fOutxCtsFlow = FALSE;
    config.fOutxDsrFlow = FALSE;
    config.fDtrControl = DTR_CONTROL_DISABLE;
    config.fDsrSensitivity = FALSE;
    config.fTXContinueOnXoff = TRUE;
    config.fOutX = FALSE;
    config.fInX = FALSE;
    config.fErrorChar = FALSE;
    config.fNull = FALSE;
    config.fRtsControl = RTS_CONTROL_DISABLE;
    config.fAbortOnError = FALSE;
    if (!SetCommState(port_.get(), &config)) {
      return ConfigurationFailed();
    }
    COMMTIMEOUTS timeouts{};
    // MAXDWORD + zero read totals returns only already-buffered bytes.
    timeouts.ReadIntervalTimeout = MAXDWORD;
    timeouts.WriteTotalTimeoutConstant = 1500;
    if (!SetCommTimeouts(port_.get(), &timeouts) ||
        !PurgeComm(port_.get(), PURGE_RXCLEAR)) {
      return ConfigurationFailed();
    }
    // Deliberately no EscapeCommFunction, reset sequence, bootloader command,
    // auto-upload or firmware flash. Some board/driver designs may still
    // reset on opening; the Dart protocol must complete a fresh handshake.
    return {};
  }

  SerialError Read(std::vector<uint8_t>* bytes, HANDLE stop_event) override {
    bytes->clear();
    COMSTAT status{};
    auto error = CheckStatus(&status);
    if (!error.ok() || status.cbInQue == 0) {
      return error;
    }
    bytes->resize(std::min(static_cast<size_t>(status.cbInQue),
                            kMaxSerialTransfer));
    DWORD transferred = 0;
    error = Transfer(false, bytes->data(), static_cast<DWORD>(bytes->size()),
                      stop_event, &transferred);
    if (error.ok()) {
      bytes->resize(transferred);
    } else {
      bytes->clear();
    }
    return error;
  }

  SerialError Write(const std::vector<uint8_t>& bytes,
                     HANDLE stop_event) override {
    COMSTAT status{};
    auto error = CheckStatus(&status);
    if (!error.ok() || bytes.empty()) {
      return error;
    }
    DWORD transferred = 0;
    error = Transfer(true, const_cast<uint8_t*>(bytes.data()),
                      static_cast<DWORD>(bytes.size()), stop_event,
                      &transferred);
    if (error.ok() && transferred != bytes.size()) {
      return Error("serial_timeout",
                   "Serial write was incomplete; reconnect before retrying");
    }
    return error;
  }

  void Close() override { port_.Reset(); }

 private:
  SerialError ConfigurationFailed() {
    const DWORD failure = GetLastError();
    Close();
    return Error("serial_configuration_failed",
                 "Cannot configure the COM port for 115200 8N1", failure);
  }

  SerialError CheckStatus(COMSTAT* status) {
    DWORD flags = 0;
    if (!port_.valid() || !ClearCommError(port_.get(), &flags, status)) {
      return Error("disconnected", "The serial device was disconnected",
                   GetLastError());
    }
    if (flags != 0) {
      return Error("serial_io_error",
                   "Serial data was lost or corrupted; reconnect the device",
                   flags);
    }
    return {};
  }

  SerialError Transfer(bool writing, uint8_t* buffer, DWORD size,
                        HANDLE stop_event, DWORD* transferred) {
    OwnedHandle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!event.valid()) {
      return Error("serial_io_error", "Cannot allocate a serial I/O event",
                   GetLastError());
    }
    OVERLAPPED operation{};
    operation.hEvent = event.get();
    const BOOL completed = writing
                               ? WriteFile(port_.get(), buffer, size,
                                            transferred, &operation)
                               : ReadFile(port_.get(), buffer, size,
                                           transferred, &operation);
    if (completed) {
      return {};
    }
    DWORD failure = GetLastError();
    if (failure != ERROR_IO_PENDING) {
      return Error("disconnected", "Serial I/O failed", failure);
    }
    HANDLE events[] = {event.get(), stop_event};
    const DWORD wait = WaitForMultipleObjects(2, events, FALSE,
                                               writing ? 2000 : 250);
    if (wait == WAIT_OBJECT_0) {
      if (GetOverlappedResult(port_.get(), &operation, transferred, FALSE)) {
        return {};
      }
      return Error("disconnected", "Serial I/O failed", GetLastError());
    }
    failure = wait == WAIT_FAILED ? GetLastError() : ERROR_OPERATION_ABORTED;
    CancelIoEx(port_.get(), &operation);
    // CancelIoEx only requests cancellation. Preserve OVERLAPPED and buffer
    // until the driver actually completes it. A faulty driver may delay this
    // wait; it is confined to a self-owned worker, never the Flutter thread.
    GetOverlappedResult(port_.get(), &operation, transferred, TRUE);
    if (wait == WAIT_TIMEOUT) {
      return Error("serial_timeout",
                   "Serial I/O timed out; reconnect before retrying",
                   WAIT_TIMEOUT);
    }
    return Error("disconnected", "Serial I/O was cancelled", failure);
  }

  OwnedHandle port_;
};

}  // namespace

bool IsValidSerialPortName(const std::string& port) {
  if (port.size() < 4 || port.size() > 8 || port.compare(0, 3, "COM") != 0 ||
      port[3] < '1' || port[3] > '9') {
    return false;
  }
  uint32_t number = 0;
  for (size_t i = 3; i < port.size(); ++i) {
    if (port[i] < '0' || port[i] > '9') {
      return false;
    }
    number = number * 10 + static_cast<uint32_t>(port[i] - '0');
  }
  return number <= 65535;
}

std::unique_ptr<SerialBackend> MakeWin32SerialBackend() {
  return std::make_unique<Win32SerialBackend>();
}

SerialSession::SerialSession(std::unique_ptr<SerialBackend> backend)
    : backend_(std::move(backend)) {}

SerialSession::~SerialSession() { Close(); }

void SerialSession::Close() {
  backend_->Close();
  connection_id_.clear();
}

SerialResponse SerialSession::Execute(const SerialRequest& request,
                                       HANDLE stop_event) {
  SerialResponse response;
  response.request_id = request.request_id;
  response.operation = request.operation;
  if (request.operation == SerialOperation::kListPorts) {
    response.error = backend_->ListPorts(&response.ports);
    return response;
  }
  if (request.operation == SerialOperation::kOpen) {
    if (!IsValidSerialPortName(request.port)) {
      response.error = Error("invalid_arguments", "Invalid COM port name");
    } else if (!connection_id_.empty()) {
      response.error = Error("busy", "Close the current serial connection first");
    } else {
      response.error = backend_->Open(request.port, stop_event);
      if (response.error.ok()) {
        connection_id_ = "rfid-" + std::to_string(++g_connection_sequence);
        response.connection_id = connection_id_;
      } else {
        backend_->Close();
      }
    }
    return response;
  }
  if (connection_id_.empty() || request.connection_id != connection_id_) {
    response.error = Error("stale_connection",
                           "This serial connection is no longer active");
    return response;
  }
  switch (request.operation) {
    case SerialOperation::kRead:
      response.error = backend_->Read(&response.bytes, stop_event);
      if (response.error.ok() && response.bytes.size() > kMaxSerialTransfer) {
        response.error = Error("serial_io_error", "Serial receive limit exceeded");
      }
      break;
    case SerialOperation::kWrite:
      if (request.bytes.size() > kMaxSerialTransfer) {
        response.error = Error("invalid_arguments", "Serial write limit exceeded");
        return response;
      }
      response.error = backend_->Write(request.bytes, stop_event);
      break;
    case SerialOperation::kClose:
      Close();
      break;
    default:
      response.error = Error("invalid_arguments", "Unknown serial operation");
      return response;
  }
  if (!response.error.ok()) {
    response.bytes.clear();
    // Never continue a byte stream after a partial/uncertain I/O operation.
    Close();
  }
  return response;
}

struct AsyncSerialTransport::State {
  State(std::function<void()> signal, std::unique_ptr<SerialBackend> backend)
      : wakeup(std::move(signal)),
        stop_event(CreateEventW(nullptr, TRUE, FALSE, nullptr)),
        session(std::move(backend)) {}

  std::mutex mutex;
  std::condition_variable available;
  std::deque<SerialRequest> requests;
  std::vector<SerialResponse> responses;
  std::function<void()> wakeup;
  OwnedHandle stop_event;
  SerialSession session;
  size_t pending = 0;
  bool stopped = false;
};

AsyncSerialTransport::AsyncSerialTransport(
    std::function<void()> wakeup, std::unique_ptr<SerialBackend> backend)
    : state_(std::make_shared<State>(std::move(wakeup), std::move(backend))) {
  if (!state_->stop_event.valid()) {
    state_->stopped = true;
    return;
  }
  std::thread([state = state_]() {
    for (;;) {
      SerialRequest request;
      {
        std::unique_lock<std::mutex> lock(state->mutex);
        state->available.wait(lock, [&state]() {
          return state->stopped || !state->requests.empty();
        });
        if (state->stopped) {
          break;
        }
        request = std::move(state->requests.front());
        state->requests.pop_front();
      }
      auto response = state->session.Execute(request, state->stop_event.get());
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (!state->stopped) {
          state->responses.push_back(std::move(response));
          if (state->wakeup) {
            state->wakeup();
          }
        }
      }
    }
    state->session.Close();
  }).detach();
  // The worker owns State and its handles until all cancelled I/O completes.
  // No join on the UI thread: a wedged third-party driver cannot hang window
  // destruction, nor can a late callback access a destroyed Flutter engine.
}

AsyncSerialTransport::~AsyncSerialTransport() { Shutdown(); }

bool AsyncSerialTransport::Submit(SerialRequest request) {
  std::lock_guard<std::mutex> lock(state_->mutex);
  if (state_->stopped || state_->pending >= kMaxPendingSerialRequests ||
      request.bytes.size() > kMaxSerialTransfer) {
    return false;
  }
  ++state_->pending;
  state_->requests.push_back(std::move(request));
  state_->available.notify_one();
  return true;
}

std::vector<SerialResponse> AsyncSerialTransport::TakeResponses() {
  std::lock_guard<std::mutex> lock(state_->mutex);
  std::vector<SerialResponse> responses;
  responses.swap(state_->responses);
  state_->pending -= responses.size();
  return responses;
}

void AsyncSerialTransport::Shutdown() {
  std::lock_guard<std::mutex> lock(state_->mutex);
  if (state_->stopped) {
    return;
  }
  state_->stopped = true;
  state_->requests.clear();
  state_->responses.clear();
  state_->pending = 0;
  SetEvent(state_->stop_event.get());
  state_->available.notify_all();
}

}  // namespace sohun::rfid
