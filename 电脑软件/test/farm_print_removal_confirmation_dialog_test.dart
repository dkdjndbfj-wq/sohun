import 'dart:io';

import 'package:consumable_tracker_desktop/data/database/daos/print_queue_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/print_queue_item.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_print_removal_confirmation_dialog.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'print_queue_enabled': false,
      'unattended_mode_enabled': false,
    });
  });

  testWidgets('等待取件弹窗不可略过，并在确认后放行当前队列项', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = PrintQueueDao(db);
    final waitingId = await dao.enqueue(
      PrintQueueItem(
        printerSerial: 'FARM-PRINTER-1',
        gcodePath: r'C:\finished.3mf',
        filename: '已完成模型.3mf',
        queuedAt: DateTime(2026, 8, 6, 8),
      ),
    );
    await dao.setStatus(waitingId, PrintQueueStatus.waitingRemoval);
    await dao.enqueue(
      PrintQueueItem(
        printerSerial: 'FARM-PRINTER-1',
        gcodePath: r'C:\next.3mf',
        filename: '下一个模型.3mf',
        queuedAt: DateTime(2026, 8, 6, 9),
      ),
    );
    final waiting = await dao.getWaitingRemoval('FARM-PRINTER-1');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => FarmPrintRemovalConfirmationDialog.show(
                    context,
                    item: waiting!,
                    pendingCount: 1,
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('打印完成，请先取件'), findsOneWidget);
    expect(find.text('已完成模型.3mf'), findsOneWidget);
    expect(find.textContaining('下一项已预排：下一个模型.3mf'), findsOneWidget);
    expect(find.text('已取件，开始下一项'), findsOneWidget);
    expect(find.text('取消'), findsNothing);

    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.text('打印完成，请先取件'), findsOneWidget);

    await tester.tap(find.text('已取件，开始下一项'));
    await tester.pumpAndSettle();

    final items = await dao.getByPrinter('FARM-PRINTER-1');
    expect(
      items.singleWhere((item) => item.id == waitingId).status,
      PrintQueueStatus.completed,
    );
    expect(
      items.singleWhere((item) => item.filename == '下一个模型.3mf').status,
      PrintQueueStatus.queued,
    );
    expect(find.text('打印完成，请先取件'), findsNothing);
  });

  test('等待取件流包含启动前遗留状态，并响应后续状态变化', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final dao = PrintQueueDao(db);
    final id = await dao.enqueue(
      PrintQueueItem(
        printerSerial: 'FARM-PRINTER-2',
        gcodePath: r'C:\persisted.3mf',
        filename: '重启前已完成.3mf',
        queuedAt: DateTime(2026, 8, 6, 8),
      ),
    );
    await dao.setStatus(id, PrintQueueStatus.waitingRemoval);

    final events = <List<PrintQueueItem>>[];
    final subscription = dao.watchAllWaitingRemovals().listen(events.add);
    addTearDown(subscription.cancel);
    await _waitUntil(() => events.isNotEmpty);
    expect(events.last.single.id, id);

    await dao.setStatus(id, PrintQueueStatus.completed);
    await _waitUntil(() => events.isNotEmpty && events.last.isEmpty);
    expect(events.last, isEmpty);
  });

  test('应用入口监听等待取件流并通过全局导航弹出确认', () {
    final app = File('lib/app.dart').readAsStringSync();
    expect(app, contains('ref.listen(pendingPrintRemovalsProvider'));
    expect(app, contains('FarmPrintRemovalConfirmationDialog.show'));
    expect(app, contains('_showPendingFarmPrintRemovals'));
    expect(app, contains('await _showMainWindow()'));
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待异步状态更新超时');
}
