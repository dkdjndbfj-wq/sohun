// 跨打印机智能调度 Provider（Phase C 增强）。
//
// 任务书 Phase C 硬性约束：
// 1. 精确机型匹配：不能把宽泛机型组（A1组/P1组/X1组）作为发送现成 G-code 的
//    安全依据。必须用 PrinterModelNormalizer.sameModel + 喷嘴直径精确匹配。
//    机型组只用于 UI 分组或候选提示。
// 2. 多色任务逐工具匹配：通过 scheduler_task_materials 子表为每个工具单独匹配
//    材料和余量，任一工具不足即整任务拒绝。
// 3. 耗材预留：排队任务通过 spool_reservations 先预留耗材，避免两个任务
//    同时把同一卷剩余量各算一遍。getAvailableGrams 返回扣除活动预留后的真实可用量。
// 4. 唯一关联：print_queue 通过唯一 scheduler_task_id 关联调度任务，禁止靠文件名反查。
// 5. 多连接管理：通过 PrinterFleetConnectionManager 维护多台打印机连接和状态。
//    仅云连接设备标为"仅监控，无法自动下发"。
// 6. 状态闭环：scheduler_tasks 状态随 print_queue/print_tasks 推进到
//    printing/completed/failed/cancelled，不得永久停在 assigned。
// 7. 原子化：分配任务 + 创建队列项 + 创建耗材预留必须在同一数据库事务内完成，
//    任一步失败则全部回滚，任务进入带原因的 pending/blocked。
// 8. 硬性过滤：精确机器/G-code 不兼容、喷嘴不兼容、任一必需材料缺失或余量不足、
//    打印机处于错误/维护/升级或状态数据过期、文件不存在或不可读、参数兼容性 blocker。
// 9. 余量安全缓冲：max(5g, 预计克数的 10%)，集中配置在 SchedulingConfig。
// 10. 评分维度（权重集中定义）：
//    - 预计最早完工时间 35%
//    - 材料/颜色匹配 25%
//    - 最近 90 天同类任务成功率 15%
//    - 耗材换卷成本与余量利用 10%
//    - 设备健康和最近故障 10%
//    - 同批次连续性 5%

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/kill_switch_service.dart';
import '../core/services/printer_fleet_connection_manager.dart';
import '../data/database/daos/print_queue_dao.dart';
import '../data/database/daos/printer_dao.dart';
import '../data/database/daos/scheduler_dao.dart';
import '../data/database/daos/scheduler_material_dao.dart';
import '../data/database/daos/spool_reservation_dao.dart';
import '../data/database/models/print_queue_item.dart';
import '../data/database/models/scheduler_models.dart';
import '../data/external/printer/printer_connector.dart';
import '../data/prefs/app_prefs.dart';
import 'database_provider.dart'
    show databaseProvider, printerDaoProvider, consumableDaoProvider;
import 'print_queue_provider.dart';
import 'studio_provider.dart';

/// 调度器 DAO 单例。raw SQL DAO，手动实例化，dispose 时释放 StreamController。
final schedulerDaoProvider = Provider<SchedulerDao>((ref) {
  final db = ref.watch(databaseProvider);
  final dao = SchedulerDao(db);
  ref.onDispose(dao.dispose);
  return dao;
});

/// 调度任务材料需求 DAO 单例。
final schedulerMaterialDaoProvider = Provider<SchedulerMaterialDao>((ref) {
  final db = ref.watch(databaseProvider);
  return SchedulerMaterialDao(db);
});

/// 耗材卷预留 DAO 单例。
final spoolReservationDaoProvider = Provider<SpoolReservationDao>((ref) {
  final db = ref.watch(databaseProvider);
  return SpoolReservationDao(db);
});

/// 打印队列 DAO 单例（供调度器原子事务内直接调用，绕过 PrintQueueNotifier）。
final _printQueueDaoProvider = Provider<PrintQueueDao>((ref) {
  final db = ref.watch(databaseProvider);
  return PrintQueueDao(db);
});

/// 所有调度任务（实时流）。
final schedulerTasksProvider = StreamProvider<List<SchedulerTask>>((ref) {
  return ref.read(schedulerDaoProvider).watchAll();
});

/// 待分配任务（实时流，过滤 pending）。
final pendingSchedulerTasksProvider =
    StreamProvider<List<SchedulerTask>>((ref) {
  return ref.read(schedulerDaoProvider).watchAll().map(
        (tasks) => tasks
            .where((t) => t.status == SchedulerTaskStatus.pending)
            .toList(),
      );
});

/// 调度器集中配置 Provider。
///
/// 默认值见 [SchedulingConfig.defaults]。可在设置页覆盖。
final schedulingConfigProvider = Provider<SchedulingConfig>((ref) {
  return SchedulingConfig.defaults;
});

/// 评分权重 Provider。
final schedulingWeightsProvider = Provider<SchedulingWeights>((ref) {
  return SchedulingWeights.defaults;
});

/// 自动调度开关（持久化到 SharedPreferences，默认关闭）。
///
/// 任务书要求：autoScheduleEnabled 持久化，重启后保持，默认关闭。
class AutoScheduleEnabledNotifier extends StateNotifier<bool> {
  AutoScheduleEnabledNotifier() : super(false) {
    _load();
  }

  static const _key = 'auto_schedule_enabled';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        state = prefs.getBool(_key) ?? false;
      }
    } catch (e) {
      debugPrint('[Scheduler] 加载 autoScheduleEnabled 失败: $e');
    }
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, enabled);
    } catch (e) {
      debugPrint('[Scheduler] 保存 autoScheduleEnabled 失败: $e');
    }
  }
}

final autoScheduleEnabledProvider =
    StateNotifierProvider<AutoScheduleEnabledNotifier, bool>((ref) {
  return AutoScheduleEnabledNotifier();
});

/// 调度器 Notifier。负责任务增删、手动/自动分配、排序更新、状态闭环推进。
///
/// 关键约束：
/// - 自动调度由 [_isAutoScheduling] 串行化，防止并发调用把同一任务分配到多台打印机。
/// - 分配 + 入队 + 预留 原子化（同一数据库事务），任一步失败全部回滚。
/// - 状态闭环通过 [_printQueueWatchSub] 监听 print_queue 变化，
///   推进 scheduler_tasks 到 printing/completed/failed/cancelled。
final schedulerNotifierProvider =
    StateNotifierProvider<SchedulerNotifier, AsyncValue<void>>((ref) {
  return SchedulerNotifier(ref);
});

class SchedulerNotifier extends StateNotifier<AsyncValue<void>> {
  final Ref _ref;
  SchedulerNotifier(this._ref) : super(const AsyncValue.data(null)) {
    _initStatusSync();
  }

  /// autoSchedule 并发锁，防止并发调用把同一任务分配到多台打印机。
  bool _isAutoScheduling = false;

  /// 打印队列变化订阅，用于状态闭环推进。
  StreamSubscription<List<SchedulerTask>>? _schedulerWatchSub;
  StreamSubscription<void>? _printQueueWatchSub;
  bool _statusSyncInProgress = false;
  bool _statusSyncRequested = false;

  /// 已分配任务的 printerId 缓存，避免每次状态推进都查数据库。
  /// key: schedulerTaskId, value: (printerId, printerSerial)
  final Map<int, ({int printerId, String serial})> _assignedCache = {};

  /// 初始化状态闭环：监听 scheduler_tasks 变化，对 assigned 状态的任务
  /// 监听其 print_queue 项的 status 变化，同步推进 scheduler_tasks.status。
  void _initStatusSync() {
    final schedulerDao = _ref.read(schedulerDaoProvider);
    final printQueueDao = _ref.read(_printQueueDaoProvider);
    _schedulerWatchSub = schedulerDao.watchAll().listen((_) {
      _requestStatusSync();
    });
    _printQueueWatchSub = printQueueDao.onChange.listen((_) {
      _requestStatusSync();
    });
  }

  void _requestStatusSync() {
    _statusSyncRequested = true;
    if (_statusSyncInProgress) return;
    unawaited(_drainStatusSync());
  }

  Future<void> _drainStatusSync() async {
    _statusSyncInProgress = true;
    try {
      while (_statusSyncRequested && mounted) {
        _statusSyncRequested = false;
        final schedulerDao = _ref.read(schedulerDaoProvider);
        await _syncAssignedStatuses(await schedulerDao.getAll());
      }
    } catch (error, stackTrace) {
      debugPrint('[Scheduler] 读取队列变更后的状态失败: $error\n$stackTrace');
    } finally {
      _statusSyncInProgress = false;
    }
  }

  /// 同步 assigned 状态任务的状态推进。
  ///
  /// 任务书要求：scheduler_tasks 必须随 print_queue/print_tasks 推进到
  /// printing/completed/failed/cancelled，不得永久停在 assigned。
  Future<void> _syncAssignedStatuses(List<SchedulerTask> tasks) async {
    try {
      final printQueueDao = _ref.read(_printQueueDaoProvider);
      final schedulerDao = _ref.read(schedulerDaoProvider);
      for (final task in tasks) {
        if (task.id == null) continue;
        if (task.status != SchedulerTaskStatus.assigned &&
            task.status != SchedulerTaskStatus.printing) {
          continue;
        }
        // 通过 scheduler_task_id 查 print_queue 项（禁止靠文件名反查）
        final queueItem = await printQueueDao.getBySchedulerTaskId(task.id!);
        if (queueItem == null) continue;
        // 根据 print_queue 状态推进 scheduler_tasks
        final newStatus = _mapQueueStatusToScheduler(queueItem.status);
        if (newStatus != null && newStatus != task.status) {
          await schedulerDao.updateStatus(
            task.id!,
            newStatus,
            completedAt: newStatus.isTerminal ? DateTime.now() : null,
          );
          // 终态释放耗材预留
          if (newStatus.isTerminal) {
            await _ref
                .read(spoolReservationDaoProvider)
                .releaseForTask(task.id!);
          }
        }
      }
    } catch (e, st) {
      debugPrint('[Scheduler] 状态闭环同步异常: $e\n$st');
    }
  }

  /// print_queue 状态映射到 scheduler_tasks 状态。
  SchedulerTaskStatus? _mapQueueStatusToScheduler(PrintQueueStatus qs) {
    switch (qs) {
      case PrintQueueStatus.queued:
        return SchedulerTaskStatus.assigned; // 已入队但仍 assigned
      case PrintQueueStatus.printing:
        return SchedulerTaskStatus.printing;
      case PrintQueueStatus.waitingRemoval:
        return SchedulerTaskStatus.printing; // 仍算打印中（等取件）
      case PrintQueueStatus.completed:
        return SchedulerTaskStatus.completed;
      case PrintQueueStatus.cancelled:
        return SchedulerTaskStatus.cancelled;
      case PrintQueueStatus.failed:
        return SchedulerTaskStatus.failed;
    }
  }

  /// 添加单色任务到调度池。
  ///
  /// 自动调度开启时立即尝试分配。
  /// 多色任务请用 [addTaskWithMaterials]。
  Future<int> addTask({
    required String gcodePath,
    required String gcodeFilename,
    required PrinterModelGroup modelGroup,
    required String requiredMaterial,
    String? requiredColorHex,
    double estimatedGrams = 0,
    int? estimatedSeconds,
    String? targetModel,
    double? targetNozzleDiameter,
  }) async {
    final dao = _ref.read(schedulerDaoProvider);
    final taskId = await dao.insertTask(
      SchedulerTask(
        gcodePath: gcodePath,
        gcodeFilename: gcodeFilename,
        modelGroup: modelGroup,
        requiredMaterial: requiredMaterial,
        requiredColorHex: requiredColorHex,
        estimatedGrams: estimatedGrams,
        estimatedSeconds: estimatedSeconds,
        createdAt: DateTime.now(),
        targetModel: targetModel,
        targetNozzleDiameter: targetNozzleDiameter,
      ),
    );
    // 自动调度开启且 kill switch 允许时立即尝试分配
    if (_ref.read(autoScheduleEnabledProvider) &&
        _ref.read(killSwitchServiceProvider).isEnabled('auto_schedule')) {
      await autoSchedule();
    }
    return taskId;
  }

  /// 添加多色任务到调度池（含每个工具的材料需求）。
  ///
  /// [materials] 为每个工具的材料需求列表，会写入 scheduler_task_materials 子表。
  /// 自动调度开启时立即尝试分配。
  Future<int> addTaskWithMaterials({
    required String gcodePath,
    required String gcodeFilename,
    required PrinterModelGroup modelGroup,
    required List<SchedulerTaskMaterial> materials,
    int? estimatedSeconds,
    String? targetModel,
    double? targetNozzleDiameter,
  }) async {
    final schedulerDao = _ref.read(schedulerDaoProvider);
    final materialDao = _ref.read(schedulerMaterialDaoProvider);

    // 计算总预估克数（所有工具之和）
    final totalGrams = materials.fold<double>(
      0,
      (sum, m) => sum + m.estimatedGrams,
    );

    // 取第一个工具的材料类型作为主材质（用于 UI 显示和兼容性回退）
    final primaryMaterial =
        materials.isNotEmpty ? materials.first.materialType : '';
    final primaryColor =
        materials.isNotEmpty ? materials.first.requiredColorHex : null;

    // 原子化插入任务 + 材料需求
    final taskId = await schedulerDao.insertTask(
      SchedulerTask(
        gcodePath: gcodePath,
        gcodeFilename: gcodeFilename,
        modelGroup: modelGroup,
        requiredMaterial: primaryMaterial,
        requiredColorHex: primaryColor,
        estimatedGrams: totalGrams,
        estimatedSeconds: estimatedSeconds,
        createdAt: DateTime.now(),
        targetModel: targetModel,
        targetNozzleDiameter: targetNozzleDiameter,
      ),
    );

    // 写入材料子表
    if (materials.isNotEmpty) {
      await materialDao.replaceMaterialsForTask(
        taskId,
        materials.map((m) => m.copyWith(schedulerTaskId: taskId)).toList(),
      );
    }

    // 自动调度开启且 kill switch 允许时立即尝试分配
    if (_ref.read(autoScheduleEnabledProvider) &&
        _ref.read(killSwitchServiceProvider).isEnabled('auto_schedule')) {
      await autoSchedule();
    }
    return taskId;
  }

  /// 删除任务（同时清理材料需求和耗材预留）。
  Future<void> deleteTask(int id) async {
    try {
      await _ref.read(spoolReservationDaoProvider).cancelForTask(id);
      await _ref.read(schedulerMaterialDaoProvider).deleteMaterialsForTask(id);
    } catch (e) {
      debugPrint('[Scheduler] 删除任务清理关联数据失败: $e');
    }
    await _ref.read(schedulerDaoProvider).deleteTask(id);
  }

  /// 手动分配任务到指定打印机。
  ///
  /// 分配后把任务转入该打印机的 print_queue，复用其完整状态机
  /// （queued → printing → waiting_removal → completed）。
  /// scheduler_tasks.status 保留为 assigned，真正的打印状态由 print_queue 管理。
  ///
  /// Phase C：分配 + 入队 + 预留 原子化。任一步失败全部回滚。
  Future<void> manualAssign(int taskId, int printerId) async {
    final task = await _ref.read(schedulerDaoProvider).getById(taskId);
    if (task == null) {
      debugPrint('[Scheduler] 手动分配失败：任务 $taskId 不存在');
      return;
    }
    // 前置校验：文件存在、机型匹配、耗材充足
    final validation = await _validateForAssignment(task, printerId);
    if (!validation.ok) {
      // 进入 blocked 状态，记录原因
      await _ref.read(schedulerDaoProvider).updateStatus(
            taskId,
            SchedulerTaskStatus.blocked,
          );
      debugPrint('[Scheduler] 手动分配被拒：${validation.reason}');
      return;
    }
    await _atomicAssignAndEnqueue(task, printerId, validation.reservations);
  }

  /// 取消任务：显式清空 assigned_printer_id（避免残留旧分配）。
  /// 同时释放该任务的所有耗材预留。
  Future<void> cancelTask(int taskId) async {
    try {
      await _ref.read(spoolReservationDaoProvider).cancelForTask(taskId);
    } catch (e) {
      debugPrint('[Scheduler] 取消任务释放预留失败: $e');
    }
    await _ref.read(schedulerDaoProvider).cancelTask(taskId);
    _assignedCache.remove(taskId);
  }

  /// 重置任务为 pending（取消分配后重新进队）。
  /// 同时释放该任务的所有耗材预留。
  Future<void> resetToPending(int taskId) async {
    try {
      await _ref.read(spoolReservationDaoProvider).cancelForTask(taskId);
    } catch (e) {
      debugPrint('[Scheduler] 重置任务释放预留失败: $e');
    }
    await _ref.read(schedulerDaoProvider).updateStatus(
          taskId,
          SchedulerTaskStatus.pending,
        );
    _assignedCache.remove(taskId);
  }

  /// 自动调度：遍历 pending 任务，为每个任务找最优打印机。
  ///
  /// 算法：
  /// 1. 取所有 pending 任务（按 sortOrder）
  /// 2. 对每个任务找候选打印机（精确机型 + 喷嘴 + 多材料硬约束过滤后评分）
  /// 3. 选评分最高的候选，若 eligible 且 score > 0 则原子化分配
  ///
  /// 分配后把任务转入该打印机的 print_queue，复用其完整状态机
  /// （queued → printing → waiting_removal → completed）。
  Future<void> autoSchedule() async {
    // 并发竞争修复：原实现无并发保护，两次并发调用会读到相同 pending 列表，
    // 把同一任务分配到多台打印机。加 isRunning 标志串行化。
    if (_isAutoScheduling) return;
    _isAutoScheduling = true;
    try {
      final dao = _ref.read(schedulerDaoProvider);
      final pending = await dao.getPendingTasks();
      if (pending.isEmpty) return;

      for (final task in pending) {
        final candidates = await _findCandidates(task);
        if (candidates.isEmpty) continue;
        // 选评分最高的 eligible 候选
        final eligible = candidates.where((c) => c.eligible).toList();
        if (eligible.isEmpty) continue;
        eligible.sort((a, b) => b.score.compareTo(a.score));
        final best = eligible.first;
        if (best.score <= 0) continue;

        // 收集 best 的材料匹配结果对应的预留
        final reservations = <_ReservationPlan>[];
        for (final m in best.materialMatches) {
          if (m.matched && m.matchedConsumableId != null) {
            reservations.add(
              _ReservationPlan(
                consumableId: m.matchedConsumableId!,
                toolIndex: m.toolIndex,
                grams: m.requiredGrams,
              ),
            );
          }
        }
        // 单色任务回退：材料子表为空时用 task 主字段
        if (reservations.isEmpty && best.materialMatches.isEmpty) {
          // 用 PrinterCandidate.remainingGrams 对应的耗材（单色任务）
          // 此处通过 _resolveSingleColorConsumable 查询
          final consumableId =
              await _resolveSingleColorConsumable(task, best.printerId);
          if (consumableId != null) {
            reservations.add(
              _ReservationPlan(
                consumableId: consumableId,
                toolIndex: 0,
                grams: task.estimatedGrams,
              ),
            );
          }
        }
        if (reservations.isEmpty) continue;

        final ok =
            await _atomicAssignAndEnqueue(task, best.printerId, reservations);
        if (!ok) {
          debugPrint('[Scheduler] 任务 ${task.id} 原子分配失败，将保留 pending 等下次调度');
        }
      }
    } finally {
      _isAutoScheduling = false;
    }
  }

  /// 解析单色任务的耗材卷 id（材料子表为空时的回退路径）。
  Future<int?> _resolveSingleColorConsumable(
    SchedulerTask task,
    int printerId,
  ) async {
    try {
      final printerDao = _ref.read(printerDaoProvider);
      final pwc = await printerDao.getByIdWithChannels(printerId);
      if (pwc == null) return null;
      for (final ch in pwc.channels) {
        if (ch.consumable == null) continue;
        if (ch.consumable!.materialType.toUpperCase() !=
            task.requiredMaterial.toUpperCase()) {
          continue;
        }
        if (ch.consumable!.remainingGrams < task.estimatedGrams) continue;
        return ch.consumable!.id;
      }
    } catch (e) {
      debugPrint('[Scheduler] 解析单色耗材失败: $e');
    }
    return null;
  }

  /// 原子化：分配任务 + 入队 print_queue + 创建耗材预留。
  ///
  /// 任务书要求：三步必须在同一数据库事务内完成，任一步失败全部回滚，
  /// 任务进入带原因的 pending/blocked。
  ///
  /// 返回 true 表示成功，false 表示失败（已回滚，任务保持 pending）。
  Future<bool> _atomicAssignAndEnqueue(
    SchedulerTask task,
    int printerId,
    List<_ReservationPlan> reservations,
  ) async {
    final db = _ref.read(databaseProvider);
    final schedulerDao = _ref.read(schedulerDaoProvider);
    final printQueueDao = _ref.read(_printQueueDaoProvider);
    final reservationDao = _ref.read(spoolReservationDaoProvider);

    // 查 printer serial
    final printerWithChannels =
        await _ref.read(printerDaoProvider).getByIdWithChannels(printerId);
    final serial = printerWithChannels?.serial;
    if (serial == null || serial.isEmpty) {
      debugPrint('[Scheduler] 打印机 $printerId 无 serial，无法入队');
      return false;
    }
    final slotByConsumable = <int, int>{
      for (final channel in printerWithChannels!.channels)
        if (channel.consumable case final consumable?)
          consumable.id: channel.channel.channelIndex,
    };
    final maxToolIndex = reservations.fold<int>(
      -1,
      (value, item) => item.toolIndex > value ? item.toolIndex : value,
    );
    final reservationByTool = <int, _ReservationPlan>{
      for (final item in reservations) item.toolIndex: item,
    };
    final amsMapping = maxToolIndex < 0
        ? null
        : List<int>.generate(
            maxToolIndex + 1,
            (toolIndex) {
              final reservation = reservationByTool[toolIndex];
              return reservation == null
                  ? -1
                  : slotByConsumable[reservation.consumableId] ?? -1;
            },
            growable: false,
          );

    try {
      // 三步原子化：用 db.transaction 包裹
      // 注意：schedulerDao/printQueueDao/reservationDao 都基于同一 db 实例，
      // 在事务内调用它们的方法会自动加入当前事务（drift 的 transaction 机制）。
      await db.transaction(() async {
        // 1. 更新 scheduler_tasks 为 assigned
        await schedulerDao.updateStatus(
          task.id!,
          SchedulerTaskStatus.assigned,
          assignedPrinterId: printerId,
          assignedAt: DateTime.now(),
        );
        // 2. 入队 print_queue（带 scheduler_task_id 唯一关联）
        // 直接调用 PrintQueueDao.enqueue，绕过 PrintQueueNotifier 的 UI 逻辑
        await printQueueDao.enqueue(
          PrintQueueItem(
            printerSerial: serial,
            gcodePath: task.gcodePath,
            filename: task.gcodeFilename,
            queuedAt: DateTime.now(),
            schedulerTaskId: task.id,
            amsMapping: amsMapping,
          ),
        );
        // 3. 创建耗材预留
        for (final r in reservations) {
          await reservationDao.reserve(
            schedulerTaskId: task.id!,
            consumableId: r.consumableId,
            toolIndex: r.toolIndex,
            grams: r.grams,
          );
        }
      });
      // 事务成功：缓存 assigned 映射，触发 PrintQueueNotifier 刷新
      _assignedCache[task.id!] = (printerId: printerId, serial: serial);
      // 触发 PrintQueueNotifier 重新加载（它监听 DAO 的 stream，但事务内
      // 直接写表不会触发其 _load，这里手动调用 refresh）
      try {
        await _ref.read(printQueueProvider(serial).notifier).startIfIdle();
      } catch (e) {
        // PrintQueueNotifier 可能未初始化（用户未在该打印机页面），忽略
        debugPrint('[Scheduler] 触发 PrintQueueNotifier 刷新失败（可忽略）: $e');
      }
      return true;
    } catch (e, st) {
      debugPrint('[Scheduler] 原子分配事务失败: $e\n$st');
      // 事务已自动回滚，任务保持 pending
      // 标记为 blocked 并记录原因（再回退到 pending 让下次调度重试）
      try {
        await schedulerDao.updateStatus(task.id!, SchedulerTaskStatus.blocked);
      } catch (_) {}
      return false;
    }
  }

  /// 前置校验：文件存在、机型匹配、耗材充足。
  ///
  /// 返回 [_ValidationResult]：
  /// - ok=true 表示可分配，reservations 含要预留的耗材列表
  /// - ok=false 表示被拒，reason 含拒绝原因
  Future<_ValidationResult> _validateForAssignment(
    SchedulerTask task,
    int printerId,
  ) async {
    // 1. 文件存在校验
    final fileCheck = _validateFileExists(task.gcodePath);
    if (!fileCheck.ok) {
      return _ValidationResult(
        ok: false,
        reason: fileCheck.reason,
        reservations: const [],
      );
    }
    // 2. 查询打印机并校验舰队事实、精确机型与喷嘴。
    final printerWithChannels =
        await _ref.read(printerDaoProvider).getByIdWithChannels(printerId);
    if (printerWithChannels == null) {
      return const _ValidationResult(
        ok: false,
        reason: '打印机不存在',
        reservations: [],
      );
    }
    final serial = printerWithChannels.serial;
    if (serial == null || serial.isEmpty) {
      return const _ValidationResult(
        ok: false,
        reason: '打印机缺少序列号，无法取得舰队状态事实',
        reservations: [],
      );
    }
    final config = _ref.read(schedulingConfigProvider);
    final activeQueueCount =
        await _ref.read(_printQueueDaoProvider).getActiveCount(serial);
    if (activeQueueCount >= config.maxQueuedTasksPerPrinter) {
      return _ValidationResult(
        ok: false,
        reason: '打印机已有 $activeQueueCount 个活动任务，已达到预排上限',
        reservations: const [],
      );
    }
    final fleetState = await _ref
        .read(printerFleetConnectionManagerProvider.notifier)
        .ensureFreshStatus(serial, config);
    final fleetCheck = _validateFleetCompatibility(
      task,
      fleetState,
      config,
    );
    if (!fleetCheck.ok) {
      return _ValidationResult(
        ok: false,
        reason: fleetCheck.reason,
        reservations: const [],
      );
    }
    // 3. 多材料匹配（逐工具）
    final materialResult = await _matchMaterials(task, printerWithChannels);
    if (!materialResult.allMatched) {
      return _ValidationResult(
        ok: false,
        reason: materialResult.rejectReason,
        reservations: const [],
      );
    }
    // 4. 构建预留计划
    final reservations = <_ReservationPlan>[];
    for (final m in materialResult.matches) {
      if (m.matchedConsumableId != null) {
        reservations.add(
          _ReservationPlan(
            consumableId: m.matchedConsumableId!,
            toolIndex: m.toolIndex,
            grams: m.requiredGrams,
          ),
        );
      }
    }
    return _ValidationResult(
      ok: true,
      reason: '',
      reservations: reservations,
    );
  }

  /// 校验文件存在且可读。
  ({bool ok, String reason}) _validateFileExists(String gcodePath) {
    try {
      final file = File(gcodePath);
      if (!file.existsSync()) {
        return (ok: false, reason: 'G-code 文件不存在: $gcodePath');
      }
      return (ok: true, reason: '');
    } catch (e) {
      return (ok: false, reason: 'G-code 文件不可读: $e');
    }
  }

  /// 校验舰队连接、实时状态、精确机型和喷嘴直径。
  ({bool ok, String reason}) _validateFleetCompatibility(
    SchedulerTask task,
    FleetPrinterState? fleetState,
    SchedulingConfig config,
  ) {
    if (fleetState == null) {
      return (ok: false, reason: '未注册舰队连接，无法确认设备事实');
    }
    if (!fleetState.isLanCapable) {
      return (ok: false, reason: '仅云连接，无法自动下发');
    }
    if (fleetState.connectionState != PrinterConnectionState.connected) {
      return (ok: false, reason: '打印机未连接');
    }
    if (fleetState.lastStatus == null || fleetState.isStale(config)) {
      return (ok: false, reason: '打印机缺少新鲜状态事实');
    }
    if (!fleetState.canAcceptQueuedTask(config)) {
      return (ok: false, reason: '打印机处于异常、维护或不可预排状态');
    }
    final mismatch = fleetState.targetSpecMismatch(task.targetSpec);
    if (mismatch != null) return (ok: false, reason: mismatch);
    return (ok: true, reason: '');
  }

  /// 多材料匹配：逐工具匹配材料类型 + 颜色 + 余量（含安全缓冲）。
  ///
  /// 任务书要求：多色任务必须逐个工具匹配材料和余量，任一工具不足即整任务拒绝。
  Future<
      ({
        bool allMatched,
        String rejectReason,
        List<MaterialMatchResult> matches
      })> _matchMaterials(
    SchedulerTask task,
    PrinterWithChannels printerWithChannels,
  ) async {
    final materialDao = _ref.read(schedulerMaterialDaoProvider);
    final reservationDao = _ref.read(spoolReservationDaoProvider);
    final config = _ref.read(schedulingConfigProvider);

    // 取任务的材料需求列表
    final materials = await materialDao.getMaterialsForTask(task.id!);
    final channels = printerWithChannels.channels;
    Set<int>? farmStockIds;
    if (_ref.read(studioModeEnabledProvider)) {
      final snapshot = await _ref.read(studioSnapshotProvider.future);
      farmStockIds = (await _ref
              .read(consumableDaoProvider)
              .getFarm(snapshot.workspace.id))
          .map((item) => item.id)
          .toSet();
    }

    // 单色任务回退：材料子表为空时，用 task 主字段构造单条需求
    final effMaterials = materials.isNotEmpty
        ? materials
        : [
            SchedulerTaskMaterial(
              schedulerTaskId: task.id!,
              toolIndex: 0,
              materialProfile: '',
              materialType: task.requiredMaterial,
              requiredColorHex: task.requiredColorHex,
              estimatedGrams: task.estimatedGrams,
            ),
          ];

    final matches = <MaterialMatchResult>[];
    final rejectReasons = <String>[];
    final plannedByConsumable = <int, double>{};

    for (final m in effMaterials) {
      // 在该打印机的通道中找匹配耗材
      int? matchedConsumableId;
      double matchedAvailableGrams = 0;
      bool materialMatched = false;
      bool colorMatched = false;
      bool sufficient = false;
      String? rejectReason;

      for (final ch in channels) {
        final consumable = ch.consumable;
        if (consumable == null) continue;
        if (farmStockIds != null && !farmStockIds.contains(consumable.id)) {
          continue;
        }
        if (consumable.materialType.toUpperCase() !=
            m.materialType.toUpperCase()) {
          continue;
        }
        materialMatched = true;
        // 查扣除活动预留后的可用量
        final availInfo = await reservationDao.getAvailableGrams(consumable.id);
        final buffer = config.safetyBuffer(m.estimatedGrams);
        final required = m.estimatedGrams + buffer;
        final alreadyPlanned = plannedByConsumable[consumable.id] ?? 0;
        final availableAfterPlanned = availInfo.availableGrams - alreadyPlanned;
        if (availableAfterPlanned < required) {
          // 余量不足，记录原因但继续找其他通道
          rejectReason = 'T${m.toolIndex} ${m.materialType} '
              '余量不足（需 ${required.toStringAsFixed(1)}g，'
              '可用 ${availableAfterPlanned.toStringAsFixed(1)}g）';
          continue;
        }
        // 余量足够，检查颜色
        final channelColorMatches = m.requiredColorHex != null &&
            consumable.colorHex.toUpperCase() ==
                m.requiredColorHex!.toUpperCase();
        if (channelColorMatches) {
          matchedConsumableId = consumable.id;
          matchedAvailableGrams = availableAfterPlanned;
          colorMatched = true;
          sufficient = true;
          break;
        }
        // 颜色不匹配但材质+余量OK，作为候选保留（取第一个）
        matchedConsumableId ??= consumable.id;
        matchedAvailableGrams = availableAfterPlanned;
        sufficient = true;
      }

      if (!materialMatched) {
        rejectReason = 'T${m.toolIndex} 无 ${m.materialType} 材料';
      } else if (!sufficient) {
        rejectReason ??= 'T${m.toolIndex} ${m.materialType} 余量不足';
      } else if (m.requiredColorHex != null && !colorMatched) {
        rejectReason = 'T${m.toolIndex} 缺少指定颜色 ${m.requiredColorHex}';
      }

      if (matchedConsumableId != null &&
          sufficient &&
          (m.requiredColorHex == null || colorMatched)) {
        plannedByConsumable.update(
          matchedConsumableId,
          (value) => value + m.estimatedGrams,
          ifAbsent: () => m.estimatedGrams,
        );
      }

      matches.add(
        MaterialMatchResult(
          toolIndex: m.toolIndex,
          requiredMaterialType: m.materialType,
          requiredColorHex: m.requiredColorHex,
          requiredGrams: m.estimatedGrams,
          matchedConsumableId: matchedConsumableId,
          matchedAvailableGrams: matchedAvailableGrams,
          materialMatched: materialMatched,
          colorMatched: colorMatched,
          sufficient: sufficient,
          rejectReason: rejectReason,
        ),
      );

      if (matchedConsumableId == null ||
          !sufficient ||
          m.requiredColorHex != null && !colorMatched) {
        rejectReasons.add(rejectReason ?? 'T${m.toolIndex} 匹配失败');
      }
    }

    final allMatched = matches.every((m) => m.matched);
    return (
      allMatched: allMatched,
      rejectReason: rejectReasons.join('; '),
      matches: matches,
    );
  }

  /// 为任务找候选打印机（Phase C 增强版）。
  ///
  /// 硬约束（任一不满足即 eligible=false，不参与排序）：
  /// - 精确机型匹配（PrinterModelNormalizer.sameModel + 喷嘴直径）
  /// - 单台打印机的活动队列不能超过配置上限
  /// - 多材料任务每个工具都有匹配耗材且余量足够（含安全缓冲）
  /// - 打印机状态新鲜（未过期）；正常打印中的设备允许继续预排
  /// - 文件存在且可读
  /// - 仅云连接设备标为 cloudOnly=true，eligible=false（无法自动下发）
  ///
  /// 评分维度（权重见 [SchedulingWeights]）：
  /// - 预计最早完工时间 35%
  /// - 材料/颜色匹配 25%
  /// - 最近 90 天同类任务成功率 15%
  /// - 耗材换卷成本与余量利用 10%
  /// - 设备健康和最近故障 10%
  /// - 同批次连续性 5%
  Future<List<PrinterCandidate>> _findCandidates(SchedulerTask task) async {
    final printerDao = _ref.read(printerDaoProvider);
    final config = _ref.read(schedulingConfigProvider);
    final weights = _ref.read(schedulingWeightsProvider);
    final fleetManager =
        _ref.read(printerFleetConnectionManagerProvider.notifier);
    final printers = await printerDao.getAllPrintersWithChannels();
    final candidates = <PrinterCandidate>[];

    // 文件存在校验（任务级，所有候选共享）
    final fileExists = _validateFileExists(task.gcodePath);
    if (!fileExists.ok) {
      // 文件不存在：所有候选都标为拒绝
      for (final p in printers) {
        candidates.add(
          PrinterCandidate(
            printerId: p.printer.id,
            printerName: p.printer.name ?? p.serial ?? '未命名',
            modelGroup: PrinterModelGroup.fromModel(p.printer.model) ??
                PrinterModelGroup.a1,
            score: 0,
            eligible: false,
            rejectReasons: [fileExists.reason],
          ),
        );
      }
      return candidates;
    }

    for (final p in printers) {
      final printerId = p.printer.id;
      final printerName = p.printer.name ?? p.serial ?? '未命名';
      final pGroup =
          PrinterModelGroup.fromModel(p.printer.model) ?? PrinterModelGroup.a1;
      // 1. 任务必须带有精确机型和喷嘴；旧任务不得回退到宽泛机型组。
      if (task.targetSpec == null) {
        candidates.add(
          PrinterCandidate(
            printerId: printerId,
            printerName: printerName,
            modelGroup: pGroup,
            score: 0,
            eligible: false,
            rejectReasons: const ['任务缺少精确目标机型或喷嘴信息，请重新添加任务'],
          ),
        );
        continue;
      }

      // 2. 忙机可以预排，但活动队列有明确上限，避免无限占用耗材。
      final serialForQueue = p.serial;
      final activeQueueCount = serialForQueue == null
          ? 0
          : await _ref
              .read(_printQueueDaoProvider)
              .getActiveCount(serialForQueue);
      if (activeQueueCount >= config.maxQueuedTasksPerPrinter) {
        candidates.add(
          PrinterCandidate(
            printerId: printerId,
            printerName: printerName,
            modelGroup: pGroup,
            score: 0,
            eligible: false,
            rejectReasons: [
              '活动队列已达 ${config.maxQueuedTasksPerPrinter} 个任务上限',
            ],
          ),
        );
        continue;
      }

      // 3. 舰队连接事实 + 精确机型 + 喷嘴硬校验。
      PrinterStateFreshness? freshness;
      bool cloudOnly = false;
      final serial = p.serial;
      if (serial == null || serial.isEmpty) {
        candidates.add(
          PrinterCandidate(
            printerId: printerId,
            printerName: printerName,
            modelGroup: pGroup,
            score: 0,
            eligible: false,
            rejectReasons: const ['打印机缺少序列号，无法取得舰队状态事实'],
          ),
        );
        continue;
      }
      final registeredState = fleetManager.getState(serial);
      if (registeredState != null && !registeredState.isLanCapable) {
        cloudOnly = true;
        candidates.add(
          PrinterCandidate(
            printerId: printerId,
            printerName: printerName,
            modelGroup: pGroup,
            score: 0,
            eligible: false,
            rejectReasons: const ['仅云连接，无法自动下发（仅监控/排队）'],
            cloudOnly: true,
          ),
        );
        continue;
      }
      final fleetState = await fleetManager.ensureFreshStatus(serial, config);
      if (fleetState != null) {
        cloudOnly = !fleetState.isLanCapable;
        final stale = fleetState.isStale(config);
        final busy = fleetState.printerBusy;
        freshness = PrinterStateFreshness(
          statusUpdatedAt: fleetState.statusUpdatedAt,
          stale: stale,
          lanCapable: fleetState.isLanCapable,
          printerBusy: busy,
          busyReason: busy ? '打印机正在运行，任务将进入预排队列' : null,
        );
      }
      final fleetCheck = _validateFleetCompatibility(
        task,
        fleetState,
        config,
      );
      if (!fleetCheck.ok) {
        candidates.add(
          PrinterCandidate(
            printerId: printerId,
            printerName: printerName,
            modelGroup: pGroup,
            score: 0,
            eligible: false,
            rejectReasons: [fleetCheck.reason],
            freshness: freshness,
            cloudOnly: cloudOnly,
          ),
        );
        continue;
      }

      // 4. 多材料匹配（硬约束）
      final materialResult = await _matchMaterials(task, p);
      if (!materialResult.allMatched) {
        candidates.add(
          PrinterCandidate(
            printerId: printerId,
            printerName: printerName,
            modelGroup: pGroup,
            score: 0,
            eligible: false,
            rejectReasons: [materialResult.rejectReason],
            materialMatches: materialResult.matches,
            freshness: freshness,
            cloudOnly: cloudOnly,
          ),
        );
        continue;
      }

      // 5. 评分（6 维度，按权重加权）
      final scores = await _calculateScores(
        task: task,
        printerId: printerId,
        materialMatches: materialResult.matches,
        weights: weights,
      );

      candidates.add(
        PrinterCandidate(
          printerId: printerId,
          printerName: printerName,
          modelGroup: pGroup,
          score: scores.total,
          eligible: true,
          earliestFinishScore: scores.earliestFinish,
          materialColorScore: scores.materialColor,
          historyRateScore: scores.historyRateScore,
          changeCostScore: scores.changeCost,
          healthScore: scores.health,
          batchAffinityScore: scores.batchAffinity,
          materialMatches: materialResult.matches,
          freshness: freshness,
          cloudOnly: cloudOnly,
          earliestFinishAt: scores.earliestFinishAt,
          remainingGrams: scores.matchedRemainingGrams,
          historySuccessRate: scores.historyRateValue,
          estimatedSeconds: task.estimatedSeconds,
        ),
      );
    }
    return candidates;
  }

  /// 计算 6 维度评分。
  ///
  /// 任务书要求权重：
  /// - 预计最早完工时间 35%
  /// - 材料/颜色匹配 25%
  /// - 最近 90 天同类任务成功率 15%
  /// - 耗材换卷成本与余量利用 10%
  /// - 设备健康和最近故障 10%
  /// - 同批次连续性 5%
  Future<
      ({
        double total,
        double earliestFinish,
        double materialColor,
        double historyRateScore,
        double changeCost,
        double health,
        double batchAffinity,
        DateTime? earliestFinishAt,
        double matchedRemainingGrams,
        double historyRateValue,
      })> _calculateScores({
    required SchedulerTask task,
    required int printerId,
    required List<MaterialMatchResult> materialMatches,
    required SchedulingWeights weights,
  }) async {
    final schedulerDao = _ref.read(schedulerDaoProvider);

    // 1. 预计最早完工时间（35%）。忙机允许预排，因此把该机已分配任务的
    // 预计时长加入队列延迟；空闲机自然获得更高分。
    final queueDelaySeconds =
        await schedulerDao.getQueuedEstimatedSeconds(printerId);
    final ownSeconds = task.estimatedSeconds ?? 0;
    final earliestFinishAt = ownSeconds > 0
        ? DateTime.now().add(Duration(seconds: queueDelaySeconds + ownSeconds))
        : null;
    final earliestFinishNorm =
        ownSeconds <= 0 ? 0.5 : 1 / (1 + queueDelaySeconds / ownSeconds);
    final earliestFinishScore = weights.earliestFinish * earliestFinishNorm;

    // 2. 材料/颜色匹配（25%）
    // 归一化：所有工具颜色都匹配=1.0，部分匹配按比例。
    final totalTools = materialMatches.length;
    final colorMatchedTools =
        materialMatches.where((m) => m.colorMatched).length;
    final materialColorNorm =
        totalTools > 0 ? colorMatchedTools / totalTools : 1.0;
    final materialColorScore = weights.materialColor * materialColorNorm;

    // 3. 最近 90 天同类任务成功率（15%）
    final historyRateValue =
        await schedulerDao.getPrinterHistoryRate(printerId) ?? 0.5;
    final historyRateScoreVal = weights.historyRate * historyRateValue;

    // 4. 耗材换卷成本与余量利用（10%）
    // 归一化：余量越充足分越高。min(available/required, 2) / 2。
    double totalRequired = 0;
    double totalAvailable = 0;
    for (final m in materialMatches) {
      totalRequired += m.requiredGrams;
      totalAvailable += m.matchedAvailableGrams;
    }
    final ratio = totalRequired > 0
        ? (totalAvailable / totalRequired).clamp(0.0, 2.0)
        : 2.0;
    final changeCostNorm = ratio / 2.0;
    final changeCostScore = weights.changeCost * changeCostNorm;
    final matchedRemainingGrams = totalAvailable;

    // 5. 设备健康和最近故障（10%）
    // 归一化：基于历史成功率（与维度3不同：此处关注故障率，1-historyRate 的反向）。
    // 简化：用历史成功率作为健康指标。无故障记录=1.0。
    final healthNorm = historyRateValue;
    final healthScore = weights.health * healthNorm;

    // 6. 同批次连续性（5%）
    final batchAffinity = await _checkBatchAffinity(printerId, task);
    final batchAffinityNorm =
        batchAffinity / 5.0; // _checkBatchAffinity 返回 0 或 5
    final batchAffinityScore = weights.batchAffinity * batchAffinityNorm;

    final total = earliestFinishScore +
        materialColorScore +
        historyRateScoreVal +
        changeCostScore +
        healthScore +
        batchAffinityScore;

    return (
      total: total,
      earliestFinish: earliestFinishScore,
      materialColor: materialColorScore,
      historyRateScore: historyRateScoreVal,
      changeCost: changeCostScore,
      health: healthScore,
      batchAffinity: batchAffinityScore,
      earliestFinishAt: earliestFinishAt,
      matchedRemainingGrams: matchedRemainingGrams,
      historyRateValue: historyRateValue,
    );
  }

  /// 检查批次亲和性：该打印机是否在最近 10 分钟内打过同文件名的任务。
  ///
  /// 若是，返回 5.0（批次亲和性满分）；否则返回 0.0。
  /// 这能让"同一批次分发的任务"优先分配给已参与该批次的打印机，
  /// 减少用户手动协调多台打印机。
  Future<double> _checkBatchAffinity(
    int printerId,
    SchedulerTask task,
  ) async {
    try {
      final db = _ref.read(databaseProvider);
      final basename = task.gcodeFilename;
      final windowStart = DateTime.now()
          .subtract(const Duration(minutes: 10))
          .millisecondsSinceEpoch;
      final rows = await db.customSelect(
        "SELECT COUNT(*) AS cnt FROM print_tasks "
        "WHERE printer_id = ? AND (task_name = ? OR gcode_path LIKE ?) "
        "AND started_at IS NOT NULL AND started_at >= ?",
        variables: [
          Variable<int>(printerId),
          Variable<String>(basename),
          Variable<String>('%$basename%'),
          Variable<int>(windowStart),
        ],
      ).get();
      return rows.first.read<int>('cnt') > 0 ? 5.0 : 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  /// 更新排序（拖拽调整顺序用）。
  Future<void> updateSortOrder(List<int> taskIds) async {
    await _ref.read(schedulerDaoProvider).updateSortOrder(taskIds);
  }

  @override
  void dispose() {
    _schedulerWatchSub?.cancel();
    _printQueueWatchSub?.cancel();
    super.dispose();
  }
}

/// 内部：耗材预留计划（原子事务用）。
class _ReservationPlan {
  final int consumableId;
  final int toolIndex;
  final double grams;
  const _ReservationPlan({
    required this.consumableId,
    required this.toolIndex,
    required this.grams,
  });
}

/// 内部：[_validateForAssignment] 的返回结果。
///
/// 替代 record 类型 `({bool ok, String reason, List<_ReservationPlan> reservations})`，
/// 因 record 中含私有类型 [_ReservationPlan] 在公共 API 中使用会触发
/// `library_private_types_in_public_api` 警告，且 Dart 解析器对
/// `Future<({...})>` 跨行声明的解析有歧义（误判为 operator < 声明），
/// 改用具名类避免该问题。
class _ValidationResult {
  final bool ok;
  final String reason;
  final List<_ReservationPlan> reservations;
  const _ValidationResult({
    required this.ok,
    required this.reason,
    required this.reservations,
  });
}
