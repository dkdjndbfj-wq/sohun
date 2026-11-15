import 'package:consumable_tracker_desktop/features/cluster/cluster_decision_widgets.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_task_array.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cluster_screen_test.dart' as existing;

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      '1000px ${brightness.name} desktop content keeps three columns and candidate selection',
      (tester) async {
        // ClusterScreen contributes 16px on each side, leaving 1000px for the
        // three-column workspace at the supported compact-desktop boundary.
        await existing.pumpCluster(
          tester,
          snapshot: existing.fixture(),
          size: const Size(1032, 900),
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('P01  外壳'));
        await tester.pumpAndSettle();

        final taskRect = tester.getRect(find.byType(ClusterTaskArray));
        final decisionRect = tester.getRect(
          find.byKey(const ValueKey('mifu-decision-panel')),
        );
        final deviceHeading = tester.getRect(find.text('打印机阵列'));
        expect(taskRect.right, lessThan(decisionRect.left));
        expect(decisionRect.right, lessThan(deviceHeading.left));
        expect(taskRect.top, closeTo(decisionRect.top, .1));
        expect(
          deviceHeading.top,
          inInclusiveRange(taskRect.top, taskRect.top + 40),
        );
        expect(tester.takeException(), isNull);

        final candidate = find.widgetWithText(MifuCandidateTile, '设备 2');
        await tester.ensureVisible(candidate);
        await tester.pumpAndSettle();
        expect(candidate.hitTestable(), findsOneWidget);
        await tester.tap(candidate);
        await tester.pumpAndSettle();
        expect(tester.widget<MifuCandidateTile>(candidate).selected, isTrue);
        expect(
          tester
              .widget<MifuCandidateTile>(
                find.widgetWithText(MifuCandidateTile, '设备 1'),
              )
              .selected,
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
