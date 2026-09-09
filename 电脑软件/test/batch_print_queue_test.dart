import 'package:consumable_tracker_desktop/data/database/daos/print_queue_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/print_queue_item.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('批量队列保存每项取件方式和批次计数', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final dao = PrintQueueDao(database);

    await dao.enqueue(
      PrintQueueItem(
        printerSerial: 'BATCH-A1-01',
        gcodePath: 'C:/batch/part.3mf',
        filename: 'part · 批量 2/9',
        queuedAt: DateTime(2026, 8, 5),
        autoContinue: false,
        batchId: 'batch-1',
        batchIndex: 2,
        batchTotal: 9,
      ),
    );

    final item = (await dao.getByPrinter('BATCH-A1-01')).single;
    expect(await dao.getByBatchId('batch-1'), hasLength(1));
    expect(item.autoContinue, isFalse);
    expect(item.batchId, 'batch-1');
    expect(item.batchIndex, 2);
    expect(item.batchTotal, 9);
    expect(item.effectiveAutoContinue(true), isFalse);

    final automatic = item.copyWith(autoContinue: true);
    expect(automatic.effectiveAutoContinue(false), isTrue);
    final legacy = PrintQueueItem(
      printerSerial: 'LEGACY',
      gcodePath: 'legacy.3mf',
      filename: 'legacy.3mf',
      queuedAt: DateTime(2026, 8, 5),
    );
    expect(legacy.effectiveAutoContinue(true), isTrue);
  });
}
