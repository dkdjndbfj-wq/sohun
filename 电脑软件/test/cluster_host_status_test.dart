import 'package:consumable_tracker_desktop/core/services/local_host_monitor.dart';
import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_host_status.dart';
import 'package:consumable_tracker_desktop/providers/local_host_monitor_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const gib = 1024 * 1024 * 1024;

Future<void> mount(
  WidgetTester tester,
  LocalHostSnapshot sample, {
  MifuHealth health = const MifuHealth.disconnected(),
  VoidCallback? onOpenDetails,
  double width = 650,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localHostSnapshotProvider.overrideWith((_) => Stream.value(sample)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: ClusterHostStatus(
                health: health,
                onOpenDetails: onOpenDetails ?? () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('local resources stay visible when the model is disconnected', (
    tester,
  ) async {
    var opened = false;
    await mount(
      tester,
      LocalHostSnapshot(
        observedAt: DateTime(2026, 11, 13),
        cpuPercent: 23,
        memoryUsedBytes: 8 * gib,
        memoryTotalBytes: 16 * gib,
      ),
      onOpenDetails: () => opened = true,
    );
    expect(find.text('CPU'), findsOneWidget);
    expect(find.text('23%'), findsOneWidget);
    expect(find.text('8.0 / 16.0 GB'), findsOneWidget);
    expect(find.text('Mifu 未连接'), findsOneWidget);
    expect(find.text('GPU'), findsNothing);
    expect(find.text('显存'), findsNothing);
    expect(find.text('温度'), findsNothing);
    expect(find.text('—'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cluster-host-model-status')));
    expect(opened, isTrue);
  });

  testWidgets('first CPU sample and unavailable resources have honest states', (
    tester,
  ) async {
    await mount(
      tester,
      LocalHostSnapshot(
        observedAt: DateTime(2026, 11, 13),
        cpuSampling: true,
        memoryUsedBytes: 8 * gib,
        memoryTotalBytes: 16 * gib,
      ),
    );
    expect(find.text('采样中'), findsOneWidget);
    expect(find.text('0%'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await mount(
      tester,
      LocalHostSnapshot(
        observedAt: DateTime(2026, 11, 13),
        unavailableReason: '本机资源暂不可用',
      ),
    );
    expect(find.text('本机资源暂不可用'), findsOneWidget);
    expect(find.text('CPU'), findsNothing);
    expect(find.text('内存'), findsNothing);
  });

  testWidgets(
    'only genuine provided GPU fields render and a narrow header wraps',
    (tester) async {
      await mount(
        tester,
        LocalHostSnapshot(
          observedAt: DateTime(2026, 11, 13),
          cpuPercent: 12,
          memoryUsedBytes: 8 * gib,
          memoryTotalBytes: 16 * gib,
        ),
        health: const MifuHealth(
          trainingState: 'ready',
          gpuName: 'Local GPU',
          utilizationPercent: 36,
          memoryUsedMb: 2048,
          memoryTotalMb: 8192,
        ),
        width: 320,
      );
      expect(find.text('GPU'), findsOneWidget);
      expect(find.text('36%'), findsOneWidget);
      expect(find.text('2.0 / 8.0 GB'), findsOneWidget);
      expect(find.text('温度'), findsNothing);
      expect(find.text('Mifu 就绪'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid GPU fields are omitted instead of fabricated', (
    tester,
  ) async {
    await mount(
      tester,
      LocalHostSnapshot(
        observedAt: DateTime(2026, 11, 13),
        unavailableReason: '本机资源暂不可用',
      ),
      health: const MifuHealth(
        trainingState: 'ready',
        utilizationPercent: 140,
        memoryUsedMb: 1000,
        memoryTotalMb: 500,
      ),
    );
    expect(find.text('GPU'), findsNothing);
    expect(find.text('显存'), findsNothing);
    expect(find.text('温度'), findsNothing);
  });

  testWidgets('monitor samples only while the page observes it', (
    tester,
  ) async {
    var reads = 0;
    final monitor = LocalHostMonitor(
      readCounters: () {
        reads++;
        return HostSystemCounters(
          idleTicks: reads * 10,
          kernelTicks: reads * 20,
          userTicks: reads * 10,
          memoryTotalBytes: 16 * gib,
          memoryAvailableBytes: 8 * gib,
        );
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localHostMonitorProvider.overrideWithValue(monitor)],
        child: MaterialApp(
          home: ClusterHostStatus(
            health: const MifuHealth.disconnected(),
            onOpenDetails: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, 1);
    await tester.pump(const Duration(seconds: 3));
    expect(reads, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final afterLeaving = reads;
    await tester.pump(const Duration(seconds: 9));
    expect(reads, afterLeaving);
  });
}
