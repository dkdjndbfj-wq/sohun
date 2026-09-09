import 'package:consumable_tracker_desktop/core/services/error_logger.dart';
import 'package:consumable_tracker_desktop/core/services/product_issue_collector.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/features/diagnostics/diagnostics_screen.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('隐私与导出页显示四类本地问题线索', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').get();
    ErrorLogger.init(database);
    ProductIssueCollector.init(database);
    addTearDown(() async {
      // Drain pending frames before detaching the global diagnostics services.
      await tester.pump();
      ProductIssueCollector.detachForTesting();
      ErrorLogger.detachForTesting();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    });

    for (final category in ProductIssueCategory.values) {
      await ProductIssueCollector.record(
        category: category,
        outcome: 'test',
      );
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.5),
            ),
            child: child!,
          ),
          home: const DiagnosticsScreen(),
        ),
      ),
    );
    // The logs tab owns a progress indicator while its asynchronous query is
    // running; advance a bounded amount of fake time instead of waiting for
    // every animation in the diagnostics surface to settle.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.text('隐私与导出'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('本地问题线索'), findsOneWidget);
    for (final category in ProductIssueCategory.values) {
      expect(find.text(category.label), findsOneWidget);
    }
    expect(find.textContaining('最近 30 天 · 4 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
