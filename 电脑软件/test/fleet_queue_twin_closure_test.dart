import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_ftp_uploader.dart';

import 'package:consumable_tracker_desktop/core/services/consumable_twin_service.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/data/database/daos/consumable_twin_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/print_queue_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/preset_result_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/print_task_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/scheduler_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/spool_reservation_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/studio_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/consumable_twin_event.dart';
import 'package:consumable_tracker_desktop/data/database/models/print_queue_item.dart';
import 'package:consumable_tracker_desktop/data/database/models/scheduler_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_queue_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_task_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:consumable_tracker_desktop/providers/scheduler_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = PrinterConnectionConfig(
    serial: 'FLEET-001',
    host: '192.168.1.20',
    accessCode: '12345678',
    devProductName: 'P1S',
    installedNozzleDiameter: 0.4,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('新配置注册 connector，ensureConnected 和按 serial 发送可用', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final connectors = <_FakePrinterConnector>[];
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mergedPrinterListProvider.overrideWithValue(const [config]),
        printerConnectorFactoryProvider.overrideWithValue((printerConfig) {
          final connector = _FakePrinterConnector(printerConfig);
          connectors.add(connector);
          return connector;
        }),
      ],
    );
    addTearDown(container.dispose);

    final manager =
        container.read(printerFleetConnectionManagerProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    expect(manager.getState(config.serial), isNotNull);
    expect(
      manager.getState(config.serial)!.connectionState,
      PrinterConnectionState.disconnected,
    );

    await Future.wait([
      manager.ensureConnected(config.serial),
      manager.ensureConnected(config.serial),
    ]);
    expect(connectors.length, 2, reason: '并发连接请求只能创建一个实际连接器');

    final state = await manager.ensureFreshStatus(
      config.serial,
      SchedulingConfig.defaults,
    );
    expect(state?.connectionState, PrinterConnectionState.connected);
    expect(state?.lastStatus?.gcodeState, BambuGcodeState.idle);
    expect(
      state?.targetSpecMismatch(
        const PrinterModelSpec(
          canonicalModel: 'P1S',
          nozzleDiameter: 0.6,
        ),
      ),
      contains('喷嘴不匹配'),
    );
    expect(
      state?.targetSpecMismatch(
        const PrinterModelSpec(
          canonicalModel: 'P1S',
          nozzleDiameter: 0.4,
        ),
      ),
      isNull,
    );

    final sent = await manager.sendPrintTask(config.serial, r'C:\part.3mf');
    expect(sent, isTrue);
    expect(connectors.last.sentPaths, [r'C:\part.3mf']);
  });

  test('队列完成和失败推进使用舰队 serial，不依赖当前 UI 活跃打印机', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    late _FakePrinterConnector activeConnector;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mergedPrinterListProvider.overrideWithValue(const [config]),
        printerConnectorFactoryProvider.overrideWithValue((printerConfig) {
          activeConnector = _FakePrinterConnector(printerConfig);
          return activeConnector;
        }),
      ],
    );
    addTearDown(container.dispose);

    final queueDao = PrintQueueDao(db);
    final queueId = await queueDao.enqueue(
      PrintQueueItem(
        printerSerial: config.serial,
        gcodePath: r'C:\part.3mf',
        filename: 'part.3mf',
        queuedAt: DateTime.now(),
      ),
    );
    await queueDao.setStatus(
      queueId,
      PrintQueueStatus.printing,
      startedAt: DateTime.now(),
    );

    container.read(printQueueStateMachineProvider);
    final manager =
        container.read(printerFleetConnectionManagerProvider.notifier);
    await manager.ensureFreshStatus(config.serial, SchedulingConfig.defaults);

    activeConnector.emitStatus(BambuGcodeState.running);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    activeConnector.emitStatus(BambuGcodeState.finish);

    final advanced = await _waitForQueueStatus(
      queueDao,
      config.serial,
      PrintQueueStatus.waitingRemoval,
    );
    expect(advanced, isTrue);

    await queueDao.setStatus(queueId, PrintQueueStatus.completed);
    final failedQueueId = await queueDao.enqueue(
      PrintQueueItem(
        printerSerial: config.serial,
        gcodePath: r'C:\failed.3mf',
        filename: 'failed.3mf',
        queuedAt: DateTime.now(),
      ),
    );
    await queueDao.setStatus(
      failedQueueId,
      PrintQueueStatus.printing,
      startedAt: DateTime.now(),
    );
    activeConnector.emitStatus(BambuGcodeState.running);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    activeConnector.emitStatus(BambuGcodeState.failed);

    final failed = await _waitForQueueStatus(
      queueDao,
      config.serial,
      PrintQueueStatus.failed,
    );
    expect(failed, isTrue);
  });

  test('失败队列项原位重试，不创建重复任务', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final queueDao = PrintQueueDao(db);
    final queueId = await queueDao.enqueue(
      PrintQueueItem(
        printerSerial: config.serial,
        gcodePath: r'C:\retry.3mf',
        filename: 'retry.3mf',
        queuedAt: DateTime.now(),
      ),
    );
    await queueDao.setStatus(
      queueId,
      PrintQueueStatus.failed,
      completedAt: DateTime.now(),
    );

    await queueDao.retryFailed(queueId);
    final items = await queueDao.getByPrinter(config.serial);
    expect(items, hasLength(1));
    expect(items.single.id, queueId);
    expect(items.single.status, PrintQueueStatus.queued);
    expect(items.single.attemptNo, 2);
    expect(items.single.startedAt, isNull);
    expect(items.single.completedAt, isNull);
    await expectLater(queueDao.retryFailed(queueId), throwsStateError);
  });

  test('打印机从运行直接回到 idle 时，队列会按中止处理而不是继续卡在打印中', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    late _FakePrinterConnector connector;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mergedPrinterListProvider.overrideWithValue(const [config]),
        printerConnectorFactoryProvider.overrideWithValue((printerConfig) {
          connector = _FakePrinterConnector(printerConfig);
          return connector;
        }),
      ],
    );
    addTearDown(container.dispose);
    final queueDao = PrintQueueDao(db);
    final queueId = await queueDao.enqueue(
      PrintQueueItem(
        printerSerial: config.serial,
        gcodePath: r'C:\stopped.3mf',
        filename: 'stopped.3mf',
        queuedAt: DateTime.now(),
      ),
    );
    await queueDao.setStatus(
      queueId,
      PrintQueueStatus.printing,
      startedAt: DateTime.now(),
    );
    container.read(printQueueStateMachineProvider);
    final manager =
        container.read(printerFleetConnectionManagerProvider.notifier);
    await manager.ensureFreshStatus(config.serial, SchedulingConfig.defaults);
    connector.emitStatus(BambuGcodeState.running, mcPercent: 35);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    connector.emitStatus(BambuGcodeState.idle, mcPercent: 35);
    expect(
      await _waitForQueueStatus(
        queueDao,
        config.serial,
        PrintQueueStatus.failed,
      ),
      isTrue,
    );
  });

  test('农场打印完成上报后立即完成工单和订单，取件只放行下一项', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final studioDao = StudioDao(db);
    addTearDown(studioDao.dispose);
    final workspace = await studioDao.ensureDefaultWorkspace();
    final orderId = await studioDao.addProductionOrder(
      workspaceId: workspace.id,
      orderNo: 'SO-FINISH-AUTO',
      title: '自动完成订单',
      packages: const [
        StudioProductionPackageDraft(
          sourceName: 'auto-finish.3mf',
          artifactKind: 'bambu3mf',
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 1,
              name: '自动完成盘',
              requiredRuns: 1,
              estimatedSeconds: 60,
              estimatedGrams: 0,
              sliceStatus: StudioPlateSliceStatus.sliced,
              items: [
                StudioOrderItemDraft(
                  sourceKey: 'object',
                  name: '对象',
                  perRunQuantity: 1,
                  requiredQuantity: 1,
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final workOrder = (await studioDao.getDefaultSnapshot())
        .workOrders
        .singleWhere((item) => item.orderId == orderId);

    late _FakePrinterConnector connector;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mergedPrinterListProvider.overrideWithValue(const [config]),
        printerConnectorFactoryProvider.overrideWithValue((printerConfig) {
          connector = _FakePrinterConnector(printerConfig);
          return connector;
        }),
      ],
    );
    addTearDown(container.dispose);
    final queueDao = PrintQueueDao(db);
    final queueId = await queueDao.enqueue(
      PrintQueueItem(
        printerSerial: config.serial,
        gcodePath: r'C:\auto-finish.3mf',
        filename: 'auto-finish.3mf',
        queuedAt: DateTime.now(),
        studioWorkOrderId: workOrder.id,
      ),
    );
    await queueDao.setStatus(
      queueId,
      PrintQueueStatus.printing,
      startedAt: DateTime.now(),
    );

    container.read(printQueueStateMachineProvider);
    final manager =
        container.read(printerFleetConnectionManagerProvider.notifier);
    await manager.ensureFreshStatus(config.serial, SchedulingConfig.defaults);
    connector.emitStatus(BambuGcodeState.running, mcPercent: 20);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    connector.emitStatus(BambuGcodeState.finish, mcPercent: 100);

    expect(
      await _waitForQueueStatus(
        queueDao,
        config.serial,
        PrintQueueStatus.waitingRemoval,
      ),
      isTrue,
    );
    for (var i = 0; i < 50; i++) {
      final snapshot = await studioDao.getDefaultSnapshot();
      final currentWorkOrder =
          snapshot.workOrders.singleWhere((item) => item.id == workOrder.id);
      if (currentWorkOrder.status == StudioWorkOrderStatus.completed) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final completed = await studioDao.getDefaultSnapshot();
    expect(
      completed.workOrders
          .singleWhere((item) => item.id == workOrder.id)
          .status,
      StudioWorkOrderStatus.completed,
    );
    expect(completed.orders.singleWhere((item) => item.id == orderId).status,
        StudioOrderStatus.completed);
    expect(completed.printAttempts, hasLength(1));
    expect(
      completed.printAttempts.single.outcome,
      StudioPrintAttemptOutcome.completed,
    );
  });

  test('后台非选中打印机也会建立任务、绑定队列并落库终态结果', () async {
    final tempDir = await Directory.systemTemp.createTemp('fleet_task_chain_');
    addTearDown(() => tempDir.delete(recursive: true));
    final gcode = await _writeQueueGcode(
      tempDir,
      filename: 'background-p1s.gcode',
      printerSettingsId: 'Bambu Lab P1S 0.4 nozzle',
    );
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement(
      "INSERT INTO printers(id, brand, model, serial) "
      "VALUES (1, 'Bambu Lab', 'P1S', '${config.serial}')",
    );

    late _FakePrinterConnector connector;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mergedPrinterListProvider.overrideWithValue(const [config]),
        printerConnectorFactoryProvider.overrideWithValue((printerConfig) {
          connector = _FakePrinterConnector(printerConfig);
          return connector;
        }),
      ],
    );
    addTearDown(container.dispose);

    final queueDao = PrintQueueDao(db);
    final taskDao = PrintTaskDao(db);
    addTearDown(taskDao.dispose);
    final queueId = await queueDao.enqueue(
      PrintQueueItem(
        printerSerial: config.serial,
        gcodePath: gcode.path,
        filename: gcode.uri.pathSegments.last,
        queuedAt: DateTime.now(),
      ),
    );
    await queueDao.setStatus(
      queueId,
      PrintQueueStatus.printing,
      startedAt: DateTime.now(),
    );

    container.read(printQueueStateMachineProvider);
    container.read(printTaskOrchestratorProvider);
    final manager =
        container.read(printerFleetConnectionManagerProvider.notifier);
    await manager.ensureFreshStatus(config.serial, SchedulingConfig.defaults);

    connector.emitStatus(
      BambuGcodeState.running,
      gcodeFile: gcode.uri.pathSegments.last,
      mcPercent: 10,
      currLayer: 2,
      totalLayers: 20,
    );
    expect(
      await _waitForPrintTaskStatus(
        taskDao,
        PrintTaskStatus.printing,
      ),
      isTrue,
    );
    final task = (await taskDao.getAll()).single;
    final printingQueue = await queueDao.getPrinting(config.serial);
    expect(printingQueue?.printTaskId, task.id);

    connector.emitStatus(
      BambuGcodeState.finish,
      gcodeFile: gcode.uri.pathSegments.last,
      mcPercent: 100,
      currLayer: 20,
      totalLayers: 20,
    );
    expect(
      await _waitForPrintTaskStatus(
        taskDao,
        PrintTaskStatus.finished,
      ),
      isTrue,
    );
    expect(
      await _waitForQueueStatus(
        queueDao,
        config.serial,
        PrintQueueStatus.waitingRemoval,
      ),
      isTrue,
    );

    final resultDao = PresetResultDao(db);
    addTearDown(resultDao.dispose);
    expect(
      await _waitForPresetResult(resultDao, task.id!),
      isTrue,
    );
  });

  test('队列发送前拒绝错机型文件，并把正确文件的 AMS 映射传给设备', () async {
    final tempDir = await Directory.systemTemp.createTemp('queue_preflight_');
    addTearDown(() => tempDir.delete(recursive: true));
    final wrongFile = await _writeQueueGcode(
      tempDir,
      filename: 'wrong-x1.gcode',
      printerSettingsId: 'Bambu Lab X1 Carbon 0.4 nozzle',
    );
    final validFile = await _writeQueueGcode(
      tempDir,
      filename: 'valid-p1s.gcode',
      printerSettingsId: 'Bambu Lab P1S 0.4 nozzle',
      amsMapping: '[1,0]',
    );
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    late _FakePrinterConnector connector;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mergedPrinterListProvider.overrideWithValue(const [config]),
        printerConnectorFactoryProvider.overrideWithValue((printerConfig) {
          connector = _FakePrinterConnector(printerConfig);
          return connector;
        }),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      printQueueProvider(config.serial),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    final notifier = container.read(printQueueProvider(config.serial).notifier);

    await expectLater(
      notifier.enqueue(
        gcodePath: wrongFile.path,
        filename: wrongFile.uri.pathSegments.last,
      ),
      throwsA(isA<StateError>()),
    );
    final rejected = await PrintQueueDao(db).getByPrinter(config.serial);
    expect(rejected.single.status, PrintQueueStatus.failed);
    expect(connector.sentPaths, isEmpty);

    await notifier.delete(rejected.single.id!);
    await notifier.enqueue(
      gcodePath: validFile.path,
      filename: validFile.uri.pathSegments.last,
    );
    final accepted = await PrintQueueDao(db).getByPrinter(config.serial);
    expect(accepted.single.status, PrintQueueStatus.printing);
    expect(connector.sentPaths, [validFile.path]);
    expect(connector.sentAmsMappings, [
      const [1, 0],
    ]);
  });

  test('多盘项目从工单到发送保留第二盘，不误用第一盘机型与耗材', () async {
    final directory =
        await Directory.systemTemp.createTemp('queue_plate_selection_');
    addTearDown(() => directory.delete(recursive: true));
    final wrong = await _writeQueueGcode(directory,
        filename: 'one.gcode',
        printerSettingsId: 'Bambu Lab X1 Carbon 0.4 nozzle');
    final right = await _writeQueueGcode(directory,
        filename: 'two.gcode', printerSettingsId: 'Bambu Lab P1S 0.4 nozzle');
    final archive = Archive();
    void add(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('Metadata/plate_1.gcode', await wrong.readAsString());
    add('Metadata/plate_2.gcode', await right.readAsString());
    add(
        'Metadata/slice_info.config',
        '<config>${[
          1,
          2
        ].map((index) => '<plate><metadata key="index" value="$index"/><metadata key="prediction" value="60"/><filament id="1" used_g="12.5"/><filament id="2" used_g="4"/></plate>').join()}</config>');
    final artifact = File('${directory.path}/two-plates.3mf');
    await artifact.writeAsBytes(ZipEncoder().encode(archive)!);
    await expectLater(
        BambuGcodePathResolver.resolveFrom3mf(artifact.path, plateIndex: 3),
        throwsFormatException);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final studioDao = StudioDao(db);
    addTearDown(studioDao.dispose);
    final workspace = await studioDao.ensureDefaultWorkspace();
    final orderId = await studioDao.addProductionOrder(
        workspaceId: workspace.id,
        orderNo: 'PLATE-2',
        title: '第二盘',
        packages: [
          StudioProductionPackageDraft(
              sourceName: 'two-plates.3mf',
              artifactKind: 'bambu3mf',
              plates: [
                StudioProductionPlateDraft(
                    plateIndex: 2,
                    name: '第二盘',
                    requiredRuns: 1,
                    estimatedSeconds: 60,
                    estimatedGrams: 16.5,
                    sliceStatus: StudioPlateSliceStatus.sliced,
                    items: const [
                      StudioOrderItemDraft(
                          sourceKey: 'part',
                          name: 'part',
                          perRunQuantity: 1,
                          requiredQuantity: 1),
                    ]),
              ]),
        ]);
    final workOrder = (await studioDao.getDefaultSnapshot())
        .workOrders
        .singleWhere((item) => item.orderId == orderId);
    late _FakePrinterConnector connector;
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      mergedPrinterListProvider.overrideWithValue(const [config]),
      printerConnectorFactoryProvider.overrideWithValue(
          (printerConfig) => connector = _FakePrinterConnector(printerConfig)),
    ]);
    addTearDown(container.dispose);
    final subscription = container.listen(
        printQueueProvider(config.serial), (_, __) {},
        fireImmediately: true);
    addTearDown(subscription.close);
    await container
        .read(printQueueProvider(config.serial).notifier)
        .enqueueStudioWorkOrder(
            workOrderId: workOrder.id,
            gcodePath: artifact.path,
            filename: 'two-plates.3mf',
            amsMapping: [1, 0]);
    expect(connector.sentPaths, [artifact.path]);
    expect(connector.sentPlateIndices, [2]);
    expect((await PrintQueueDao(db).getByPrinter(config.serial)).single.status,
        PrintQueueStatus.printing);
  });

  test('后续任务可在打印中预排，但必须确认取件后才发送', () async {
    SharedPreferences.setMockInitialValues({
      'farm_allow_queue_while_printing': false,
    });
    final tempDir = await Directory.systemTemp.createTemp('queue_prequeue_');
    addTearDown(() => tempDir.delete(recursive: true));
    final firstFile = await _writeQueueGcode(
      tempDir,
      filename: 'first-p1s.gcode',
      printerSettingsId: 'Bambu Lab P1S 0.4 nozzle',
    );
    final nextFile = await _writeQueueGcode(
      tempDir,
      filename: 'next-p1s.gcode',
      printerSettingsId: 'Bambu Lab P1S 0.4 nozzle',
    );
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    late _FakePrinterConnector connector;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mergedPrinterListProvider.overrideWithValue(const [config]),
        printerConnectorFactoryProvider.overrideWithValue((printerConfig) {
          connector = _FakePrinterConnector(printerConfig);
          return connector;
        }),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      printQueueProvider(config.serial),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    container.read(printQueueStateMachineProvider);
    final notifier = container.read(printQueueProvider(config.serial).notifier);

    await notifier.enqueue(
      gcodePath: firstFile.path,
      filename: firstFile.uri.pathSegments.last,
    );
    connector.emitStatus(BambuGcodeState.running, mcPercent: 20);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await notifier.enqueue(
      gcodePath: nextFile.path,
      filename: nextFile.uri.pathSegments.last,
    );

    var items = await PrintQueueDao(db).getByPrinter(config.serial);
    expect(items.where((item) => item.status == PrintQueueStatus.printing),
        hasLength(1));
    expect(items.where((item) => item.status == PrintQueueStatus.queued),
        hasLength(1));
    expect(connector.sentPaths, [firstFile.path]);

    connector.emitStatus(BambuGcodeState.finish, mcPercent: 100);
    expect(
      await _waitForQueueStatus(
        PrintQueueDao(db),
        config.serial,
        PrintQueueStatus.waitingRemoval,
      ),
      isTrue,
    );
    expect(connector.sentPaths, [firstFile.path], reason: '等待工作人员取件期间不能发送下一项');

    items = await PrintQueueDao(db).getByPrinter(config.serial);
    final waiting = items.singleWhere(
      (item) => item.status == PrintQueueStatus.waitingRemoval,
    );
    await notifier.confirmRemoval(expectedQueueItemId: waiting.id);

    items = await PrintQueueDao(db).getByPrinter(config.serial);
    expect(
      items.singleWhere((item) => item.id == waiting.id).status,
      PrintQueueStatus.completed,
    );
    expect(
      items
          .singleWhere(
              (item) => item.filename == nextFile.uri.pathSegments.last)
          .status,
      PrintQueueStatus.printing,
    );
    expect(connector.sentPaths, [firstFile.path, nextFile.path]);
  });

  test('队列终态自动推进调度任务并释放耗材预留', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(schedulerNotifierProvider);

    await db.customStatement(
      "INSERT INTO printers(id, brand, model, serial) "
      "VALUES (1, '拓竹', 'P1S', 'SCHEDULER-QUEUE-1')",
    );
    final consumableId = await db.customInsert(
      "INSERT INTO consumables(manufacturer, model, material_type, color_hex, "
      "total_grams, remaining_grams) "
      "VALUES ('Bambu Lab', 'PLA Basic', 'PLA', '#FFFFFF', 1000, 800)",
    );
    final schedulerDao = SchedulerDao(db);
    addTearDown(schedulerDao.dispose);
    final taskId = await schedulerDao.insertTask(
      SchedulerTask(
        gcodePath: r'C:\scheduled.gcode',
        gcodeFilename: 'scheduled.gcode',
        modelGroup: PrinterModelGroup.p1,
        requiredMaterial: 'PLA',
        estimatedGrams: 50,
        status: SchedulerTaskStatus.assigned,
        assignedPrinterId: 1,
        createdAt: DateTime.now(),
        assignedAt: DateTime.now(),
      ),
    );
    final reservationDao = SpoolReservationDao(db);
    await reservationDao.reserve(
      schedulerTaskId: taskId,
      consumableId: consumableId,
      toolIndex: 0,
      grams: 50,
    );
    final queueDao = PrintQueueDao(db);
    final queueId = await queueDao.enqueue(
      PrintQueueItem(
        printerSerial: 'SCHEDULER-QUEUE-1',
        gcodePath: r'C:\scheduled.gcode',
        filename: 'scheduled.gcode',
        queuedAt: DateTime.now(),
        schedulerTaskId: taskId,
      ),
    );

    await queueDao.setStatus(
      queueId,
      PrintQueueStatus.completed,
      completedAt: DateTime.now(),
    );

    expect(
      await _waitForSchedulerStatus(
        schedulerDao,
        taskId,
        SchedulerTaskStatus.completed,
      ),
      isTrue,
    );
    final availability = await reservationDao.getAvailableGrams(consumableId);
    expect(availability.totalReservedGrams, 0);
  });

  group('耗材孪生位置账本', () {
    late AppDatabase db;
    late int consumableId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.customStatement(
        "INSERT INTO printers(id, brand, model, serial) "
        "VALUES (1, '拓竹', 'P1S', 'PRINTER-A')",
      );
      await db.customStatement(
        "INSERT INTO printers(id, brand, model, serial) "
        "VALUES (2, '拓竹', 'P1S', 'PRINTER-B')",
      );
    });

    tearDown(() => db.close());

    test('事件保存 printer_serial，心跳位置比较包含打印机', () async {
      // 使用 customStatement 写入，避免本测试依赖 Drift 生成 companion。
      consumableId = await db.customInsert(
        "INSERT INTO consumables(manufacturer, model, material_type, color_hex, total_grams, remaining_grams, tray_uuid) "
        "VALUES ('Bambu Lab', 'PLA Basic', 'PLA', '#FFFFFF', 1000, 800, 'tray-1')",
      );
      final dao = ConsumableTwinDao(db);
      final first = await dao.recordEvent(
        consumableId: consumableId,
        trayUuid: 'tray-1',
        eventType: TwinEventType.rfidObserved,
        printerId: 1,
        printerSerial: 'PRINTER-A',
        amsId: 0,
        slotIndex: 0,
        afterGrams: 800,
      );
      final movedPrinter = await dao.recordEvent(
        consumableId: consumableId,
        trayUuid: 'tray-1',
        eventType: TwinEventType.rfidObserved,
        printerId: 2,
        printerSerial: 'PRINTER-B',
        amsId: 0,
        slotIndex: 0,
        afterGrams: 800,
      );

      expect(first, isNotEmpty);
      expect(movedPrinter, isNotEmpty, reason: '相同 AMS/槽位但不同打印机不能被当作心跳去重');
      final state = await dao.getCurrentState('tray-1');
      expect(state?.printerSerial, 'PRINTER-B');
    });

    test('跨打印机移动后，空槽会记录 removed', () async {
      consumableId = await db.customInsert(
        "INSERT INTO consumables(manufacturer, model, material_type, color_hex, total_grams, remaining_grams, tray_uuid) "
        "VALUES ('Bambu Lab', 'PLA Basic', 'PLA', '#FFFFFF', 1000, 800, 'tray-move')",
      );
      final service = ConsumableTwinService(db);
      const loaded = AmsTray(
        amsId: 0,
        slot: 1,
        trayType: 'PLA',
        trayInfoIdx: 'GFA00',
        trayUuid: 'tray-move',
        traySubBrands: 'Bambu Lab',
        trayWeight: 1000,
        remain: 80,
        hasFilament: true,
      );
      await service.handleAmsTrays(
        printerId: 1,
        printerSerial: 'PRINTER-A',
        trays: const [loaded],
      );
      await service.handleAmsTrays(
        printerId: 2,
        printerSerial: 'PRINTER-B',
        trays: const [loaded],
      );
      await service.handleAmsTrays(
        printerId: 2,
        printerSerial: 'PRINTER-B',
        trays: const [AmsTray(amsId: 0, slot: 1, hasFilament: false)],
      );

      final events = await service.getTimeline('tray-move');
      expect(
        events.any(
          (event) =>
              event.eventType == TwinEventType.moved &&
              event.printerSerial == 'PRINTER-B',
        ),
        isTrue,
      );
      expect(
        events.any(
          (event) =>
              event.eventType == TwinEventType.removed &&
              event.printerSerial == 'PRINTER-B',
        ),
        isTrue,
      );
    });
  });
}

Future<bool> _waitForQueueStatus(
  PrintQueueDao dao,
  String serial,
  PrintQueueStatus expected,
) async {
  for (var i = 0; i < 50; i++) {
    final items = await dao.getByPrinter(serial, includeCancelled: true);
    if (items.any((item) => item.status == expected)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return false;
}

Future<bool> _waitForSchedulerStatus(
  SchedulerDao dao,
  int taskId,
  SchedulerTaskStatus expected,
) async {
  for (var i = 0; i < 50; i++) {
    if ((await dao.getById(taskId))?.status == expected) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return false;
}

Future<bool> _waitForPrintTaskStatus(
  PrintTaskDao dao,
  PrintTaskStatus expected,
) async {
  for (var i = 0; i < 150; i++) {
    final tasks = await dao.getAll();
    if (tasks.any((task) => task.status == expected)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return false;
}

Future<bool> _waitForPresetResult(PresetResultDao dao, int taskId) async {
  for (var i = 0; i < 150; i++) {
    if (await dao.getByTaskId(taskId) != null) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return false;
}

class _FakePrinterConnector implements PrinterConnector {
  _FakePrinterConnector(this.config);

  final PrinterConnectionConfig config;
  final _statusController = StreamController<BambuPrinterStatus>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _connectionController =
      StreamController<PrinterConnectionState>.broadcast();
  final List<String> sentPaths = [];
  final List<int> sentPlateIndices = [];
  final List<List<int>?> sentAmsMappings = [];

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Stream<BambuPrinterStatus> get statusStream => _statusController.stream;

  @override
  Stream<String> get errorStream => _errorController.stream;

  @override
  Stream<PrinterConnectionState> get connectionStateStream =>
      _connectionController.stream;

  @override
  Future<bool> connect() async {
    _connected = true;
    _connectionController.add(PrinterConnectionState.connected);
    emitStatus(BambuGcodeState.idle);
    return true;
  }

  void emitStatus(
    BambuGcodeState state, {
    String? gcodeFile,
    int? mcPercent,
    int? currLayer,
    int? totalLayers,
  }) {
    _statusController.add(
      BambuPrinterStatus(
        serial: config.serial,
        gcodeState: state,
        gcodeFile: gcodeFile,
        mcPercent: mcPercent,
        currLayer: currLayer,
        totalLayers: totalLayers,
        amsTrays: const [
          AmsTray(amsId: 0, slot: 0, hasFilament: true),
          AmsTray(amsId: 0, slot: 1, hasFilament: true),
        ],
      ),
    );
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    if (!_connectionController.isClosed) {
      _connectionController.add(PrinterConnectionState.disconnected);
    }
  }

  @override
  Future<void> requestStatus() async {}

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> stop() async => true;

  @override
  Future<bool> setSpeed(int speed) async => true;

  @override
  Future<bool> sendPrintTask(
    String filePath, {
    List<int>? amsMapping,
    int plateIndex = 1,
  }) async {
    sentPaths.add(filePath);
    sentPlateIndices.add(plateIndex);
    sentAmsMappings.add(
      amsMapping == null ? null : List<int>.unmodifiable(amsMapping),
    );
    return true;
  }

  @override
  Future<void> dispose() async {
    await _statusController.close();
    await _errorController.close();
    await _connectionController.close();
  }
}

Future<File> _writeQueueGcode(
  Directory directory, {
  required String filename,
  required String printerSettingsId,
  String? amsMapping = '[1,0]',
}) async {
  final file = File('${directory.path}/$filename');
  await file.writeAsString('''
; HEADER_BLOCK_START
; BambuStudio 02.07.01.57
; total filament weight [g] : 12.5,4.0
; total filament length [mm] : 4020,1200
; total layer number: 20
; total estimated time: 12m 5s
; HEADER_BLOCK_END
; CONFIG_BLOCK_START
; print_settings_id = "0.20mm Standard"
; printer_settings_id = "$printerSettingsId"
; nozzle_diameter = [0.4]
; filament_type = PLA;PLA
${amsMapping == null ? '' : '; ams_mapping = $amsMapping'}
; CONFIG_BLOCK_END
G1 X0 Y0
''');
  return file;
}
