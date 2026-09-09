import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/services/anomaly_detection_service.dart';
import '../core/services/error_logger.dart';
import '../core/services/filament_change_reminder_service.dart';
import '../core/services/notification_service.dart';
import '../core/services/parameter_experiment_service.dart';
import '../core/services/printer_fleet_connection_manager.dart';
import '../data/database/database.dart';
import '../data/database/daos/preset_result_dao.dart';
import '../data/database/daos/print_task_dao.dart';
import '../data/database/models/experiment_models.dart';
import '../data/database/models/print_queue_item.dart';
import '../data/database/models/print_task_consumable.dart';
import '../data/external/print_task/gram_calculator.dart';
import '../data/external/print_task/cloud_task_slice_enricher.dart';
import '../data/external/print_task/print_task_state_machine.dart';
import '../data/external/printer/bambu_printer_models.dart';
import '../data/external/slicer/slice_isolate_runner.dart';
import '../data/external/slicer/slice_result.dart';
import '../data/prefs/app_prefs.dart';
import '../data/prefs/slicer_prefs.dart';
import 'database_provider.dart';
import 'bambu_cloud_tasks_provider.dart';
import 'consumable_provider.dart';
import 'external_multicolor_plan_provider.dart';
import 'printer_connection_provider.dart';
import 'print_queue_provider.dart';
import 'slicer_provider.dart';

({double inventoryDelta, double accountingBaseline})
planRealtimeConsumableDeduction({
  required double estimatedGrams,
  required int mcPercent,
  required double lastDeductedGrams,
  required bool maintenancePaused,
  double segmentStartGrams = 0,
}) {
  final estimatedAtProgress =
      ((estimatedGrams + segmentStartGrams) * mcPercent.clamp(0, 100) / 100 -
              segmentStartGrams)
          .clamp(0.0, estimatedGrams)
          .toDouble();
  if (maintenancePaused) {
    return (
      inventoryDelta: 0,
      accountingBaseline: estimatedAtProgress > lastDeductedGrams
          ? estimatedAtProgress
          : lastDeductedGrams,
    );
  }
  return (
    inventoryDelta: estimatedAtProgress - lastDeductedGrams,
    accountingBaseline: lastDeductedGrams,
  );
}

/// 打印任务编排器。
///
/// 负责把「打印机实时状态」串到「打印任务数据库记录」+「克数计算」+「切片缓存」：
///
/// ```
/// [activePrinterConnection]  ← 打印机实时状态（mc_percent, curr_layer, gcode_state）
///         │
///         ▼
/// [PrintTaskOrchestrator]
///         │
///         ├──→ 当前活跃任务（PrintTaskDao.getActive() 取首条）
///         ├──→ 切片结果缓存（按 gcodePath 索引 SliceResult）
///         ├──→ GramCalculator.calculate()  ← task + slice + mode
///         │
///         ▼
/// [PrintTaskDao.updateProgress / updateStatus / finish]
/// ```
///
/// UI 层通过 [activePrintTaskProvider] 监听当前活跃任务的实时状态。
class PrintTaskOrchestrator extends StateNotifier<PrintTask?> {
  final Ref ref;
  final _uuid = const Uuid();

  Future<bool> _canUseCurrentPersonalConsumable(
    int consumableId, {
    bool claimAnonymous = false,
  }) {
    final scope = ref.read(personalInventoryAccountScopeProvider);
    if (!scope.enforce) return Future.value(true);
    return ref
        .read(consumableDaoProvider)
        .ensurePersonalConsumableAccess(
          consumableId,
          ownerAccount: scope.ownerAccount,
          claimAnonymous: claimAnonymous,
        );
  }

  StreamSubscription<List<PrintTask>>? _activeTaskSub;
  Timer? _settlementRecoveryTimer;
  Future<void>? _settlementRecovery;

  /// 切片结果缓存。key = gcodePath，value = SliceResult。
  /// 启动任务时从 [SlicerWatcherState.recentSlices] 中按 gcodePath 查找并缓存。
  final Map<String, SliceResult> _sliceCache = {};

  /// 屏幕任务自动创建防重入标志。
  /// MQTT pushing 消息可能在 watchActive 流回写 state 之前多次推送 running，
  /// 用此标志避免对同一屏幕任务重复创建 PrintTask。
  final Set<String> _creatingScreenTaskSerials = {};

  /// 每台后台打印机各自串行消费 MQTT 状态，防止同一设备的进度、终态并发乱序。
  final Map<String, Future<void>> _fleetStatusOperations = {};

  /// 任务关联记录缓存。key = taskId，value = 该任务的耗材关联记录列表。
  /// 实时扣减时直接读缓存，避免每次 MQTT 推送都查库（多打印机场景防抖）。
  final Map<int, List<PrintTaskConsumable>> _taskConsumablesCache = {};

  /// 实时扣减节流时间戳。key = taskId，value = 上次扣减的时间。
  /// MQTT 推送频率高（1-2 秒/次），扣减写库间隔不小于 5 秒，防止多打印机场景死机。
  final Map<int, DateTime> _lastDeductTime = {};

  /// 实时扣减最小间隔（秒）。防止频繁写库导致 UI 卡顿/死机。
  static const int _deductThrottleSeconds = 5;

  /// 正在结算的任务集合。实时扣减遇到正在结算的任务直接跳过，防止竞态重复扣减。
  final Set<int> _settlingTasks = {};

  /// 每个任务正在执行的实时扣减 Future。结算前 await 确保扣减完成，防止并发。
  final Map<int, Future<void>> _pendingDeducts = {};

  /// P1-4: AMS 映射失败告警去重缓存（key = gcodePath）。
  /// 同一切片文件路径只告警一次，避免任务反复创建时重复打扰。
  final Set<String> _amsMappingAlertedPaths = {};

  /// P1-5: 每个任务的实时扣减失败计数（key = taskId）。
  /// 用于结算时判断是否需要提示用户"打印过程中有扣减异常已自动修正"。
  /// 失败计数 > 0 但结算成功 → 已修正，提示用户；
  /// 结算也失败 → 严重告警，提示用户手动核查。
  final Map<int, int> _deductFailureCount = {};

  /// 初始化是否完成（C1 修复：防止早期 MQTT 事件在 state 尚未加载时误创建任务）
  bool _isInitialized = false;

  /// 是否已 dispose（C3 修复：防止 dispose 后异步操作访问 provider）
  bool _isDisposed = false;

  /// H4 修复：屏幕任务创建期间缓存的最新 MQTT 状态。
  /// 任务创建是异步的（onDemand 模式需查找解析切片文件），期间到达的 MQTT
  /// 进度事件会因 task==null 被丢弃。任务创建完成后补一次 _updateExistingTask。
  BambuPrinterStatus? _pendingScreenStatus;

  /// 架构修复：持有 H4 延迟补发进度的 Timer 引用，dispose 时取消，
  /// 防止 dispose 后 100ms 窗口期内访问 state 导致异常。
  Timer? _pendingScreenStatusTimer;

  /// 当前 UI 选中打印机对应的本地 id。任务状态只允许由同一台打印机推进。
  int? _activePrinterId;

  /// 当前活跃打印机任务加载代数。
  ///
  /// 查询任务涉及两次异步数据库访问。用户快速切换打印机时，较早的
  /// 查询可能晚于较新的查询返回；只有最新一代加载才允许回写 id/state。
  int _taskLoadGeneration = 0;

  PrintTaskOrchestrator(this.ref) : super(null) {
    // 启动时主动查询一次活跃任务，避免流只在变更后推送导致初始 state 一直为 null。
    _loadTaskForSerial(ref.read(activePrinterSerialProvider));
    unawaited(recoverPendingSettlements());
    _settlementRecoveryTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(recoverPendingSettlements());
    });

    // 监听活跃任务流：当数据库里的活跃任务变化时，更新 state
    _activeTaskSub = ref.watch(printTaskDaoProvider).watchActive().listen((
      tasks,
    ) {
      final active = _activePrinterId == null
          ? null
          : tasks.cast<PrintTask?>().firstWhere(
              (task) => task?.printerId == _activePrinterId,
              orElse: () => null,
            );
      if (mounted) state = active;
    });

    ref.listen<String?>(activePrinterSerialProvider, (previous, next) {
      if (previous != next) _loadTaskForSerial(next);
    });

    // 监听打印机实时状态：当打印机上报新状态时，更新当前活跃任务。
    // 注意：StateNotifier 没有 stream，必须用 ref.listen 监听 provider 变化。
    ref.listen<ActivePrinterState>(activePrinterConnectionProvider, (
      previous,
      next,
    ) {
      _onPrinterStateChanged(next);
    });

    // 舰队连接负责非当前 UI 打印机。当前选中的设备仍由上面的活动连接处理，
    // 避免同一台打印机的两条 MQTT 连接重复推进同一个任务。
    ref.listen<Map<String, FleetPrinterState>>(
      printerFleetConnectionManagerProvider,
      (previous, next) {
        final activeSerial = ref.read(activePrinterSerialProvider);
        for (final entry in next.entries) {
          final serial = entry.key;
          final fleetState = entry.value;
          if (serial == activeSerial || fleetState.lastStatus == null) continue;
          if (fleetState.statusUpdatedAt ==
              previous?[serial]?.statusUpdatedAt) {
            continue;
          }
          _enqueueFleetPrinterStatus(serial, fleetState.lastStatus!);
        }
      },
    );
  }

  Future<void> _loadTaskForSerial(String? serial) async {
    final generation = ++_taskLoadGeneration;
    if (serial == null || serial.isEmpty) {
      _activePrinterId = null;
      if (mounted) state = null;
      _isInitialized = true;
      return;
    }
    final printerId = await ref
        .read(printerDaoProvider)
        .getPrinterIdBySerial(serial);
    if (_isDisposed ||
        generation != _taskLoadGeneration ||
        ref.read(activePrinterSerialProvider) != serial) {
      return;
    }
    _activePrinterId = printerId;
    final tasks = printerId == null
        ? const <PrintTask>[]
        : await ref.read(printTaskDaoProvider).getActiveByPrinter(printerId);
    if (_isDisposed ||
        generation != _taskLoadGeneration ||
        ref.read(activePrinterSerialProvider) != serial) {
      return;
    }
    if (mounted) state = tasks.isEmpty ? null : tasks.first;
    _isInitialized = true;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _settlementRecoveryTimer?.cancel();
    _activeTaskSub?.cancel();
    _pendingScreenStatusTimer?.cancel();
    // 清理缓存防止内存泄漏
    _taskConsumablesCache.clear();
    _lastDeductTime.clear();
    _sliceCache.clear();
    _settlingTasks.clear();
    _pendingDeducts.clear();
    _amsMappingAlertedPaths.clear();
    _deductFailureCount.clear();
    _creatingScreenTaskSerials.clear();
    _fleetStatusOperations.clear();
    super.dispose();
  }

  /// Retry accounting left between the terminal-state write and inventory
  /// settlement (process exit, disk error, or a partially failed settlement).
  /// consumed_at is claimed in the same transaction as stock and usage logs,
  /// so restarting or retrying cannot deduct an already settled entry twice.
  Future<void> recoverPendingSettlements() {
    final active = _settlementRecovery;
    if (active != null) return active;
    final operation = _recoverPendingSettlements();
    _settlementRecovery = operation;
    return operation.whenComplete(() {
      if (identical(_settlementRecovery, operation)) _settlementRecovery = null;
    });
  }

  Future<void> _recoverPendingSettlements() async {
    if (_isDisposed) return;
    try {
      final tasks = await ref
          .read(printTaskDaoProvider)
          .getPendingSettlements();
      for (final task in tasks) {
        if (_isDisposed) return;
        await _settleTaskConsumables(
          task: task,
          finalGrams: task.actualGrams,
          isCancelled: task.status != PrintTaskStatus.finished,
        );
      }
    } catch (error, stackTrace) {
      if (!_isDisposed) {
        ErrorLogger.log(
          error,
          stackTrace,
          source: 'print_task',
          level: ErrorLevel.error,
          context: {'phase': 'recover_settlement'},
        );
      }
    }
  }

  void _enqueueFleetPrinterStatus(String serial, BambuPrinterStatus status) {
    final previous = _fleetStatusOperations[serial] ?? Future<void>.value();
    late final Future<void> operation;
    operation = previous
        .then((_) async {
          if (_isDisposed) return;
          await _syncFleetPrinterStatus(serial, status);
        })
        .catchError((Object error, StackTrace stackTrace) {
          ErrorLogger.log(
            error,
            stackTrace,
            source: 'print_task',
            level: ErrorLevel.error,
            context: {'phase': 'sync_fleet_status', 'serial': serial},
          );
        });
    _fleetStatusOperations[serial] = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_fleetStatusOperations[serial], operation)) {
          _fleetStatusOperations.remove(serial);
        }
      }),
    );
  }

  Future<void> _syncFleetPrinterStatus(
    String serial,
    BambuPrinterStatus status,
  ) async {
    final printerId = await ref
        .read(printerDaoProvider)
        .getPrinterIdBySerial(serial);
    if (_isDisposed || printerId == null) return;

    final tasks = await ref
        .read(printTaskDaoProvider)
        .getActiveByPrinter(printerId);
    if (_isDisposed) return;
    final task = tasks.isEmpty ? null : tasks.first;

    if (task == null) {
      if (status.gcodeState == BambuGcodeState.running) {
        await _maybeAutoCreateScreenTask(status, serialOverride: serial);
      }
      return;
    }

    if (status.gcodeFile != null && status.gcodeFile!.isNotEmpty) {
      final taskBasename = task.gcodePath.split(RegExp(r'[/\\]')).last;
      final printerBasename = status.gcodeFile!.split(RegExp(r'[/\\]')).last;
      if (taskBasename.isNotEmpty &&
          printerBasename.isNotEmpty &&
          taskBasename != printerBasename) {
        await _cancelTaskForFileMismatch(task, status, serialOverride: serial);
        return;
      }
    }

    await _updateExistingTask(
      task,
      status,
      updateUiState: false,
      printerSerial: serial,
    );
  }

  /// 处理打印机状态变化。
  ///
  /// 三种场景：
  /// 1. 无活跃任务（或已终态）+ 打印机正在 running → 自动创建屏幕启动任务
  /// 2. 有活跃任务但 gcodeFile 不匹配 → 旧任务标记 cancelled + 自动创建新任务
  /// 3. 有活跃任务且文件匹配 → 正常更新进度/状态
  void _onPrinterStateChanged(ActivePrinterState printerState) {
    // C1 修复：初始化完成前丢弃早期事件，防止误创建任务
    if (!_isInitialized) return;
    final task = state;
    final status = printerState.status;
    if (status == null) return;
    if (_activePrinterId == null) return;
    if (task != null && task.printerId != _activePrinterId) return;

    // 场景1：无活跃任务或任务已终态
    if (task == null || task.status.isTerminal) {
      if (status.gcodeState == BambuGcodeState.running) {
        // H4 修复：创建期间缓存最新状态，防止进度丢失
        final serial = ref.read(activePrinterSerialProvider);
        if (serial != null && _creatingScreenTaskSerials.contains(serial)) {
          _pendingScreenStatus = status;
        } else {
          unawaited(_maybeAutoCreateScreenTask(status));
        }
      }
      return;
    }

    // 场景2：有活跃任务但打印机在跑别的文件
    if (status.gcodeFile != null && status.gcodeFile!.isNotEmpty) {
      final taskBasename = task.gcodePath.split(RegExp(r'[/\\]')).last;
      final printerBasename = status.gcodeFile!.split(RegExp(r'[/\\]')).last;
      if (taskBasename.isNotEmpty &&
          printerBasename.isNotEmpty &&
          taskBasename != printerBasename) {
        // 打印机切到别的文件了：旧任务标记 cancelled，并尝试自动创建新任务
        unawaited(_cancelTaskForFileMismatch(task, status));
        return;
      }
    }

    // 场景3：文件匹配，正常更新
    unawaited(_updateExistingTask(task, status));
  }

  /// 正常更新已匹配的活跃任务（状态机推进 + 进度快照 + 实时扣减）。
  Future<void> _updateExistingTask(
    PrintTask task,
    BambuPrinterStatus status, {
    bool updateUiState = true,
    String? printerSerial,
  }) async {
    // Keep the status translated from this packet separate from the snapshot
    // that was passed in. The snapshot may still contain the previous status
    // while the database update below is in flight; using it for accounting
    // would deduct on a pause packet or skip the first packet after resume.
    var effectiveStatus = task.status;
    // 增量消息可能不含 gcodeState（null），此时只更新进度不更新状态
    if (status.gcodeState != null) {
      final newTaskStatus = PrintTaskStateMachine.safeTransition(
        from: task.status,
        to: PrintTaskStateMachine.translate(
          current: task.status,
          gcodeState: status.gcodeState!,
          lastMcPercent: status.mcPercent ?? task.lastMcPercent,
          lastLayer: status.currLayer ?? task.lastLayer,
          totalLayers: status.totalLayers ?? 0,
        ),
      );
      effectiveStatus = newTaskStatus;

      // 1. 状态变化 → 更新状态
      if (newTaskStatus != task.status) {
        if (newTaskStatus.isTerminal) {
          // 终态必须通过带状态条件的 finish 原子认领。多个 MQTT 包、
          // stop() 与文件切换回调可能同时看到同一份 active 快照；只有
          // 成功把 active 行改成终态的调用方才能继续结算，避免重复扣库。
          final finalMcPercent = status.mcPercent ?? task.lastMcPercent;
          final finalLayer = status.currLayer ?? task.lastLayer;
          final finalGrams = _calculateActualGrams(
            task: task.copyWith(
              lastMcPercent: finalMcPercent,
              lastLayer: finalLayer,
            ),
          );
          final terminalTask = task.copyWith(
            lastMcPercent: finalMcPercent,
            lastLayer: finalLayer,
            actualGrams: finalGrams,
            finishedAt: DateTime.now(),
            status: newTaskStatus,
          );
          final claimed = await ref
              .read(printTaskDaoProvider)
              .finish(
                id: task.id!,
                actualGrams: finalGrams,
                status: newTaskStatus,
                lastMcPercent: finalMcPercent,
                lastLayer: finalLayer,
              );
          if (claimed == 0) return;
          unawaited(() async {
            await _upsertTerminalPresetResult(
              task: terminalTask,
              printerStatus: status,
            );
            if (newTaskStatus == PrintTaskStatus.cancelled) {
              await _cancelPrintingQueueItemForTask(
                terminalTask,
                serialOverride: printerSerial,
              );
            }
          }());
          // 异步结算，不阻塞状态机流程
          _settleTaskConsumables(
            task: task.copyWith(
              lastMcPercent: finalMcPercent,
              lastLayer: finalLayer,
              actualGrams: finalGrams,
            ),
            finalGrams: finalGrams,
            isCancelled:
                newTaskStatus == PrintTaskStatus.cancelled ||
                newTaskStatus == PrintTaskStatus.failed,
          );
          // 告警挂钩：仅当之前状态为活跃（printing/paused）时告警，
          // 避免 planned→cancelled 误报
          if (task.status.isActive) {
            _notifyTaskTerminal(
              task: task,
              newStatus: newTaskStatus,
              finalGrams: finalGrams,
              failReason: status.failReason,
            );
          }
          return;
        } else {
          // Non-terminal transitions are also guarded in the DAO so a stale
          // in-flight packet cannot move a task back from a terminal state.
          await ref
              .read(printTaskDaoProvider)
              .updateStatus(id: task.id!, status: newTaskStatus);
        }
      }
    }

    // 2. 进度变化 → 更新进度快照 + 实际克数
    // 增量消息可能不含 mcPercent/currLayer（null），用旧值
    final mcPercent = status.mcPercent ?? task.lastMcPercent;
    final currLayer = status.currLayer ?? task.lastLayer;
    if (mcPercent == task.lastMcPercent && currLayer == task.lastLayer) {
      return; // 进度没变化，不写库
    }

    final slice = _sliceCache[task.gcodePath];
    final mode = ref.read(printTaskCalculationModeProvider);
    final actualGrams = GramCalculator.calculate(
      task: task.copyWith(lastMcPercent: mcPercent, lastLayer: currLayer),
      slice: slice,
      mode: mode,
    );

    final progressUpdated = await ref
        .read(printTaskDaoProvider)
        .updateProgress(
          id: task.id!,
          mcPercent: mcPercent,
          layer: currLayer,
          actualGrams: actualGrams,
        );
    if (progressUpdated == 0 || _isDisposed) return;

    // B5 修复：直接更新 orchestrator state，让 UI 立即看到实时进度。
    if (updateUiState &&
        mounted &&
        _activePrinterId == task.printerId &&
        (state == null || state?.id == task.id)) {
      state = task.copyWith(
        status: effectiveStatus,
        lastMcPercent: mcPercent,
        lastLayer: currLayer,
        actualGrams: actualGrams,
      );
    }

    // 实时扣减库存（校准阶段 mcPercent=0 不扣，带节流防多打印机死机）
    // 只有 printing 状态才扣减，paused 状态不扣
    if (effectiveStatus == PrintTaskStatus.printing && mcPercent > 0) {
      _maybeDeductConsumables(
        task: task.copyWith(
          status: effectiveStatus,
          lastMcPercent: mcPercent,
          lastLayer: currLayer,
        ),
        mcPercent: mcPercent,
      );
    }

    // 外挂料多色打印换色提醒（预告 + 即时弹窗）
    // 仅在打印中/暂停状态触发，避免空闲/终态误触发
    if (effectiveStatus == PrintTaskStatus.printing ||
        effectiveStatus == PrintTaskStatus.paused) {
      _maybeTriggerFilamentChangeReminder(
        task: task.copyWith(
          status: effectiveStatus,
          lastMcPercent: mcPercent,
          lastLayer: currLayer,
        ),
        status: status,
        currLayer: currLayer,
      );
    }
  }

  /// 触发外挂料换色提醒。
  ///
  /// 委托给 [FilamentChangeReminderService] 处理：
  /// - 全局开关检查（用户可在设置页关闭）
  /// - AMS 模式自动跳过（AMS 自动换料无需提醒）
  /// - G-code 含换料指令才提醒（无换料指令 = 用户没启用换色 = 不打扰）
  /// - 预告：currLayer 接近下一个换色点时 Toast 通知
  /// - 即时：暂停命中换色点时弹窗，由进退料状态自动关闭
  void _maybeTriggerFilamentChangeReminder({
    required PrintTask task,
    required BambuPrinterStatus status,
    required int currLayer,
  }) {
    try {
      final gcodePath = task.gcodePath;
      if (gcodePath.isEmpty) return;

      // 判断是否为 AMS 模式：amsTrays 非空 = 有 AMS 硬件
      final hasAms =
          (status.amsUnits?.isNotEmpty ?? false) ||
          (status.amsTrays?.isNotEmpty ?? false);
      final printerSerial = status.serial;
      final config = ref
          .read(printerConnectionListProvider.notifier)
          .get(printerSerial);

      ref
          .read(filamentChangeReminderServiceProvider)
          .onPrinterStateChanged(
            taskId: task.id!,
            printerSerial: printerSerial,
            printerLabel: config?.displayLabel ?? printerSerial,
            taskName: task.taskName,
            gcodeState: status.gcodeState,
            currLayer: currLayer,
            totalLayers: status.totalLayers,
            gcodePath: gcodePath,
            trayNow: status.trayNow,
            hasAms: hasAms,
            mcPrintStage: status.mcPrintStage,
            hwSwitchState: status.hwSwitchState,
            extruderFilamentPresent: status.extruderFilamentPresent,
            knownChangePoints: _sliceCache[gcodePath]?.filamentChangePoints,
          );
    } catch (e, st) {
      // 提醒失败不影响主流程
      ErrorLogger.log(
        e,
        st,
        source: 'print_task',
        level: ErrorLevel.warning,
        context: {'phase': 'filament_change_reminder'},
      );
    }
  }

  /// 任务进入终态时发送 Toast 告警。
  ///
  /// 仅在 previously-active 状态（printing/paused）下告警，避免 planned→cancelled 误报。
  /// 告警失败不影响主流程（try-catch 保护）。
  void _notifyTaskTerminal({
    required PrintTask task,
    required PrintTaskStatus newStatus,
    required double finalGrams,
    String? failReason,
  }) {
    try {
      final notif = ref.read(notificationServiceProvider);
      switch (newStatus) {
        case PrintTaskStatus.failed:
          notif.alert(
            type: AlertType.printFailed,
            title: '打印失败',
            body: '${task.taskName} - ${failReason ?? "未知原因"}',
          );
          break;
        case PrintTaskStatus.cancelled:
          notif.alert(
            type: AlertType.printCancelled,
            title: '打印异常终止',
            body: '${task.taskName} 已被异常取消',
          );
          break;
        case PrintTaskStatus.finished:
          notif.alert(
            type: AlertType.printFinished,
            title: '打印完成',
            body: '${task.taskName} 已完成，消耗 ${finalGrams.toStringAsFixed(1)}g',
          );
          break;
        default:
          break;
      }
    } catch (e, st) {
      // 告警失败不影响主流程，但记录到错误日志便于排查
      ErrorLogger.log(
        e,
        st,
        source: 'print_task',
        level: ErrorLevel.warning,
        context: {'phase': 'notify_task_terminal'},
      );
    }
  }

  /// 实时扣减库存（乐观扣减，带节流）。
  ///
  /// **校准阶段保护**：只有 mcPercent > 0 才扣减。
  /// 打印机启动后会有校准过程（热床调平/流量校准等），此时 mcPercent=0，
  /// 不消耗耗材，扣减会导致库存虚减。
  ///
  /// **节流**：[_deductThrottleSeconds] 秒内只扣一次，防止 MQTT 高频推送
  /// 导致频繁写库卡死（多打印机场景尤其重要）。
  ///
  /// **差额扣减**：本次估算消耗 = estimatedGrams × mcPercent / 100，
  /// 扣减量 = 本次估算 - 上次已扣减（lastDeductedGrams），只扣增量。
  void _maybeDeductConsumables({
    required PrintTask task,
    required int mcPercent,
  }) {
    // 正在结算的任务跳过实时扣减，防止竞态重复扣减
    if (_settlingTasks.contains(task.id!)) return;
    // 节流：间隔不够跳过（不阻塞 UI，下次推送再扣）
    final lastTime = _lastDeductTime[task.id!];
    if (lastTime != null) {
      final elapsed = DateTime.now().difference(lastTime).inSeconds;
      if (elapsed < _deductThrottleSeconds) return;
    }
    // P1-4 修复：节流时间戳延后到实际执行扣减成功后写入，
    // 否则若 _doDeductConsumables 因 _isDisposed 立即返回，
    // 节流时间戳已写入，下次扣减被错误节流 5 秒，导致进度数据丢失

    // 异步执行，用链式 then 组合确保旧扣减完成后再执行新的（C2 修复：防止覆盖）
    final prev = _pendingDeducts[task.id!];
    late Future<void> future;
    future = (prev ?? Future<void>.value())
        .then((_) {
          if (_isDisposed) return Future<void>.value();
          return _doDeductConsumables(task: task, mcPercent: mcPercent);
        })
        .then((_) {
          // 扣减成功后写入节流时间戳
          _lastDeductTime[task.id!] = DateTime.now();
        })
        .whenComplete(() {
          // 6.1 修复：只在 map 中的值仍是本次 future 时才移除。
          // 避免误删后续链接的 future 导致扣减并发（重复扣减库存）。
          if (identical(_pendingDeducts[task.id!], future)) {
            _pendingDeducts.remove(task.id!);
          }
        });
    _pendingDeducts[task.id!] = future;
  }

  Future<void> _doDeductConsumables({
    required PrintTask task,
    required int mcPercent,
  }) async {
    if (_isDisposed) return;
    try {
      // Channel handoffs can close a segment outside this orchestrator.
      // Re-read before planning; the existing CAS handles a concurrent handoff.
      final entries = await ref
          .read(printTaskConsumableDaoProvider)
          .getByTask(task.id!);
      if (entries.isEmpty) return;

      final consumableDao = ref.read(consumableDaoProvider);
      final ptcDao = ref.read(printTaskConsumableDaoProvider);

      // 用可变列表，每轮更新后赋回缓存，避免 map 覆盖前面的更新（C1 修复）
      final updated = List<PrintTaskConsumable>.from(entries);
      final pausedChannelsByPrinter = <int, Set<int>>{};
      for (var i = 0; i < updated.length; i++) {
        final e = updated[i];
        if (e.consumedAt != null) continue;
        if (e.consumableId == null) continue; // 通道未绑定耗材，跳过
        if (!await _canUseCurrentPersonalConsumable(
          e.consumableId!,
          claimAnonymous: true,
        )) {
          continue;
        }
        final printerId = e.printerId ?? task.printerId;
        final isMaintenancePaused =
            printerId != null &&
            (pausedChannelsByPrinter[printerId] ??= await ref
                    .read(printerDaoProvider)
                    .getMaintenancePausedChannelIndexes(printerId))
                .contains(e.channelIndex);
        final plan = planRealtimeConsumableDeduction(
          estimatedGrams: e.estimatedGrams,
          segmentStartGrams: e.segmentStartGrams,
          mcPercent: mcPercent,
          lastDeductedGrams: e.lastDeductedGrams,
          maintenancePaused: isMaintenancePaused,
        );
        if (isMaintenancePaused) {
          // A repair can leave stale progress in the next MQTT packet. Advance
          // the accounting baseline without touching inventory, so the stale
          // jump is never deducted after the spool is restored.
          if (plan.accountingBaseline > e.lastDeductedGrams) {
            final claimed = await ptcDao.updateDeducted(
              e.id!,
              plan.accountingBaseline,
              expectedPrevious: e.lastDeductedGrams,
            );
            if (!claimed) {
              _taskConsumablesCache.remove(task.id!);
              return;
            }
            updated[i] = e.copyWith(lastDeductedGrams: plan.accountingBaseline);
          }
          continue;
        }
        final delta = plan.inventoryDelta;
        if (delta.abs() < 0.5) continue; // 变化太小不扣

        // H1 修复：扣减库存 + 更新累计扣减值 放在同一事务中，
        // 防止中途失败导致库存与关联记录不一致
        final deducted = await ref.read(databaseProvider).transaction(() async {
          if (!await _canUseCurrentPersonalConsumable(
            e.consumableId!,
            claimAnonymous: true,
          )) {
            return true;
          }
          // Claim the expected baseline before touching inventory. A late
          // packet cannot change a finalized row or replay an old deduction.
          if (!await ptcDao.updateDeducted(
            e.id!,
            e.lastDeductedGrams + delta,
            expectedPrevious: e.lastDeductedGrams,
          ))
            return false;
          final actual = await consumableDao.adjustGrams(
            e.consumableId!,
            delta,
          );
          final actualDeducted = e.lastDeductedGrams + actual;
          await ptcDao.updateDeducted(e.id!, actualDeducted);
          updated[i] = e.copyWith(lastDeductedGrams: actualDeducted);
          if ((actual - delta).abs() >= 0.01) {
            ErrorLogger.log(
              StateError(
                '库存边界截断：请求 ${delta.toStringAsFixed(2)}g，实际 ${actual.toStringAsFixed(2)}g',
              ),
              StackTrace.current,
              source: 'print_task',
              level: ErrorLevel.warning,
              context: {
                'phase': 'realtime_deduct_clamped',
                'taskId': task.id,
                'entryId': e.id,
                'consumableId': e.consumableId,
              },
            );
          }
          return true;
        });
        if (!deducted) {
          _taskConsumablesCache.remove(task.id!);
          return;
        }

        // 创新2: 实时扣减异常检测（只检测 delta>0 的扣减场景）
        if (delta > 0) {
          await ref
              .read(anomalyDetectionServiceProvider)
              .detectRealtimeDeduction(
                task: task,
                entry: updated[i],
                delta: delta,
                mcPercent: mcPercent,
              );
        }
      }
      // 一次性更新缓存
      _taskConsumablesCache[task.id!] = updated;
    } catch (e, st) {
      // 扣减失败不影响任务流程，完成时会修正
      // P1-5: 累计失败次数，结算时若 > 0 提示用户已自动修正
      _deductFailureCount[task.id!] = (_deductFailureCount[task.id!] ?? 0) + 1;
      ErrorLogger.log(
        e,
        st,
        source: 'print_task',
        level: ErrorLevel.warning,
        context: {
          'phase': 'realtime_deduct',
          'taskId': task.id,
          'failureCount': _deductFailureCount[task.id!],
        },
      );
    } finally {
      // 6.1 修复：remove 逻辑已移到 _maybeDeductConsumables 的 whenComplete 中，
      // 此处不再 remove（避免误删后续链接的 future 导致并发扣减）。
    }
  }

  /// 任务终态结算：按 actualGrams 分配到各卷 + 修正库存差额 + 写 usage_logs。
  ///
  /// **校准阶段取消保护**：如果 finalGrams=0（校准阶段取消/失败），不扣减不写日志。
  ///
  /// **分配规则**：按各卷预估比例分配实际总消耗。
  /// 例：T0 预估 20g，T1 预估 10g，实际总 36g → T0=24g，T1=12g
  ///
  /// **修正**：每卷的 finalConsumed - lastDeductedGrams = 需修正的差额
  /// （正数补扣，负数回补），通过 [ConsumableDao.adjustGrams] 一次性修正。
  ///
  /// **写日志**：每卷写一条 usage_logs 记录，finished=true 表示正常完成，
  /// finished=false 表示取消/失败（部分消耗）。
  Future<void> _settleTaskConsumables({
    required PrintTask task,
    required double finalGrams,
    required bool isCancelled,
  }) async {
    // 并发竞争修复：入口检查 _settlingTasks，防止 _cancelTaskForFileMismatch
    // 与 _updateExistingTask 终态路径同时触发同一 task 导致双重结算。
    if (_settlingTasks.contains(task.id!)) return;
    // 标记正在结算，阻止新的实时扣减
    _settlingTasks.add(task.id!);
    try {
      // 等待正在进行的实时扣减完成，防止竞态重复扣减
      // P0 修复：用 catchError 包装，避免 pending Future 内部异常（如日志写入失败）
      // 中断本次结算，导致库存与日志永久不一致
      final pending = _pendingDeducts[task.id!];
      if (pending != null) {
        await pending.catchError((Object _, StackTrace __) {});
      }

      final ptcDao = ref.read(printTaskConsumableDaoProvider);
      // 扣减完成后缓存可能已更新，重新读取确保用最新 lastDeductedGrams
      // 始终从数据库重读 consumed_at，不能依赖可能过期的内存缓存做幂等判断。
      final entries = await ptcDao.getByTask(task.id!);
      if (entries.isEmpty) return;

      if (_isDisposed) return;

      final consumableDao = ref.read(consumableDaoProvider);
      final usageDao = ref.read(usageLogDaoProvider);

      // 按预估比例分配实际总消耗
      final totalEstimated = entries.fold(
        0.0,
        (sum, e) => sum + e.estimatedGrams,
      );

      // 收集已结算的关联记录（含 finalConsumed），用于结算异常检测
      final settledEntries = <PrintTaskConsumable>[];
      final pausedChannelsByPrinter = <int, Set<int>>{};
      // BUG-8 修复：记录失败的 entry，部分失败不中断循环
      final failedEntries = <PrintTaskConsumable>[];

      for (final e in entries) {
        if (e.consumedAt != null) continue;
        try {
          if (e.consumableId != null &&
              !await _canUseCurrentPersonalConsumable(
                e.consumableId!,
                claimAnonymous: true,
              )) {
            continue;
          }
          // 该卷实际消耗 = 总实际 × 该卷预估占比（预估为 0 时该卷不消耗）
          final printerId = e.printerId ?? task.printerId;
          final isMaintenancePaused =
              printerId != null &&
              (pausedChannelsByPrinter[printerId] ??= await ref
                      .read(printerDaoProvider)
                      .getMaintenancePausedChannelIndexes(printerId))
                  .contains(e.channelIndex);
          final finalConsumed = isMaintenancePaused
              ? e.lastDeductedGrams
              : e.finalSegmentGrams(finalGrams, totalEstimated);

          // H2 修复：finalize + 修正库存 + 写日志 放在同一事务中，
          // 防止中途失败导致关联记录已结算但库存未修正/日志缺失
          final settledConsumed = await ref
              .read(databaseProvider)
              .transaction<double?>(() async {
                if (e.consumableId != null &&
                    !await _canUseCurrentPersonalConsumable(
                      e.consumableId!,
                      claimAnonymous: true,
                    )) {
                  return null;
                }
                final current = (await ptcDao.getByTask(
                  task.id!,
                )).firstWhere((row) => row.id == e.id);
                // 先通过 consumed_at IS NULL 原子抢占结算权。后续任一步失败时事务整体回滚。
                final finalized = await ptcDao.finalize(e.id!, finalConsumed);
                if (!finalized) return null;

                // 修正库存差额：finalConsumed - lastDeductedGrams
                var settledConsumed = finalConsumed;
                if (e.consumableId != null) {
                  final correction = finalConsumed - current.lastDeductedGrams;
                  if (correction.abs() >= 0.0001) {
                    final actualCorrection = await consumableDao.adjustGrams(
                      e.consumableId!,
                      correction,
                    );
                    settledConsumed =
                        current.lastDeductedGrams + actualCorrection;
                    if ((actualCorrection - correction).abs() >= 0.01) {
                      ErrorLogger.log(
                        StateError(
                          '结算被库存边界截断：请求 ${correction.toStringAsFixed(2)}g，实际 ${actualCorrection.toStringAsFixed(2)}g',
                        ),
                        StackTrace.current,
                        source: 'print_task',
                        level: ErrorLevel.warning,
                        context: {
                          'phase': 'settlement_clamped',
                          'taskId': task.id,
                          'entryId': e.id,
                          'consumableId': e.consumableId,
                        },
                      );
                    }
                  }

                  await ptcDao.updateFinalizedAmount(e.id!, settledConsumed);

                  // 写 usage_logs（取消/失败时 finished=false）
                  if (settledConsumed > 0)
                    await usageDao.addLog(
                      UsageLogsCompanion.insert(
                        printerId: Value(task.printerId),
                        channelIndex: Value(e.channelIndex),
                        consumableId: Value(e.consumableId),
                        consumedGrams: Value(settledConsumed),
                        finished: Value(!isCancelled),
                        note: Value(isCancelled ? '任务取消/失败结算' : '任务完成结算'),
                      ),
                      taskUid: task.uid,
                    );
                }
                return settledConsumed;
              });
          if (settledConsumed == null) continue;

          // 收集已结算记录（用 finalConsumed 替换 consumedGrams 字段，供异常检测用）
          settledEntries.add(
            e.copyWith(
              consumedGrams: settledConsumed,
              lastDeductedGrams: settledConsumed,
              consumedAt: DateTime.now(),
            ),
          );
        } catch (ex, st) {
          // BUG-8 修复：单个 entry 结算失败不中断循环，记录后继续处理其他 entry
          failedEntries.add(e);
          ErrorLogger.log(
            ex,
            st,
            source: 'print_task',
            level: ErrorLevel.warning,
            context: {
              'phase': 'settle_single_entry',
              'taskId': task.id,
              'entryId': e.id,
            },
          );
        }
      }

      // BUG-8 修复：部分 entry 结算失败时告警用户手动核查
      if (failedEntries.isNotEmpty) {
        try {
          ref
              .read(notificationServiceProvider)
              .alert(
                type: AlertType.consumptionAnomaly,
                title: '部分耗材结算失败',
                body:
                    '${task.taskName} 有 ${failedEntries.length} 卷耗材结算失败，'
                    '已成功结算 ${settledEntries.length} 卷。'
                    '失败卷的库存可能未修正，请手动核查。',
              );
        } catch (_) {}
      }

      // 创新2: 结算异常检测（所有卷结算完成后统一检测，含 Z-score 统计）
      if (settledEntries.isNotEmpty) {
        await ref
            .read(anomalyDetectionServiceProvider)
            .detectSettlement(
              task: task,
              entries: settledEntries,
              isCancelled: isCancelled,
            );
      }

      // P1-5: 结算成功后，检查实时扣减失败计数，提示用户已自动修正
      final failCount = _deductFailureCount[task.id!] ?? 0;
      if (failCount > 0 && failedEntries.isEmpty) {
        try {
          ref
              .read(notificationServiceProvider)
              .alert(
                type: AlertType.consumptionAnomaly,
                title: '耗材扣减已自动修正',
                body:
                    '${task.taskName} 打印过程中有 $failCount 次实时扣减异常，'
                    '结算时已自动修正库存与消耗记录，无需手动处理。',
              );
        } catch (_) {}
      }
    } catch (e, st) {
      // 结算失败不影响任务流程，用户可手动修正
      // P1-5: 结算失败是严重事件，Toast 告警提示用户手动核查
      try {
        ref
            .read(notificationServiceProvider)
            .alert(
              type: AlertType.consumptionAnomaly,
              title: '耗材结算失败',
              body:
                  '${task.taskName} 结算时发生错误，库存与消耗记录可能不一致，'
                  '请手动核查耗材库存与历史记录。错误已记录到日志。',
            );
      } catch (_) {}
      ErrorLogger.log(
        e,
        st,
        source: 'print_task',
        level: ErrorLevel.error,
        context: {'phase': 'settle_task', 'taskId': task.id},
      );
    } finally {
      // 无论成功失败都清理缓存，防止内存泄漏
      _settlingTasks.remove(task.id!);
      _cleanupTaskCache(task.id!);
      // P1-5: 清理失败计数（结算已完成，计数不再需要）
      _deductFailureCount.remove(task.id!);
      // P0-3 修复：清理 gcodePath 键控缓存，防止长期运行后无限增长。
      // _sliceCache：任务结束后切片结果不再需要，下次重打同一文件会重新解析。
      // _amsMappingAlertedPaths：告警去重集合同步清理，下次重打若仍映射失败会重新告警（符合预期）。
      if (task.gcodePath.isNotEmpty) {
        _sliceCache.remove(task.gcodePath);
        _amsMappingAlertedPaths.remove(task.gcodePath);
        // 清理换色提醒服务的缓存和触发记录，防止下次重打同路径文件时残留状态。
        try {
          ref
              .read(filamentChangeReminderServiceProvider)
              .clearForGcode(task.gcodePath);
        } catch (_) {}
      }
    }
  }

  /// 清理任务缓存（关联记录 + 节流时间戳 + Future 引用）。
  void _cleanupTaskCache(int taskId) {
    _taskConsumablesCache.remove(taskId);
    _lastDeductTime.remove(taskId);
    _pendingDeducts.remove(taskId);
    // P1-5: 失败计数延迟到结算完成后清理（_settleTaskConsumables 末尾），
    // 这里不清理，避免结算时读不到计数。
  }

  /// 文件不匹配时：把旧任务标记 cancelled，并尝试自动创建新任务。
  ///
  /// 场景：用户先通过软件发任务 A（任务表 printing），又在打印机屏幕上
  /// 启动任务 B。打印机上报 gcodeFile 变成 B 的文件名，与任务 A 不匹配。
  /// 此时把 A 标为 cancelled，再尝试自动创建 B。
  ///
  /// **校准阶段保护**：如果旧任务 mcPercent=0（还在校准），不扣减耗材。
  ///
  /// **注意**：此处用旧任务的 lastMcPercent 计算消耗，不用 status.mcPercent
  /// （后者是新文件的进度，与旧任务无关，会导致消耗计算错误）。
  Future<void> _cancelTaskForFileMismatch(
    PrintTask task,
    BambuPrinterStatus status, {
    String? serialOverride,
  }) async {
    // 用旧任务最后已知进度，不用新文件的 status.mcPercent
    final finalGrams = _calculateActualGrams(task: task);
    final claimed = await ref
        .read(printTaskDaoProvider)
        .finish(
          id: task.id!,
          actualGrams: finalGrams,
          status: PrintTaskStatus.cancelled,
          lastMcPercent: task.lastMcPercent,
          lastLayer: task.lastLayer,
        );
    if (claimed == 0) return;
    final terminalTask = task.copyWith(
      actualGrams: finalGrams,
      status: PrintTaskStatus.cancelled,
      finishedAt: DateTime.now(),
    );
    await _upsertTerminalPresetResult(
      task: terminalTask,
      printerStatus: status,
    );
    await _cancelPrintingQueueItemForTask(
      terminalTask,
      serialOverride: serialOverride,
    );
    // M7 修复：await 结算完成后再创建新任务，防止两个任务的扣减交叉
    await _settleTaskConsumables(
      task: task.copyWith(actualGrams: finalGrams),
      finalGrams: finalGrams,
      isCancelled: true,
    );
    // 打印机切到新文件且正在 running → 自动创建屏幕任务
    if (!_isDisposed && status.gcodeState == BambuGcodeState.running) {
      await _maybeAutoCreateScreenTask(status, serialOverride: serialOverride);
    }
  }

  /// 自动创建屏幕启动任务。
  ///
  /// **触发条件**：打印机 gcode_state=RUNNING 但本地无活跃任务。
  /// **场景**：用户在打印机屏幕上选文件启动打印，软件未发任务但需要追踪。
  ///
  /// **去重**：用 [_isCreatingScreenTask] 标志位防止并发推送导致重复创建。
  /// 创建后 watchActive 流会把新任务回写到 state，后续状态走正常更新流程。
  ///
  /// **任务标识**：优先用 subtaskName，其次 gcodeFile basename。
  /// **source 字段**标记为 'screen'，便于 UI 区分软件发送 vs 屏幕启动。
  /// **estimatedGrams** 为 0（无切片信息无法预估），actualGrams 也只能记 0，
  /// 精细克数统计需要后续用户把切片文件关联到该任务。
  ///
  /// **on_demand 模式优化**：当切片读取方式为 [SliceReadMode.onDemand] 时，
  /// 会按 gcode 文件名去切片输出目录查找并解析切片文件，拿到 estimatedGrams +
  /// ams_mapping + filaments，从而支持完整的耗材统计（与 watch 模式效果一致）。
  /// 查找失败则回退到无切片信息的屏幕任务。
  Future<void> _maybeAutoCreateScreenTask(
    BambuPrinterStatus status, {
    String? serialOverride,
  }) async {
    final serial = serialOverride ?? ref.read(activePrinterSerialProvider);
    if (serial == null || serial.isEmpty) return;
    if (_creatingScreenTaskSerials.contains(serial)) return;
    _creatingScreenTaskSerials.add(serial);

    final file = status.gcodeFile;
    final subtask = status.subtaskName;
    try {
      final printerId = await ref
          .read(printerDaoProvider)
          .getPrinterIdBySerial(serial);
      if (printerId == null) return;
      final queueDao = ref.read(printQueueDaoProvider);
      final queueItem = await queueDao.getPrinting(serial);

      // 队列任务本身就是稳定标识；部分型号的增量 MQTT 状态不带文件名，
      // 不能因此丢掉任务、耗材与实验结果链路。
      if ((file == null || file.isEmpty) &&
          (subtask == null || subtask.isEmpty) &&
          queueItem == null) {
        return;
      }

      final taskName = (subtask != null && subtask.isNotEmpty)
          ? subtask
          : (file != null && file.isNotEmpty
                ? file.split(RegExp(r'[/\\]')).last
                : (queueItem?.filename ?? '屏幕启动任务'));
      final gcodePath =
          queueItem?.gcodePath ??
          ((file != null && file.isNotEmpty)
              ? file
              : (subtask ?? 'screen_task'));

      // 按文件名查找解析切片文件（两种模式都尝试，watch 模式优先从缓存取）
      SliceResult? slice;
      if (queueItem != null) {
        slice = await SliceIsolateRunner.parseAuto(queueItem.gcodePath);
        if (slice != null) {
          _sliceCache[slice.filePath] = slice;
        }
      }
      if (file != null && file.isNotEmpty) {
        final basename = file.split(RegExp(r'[/\\]')).last.toLowerCase();

        // watch 模式：优先从 recentSlices 缓存中按 basename 精确查找
        if (slice == null && basename.isNotEmpty) {
          final watcherState = ref.read(slicerWatcherProvider);
          for (final s in watcherState.recentSlices) {
            final sBasename = s.filePath
                .split(RegExp(r'[/\\]'))
                .last
                .toLowerCase();
            if (sBasename == basename) {
              slice = s;
              break;
            }
          }
        }

        // 缓存未命中或 onDemand 模式：按需解析切片文件
        slice ??= await _findAndParseSlice(file);
        if (slice != null) {
          _sliceCache[slice.filePath] = slice;
        }
      }

      // 用户从打印机屏幕或 Bambu Handy 发起任务时，本机通常没有切片文件。
      // 此时用同一设备的活跃云任务补齐预计克数与 AMS 映射；失败或未登录时
      // 保持原有零估算任务，不影响 MQTT 监控链路。
      if (slice == null) {
        try {
          final cloudTasks = await ref
              .read(bambuCloudTasksProvider.future)
              .timeout(const Duration(seconds: 4));
          final cloudTask = findActiveCloudTaskForPrinter(
            tasks: cloudTasks,
            serial: serial,
            taskName: taskName,
            gcodeFile: file,
          );
          if (cloudTask != null) {
            final hasAms =
                (status.amsUnits?.isNotEmpty ?? false) ||
                (status.amsTrays?.isNotEmpty ?? false);
            slice = cloudTaskToSliceResult(
              task: cloudTask,
              fallbackPath: gcodePath,
              fallbackTaskName: taskName,
              hasAms: hasAms,
              totalLayers: status.totalLayers ?? 0,
            );
            if (slice != null) {
              _sliceCache[slice.filePath] = slice;
            }
          }
        } catch (error, stackTrace) {
          // 云端补全是尽力而为，局域网用户与临时网络故障不应阻断任务创建。
          ErrorLogger.log(
            error,
            stackTrace,
            source: 'print_task',
            level: ErrorLevel.warning,
            context: {
              'phase': 'enrich_screen_task_from_cloud',
              'serial': serial,
            },
          );
        }
      }

      final now = DateTime.now();
      final task = PrintTask(
        uid: _uuid.v4(),
        printerId: printerId,
        consumableId: null,
        gcodePath: slice?.filePath ?? gcodePath,
        taskName: taskName,
        estimatedGrams: slice?.totalGrams ?? 0,
        estimatedSeconds: slice?.estimatedSeconds ?? 0,
        actualGrams: 0,
        startedAt: now,
        lastMcPercent: 0, // H5 修复：强制从校准阶段开始保护，防止残留 mcPercent 导致误扣减
        lastLayer: status.currLayer ?? 0,
        status: PrintTaskStatus.printing,
        source: 'screen', // 标记来源为屏幕启动
        perFilamentGrams:
            slice?.filaments.map((f) => f.grams).toList() ?? const [],
        note: slice != null ? '屏幕启动（已自动匹配切片）' : '打印机屏幕启动',
        createdAt: now,
        updatedAt: now,
      );

      final taskId = await ref.read(printTaskDaoProvider).create(task);

      // 有切片信息时建立耗材关联记录（含 AMS 映射）
      if (slice != null) {
        final statusHasAms =
            (status.amsUnits?.isNotEmpty ?? false) ||
            (status.amsTrays?.isNotEmpty ?? false);
        final activeTray = int.tryParse(status.trayNow ?? '');
        await _createTaskConsumableLinks(
          taskId: taskId,
          printerId: printerId,
          slice: slice,
          now: now,
          forceExternalMapping:
              !statusHasAms || activeTray == 254 || activeTray == 255,
        );
        await _captureTaskAttribution(taskId: taskId, slice: slice);
        await _queueExternalMulticolorPlan(
          taskId: taskId,
          printerId: printerId,
          printerSerial: serial,
          taskName: taskName,
          slice: slice,
          hasAms: statusHasAms,
          trayNow: status.trayNow,
        );
      } else {
        await _captureTaskAttribution(taskId: taskId, slice: null);
      }
      if (queueItem?.id != null) {
        if (queueItem!.experimentRunId != null) {
          await ref
              .read(experimentServiceProvider)
              .bindQueuedRunToTask(
                queueItem: queueItem,
                taskId: taskId,
                slice: slice,
              );
        } else {
          await queueDao.setStatus(
            queueItem.id!,
            PrintQueueStatus.printing,
            printTaskId: taskId,
          );
        }
      }
      // create 后 watchActive 流会自动更新 state，无需手动 set
    } finally {
      _creatingScreenTaskSerials.remove(serial);
      // H4 修复：任务创建完成后，补一次创建期间缓存的最新 MQTT 进度，
      // 防止解析切片文件期间到达的进度事件丢失
      final isActivePrinter = serial == ref.read(activePrinterSerialProvider);
      final pending = isActivePrinter ? _pendingScreenStatus : null;
      if (isActivePrinter) _pendingScreenStatus = null;
      if (pending != null && mounted) {
        // 等待 watchActive 流把新任务回写到 state
        // 架构修复：用 Timer 持有引用，dispose 时取消，防止 100ms 窗口期访问 state
        _pendingScreenStatusTimer?.cancel();
        _pendingScreenStatusTimer = Timer(
          const Duration(milliseconds: 100),
          () {
            if (_isDisposed || !mounted) return;
            final task = state;
            if (task != null && !task.status.isTerminal) {
              unawaited(_updateExistingTask(task, pending));
            }
          },
        );
      }
    }
  }

  Future<void> _cancelPrintingQueueItemForTask(
    PrintTask task, {
    String? serialOverride,
  }) async {
    final serial = serialOverride ?? ref.read(activePrinterSerialProvider);
    if (serial == null || task.id == null) return;
    final queueDao = ref.read(printQueueDaoProvider);
    final queueItem = await queueDao.getPrinting(serial);
    if (queueItem?.id == null) return;
    if (queueItem!.printTaskId != null && queueItem.printTaskId != task.id) {
      return;
    }
    await queueDao.setStatus(
      queueItem.id!,
      PrintQueueStatus.cancelled,
      completedAt: DateTime.now(),
    );
    await ref
        .read(experimentServiceProvider)
        .markQueueRunStatus(queueItem, RunStatus.cancelled);
    await ref.read(printQueueProvider(serial).notifier).refresh();
  }

  /// 按 gcode 文件名去切片输出目录递归查找并解析切片文件。
  ///
  /// MQTT 上报的 [gcodeFile] 可能是完整路径或纯文件名，取 basename 在
  /// 切片输出目录下递归精确匹配同名 .gcode / .3mf 文件。
  /// 找到后解析返回 SliceResult，找不到返回 null。
  ///
  /// **查找策略**：
  /// 1. 精确 basename 匹配（如 `test.gcode` 只匹配 `test.gcode`，不匹配 `copy_test.gcode`）
  /// 2. .gcode → .3mf 回退（BambuStudio 默认只存 .3mf 项目文件时）
  /// 3. 流式查找，找到首个匹配立即停止，不全量列举目录
  Future<SliceResult?> _findAndParseSlice(String gcodeFile) async {
    try {
      // C2 修复：用 .future 等待切片软件状态加载完成，避免启动早期竞态
      final status = await ref.read(activeSlicerStatusProvider.future);
      final outDir = status?.outputDirectory;
      if (outDir == null) return null;

      final dir = Directory(outDir);
      if (!await dir.exists()) return null;

      // 取目标文件 basename（小写用于比较）
      final basename = gcodeFile.split(RegExp(r'[/\\]')).last.toLowerCase();
      if (basename.isEmpty) return null;

      // C1 修复：精确 basename 匹配（非 endsWith 后缀匹配）
      // M3 修复：流式查找，找到首个匹配立即停止
      File? match = await _findFileByBasename(dir, basename);

      // C4 修复：.gcode → .3mf 回退
      if (match == null && basename.endsWith('.gcode')) {
        final threemfBasename =
            '${basename.substring(0, basename.length - 6)}.3mf';
        match = await _findFileByBasename(dir, threemfBasename);
      }

      if (match == null) return null;

      final matchedPath = match.path;
      final enableLayerMapping =
          ref.read(printTaskCalculationModeProvider) == CalculationMode.precise;

      // P1-3: 在 Isolate 中解析（避免大文件阻塞 UI）
      if (matchedPath.toLowerCase().endsWith('.3mf')) {
        return SliceIsolateRunner.parse3mf(
          matchedPath,
          enableLayerMapping: enableLayerMapping,
        );
      }
      return SliceIsolateRunner.parseGcode(
        matchedPath,
        enableLayerMapping: enableLayerMapping,
      );
    } catch (e, st) {
      ErrorLogger.log(
        e,
        st,
        source: 'gcode_parser',
        level: ErrorLevel.warning,
        context: {'phase': 'find_and_parse_slice'},
      );
      return null;
    }
  }

  /// 在目录中递归查找 basename 精确匹配的文件（大小写不敏感）。
  /// 找到首个匹配立即返回，不全量列举目录。
  Future<File?> _findFileByBasename(Directory dir, String lowerBasename) async {
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final fb = entity.path.split(RegExp(r'[/\\]')).last.toLowerCase();
          if (fb == lowerBasename) return entity;
        }
      }
    } catch (e, st) {
      ErrorLogger.log(
        e,
        st,
        source: 'gcode_parser',
        level: ErrorLevel.warning,
        context: {'phase': 'find_file_by_basename', 'dir': dir.path},
      );
      // 目录访问失败返回 null
    }
    return null;
  }

  /// 计算实际克数（不写库）。
  double _calculateActualGrams({required PrintTask task}) {
    final slice = _sliceCache[task.gcodePath];
    final mode = ref.read(printTaskCalculationModeProvider);
    return GramCalculator.calculate(task: task, slice: slice, mode: mode);
  }

  /// 创建新打印任务。
  ///
  /// [printerId] 关联打印机
  /// [consumableId] 主耗材（T0 槽位，可选，多色任务自动从通道读取）
  /// [slice] 切片结果（含 gcodePath、estimatedGrams、layerCumulativeGrams）
  /// [taskName] 任务名（默认用 slice.taskName）
  /// [toolConsumableOverrides] C3 新增：用户在映射确认 UI 中指定的 T→耗材 映射。
  ///   无 AMS 映射的多色任务（手动换料场景）由用户为每个 T 选择耗材。
  ///
  /// 创建后任务处于 planned 状态，等待用户在打印机上启动。
  /// 也可调用 [sendToPrinter] 直接发送到打印机。
  ///
  /// **耗材关联**：按切片 SliceResult.filaments[i].toolIndex → 打印机
  /// PrinterChannels[channelIndex] → consumableId 建立关联记录，
  /// 同时匹配成本配置冻结单价快照。无切片信息的屏幕任务不建关联。
  Future<int> createTask({
    required int printerId,
    int? consumableId,
    required SliceResult slice,
    String? taskName,
    String? note,
    Map<int, int>? toolConsumableOverrides,
  }) async {
    final explicitlySelected = <int>{
      if (consumableId != null) consumableId,
      ...?toolConsumableOverrides?.values,
    };
    for (final selectedId in explicitlySelected) {
      if (!await _canUseCurrentPersonalConsumable(
        selectedId,
        claimAnonymous: true,
      )) {
        throw StateError('所选耗材属于其他 Sohun 账号，请重新选择');
      }
    }
    // 缓存切片结果，后续实时计算用
    _sliceCache[slice.filePath] = slice;

    final now = DateTime.now();
    final task = PrintTask(
      uid: _uuid.v4(),
      printerId: printerId,
      consumableId: consumableId,
      gcodePath: slice.filePath,
      taskName: taskName ?? slice.taskName,
      estimatedGrams: slice.totalGrams,
      estimatedSeconds: slice.estimatedSeconds,
      actualGrams: 0,
      lastMcPercent: 0,
      lastLayer: 0,
      status: PrintTaskStatus.planned,
      source: slice.slicerName,
      perFilamentGrams: slice.filaments
          .map((f) => f.grams)
          .toList(growable: false),
      note: note,
      createdAt: now,
      updatedAt: now,
    );

    final id = await ref.read(printTaskDaoProvider).create(task);

    // 建立耗材关联记录（按 toolIndex 匹配打印机通道 → 耗材卷）
    await _createTaskConsumableLinks(
      taskId: id,
      printerId: printerId,
      slice: slice,
      now: now,
      toolConsumableOverrides: toolConsumableOverrides,
      forceExternalMapping:
          slice.amsMapping == null || slice.amsMapping!.isEmpty,
    );

    await _captureTaskAttribution(taskId: id, slice: slice);

    final printer = await ref
        .read(printerDaoProvider)
        .getByIdWithChannels(printerId);
    final mapping = slice.amsMapping;
    final inferredHasAms =
        mapping != null &&
        mapping.isNotEmpty &&
        mapping.any((channel) => channel >= 0 && channel < 254);
    await _queueExternalMulticolorPlan(
      taskId: id,
      printerId: printerId,
      printerSerial: printer?.serial ?? 'printer-$printerId',
      taskName: taskName ?? slice.taskName,
      slice: slice,
      hasAms: inferredHasAms,
      trayNow: inferredHasAms ? null : '254',
      alreadyMappedToolIndices: toolConsumableOverrides?.keys.toSet(),
      farmMode: ref.read(studioModeEnabledProvider),
    );

    return id;
  }

  Future<void> _captureTaskAttribution({
    required int taskId,
    required SliceResult? slice,
  }) async {
    final dao = PresetResultDao(ref.read(databaseProvider));
    try {
      Map<String, dynamic>? exactApplication;
      var attribution = ResultAttribution.unknown;

      final hash = slice?.artifactSha256;
      if (hash != null) {
        final candidates = await dao.getApplicationsByArtifactHash(hash);
        if (candidates.length == 1) {
          exactApplication = candidates.single;
          attribution = ResultAttribution.exact;
        } else if (candidates.length > 1) {
          attribution = ResultAttribution.ambiguous;
        }
      }

      if (exactApplication == null && slice?.printSettingsId != null) {
        final candidates = await dao.getApplicationsBySlicerSettingsId(
          slice!.printSettingsId!,
        );
        if (candidates.isNotEmpty) {
          attribution = ResultAttribution.ambiguous;
        }
      }

      final firstFilament = slice == null || slice.filaments.isEmpty
          ? null
          : slice.filaments.first;
      await dao.recordTaskAttribution(
        taskId: taskId,
        snapshotId: exactApplication?['snapshot_id'] as String?,
        applicationId: exactApplication?['id'] as String?,
        presetDisplayName: (exactApplication?['display_name'] as String?) ?? '',
        attribution: attribution,
        communityPublicationId:
            exactApplication?['community_publication_id'] as String?,
        communityVersionId:
            exactApplication?['community_version_id'] as String?,
        communityRevision: exactApplication?['community_revision'] as int?,
        artifactSha256: hash,
        printSettingsId: slice?.printSettingsId,
        printerSettingsId: slice?.printerSettingsId,
        nozzleDiameter: slice?.nozzleDiameter,
        plateType: slice?.plateType,
        materialProfile: firstFilament?.settingsId,
        materialType: firstFilament?.materialType,
      );
    } catch (error, stackTrace) {
      ErrorLogger.log(
        error,
        stackTrace,
        source: 'print_task',
        level: ErrorLevel.warning,
        context: {'phase': 'capture_preset_attribution', 'taskId': taskId},
      );
    } finally {
      dao.dispose();
    }
  }

  Future<void> _upsertTerminalPresetResult({
    required PrintTask task,
    required BambuPrinterStatus printerStatus,
  }) async {
    final taskId = task.id;
    if (taskId == null) return;
    final dao = PresetResultDao(ref.read(databaseProvider));
    try {
      final attribution = await dao.getTaskAttribution(taskId);
      String printerModel = '';
      if (task.printerId != null) {
        final printer = await ref
            .read(printerDaoProvider)
            .getByIdWithChannels(task.printerId!);
        printerModel = printer?.printer.model ?? '';
      }

      final technicalStatus = switch (task.status) {
        PrintTaskStatus.finished => TechnicalStatus.finished,
        PrintTaskStatus.failed => TechnicalStatus.failed,
        PrintTaskStatus.cancelled => TechnicalStatus.cancelled,
        _ => throw StateError('非终态任务不能生成打印结果: ${task.status.code}'),
      };
      final hmsAlerts = printerStatus.hmsAlerts;
      final firstHms = hmsAlerts == null || hmsAlerts.isEmpty
          ? null
          : hmsAlerts.first;
      final elapsedSeconds = task.startedAt == null
          ? 0
          : task.finishedAt!.difference(task.startedAt!).inSeconds;
      final actualSeconds = elapsedSeconds < 0 ? 0 : elapsedSeconds;

      final resultId = await dao.upsertResultForTask(
        taskId: taskId,
        taskUid: task.uid,
        snapshotId: attribution?['snapshot_id'] as String?,
        applicationId: attribution?['application_id'] as String?,
        presetDisplayName:
            (attribution?['preset_display_name'] as String?) ?? '',
        attribution: ResultAttribution.fromString(
          attribution?['attribution'] as String?,
        ),
        communityPublicationId:
            attribution?['community_publication_id'] as String?,
        communityVersionId: attribution?['community_version_id'] as String?,
        communityRevision: attribution?['community_revision'] as int?,
        printerModel: printerModel,
        nozzleDiameter: (attribution?['nozzle_diameter'] as num?)?.toDouble(),
        plateType: attribution?['plate_type'] as String?,
        materialProfile: attribution?['material_profile'] as String?,
        materialType: attribution?['material_type'] as String?,
        amsHumidity: printerStatus.amsHumidity?.toDouble(),
        amsHumiditySampledAt: printerStatus.amsHumidity == null
            ? null
            : printerStatus.updatedAt,
        technicalStatus: technicalStatus,
        failureCode: printerStatus.printError ?? firstHms?.code,
        failureCategory: printerStatus.failReason,
        estimatedGrams: task.estimatedGrams,
        actualGrams: task.actualGrams,
        estimatedSeconds: task.estimatedSeconds,
        actualSeconds: actualSeconds,
      );
      await ref
          .read(experimentServiceProvider)
          .linkTerminalTaskResult(taskId: taskId, resultId: resultId);
    } catch (error, stackTrace) {
      ErrorLogger.log(
        error,
        stackTrace,
        source: 'print_task',
        level: ErrorLevel.error,
        context: {'phase': 'upsert_preset_result', 'taskId': taskId},
      );
    } finally {
      dao.dispose();
    }
  }

  /// 按切片 filaments 建立任务↔耗材卷关联记录。
  ///
  /// 每个 FilamentUsage 对应一个 toolIndex（T0/T1...），
  /// 查打印机的 PrinterChannels[channelIndex=toolIndex] 取绑定的 consumableId，
  /// 同时匹配成本配置冻结单价快照。
  ///
  /// **C3 修复**：无 AMS 映射的多色任务（手动换料场景）：
  /// - 所有 T 的 channelIndex 都设为 0（单通道打印机）
  /// - consumableId 由 [toolConsumableOverrides] 指定（用户在映射确认 UI 中选择）
  Future<void> _queueExternalMulticolorPlan({
    required int taskId,
    required int printerId,
    required String printerSerial,
    required String taskName,
    required SliceResult slice,
    required bool hasAms,
    required String? trayNow,
    Set<int>? alreadyMappedToolIndices,
    bool farmMode = false,
  }) async {
    // Farm production has its own plate/AMS assignment workflow. Never put a
    // farm task into the personal external-color dialog queue.
    if (farmMode) return;
    var filaments = externalFilamentsRequiringPlan(
      slice: slice,
      hasAms: hasAms,
      trayNow: trayNow,
    );
    if (alreadyMappedToolIndices != null) {
      filaments = filaments
          .where((item) => !alreadyMappedToolIndices.contains(item.toolIndex))
          .toList();
    }
    if (filaments.isEmpty) return;

    final config = ref
        .read(printerConnectionListProvider.notifier)
        .get(printerSerial);
    final localPrinter = await ref.read(printerDaoProvider).getById(printerId);
    final localName = localPrinter?.name?.trim();
    final printerLabel =
        config?.displayLabel ??
        (localName?.isNotEmpty == true ? localName! : printerSerial);

    ref
        .read(externalMulticolorPlanQueueProvider.notifier)
        .enqueue(
          ExternalMulticolorPlanRequest(
            taskId: taskId,
            printerId: printerId,
            printerSerial: printerSerial,
            printerLabel: printerLabel,
            taskName: taskName,
            filaments: filaments,
            changePoints: slice.filamentChangePoints,
            createdAt: DateTime.now(),
            farmMode: farmMode,
          ),
        );
  }

  /// Applies the user-confirmed T-to-inventory mapping. The next MQTT progress
  /// update catches up all real-time deductions from zero, so no material used
  /// while this dialog was open is lost.
  Future<void> applyExternalMulticolorPlan({
    required int taskId,
    required Map<int, int> toolConsumableIds,
  }) async {
    if (toolConsumableIds.isEmpty) {
      throw ArgumentError('至少需要选择一卷库存耗材');
    }
    final database = ref.read(databaseProvider);
    final ptcDao = ref.read(printTaskConsumableDaoProvider);
    final consumableDao = ref.read(consumableDaoProvider);
    final costDao = ref.read(filamentCostConfigDaoProvider);
    await database.transaction(() async {
      final current = await ptcDao.getByTask(taskId);
      final pendingTools = current
          .where((entry) => entry.consumedAt == null)
          .map((entry) => entry.toolIndex)
          .toSet();
      if (!toolConsumableIds.keys.every(pendingTools.contains)) {
        throw StateError('打印任务已经结束或耗材方案已失效');
      }

      final selectedIds = toolConsumableIds.values.toSet();
      final demandByConsumable = <int, double>{};
      for (final entry in current) {
        if (entry.consumedAt != null) continue;
        final consumableId =
            toolConsumableIds[entry.toolIndex] ?? entry.consumableId;
        if (consumableId == null || !selectedIds.contains(consumableId)) {
          continue;
        }
        demandByConsumable.update(
          consumableId,
          (grams) => grams + entry.estimatedGrams,
          ifAbsent: () => entry.estimatedGrams,
        );
      }

      final outstanding = await ptcDao.getOutstandingDemandByConsumable(
        excludingTaskId: taskId,
      );
      final selectedConsumables = <int, Consumable>{};
      for (final demand in demandByConsumable.entries) {
        if (!await _canUseCurrentPersonalConsumable(
          demand.key,
          claimAnonymous: true,
        )) {
          throw StateError('所选耗材属于其他 Sohun 账号，请重新选择');
        }
        final consumable = await consumableDao.getById(demand.key);
        if (consumable == null || consumable.remainingGrams <= 0) {
          throw StateError('所选耗材已不存在或库存不足，请重新选择');
        }
        final reservedByOtherTasks = outstanding[demand.key] ?? 0.0;
        final available = consumable.remainingGrams - reservedByOtherTasks;
        if (available + 0.01 < demand.value) {
          final shortage = demand.value - available;
          final occupiedHint = reservedByOtherTasks > 0.01
              ? '（其他任务已占用 ${reservedByOtherTasks.toStringAsFixed(1)}g）'
              : '';
          throw StateError(
            '${consumable.manufacturer} ${consumable.model} 库存不足$occupiedHint，'
            '还差 ${shortage.toStringAsFixed(1)}g，请补入同款卷或重新分配',
          );
        }
        selectedConsumables[demand.key] = consumable;
      }

      final updates =
          <
            ({
              int toolIndex,
              int consumableId,
              double? costPerKg,
              int? costConfigId,
            })
          >[];
      for (final item in toolConsumableIds.entries) {
        final consumable = selectedConsumables[item.value]!;
        final cost = await costDao.matchCost(
          vendor: consumable.manufacturer,
          materialType: consumable.materialType,
          colorHex: consumable.colorHex,
        );
        updates.add((
          toolIndex: item.key,
          consumableId: item.value,
          costPerKg: cost?.costPerKg,
          costConfigId: cost?.id,
        ));
      }

      await ptcDao.updateExternalMappings(taskId, updates);
    });
    _taskConsumablesCache[taskId] = await ptcDao.getByTask(taskId);
    _lastDeductTime.remove(taskId);
  }

  Future<void> _createTaskConsumableLinks({
    required int taskId,
    required int printerId,
    required SliceResult slice,
    required DateTime now,
    Map<int, int>? toolConsumableOverrides,
    bool forceExternalMapping = false,
  }) async {
    if (slice.filaments.isEmpty) return;
    final printerDao = ref.read(printerDaoProvider);
    final costDao = ref.read(filamentCostConfigDaoProvider);
    final ptcDao = ref.read(printTaskConsumableDaoProvider);
    final consumableDao = ref.read(consumableDaoProvider);

    // 取打印机通道列表（含绑定的耗材）
    final printerWithChannels = await printerDao.getByIdWithChannels(printerId);
    if (printerWithChannels == null) return;
    final channels = printerWithChannels.channels;

    final entries = <PrintTaskConsumable>[];
    final amsMapping = slice.amsMapping;
    final activeFilamentCount = slice.filaments
        .where((item) => item.grams > 0.01)
        .length;
    final hasConfirmedManualChanges =
        activeFilamentCount > 1 &&
        (slice.filamentChangePoints.isNotEmpty || slice.toolChangeCount > 0);
    for (final f in slice.filaments) {
      // C3 修复：确定 T→通道映射
      // - 有 amsMapping 且长度足够：用 amsMapping[toolIndex]
      // - 无 amsMapping（null 或空）：单通道打印机多色任务（手动换料），
      //   所有 T 都用通道 0，consumableId 由用户在映射确认 UI 中选择
      // - amsMapping 存在但长度不足：回退到 toolIndex
      int channelIndex;
      if (forceExternalMapping) {
        channelIndex = 0;
      } else if (amsMapping != null &&
          amsMapping.isNotEmpty &&
          f.toolIndex < amsMapping.length) {
        channelIndex = amsMapping[f.toolIndex];
      } else if (amsMapping == null || amsMapping.isEmpty) {
        // 无 AMS 映射：单通道打印机多色任务（手动换料）
        // 所有 T 都用通道 0，consumableId 由用户在映射确认 UI 中选择
        channelIndex = 0;
      } else {
        // amsMapping 存在但长度不足，回退
        channelIndex = f.toolIndex;
      }

      // C3 修复：优先使用用户在映射确认 UI 中指定的耗材，否则从通道绑定获取
      // 注意：amsMapping 可能含 -1（TPU 直通），channelIndex 为负时无对应通道
      int? consumableId;
      Consumable? cons;
      if (channelIndex >= 0) {
        for (final channel in channels) {
          if (channel.channel.channelIndex == channelIndex) {
            cons = channel.consumable;
            break;
          }
        }
      }
      final mappedChannelIsExternal = channelIndex < 0 || channelIndex >= 254;
      final mappingMissing =
          amsMapping == null ||
          amsMapping.isEmpty ||
          f.toolIndex >= amsMapping.length;
      final requiresUserMapping =
          hasConfirmedManualChanges &&
          (forceExternalMapping || mappingMissing || mappedChannelIsExternal);
      if (toolConsumableOverrides != null &&
          toolConsumableOverrides.containsKey(f.toolIndex)) {
        consumableId = toolConsumableOverrides[f.toolIndex];
        if (consumableId != null) {
          cons = await consumableDao.getById(consumableId);
        } else {
          cons = null;
        }
      } else if (requiresUserMapping) {
        // Never deduct several external colors from the same channel fallback.
        // The plan dialog will fill this association before deduction starts.
        consumableId = null;
        cons = null;
      } else {
        consumableId = cons?.id;
      }

      if (cons != null &&
          !await _canUseCurrentPersonalConsumable(
            cons.id,
            claimAnonymous: true,
          )) {
        consumableId = null;
        cons = null;
      }

      // 匹配成本配置，冻结单价快照
      double? costSnapshot;
      int? matchedConfigId;
      if (cons != null) {
        final config = await costDao.matchCost(
          vendor: cons.manufacturer,
          materialType: cons.materialType,
          colorHex: cons.colorHex,
        );
        if (config != null) {
          costSnapshot = config.costPerKg;
          matchedConfigId = config.id;
        }
      } else if (f.vendor != null || f.materialType != null) {
        // 通道没绑耗材，但切片有元信息，尝试按切片元信息匹配成本
        final config = await costDao.matchCost(
          vendor: f.vendor ?? '',
          materialType: f.materialType ?? '',
          colorHex: f.colorHex ?? '',
        );
        if (config != null) {
          costSnapshot = config.costPerKg;
          matchedConfigId = config.id;
        }
      }

      entries.add(
        PrintTaskConsumable(
          taskId: taskId,
          printerId: printerId,
          channelIndex: channelIndex,
          consumableId: consumableId,
          toolIndex: f.toolIndex,
          estimatedGrams: f.grams,
          consumedGrams: 0,
          lastDeductedGrams: 0,
          costPerKgSnapshot: costSnapshot,
          matchedCostConfigId: matchedConfigId,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    if (entries.isNotEmpty) {
      // C1 修复：用 createForTask 返回的带数据库 id 的记录更新缓存，
      // 后续 updateDeducted(e.id!, ...) / finalize(e.id!, ...) 才能正确按 id 更新
      final savedEntries = await ptcDao.createForTask(taskId, entries);
      _taskConsumablesCache[taskId] = savedEntries;
    }

    // P1-4: AMS 映射失败告警（多色任务且映射缺失/不完整时提醒用户）
    _checkAmsMappingCoverage(
      slice: slice,
      toolConsumableOverrides: toolConsumableOverrides,
    );
  }

  /// P1-4: 检测 AMS 映射覆盖情况，发现降级时告警。
  ///
  /// **告警条件**（同时满足）：
  /// 1. 多色任务（slice.filaments.length > 1）
  /// 2. amsMapping 缺失或不完整（无法覆盖所有 filaments 的 toolIndex）
  /// 3. 用户未通过 [toolConsumableOverrides] 手动指定全部耗材映射
  ///
  /// **告警内容**：提示耗材扣减可能归属到错误通道。
  ///
  /// **去重**：按 slice.filePath 缓存，同一切片文件只告警一次。
  void _checkAmsMappingCoverage({
    required SliceResult slice,
    Map<int, int>? toolConsumableOverrides,
  }) {
    try {
      // 单色任务无需 AMS 映射
      if (slice.filaments.length <= 1) return;

      // 去重：同一切片文件只告警一次
      final path = slice.filePath;
      if (path.isEmpty) return;
      if (_amsMappingAlertedPaths.contains(path)) return;

      final amsMapping = slice.amsMapping;
      // 检查每个 filament 的 toolIndex 是否都能从 amsMapping 取到有效映射
      final missingToolIndices = <int>[];
      for (final f in slice.filaments) {
        // 用户已手动指定耗材 → 视为已覆盖，跳过
        if (toolConsumableOverrides != null &&
            toolConsumableOverrides.containsKey(f.toolIndex)) {
          continue;
        }
        // 检查 amsMapping 是否覆盖此 toolIndex
        final covered =
            amsMapping != null &&
            amsMapping.isNotEmpty &&
            f.toolIndex < amsMapping.length;
        if (!covered) {
          missingToolIndices.add(f.toolIndex);
        }
      }

      if (missingToolIndices.isEmpty) return;

      // 标记已告警
      _amsMappingAlertedPaths.add(path);

      // 判断降级类型
      final String detail;
      if (amsMapping == null || amsMapping.isEmpty) {
        detail = '切片文件未提供 ams_mapping 信息，所有通道已回退到默认映射';
      } else {
        detail =
            'ams_mapping 长度不足（${amsMapping.length}），'
            'T${missingToolIndices.join('/T')} 已回退到 toolIndex 自身';
      }

      const title = 'AMS 通道映射降级告警';
      final body =
          '多色任务「${path.split(RegExp(r'[/\\]')).last}」$detail。'
          '耗材扣减可能归属到错误通道，建议核查切片设置或手动确认通道绑定。';

      // Toast 通知
      ref
          .read(notificationServiceProvider)
          .alert(type: AlertType.consumptionAnomaly, title: title, body: body);

      // ErrorLogger 数据库日志（便于回溯）
      ErrorLogger.log(
        '$title: $body',
        null,
        source: 'print_task',
        level: ErrorLevel.warning,
        context: {
          'phase': 'ams_mapping_degraded',
          'gcodePath': path,
          'filamentCount': slice.filaments.length,
          'missingToolIndices': missingToolIndices,
          'amsMappingLength': amsMapping?.length,
        },
      );
    } catch (e, st) {
      // 告警失败不影响主流程
      ErrorLogger.log(
        e,
        st,
        source: 'print_task',
        level: ErrorLevel.warning,
        context: {'phase': 'check_ams_mapping_coverage'},
      );
    }
  }

  /// 把任务发送到打印机（启动打印）。
  /// 仅拓竹打印机支持，发送 project_file 指令。
  /// 发送成功后任务状态自动变为 printing（等打印机上报 RUNNING 后状态机会自动同步）。
  Future<bool> sendToPrinter(int taskId) async {
    final task = await ref.read(printTaskDaoProvider).getById(taskId);
    if (task == null) return false;

    final slice =
        _sliceCache[task.gcodePath] ??
        await SliceIsolateRunner.parseAuto(task.gcodePath);

    final ok = await ref
        .read(activePrinterConnectionProvider.notifier)
        .sendPrintTask(task.gcodePath, amsMapping: slice?.amsMapping);
    if (ok) {
      // 标记为 printing，等打印机上报 RUNNING 时状态机会保持这个状态
      await ref
          .read(printTaskDaoProvider)
          .updateStatus(id: taskId, status: PrintTaskStatus.printing);
    }
    return ok;
  }

  /// 暂停当前任务
  Future<bool> pause() async {
    final task = state;
    if (task == null || !task.status.canPause) return false;
    return ref.read(activePrinterConnectionProvider.notifier).pause();
  }

  /// 恢复当前任务
  Future<bool> resume() async {
    final task = state;
    if (task == null || !task.status.canResume) return false;
    return ref.read(activePrinterConnectionProvider.notifier).resume();
  }

  /// 停止当前任务（用户主动取消）
  ///
  /// **校准阶段保护**：如果 mcPercent=0（还在校准阶段），不扣减耗材，
  /// actualGrams 记 0，_settleTaskConsumables 会跳过扣减和写日志。
  Future<bool> stop() async {
    final task = state;
    if (task == null || !task.status.canStop) return false;
    final ok = await ref.read(activePrinterConnectionProvider.notifier).stop();
    if (ok) {
      // 立刻标为 cancelled，不等打印机上报 IDLE
      final finalGrams = _calculateActualGrams(task: task);
      final claimed = await ref
          .read(printTaskDaoProvider)
          .finish(
            id: task.id!,
            actualGrams: finalGrams,
            status: PrintTaskStatus.cancelled,
            lastMcPercent: task.lastMcPercent,
            lastLayer: task.lastLayer,
          );
      if (claimed == 0) return ok;
      final printerStatus = ref.read(activePrinterConnectionProvider).status;
      if (printerStatus != null) {
        await _upsertTerminalPresetResult(
          task: task.copyWith(
            actualGrams: finalGrams,
            status: PrintTaskStatus.cancelled,
            finishedAt: DateTime.now(),
          ),
          printerStatus: printerStatus,
        );
      }
      await _cancelPrintingQueueItemForTask(
        task.copyWith(
          actualGrams: finalGrams,
          status: PrintTaskStatus.cancelled,
          finishedAt: DateTime.now(),
        ),
      );
      // 异步结算（校准阶段 finalGrams=0 不扣减不写日志）
      // 架构修复：await 结算完成后再返回，防止用户连点 stop 或应用退出时
      // 结算未完成导致库存与日志不一致。
      await _settleTaskConsumables(
        task: task,
        finalGrams: finalGrams,
        isCancelled: true,
      );
    }
    return ok;
  }

  /// 缓存切片结果（用于精细模式实时计算）。
  /// 通常由 UI 层在用户选择切片文件后调用。
  void cacheSliceResult(SliceResult slice) {
    _sliceCache[slice.filePath] = slice;
  }

  /// 取消缓存中的切片结果（释放内存）。
  void evictSliceResult(String gcodePath) {
    _sliceCache.remove(gcodePath);
  }
}

/// 打印任务编排器 provider。
/// 持有当前活跃任务的实时状态，UI 监听它显示进度卡片。
final printTaskOrchestratorProvider =
    StateNotifierProvider<PrintTaskOrchestrator, PrintTask?>((ref) {
      return PrintTaskOrchestrator(ref);
    });

/// 当前活跃任务（语法糖，等同于直接 watch orchestrator）。
final activePrintTaskProvider = Provider<PrintTask?>((ref) {
  return ref.watch(printTaskOrchestratorProvider);
});

/// 全部打印任务列表（UI 列表页用）。
final printTasksProvider = StreamProvider<List<PrintTask>>((ref) {
  // 监听 PrintTaskDao 的变更广播流，每次变更重新查询
  final dao = ref.watch(printTaskDaoProvider);
  // watchActive 已封装好 _changeController.stream.asyncMap
  return dao.watchAll();
});

/// 克数计算模式（粗略 / 精细）。
/// 枚举定义在 [CalculationMode]（lib/data/external/print_task/gram_calculator.dart）。
///
/// P0-6 修复：持久化到 SharedPreferences，重启后恢复用户选择。
/// 旧实现为内存态 StateProvider，重启后总是回到粗略模式，与用户设置不符。
class CalculationModeNotifier extends StateNotifier<CalculationMode> {
  CalculationModeNotifier() : super(CalculationMode.coarse) {
    _load();
  }

  static const _key = 'calculation_mode';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (mounted && saved == 'precise') state = CalculationMode.precise;
  }

  Future<void> set(CalculationMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}

final printTaskCalculationModeProvider =
    StateNotifierProvider<CalculationModeNotifier, CalculationMode>((ref) {
      return CalculationModeNotifier();
    });
