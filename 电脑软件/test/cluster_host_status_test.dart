import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_host_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> mount(
  WidgetTester tester, {
  required MifuHealth health,
  VoidCallback? onOpenDetails,
  double width = 650,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
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
  testWidgets('provided GPU snapshot and model details remain visible', (
    tester,
  ) async {
    var opened = false;
    await mount(
      tester,
      health: const MifuHealth(
        trainingState: 'ready',
        gpuName: 'NVIDIA RTX 4070',
        utilizationPercent: 38,
        memoryUsedMb: 4096,
        memoryTotalMb: 12288,
        temperatureC: 51,
      ),
      onOpenDetails: () => opened = true,
    );
    expect(find.text('NVIDIA RTX 4070'), findsOneWidget);
    expect(find.text('38%'), findsOneWidget);
    expect(find.text('4.0 / 12.0 GB'), findsOneWidget);
    expect(find.text('51°C'), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cluster-host-model-status')));
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'missing metrics keep all columns and never become invented zeros',
    (tester) async {
      await mount(tester, health: const MifuHealth.disconnected());
      expect(find.text('GPU 负载'), findsOneWidget);
      expect(find.text('显存'), findsOneWidget);
      expect(find.text('温度'), findsOneWidget);
      expect(find.text('GPU 未识别'), findsOneWidget);
      expect(find.text('待连接'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(3));
      expect(find.text('0%'), findsNothing);
    },
  );

  testWidgets('invalid fields remain unknown and zero load is valid', (
    tester,
  ) async {
    await mount(
      tester,
      health: const MifuHealth(
        trainingState: 'ready',
        utilizationPercent: 140,
        memoryUsedMb: 1000,
        memoryTotalMb: 500,
        temperatureC: double.nan,
      ),
    );
    expect(find.text('—'), findsNWidgets(3));
    await mount(
      tester,
      health: const MifuHealth(
        trainingState: 'ready',
        utilizationPercent: 0,
        memoryUsedMb: 0,
        memoryTotalMb: 8192,
        temperatureC: 0,
      ),
    );
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('0.0 / 8.0 GB'), findsOneWidget);
    expect(find.text('0°C'), findsOneWidget);
  });

  testWidgets('narrow layout wraps while preserving every metric', (
    tester,
  ) async {
    await mount(
      tester,
      health: const MifuHealth(
        trainingState: 'loading',
        gpuName: 'NVIDIA RTX 4070',
        utilizationPercent: 36,
        memoryUsedMb: 2048,
        memoryTotalMb: 8192,
        temperatureC: 49,
      ),
      width: 320,
      textScale: 1.5,
    );
    expect(find.text('NVIDIA RTX 4070'), findsOneWidget);
    expect(find.text('36%'), findsOneWidget);
    expect(find.text('2.0 / 8.0 GB'), findsOneWidget);
    expect(find.text('49°C'), findsOneWidget);
    expect(find.text('加载中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
