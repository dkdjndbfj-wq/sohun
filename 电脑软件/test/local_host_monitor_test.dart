import 'dart:io';

import 'package:consumable_tracker_desktop/core/services/local_host_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('first sample reports memory but waits for a CPU interval', () {
    final monitor = LocalHostMonitor(
      readCounters: () => const HostSystemCounters(
        idleTicks: 100,
        kernelTicks: 200,
        userTicks: 100,
        memoryTotalBytes: 16000,
        memoryAvailableBytes: 6000,
      ),
    );
    final sample = monitor.sample();
    expect(sample.cpuPercent, isNull);
    expect(sample.cpuSampling, isTrue);
    expect(sample.memoryUsedBytes, 10000);
    expect(sample.memoryTotalBytes, 16000);
  });

  test('CPU uses interval deltas and includes kernel idle time only once', () {
    final samples = [
      const HostSystemCounters(
        idleTicks: 100,
        kernelTicks: 200,
        userTicks: 100,
      ),
      const HostSystemCounters(
        idleTicks: 180,
        kernelTicks: 300,
        userTicks: 200,
      ),
      const HostSystemCounters(
        idleTicks: 380,
        kernelTicks: 500,
        userTicks: 200,
      ),
    ].iterator;
    final monitor = LocalHostMonitor(
      readCounters: () {
        samples.moveNext();
        return samples.current;
      },
    );
    monitor.sample();
    expect(monitor.sample().cpuPercent, 60);
    expect(monitor.sample().cpuPercent, 0);
  });

  test(
    'failed reads clear the CPU baseline and recover without false zeros',
    () {
      var failed = false;
      final monitor = LocalHostMonitor(
        readCounters: () {
          if (failed) throw StateError('reader unavailable');
          return const HostSystemCounters(
            idleTicks: 100,
            kernelTicks: 200,
            userTicks: 100,
            memoryTotalBytes: 16000,
            memoryAvailableBytes: 6000,
          );
        },
      );
      monitor.sample();
      failed = true;
      final failure = monitor.sample();
      expect(failure.hasMetrics, isFalse);
      expect(failure.cpuPercent, isNull);
      expect(failure.cpuSampling, isFalse);
      expect(failure.unavailableReason, '本机资源暂不可用');
      failed = false;
      final recovered = monitor.sample();
      expect(recovered.cpuPercent, isNull);
      expect(recovered.cpuSampling, isTrue);
      expect(recovered.memoryUsedBytes, 10000);
    },
  );

  test(
    'invalid or regressing counters do not become believable percentages',
    () {
      final counters = [
        const HostSystemCounters(
          idleTicks: 100,
          kernelTicks: 200,
          userTicks: 100,
        ),
        const HostSystemCounters(
          idleTicks: 90,
          kernelTicks: 190,
          userTicks: 90,
        ),
        const HostSystemCounters(
          idleTicks: 90,
          kernelTicks: 190,
          userTicks: 90,
        ),
        const HostSystemCounters(
          idleTicks: 300,
          kernelTicks: 310,
          userTicks: 90,
        ),
      ].iterator;
      final monitor = LocalHostMonitor(
        readCounters: () {
          counters.moveNext();
          return counters.current;
        },
      );
      for (var index = 0; index < 4; index++) {
        expect(monitor.sample().cpuPercent, isNull);
      }
    },
  );

  test('invalid memory counters are omitted instead of clamped', () {
    for (final counters in [
      const HostSystemCounters(memoryTotalBytes: 0, memoryAvailableBytes: 0),
      const HostSystemCounters(memoryTotalBytes: 10, memoryAvailableBytes: 11),
      const HostSystemCounters(memoryTotalBytes: 10, memoryAvailableBytes: -1),
    ]) {
      final sample = LocalHostMonitor(readCounters: () => counters).sample();
      expect(sample.memoryUsedBytes, isNull);
      expect(sample.memoryTotalBytes, isNull);
      expect(sample.hasMetrics, isFalse);
    }
  });

  test('unsupported hosts return an explicit reason without reading a DLL', () {
    final sample = LocalHostMonitor(windows: false).sample();
    expect(sample.hasMetrics, isFalse);
    expect(sample.unavailableReason, '本机资源监测仅支持 Windows');
  });

  test(
    'Windows system counters can be read without the Mifu service',
    () async {
      final monitor = LocalHostMonitor();
      final first = monitor.sample();
      expect(first.memoryTotalBytes, greaterThan(0));
      expect(first.memoryUsedBytes, greaterThan(0));
      expect(first.cpuPercent, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final second = monitor.sample();
      expect(second.cpuPercent, inInclusiveRange(0, 100));
      expect(second.unavailableReason, isNull);
    },
    skip: !Platform.isWindows,
  );
}
