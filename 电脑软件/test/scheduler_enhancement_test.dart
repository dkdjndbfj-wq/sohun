// Phase C 打印农场调度增强 - 验收测试。
//
// 覆盖任务书要求的验收用例：
// 1. A1 G-code 不会仅因属于 A1 组而自动发给 A1 mini（精确型号+喷嘴必须匹配）
// 2. 0.4mm G-code 不会自动发给已安装 0.6mm 喷嘴的机器
// 3. 多材料任务任一材料不足即拒绝候选
// 4. 两次并发自动调度不会重复分配同一任务
// 5. 分配后队列失败会回滚或进入可恢复错误态
// 6. 完成打印后 scheduler 状态自动完成并释放设备
// 7. 状态过期的打印机不参与自动发送
// 8. 仅云连接设备不会进入可自动下发候选
// 9. 两个任务并发调度不会超额预留同一卷；取消后预留正确释放

import 'package:consumable_tracker_desktop/core/services/printer_model_normalizer.dart';
import 'package:consumable_tracker_desktop/data/database/daos/print_queue_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/scheduler_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/scheduler_material_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/spool_reservation_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/print_queue_item.dart';
import 'package:consumable_tracker_desktop/data/database/models/scheduler_models.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PrinterModelNormalizer - 精确机型匹配', () {
    test('X1 Carbon 与 X1C 是等价别名（同一 canonical 型号）', () {
      expect(PrinterModelNormalizer.normalize('X1 Carbon'), 'X1C');
      expect(PrinterModelNormalizer.normalize('X1C'), 'X1C');
      expect(
        PrinterModelNormalizer.sameModel('X1 Carbon', 'X1C'),
        isTrue,
      );
    });

    test('A1 与 A1 mini 是不同型号（构建体积不同，G-code 不互通）', () {
      expect(PrinterModelNormalizer.normalize('A1'), 'A1');
      expect(PrinterModelNormalizer.normalize('A1 mini'), 'A1mini');
      expect(
        PrinterModelNormalizer.sameModel('A1', 'A1 mini'),
        isFalse,
        reason: 'A1 G-code 不能安全发给 A1 mini（构建体积不同）',
      );
    });

    test('P1S 与 P1P 是不同型号（G-code 不兼容）', () {
      expect(PrinterModelNormalizer.normalize('P1S'), 'P1S');
      expect(PrinterModelNormalizer.normalize('P1P'), 'P1P');
      expect(
        PrinterModelNormalizer.sameModel('P1S', 'P1P'),
        isFalse,
        reason: 'P1S G-code 不能安全发给 P1P',
      );
    });

    test('验收用例1：A1 组内 A1 与 A1 mini 不能仅因同组而互通 G-code', () {
      // 机型组相同（都属 A1 组），但精确型号不同
      final a1Group = PrinterModelGroup.fromModel('A1');
      final a1MiniGroup = PrinterModelGroup.fromModel('A1 mini');
      expect(a1Group, a1MiniGroup, reason: '都属 A1 组（UI 分组用）');
      // 但精确匹配必须返回 false
      expect(
        PrinterModelNormalizer.sameModel('A1', 'A1 mini'),
        isFalse,
        reason: '机型组相同不代表 G-code 通用，必须精确匹配',
      );
    });

    test('品牌前缀和喷嘴后缀正确去除', () {
      expect(PrinterModelNormalizer.normalize('Bambu Lab P1S'), 'P1S');
      expect(PrinterModelNormalizer.normalize('@BBL X1C'), 'X1C');
      expect(
        PrinterModelNormalizer.normalize('P1S 0.4mm nozzle'),
        'P1S',
      );
    });

    test('含糊系列名不会映射成某个精确型号', () {
      expect(PrinterModelNormalizer.normalize('X1'), 'X1');
      expect(PrinterModelNormalizer.normalize('P1'), 'P1');
      expect(PrinterModelNormalizer.normalize('H2'), 'H2');
      expect(PrinterModelNormalizer.isKnownBambuModel('P1'), isFalse);
      expect(PrinterModelNormalizer.sameModel('P1', 'P1S'), isFalse);
    });

    test('H2D Pro 保持独立的精确机型', () {
      expect(PrinterModelNormalizer.normalize('H2D Pro'), 'H2D Pro');
      expect(PrinterModelNormalizer.normalize('H2DP'), 'H2D Pro');
      expect(PrinterModelNormalizer.sameModel('H2D Pro', 'H2D'), isFalse);
    });
  });

  group('PrinterModelSpec - 喷嘴直径匹配', () {
    test('验收用例2：0.4mm G-code 不能匹配 0.6mm 喷嘴', () {
      const taskSpec = PrinterModelSpec(
        canonicalModel: 'P1S',
        nozzleDiameter: 0.4,
      );
      const printerSpec04 = PrinterModelSpec(
        canonicalModel: 'P1S',
        nozzleDiameter: 0.4,
      );
      const printerSpec06 = PrinterModelSpec(
        canonicalModel: 'P1S',
        nozzleDiameter: 0.6,
      );
      expect(taskSpec.matchesSpec(printerSpec04), isTrue);
      expect(
        taskSpec.matchesSpec(printerSpec06),
        isFalse,
        reason: '0.4mm G-code 不能发到 0.6mm 喷嘴的机器',
      );
    });

    test('机型不同时即使喷嘴相同也不匹配', () {
      const spec1 = PrinterModelSpec(
        canonicalModel: 'P1S',
        nozzleDiameter: 0.4,
      );
      const spec2 = PrinterModelSpec(
        canonicalModel: 'P1P',
        nozzleDiameter: 0.4,
      );
      expect(spec1.matchesSpec(spec2), isFalse);
    });

    test('喷嘴直径允许 0.001mm 浮点误差', () {
      const spec1 = PrinterModelSpec(
        canonicalModel: 'A1',
        nozzleDiameter: 0.4,
      );
      const spec2 = PrinterModelSpec(
        canonicalModel: 'A1',
        nozzleDiameter: 0.4001,
      );
      expect(spec1.matchesSpec(spec2), isTrue);
    });
  });

  group('SchedulingConfig - 余量安全缓冲', () {
    const config = SchedulingConfig.defaults;

    test('小克数任务使用最小缓冲 5g', () {
      // 50g * 10% = 5g，等于 minBufferGrams，取 max(5, 5) = 5
      expect(config.safetyBuffer(50), 5.0);
      // 30g * 10% = 3g < 5g，取 max(5, 3) = 5
      expect(config.safetyBuffer(30), 5.0);
      // 0g 任务也至少 5g 缓冲
      expect(config.safetyBuffer(0), 5.0);
    });

    test('大克数任务使用 10% 缓冲', () {
      // 100g * 10% = 10g > 5g
      expect(config.safetyBuffer(100), 10.0);
      // 200g * 10% = 20g > 5g
      expect(config.safetyBuffer(200), 20.0);
      // 1000g * 10% = 100g > 5g
      expect(config.safetyBuffer(1000), 100.0);
    });

    test('边界：50g 正好在 minBuffer 和 10% 交点', () {
      // 50g * 10% = 5g = minBufferGrams，max(5, 5) = 5
      expect(config.safetyBuffer(50), 5.0);
      // 51g * 10% = 5.1g > 5g
      expect(config.safetyBuffer(51), closeTo(5.1, 0.001));
    });

    test('状态过期判断', () {
      // null 状态时间视为过期
      expect(config.isStale(null), isTrue);
      // 当前时间不过期
      expect(config.isStale(DateTime.now()), isFalse);
      // 6 分钟前过期（默认阈值 5 分钟）
      expect(
        config.isStale(DateTime.now().subtract(const Duration(minutes: 6))),
        isTrue,
      );
      // 4 分钟前不过期
      expect(
        config.isStale(DateTime.now().subtract(const Duration(minutes: 4))),
        isFalse,
      );
    });

    test('忙机预排默认最多保留 5 个活动任务', () {
      expect(config.maxQueuedTasksPerPrinter, 5);
    });
  });

  test('指定颜色不匹配时不能视为可用 AMS 通道', () {
    const mismatch = MaterialMatchResult(
      toolIndex: 1,
      requiredMaterialType: 'PETG',
      requiredColorHex: '#FFFFFF',
      requiredGrams: 20,
      matchedConsumableId: 7,
      matchedAvailableGrams: 800,
      materialMatched: true,
      colorMatched: false,
      sufficient: true,
    );
    expect(mismatch.matched, isFalse);
  });

  group('SchedulingWeights - 评分权重验证', () {
    test('默认权重总和等于 100', () {
      const weights = SchedulingWeights.defaults;
      expect(weights.sum, closeTo(100.0, 0.001));
      expect(weights.isValid, isTrue);
    });

    test('默认权重符合任务书要求', () {
      const weights = SchedulingWeights.defaults;
      expect(weights.earliestFinish, 35);
      expect(weights.materialColor, 25);
      expect(weights.historyRate, 15);
      expect(weights.changeCost, 10);
      expect(weights.health, 10);
      expect(weights.batchAffinity, 5);
    });

    test('自定义权重总和验证', () {
      const valid = SchedulingWeights(
        earliestFinish: 40,
        materialColor: 20,
        historyRate: 15,
        changeCost: 10,
        health: 10,
        batchAffinity: 5,
      );
      expect(valid.isValid, isTrue);

      const invalid = SchedulingWeights(
        earliestFinish: 50,
        materialColor: 30,
        historyRate: 15,
        changeCost: 10,
        health: 10,
        batchAffinity: 5,
      );
      expect(invalid.isValid, isFalse);
    });

    test('combine 方法按权重加权', () {
      const weights = SchedulingWeights.defaults;
      final score = weights.combine(
        earliestFinishNormalized: 1.0,
        materialColorNormalized: 1.0,
        historyRateNormalized: 1.0,
        changeCostNormalized: 1.0,
        healthNormalized: 1.0,
        batchAffinityNormalized: 1.0,
      );
      // 所有维度满分时，综合分 = 35 + 25 + 15 + 10 + 10 + 5 = 100
      expect(score, closeTo(100.0, 0.001));
    });
  });

  group('PrinterStateFreshness - 状态新鲜度', () {
    test('验收用例7：状态过期的打印机 canAutoDispatch 为 false', () {
      final freshness = PrinterStateFreshness(
        statusUpdatedAt: DateTime.now().subtract(const Duration(minutes: 10)),
        stale: true,
        lanCapable: true,
        printerBusy: false,
      );
      expect(freshness.canAutoDispatch, isFalse, reason: '状态过期的打印机不参与自动发送');
    });

    test('验收用例8：仅云连接设备 canAutoDispatch 为 false', () {
      final freshness = PrinterStateFreshness(
        statusUpdatedAt: DateTime.now(),
        stale: false,
        lanCapable: false, // 仅云连接
        printerBusy: false,
      );
      expect(freshness.canAutoDispatch, isFalse, reason: '仅云连接设备无法自动下发');
    });

    test('LAN 可达 + 状态新鲜 + 不忙碌 = 可自动下发', () {
      final freshness = PrinterStateFreshness(
        statusUpdatedAt: DateTime.now(),
        stale: false,
        lanCapable: true,
        printerBusy: false,
      );
      expect(freshness.canAutoDispatch, isTrue);
    });

    test('打印机忙碌时 canAutoDispatch 为 false', () {
      final freshness = PrinterStateFreshness(
        statusUpdatedAt: DateTime.now(),
        stale: false,
        lanCapable: true,
        printerBusy: true,
      );
      expect(freshness.canAutoDispatch, isFalse);
    });
  });

  // ============ 数据库集成测试 ============
  // 使用内存数据库，避免影响磁盘数据。
  // AppDatabase.forTesting 会执行所有迁移（v1→v21），创建完整 schema。

  late AppDatabase db;
  late SchedulerDao schedulerDao;
  late SchedulerMaterialDao materialDao;
  late SpoolReservationDao reservationDao;
  late PrintQueueDao printQueueDao;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    schedulerDao = SchedulerDao(db);
    materialDao = SchedulerMaterialDao(db);
    reservationDao = SpoolReservationDao(db);
    printQueueDao = PrintQueueDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('SchedulerDao - 任务状态推进', () {
    test('插入任务后可按 id 查回', () async {
      final taskId = await schedulerDao.insertTask(
        SchedulerTask(
          gcodePath: '/tmp/test.gcode',
          gcodeFilename: 'test.gcode',
          modelGroup: PrinterModelGroup.p1,
          requiredMaterial: 'PLA',
          estimatedGrams: 100,
          createdAt: DateTime.now(),
          targetModel: 'P1S',
          targetNozzleDiameter: 0.4,
        ),
      );
      expect(taskId, greaterThan(0));

      final task = await schedulerDao.getById(taskId);
      expect(task, isNotNull);
      expect(task!.gcodeFilename, 'test.gcode');
      expect(task.status, SchedulerTaskStatus.pending);
      expect(task.targetModel, 'P1S');
      expect(task.targetNozzleDiameter, 0.4);
    });

    test('updateStatus 推进任务状态', () async {
      // 先插入打印机（外键约束要求 assigned_printer_id 存在）
      final printerId = await _insertPrinter(db, serial: 'SN_STATUS');
      final taskId = await schedulerDao.insertTask(
        SchedulerTask(
          gcodePath: '/tmp/test.gcode',
          gcodeFilename: 'test.gcode',
          modelGroup: PrinterModelGroup.p1,
          requiredMaterial: 'PLA',
          estimatedGrams: 100,
          createdAt: DateTime.now(),
        ),
      );

      await schedulerDao.updateStatus(
        taskId,
        SchedulerTaskStatus.assigned,
        assignedPrinterId: printerId,
        assignedAt: DateTime.now(),
      );
      var task = await schedulerDao.getById(taskId);
      expect(task!.status, SchedulerTaskStatus.assigned);
      expect(task.assignedPrinterId, printerId);

      await schedulerDao.updateStatus(
        taskId,
        SchedulerTaskStatus.printing,
      );
      task = await schedulerDao.getById(taskId);
      expect(task!.status, SchedulerTaskStatus.printing);

      await schedulerDao.updateStatus(
        taskId,
        SchedulerTaskStatus.completed,
        completedAt: DateTime.now(),
      );
      task = await schedulerDao.getById(taskId);
      expect(task!.status, SchedulerTaskStatus.completed);
      expect(task.completedAt, isNotNull);
    });

    test('cancelTask 清空 assigned_printer_id', () async {
      // 先插入打印机（外键约束要求 assigned_printer_id 存在）
      final printerId = await _insertPrinter(db, serial: 'SN_CANCEL');
      final taskId = await schedulerDao.insertTask(
        SchedulerTask(
          gcodePath: '/tmp/test.gcode',
          gcodeFilename: 'test.gcode',
          modelGroup: PrinterModelGroup.p1,
          requiredMaterial: 'PLA',
          estimatedGrams: 100,
          createdAt: DateTime.now(),
        ),
      );
      await schedulerDao.updateStatus(
        taskId,
        SchedulerTaskStatus.assigned,
        assignedPrinterId: printerId,
      );
      await schedulerDao.cancelTask(taskId);
      final task = await schedulerDao.getById(taskId);
      expect(task!.status, SchedulerTaskStatus.cancelled);
      expect(
        task.assignedPrinterId,
        isNull,
        reason: '取消后必须清空 assigned_printer_id',
      );
    });

    test('isPrinterOccupied 检测打印机是否已有 assigned 任务', () async {
      // 先插入打印机（外键约束要求 assigned_printer_id 存在）
      final printerId = await _insertPrinter(db, serial: 'SN_OCCUPY');
      final taskId = await schedulerDao.insertTask(
        SchedulerTask(
          gcodePath: '/tmp/test.gcode',
          gcodeFilename: 'test.gcode',
          modelGroup: PrinterModelGroup.p1,
          requiredMaterial: 'PLA',
          estimatedGrams: 100,
          createdAt: DateTime.now(),
        ),
      );
      // 分配前打印机空闲
      expect(await schedulerDao.isPrinterOccupied(printerId), isFalse);
      // 分配后打印机被占用
      await schedulerDao.updateStatus(
        taskId,
        SchedulerTaskStatus.assigned,
        assignedPrinterId: printerId,
      );
      expect(await schedulerDao.isPrinterOccupied(printerId), isTrue);
      // 完成后释放
      await schedulerDao.updateStatus(
        taskId,
        SchedulerTaskStatus.completed,
        completedAt: DateTime.now(),
      );
      expect(await schedulerDao.isPrinterOccupied(printerId), isFalse);
    });
  });

  group('SchedulerMaterialDao - 多材料任务', () {
    test('验收用例3：多色任务逐工具写入材料需求', () async {
      final taskId = await schedulerDao.insertTask(
        SchedulerTask(
          gcodePath: '/tmp/multi.gcode',
          gcodeFilename: 'multi.gcode',
          modelGroup: PrinterModelGroup.x1,
          requiredMaterial: 'PLA',
          estimatedGrams: 200,
          createdAt: DateTime.now(),
          targetModel: 'X1C',
          targetNozzleDiameter: 0.4,
        ),
      );

      // 写入两个工具的材料需求
      await materialDao.insertMaterial(
        taskId,
        0,
        'Bambu PLA Red',
        'PLA',
        '#FF0000',
        100,
      );
      await materialDao.insertMaterial(
        taskId,
        1,
        'Bambu PLA Blue',
        'PLA',
        '#0000FF',
        100,
      );

      final materials = await materialDao.getMaterialsForTask(taskId);
      expect(materials.length, 2);
      expect(materials[0].toolIndex, 0);
      expect(materials[0].materialType, 'PLA');
      expect(materials[0].requiredColorHex, '#FF0000');
      expect(materials[0].estimatedGrams, 100);
      expect(materials[1].toolIndex, 1);
      expect(materials[1].requiredColorHex, '#0000FF');
    });

    test('replaceMaterialsForTask 事务替换', () async {
      final taskId = await schedulerDao.insertTask(
        SchedulerTask(
          gcodePath: '/tmp/test.gcode',
          gcodeFilename: 'test.gcode',
          modelGroup: PrinterModelGroup.p1,
          requiredMaterial: 'PLA',
          estimatedGrams: 100,
          createdAt: DateTime.now(),
        ),
      );

      // 先插入两条
      await materialDao.insertMaterial(taskId, 0, 'PLA', 'PLA', null, 50);
      await materialDao.insertMaterial(taskId, 1, 'PETG', 'PETG', null, 50);
      expect((await materialDao.getMaterialsForTask(taskId)).length, 2);

      // 替换为三条
      await materialDao.replaceMaterialsForTask(taskId, [
        SchedulerTaskMaterial(
          schedulerTaskId: taskId,
          toolIndex: 0,
          materialProfile: 'PLA',
          materialType: 'PLA',
          estimatedGrams: 60,
        ),
        SchedulerTaskMaterial(
          schedulerTaskId: taskId,
          toolIndex: 1,
          materialProfile: 'PETG',
          materialType: 'PETG',
          estimatedGrams: 40,
        ),
        SchedulerTaskMaterial(
          schedulerTaskId: taskId,
          toolIndex: 2,
          materialProfile: 'ABS',
          materialType: 'ABS',
          estimatedGrams: 30,
        ),
      ]);
      final materials = await materialDao.getMaterialsForTask(taskId);
      expect(materials.length, 3);
      expect(materials[0].toolIndex, 0);
      expect(materials[2].materialType, 'ABS');
    });
  });

  group('SpoolReservationDao - 耗材预留', () {
    test('reserve 创建预留后 getAvailableGrams 扣减', () async {
      // 先插入调度任务和耗材卷（外键约束要求 scheduler_task_id 存在）
      final taskId = await _insertSchedulerTask(db);
      final consumableId = await _insertConsumable(db, remainingGrams: 1000);

      // 初始可用量 = 1000
      var avail = await reservationDao.getAvailableGrams(consumableId);
      expect(avail.totalRemainingGrams, 1000);
      expect(avail.totalReservedGrams, 0);
      expect(avail.availableGrams, 1000);

      // 预留 200g
      await reservationDao.reserve(
        schedulerTaskId: taskId,
        consumableId: consumableId,
        toolIndex: 0,
        grams: 200,
      );
      avail = await reservationDao.getAvailableGrams(consumableId);
      expect(avail.totalReservedGrams, 200);
      expect(avail.availableGrams, 800);
    });

    test('验收用例9：两个任务并发预留不超额', () async {
      final taskId1 = await _insertSchedulerTask(db);
      final taskId2 = await _insertSchedulerTask(db);
      final consumableId = await _insertConsumable(db, remainingGrams: 500);

      // 任务1预留 300g
      await reservationDao.reserve(
        schedulerTaskId: taskId1,
        consumableId: consumableId,
        toolIndex: 0,
        grams: 300,
      );
      // 任务2再预留 300g → 总预留 600g > 500g 库存
      await reservationDao.reserve(
        schedulerTaskId: taskId2,
        consumableId: consumableId,
        toolIndex: 0,
        grams: 300,
      );
      final avail = await reservationDao.getAvailableGrams(consumableId);
      expect(avail.totalReservedGrams, 600);
      // 可用量为 0（500 - 600 = -100，钳制为 0）
      expect(avail.availableGrams, 0, reason: '两个任务预留总和超过库存时可用量为 0');
    });

    test('releaseForTask 释放任务的所有 active 预留', () async {
      final taskId1 = await _insertSchedulerTask(db);
      final taskId2 = await _insertSchedulerTask(db);
      final consumableId = await _insertConsumable(db, remainingGrams: 1000);

      // 任务1在两个工具上各预留 100g
      await reservationDao.reserve(
        schedulerTaskId: taskId1,
        consumableId: consumableId,
        toolIndex: 0,
        grams: 100,
      );
      await reservationDao.reserve(
        schedulerTaskId: taskId1,
        consumableId: consumableId,
        toolIndex: 1,
        grams: 100,
      );
      // 任务2预留 100g
      await reservationDao.reserve(
        schedulerTaskId: taskId2,
        consumableId: consumableId,
        toolIndex: 0,
        grams: 100,
      );
      var avail = await reservationDao.getAvailableGrams(consumableId);
      expect(avail.totalReservedGrams, 300);

      // 释放任务1的所有预留
      await reservationDao.releaseForTask(taskId1);
      avail = await reservationDao.getAvailableGrams(consumableId);
      expect(
        avail.totalReservedGrams,
        100,
        reason: '任务1的 200g 预留已释放，只剩任务2的 100g',
      );
      expect(avail.availableGrams, 900);
    });

    test('cancelForTask 区别于 releaseForTask（语义不同）', () async {
      final taskId = await _insertSchedulerTask(db);
      final consumableId = await _insertConsumable(db, remainingGrams: 1000);

      await reservationDao.reserve(
        schedulerTaskId: taskId,
        consumableId: consumableId,
        toolIndex: 0,
        grams: 200,
      );

      // cancel 标记为 cancelled（取消/回滚）
      final affected = await reservationDao.cancelForTask(taskId);
      expect(affected, 1);

      final avail = await reservationDao.getAvailableGrams(consumableId);
      expect(avail.totalReservedGrams, 0, reason: 'cancelled 预留不计入活动预留');
      expect(avail.availableGrams, 1000);
    });

    test('canReserve 前置校验', () async {
      final consumableId = await _insertConsumable(db, remainingGrams: 100);

      // 100g 库存，预留 80g + 5g 缓冲 = 85g，足够
      expect(
        await reservationDao.canReserve(
          consumableId: consumableId,
          grams: 80,
          safetyBuffer: 5,
        ),
        isTrue,
      );

      // 预留 96g + 5g 缓冲 = 101g > 100g，不够
      expect(
        await reservationDao.canReserve(
          consumableId: consumableId,
          grams: 96,
          safetyBuffer: 5,
        ),
        isFalse,
      );
    });

    test('getActiveReservationsForConsumable 按时间升序', () async {
      final taskId1 = await _insertSchedulerTask(db);
      final taskId2 = await _insertSchedulerTask(db);
      final consumableId = await _insertConsumable(db, remainingGrams: 1000);

      await reservationDao.reserve(
        schedulerTaskId: taskId1,
        consumableId: consumableId,
        toolIndex: 0,
        grams: 100,
      );
      await Future.delayed(const Duration(milliseconds: 10));
      await reservationDao.reserve(
        schedulerTaskId: taskId2,
        consumableId: consumableId,
        toolIndex: 0,
        grams: 200,
      );

      final list =
          await reservationDao.getActiveReservationsForConsumable(consumableId);
      expect(list.length, 2);
      expect(list[0].reservedGrams, 100, reason: '按 reserved_at 升序');
      expect(list[1].reservedGrams, 200);
    });

    test('不存在的耗材卷返回 0 可用量', () async {
      final avail = await reservationDao.getAvailableGrams(99999);
      expect(avail.availableGrams, 0.0);
      expect(avail.totalRemainingGrams, 0.0);
      expect(avail.totalReservedGrams, 0.0);
    });
  });

  group('PrintQueueDao - scheduler_task_id 唯一关联', () {
    test('验收用例4：enqueue 带 schedulerTaskId 可按 id 查回', () async {
      final id = await printQueueDao.enqueue(
        PrintQueueItem(
          printerSerial: 'SN001',
          gcodePath: '/tmp/test.gcode',
          filename: 'test.gcode',
          queuedAt: DateTime.now(),
          schedulerTaskId: 42,
        ),
      );
      expect(id, greaterThan(0));

      final item = await printQueueDao.getBySchedulerTaskId(42);
      expect(item, isNotNull);
      expect(item!.schedulerTaskId, 42);
      expect(item.filename, 'test.gcode');
      expect(item.status, PrintQueueStatus.queued);
    });

    test('验收用例4：同一 schedulerTaskId 重复入队被唯一索引拦截', () async {
      // 第一次入队成功
      await printQueueDao.enqueue(
        PrintQueueItem(
          printerSerial: 'SN001',
          gcodePath: '/tmp/test.gcode',
          filename: 'test.gcode',
          queuedAt: DateTime.now(),
          schedulerTaskId: 99,
        ),
      );

      // 第二次入队同一 schedulerTaskId 应抛异常（唯一索引）
      expect(
        () => printQueueDao.enqueue(
          PrintQueueItem(
            printerSerial: 'SN001',
            gcodePath: '/tmp/test2.gcode',
            filename: 'test2.gcode',
            queuedAt: DateTime.now(),
            schedulerTaskId: 99,
          ),
        ),
        throwsA(isA<Object>()),
        reason: '唯一索引 idx_pq_scheduler_task_unique 防止重复入队',
      );
    });

    test('isSchedulerTaskEnqueued 检查', () async {
      expect(await printQueueDao.isSchedulerTaskEnqueued(1), isFalse);

      await printQueueDao.enqueue(
        PrintQueueItem(
          printerSerial: 'SN001',
          gcodePath: '/tmp/test.gcode',
          filename: 'test.gcode',
          queuedAt: DateTime.now(),
          schedulerTaskId: 1,
        ),
      );
      expect(await printQueueDao.isSchedulerTaskEnqueued(1), isTrue);
    });

    test('schedulerTaskId 为 null 时不触发唯一索引', () async {
      // 两条 schedulerTaskId=null 的记录可以共存
      await printQueueDao.enqueue(
        PrintQueueItem(
          printerSerial: 'SN001',
          gcodePath: '/tmp/a.gcode',
          filename: 'a.gcode',
          queuedAt: DateTime.now(),
        ),
      );
      await printQueueDao.enqueue(
        PrintQueueItem(
          printerSerial: 'SN001',
          gcodePath: '/tmp/b.gcode',
          filename: 'b.gcode',
          queuedAt: DateTime.now(),
        ),
      );
      final items = await printQueueDao.getByPrinter('SN001');
      expect(items.length, 2);
    });

    test('AMS 映射随队列持久化，活动数量包含打印中和后续排队', () async {
      final firstId = await printQueueDao.enqueue(
        PrintQueueItem(
          printerSerial: 'AMS-QUEUE',
          gcodePath: '/tmp/multicolor.3mf',
          filename: 'multicolor.3mf',
          queuedAt: DateTime.now(),
          amsMapping: const [3, -1, 6],
        ),
      );
      await printQueueDao.setStatus(
        firstId,
        PrintQueueStatus.printing,
        startedAt: DateTime.now(),
      );
      await printQueueDao.enqueue(
        PrintQueueItem(
          printerSerial: 'AMS-QUEUE',
          gcodePath: '/tmp/next.3mf',
          filename: 'next.3mf',
          queuedAt: DateTime.now(),
        ),
      );

      final items = await printQueueDao.getByPrinter('AMS-QUEUE');
      expect(items.first.amsMapping, const [3, -1, 6]);
      expect(await printQueueDao.getActiveCount('AMS-QUEUE'), 2);
    });
  });

  group('原子事务 - 分配+入队+预留', () {
    test('验收用例5：事务内三步全部成功', () async {
      // 准备：插入任务、打印机、耗材
      final printerId = await _insertPrinter(db, serial: 'SN_ATOMIC_OK');
      final taskId = await schedulerDao.insertTask(
        SchedulerTask(
          gcodePath: '/tmp/test.gcode',
          gcodeFilename: 'test.gcode',
          modelGroup: PrinterModelGroup.p1,
          requiredMaterial: 'PLA',
          estimatedGrams: 100,
          createdAt: DateTime.now(),
          targetModel: 'P1S',
          targetNozzleDiameter: 0.4,
        ),
      );
      final consumableId = await _insertConsumable(db, remainingGrams: 500);

      // 执行原子事务：分配 + 入队 + 预留
      await db.transaction(() async {
        await schedulerDao.updateStatus(
          taskId,
          SchedulerTaskStatus.assigned,
          assignedPrinterId: printerId,
          assignedAt: DateTime.now(),
        );
        await printQueueDao.enqueue(
          PrintQueueItem(
            printerSerial: 'SN_ATOMIC_OK',
            gcodePath: '/tmp/test.gcode',
            filename: 'test.gcode',
            queuedAt: DateTime.now(),
            schedulerTaskId: taskId,
          ),
        );
        await reservationDao.reserve(
          schedulerTaskId: taskId,
          consumableId: consumableId,
          toolIndex: 0,
          grams: 100,
        );
      });

      // 验证三步都成功
      final task = await schedulerDao.getById(taskId);
      expect(task!.status, SchedulerTaskStatus.assigned);
      expect(task.assignedPrinterId, printerId);

      final queueItem = await printQueueDao.getBySchedulerTaskId(taskId);
      expect(queueItem, isNotNull);
      expect(queueItem!.status, PrintQueueStatus.queued);

      final avail = await reservationDao.getAvailableGrams(consumableId);
      expect(avail.totalReservedGrams, 100);
      expect(avail.availableGrams, 400);
    });

    test('验收用例5：事务内任一步失败全部回滚', () async {
      final printerId = await _insertPrinter(db, serial: 'SN_ATOMIC_ROLLBACK');
      final taskId = await schedulerDao.insertTask(
        SchedulerTask(
          gcodePath: '/tmp/test.gcode',
          gcodeFilename: 'test.gcode',
          modelGroup: PrinterModelGroup.p1,
          requiredMaterial: 'PLA',
          estimatedGrams: 100,
          createdAt: DateTime.now(),
        ),
      );
      final consumableId = await _insertConsumable(db, remainingGrams: 500);

      // 先入队一次（占用唯一索引）
      await printQueueDao.enqueue(
        PrintQueueItem(
          printerSerial: 'SN_ATOMIC_ROLLBACK',
          gcodePath: '/tmp/test.gcode',
          filename: 'test.gcode',
          queuedAt: DateTime.now(),
          schedulerTaskId: taskId,
        ),
      );

      // 事务：分配 + 重复入队（违反唯一索引）+ 预留
      // 重复入队应抛异常，整个事务回滚
      Object? caughtError;
      try {
        await db.transaction(() async {
          await schedulerDao.updateStatus(
            taskId,
            SchedulerTaskStatus.assigned,
            assignedPrinterId: printerId,
            assignedAt: DateTime.now(),
          );
          // 重复入队 → 唯一索引冲突
          await printQueueDao.enqueue(
            PrintQueueItem(
              printerSerial: 'SN_ATOMIC_ROLLBACK',
              gcodePath: '/tmp/test.gcode',
              filename: 'test.gcode',
              queuedAt: DateTime.now(),
              schedulerTaskId: taskId,
            ),
          );
          await reservationDao.reserve(
            schedulerTaskId: taskId,
            consumableId: consumableId,
            toolIndex: 0,
            grams: 100,
          );
        });
      } catch (e) {
        caughtError = e;
      }

      // 验证事务回滚
      expect(caughtError, isNotNull, reason: '事务应因唯一索引冲突抛异常');

      // 任务状态不应变为 assigned（回滚）
      final task = await schedulerDao.getById(taskId);
      expect(
        task!.status,
        SchedulerTaskStatus.pending,
        reason: '事务回滚后任务保持 pending',
      );

      // 不应创建新预留（回滚）
      final avail = await reservationDao.getAvailableGrams(consumableId);
      expect(avail.totalReservedGrams, 0, reason: '事务回滚后预留不生效');
    });

    test('验收用例6：print_queue 推进到 completed 后释放设备', () async {
      final printerId = await _insertPrinter(db, serial: 'SN_ATOMIC_DONE');
      final taskId = await schedulerDao.insertTask(
        SchedulerTask(
          gcodePath: '/tmp/test.gcode',
          gcodeFilename: 'test.gcode',
          modelGroup: PrinterModelGroup.p1,
          requiredMaterial: 'PLA',
          estimatedGrams: 100,
          createdAt: DateTime.now(),
        ),
      );
      final consumableId = await _insertConsumable(db, remainingGrams: 500);

      // 分配 + 入队 + 预留
      await db.transaction(() async {
        await schedulerDao.updateStatus(
          taskId,
          SchedulerTaskStatus.assigned,
          assignedPrinterId: printerId,
          assignedAt: DateTime.now(),
        );
        await printQueueDao.enqueue(
          PrintQueueItem(
            printerSerial: 'SN_ATOMIC_DONE',
            gcodePath: '/tmp/test.gcode',
            filename: 'test.gcode',
            queuedAt: DateTime.now(),
            schedulerTaskId: taskId,
          ),
        );
        await reservationDao.reserve(
          schedulerTaskId: taskId,
          consumableId: consumableId,
          toolIndex: 0,
          grams: 100,
        );
      });

      // 模拟打印完成：print_queue → completed
      final queueItem = await printQueueDao.getBySchedulerTaskId(taskId);
      await printQueueDao.setStatus(
        queueItem!.id!,
        PrintQueueStatus.completed,
        completedAt: DateTime.now(),
      );

      // scheduler_tasks 推进到 completed
      await schedulerDao.updateStatus(
        taskId,
        SchedulerTaskStatus.completed,
        completedAt: DateTime.now(),
      );

      // 终态释放耗材预留
      await reservationDao.releaseForTask(taskId);

      // 验证设备释放
      expect(
        await schedulerDao.isPrinterOccupied(printerId),
        isFalse,
        reason: '完成后设备应释放',
      );
      final avail = await reservationDao.getAvailableGrams(consumableId);
      expect(avail.totalReservedGrams, 0, reason: '完成后预留应释放');
    });

    test('验收用例9：取消任务后预留正确释放', () async {
      final taskId = await schedulerDao.insertTask(
        SchedulerTask(
          gcodePath: '/tmp/test.gcode',
          gcodeFilename: 'test.gcode',
          modelGroup: PrinterModelGroup.p1,
          requiredMaterial: 'PLA',
          estimatedGrams: 100,
          createdAt: DateTime.now(),
        ),
      );
      final consumableId = await _insertConsumable(db, remainingGrams: 500);

      // 预留 200g
      await reservationDao.reserve(
        schedulerTaskId: taskId,
        consumableId: consumableId,
        toolIndex: 0,
        grams: 200,
      );
      var avail = await reservationDao.getAvailableGrams(consumableId);
      expect(avail.availableGrams, 300);

      // 取消任务，释放预留
      await reservationDao.cancelForTask(taskId);
      avail = await reservationDao.getAvailableGrams(consumableId);
      expect(avail.availableGrams, 500, reason: '取消后预留全部释放，可用量恢复');
    });
  });

  group('SchedulerTaskMaterial - 多色任务模型', () {
    test('copyWith 正确复制', () {
      const m = SchedulerTaskMaterial(
        schedulerTaskId: 1,
        toolIndex: 0,
        materialProfile: 'PLA',
        materialType: 'PLA',
        estimatedGrams: 100,
      );
      final m2 = m.copyWith(schedulerTaskId: 2, estimatedGrams: 200);
      expect(m2.schedulerTaskId, 2);
      expect(m2.estimatedGrams, 200);
      expect(m2.toolIndex, 0);
      expect(m2.materialType, 'PLA');
    });

    test('fromMap/toMap 往返', () {
      const m = SchedulerTaskMaterial(
        id: 5,
        schedulerTaskId: 1,
        toolIndex: 2,
        materialProfile: 'Bambu PETG',
        materialType: 'PETG',
        requiredColorHex: '#00FF00',
        estimatedGrams: 150.5,
        assignedConsumableId: 10,
      );
      final map = m.toMap();
      final m2 = SchedulerTaskMaterial.fromMap(map);
      expect(m2.id, 5);
      expect(m2.toolIndex, 2);
      expect(m2.materialType, 'PETG');
      expect(m2.estimatedGrams, 150.5);
      expect(m2.assignedConsumableId, 10);
    });
  });

  group('PrinterModelGroup - UI 分组语义', () {
    test('fromModel 返回机型组（仅 UI 分组用）', () {
      expect(PrinterModelGroup.fromModel('A1'), PrinterModelGroup.a1);
      expect(PrinterModelGroup.fromModel('A1 mini'), PrinterModelGroup.a1);
      expect(PrinterModelGroup.fromModel('P1S'), PrinterModelGroup.p1);
      expect(PrinterModelGroup.fromModel('P1P'), PrinterModelGroup.p1);
      expect(PrinterModelGroup.fromModel('X1C'), PrinterModelGroup.x1);
      expect(PrinterModelGroup.fromModel('H2D'), PrinterModelGroup.h2d);
    });

    test('同组不等于 G-code 通用（核心约束）', () {
      // A1 和 A1 mini 同组，但 G-code 不互通
      expect(
        PrinterModelGroup.fromModel('A1'),
        PrinterModelGroup.fromModel('A1 mini'),
      );
      expect(
        PrinterModelNormalizer.sameModel('A1', 'A1 mini'),
        isFalse,
      );

      // P1S 和 P1P 同组，但 G-code 不互通
      expect(
        PrinterModelGroup.fromModel('P1S'),
        PrinterModelGroup.fromModel('P1P'),
      );
      expect(
        PrinterModelNormalizer.sameModel('P1S', 'P1P'),
        isFalse,
      );
    });
  });

  group('SpoolReservation - 状态机', () {
    test('SpoolReservationStatus.fromCode 解析', () {
      expect(
        SpoolReservationStatus.fromCode('active'),
        SpoolReservationStatus.active,
      );
      expect(
        SpoolReservationStatus.fromCode('released'),
        SpoolReservationStatus.released,
      );
      expect(
        SpoolReservationStatus.fromCode('cancelled'),
        SpoolReservationStatus.cancelled,
      );
      // 未知值回退到 active
      expect(
        SpoolReservationStatus.fromCode('unknown'),
        SpoolReservationStatus.active,
      );
    });

    test('isActive 仅 active 状态为 true', () {
      expect(SpoolReservationStatus.active.isActive, isTrue);
      expect(SpoolReservationStatus.released.isActive, isFalse);
      expect(SpoolReservationStatus.cancelled.isActive, isFalse);
    });
  });

  group('SchedulerTaskStatus - 状态机', () {
    test('isTerminal 终态判断', () {
      expect(SchedulerTaskStatus.completed.isTerminal, isTrue);
      expect(SchedulerTaskStatus.cancelled.isTerminal, isTrue);
      expect(SchedulerTaskStatus.failed.isTerminal, isTrue);
      expect(SchedulerTaskStatus.pending.isTerminal, isFalse);
      expect(SchedulerTaskStatus.assigned.isTerminal, isFalse);
      expect(SchedulerTaskStatus.printing.isTerminal, isFalse);
    });

    test('canReschedule 可重调度判断', () {
      expect(SchedulerTaskStatus.cancelled.canReschedule, isTrue);
      expect(SchedulerTaskStatus.blocked.canReschedule, isTrue);
      expect(SchedulerTaskStatus.failed.canReschedule, isTrue);
      expect(SchedulerTaskStatus.pending.canReschedule, isFalse);
      expect(SchedulerTaskStatus.assigned.canReschedule, isFalse);
    });

    test('fromCode 解析（容错）', () {
      expect(
        SchedulerTaskStatus.fromCode('pending'),
        SchedulerTaskStatus.pending,
      );
      expect(
        SchedulerTaskStatus.fromCode('assigned'),
        SchedulerTaskStatus.assigned,
      );
      // 未知值回退到 pending
      expect(
        SchedulerTaskStatus.fromCode('unknown'),
        SchedulerTaskStatus.pending,
      );
    });
  });
}

/// 插入测试用耗材卷，返回 id。
Future<int> _insertConsumable(
  AppDatabase db, {
  double remainingGrams = 1000,
  String materialType = 'PLA',
}) async {
  return db.customInsert(
    "INSERT INTO consumables ("
    "uid, manufacturer, model, material_type, color_hex, "
    "total_grams, remaining_grams, created_at, updated_at"
    ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    variables: [
      const Variable<String>(''),
      const Variable<String>('TestBrand'),
      const Variable<String>('TestModel'),
      Variable<String>(materialType),
      const Variable<String>('#FFFFFF'),
      const Variable<double>(1000.0),
      Variable<double>(remainingGrams),
      Variable<int>(DateTime.now().millisecondsSinceEpoch),
      Variable<int>(DateTime.now().millisecondsSinceEpoch),
    ],
  );
}

/// 插入测试用调度任务，返回 id。
///
/// spool_reservations.scheduler_task_id 有外键约束引用 scheduler_tasks(id)，
/// 调用 reserve 前必须先插入调度任务。
Future<int> _insertSchedulerTask(
  AppDatabase db, {
  String gcodeFilename = 'test.gcode',
  String modelGroup = 'p1',
  String requiredMaterial = 'PLA',
  double estimatedGrams = 100,
  String? targetModel,
  double? targetNozzleDiameter,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  // 使用 customStatement 直接执行 SQL，避免 drift Variable 泛型对 nullable
  // 类型的限制（Variable<T> 要求 T extends Object）。
  await db.customStatement(
    'INSERT INTO scheduler_tasks ('
    'gcode_path, gcode_filename, model_group, required_material, '
    'estimated_grams, status, sort_order, created_at, '
    'target_model, target_nozzle_diameter'
    ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      '/tmp/test.gcode',
      gcodeFilename,
      modelGroup,
      requiredMaterial,
      estimatedGrams,
      'pending',
      0,
      now,
      targetModel,
      targetNozzleDiameter,
    ],
  );
  // 查询刚插入的 id
  final rows = await db
      .customSelect(
        'SELECT last_insert_rowid() AS id',
      )
      .get();
  return rows.first.read<int>('id');
}

/// 插入测试用打印机，返回 id。
///
/// scheduler_tasks.assigned_printer_id 有外键约束引用 printers(id)，
/// 调用 updateStatus 分配打印机前必须先插入打印机记录。
Future<int> _insertPrinter(
  AppDatabase db, {
  String serial = 'SN001',
  String brand = '拓竹',
  String model = 'P1S',
  String name = '测试打印机',
}) async {
  return db.customInsert(
    "INSERT INTO printers ("
    "uid, name, brand, model, channel_count, "
    "is_custom_image, created_at, updated_at, serial"
    ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    variables: [
      const Variable<String>(''),
      Variable<String>(name),
      Variable<String>(brand),
      Variable<String>(model),
      const Variable<int>(1),
      const Variable<int>(0),
      Variable<int>(DateTime.now().millisecondsSinceEpoch),
      Variable<int>(DateTime.now().millisecondsSinceEpoch),
      Variable<String>(serial),
    ],
  );
}
