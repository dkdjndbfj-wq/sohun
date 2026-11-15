import 'package:consumable_tracker_desktop/features/cluster/cluster_preparation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cluster_screen_test.dart' as fixtures;

void main() {
  testWidgets('preparation only becomes zero after an explicit ready action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ClusterPreparationDialog(
          candidates: fixtures.fixture().plates.first.candidates,
          checkingOnly: false,
          initialValues: const {1: 90},
        ),
      ),
    );
    final first = find.byKey(const ValueKey('preparation-1'));
    final second = find.byKey(const ValueKey('preparation-2'));
    expect(tester.widget<TextField>(first).controller!.text, '90');
    expect(tester.widget<TextField>(second).controller!.text, isEmpty);
    await tester.tap(find.text('全部无需准备'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(first).controller!.text, '0');
    expect(tester.widget<TextField>(second).controller!.text, '0');
    expect(tester.takeException(), isNull);
  });

  for (final raw in ['-5', '1.5', '1e3', '0x10', '+5', '2678401']) {
    testWidgets('preparation rejects $raw without rewriting the estimate', (
      tester,
    ) async {
      Map<int, int?>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showClusterPreparationDialog(
                    context,
                    candidates: fixtures.fixture().plates.first.candidates,
                    checkingOnly: true,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('preparation-1'));
      await tester.enterText(input, raw);
      expect(tester.widget<TextField>(input).controller!.text, raw);
      await tester.tap(find.text('检查条件'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('请逐台填写预计准备秒数，确认无需准备时填0'), findsOneWidget);

      await tester.enterText(input, '0');
      await tester.tap(find.text('检查条件'));
      await tester.pumpAndSettle();
      expect(result, {1: 0, 2: null});
      expect(tester.takeException(), isNull);
    });
  }
}
