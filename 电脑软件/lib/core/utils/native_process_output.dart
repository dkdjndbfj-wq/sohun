import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// Waits for our own helper and drains both pipes before parsing its result.
/// The termination grace period starts only AFTER the operation times out.
Future<ProcessResult> collectNativeProcessOutput(
  Process process, {
  required Duration timeout,
  Duration terminationGrace = const Duration(seconds: 5),
  Duration drainTimeout = const Duration(seconds: 5),
  String? inputLine,
  int maxOutputBytes = 1024 * 1024,
}) async {
  final stdout = _OutputTail(maxOutputBytes);
  final stderr = _OutputTail(maxOutputBytes);
  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();
  Object? streamError;
  final stdoutSub = process.stdout.listen(
    stdout.add,
    onError: (Object error) => streamError ??= error,
    onDone: stdoutDone.complete,
  );
  final stderrSub = process.stderr.listen(
    stderr.add,
    onError: (Object error) => streamError ??= error,
    onDone: stderrDone.complete,
  );
  Future<void> stop() async {
    process.kill(ProcessSignal.sigkill);
    try {
      await process.exitCode.timeout(terminationGrace);
    } catch (_) {
      // OS cleanup must not hold the UI indefinitely.
    }
  }

  try {
    final exitCode = await (() async {
      if (inputLine != null) process.stdin.writeln(inputLine);
      await process.stdin.close();
      return process.exitCode;
    })().timeout(timeout);
    // exitCode can complete before the final stdout/stderr event is delivered.
    await Future.wait([
      stdoutDone.future,
      stderrDone.future,
    ]).timeout(drainTimeout);
    if (streamError != null) throw streamError!;
    return ProcessResult(process.pid, exitCode, stdout.text, stderr.text);
  } on TimeoutException {
    await stop();
    throw TimeoutException('原生组件执行或输出收集超时', timeout);
  } catch (_) {
    await stop();
    rethrow;
  } finally {
    await stdoutSub.cancel();
    await stderrSub.cancel();
  }
}

/// Retain the tail, where helpers report their final status; always drain the
/// remaining bytes so verbose vendor logging cannot block or exhaust the app.
class _OutputTail {
  _OutputTail(this.capacity) : assert(capacity > 0);
  final int capacity;
  final _chunks = Queue<List<int>>();
  int _length = 0;

  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    _chunks.add(List<int>.of(bytes));
    _length += bytes.length;
    while (_length > capacity) {
      final first = _chunks.removeFirst();
      final excess = _length - capacity;
      if (first.length <= excess) {
        _length -= first.length;
      } else {
        _chunks.addFirst(first.sublist(excess));
        _length -= excess;
      }
    }
  }

  String get text => utf8.decode(
    _chunks.expand((chunk) => chunk).toList(),
    allowMalformed: true,
  );
}
