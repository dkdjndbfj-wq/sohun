import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_decision_widgets.dart';
import 'package:consumable_tracker_desktop/widgets/mifu_brand.dart';
import 'package:consumable_tracker_desktop/widgets/mifu_wordmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cluster_screen_test.dart' as cluster;

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'Mifu ${brightness.name} identity keeps existing mark and concise branding',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: Center(
                  child: SizedBox(
                    width: 276,
                    child: MifuDecisionHeader(
                      health: const MifuHealth.disconnected(),
                      inferring: false,
                      onDetails: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(MifuWordmark), findsOneWidget);
        expect(find.text(MifuBrand.tagline), findsOneWidget);
        expect(find.text('待连接'), findsOneWidget);
        expect(find.textContaining('Laya'), findsNothing);
        expect(find.textContaining('100%'), findsNothing);
        expect(find.textContaining('已上线'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final health in [
    const MifuHealth.disconnected(),
    const MifuHealth(trainingState: 'unconfigured'),
  ]) {
    testWidgets(
      'brand details preserve ${health.trainingState} and centered status dialog',
      (tester) async {
        await cluster.pumpCluster(
          tester,
          snapshot: cluster.fixture(),
          health: health,
        );
        expect(find.text(MifuBrand.tagline), findsOneWidget);
        expect(find.textContaining('Laya'), findsNothing);
        final compare = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, '重新决策'),
        );
        expect(compare.onPressed, isNull);
        await tester.tap(find.byTooltip('查看模型与训练节点'));
        await tester.pumpAndSettle();
        final dialog = find.byKey(const ValueKey('mifu-model-details'));
        expect(dialog, findsOneWidget);
        expect(tester.widget<AlertDialog>(dialog).alignment, Alignment.center);
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.text(MifuBrand.description), findsOneWidget);
        expect(find.text('尚未配置'), findsOneWidget);
        expect(find.text('未启用'), findsOneWidget);
        expect(find.text('组件信息'), findsOneWidget);
        expect(find.textContaining('Laya'), findsNothing);

        await tester.tap(find.text('组件信息'));
        await tester.pumpAndSettle();
        expect(find.text('Sohun 自主研发'), findsOneWidget);
        expect(find.textContaining('旧版兼容推理路径使用 Laya'), findsOneWidget);
        expect(find.textContaining('不是从零研发的通用大模型'), findsOneWidget);
        expect(find.textContaining('尚未完成全业务与实机验收'), findsOneWidget);
        expect(find.textContaining('100%'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('expanded component information fits narrow dark large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              child: SingleChildScrollView(child: MifuBrandDetails()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('组件信息'));
    await tester.pumpAndSettle();
    final boundary = find.textContaining('不是从零研发的通用大模型');
    await tester.ensureVisible(boundary);
    await tester.pumpAndSettle();
    expect(boundary, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
