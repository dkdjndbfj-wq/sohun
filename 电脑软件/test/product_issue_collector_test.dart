import 'package:consumable_tracker_desktop/core/services/error_logger.dart';
import 'package:consumable_tracker_desktop/core/services/product_issue_collector.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ProductIssueCollector', () {
    late AppDatabase database;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      database = AppDatabase.forTesting(NativeDatabase.memory());
      await database.customSelect('SELECT 1').get();
      ErrorLogger.init(database);
      ProductIssueCollector.init(database);
    });

    tearDown(() async {
      await ErrorLogger.flushPendingWrites();
      await ProductIssueCollector.flushPendingWrites();
      ProductIssueCollector.detachForTesting();
      ErrorLogger.detachForTesting();
      await database.close();
    });

    test('stores only allowlisted and sanitized issue facts', () async {
      await ProductIssueCollector.record(
        category: ProductIssueCategory.deviceCompatibility,
        outcome: 'connection_failed',
        level: ErrorLevel.warning,
        details: {
          'connectionMode': 'lan',
          'printerModel': 'A1 user@example.com 192.168.1.22',
          'errorCategory': 'network',
          'serial': '01P00A123456789',
          'accessCode': '12345678',
        },
      );

      final summary = await ProductIssueCollector.loadSummary();
      expect(
        summary.counts[ProductIssueCategory.deviceCompatibility],
        1,
      );

      final row = await database
          .customSelect(
            "SELECT context FROM error_logs WHERE source = "
            "'product_issue.device_compatibility'",
          )
          .getSingle();
      final context = row.read<String>('context');
      expect(context, contains('network'));
      expect(context, isNot(contains('user@example.com')));
      expect(context, isNot(contains('192.168.1.22')));
      expect(context, isNot(contains('01P00A123456789')));
      expect(context, isNot(contains('12345678')));
      expect(context, isNot(contains('accessCode')));
    });

    test('serial logger queue can be queried after startup pruning', () async {
      expect(await ErrorLogger.query(limit: 10), isEmpty);
      expect(await ErrorLogger.getStats(), (error: 0, warning: 0, info: 0));
    });

    test('classifies common connection failures without retaining raw errors',
        () {
      expect(
        ProductIssueCollector.classifyConnectionError('socket timeout'),
        'timeout',
      );
      expect(
        ProductIssueCollector.classifyConnectionError('HTTP 401'),
        'authentication',
      );
      expect(
        ProductIssueCollector.classifyConnectionError('TLS certificate'),
        'certificate',
      );
      expect(
        ProductIssueCollector.classifyConnectionError('unknown failure'),
        'unknown',
      );
    });

    test('turns unhandled framework and isolate errors into crash clues',
        () async {
      ErrorLogger.log(
        StateError('test crash'),
        StackTrace.current,
        source: 'isolate',
      );
      await ErrorLogger.flushPendingWrites();
      await ProductIssueCollector.flushPendingWrites();

      final summary = await ProductIssueCollector.loadSummary();
      expect(summary.counts[ProductIssueCategory.crash], 1);
    });

    test('coalesces a burst of equivalent Flutter errors and crash clues',
        () async {
      for (var index = 0; index < 100; index += 1) {
        ErrorLogger.log(
          FlutterError(
            'Cannot hit test RenderAnimatedOpacity#'
            '${(0x10000 + index).toRadixString(16)} with no size',
          ),
          StackTrace.current,
          source: 'flutter_framework',
          context: const {'library': 'gestures library'},
        );
      }

      await ErrorLogger.flushPendingWrites();
      await ProductIssueCollector.flushPendingWrites();

      final rows = await database.customSelect('''
        SELECT source, COUNT(*) AS entry_count
        FROM error_logs
        WHERE source IN ('flutter_framework', 'product_issue.crash')
        GROUP BY source
      ''').get();
      final counts = <String, int>{
        for (final row in rows)
          row.read<String>('source'): row.read<int>('entry_count'),
      };
      expect(counts['flutter_framework'], 1);
      expect(counts['product_issue.crash'], 1);
    });

    test('reports an unclean previous process session on the next start',
        () async {
      await ProductIssueCollector.startSession();
      expect(
        (await ProductIssueCollector.loadSummary())
            .counts[ProductIssueCategory.crash],
        0,
      );

      await ProductIssueCollector.startSession();
      expect(
        (await ProductIssueCollector.loadSummary())
            .counts[ProductIssueCategory.crash],
        1,
      );

      await ProductIssueCollector.markCleanShutdown();
      await ProductIssueCollector.startSession();
      expect(
        (await ProductIssueCollector.loadSummary())
            .counts[ProductIssueCategory.crash],
        1,
      );
    });

    test('diagnostic bundle includes current schema and issue summary',
        () async {
      final bundle = await ErrorLogger.exportDiagnosticsBundle(
        appVersion: 'v1.0.0+1',
        databaseSchemaVersion: AppDatabase.kSchemaVersion,
        featureFlags: const {'telemetry_upload_enabled': false},
        telemetrySummary: 'none',
        productIssueSummary: await ProductIssueCollector.exportSummary(),
      );

      expect(bundle, contains('数据库 schema：v${AppDatabase.kSchemaVersion}'));
      expect(bundle, contains('本地问题线索'));
      expect(bundle, contains('设备兼容'));
    });
  });
}
