import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:consumable_tracker_desktop/core/utils/native_process_output.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeProcess process;
  setUp(() => process = _FakeProcess());
  tearDown(() => process.dispose());

  test('退出后晚到的输出必须排空，不能提前 cancel 丢失成功结果', () async {
    final result = collectNativeProcessOutput(
      process,
      timeout: const Duration(seconds: 1),
    );
    process.exit.complete(0);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    process.output.add(utf8.encode('ping_bind = 0\n成功\n'));
    process.errors.add(utf8.encode('last diagnostic'));
    await process.closePipes();
    final value = await result;
    expect(value.stdout, contains('成功'));
    expect(value.stderr, 'last diagnostic');
    expect(process.killCount, 0);
  });

  test('清理宽限不能缩短正常任务超时，PIN 仅写入 stdin', () async {
    final result = collectNativeProcessOutput(
      process,
      timeout: const Duration(seconds: 1),
      terminationGrace: const Duration(milliseconds: 5),
      inputLine: 'test-only-pin',
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    process.exit.complete(0);
    await process.closePipes();
    expect((await result).exitCode, 0);
    expect(utf8.decode(process.inputBytes), 'test-only-pin\n');
    expect(process.killCount, 0);
  });

  test('真正超时后才终止进程，清理等待有上限', () async {
    await expectLater(
      collectNativeProcessOutput(
        process,
        timeout: const Duration(milliseconds: 20),
        terminationGrace: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(process.killCount, 1);
  });

  test('退出但被继承的管道一直不关闭时也有界结束', () async {
    process.exit.complete(0);
    await expectLater(
      collectNativeProcessOutput(
        process,
        timeout: const Duration(seconds: 1),
        drainTimeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(process.killCount, 1);
  });

  test('输出有界保留尾部结果，非法 UTF-8 不再令结果解析失败', () async {
    final result = collectNativeProcessOutput(
      process,
      timeout: const Duration(seconds: 1),
      maxOutputBytes: 12,
    );
    process.output.add(List<int>.filled(1024, 65));
    process.output.add([255, ...utf8.encode('complete')]);
    process.errors.add([255]);
    process.exit.complete(3);
    await process.closePipes();
    final value = await result;
    expect(value.exitCode, 3);
    expect((value.stdout as String).length, lessThanOrEqualTo(12));
    expect(value.stdout, endsWith('complete'));
    expect(value.stderr, '\uFFFD');
  });
}

class _FakeProcess implements Process {
  _FakeProcess() {
    input.stream.listen(inputBytes.addAll);
    sink = IOSink(input.sink);
  }
  final exit = Completer<int>();
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final input = StreamController<List<int>>();
  final inputBytes = <int>[];
  late final IOSink sink;
  int killCount = 0;

  Future<void> closePipes() async {
    await output.close();
    await errors.close();
  }

  Future<void> dispose() async {
    if (!exit.isCompleted) exit.complete(-1);
    await closePipes();
  }

  @override
  int get pid => 123;
  @override
  Future<int> get exitCode => exit.future;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  IOSink get stdin => sink;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCount++;
    return true; // OS exit can remain pending even after a successful kill.
  }
}
