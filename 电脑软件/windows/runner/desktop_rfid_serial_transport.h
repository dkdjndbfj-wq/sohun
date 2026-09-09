#ifndef RUNNER_DESKTOP_RFID_SERIAL_TRANSPORT_H_
#define RUNNER_DESKTOP_RFID_SERIAL_TRANSPORT_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace sohun::rfid {

constexpr size_t kMaxSerialTransfer = 8192;
constexpr size_t kMaxPendingSerialRequests = 32;

// Only canonical COM names are accepted. No caller-controlled device paths.
bool IsValidSerialPortName(const std::string& port);

struct SerialPortInfo {
  std::string port;
  std::string label;
  std::string hardware_id;
};

struct SerialError {
  std::string code;
  std::string message;
  uint32_t windows_error = 0;
  bool ok() const { return code.empty(); }
};

enum class SerialOperation { kListPorts, kOpen, kRead, kWrite, kClose };

struct SerialRequest {
  uint64_t request_id = 0;
  SerialOperation operation = SerialOperation::kListPorts;
  std::string port;
  std::string connection_id;
  std::vector<uint8_t> bytes;
};

struct SerialResponse {
  uint64_t request_id = 0;
  SerialOperation operation = SerialOperation::kListPorts;
  SerialError error;
  std::vector<SerialPortInfo> ports;
  std::string connection_id;
  std::vector<uint8_t> bytes;
};

// This boundary is injectable for hardware-free lifecycle/queue tests. A
// backend is accessed only by one worker; it never calls Flutter or logs data.
class SerialBackend {
 public:
  virtual ~SerialBackend() = default;
  virtual SerialError ListPorts(std::vector<SerialPortInfo>* ports) = 0;
  virtual SerialError Open(const std::string& port, HANDLE stop_event) = 0;
  virtual SerialError Read(std::vector<uint8_t>* bytes,
                           HANDLE stop_event) = 0;
  virtual SerialError Write(const std::vector<uint8_t>& bytes,
                            HANDLE stop_event) = 0;
  virtual void Close() = 0;
};

std::unique_ptr<SerialBackend> MakeWin32SerialBackend();

class SerialSession {
 public:
  explicit SerialSession(std::unique_ptr<SerialBackend> backend);
  ~SerialSession();
  SerialResponse Execute(const SerialRequest& request, HANDLE stop_event);
  void Close();

 private:
  std::unique_ptr<SerialBackend> backend_;
  std::string connection_id_;
};

// Requests and completions are bounded. No serial API executes on the caller's
// thread. Wakeup must be nonblocking and must not capture a Flutter object.
class AsyncSerialTransport {
 public:
  explicit AsyncSerialTransport(
      std::function<void()> wakeup,
      std::unique_ptr<SerialBackend> backend = MakeWin32SerialBackend());
  ~AsyncSerialTransport();
  AsyncSerialTransport(const AsyncSerialTransport&) = delete;
  AsyncSerialTransport& operator=(const AsyncSerialTransport&) = delete;

  bool Submit(SerialRequest request);
  std::vector<SerialResponse> TakeResponses();
  void Shutdown();

 private:
  struct State;
  std::shared_ptr<State> state_;
};

}  // namespace sohun::rfid

#endif  // RUNNER_DESKTOP_RFID_SERIAL_TRANSPORT_H_
