// 打印队列 Provider。
//
// 监听活跃打印机状态变化，驱动队列状态机：
// queued → printing → waiting_removal → completed（或 cancelled）
//
// 无人值守模式：printing → completed（跳过取件确认，直接发下一个）。
// 安全门：队首 G-code 必须通过自动清件检测（或手动标记为含），
// 否则不发送，避免喷嘴撞到上一个打印件。
//
// 注意：sendPrintTask 仅 LAN 模式支持。云端打印机的队列不自动发送任务，
// 仅记录排队，用户需手动在 BS 中打印。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/notification_service.dart';
import '../core/services/parameter_experiment_service.dart';
import '../core/services/printer_fleet_connection_manager.dart';
import '../core/services/printer_model_normalizer.dart';
import '../core/services/error_logger.dart';
import '../core/services/slice_artifact_hash_service.dart';
import '../data/database/daos/print_queue_dao.dart';
import '../data/database/database_provider.dart';
import '../data/database/models/experiment_models.dart';
import '../data/database/models/print_queue_item.dart';
import '../data/database/models/scheduler_models.dart';
import '../data/database/models/studio_models.dart';
import '../data/external/printer/bambu_printer_models.dart';
import '../data/external/printer/bambu_print_feed.dart';
import '../data/external/printer/bambu_ftp_uploader.dart';
import '../data/external/slicer/slice_isolate_runner.dart';
import 'autoclear_provider.dart';
import 'studio_provider.dart';

/// 打印队列 DAO provider
final printQueueDaoProvider = Provider<PrintQueueDao>((ref) {
  final db = ref.watch(databaseProvider);
  return PrintQueueDao(db);
});

/// 整支舰队中等待人工取件的任务。
///
/// 该流从数据库读取初始快照，因此软件重启或重新进入农场后也不会漏掉
/// 已经处于 waiting_removal 的任务。
final pendingPrintRemovalsProvider =
    StreamProvider<List<PrintQueueItem>>((ref) {
  return ref.watch(printQueueDaoProvider).watchAllWaitingRemovals();
});

/// 无人值守模式设置（全局，持久化）。
/// 开启后队列打完直接发下一个，不弹取件确认。
/// 前提：用户的 G-code 尾部脚本含自动清件动作（挤出机推件）。
class UnattendedModeNotifier extends StateNotifier<bool> {
  UnattendedModeNotifier() : super(false) {
    ready = _load();
  }

  static const _key = 'unattended_mode_enabled';
  late final Future<void> ready;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) state = prefs.getBool(_key) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    await ready;
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
  }
}

final unattendedModeProvider =
    StateNotifierProvider<UnattendedModeNotifier, bool>(
  (ref) => UnattendedModeNotifier(),
);

class PrintQueueEnabledNotifier extends StateNotifier<bool> {
  static const _key = 'print_queue_enabled';
  PrintQueueEnabledNotifier() : super(true) {
    SharedPreferences.getInstance().then(
      (prefs) => state = prefs.getBool(_key) ?? true,
    );
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
  }
}

final printQueueEnabledProvider =
    StateNotifierProvider<PrintQueueEnabledNotifier, bool>(
  (ref) => PrintQueueEnabledNotifier(),
);

/// 指定打印机的队列列表（实时监听）
/// autoDispose：切换打印机后旧队列 Notifier 自动释放，避免多打印机内存线性增长。
/// 修复：原 ref.keepAlive() 无条件调用，完全抵消 autoDispose，所有打印机队列
/// Notifier 永驻内存。移除 keepAlive，让 autoDispose 正常工作；
/// 队列通过 DAO 的 watch 流保持实时，Notifier 销毁后重建会重新订阅，无数据丢失。
final printQueueProvider = StateNotifierProvider.autoDispose
    .family<PrintQueueNotifier, List<PrintQueueItem>, String>(
        (ref, printerSerial) {
  return PrintQueueNotifier(ref, printerSerial);
});

final printBatchQueueItemsProvider = StreamProvider.autoDispose
    .family<List<PrintQueueItem>, String>((ref, batchId) async* {
  final dao = ref.watch(printQueueDaoProvider);
  yield await dao.getByBatchId(batchId);
  await for (final _ in dao.onChange) {
    yield await dao.getByBatchId(batchId);
  }
});

class PrintQueueNotifier extends StateNotifier<List<PrintQueueItem>> {
  final Ref _ref;
  final String _printerSerial;

  /// _tryStartHead 防重入标志。
  /// 多入口（enqueue/confirmRemoval/skipCurrent/_onPrintFinished）并发调用时，
  /// 只允许一个执行，避免同时发送多个打印任务到打印机（7.1 修复）。
  bool _isStartingHead = false;

  PrintQueueNotifier(this._ref, this._printerSerial) : super(const []) {
    _load();
  }

  Future<void> _load() async {
    final items =
        await _ref.read(printQueueDaoProvider).getByPrinter(_printerSerial);
    if (mounted) state = items;
  }

  /// 添加 G-code 到队列末尾
  ///
  /// 入队后异步触发自动清件检测（不阻塞入队流程），
  /// 检测结果存入 [autoclearStateProvider] 供 UI 显示徽章。
  Future<void> enqueue({
    required String gcodePath,
    required String filename,
    bool? autoContinue,
    String? batchId,
    int? batchIndex,
    int? batchTotal,
  }) async {
    await _ref.read(printQueueDaoProvider).enqueue(
          PrintQueueItem(
            printerSerial: _printerSerial,
            gcodePath: gcodePath,
            filename: filename,
            queuedAt: DateTime.now(),
            autoContinue: autoContinue,
            batchId: batchId,
            batchIndex: batchIndex,
            batchTotal: batchTotal,
          ),
        );
    await _load();

    // 异步触发自动清件检测（不阻塞入队流程，大文件扫描 1-2 秒）
    // 忽略错误：检测失败只影响无人值守安全门，不影响入队本身
    unawaited(() async {
      try {
        await _ref.read(autoclearServiceProvider).detectAndCache(gcodePath);
      } catch (e) {
        debugPrint('[PrintQueue] 自动清件检测失败: $e');
      }
    }());

    // 如果队列里没有正在打印的，自动开始队首
    final failure = await _tryStartHead();
    if (failure != null) throw StateError(failure);
  }

  Future<void> enqueueStudioWorkOrder({
    required String workOrderId,
    required String gcodePath,
    required String filename,
    required List<int>? amsMapping,
    String? artifactSha256,
    bool autoContinue = false,
    String? batchId,
    int? batchIndex,
    int? batchTotal,
  }) async {
    final dao = _ref.read(printQueueDaoProvider);
    final existing = await dao.getByStudioWorkOrderId(workOrderId);
    if (existing != null && existing.status != PrintQueueStatus.cancelled) {
      throw StateError('该工单已经在打印队列中');
    }
    await dao.enqueue(
      PrintQueueItem(
        printerSerial: _printerSerial,
        gcodePath: gcodePath,
        filename: filename,
        queuedAt: DateTime.now(),
        artifactSha256: artifactSha256,
        amsMapping: amsMapping,
        studioWorkOrderId: workOrderId,
        autoContinue: autoContinue,
        batchId: batchId,
        batchIndex: batchIndex,
        batchTotal: batchTotal,
      ),
    );
    await _ref.read(studioDaoProvider).updateWorkOrderQueueStatus(
          workOrderId,
          StudioWorkOrderStatus.assigned,
        );
    await _load();
    unawaited(() async {
      try {
        await _ref.read(autoclearServiceProvider).detectAndCache(gcodePath);
      } catch (error) {
        debugPrint('[PrintQueue] 农场工单自动清件检测失败: $error');
      }
    }());
    final failure = await _tryStartHead();
    if (failure != null) throw StateError(failure);
  }

  Future<void> enqueueExperiment(ExperimentQueueCheck check) async {
    if (check.printerSerial != _printerSerial) {
      throw StateError('实验检查的打印机与当前队列不一致');
    }
    await _ref.read(experimentServiceProvider).enqueueRun(check);
    await _load();
    unawaited(() async {
      try {
        await _ref
            .read(autoclearServiceProvider)
            .detectAndCache(check.filePath);
      } catch (error) {
        debugPrint('[PrintQueue] 实验文件自动清件检测失败: $error');
      }
    }());
    final failure = await _tryStartHead();
    if (failure != null) throw StateError(failure);
  }

  /// 尝试发送队首任务到打印机
  /// 仅当：没有正在打印的 + 没有等待取件的
  ///
  /// 无人值守安全门：队首 G-code 必须通过自动清件检测（或手动标记为含），
  /// 否则不发送，避免喷嘴撞到上一个打印件。
  Future<String?> _tryStartHead() async {
    if (!_ref.read(printQueueEnabledProvider)) return null;
    // 7.1 修复：防重入。多入口并发调用时只允许一个执行，
    // 避免同时发送多个打印任务到打印机。
    if (_isStartingHead) return null;
    _isStartingHead = true;
    try {
      final dao = _ref.read(printQueueDaoProvider);
      final printing = await dao.getPrinting(_printerSerial);
      if (printing != null) return null; // 已有打印中
      final waiting = await dao.getWaitingRemoval(_printerSerial);
      if (waiting != null) return null; // 有等待取件的

      final head = await dao.getHead(_printerSerial);
      if (head == null) return null; // 队列空

      final expectedHash = head.artifactSha256;
      if (expectedHash != null) {
        final current =
            await SliceArtifactHashService.computeStable(head.gcodePath);
        if (current == null || current.sha256Hex != expectedHash) {
          const reason = '打印文件在入队后发生变化，已阻止发送';
          await _failSafetyCheck(dao, head, reason);
          return reason;
        }
      }

      // 连接并校验这台任务所属打印机自己的舰队状态。
      final fleetManager =
          _ref.read(printerFleetConnectionManagerProvider.notifier);
      const config = SchedulingConfig.defaults;
      final fleetState = await fleetManager.ensureFreshStatus(
        _printerSerial,
        config,
      );
      if (fleetState == null || !fleetState.canAutoDispatch(config)) {
        debugPrint('[PrintQueue] $_printerSerial 无可用的新鲜 LAN 状态，跳过自动发送');
        return null;
      }

      // 所有队列入口都必须在真正发送前从文件本身复核精确机型和喷嘴。
      // 调度器或 UI 先前做过的检查不能替代此处，因为文件可能被替换，
      // 普通手动入队过去也没有任何设备兼容性硬门。
      final requestedPlateIndex = head.studioWorkOrderId == null
          ? 1
          : await _ref
                  .read(studioDaoProvider)
                  .getWorkOrderPlateIndex(head.studioWorkOrderId!) ??
              1;
      String gcodeParam;
      try {
        gcodeParam = head.gcodePath.toLowerCase().endsWith('.3mf')
            ? await BambuGcodePathResolver.resolveFrom3mf(head.gcodePath,
                plateIndex: requestedPlateIndex)
            : '';
      } on FormatException catch (error) {
        final reason = error.message;
        await _failSafetyCheck(dao, head, reason);
        return reason;
      }
      final plateIndex = int.tryParse(
              RegExp(r'plate_(\d+)\.gcode').firstMatch(gcodeParam)?.group(1) ??
                  '') ??
          requestedPlateIndex;
      final slice = await SliceIsolateRunner.parseAuto(head.gcodePath,
          plateIndex: plateIndex);
      if (slice == null) {
        const reason = '无法解析打印文件，已阻止发送';
        await _failSafetyCheck(dao, head, reason);
        return reason;
      }
      final targetModel = slice.printerSettingsId?.trim() ?? '';
      final targetNozzle = slice.nozzleDiameter;
      final hasExactTarget = targetModel.isNotEmpty &&
          PrinterModelNormalizer.isKnownBambuModel(targetModel) &&
          targetNozzle != null &&
          targetNozzle > 0;
      final mismatch = fleetState.targetSpecMismatch(
        hasExactTarget
            ? PrinterModelSpec(
                canonicalModel: PrinterModelNormalizer.normalize(targetModel),
                nozzleDiameter: targetNozzle,
                plateType: slice.plateType,
                rawModel: targetModel,
              )
            : null,
      );
      if (mismatch != null) {
        await _failSafetyCheck(dao, head, mismatch);
        return mismatch;
      }

      // A queue row can sit behind another print for hours.  Re-check the
      // physical AMS layout at the moment it is sent so an unplugged unit or
      // a changed multi-AMS topology cannot receive a stale tray index.
      final amsMapping = head.amsMapping ?? slice.amsMapping;
      final mappingError = validateBambuPrintFeed(
        model: fleetState.reportedModel ?? '',
        mapping: amsMapping ?? const [],
        activeTools: slice.filaments
            .where((item) => item.grams > .01)
            .map((item) => item.toolIndex),
        status: fleetState.lastStatus!,
        toolExtruders: await readBambuToolExtruders(head.gcodePath,
            plateIndex: plateIndex),
      );
      if (mappingError != null) {
        await _failSafetyCheck(dao, head, mappingError);
        return mappingError;
      }

      // 无人值守安全门：检测队首 G-code 是否含自动清件脚本
      final unattended = head.effectiveAutoContinue(
        _ref.read(unattendedModeProvider),
      );
      if (unattended) {
        final autoclearService = _ref.read(autoclearServiceProvider);
        bool? flag = autoclearService.getFinalFlagSync(head.gcodePath);
        if (flag == null) {
          // state 尚未加载或未检测，触发一次同步检测等待结果
          final entry = await autoclearService.detectAndCache(head.gcodePath);
          flag = entry.finalFlag;
        }
        if (flag != true) {
          // 未检测到自动清件脚本 → 阻塞，弹通知
          debugPrint('[PrintQueue] 队首 ${head.filename} 未检测到自动清件脚本，'
              '无人值守模式已暂停');
          try {
            _ref.read(notificationServiceProvider).alert(
                  type: AlertType.unattendedBlocked,
                  title: '无人值守模式已暂停',
                  body: '队首「${head.filename}」未检测到自动清件脚本。'
                      '请：① 在队列中手动标记为含 ② 跳过此任务 ③ 关闭无人值守模式',
                );
          } catch (e) {
            debugPrint('[PrintQueue] 通知发送失败: $e');
          }
          return null;
        }
      }

      final ok = await fleetManager.sendPrintTask(
        _printerSerial,
        head.gcodePath,
        amsMapping: amsMapping,
        plateIndex: plateIndex,
      );
      if (ok) {
        await dao.setStatus(
          head.id!,
          PrintQueueStatus.printing,
          startedAt: DateTime.now(),
        );
        await _ref
            .read(experimentServiceProvider)
            .markQueueRunStatus(head, RunStatus.printing);
        if (head.studioWorkOrderId case final workOrderId?) {
          await _ref.read(studioDaoProvider).updateWorkOrderQueueStatus(
                workOrderId,
                StudioWorkOrderStatus.printing,
              );
        }
        await _load();
      } else {
        debugPrint('[PrintQueue] 队首任务发送失败: ${head.filename}');
        const reason = '打印机未确认接收任务，已停止自动重试；请检查设备与连接后再发送';
        await _failSafetyCheck(dao, head, reason);
        return reason;
      }
      return null;
    } catch (error, stackTrace) {
      ErrorLogger.log(
        error,
        stackTrace,
        source: 'print_queue',
        context: {
          'phase': 'start_head',
          'printerSerial': _printerSerial,
        },
      );
      return '发布打印未完成：$error';
    } finally {
      _isStartingHead = false;
    }
  }

  Future<void> _failSafetyCheck(
    PrintQueueDao dao,
    PrintQueueItem item,
    String reason,
  ) async {
    await dao.setStatus(
      item.id!,
      PrintQueueStatus.failed,
      completedAt: DateTime.now(),
    );
    await _ref
        .read(experimentServiceProvider)
        .markQueueRunStatus(item, RunStatus.failed);
    if (item.studioWorkOrderId case final workOrderId?) {
      await _ref.read(studioDaoProvider).updateWorkOrderQueueStatus(
            workOrderId,
            StudioWorkOrderStatus.failed,
          );
    }
    await _load();
    ErrorLogger.log(
      StateError(reason),
      StackTrace.current,
      source: 'print_queue',
      level: ErrorLevel.warning,
      context: {
        'phase': 'preflight_rejected',
        'queueId': item.id,
        'filename': item.filename,
        'printerSerial': item.printerSerial,
      },
    );
    try {
      _ref.read(notificationServiceProvider).alert(
            type: AlertType.printFailed,
            title: '打印队列安全检查未通过',
            body: '${item.filename}：$reason',
          );
    } catch (error) {
      debugPrint('[PrintQueue] 安全检查通知发送失败: $error');
    }
  }

  /// 用户确认取件完成 → 推进到下一个
  Future<void> confirmRemoval({int? expectedQueueItemId}) async {
    final dao = _ref.read(printQueueDaoProvider);
    final waiting = await dao.getWaitingRemoval(_printerSerial);
    if (waiting?.id == null) return;
    if (expectedQueueItemId != null && waiting!.id != expectedQueueItemId) {
      throw StateError('等待取件任务已经变化，请核对当前打印机状态');
    }
    await dao.setStatus(
      waiting!.id!,
      PrintQueueStatus.completed,
      completedAt: DateTime.now(),
    );
    await _load();
    // 自动开始下一个
    await _tryStartHead();
  }

  /// Retries a failed farm print after rechecking that the assigned roll can
  /// still cover one complete run. The failed attempt's loss remains charged.
  Future<void> retryFailed(int id) async {
    final item = state.cast<PrintQueueItem?>().firstWhere(
          (candidate) => candidate?.id == id,
          orElse: () => null,
        );
    if (item == null || item.status != PrintQueueStatus.failed) {
      throw StateError('只有失败的队列任务可以重试');
    }
    final workOrderId = item.studioWorkOrderId;
    if (workOrderId == null) {
      throw StateError('当前只支持重试关联农场工单的失败任务');
    }
    final studioDao = _ref.read(studioDaoProvider);
    await studioDao.validateWorkOrderRetry(workOrderId);
    await _ref.read(printQueueDaoProvider).retryFailed(id);
    await studioDao.updateWorkOrderQueueStatus(
      workOrderId,
      StudioWorkOrderStatus.assigned,
    );
    await _ref
        .read(experimentServiceProvider)
        .markQueueRunStatus(item, RunStatus.queued);
    await _load();
    final failure = await _tryStartHead();
    if (failure != null) throw StateError(failure);
  }

  Future<bool> rejectCompletedFarmPrint({
    required int queueItemId,
    required String workOrderId,
    String reason = '成品质检不合格',
  }) async {
    final item = state.cast<PrintQueueItem?>().firstWhere(
          (candidate) => candidate?.id == queueItemId,
          orElse: () => null,
        );
    if (item == null ||
        (item.status != PrintQueueStatus.waitingRemoval &&
            item.status != PrintQueueStatus.completed)) {
      throw StateError('没有找到已经完成的打印记录');
    }
    final reserved =
        await _ref.read(studioDaoProvider).rejectCompletedWorkOrderForQuality(
              id: workOrderId,
              printQueueId: queueItemId,
              attemptNo: item.attemptNo,
              reason: reason,
            );
    await _ref.read(printQueueDaoProvider).markQualityRejected(queueItemId);
    await _load();
    return reserved;
  }

  /// 取消指定队列项
  Future<void> cancel(int id) async {
    final item = state.cast<PrintQueueItem?>().firstWhere(
          (candidate) => candidate?.id == id,
          orElse: () => null,
        );
    if (item == null) return;
    if (item.status != PrintQueueStatus.queued) {
      throw StateError('只有排队中的任务可以取消');
    }
    await _ref
        .read(printQueueDaoProvider)
        .setStatus(id, PrintQueueStatus.cancelled);
    await _ref
        .read(experimentServiceProvider)
        .markQueueRunStatus(item, RunStatus.cancelled);
    if (item.studioWorkOrderId case final workOrderId?) {
      await _ref.read(studioDaoProvider).updateWorkOrderQueueStatus(
            workOrderId,
            StudioWorkOrderStatus.queued,
          );
    }
    await _load();
    await _tryStartHead();
  }

  /// 跳过队首尚未发送的任务，推进到下一个。
  /// 正在打印的任务必须先向设备发送 stop，不能只改本地状态。
  Future<void> skipCurrent() async {
    final skipped =
        await _ref.read(printQueueDaoProvider).skipCurrent(_printerSerial);
    if (skipped != null) {
      await _ref
          .read(experimentServiceProvider)
          .markQueueRunStatus(skipped, RunStatus.cancelled);
      if (skipped.studioWorkOrderId case final workOrderId?) {
        await _ref.read(studioDaoProvider).updateWorkOrderQueueStatus(
              workOrderId,
              StudioWorkOrderStatus.queued,
            );
      }
    }
    await _load();
    await _tryStartHead();
  }

  /// 删除队列项（仅 queued/cancelled 可删除）
  Future<void> delete(int id) async {
    final item = state.cast<PrintQueueItem?>().firstWhere(
          (candidate) => candidate?.id == id,
          orElse: () => null,
        );
    if (item == null) return;
    final canDelete = item.status == PrintQueueStatus.queued ||
        item.status == PrintQueueStatus.cancelled ||
        item.status == PrintQueueStatus.completed ||
        item.status == PrintQueueStatus.failed;
    if (!canDelete) {
      throw StateError('打印中或等待取件的任务不能删除');
    }
    if (!item.status.isTerminal) {
      await _ref
          .read(experimentServiceProvider)
          .markQueueRunStatus(item, RunStatus.cancelled);
    }
    await _ref.read(printQueueDaoProvider).delete(id);
    await _load();
    await _tryStartHead();
  }

  /// 重新排序
  Future<void> reorder(List<int> orderedIds) async {
    await _ref.read(printQueueDaoProvider).reorder(orderedIds);
    await _load();
  }

  /// 清理已完成/已取消
  Future<void> clearFinished() async {
    await _ref.read(printQueueDaoProvider).clearFinished(_printerSerial);
    await _load();
  }

  /// 刷新列表
  Future<void> refresh() async => _load();

  /// 调度器直接写入队列后，显式尝试启动队首。
  Future<String?> startIfIdle() async {
    await _load();
    return _tryStartHead();
  }

  /// A farm dispatch transaction inserted all rows directly. Refresh only
  /// after commit, warm the safety cache, then allow one queue head to start.
  Future<String?> activateCommittedStudioDispatch(
    Iterable<String> artifactPaths,
  ) async {
    await _load();
    for (final path in artifactPaths.toSet()) {
      unawaited(() async {
        try {
          await _ref.read(autoclearServiceProvider).detectAndCache(path);
        } catch (error) {
          debugPrint('[PrintQueue] 农场工单自动清件检测失败: $error');
        }
      }());
    }
    return _tryStartHead();
  }
}

/// 队列状态机服务：监听整支舰队状态，按 serial 驱动各自队列推进。
///
/// 当 gcodeState 从 running 变为 finish 时：
/// - 找到该打印机的 printing 队列项
/// - 先完成关联农场工单并结算耗材
/// - 无人值守模式：直接 completed + 发下一个
/// - 手动模式：改为 waiting_removal；取件确认只负责发下一个
final printQueueStateMachineProvider = Provider<void>((ref) {
  ref.listen<Map<String, FleetPrinterState>>(
      printerFleetConnectionManagerProvider, (previous, next) {
    if (!ref.read(printQueueEnabledProvider)) return;
    for (final entry in next.entries) {
      final serial = entry.key;
      const config = SchedulingConfig.defaults;
      final wasDispatchable =
          previous?[serial]?.canAutoDispatch(config) ?? false;
      final isDispatchable = entry.value.canAutoDispatch(config);
      if (!wasDispatchable && isDispatchable) {
        unawaited(
          ref.read(printQueueProvider(serial).notifier).startIfIdle(),
        );
      }
      final prevState = previous?[serial]?.lastStatus?.gcodeState;
      final currentStatus = entry.value.lastStatus;
      final currState = currentStatus?.gcodeState;
      if (previous?[serial]?.lastStatus == null) {
        unawaited(_reconcileRecoveredQueue(ref, serial, currentStatus));
        continue;
      }
      final wasActive = prevState == BambuGcodeState.running ||
          prevState == BambuGcodeState.pause ||
          prevState == BambuGcodeState.init ||
          prevState == BambuGcodeState.prepare;
      if (!wasActive) continue;
      if (currState == BambuGcodeState.finish) {
        unawaited(_onPrintFinished(ref, serial));
      } else if (currState == BambuGcodeState.failed) {
        unawaited(
          _onPrintFailed(
            ref,
            serial,
            status: currentStatus,
          ),
        );
      } else if (currState == BambuGcodeState.idle) {
        unawaited(
          _onPrintFailed(
            ref,
            serial,
            status: currentStatus,
            outcome: StudioPrintAttemptOutcome.stopped,
          ),
        );
      }
    }
  });
});

Future<void> _reconcileRecoveredQueue(
  Ref ref,
  String printerSerial,
  BambuPrinterStatus? status,
) async {
  if (status?.gcodeState == BambuGcodeState.idle) {
    // Connectors can briefly publish a synthetic idle snapshot before the
    // printer's real push arrives. Give that push a short grace period so a
    // still-running job is not mistaken for an offline interruption.
    final ready = Completer<void>();
    var cancelled = false;
    final timer = Timer(const Duration(seconds: 2), ready.complete);
    ref.onDispose(() {
      cancelled = true;
      timer.cancel();
      if (!ready.isCompleted) ready.complete();
    });
    await ready.future;
    if (cancelled) return;
    status = ref
        .read(printerFleetConnectionManagerProvider)[printerSerial]
        ?.lastStatus;
  }
  final printing =
      await ref.read(printQueueDaoProvider).getPrinting(printerSerial);
  if (printing == null) return;
  switch (status?.gcodeState) {
    case BambuGcodeState.finish:
      await _onPrintFinished(ref, printerSerial);
      return;
    case BambuGcodeState.failed:
      await _onPrintFailed(ref, printerSerial, status: status);
      return;
    case BambuGcodeState.idle:
      if ((status?.mcPercent ?? 0) >= 99) {
        await _onPrintFinished(ref, printerSerial);
      } else {
        await _onPrintFailed(
          ref,
          printerSerial,
          status: status,
          outcome: StudioPrintAttemptOutcome.stopped,
          recoveredAfterDisconnect: true,
        );
      }
      return;
    case _:
      return;
  }
}

Future<void> _onPrintFinished(Ref ref, String printerSerial) async {
  try {
    final dao = ref.read(printQueueDaoProvider);
    final printing = await dao.getPrinting(printerSerial);
    if (printing == null || printing.id == null) return; // 不在队列管理中

    final unattended = printing.effectiveAutoContinue(
      ref.read(unattendedModeProvider),
    );
    await ref
        .read(experimentServiceProvider)
        .markQueueRunStatus(printing, RunStatus.completed);

    // 农场订单以打印机上报 finish 为唯一完成事实。取件确认只控制
    // 下一项能否启动，不再影响订单完成度或耗材成本结算。
    var accountingReview = false;
    String? accountingError;
    if (printing.studioWorkOrderId case final workOrderId?) {
      final studioDao = ref.read(studioDaoProvider);
      try {
        await studioDao.completeWorkOrderUsingEstimate(workOrderId);
      } catch (error, stackTrace) {
        accountingReview = true;
        accountingError = '$error';
        ErrorLogger.log(
          error,
          stackTrace,
          source: 'print_queue',
          level: ErrorLevel.warning,
          context: {
            'phase': 'complete_farm_accounting',
            'queueId': printing.id,
            'workOrderId': workOrderId,
          },
        );
        await studioDao.forceCompleteWorkOrderForAccountingReview(
          workOrderId,
          reason: accountingError,
        );
      }
      try {
        await studioDao.recordCompletedWorkOrderAttempt(
          id: workOrderId,
          printQueueId: printing.id!,
          attemptNo: printing.attemptNo,
          printerSerial: printerSerial,
          startedAt: printing.startedAt,
          outcome: accountingReview
              ? StudioPrintAttemptOutcome.accountingReview
              : StudioPrintAttemptOutcome.completed,
          reason: accountingError,
        );
      } catch (error, stackTrace) {
        ErrorLogger.log(
          error,
          stackTrace,
          source: 'print_queue',
          context: {
            'phase': 'record_completed_farm_attempt',
            'queueId': printing.id,
            'workOrderId': workOrderId,
          },
        );
      }
    }

    if (unattended) {
      // 无人值守模式：直接完成 + 发下一个
      await dao.setStatus(
        printing.id!,
        PrintQueueStatus.completed,
        completedAt: DateTime.now(),
      );
      ref.read(printQueueProvider(printerSerial).notifier).refresh();
      // 自动开始下一个
      await ref
          .read(printQueueProvider(printerSerial).notifier)
          ._tryStartHead();
    } else {
      // 手动模式：等待取件
      await dao.setStatus(printing.id!, PrintQueueStatus.waitingRemoval);
      ref.read(printQueueProvider(printerSerial).notifier).refresh();
      // 弹通知
      try {
        ref.read(notificationServiceProvider).alert(
              type: AlertType.printFinished,
              title: accountingReview ? '打印完成，成本待核对' : '打印完成，请取件',
              body: accountingReview
                  ? '${printing.filename} 已按完成处理，但耗材账目需要核对。取件后可继续下一项。'
                  : '${printing.filename} 已打完。取件后在队列中点「已取件」继续下一个。',
            );
      } catch (e) {
        debugPrint('[PrintQueue] 通知发送失败: $e');
      }
    }
  } catch (e, st) {
    // 架构修复：async void 改为 Future<void> + try/catch，
    // 防止队列推进异常无法传播导致队列卡死。
    debugPrint('[PrintQueue] _onPrintFinished 异常: $e\n$st');
  }
}

Future<void> _onPrintFailed(
  Ref ref,
  String printerSerial, {
  BambuPrinterStatus? status,
  StudioPrintAttemptOutcome outcome = StudioPrintAttemptOutcome.failed,
  bool recoveredAfterDisconnect = false,
}) async {
  try {
    final dao = ref.read(printQueueDaoProvider);
    final printing = await dao.getPrinting(printerSerial);
    if (printing == null || printing.id == null) return;
    double? recordedLoss;
    final hasReliableProgress =
        status?.mcPercent != null || recoveredAfterDisconnect;
    if (printing.studioWorkOrderId case final workOrderId?) {
      try {
        recordedLoss = await ref
            .read(studioDaoProvider)
            .recordFailedWorkOrderAttemptUsingEstimate(
              id: workOrderId,
              printQueueId: printing.id!,
              attemptNo: printing.attemptNo,
              progressPercent:
                  status?.mcPercent ?? (recoveredAfterDisconnect ? 0 : null),
              printerSerial: printerSerial,
              startedAt: printing.startedAt,
              failureReason: status?.failReason,
              errorCode: status?.printError,
              outcome: outcome,
            );
      } catch (error, stackTrace) {
        ErrorLogger.log(
          error,
          stackTrace,
          source: 'print_queue',
          context: {
            'phase': 'record_farm_print_loss',
            'queueId': printing.id,
            'workOrderId': workOrderId,
          },
        );
        await ref.read(studioDaoProvider).updateWorkOrderQueueStatus(
              workOrderId,
              StudioWorkOrderStatus.failed,
            );
      }
    }
    // Publish the queue failure only after the farm loss ledger has been
    // written, so a fast retry cannot race ahead of the accounting update.
    await dao.setStatus(
      printing.id!,
      PrintQueueStatus.failed,
      completedAt: DateTime.now(),
    );
    await ref
        .read(experimentServiceProvider)
        .markQueueRunStatus(printing, RunStatus.failed);
    await ref.read(printQueueProvider(printerSerial).notifier).refresh();
    try {
      ref.read(notificationServiceProvider).alert(
            type: AlertType.printFailed,
            title: recoveredAfterDisconnect
                ? '离线任务状态已对账'
                : outcome == StudioPrintAttemptOutcome.stopped
                    ? '打印已中止'
                    : '队列任务打印失败',
            body: recordedLoss == null
                ? '${printing.filename} 未正常完成，队列已暂停，请核对成品后重试。'
                : !hasReliableProgress
                    ? '${printing.filename} 未正常完成，但设备没有提供可靠进度；未自动扣除损耗，请先人工核对账目再重试。'
                    : '${printing.filename} 未正常完成，已按进度计入约 '
                        '${recordedLoss.toStringAsFixed(1)}g 损耗；处理故障并确认耗材充足后可重试。',
          );
    } catch (e) {
      debugPrint('[PrintQueue] 失败通知发送失败: $e');
    }
  } catch (e, st) {
    debugPrint('[PrintQueue] _onPrintFailed 异常: $e\n$st');
  }
}
