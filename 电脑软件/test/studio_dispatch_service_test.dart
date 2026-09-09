import 'package:consumable_tracker_desktop/core/services/studio_dispatch_service.dart';
import 'package:consumable_tracker_desktop/data/database/daos/print_queue_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/studio_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/print_queue_item.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late StudioDao studioDao;
  late PrintQueueDao queueDao;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    studioDao = StudioDao(database);
    queueDao = PrintQueueDao(database);
    await studioDao.ensureDefaultWorkspace();
  });

  tearDown(() async {
    studioDao.dispose();
    await database.close();
  });

  test('排产会原子拆分工单、预留耗材并写入打印队列', () async {
    final fixture = await _seedFixture(database, studioDao, runs: 2);
    final service = StudioDispatchService(
      database: database,
      studioDao: studioDao,
      printQueueDao: queueDao,
    );

    final result = await service.dispatchPlateRuns(
      fixture.request(runs: 2),
    );

    expect(result.workOrderIds, hasLength(2));
    expect(result.queueIds, hasLength(2));
    final snapshot = await studioDao.getDefaultSnapshot();
    final plateOrders = snapshot.workOrders
        .where((item) => item.productionPlateId == fixture.plateId)
        .toList();
    expect(plateOrders, hasLength(2));
    expect(
      plateOrders.every((item) => item.printerId == fixture.printerId),
      isTrue,
    );
    expect(
      snapshot.workOrderMaterials
          .where((item) => result.workOrderIds.contains(item.workOrderId))
          .every((item) => item.isAllocated),
      isTrue,
    );
    final queue = await queueDao.getByPrinter(_DispatchFixture.serial);
    expect(queue, hasLength(2));
    expect(
      queue.every((item) => item.artifactSha256 == _DispatchFixture.sha256),
      isTrue,
    );
  });

  test('第二份队列写入失败会回滚工单拆分、耗材预留和全部队列行', () async {
    final fixture = await _seedFixture(database, studioDao, runs: 2);
    final failingQueueDao = _FailingSecondEnqueueDao(database);
    final service = StudioDispatchService(
      database: database,
      studioDao: studioDao,
      printQueueDao: failingQueueDao,
    );

    await expectLater(
      service.dispatchPlateRuns(fixture.request(runs: 2)),
      throwsA(isA<StateError>()),
    );

    final snapshot = await studioDao.getDefaultSnapshot();
    final plateOrders = snapshot.workOrders
        .where((item) => item.productionPlateId == fixture.plateId)
        .toList();
    expect(plateOrders, hasLength(1));
    expect(plateOrders.single.printerId, isNull);
    expect(plateOrders.single.quantity, 2);
    final materials = snapshot.workOrderMaterials
        .where((item) => item.workOrderId == plateOrders.single.id)
        .toList();
    expect(materials, hasLength(1));
    expect(materials.single.status, StudioWorkOrderMaterialStatus.unallocated);
    expect(materials.single.estimatedGrams, 50);
    expect(
      await queueDao.getByPrinter(
        _DispatchFixture.serial,
        includeCancelled: true,
      ),
      isEmpty,
    );
  });

  test('撤回未开始排产会取消队列、释放预留并恢复待排产数量', () async {
    final fixture = await _seedFixture(database, studioDao, runs: 2);
    final service = StudioDispatchService(
      database: database,
      studioDao: studioDao,
      printQueueDao: queueDao,
    );
    final result = await service.dispatchPlateRuns(fixture.request(runs: 1));

    await service.withdrawAssignedRun(result.workOrderIds.single);

    final snapshot = await studioDao.getDefaultSnapshot();
    final plateOrders = snapshot.workOrders
        .where((item) => item.productionPlateId == fixture.plateId)
        .toList();
    final cancelled = plateOrders.singleWhere(
      (item) => item.id == result.workOrderIds.single,
    );
    final remainder = plateOrders.singleWhere((item) => item.printerId == null);
    expect(cancelled.status, StudioWorkOrderStatus.cancelled);
    expect(remainder.quantity, 2);
    expect(remainder.status, StudioWorkOrderStatus.queued);

    final cancelledMaterials = snapshot.workOrderMaterials
        .where((item) => item.workOrderId == cancelled.id)
        .toList();
    expect(cancelledMaterials, hasLength(1));
    expect(cancelledMaterials.single.reservedGrams, 0);
    expect(
      cancelledMaterials.single.status,
      StudioWorkOrderMaterialStatus.released,
    );
    final remainderMaterials = snapshot.workOrderMaterials
        .where((item) => item.workOrderId == remainder.id)
        .toList();
    expect(remainderMaterials.single.estimatedGrams, 50);
    expect(
      remainderMaterials.single.status,
      StudioWorkOrderMaterialStatus.unallocated,
    );

    final queue = await queueDao.getByPrinter(
      _DispatchFixture.serial,
      includeCancelled: true,
    );
    expect(queue, hasLength(1));
    expect(queue.single.status, PrintQueueStatus.cancelled);
  });

  test('已有排产工单时拒绝重新切片并保留原产物', () async {
    final fixture = await _seedFixture(database, studioDao, runs: 1);
    final service = StudioDispatchService(
      database: database,
      studioDao: studioDao,
      printQueueDao: queueDao,
    );
    await service.dispatchPlateRuns(fixture.request(runs: 1));

    await expectLater(
      studioDao.updateProductionPlateSlice(
        id: fixture.plateId,
        status: StudioPlateSliceStatus.slicing,
      ),
      throwsA(isA<StateError>()),
    );

    final plate = (await studioDao.getDefaultSnapshot())
        .productionPlates
        .singleWhere((item) => item.id == fixture.plateId);
    expect(plate.sliceStatus, StudioPlateSliceStatus.sliced);
    expect(plate.sliceArtifactSha256, _DispatchFixture.sha256);
  });
}

class _DispatchFixture {
  const _DispatchFixture({
    required this.plateId,
    required this.printerId,
    required this.channelId,
    required this.consumableId,
  });

  static const serial = 'A1-DISPATCH-TEST';
  static const sha256 =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  final String plateId;
  final int printerId;
  final int channelId;
  final int consumableId;

  StudioPlateDispatchRequest request({required int runs}) {
    return StudioPlateDispatchRequest(
      productionPlateId: plateId,
      printerId: printerId,
      printerSerial: serial,
      runs: runs,
      gcodePath: 'C:/fixtures/dispatch.3mf',
      filename: 'dispatch.3mf',
      artifactSha256: sha256,
      consumableByTool: {0: consumableId},
      printerChannelByTool: {0: channelId},
      amsMapping: const [0],
    );
  }
}

Future<_DispatchFixture> _seedFixture(
  AppDatabase database,
  StudioDao studioDao, {
  required int runs,
}) async {
  final now = DateTime.now();
  final workspace = (await studioDao.getDefaultSnapshot()).workspace;
  final consumableId = await database.consumableDao.addFarmConsumable(
    ConsumablesCompanion.insert(
      uid: const Value('dispatch-spool'),
      manufacturer: 'Bambu Lab',
      model: 'PLA Basic',
      materialType: const Value('PLA'),
      colorHex: const Value('#FFFFFF'),
      totalGrams: const Value(2000),
      remainingGrams: const Value(2000),
      createdAt: Value(now),
      updatedAt: Value(now),
    ),
    workspaceId: workspace.id,
  );
  final printerId = await database.printerDao.addPrinter(
    brand: 'Bambu Lab',
    model: 'A1',
    channelCount: 1,
  );
  final printer = await database.printerDao.getByIdWithChannels(printerId);
  final channelId = printer!.channels.single.channel.id;
  await database.printerDao.bindConsumable(
    channelId,
    consumableId,
    farmLoadAuthorization: FarmRollLoadAuthorization.farmOwnerConfirmed,
  );
  await studioDao.addProductionOrder(
    workspaceId: workspace.id,
    orderNo: 'SO-DISPATCH-TEST',
    title: '原子排产测试',
    packages: [
      StudioProductionPackageDraft(
        sourceName: 'dispatch.3mf',
        localPath: 'C:/fixtures/source.3mf',
        artifactKind: 'bambu3mf',
        plates: [
          StudioProductionPlateDraft(
            plateIndex: 1,
            name: '测试盘',
            requiredRuns: runs,
            estimatedSeconds: 600,
            estimatedGrams: 25,
            sliceStatus: StudioPlateSliceStatus.sliced,
            sliceArtifactPath: 'C:/fixtures/dispatch.3mf',
            sliceArtifactSha256: _DispatchFixture.sha256,
            filaments: const [
              StudioPlateFilamentUsage(
                toolIndex: 0,
                grams: 25,
                materialType: 'PLA',
                colorHex: '#FFFFFF',
              ),
            ],
            items: [
              StudioOrderItemDraft(
                sourceKey: 'part-1',
                name: '测试件',
                perRunQuantity: 1,
                requiredQuantity: runs,
              ),
            ],
          ),
        ],
      ),
    ],
  );
  final snapshot = await studioDao.getDefaultSnapshot();
  return _DispatchFixture(
    plateId: snapshot.productionPlates.single.id,
    printerId: printerId,
    channelId: channelId,
    consumableId: consumableId,
  );
}

class _FailingSecondEnqueueDao extends PrintQueueDao {
  _FailingSecondEnqueueDao(super.database);

  var _enqueueCount = 0;

  @override
  Future<int> enqueue(PrintQueueItem item, {bool notify = true}) async {
    _enqueueCount += 1;
    if (_enqueueCount == 2) {
      throw StateError('simulated second queue insert failure');
    }
    return super.enqueue(item, notify: notify);
  }
}
