import 'dart:async';

import 'package:consumable_tracker_desktop/features/dashboard/batch_progress_card.dart';
import 'package:consumable_tracker_desktop/providers/batch_recognition_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('batch card keeps its previous frame while aggregate reloads',
      (tester) async {
    final reloadProvider = StateProvider<int>((ref) => 0);
    var result = Future<Map<String, dynamic>?>.value(
      _batchData(progress: 42),
    );
    final container = ProviderContainer(
      overrides: [
        activeBatchProgressProvider.overrideWith((ref) {
          ref.watch(reloadProvider);
          return result;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: BatchProgressCard()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('批次打印'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);

    final pending = Completer<Map<String, dynamic>?>();
    result = pending.future;
    container.read(reloadProvider.notifier).state++;
    await tester.pump();

    expect(find.text('批次打印'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);

    pending.complete(_batchData(progress: 43));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('43%'), findsOneWidget);
  });
}

Map<String, dynamic> _batchData({required int progress}) {
  return {
    'batch_id': 'BATCH-001',
    'count': 2,
    'task_name': 'Flicker regression',
    'success_count': 0,
    'fail_count': 0,
    'printing_count': 2,
    'avg_mc_percent': progress,
    'active_task_id': 1,
    'is_multi_color': false,
    'color_count': 1,
  };
}
