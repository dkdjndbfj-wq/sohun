import 'package:consumable_tracker_desktop/core/services/cluster_planning_service.dart';
import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_decision_widgets.dart';
import 'package:consumable_tracker_desktop/widgets/mifu_wordmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _longPrinterName = '工作室东侧第三排透明工程材料高速打印设备（用于长名称显示检查）';

ClusterPrinterCandidate _candidate({String name = '设备一'}) =>
    ClusterPrinterCandidate(
      printerId: 1,
      printerSerial: 'fixture-private-serial',
      printerName: name,
      maxRuns: 3,
      materialMatches: const [],
      queuedRuns: 2,
      availableAfterSeconds: null,
    );

ClusterPlatePlan _plan(double grams) => ClusterPlatePlan(
  plate: StudioProductionPlate(
    id: 'plate',
    workspaceId: 'fixture',
    orderId: 'order',
    packageId: 'package',
    plateIndex: 1,
    name: '外壳',
    requiredRuns: 3,
    estimatedSeconds: 3600,
    estimatedGrams: grams,
    createdAt: DateTime(2026, 11, 12),
  ),
  remainingRuns: 2,
  assignedRuns: 1,
  completedRuns: 0,
  candidates: const [],
  blockers: const [],
  rejections: const {},
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  double width = 300,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    InteractionEffectsScope(
      enabled: false,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Center(
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

MifuWordmarkPainter _painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(MifuWordmark),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!
        as MifuWordmarkPainter;

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'wordmark ${brightness.name} keeps its accessible name and colors',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await _pump(
          tester,
          const Align(child: MifuWordmark(width: 116)),
          brightness: brightness,
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Mifu')),
          matchesSemantics(label: 'Mifu', isImage: true),
        );
        final size = tester.getSize(
          find.byKey(const ValueKey('mifu-wordmark')),
        );
        expect(size.width, 116);
        expect(size.height, closeTo(50.4, .0001));
        final painter = _painter(tester);
        expect(
          painter.color,
          brightness == Brightness.dark
              ? const Color(0xFFEEF2EF)
              : const Color(0xFF202623),
        );
        expect(
          painter.accentColor,
          brightness == Brightness.dark
              ? const Color(0xFF9FBE82)
              : const Color(0xFF94B274),
        );
        semantics.dispose();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('long candidate ${brightness.name} remains usable at 2x text', (
      tester,
    ) async {
      var selections = 0;
      final semantics = tester.ensureSemantics();
      await _pump(
        tester,
        MifuCandidateTile(
          candidate: _candidate(name: _longPrinterName),
          selected: true,
          probability: 1,
          onTap: () => selections++,
        ),
        brightness: brightness,
        width: 276,
        textScale: 2,
      );
      expect(find.text('100.0%'), findsOneWidget);
      expect(find.text('机器等待未知'), findsOneWidget);
      expect(find.text('机器等待 0 分'), findsNothing);
      final label = tester.widget<Text>(find.text(_longPrinterName));
      expect(label.maxLines, isNotNull);
      expect(label.overflow, TextOverflow.ellipsis);
      expect(
        tester.getSemantics(find.byType(MifuCandidateTile)).label,
        contains(_longPrinterName),
      );
      semantics.dispose();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(_longPrinterName));
      await tester.pumpAndSettle();
      expect(selections, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('status chip is announced as an actionable button', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pump(
        tester,
        MifuDecisionHeader(
          health: const MifuHealth(trainingState: 'unconfigured'),
          inferring: false,
          onDetails: () {},
        ),
      );
      final status = tester.getSemantics(
        find.descendant(
          of: find.byTooltip('查看 Mifu 状态'),
          matching: find.byType(InkWell),
        ),
      );
      expect(status.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(status.label, contains('待训练'));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'wordmark honors explicit colors and repaints only changed colors',
    (tester) async {
      await _pump(
        tester,
        const MifuWordmark(color: Colors.purple, accentColor: Colors.orange),
      );
      final painter = _painter(tester);
      expect(painter.color, Colors.purple);
      expect(painter.accentColor, Colors.orange);
      expect(
        painter.shouldRepaint(
          const MifuWordmarkPainter(
            color: Colors.purple,
            accentColor: Colors.orange,
          ),
        ),
        isFalse,
      );
      expect(
        painter.shouldRepaint(
          const MifuWordmarkPainter(
            color: Colors.black,
            accentColor: Colors.orange,
          ),
        ),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          const MifuWordmarkPainter(
            color: Colors.purple,
            accentColor: Colors.green,
          ),
        ),
        isTrue,
      );
    },
  );

  for (final state in {
    'disconnected': '待连接',
    'unconfigured': '待训练',
    'loading': '加载中',
    'error': '加载失败',
    'ready': '已连接',
  }.entries) {
    testWidgets('header exposes ${state.key} and opens status with keyboard', (
      tester,
    ) async {
      var opened = 0;
      await _pump(
        tester,
        MifuDecisionHeader(
          health: MifuHealth(trainingState: state.key),
          inferring: false,
          onDetails: () => opened++,
        ),
        width: 276,
        textScale: 2,
      );
      expect(find.text(state.value), findsOneWidget);
      expect(find.byTooltip('查看 Mifu 状态'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(opened, 1);
    });
  }

  testWidgets(
    'inference status overrides the ready label only while comparing',
    (tester) async {
      await _pump(
        tester,
        MifuDecisionHeader(
          health: const MifuHealth(trainingState: 'ready', version: 'fixture'),
          inferring: true,
          onDetails: () {},
        ),
      );
      expect(find.text('比较中'), findsOneWidget);
      expect(find.text('已连接'), findsNothing);
    },
  );

  testWidgets(
    'manual candidate has no probability or progress and is keyboard selectable',
    (tester) async {
      var selections = 0;
      await _pump(
        tester,
        MifuCandidateTile(
          candidate: _candidate(),
          selected: false,
          onTap: () => selections++,
        ),
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      final queueSummary = tester.widget<Text>(find.textContaining('队列'));
      expect(queueSummary.data, contains('3'));
      expect(queueSummary.data, contains('2'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selections, 1);
    },
  );

  testWidgets('candidate selection state is exposed to accessibility', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    for (final selected in [false, true]) {
      await _pump(
        tester,
        MifuCandidateTile(
          candidate: _candidate(),
          selected: selected,
          onTap: () {},
        ),
      );
      final candidate = tester.getSemantics(find.byType(MifuCandidateTile));
      expect(candidate.label, contains('设备一'));
      expect(
        candidate,
        matchesSemantics(
          label: candidate.label,
          isButton: true,
          isSelected: selected,
          hasSelectedState: true,
          hasTapAction: true,
          isFocusable: true,
          hasFocusAction: true,
        ),
      );
    }
    semantics.dispose();
  });

  testWidgets('plate summary keeps unknown weight distinct from real weight', (
    tester,
  ) async {
    for (final grams in [double.nan, double.infinity, -1.0, 0.0]) {
      await _pump(
        tester,
        MifuPlateSummary(plan: _plan(grams), duration: '1.0 时'),
      );
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0.0 g'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await _pump(tester, MifuPlateSummary(plan: _plan(50.2), duration: '1.0 时'));
    expect(find.text('50.2 g'), findsOneWidget);
    expect(find.text('P01 · 外壳'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets(
    'candidate counts wrap without conflating total eligible and compared',
    (tester) async {
      await _pump(
        tester,
        const MifuCandidateSummary(total: 100, eligible: 24, compared: 16),
        width: 276,
        textScale: 2,
      );
      for (final label in ['100', '24', '16', '全部设备', '满足条件', '本次候选']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
