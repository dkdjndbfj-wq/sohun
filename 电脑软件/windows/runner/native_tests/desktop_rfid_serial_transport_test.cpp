#include "desktop_rfid_serial_transport.h"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <thread>

using namespace sohun::rfid;

namespace {

int checks = 0;

void Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAILED: " << message << '\n';
    std::exit(1);
  }
  ++checks;
}

struct FakeState {
  int opens = 0;
  int reads = 0;
  int writes = 0;
  int closes = 0;
  SerialError open_error;
  SerialError read_error;
  SerialError write_error;
  std::vector<uint8_t> incoming{0, 1, 127, 128, 255};
  std::vector<uint8_t> written;
};

class FakeBackend final : public SerialBackend {
 public:
  explicit FakeBackend(std::shared_ptr<FakeState> state)
      : state_(std::move(state)) {}
  SerialError ListPorts(std::vector<SerialPortInfo>* ports) override {
    *ports = {{"COM5", "USB-SERIAL CH340 (COM5)",
               "USB\\VID_1A86&PID_7523&REV_0264"}};
    return {};
  }
  SerialError Open(const std::string&, HANDLE) override {
    ++state_->opens;
    return state_->open_error;
  }
  SerialError Read(std::vector<uint8_t>* bytes, HANDLE) override {
    ++state_->reads;
    *bytes = state_->incoming;
    return state_->read_error;
  }
  SerialError Write(const std::vector<uint8_t>& bytes, HANDLE) override {
    ++state_->writes;
    state_->written = bytes;
    return state_->write_error;
  }
  void Close() override { ++state_->closes; }

 private:
  std::shared_ptr<FakeState> state_;
};

SerialRequest Request(SerialOperation operation,
                      const std::string& connection = "") {
  SerialRequest request;
  request.request_id = 101;
  request.operation = operation;
  request.connection_id = connection;
  request.port = "COM5";
  return request;
}

void TestPortNames() {
  for (const char* port : {"COM1", "COM9", "COM10", "COM256", "COM65535"}) {
    Expect(IsValidSerialPortName(port), "canonical port accepted");
  }
  for (const char* port : {"", "COM0", "COM01", "com5", " COM5", "COM5 ",
                           "COM65536", "COM9999999999", "COM-1", "COM1:",
                           "COM1/..", "\\\\.\\COM5", "C:\\file", "NUL",
                           "LPT1", "COM5\n", "COM5\x7f"}) {
    Expect(!IsValidSerialPortName(port), "noncanonical or path input rejected");
  }
  Expect(!IsValidSerialPortName(std::string("COM5\0file", 9)),
         "embedded NUL rejected");
}

void TestSession() {
  auto state = std::make_shared<FakeState>();
  SerialSession session(std::make_unique<FakeBackend>(state));
  auto listed = session.Execute(Request(SerialOperation::kListPorts), nullptr);
  Expect(listed.error.ok() && listed.ports.size() == 1,
         "enumeration returns ports without opening");
  Expect(state->opens == 0 && listed.ports[0].hardware_id.find("1A86") !=
                                  std::string::npos,
         "enumeration preserves the candidate hardware ID");
  auto invalid = Request(SerialOperation::kOpen);
  invalid.port = "\\\\.\\C:\\private";
  Expect(session.Execute(invalid, nullptr).error.code == "invalid_arguments" &&
             state->opens == 0,
         "path rejected before backend open");
  Expect(session.Execute(Request(SerialOperation::kRead), nullptr).error.code ==
             "stale_connection",
         "read before open rejected");

  auto opened = session.Execute(Request(SerialOperation::kOpen), nullptr);
  const auto first = opened.connection_id;
  Expect(opened.error.ok() && !first.empty() && state->opens == 1,
         "successful open provides a connection generation");
  Expect(opened.request_id == 101 && opened.operation == SerialOperation::kOpen,
         "request identity preserved");
  Expect(session.Execute(Request(SerialOperation::kOpen), nullptr).error.code ==
                 "busy" &&
             state->opens == 1,
         "second open cannot replace live connection");

  auto read = session.Execute(Request(SerialOperation::kRead, first), nullptr);
  Expect(read.error.ok() && read.bytes == state->incoming,
         "binary input preserved including zero and high bytes");
  auto write = Request(SerialOperation::kWrite, first);
  write.bytes.assign(kMaxSerialTransfer, 0xab);
  Expect(session.Execute(write, nullptr).error.ok() &&
             state->written == write.bytes,
         "8192 byte boundary writes fully");
  const int writes = state->writes;
  write.bytes.push_back(0xcd);
  Expect(session.Execute(write, nullptr).error.code == "invalid_arguments" &&
             state->writes == writes,
         "oversized write never reaches backend");
  Expect(session.Execute(Request(SerialOperation::kRead, first), nullptr)
             .error.ok(),
         "argument error does not destroy current connection");

  Expect(session.Execute(Request(SerialOperation::kClose, "wrong"), nullptr)
                 .error.code == "stale_connection" &&
             state->closes == 0,
         "incorrect generation cannot close a live connection");
  Expect(session.Execute(Request(SerialOperation::kClose, first), nullptr)
             .error.ok(),
         "matching generation closes");
  auto second_open = session.Execute(Request(SerialOperation::kOpen), nullptr);
  const auto second = second_open.connection_id;
  Expect(second_open.error.ok() && second != first,
         "reconnect always gets a different generation");
  const int closes = state->closes;
  for (auto operation : {SerialOperation::kRead, SerialOperation::kWrite,
                          SerialOperation::kClose}) {
    Expect(session.Execute(Request(operation, first), nullptr).error.code ==
               "stale_connection",
           "late command from previous connection rejected");
  }
  Expect(state->closes == closes &&
             session.Execute(Request(SerialOperation::kRead, second), nullptr)
                 .error.ok(),
         "late close left new connection intact");

  state->read_error = {"disconnected", "Fake unplug", ERROR_DEVICE_NOT_CONNECTED};
  read = session.Execute(Request(SerialOperation::kRead, second), nullptr);
  Expect(read.error.code == "disconnected" && read.bytes.empty() &&
             state->closes == closes + 1,
         "unplug closes current connection and hides partial bytes");
  Expect(session.Execute(Request(SerialOperation::kWrite, second), nullptr)
             .error.code == "stale_connection",
         "cannot write on an unplugged connection");
  state->read_error = {};
  const auto third =
      session.Execute(Request(SerialOperation::kOpen), nullptr).connection_id;
  state->write_error = {"serial_timeout", "Fake partial write", WAIT_TIMEOUT};
  write = Request(SerialOperation::kWrite, third);
  write.bytes = {1, 2, 3};
  Expect(session.Execute(write, nullptr).error.code == "serial_timeout",
         "write timeout is not reported as success");
  Expect(session.Execute(Request(SerialOperation::kRead, third), nullptr)
             .error.code == "stale_connection",
         "uncertain write invalidates stream instead of silently retrying");

  state->write_error = {};
  state->open_error = {"port_busy", "Fake occupied port", ERROR_ACCESS_DENIED};
  Expect(session.Execute(Request(SerialOperation::kOpen), nullptr).error.code ==
             "port_busy",
         "occupied port failure preserved");
  state->open_error = {};
  const auto fourth =
      session.Execute(Request(SerialOperation::kOpen), nullptr).connection_id;
  state->incoming.assign(kMaxSerialTransfer + 1, 0);
  read = session.Execute(Request(SerialOperation::kRead, fourth), nullptr);
  Expect(read.error.code == "serial_io_error" && read.bytes.empty(),
         "backend overrun cannot escape the maximum receive bound");
}

struct Gate {
  Gate()
      : entered(CreateEventW(nullptr, TRUE, FALSE, nullptr)),
        release(CreateEventW(nullptr, TRUE, FALSE, nullptr)),
        ready(CreateEventW(nullptr, FALSE, FALSE, nullptr)),
        destroyed(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
  ~Gate() {
    CloseHandle(entered);
    CloseHandle(release);
    CloseHandle(ready);
    CloseHandle(destroyed);
  }
  HANDLE entered;
  HANDLE release;
  HANDLE ready;
  HANDLE destroyed;
  std::atomic<int> calls{0};
  std::atomic<int> notifications{0};
};

class BlockingBackend final : public SerialBackend {
 public:
  explicit BlockingBackend(std::shared_ptr<Gate> gate) : gate_(std::move(gate)) {}
  ~BlockingBackend() override { SetEvent(gate_->destroyed); }
  SerialError ListPorts(std::vector<SerialPortInfo>* ports) override {
    ++gate_->calls;
    SetEvent(gate_->entered);
    WaitForSingleObject(gate_->release, 10000);
    ports->clear();
    return {};
  }
  SerialError Open(const std::string&, HANDLE) override { return {}; }
  SerialError Read(std::vector<uint8_t>* bytes, HANDLE) override {
    bytes->clear();
    return {};
  }
  SerialError Write(const std::vector<uint8_t>&, HANDLE) override { return {}; }
  void Close() override {}

 private:
  std::shared_ptr<Gate> gate_;
};

void TestQueueBounds() {
  auto gate = std::make_shared<Gate>();
  auto transport = std::make_unique<AsyncSerialTransport>(
      [gate]() { SetEvent(gate->ready); },
      std::make_unique<BlockingBackend>(gate));
  for (size_t i = 0; i < kMaxPendingSerialRequests; ++i) {
    auto request = Request(SerialOperation::kListPorts);
    request.request_id = i + 1;
    Expect(transport->Submit(std::move(request)), "bounded request accepted");
  }
  Expect(WaitForSingleObject(gate->entered, 2000) == WAIT_OBJECT_0,
         "worker actually started blocked backend operation");
  Expect(!transport->Submit(Request(SerialOperation::kListPorts)),
         "33rd request rejected while worker is blocked");
  SetEvent(gate->release);
  std::vector<SerialResponse> responses;
  const auto deadline = GetTickCount64() + 5000;
  while (responses.size() < kMaxPendingSerialRequests &&
         GetTickCount64() < deadline) {
    WaitForSingleObject(gate->ready, 100);
    auto arrived = transport->TakeResponses();
    for (auto& response : arrived) {
      responses.push_back(std::move(response));
    }
  }
  Expect(responses.size() == kMaxPendingSerialRequests,
         "all accepted requests complete exactly once");
  for (size_t i = 0; i < responses.size(); ++i) {
    Expect(responses[i].request_id == i + 1 && responses[i].error.ok(),
           "single worker preserves request order");
  }
  auto oversized = Request(SerialOperation::kWrite);
  oversized.bytes.assign(kMaxSerialTransfer + 1, 0);
  Expect(!transport->Submit(std::move(oversized)),
         "oversized payload cannot enter asynchronous queue");
  Expect(transport->Submit(Request(SerialOperation::kListPorts)),
         "draining results frees bounded queue capacity");
  transport.reset();
  Expect(WaitForSingleObject(gate->destroyed, 2000) == WAIT_OBJECT_0,
         "worker backend cleaned up after shutdown");
}

void TestNonBlockingTeardown() {
  auto gate = std::make_shared<Gate>();
  auto transport = std::make_unique<AsyncSerialTransport>(
      [gate]() { ++gate->notifications; },
      std::make_unique<BlockingBackend>(gate));
  Expect(transport->Submit(Request(SerialOperation::kListPorts)),
         "slow driver request submitted without blocking caller");
  Expect(WaitForSingleObject(gate->entered, 2000) == WAIT_OBJECT_0,
         "fake slow driver is active");
  Expect(transport->Submit(Request(SerialOperation::kListPorts)),
         "second request queued behind slow driver");
  const auto started = GetTickCount64();
  transport->Shutdown();
  Expect(!transport->Submit(Request(SerialOperation::kListPorts)),
         "shutdown rejects new requests");
  Expect(transport->TakeResponses().empty(), "shutdown discards results");
  transport.reset();
  Expect(GetTickCount64() - started < 500,
         "destruction does not wait for a blocked third-party driver");
  SetEvent(gate->release);
  Expect(WaitForSingleObject(gate->destroyed, 2000) == WAIT_OBJECT_0,
         "late driver completion safely releases worker state");
  Expect(gate->calls == 1 && gate->notifications == 0,
         "queued work and callbacks cannot survive window shutdown");
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 2 && std::string(argv[1]) == "--list-ports") {
    // Optional metadata-only smoke check: never Open/Read/Write a real port.
    auto backend = MakeWin32SerialBackend();
    std::vector<SerialPortInfo> ports;
    const auto error = backend->ListPorts(&ports);
    if (!error.ok()) {
      std::cerr << error.code << " Windows=" << error.windows_error << '\n';
      return 1;
    }
    for (const auto& port : ports) {
      std::cout << port.port << " | " << port.label << " | "
                << port.hardware_id << '\n';
    }
    std::cout << "Present COM ports: " << ports.size()
              << "; none opened or reset.\n";
    return 0;
  }
  TestPortNames();
  TestSession();
  TestQueueBounds();
  TestNonBlockingTeardown();
  std::cout << "Desktop RFID native transport: " << checks
            << " checks passed; all I/O used fake backends.\n";
  return 0;
}
