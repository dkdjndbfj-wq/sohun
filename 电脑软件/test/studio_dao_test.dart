import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/studio_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late StudioDao dao;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dao = StudioDao(database);
    await dao.ensureDefaultWorkspace();
  });

  tearDown(() async {
    dao.dispose();
    await database.close();
  });

  test('工作室订单、工单、报价和库存流水形成完整本地闭环', () async {
    final now = DateTime.now();
    var snapshot = await dao.getDefaultSnapshot();
    final consumableId = await database.consumableDao.addFarmConsumable(
      ConsumablesCompanion.insert(
        uid: const Value('studio-spool-1'),
        manufacturer: 'Bambu Lab',
        model: 'PLA Basic',
        materialType: const Value('PLA'),
        colorHex: const Value('#00B42A'),
        totalGrams: const Value(1000),
        remainingGrams: const Value(1000),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      workspaceId: snapshot.workspace.id,
    );
    final customerId = await dao.addCustomer(
      workspaceId: snapshot.workspace.id,
      name: '测试客户',
      phone: '13800000000',
    );
    final orderId = await dao.addOrder(
      workspaceId: snapshot.workspace.id,
      orderNo: 'SO-TEST-1',
      title: '测试批次',
      customerId: customerId,
      totalPrice: 120,
    );
    final workOrderId = await dao.addWorkOrder(
      workspaceId: snapshot.workspace.id,
      orderId: orderId,
      title: '主体打印',
      quantity: 2,
      materialCostSnapshot: 12,
      quotedPriceSnapshot: 120,
    );
    await dao.updateWorkOrderProgress(
      id: workOrderId,
      completedQuantity: 2,
      status: StudioWorkOrderStatus.completed,
    );

    await dao.addQuote(
      StudioQuote(
        id: 'quote-test-1',
        workspaceId: snapshot.workspace.id,
        customerId: customerId,
        quoteNo: 'QT-TEST-1',
        title: '正式报价',
        status: StudioQuoteStatus.accepted,
        materialLabel: 'Bambu Lab · PLA',
        estimatedGrams: 250,
        materialCostPerKgSnapshot: 80,
        machineHours: 2,
        machineRatePerHour: 5,
        laborHours: 0.5,
        laborRatePerHour: 30,
        electricityCost: 2,
        packagingCost: 3,
        riskPercent: 10,
        markupPercent: 30,
        totalCost: 55,
        quotedPrice: 71.5,
        createdAt: now,
        updatedAt: now,
      ),
    );

    final actual = await dao.adjustInventory(
      workspaceId: snapshot.workspace.id,
      consumableId: consumableId,
      deltaGrams: -250,
      type: StudioInventoryEventType.consume,
      reason: '工单领用',
    );
    expect(actual, -250);

    snapshot = await dao.getDefaultSnapshot();
    expect(snapshot.customers.single.name, '测试客户');
    expect(snapshot.orders.single.status, StudioOrderStatus.completed);
    expect(snapshot.workOrders.single.completion, 1);
    expect(snapshot.acceptedRevenue, 71.5);
    expect(snapshot.acceptedProfit, 16.5);
    expect(snapshot.inventoryEvents.single.deltaGrams, -250);
    expect(
      (await database.consumableDao.getById(consumableId))!.remainingGrams,
      750,
    );
  });

  test('成员写入会在业务对象旁保留操作者、时间和动作', () async {
    dao.dispose();
    dao = StudioDao(
      database,
      actor: const StudioActivityActor(
        memberId: 'member-activity-1',
        displayName: '成员甲',
        identity: 'member',
      ),
    );
    final snapshot = await dao.getDefaultSnapshot();
    final orderId = await dao.addOrder(
      workspaceId: snapshot.workspace.id,
      orderNo: 'SO-ACTIVITY-1',
      title: '操作记录测试',
    );

    final updated = await dao.getDefaultSnapshot();
    final event = updated.latestActivityFor('order', orderId);
    expect(event == null, isFalse);
    expect(event!.actorMemberId, 'member-activity-1');
    expect(event.actorDisplayName, '成员甲');
    expect(event.actorIdentity, 'member');
    expect(event.actionCode, 'order.created');
    expect(event.summary, contains('SO-ACTIVITY-1'));
  });

  test('删除成员只停用账号，成员快照和审计历史不可删除', () async {
    final snapshot = await dao.getDefaultSnapshot();
    final memberId = await dao.addMember(
      workspaceId: snapshot.workspace.id,
      displayName: '待移除成员',
      loginName: 'removed-member',
    );
    await dao.removeMemberPreservingHistory(memberId);

    final removed = (await dao.getDefaultSnapshot())
        .members
        .singleWhere((item) => item.id == memberId);
    expect(removed.active, isFalse);
    expect(removed.accountStatus, 'removed');
    final history = (await dao.getDefaultSnapshot())
        .activityEvents
        .where((item) => item.entityId == memberId)
        .toList();
    expect(history.map((item) => item.actionCode), contains('member.created'));
    expect(history.map((item) => item.actionCode), contains('member.removed'));

    expect(
      () => database.customStatement(
        'DELETE FROM studio_activity_events',
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('打印队列推进农场工单，自动取件按切片估算完成结算', () async {
    final snapshot = await dao.getDefaultSnapshot();
    final orderId = await dao.addOrder(
      workspaceId: snapshot.workspace.id,
      orderNo: 'SO-QUEUE-1',
      title: '连续生产测试',
    );
    final workOrderId = await dao.addWorkOrder(
      workspaceId: snapshot.workspace.id,
      orderId: orderId,
      title: '第 1 盘',
      quantity: 3,
      materialCostSnapshot: 0,
      quotedPriceSnapshot: 0,
    );

    await dao.updateWorkOrderQueueStatus(
      workOrderId,
      StudioWorkOrderStatus.assigned,
    );
    await dao.updateWorkOrderQueueStatus(
      workOrderId,
      StudioWorkOrderStatus.printing,
    );
    await dao.completeWorkOrderUsingEstimate(workOrderId);
    await dao.completeWorkOrderUsingEstimate(workOrderId);

    final completed = (await dao.getDefaultSnapshot())
        .workOrders
        .singleWhere((item) => item.id == workOrderId);
    expect(completed.status, StudioWorkOrderStatus.completed);
    expect(completed.completedQuantity, 3);
  });

  test('打印失败按进度计入损耗成本，重试和完成不会重复扣料', () async {
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    await dao.receiveInventoryBatch(
      workspaceId: workspace.id,
      batchNo: 'IN-FAIL-LOSS',
      receivedAt: DateTime.now(),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Bambu Lab',
          model: 'PLA Basic',
          materialType: 'PLA',
          colorHex: '#FFFFFF',
          rolls: 1,
          unitCost: 100,
        ),
      ],
    );
    final stock = (await database.consumableDao.getFarm(workspace.id)).single;
    final orderId = await dao.addProductionOrder(
      workspaceId: workspace.id,
      orderNo: 'SO-FAIL-LOSS',
      title: '失败重试成本',
      packages: const [
        StudioProductionPackageDraft(
          sourceName: 'failed-print.3mf',
          artifactKind: 'bambu3mf',
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 1,
              name: '失败后重打',
              requiredRuns: 1,
              estimatedSeconds: 300,
              estimatedGrams: 100,
              sliceStatus: StudioPlateSliceStatus.sliced,
              filaments: [
                StudioPlateFilamentUsage(
                  toolIndex: 0,
                  grams: 100,
                  materialType: 'PLA',
                  colorHex: '#FFFFFF',
                ),
              ],
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
    final workOrder = (await dao.getDefaultSnapshot())
        .workOrders
        .singleWhere((item) => item.orderId == orderId);
    await dao.reserveWorkOrderMaterials(
      workOrderId: workOrder.id,
      consumableByTool: {0: stock.id},
    );
    final printQueueId = await database.customInsert(
      'INSERT INTO print_queue '
      '(printer_serial, gcode_path, filename, status, sort_order, queued_at, '
      'attempt_no, studio_work_order_id) '
      "VALUES ('FARM-FAIL-1', 'failed-print.3mf', 'failed-print.3mf', "
      "'printing', 1, ?, 1, ?)",
      variables: [
        Variable(DateTime.now().millisecondsSinceEpoch),
        Variable(workOrder.id),
      ],
    );

    final firstLoss = await dao.recordFailedWorkOrderAttemptUsingEstimate(
      id: workOrder.id,
      printQueueId: printQueueId,
      attemptNo: 1,
      progressPercent: 40,
    );
    expect(firstLoss, closeTo(40, .001));
    expect((await database.consumableDao.getById(stock.id))!.remainingGrams,
        closeTo(960, .001));
    var snapshot = await dao.getDefaultSnapshot();
    var failed =
        snapshot.workOrders.singleWhere((item) => item.id == workOrder.id);
    expect(failed.status, StudioWorkOrderStatus.failed);
    expect(failed.materialCostSnapshot, closeTo(4, .001));
    expect(
      snapshot.workOrderMaterials
          .singleWhere((item) => item.workOrderId == workOrder.id)
          .consumedGrams,
      closeTo(40, .001),
    );

    final duplicateLoss = await dao.recordFailedWorkOrderAttemptUsingEstimate(
      id: workOrder.id,
      printQueueId: printQueueId,
      attemptNo: 1,
      progressPercent: 90,
    );
    expect(duplicateLoss, closeTo(40, .001));
    expect((await database.consumableDao.getById(stock.id))!.remainingGrams,
        closeTo(960, .001));

    final secondLoss = await dao.recordFailedWorkOrderAttemptUsingEstimate(
      id: workOrder.id,
      printQueueId: printQueueId,
      attemptNo: 2,
      progressPercent: 20,
    );
    expect(secondLoss, closeTo(20, .001));
    expect((await database.consumableDao.getById(stock.id))!.remainingGrams,
        closeTo(940, .001));

    await dao.validateWorkOrderRetry(workOrder.id);
    await dao.completeWorkOrderUsingEstimate(workOrder.id);
    snapshot = await dao.getDefaultSnapshot();
    failed = snapshot.workOrders.singleWhere((item) => item.id == workOrder.id);
    expect(failed.status, StudioWorkOrderStatus.completed);
    expect(failed.materialCostSnapshot, closeTo(16, .001));
    expect((await database.consumableDao.getById(stock.id))!.remainingGrams,
        closeTo(840, .001));
    expect(
      snapshot.workOrderMaterials
          .singleWhere((item) => item.workOrderId == workOrder.id)
          .consumedGrams,
      closeTo(160, .001),
    );
    expect(
      snapshot.inventoryEvents
          .where((event) => event.reason.contains('打印失败'))
          .length,
      2,
    );
    expect(snapshot.printAttempts, hasLength(2));

    final reserved = await dao.rejectCompletedWorkOrderForQuality(
      id: workOrder.id,
      printQueueId: printQueueId,
      attemptNo: 3,
      reason: '翘边报废',
    );
    expect(reserved, isTrue);
    snapshot = await dao.getDefaultSnapshot();
    final reopened =
        snapshot.workOrders.singleWhere((item) => item.id == workOrder.id);
    expect(reopened.status, StudioWorkOrderStatus.failed);
    expect(reopened.completedQuantity, 0);
    expect(reopened.materialCostSnapshot, closeTo(16, .001));
    expect(snapshot.orders.single.status, StudioOrderStatus.production);
    expect(snapshot.workOrderMaterials.single.isAllocated, isTrue);
    expect(
      snapshot.printAttempts
          .where((item) =>
              item.outcome == StudioPrintAttemptOutcome.qualityRejected)
          .length,
      1,
    );
  });

  test('远端较新的记录合并，本地较新的记录不被覆盖', () async {
    final snapshot = await dao.getDefaultSnapshot();
    final old = DateTime.now().subtract(const Duration(hours: 2));
    final customerId = await dao.addCustomer(
      workspaceId: snapshot.workspace.id,
      name: '本地客户',
    );
    final orderId = await dao.addOrder(
      workspaceId: snapshot.workspace.id,
      orderNo: 'SO-MERGE',
      title: '本地新标题',
      customerId: customerId,
    );

    await dao.mergeRemoteSnapshot({
      'orders': [
        {
          'id': orderId,
          'customerId': customerId,
          'orderNo': 'SO-MERGE',
          'title': '远端旧标题',
          'status': 'confirmed',
          'createdAt': old.toUtc().toIso8601String(),
          'updatedAt': old.toUtc().toIso8601String(),
        },
      ],
    });
    expect((await dao.getDefaultSnapshot()).orders.single.title, '本地新标题');

    final newer = DateTime.now().add(const Duration(hours: 1));
    await dao.mergeRemoteSnapshot({
      'orders': [
        {
          'id': orderId,
          'customerId': customerId,
          'orderNo': 'SO-MERGE',
          'title': '远端新标题',
          'status': 'production',
          'createdAt': old.toUtc().toIso8601String(),
          'updatedAt': newer.toUtc().toIso8601String(),
        },
      ],
    });
    final merged = (await dao.getDefaultSnapshot()).orders.single;
    expect(merged.title, '远端新标题');
    expect(merged.status, StudioOrderStatus.production);
  });

  test('远端成员按邮箱合并并同步停用状态，不创建重复成员', () async {
    final snapshot = await dao.getDefaultSnapshot();
    final localId = await dao.addMember(
      workspaceId: snapshot.workspace.id,
      displayName: '本地操作员',
      email: 'operator@example.com',
    );

    await dao.mergeRemoteMembers([
      {
        'id': 'remote-member-id',
        'email': 'OPERATOR@example.com',
        'displayName': '云端操作员',
        'role': 'operator',
        'primaryRoleCode': 'slicer',
        'roleCodes': ['slicer', 'inventory_manager'],
        'active': false,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      },
    ]);

    final members = (await dao.getDefaultSnapshot())
        .members
        .where(
          (member) => member.email?.toLowerCase() == 'operator@example.com',
        )
        .toList();
    expect(members, hasLength(1));
    expect(members.single.id, localId);
    expect(members.single.displayName, '云端操作员');
    expect(members.single.active, isFalse);
    expect(members.single.primaryRoleCode, 'member');
    expect(members.single.roleCodes, ['member']);
  });

  test('云端生产盘合并后保留完整多色耗材元数据', () async {
    final createdAt = DateTime.now().toUtc().toIso8601String();
    await dao.mergeRemoteSnapshot({
      'orders': [
        {
          'id': 'remote-order',
          'orderNo': 'SO-REMOTE-COLOR',
          'title': '远端多色订单',
          'status': 'production',
          'createdAt': createdAt,
          'updatedAt': createdAt,
        },
      ],
      'productionPackages': [
        {
          'id': 'remote-package',
          'orderId': 'remote-order',
          'sourceName': 'remote-project',
          'artifactKind': 'bambu3mf',
          'createdAt': createdAt,
        },
      ],
      'productionPlates': [
        {
          'id': 'remote-plate',
          'orderId': 'remote-order',
          'packageId': 'remote-package',
          'plateIndex': 8,
          'name': '左多色配件',
          'requiredRuns': 2,
          'estimatedSeconds': 6335,
          'estimatedGrams': 38.97,
          'sliceStatus': 'sliced',
          'totalLayers': 327,
          'toolChangeCount': 4,
          'createdAt': createdAt,
          'filaments': [
            {
              'toolIndex': 0,
              'grams': 22.73,
              'materialType': 'PETG',
              'colorHex': '#F7D959',
              'trayId': 0,
              'sku': 'GFG00',
              'usedForObject': true,
              'usedForSupport': false,
              'groupId': 0,
              'nozzleDiameter': 0.4,
              'volumeType': 'Standard',
            },
            {
              'toolIndex': 2,
              'grams': 16.24,
              'materialType': 'PETG',
              'colorHex': '#FFFFFF',
              'usedForObject': true,
              'usedForSupport': true,
            },
          ],
        },
      ],
    });

    final plate = (await dao.getDefaultSnapshot()).productionPlates.single;
    expect(plate.isMulticolor, isTrue);
    expect(plate.toolChangeCount, 4);
    expect(plate.totalRequiredGrams, closeTo(77.94, 0.001));
    expect(plate.filaments.first.sku, 'GFG00');
    expect(plate.filaments.first.trayId, 0);
    expect(plate.filaments.first.usedForObject, isTrue);
    expect(plate.filaments.last.usedForSupport, isTrue);
    expect(plate.filaments.first.nozzleDiameter, 0.4);
  });

  test('农场批量入库将同款多卷聚合为一行，并固定每卷 1000g', () async {
    final snapshot = await dao.getDefaultSnapshot();
    final receivedAt = DateTime(2026, 8, 3);

    await dao.receiveInventoryBatch(
      workspaceId: snapshot.workspace.id,
      batchNo: 'IN-TEST-001',
      supplier: '测试供应商',
      receivedAt: receivedAt,
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Bambu Lab',
          model: 'PLA Basic',
          materialType: 'PLA',
          colorHex: '#00B42A',
          colorName: '绿色',
          rolls: 3,
          gramsPerRoll: 1000,
          unitCost: 89,
        ),
        StudioBatchReceiveLine(
          manufacturer: 'eSUN',
          model: 'eSUN PETG',
          materialType: 'PETG',
          colorHex: '#FFFFFF',
          rolls: 2,
          gramsPerRoll: 1000,
          unitCost: 72,
        ),
      ],
    );

    final consumables = await database.consumableDao.getAll();
    expect(consumables, hasLength(2));
    expect(consumables.every((item) => item.batchNo == 'IN-TEST-001'), isTrue);
    expect(consumables.where((item) => item.totalGrams == 3000), hasLength(1));
    expect(consumables.where((item) => item.totalGrams == 2000), hasLength(1));
    expect(
      consumables.where((item) => item.model == 'PLA Basic'),
      hasLength(1),
    );
    expect(
      consumables.every((item) => item.remainingGrams == item.totalGrams),
      isTrue,
    );

    final updated = await dao.getDefaultSnapshot();
    expect(updated.inventoryBatches, hasLength(1));
    expect(updated.inventoryBatches.single.rollCount, 5);
    expect(updated.inventoryBatches.single.totalGrams, 5000);
    expect(updated.inventoryEvents, hasLength(2));

    await expectLater(
      dao.receiveInventoryBatch(
        workspaceId: snapshot.workspace.id,
        batchNo: 'IN-INVALID',
        receivedAt: receivedAt,
        lines: const [
          StudioBatchReceiveLine(
            manufacturer: '测试厂商',
            materialType: 'PLA',
            colorHex: '#000000',
            rolls: 1,
            gramsPerRoll: 999,
          ),
        ],
      ),
      throwsArgumentError,
    );
    expect(await database.consumableDao.getAll(), hasLength(2));
  });

  test('库存卷数量只能按入库批次调整，并固定按每卷 1000g 联动余量', () async {
    final snapshot = await dao.getDefaultSnapshot();
    final batchId = await dao.receiveInventoryBatch(
      workspaceId: snapshot.workspace.id,
      batchNo: 'IN-ROLL-COUNT',
      receivedAt: DateTime(2026, 8, 4, 15, 20),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Farm',
          model: 'PLA Basic',
          materialType: 'PLA',
          colorHex: '#FF0000',
          rolls: 3,
        ),
      ],
    );
    var updated = await dao.getDefaultSnapshot();
    final batchItem = updated.inventoryBatchItems.single;

    await dao.adjustInventory(
      workspaceId: snapshot.workspace.id,
      consumableId: batchItem.consumableId,
      deltaGrams: -250,
      type: StudioInventoryEventType.consume,
      reason: '测试消耗',
    );
    await dao.updateInventoryBatchRollCounts(
      batchId: batchId,
      workspaceId: snapshot.workspace.id,
      rollCountsByItem: {batchItem.id: 5},
    );

    updated = await dao.getDefaultSnapshot();
    expect(updated.inventoryBatches.single.rollCount, 5);
    expect(updated.inventoryBatches.single.totalGrams, 5000);
    expect(updated.inventoryBatchItems.single.rollCount, 5);
    expect(updated.inventoryBatchItems.single.gramsPerRoll, 1000);
    final consumable =
        await database.consumableDao.getById(batchItem.consumableId);
    expect(consumable!.totalGrams, 5000);
    expect(consumable.remainingGrams, 4750);
    expect(
      updated.inventoryEvents
          .firstWhere((event) => event.reason.contains('批次卷数调整'))
          .deltaGrams,
      2000,
    );

    await expectLater(
      dao.updateInventoryBatchRollCounts(
        batchId: batchId,
        workspaceId: snapshot.workspace.id,
        rollCountsByItem: {batchItem.id: 0},
      ),
      throwsArgumentError,
    );
  });

  test('入库批次可编辑编号、供应商、时间到分钟并同步库存批次号', () async {
    final snapshot = await dao.getDefaultSnapshot();
    final receivedAt = DateTime(2026, 8, 3, 9, 17);
    final batchId = await dao.receiveInventoryBatch(
      workspaceId: snapshot.workspace.id,
      batchNo: 'IN-OLD',
      receivedAt: receivedAt,
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Farm',
          materialType: 'PLA',
          colorHex: '#00B42A',
          rolls: 20,
        ),
      ],
    );

    await dao.updateInventoryBatch(
      id: batchId,
      workspaceId: snapshot.workspace.id,
      batchNo: 'IN-NEW',
      supplier: '新供应商',
      receivedAt: DateTime(2026, 8, 4, 14, 36),
      note: '已核对',
    );

    final updated = await dao.getDefaultSnapshot();
    expect(updated.inventoryBatches.single.batchNo, 'IN-NEW');
    expect(updated.inventoryBatches.single.supplier, '新供应商');
    expect(updated.inventoryBatches.single.receivedAt.minute, 36);
    final consumables = await database.consumableDao.getAll();
    expect(consumables, hasLength(1));
    expect(consumables.single.totalGrams, 20000);
    expect(consumables.single.batchNo, 'IN-NEW');
  });

  test('只有完全未使用的入库批次可以整批删除并记录操作', () async {
    final snapshot = await dao.getDefaultSnapshot();
    final batchId = await dao.receiveInventoryBatch(
      workspaceId: snapshot.workspace.id,
      batchNo: 'IN-DELETE-UNUSED',
      receivedAt: DateTime(2026, 8, 5, 10, 26),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Farm',
          model: 'PLA Basic',
          materialType: 'PLA',
          colorHex: '#00B42A',
          rolls: 3,
        ),
        StudioBatchReceiveLine(
          manufacturer: 'Farm',
          model: 'PETG HF',
          materialType: 'PETG',
          colorHex: '#FFFFFF',
          rolls: 2,
        ),
      ],
    );

    await dao.deleteInventoryBatch(
      batchId: batchId,
      workspaceId: snapshot.workspace.id,
    );

    final updated = await dao.getDefaultSnapshot();
    expect(updated.inventoryBatches, isEmpty);
    expect(updated.inventoryBatchItems, isEmpty);
    expect(
        await database.consumableDao.getFarm(snapshot.workspace.id), isEmpty);
    final activity = updated.latestActivityFor('inventory_batch', batchId);
    expect(activity?.actionCode, 'inventory.batch_deleted');
    expect(activity?.summary, contains('IN-DELETE-UNUSED'));
  });

  test('库存发生变化或被工单引用后禁止删除入库批次', () async {
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    final changedBatchId = await dao.receiveInventoryBatch(
      workspaceId: workspace.id,
      batchNo: 'IN-DELETE-CHANGED',
      receivedAt: DateTime(2026, 8, 5, 11),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Farm',
          materialType: 'PLA',
          colorHex: '#FF0000',
          rolls: 1,
        ),
      ],
    );
    var current = await dao.getDefaultSnapshot();
    final changedConsumableId = current.inventoryBatchItems
        .singleWhere((item) => item.batchId == changedBatchId)
        .consumableId;
    await dao.adjustInventory(
      workspaceId: workspace.id,
      consumableId: changedConsumableId,
      deltaGrams: -10,
      type: StudioInventoryEventType.consume,
      reason: '测试库存变化',
    );

    await expectLater(
      dao.deleteInventoryBatch(
        batchId: changedBatchId,
        workspaceId: workspace.id,
      ),
      throwsStateError,
    );

    final referencedBatchId = await dao.receiveInventoryBatch(
      workspaceId: workspace.id,
      batchNo: 'IN-DELETE-REFERENCED',
      receivedAt: DateTime(2026, 8, 5, 11, 30),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Farm',
          materialType: 'PETG',
          colorHex: '#FFFFFF',
          rolls: 1,
        ),
      ],
    );
    current = await dao.getDefaultSnapshot();
    final referencedConsumableId = current.inventoryBatchItems
        .singleWhere((item) => item.batchId == referencedBatchId)
        .consumableId;
    await dao.addProductionOrder(
      workspaceId: workspace.id,
      orderNo: 'SO-BATCH-REFERENCE',
      title: '批次引用保护',
      packages: const [
        StudioProductionPackageDraft(
          sourceName: 'reference.3mf',
          artifactKind: 'bambu3mf',
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 1,
              name: '引用测试盘',
              requiredRuns: 1,
              estimatedSeconds: 300,
              estimatedGrams: 20,
              sliceStatus: StudioPlateSliceStatus.sliced,
              filaments: [
                StudioPlateFilamentUsage(
                  toolIndex: 0,
                  grams: 20,
                  materialType: 'PETG',
                  colorHex: '#FFFFFF',
                ),
              ],
              items: [],
            ),
          ],
        ),
      ],
    );
    final workOrder = (await dao.getDefaultSnapshot())
        .workOrders
        .singleWhere((item) => item.title == '引用测试盘');
    await dao.reserveWorkOrderMaterials(
      workOrderId: workOrder.id,
      consumableByTool: {0: referencedConsumableId},
    );

    await expectLater(
      dao.deleteInventoryBatch(
        batchId: referencedBatchId,
        workspaceId: workspace.id,
      ),
      throwsStateError,
    );
    expect(
      (await dao.getDefaultSnapshot()).inventoryBatches,
      hasLength(2),
    );
  });

  test('农场槽位装新卷从 1000g 开始，并按槽位余量阻止超额排队', () async {
    final snapshot = await dao.getDefaultSnapshot();
    await dao.receiveInventoryBatch(
      workspaceId: snapshot.workspace.id,
      batchNo: 'IN-SLOT-CAPACITY',
      receivedAt: DateTime(2026, 8, 4, 16, 20),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Farm PLA',
          materialType: 'PLA',
          colorHex: '#FFFFFF',
          rolls: 2,
        ),
      ],
    );
    final consumable = (await database.consumableDao.getAll()).single;
    final printerId = await database.printerDao.addPrinter(
      brand: 'Bambu Lab',
      model: 'A1',
      channelCount: 1,
    );
    final channel = (await database.printerDao.getByIdWithChannels(printerId))!
        .channels
        .single;
    await expectLater(
      database.printerDao.bindConsumable(
        channel.channel.id,
        consumable.id,
      ),
      throwsStateError,
      reason: '没有 RFID 的第三方料必须先让农场主确认，不能静默扣库',
    );
    expect(
      (await database.consumableDao.getById(consumable.id))!.remainingGrams,
      2000,
    );
    await database.printerDao.bindConsumable(
      channel.channel.id,
      consumable.id,
      farmLoadAuthorization: FarmRollLoadAuthorization.farmOwnerConfirmed,
    );
    final loaded = (await database.printerDao.getByIdWithChannels(printerId))!
        .channels
        .single;
    expect(loaded.channel.loadedRemainingGrams, 1000);
    expect(
      (await database.consumableDao.getById(consumable.id))!.remainingGrams,
      1000,
      reason: '装机时仓库只扣一整卷',
    );

    await dao.addProductionOrder(
      workspaceId: snapshot.workspace.id,
      orderNo: 'SO-SLOT-CAPACITY',
      title: '槽位容量校验',
      packages: const [
        StudioProductionPackageDraft(
          sourceName: 'capacity.3mf',
          artifactKind: 'bambu3mf',
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 1,
              name: '白色大件',
              requiredRuns: 2,
              estimatedSeconds: 600,
              estimatedGrams: 600,
              sliceStatus: StudioPlateSliceStatus.sliced,
              sliceArtifactPath: 'C:/slices/capacity.3mf',
              filaments: [
                StudioPlateFilamentUsage(
                  toolIndex: 0,
                  grams: 600,
                  materialType: 'PLA',
                  colorHex: '#FFFFFF',
                ),
              ],
              items: [
                StudioOrderItemDraft(
                  sourceKey: 'object:white',
                  name: '白色大件',
                  perRunQuantity: 1,
                  requiredQuantity: 2,
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final plate = (await dao.getDefaultSnapshot()).productionPlates.single;
    final assigned = await dao.assignPlateRuns(
      productionPlateId: plate.id,
      printerId: printerId,
      runs: 2,
    );
    expect(assigned, hasLength(2));
    await dao.reserveWorkOrderMaterials(
      workOrderId: assigned.first,
      consumableByTool: {0: consumable.id},
      printerChannelByTool: {0: channel.channel.id},
    );
    expect(
      await dao.getPrinterChannelAvailableGrams(channel.channel.id),
      400,
    );
    await expectLater(
      dao.reserveWorkOrderMaterials(
        workOrderId: assigned.last,
        consumableByTool: {0: consumable.id},
        printerChannelByTool: {0: channel.channel.id},
      ),
      throwsStateError,
    );
    await dao.updateWorkOrderProgress(
      id: assigned.first,
      completedQuantity: 1,
      status: StudioWorkOrderStatus.completed,
    );
    final afterPrint =
        (await database.printerDao.getByIdWithChannels(printerId))!
            .channels
            .single;
    expect(afterPrint.channel.loadedRemainingGrams, 400);
    expect(
      (await database.consumableDao.getById(consumable.id))!.remainingGrams,
      1000,
      reason: '打印消耗只扣槽位独立料卷，不能再扣仓库',
    );

    await database.printerDao
        .pauseFarmChannelRollForMaintenance(channel.channel.id);
    var maintenance =
        (await database.printerDao.getByIdWithChannels(printerId))!
            .channels
            .single;
    expect(maintenance.farmRollPaused, isTrue);
    expect(maintenance.channel.loadedRemainingGrams, 400);
    expect(await dao.getPrinterChannelAvailableGrams(channel.channel.id), 0);
    await expectLater(
      database.printerDao.unbindChannel(channel.channel.id),
      throwsStateError,
    );

    await database.printerDao.resumeFarmChannelRoll(channel.channel.id);
    maintenance = (await database.printerDao.getByIdWithChannels(printerId))!
        .channels
        .single;
    expect(maintenance.farmRollPaused, isFalse);
    expect(maintenance.channel.loadedRemainingGrams, 400);
    expect(await dao.getPrinterChannelAvailableGrams(channel.channel.id), 400);

    await database.consumableDao.updateRfidSync(
      consumableId: consumable.id,
      remainingGrams: 123,
    );
    expect(
      (await database.consumableDao.getById(consumable.id))!.remainingGrams,
      1000,
      reason: 'RFID 单卷观测不能覆盖农场仓库整卷数',
    );
    await database.printerDao.syncFarmChannelLoadedRemaining(
      printerId: printerId,
      channelIndex: channel.channel.channelIndex,
      remainingGrams: 350,
      expectedConsumableId: consumable.id,
    );
    expect(
      (await database.printerDao.getByIdWithChannels(printerId))!
          .channels
          .single
          .channel
          .loadedRemainingGrams,
      350,
    );
    await database.printerDao.syncFarmChannelLoadedRemaining(
      printerId: printerId,
      channelIndex: channel.channel.channelIndex,
      remainingGrams: 30,
      expectedConsumableId: consumable.id,
    );
    await database.printerDao.pauseFarmChannelRollForMaintenance(
      channel.channel.id,
    );
    await expectLater(
      database.printerDao.resumeFarmChannelRoll(channel.channel.id),
      throwsStateError,
      reason: '农场槽位余量达到 30g 时不能继续使用',
    );
  });

  test('仓库最后一卷装机后仍由槽位独立使用，耗尽时不重复扣仓库', () async {
    final snapshot = await dao.getDefaultSnapshot();
    await dao.receiveInventoryBatch(
      workspaceId: snapshot.workspace.id,
      batchNo: 'IN-LAST-ROLL',
      receivedAt: DateTime(2026, 8, 4, 18),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Farm PETG',
          materialType: 'PETG',
          colorHex: '#111111',
          rolls: 1,
        ),
      ],
    );
    final consumable = (await database.consumableDao.getAll()).single;
    final printerId = await database.printerDao.addPrinter(
      brand: 'Bambu Lab',
      model: 'A1',
      channelCount: 1,
    );
    final channel = (await database.printerDao.getByIdWithChannels(printerId))!
        .channels
        .single;

    await database.printerDao.bindSpoolReplacement(
      printerId: printerId,
      channelIndex: channel.channel.channelIndex,
      consumableId: consumable.id,
      uniquePhysicalSpool: true,
    );
    var loaded = (await database.printerDao.getByIdWithChannels(printerId))!
        .channels
        .single;
    expect(
      (await database.consumableDao.getById(consumable.id))!.remainingGrams,
      0,
    );
    expect(loaded.channel.loadedRemainingGrams, 1000);
    expect(loaded.isActive, isTrue);

    await database.printerDao.finishChannel(channel.channel.id);
    loaded = (await database.printerDao.getByIdWithChannels(printerId))!
        .channels
        .single;
    expect(loaded.consumable, equals(null));
    expect(
      (await database.consumableDao.getById(consumable.id))!.remainingGrams,
      0,
      reason: '空卷在装机时已离开仓库，耗尽不能再次扣仓库',
    );
  });

  test('农场模式的拓竹 RFID 只匹配农场库存并自动扣一卷', () async {
    final snapshot = await dao.getDefaultSnapshot();
    await dao.receiveInventoryBatch(
      workspaceId: snapshot.workspace.id,
      batchNo: 'IN-RFID-FARM',
      receivedAt: DateTime(2026, 8, 5, 9),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Bambu Lab',
          model: 'GFA00',
          materialType: 'PLA',
          colorHex: '#33AAFF',
          rolls: 2,
        ),
      ],
    );
    final farmId =
        (await database.consumableDao.getFarm(snapshot.workspace.id)).single.id;
    final personalId = await database.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'Bambu Lab',
        model: 'GFA00',
        materialType: const Value('PLA'),
        colorHex: const Value('#33AAFF'),
        totalGrams: const Value(1000),
        remainingGrams: const Value(1000),
      ),
    );
    final printerId = await database.printerDao.addPrinter(
      brand: 'Bambu Lab',
      model: 'P1S',
      channelCount: 1,
    );

    await database.printerDao.syncChannelsFromAms(
      printerId,
      const [
        AmsTray(
          amsId: 0,
          slot: 0,
          trayUuid: 'farm-official-rfid',
          trayInfoIdx: 'GFA00',
          trayType: 'PLA',
          trayColor: '33AAFFFF',
          traySubBrands: 'Bambu Lab',
          trayWeight: 1000,
          remain: 84,
          hasFilament: true,
        ),
      ],
      farmMode: true,
      autoBindRfid: true,
      unbindEmpty: false,
    );

    expect(
      await database.printerDao.getConsumableIdByChannel(printerId, 0),
      farmId,
    );
    expect(
      (await database.consumableDao.getById(farmId))!.remainingGrams,
      1000,
      reason: '拓竹 RFID 自动装机后，农场仓库应从 2 卷扣为 1 卷',
    );
    expect(
      (await database.consumableDao.getById(personalId))!.remainingGrams,
      1000,
      reason: '农场 RFID 不能读取或扣减普通用户库存',
    );
    expect(
      (await database.printerDao.getByIdWithChannels(printerId))!
          .channels
          .single
          .channel
          .loadedRemainingGrams,
      840,
    );

    final secondPrinterId = await database.printerDao.addPrinter(
      brand: 'Bambu Lab',
      model: 'P1S',
      channelCount: 1,
    );
    await database.printerDao.syncChannelsFromAms(
      secondPrinterId,
      const [
        AmsTray(
          amsId: 0,
          slot: 0,
          trayUuid: 'farm-official-rfid',
          trayInfoIdx: 'GFA00',
          trayType: 'PLA',
          trayColor: '33AAFFFF',
          traySubBrands: 'Bambu Lab',
          trayWeight: 1000,
          remain: 80,
          hasFilament: true,
        ),
      ],
      farmMode: true,
      autoBindRfid: true,
      unbindEmpty: false,
    );
    expect(
      await database.printerDao.getConsumableIdByChannel(printerId, 0),
      equals(null),
      reason: '同一 RFID 卷移到另一台机器后，旧槽位必须解除',
    );
    expect(
      await database.printerDao.getConsumableIdByChannel(secondPrinterId, 0),
      farmId,
    );
    expect(
      (await database.consumableDao.getById(farmId))!.remainingGrams,
      1000,
      reason: 'RFID 跨槽移动只转移槽位余额，不能再扣一整卷仓库库存',
    );
  });

  test('切片生产包按盘建工单并把运行次数分摊到设备', () async {
    final snapshot = await dao.getDefaultSnapshot();
    final firstPrinter = await database.printerDao.addPrinter(
      brand: 'Bambu Lab',
      model: 'A1',
      channelCount: 1,
    );
    final secondPrinter = await database.printerDao.addPrinter(
      brand: 'Bambu Lab',
      model: 'A1',
      channelCount: 1,
    );

    final orderId = await dao.addProductionOrder(
      workspaceId: snapshot.workspace.id,
      orderNo: 'SO-SLICED-1',
      title: '多盘客户订单',
      packages: [
        StudioProductionPackageDraft(
          sourceName: 'customer-parts',
          localPath: r'C:\private\customer-parts.3mf',
          artifactSha256: 'local-only-hash',
          artifactKind: 'bambu3mf',
          targetModel: 'Bambu Lab A1',
          nozzleDiameter: 0.4,
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 1,
              name: '徽章盘',
              requiredRuns: 5,
              estimatedSeconds: 3600,
              estimatedGrams: 25,
              sliceStatus: StudioPlateSliceStatus.sliced,
              totalLayers: 120,
              toolChangeCount: 3,
              filaments: const [
                StudioPlateFilamentUsage(
                  toolIndex: 0,
                  grams: 15,
                  materialType: 'PLA',
                  colorHex: '#FFFFFF',
                  trayId: 0,
                  sku: 'GFA00',
                  usedForObject: true,
                  usedForSupport: false,
                  groupId: 0,
                  nozzleDiameter: 0.4,
                  volumeType: 'Standard',
                ),
                StudioPlateFilamentUsage(
                  toolIndex: 2,
                  grams: 10,
                  materialType: 'PLA',
                  colorHex: '#FFFFFF',
                  usedForObject: true,
                  usedForSupport: true,
                ),
              ],
              assignedPrinterIds: [firstPrinter, secondPrinter],
              items: const [
                StudioOrderItemDraft(
                  sourceKey: 'badge',
                  name: '徽章',
                  perRunQuantity: 2,
                  requiredQuantity: 9,
                ),
              ],
            ),
            const StudioProductionPlateDraft(
              plateIndex: 2,
              name: '底座盘',
              requiredRuns: 2,
              estimatedSeconds: 1800,
              estimatedGrams: 12,
              sliceStatus: StudioPlateSliceStatus.sliced,
              items: [
                StudioOrderItemDraft(
                  sourceKey: 'base',
                  name: '底座',
                  perRunQuantity: 1,
                  requiredQuantity: 2,
                ),
              ],
            ),
          ],
        ),
      ],
    );

    final result = await dao.getDefaultSnapshot();
    expect(result.orders.single.id, orderId);
    expect(result.orders.single.status, StudioOrderStatus.production);
    expect(result.productionPackages, hasLength(1));
    expect(
      result.productionPackages.single.localPath,
      contains('customer-parts.3mf'),
    );
    expect(result.productionPlates, hasLength(2));
    expect(result.orderItems, hasLength(2));
    expect(result.workOrders, hasLength(3));

    final plateOne =
        result.productionPlates.singleWhere((item) => item.plateIndex == 1);
    final allocated = result.workOrders
        .where((item) => item.productionPlateId == plateOne.id)
        .toList();
    expect(allocated, hasLength(2));
    expect(allocated.fold<int>(0, (sum, item) => sum + item.quantity), 5);
    expect(allocated.map((item) => item.quantity).toSet(), {2, 3});
    expect(plateOne.totalLayers, 120);
    expect(plateOne.toolChangeCount, 3);
    expect(plateOne.filaments, hasLength(2));
    expect(plateOne.isMulticolor, isTrue);
    expect(plateOne.totalRequiredGrams, 125);
    expect(plateOne.activeFilaments.map((item) => item.toolIndex), [0, 2]);
    expect(plateOne.filaments.first.materialType, 'PLA');
    expect(plateOne.filaments.first.trayId, 0);
    expect(plateOne.filaments.first.sku, 'GFA00');
    expect(plateOne.filaments.first.usedForObject, isTrue);
    expect(plateOne.filaments.first.usedForSupport, isFalse);
    expect(plateOne.filaments.first.groupId, 0);
    expect(plateOne.filaments.first.nozzleDiameter, 0.4);
    expect(plateOne.filaments.first.volumeType, 'Standard');
    expect(plateOne.filaments.last.usedForSupport, isTrue);
    expect(
      allocated.fold<int>(
        0,
        (sum, item) => sum + (item.estimatedSeconds ?? 0),
      ),
      3600 * 5,
    );

    final plateTwo =
        result.productionPlates.singleWhere((item) => item.plateIndex == 2);
    final unassigned = result.workOrders
        .singleWhere((item) => item.productionPlateId == plateTwo.id);
    expect(unassigned.printerId, equals(null));
    expect(unassigned.quantity, 2);
  });

  test('一个生产订单保存五个独立切片包，并拒绝第六个包', () async {
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    final packages = [
      for (var index = 1; index <= 5; index++)
        StudioProductionPackageDraft(
          sourceName: '切片包 $index',
          localPath: 'C:/fixtures/package-$index.3mf',
          artifactKind: 'bambu3mf',
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 1,
              name: '切片包 $index · 第 1 盘',
              requiredRuns: index,
              estimatedSeconds: 600,
              estimatedGrams: 10,
              sliceStatus: StudioPlateSliceStatus.sliced,
              items: [
                StudioOrderItemDraft(
                  sourceKey: 'package-$index-part',
                  name: '成品 $index',
                  perRunQuantity: 1,
                  requiredQuantity: index,
                ),
              ],
            ),
          ],
        ),
    ];

    final orderId = await dao.addProductionOrder(
      workspaceId: workspace.id,
      orderNo: 'SO-FIVE-PACKAGES',
      title: '五文件订单',
      packages: packages,
    );

    final snapshot = await dao.getDefaultSnapshot();
    expect(snapshot.orders.single.id, orderId);
    expect(snapshot.orders.single.customerId, equals(null));
    expect(snapshot.productionPackages, hasLength(5));
    expect(snapshot.productionPlates, hasLength(5));
    expect(snapshot.orderItems, hasLength(5));
    expect(snapshot.workOrders, hasLength(5));

    await expectLater(
      dao.addProductionOrder(
        workspaceId: workspace.id,
        orderNo: 'SO-SIX-PACKAGES',
        title: '六文件订单',
        packages: [...packages, packages.first],
      ),
      throwsArgumentError,
    );
    expect((await dao.getDefaultSnapshot()).orders, hasLength(1));
  });

  test('未切片盘随订单保存，单盘切完后才进入生产队列', () async {
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    await dao.addProductionOrder(
      workspaceId: workspace.id,
      orderNo: 'SO-DEFERRED-PLATE',
      title: '分批释放产能',
      packages: const [
        StudioProductionPackageDraft(
          sourceName: '多盘项目',
          localPath: 'C:/fixtures/multi.3mf',
          artifactKind: 'bambu3mf',
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 2,
              name: '第二盘',
              requiredRuns: 2,
              estimatedSeconds: 0,
              estimatedGrams: 0,
              items: [
                StudioOrderItemDraft(
                  sourceKey: 'object:2',
                  name: '底座',
                  perRunQuantity: 1,
                  requiredQuantity: 2,
                ),
              ],
            ),
          ],
        ),
      ],
    );

    var snapshot = await dao.getDefaultSnapshot();
    final plate = snapshot.productionPlates.single;
    expect(plate.sliceStatus, StudioPlateSliceStatus.pending);
    expect(plate.autoEjectEnabled, null);
    expect(
      snapshot.workOrders.single.status,
      StudioWorkOrderStatus.paused,
    );

    await dao.updateProductionPlateSlice(
      id: plate.id,
      status: StudioPlateSliceStatus.sliced,
      artifactPath: 'C:/slices/plate_2.3mf',
      artifactSha256: 'plate-2-hash',
      estimatedSeconds: 900,
      estimatedGrams: 8.5,
      totalLayers: 70,
      toolChangeCount: 1,
      filaments: const [
        StudioPlateFilamentUsage(
          toolIndex: 0,
          grams: 5,
          materialType: 'PETG',
          colorHex: '#F7D959',
        ),
        StudioPlateFilamentUsage(
          toolIndex: 2,
          grams: 3.5,
          materialType: 'PETG',
          colorHex: '#FFFFFF',
          usedForSupport: true,
        ),
      ],
    );

    snapshot = await dao.getDefaultSnapshot();
    expect(
      snapshot.productionPlates.single.sliceStatus,
      StudioPlateSliceStatus.sliced,
    );
    expect(
      snapshot.productionPlates.single.sliceArtifactPath,
      'C:/slices/plate_2.3mf',
    );
    expect(snapshot.productionPlates.single.autoEjectEnabled, isFalse);
    expect(snapshot.workOrders.single.status, StudioWorkOrderStatus.queued);
    expect(snapshot.workOrders.single.estimatedSeconds, 1800);
    expect(snapshot.productionPlates.single.isMulticolor, isTrue);

    await dao.updateProductionPlateSlice(
      id: plate.id,
      status: StudioPlateSliceStatus.sliced,
      artifactPath: 'C:/slices/plate_2_resliced.3mf',
      artifactSha256: 'plate-2-resliced-hash',
      estimatedSeconds: 850,
      estimatedGrams: 7,
      totalLayers: 68,
      toolChangeCount: 0,
      filaments: const [
        StudioPlateFilamentUsage(
          toolIndex: 0,
          grams: 7,
          materialType: 'PETG',
          colorHex: '#F7D959',
        ),
      ],
    );

    snapshot = await dao.getDefaultSnapshot();
    expect(snapshot.productionPlates.single.filaments, hasLength(1));
    expect(snapshot.productionPlates.single.isMulticolor, isFalse);
    expect(snapshot.productionPlates.single.estimatedGrams, 7);
    expect(snapshot.productionPlates.single.autoEjectEnabled, isFalse);
    expect(snapshot.workOrders.single.estimatedSeconds, 1700);
  });

  test('逐盘工单按分配运行次数生成逐色需求并原子预留库存', () async {
    final now = DateTime.now();
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    final yellowId = await database.consumableDao.addFarmConsumable(
      ConsumablesCompanion.insert(
        uid: const Value('studio-yellow'),
        manufacturer: 'Bambu Lab',
        model: 'PETG HF',
        materialType: const Value('PETG'),
        colorHex: const Value('#F7D959'),
        remainingGrams: const Value(100),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      workspaceId: workspace.id,
    );
    final whiteId = await database.consumableDao.addFarmConsumable(
      ConsumablesCompanion.insert(
        uid: const Value('studio-white'),
        manufacturer: 'Bambu Lab',
        model: 'PETG HF',
        materialType: const Value('PETG'),
        colorHex: const Value('#FFFFFF'),
        remainingGrams: const Value(100),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      workspaceId: workspace.id,
    );
    final printerA = await database.printerDao.addPrinter(
      brand: 'Bambu Lab',
      model: 'A1',
      channelCount: 4,
    );
    final printerB = await database.printerDao.addPrinter(
      brand: 'Bambu Lab',
      model: 'A1',
      channelCount: 4,
    );
    await dao.addProductionOrder(
      workspaceId: workspace.id,
      orderNo: 'SO-MATERIAL-SPLIT',
      title: '多色拆单',
      packages: [
        StudioProductionPackageDraft(
          sourceName: 'multi.3mf',
          artifactKind: 'bambu3mf',
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 8,
              name: '左多色配件',
              requiredRuns: 3,
              estimatedSeconds: 600,
              estimatedGrams: 30,
              sliceStatus: StudioPlateSliceStatus.sliced,
              assignedPrinterIds: [printerA, printerB],
              filaments: const [
                StudioPlateFilamentUsage(
                  toolIndex: 0,
                  grams: 18,
                  materialType: 'PETG',
                  colorHex: '#F7D959',
                ),
                StudioPlateFilamentUsage(
                  toolIndex: 2,
                  grams: 12,
                  materialType: 'PETG',
                  colorHex: '#FFFFFF',
                ),
              ],
              items: const [
                StudioOrderItemDraft(
                  sourceKey: 'part',
                  name: '配件',
                  perRunQuantity: 1,
                  requiredQuantity: 3,
                ),
              ],
            ),
          ],
        ),
      ],
    );

    var snapshot = await dao.getDefaultSnapshot();
    expect(snapshot.workOrders.map((item) => item.quantity).toSet(), {1, 2});
    expect(snapshot.workOrderMaterials, hasLength(4));
    final twoRun =
        snapshot.workOrders.singleWhere((item) => item.quantity == 2);
    final twoRunMaterials = snapshot.workOrderMaterials
        .where((item) => item.workOrderId == twoRun.id)
        .toList();
    expect(
      twoRunMaterials.singleWhere((item) => item.toolIndex == 0).estimatedGrams,
      36,
    );
    expect(
      twoRunMaterials.singleWhere((item) => item.toolIndex == 2).estimatedGrams,
      24,
    );

    await dao.reserveWorkOrderMaterials(
      workOrderId: twoRun.id,
      consumableByTool: {0: yellowId, 2: whiteId},
    );
    snapshot = await dao.getDefaultSnapshot();
    expect(
      snapshot.workOrderMaterials
          .where((item) => item.workOrderId == twoRun.id)
          .every((item) => item.isAllocated),
      isTrue,
    );
    expect(
      (await dao.getConsumableAvailability(
        yellowId,
        workspaceId: workspace.id,
      ))
          .availableGrams,
      64,
    );
    expect(
      (await database.consumableDao.getById(yellowId))!.remainingGrams,
      100,
      reason: '预留不能提前扣实际库存',
    );
  });

  test('完成工单按逐通道实际克数结算且重试不会重复扣减', () async {
    final now = DateTime.now();
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    final blackId = await database.consumableDao.addFarmConsumable(
      ConsumablesCompanion.insert(
        uid: const Value('studio-black'),
        manufacturer: 'Bambu Lab',
        model: 'PLA Basic',
        materialType: const Value('PLA'),
        colorHex: const Value('#000000'),
        remainingGrams: const Value(200),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      workspaceId: workspace.id,
    );
    await dao.addProductionOrder(
      workspaceId: workspace.id,
      orderNo: 'SO-MATERIAL-SETTLE',
      title: '实际用量结算',
      packages: const [
        StudioProductionPackageDraft(
          sourceName: 'same-color-tools.3mf',
          artifactKind: 'bambu3mf',
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 1,
              name: '双工具同色盘',
              requiredRuns: 1,
              estimatedSeconds: 300,
              estimatedGrams: 50,
              sliceStatus: StudioPlateSliceStatus.sliced,
              filaments: [
                StudioPlateFilamentUsage(
                  toolIndex: 0,
                  grams: 30,
                  materialType: 'PLA',
                  colorHex: '#000000',
                ),
                StudioPlateFilamentUsage(
                  toolIndex: 1,
                  grams: 20,
                  materialType: 'PLA',
                  colorHex: '#000000',
                ),
              ],
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
    var snapshot = await dao.getDefaultSnapshot();
    final workOrder = snapshot.workOrders.single;
    await dao.reserveWorkOrderMaterials(
      workOrderId: workOrder.id,
      consumableByTool: {0: blackId, 1: blackId},
    );
    await dao.updateWorkOrderProgress(
      id: workOrder.id,
      completedQuantity: 1,
      status: StudioWorkOrderStatus.completed,
      actualGramsByTool: const {0: 28.5, 1: 18.0},
    );

    snapshot = await dao.getDefaultSnapshot();
    expect(
      (await database.consumableDao.getById(blackId))!.remainingGrams,
      153.5,
    );
    expect(snapshot.workOrderMaterials.every((item) => item.isSettled), isTrue);
    expect(
      snapshot.workOrderMaterials.fold<double>(
        0,
        (sum, item) => sum + item.consumedGrams,
      ),
      46.5,
    );
    expect(snapshot.inventoryEvents, hasLength(2));

    await dao.updateWorkOrderProgress(
      id: workOrder.id,
      completedQuantity: 1,
      status: StudioWorkOrderStatus.completed,
      actualGramsByTool: const {0: 99, 1: 99},
    );
    expect(
      (await database.consumableDao.getById(blackId))!.remainingGrams,
      153.5,
      reason: '重复完成必须幂等',
    );
    expect((await dao.getDefaultSnapshot()).inventoryEvents, hasLength(2));

    await expectLater(
      dao.updateProductionPlateSlice(
        id: snapshot.productionPlates.single.id,
        status: StudioPlateSliceStatus.sliced,
        estimatedSeconds: 280,
        estimatedGrams: 45,
        filaments: const [
          StudioPlateFilamentUsage(
            toolIndex: 0,
            grams: 45,
            materialType: 'PLA',
            colorHex: '#000000',
          ),
        ],
      ),
      throwsStateError,
    );
  });

  test('同一耗材卷的多通道预留按合计需求拒绝超额', () async {
    final now = DateTime.now();
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    final spoolId = await database.consumableDao.addFarmConsumable(
      ConsumablesCompanion.insert(
        uid: const Value('studio-short-spool'),
        manufacturer: 'Bambu Lab',
        model: 'PLA Basic',
        materialType: const Value('PLA'),
        colorHex: const Value('#FFFFFF'),
        remainingGrams: const Value(50),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      workspaceId: workspace.id,
    );
    await dao.addProductionOrder(
      workspaceId: workspace.id,
      orderNo: 'SO-MATERIAL-OVERBOOK',
      title: '防止重复承诺库存',
      packages: const [
        StudioProductionPackageDraft(
          sourceName: 'overbook.3mf',
          artifactKind: 'bambu3mf',
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 1,
              name: '同色双通道',
              requiredRuns: 1,
              estimatedSeconds: 300,
              estimatedGrams: 60,
              sliceStatus: StudioPlateSliceStatus.sliced,
              filaments: [
                StudioPlateFilamentUsage(
                  toolIndex: 0,
                  grams: 30,
                  materialType: 'PLA',
                  colorHex: '#FFFFFF',
                ),
                StudioPlateFilamentUsage(
                  toolIndex: 1,
                  grams: 30,
                  materialType: 'PLA',
                  colorHex: '#FFFFFF',
                ),
              ],
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
    final workOrder = (await dao.getDefaultSnapshot()).workOrders.single;
    await expectLater(
      dao.reserveWorkOrderMaterials(
        workOrderId: workOrder.id,
        consumableByTool: {0: spoolId, 1: spoolId},
      ),
      throwsStateError,
    );
    expect(
      (await dao.getDefaultSnapshot())
          .workOrderMaterials
          .every((item) => !item.isAllocated),
      isTrue,
    );
  });

  test('云端工单耗材用稳定库存 UID 恢复本地预留映射', () async {
    final created = DateTime(2026, 8, 4, 10).toUtc().toIso8601String();
    await dao.mergeRemoteSnapshot({
      'inventoryItems': [
        {
          'uid': 'remote-spool-yellow',
          'manufacturer': 'Bambu Lab',
          'model': 'PETG HF',
          'materialType': 'PETG',
          'colorHex': '#F7D959',
          'totalGrams': 1000,
          'remainingGrams': 100,
          'createdAt': created,
          'updatedAt': created,
        },
      ],
      'orders': [
        {
          'id': 'remote-material-order',
          'orderNo': 'SO-REMOTE-MATERIAL',
          'title': '云端耗材预留',
          'status': 'production',
          'createdAt': created,
          'updatedAt': created,
        },
      ],
      'productionPackages': [
        {
          'id': 'remote-material-package',
          'orderId': 'remote-material-order',
          'sourceName': 'remote.3mf',
          'artifactKind': 'bambu3mf',
          'createdAt': created,
        },
      ],
      'productionPlates': [
        {
          'id': 'remote-material-plate',
          'orderId': 'remote-material-order',
          'packageId': 'remote-material-package',
          'plateIndex': 8,
          'name': '左多色配件',
          'requiredRuns': 1,
          'estimatedSeconds': 600,
          'estimatedGrams': 22.73,
          'sliceStatus': 'sliced',
          'createdAt': created,
        },
      ],
      'workOrders': [
        {
          'id': 'remote-material-work-order',
          'orderId': 'remote-material-order',
          'productionPlateId': 'remote-material-plate',
          'title': '第 8 盘',
          'quantity': 1,
          'completedQuantity': 0,
          'status': 'queued',
          'createdAt': created,
          'updatedAt': created,
        },
      ],
      'workOrderMaterials': [
        {
          'id': 'remote-material-ledger',
          'workOrderId': 'remote-material-work-order',
          'productionPlateId': 'remote-material-plate',
          'toolIndex': 0,
          'materialType': 'PETG',
          'colorHex': '#F7D959',
          'estimatedGrams': 22.73,
          'consumableUid': 'remote-spool-yellow',
          'reservedGrams': 22.73,
          'consumedGrams': 0,
          'status': 'reserved',
          'createdAt': created,
          'updatedAt': created,
        },
      ],
    });

    final snapshot = await dao.getDefaultSnapshot();
    final material = snapshot.workOrderMaterials.single;
    expect(material.isAllocated, isTrue);
    final spool = (await database.consumableDao.getAll()).single;
    expect(material.consumableId, spool.id);
    expect(
      (await dao.getConsumableAvailability(
        spool.id,
        workspaceId: snapshot.workspace.id,
      ))
          .availableGrams,
      closeTo(77.27, 0.001),
    );
  });

  test('实际用量超过本工单预留时不能侵占另一工单库存', () async {
    final now = DateTime.now();
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    final spoolId = await database.consumableDao.addFarmConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'Bambu Lab',
        model: 'PLA Basic',
        materialType: const Value('PLA'),
        colorHex: const Value('#FFFFFF'),
        remainingGrams: const Value(100),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      workspaceId: workspace.id,
    );
    final printerA = await database.printerDao.addPrinter(
      brand: 'Bambu Lab',
      model: 'A1',
      channelCount: 1,
    );
    final printerB = await database.printerDao.addPrinter(
      brand: 'Bambu Lab',
      model: 'A1',
      channelCount: 1,
    );
    await dao.addProductionOrder(
      workspaceId: workspace.id,
      orderNo: 'SO-ACTUAL-OVER-RESERVE',
      title: '实际用量保护',
      packages: [
        StudioProductionPackageDraft(
          sourceName: 'two-runs.3mf',
          artifactKind: 'bambu3mf',
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 1,
              name: '白色盘',
              requiredRuns: 2,
              estimatedSeconds: 300,
              estimatedGrams: 50,
              sliceStatus: StudioPlateSliceStatus.sliced,
              assignedPrinterIds: [printerA, printerB],
              filaments: const [
                StudioPlateFilamentUsage(
                  toolIndex: 0,
                  grams: 50,
                  materialType: 'PLA',
                  colorHex: '#FFFFFF',
                ),
              ],
              items: const [
                StudioOrderItemDraft(
                  sourceKey: 'object',
                  name: '对象',
                  perRunQuantity: 1,
                  requiredQuantity: 2,
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final workOrders = (await dao.getDefaultSnapshot()).workOrders;
    for (final workOrder in workOrders) {
      await dao.reserveWorkOrderMaterials(
        workOrderId: workOrder.id,
        consumableByTool: {0: spoolId},
      );
    }

    await expectLater(
      dao.updateWorkOrderProgress(
        id: workOrders.first.id,
        completedQuantity: 1,
        status: StudioWorkOrderStatus.completed,
        actualGramsByTool: const {0: 60},
      ),
      throwsStateError,
    );
    expect(
      (await database.consumableDao.getById(spoolId))!.remainingGrams,
      100,
    );
    expect(
      (await dao.getDefaultSnapshot())
          .workOrderMaterials
          .every((item) => item.isAllocated),
      isTrue,
    );
  });

  test('不同账号和云农场使用独立本地工作区，禁止改绑旧农场', () async {
    final accountA = StudioDao(database, accountScope: 'server|account:a');
    final accountB = StudioDao(database, accountScope: 'server|account:b');
    addTearDown(accountA.dispose);
    addTearDown(accountB.dispose);

    final localA = await accountA.ensureDefaultWorkspace();
    await accountA.addCustomer(workspaceId: localA.id, name: '农场 A 客户');
    await accountA.setRemoteWorkspaceId(localA.id, 'remote-farm-a');
    await accountA.bindRemoteWorkspace(
      'remote-farm-a',
      accountScope: 'server|farm:remote-farm-a',
    );
    await accountB.bindRemoteWorkspace(
      'remote-farm-b',
      accountScope: 'server|farm:remote-farm-b',
    );

    expect(
      (await accountA.getDefaultSnapshot()).customers.single.name,
      '农场 A 客户',
    );
    expect((await accountB.getDefaultSnapshot()).customers, isEmpty);
    await expectLater(
      accountA.setRemoteWorkspaceId(localA.id, 'remote-farm-b'),
      throwsStateError,
    );
  });

  test('云快照保留批次单位成本，删除墓碑阻止库存复活', () async {
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    const createdAt = '2026-08-05T01:00:00.000Z';
    await dao.mergeRemoteSnapshot({
      'inventoryItems': [
        {
          'uid': 'cloud-cost-spool',
          'manufacturer': 'Bambu Lab',
          'model': 'PLA Basic',
          'materialType': 'PLA',
          'colorHex': '#FFFFFF',
          'totalGrams': 2000,
          'remainingGrams': 2000,
          'batchNo': 'CLOUD-BATCH',
          'createdAt': createdAt,
          'updatedAt': createdAt,
        },
      ],
      'inventoryBatches': [
        {
          'id': 'cloud-batch-id',
          'batchNo': 'CLOUD-BATCH',
          'receivedAt': createdAt,
          'rollCount': 2,
          'totalGrams': 2000,
          'createdAt': createdAt,
          'updatedAt': createdAt,
        },
      ],
      'inventoryBatchItems': [
        {
          'id': 'cloud-batch-item-id',
          'batchId': 'cloud-batch-id',
          'consumableUid': 'cloud-cost-spool',
          'rollCount': 2,
          'gramsPerRoll': 1000,
          'unitCost': 89,
          'createdAt': createdAt,
          'updatedAt': createdAt,
        },
      ],
    });
    var snapshot = await dao.getDefaultSnapshot();
    expect(snapshot.inventoryBatchItems.single.unitCost, 89);

    final stock = (await database.consumableDao.getFarm(workspace.id)).single;
    await database.consumableDao
        .deleteFarmConsumable(stock.id, workspaceId: workspace.id);
    await dao.recordSyncDeletion(
      workspaceId: workspace.id,
      entityType: 'inventoryItem',
      entityId: stock.uid,
    );
    await dao.mergeRemoteSnapshot({
      'inventoryItems': [
        {
          'uid': stock.uid,
          'manufacturer': '旧云端库存',
          'model': 'PLA',
          'materialType': 'PLA',
          'colorHex': '#FFFFFF',
          'totalGrams': 2000,
          'remainingGrams': 2000,
          'createdAt': createdAt,
          'updatedAt': createdAt,
        },
      ],
    });
    snapshot = await dao.getDefaultSnapshot();
    expect(await database.consumableDao.getFarm(workspace.id), isEmpty);
    expect(snapshot.inventoryBatchItems, isEmpty);
    expect(await dao.getSyncTombstones(), isNotEmpty);
  });

  test('农场卷卸下归还剩余量，同 SKU 更换 RFID 物理卷只扣一次', () async {
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    final now = DateTime.now();
    final stockId = await database.consumableDao.addFarmConsumable(
      ConsumablesCompanion.insert(
        uid: const Value('physical-roll-stock'),
        manufacturer: 'Bambu Lab',
        model: 'PLA',
        totalGrams: const Value(3000),
        remainingGrams: const Value(3000),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      workspaceId: workspace.id,
    );
    final printerId = await database.printerDao.addPrinter(
      brand: 'Bambu Lab',
      model: 'X1C',
      channelCount: 1,
    );
    final channel = (await database.printerDao.getByIdWithChannels(printerId))!
        .channels
        .single
        .channel;
    await database.printerDao.bindConsumable(
      channel.id,
      stockId,
      farmLoadAuthorization: FarmRollLoadAuthorization.rfidDetected,
      physicalSpoolUid: 'rfid-roll-a',
    );
    await database.printerDao.syncFarmChannelLoadedRemaining(
      printerId: printerId,
      channelIndex: channel.channelIndex,
      remainingGrams: 600,
    );
    await database.printerDao.changeRoll(
      channelId: channel.id,
      newConsumableId: stockId,
      farmLoadAuthorization: FarmRollLoadAuthorization.rfidDetected,
      physicalSpoolUid: 'rfid-roll-b',
    );
    expect(
      (await database.consumableDao.getById(stockId))!.remainingGrams,
      1600,
    );
    expect(
      (await database.printerDao.getByIdWithChannels(printerId))!
          .channels
          .single
          .channel
          .loadedRemainingGrams,
      1000,
    );

    await database.printerDao.syncFarmChannelLoadedRemaining(
      printerId: printerId,
      channelIndex: channel.channelIndex,
      remainingGrams: 375,
    );
    await database.printerDao.unbindChannel(channel.id);
    expect(
      (await database.consumableDao.getById(stockId))!.remainingGrams,
      1975,
    );
    expect(
      (await database.printerDao.getByIdWithChannels(printerId))!
          .channels
          .single
          .consumable,
      equals(null),
    );
  });
}
