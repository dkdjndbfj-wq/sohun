// 批次识别服务。
//
// 当多台打印机在可配置时间窗口内（默认 10 分钟）打同一文件名时，归为同一批次（batch_id）。
// 用于：耗材成本合并核算、进度统一卡、批次异常对比。
//
// 识别方式：监听打印任务 DAO 的变更，覆盖当前设备与后台舰队设备；查询窗口时间内
// 其他打印机的同文件名任务，若存在则复用其 batch_id，否则生成新 batch_id。
//
// SQL 匹配收紧（v2 修复）：
// - 旧版：`task_name = ? OR gcode_path LIKE ?` 双条件 OR，basename 在 task_name 中
//   是子串时也会命中，可能导致不同模型同 basename 误判为同批次。
// - 新版：精确匹配 `task_name = ?`（basename 完全相同）。
//   路径 basename 在 Dart 中精确比较，避免 `%`、`_` 被 SQL LIKE 当作通配符。
//
// 异常对比：监听所有打印任务终态变化，当批次内出现失败任务时，
// 检查同批次其他任务状态，若有成功的则推送"批次异常对比"通知，
// 提示用户失败原因大概率是机器问题而非模型问题。
//
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/error_logger.dart';
import '../core/services/notification_service.dart';
import 'database_provider.dart';
import 'print_task_provider.dart';

/// 批次识别窗口持久化 key（分钟数）。
/// 用户可在设置页调整，默认 10 分钟。
const _kBatchWindowMinutesKey = 'batch_recognition_window_minutes';

/// 默认批次识别窗口（分钟）。
const _kDefaultBatchWindowMinutes = 10;

/// 批次识别总开关持久化 key。
const _kBatchEnabledKey = 'batch_recognition_enabled';

/// 批次识别总开关 Provider（持久化，默认开启）。
///
/// 修复：设置页原有「批次识别」开关只写 prefs、无人读取，导致关掉后功能照跑。
/// 现由 [batchRecognitionProvider] watch 本 provider，关闭后不再注册监听。
///
/// 默认值取 true 而非 false：接通开关前该功能是无条件启用的，
/// 若默认 false 会让存量用户升级后功能静默消失。
class BatchRecognitionEnabledNotifier extends StateNotifier<bool> {
  BatchRecognitionEnabledNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_kBatchEnabledKey) ?? true;
    if (mounted) state = v;
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBatchEnabledKey, value);
    if (mounted) state = value;
  }
}

final batchRecognitionEnabledProvider =
    StateNotifierProvider<BatchRecognitionEnabledNotifier, bool>((ref) {
  return BatchRecognitionEnabledNotifier();
});

/// 读取批次识别窗口（分钟）。
Future<int> getBatchWindowMinutes() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getInt(_kBatchWindowMinutesKey) ?? _kDefaultBatchWindowMinutes;
}

/// 设置批次识别窗口（分钟）。
/// 限制范围 [1, 60]，避免极端值导致识别失效。
Future<void> setBatchWindowMinutes(int minutes) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_kBatchWindowMinutesKey, minutes.clamp(1, 60));
}

/// 批次识别服务 provider
final batchRecognitionProvider = Provider<void>((ref) {
  // 总开关关闭时不注册监听，功能真正停用。
  if (!ref.watch(batchRecognitionEnabledProvider)) return;
  final runtime = _BatchRecognitionRuntime(ref);
  runtime.start();
  ref.onDispose(runtime.dispose);
});

class _BatchRecognitionRuntime {
  _BatchRecognitionRuntime(this.ref);

  final Ref ref;
  final Set<int> _seenTerminalTaskIds = {};
  StreamSubscription<void>? _subscription;
  Future<void> _operation = Future<void>.value();
  bool _terminalBaselineLoaded = false;
  bool _disposed = false;

  void start() {
    _subscription = ref.read(printTaskDaoProvider).onChange.listen((_) {
      _requestSync();
    });
    _requestSync();
  }

  void _requestSync() {
    if (_disposed) return;
    _operation = _operation.then((_) async {
      if (_disposed) return;
      await _recognizeUnbatchedTasks(ref);
      await _checkNewTerminalBatchAnomalies();
    }).catchError((Object error, StackTrace stackTrace) {
      ErrorLogger.log(
        error,
        stackTrace,
        source: 'batch_recognition',
        level: ErrorLevel.warning,
      );
    });
  }

  Future<void> _checkNewTerminalBatchAnomalies() async {
    final db = ref.read(databaseProvider);
    final rows = await db
        .customSelect(
          "SELECT id FROM print_tasks WHERE batch_id IS NOT NULL "
          "AND status IN ('failed', 'cancelled')",
        )
        .get();
    final terminalIds =
        rows.map((row) => row.data['id'] as int?).whereType<int>().toSet();
    if (!_terminalBaselineLoaded) {
      _seenTerminalTaskIds.addAll(terminalIds);
      _terminalBaselineLoaded = true;
      return;
    }
    for (final taskId in terminalIds.difference(_seenTerminalTaskIds)) {
      await _checkBatchAnomaly(ref, taskId);
    }
    _seenTerminalTaskIds.addAll(terminalIds);
  }

  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}

/// 检查批次异常对比。
///
/// 逻辑：查同批次其他任务，若有成功的则推送"批次异常对比"通知。
/// 去重：每个 batch_id 只推送一次异常对比通知。
final Set<String> _batchAnomalyAlerted = {};

Future<void> _checkBatchAnomaly(Ref ref, int taskId) async {
  try {
    final db = ref.read(databaseProvider);
    final row = await db.customSelect(
      'SELECT batch_id, task_name FROM print_tasks WHERE id = ? '
      "AND status IN ('failed', 'cancelled')",
      variables: [Variable<int>(taskId)],
    ).getSingleOrNull();
    if (row == null) return;
    final batchId = row.data['batch_id'] as String?;
    if (batchId == null || batchId.isEmpty) return;
    final taskName = row.data['task_name'] as String? ?? '打印任务';

    // 去重：同批次已推送过则跳过
    if (_batchAnomalyAlerted.contains(batchId)) return;

    // 查同批次其他任务的状态
    final rows = await db.customSelect(
      'SELECT status FROM print_tasks WHERE batch_id = ? AND id != ?',
      variables: [Variable<String>(batchId), Variable<int>(taskId)],
    ).get();

    if (rows.isEmpty) return; // 批次只有这一台，不算批次

    int successCount = 0;
    for (final r in rows) {
      final status = r.data['status'] as String? ?? '';
      if (status == 'finished') {
        successCount++;
      }
    }

    // 有成功的同批次任务 → 推送异常对比通知
    if (successCount > 0) {
      _batchAnomalyAlerted.add(batchId);
      ref.read(notificationServiceProvider).alert(
            type: AlertType.batchAnomaly,
            title: '批次异常对比',
            body: '「$taskName」失败，但同批次 $successCount 台成功。'
                '失败原因大概率是机器问题（堵头/翘边/耗材受潮），建议检查此台耗材和喷嘴。',
          );
      debugPrint('[BatchAnomaly] 批次 $batchId 推送异常对比通知 '
          '($successCount 台成功，本任务失败)');
    }
  } catch (e, st) {
    ErrorLogger.log(
      e,
      st,
      source: 'batch_anomaly',
      level: ErrorLevel.warning,
      context: {'task_id': taskId},
    );
  }
}

Future<void> _recognizeUnbatchedTasks(Ref ref) async {
  final db = ref.read(databaseProvider);
  final rows = await db
      .customSelect(
        'SELECT pt.gcode_path, pt.task_name, p.serial '
        'FROM print_tasks pt '
        'LEFT JOIN printers p ON p.id = pt.printer_id '
        'WHERE pt.batch_id IS NULL AND pt.started_at IS NOT NULL '
        "AND pt.status IN ('printing', 'paused') "
        'ORDER BY pt.started_at ASC',
      )
      .get();
  for (final row in rows) {
    final gcodePath = row.data['gcode_path'] as String? ?? '';
    final taskName = row.data['task_name'] as String? ?? '';
    final identity = gcodePath.isNotEmpty ? gcodePath : taskName;
    if (identity.isEmpty) continue;
    await _recognizeBatch(
      ref,
      row.data['serial'] as String? ?? 'unknown',
      identity,
    );
  }
}

/// 识别批次：查询窗口时间内同文件名的其他打印机任务
///
/// v3：
/// 1. 窗口时长从 SharedPreferences 读取（默认 10 分钟，用户可配置）
/// 2. 路径和任务名都在 Dart 中做 basename 精确匹配，不使用 SQL LIKE 通配符
/// 3. SELECT + UPDATE 包在事务中，防止两台打印机同时识别时分配不同 batch_id
/// 4. 状态包含 printing 和 paused（暂停的任务仍属于活跃批次）
Future<void> _recognizeBatch(
  Ref ref,
  String printerSerial,
  String gcodeFile,
) async {
  try {
    final db = ref.read(databaseProvider);
    final basename = gcodeFile.split(RegExp(r'[/\\]')).last;
    // 读取用户配置的窗口时长
    final windowMinutes = await getBatchWindowMinutes();
    final windowStart = DateTime.now()
        .subtract(Duration(minutes: windowMinutes))
        .millisecondsSinceEpoch;

    final batchId = await db.transaction(() async {
      final rows = await db.customSelect(
        'SELECT id, batch_id, task_name, gcode_path FROM print_tasks '
        'WHERE started_at IS NOT NULL '
        "AND started_at >= ? AND status IN ('printing', 'paused') "
        'ORDER BY started_at ASC',
        variables: [Variable<int>(windowStart)],
      ).get();

      final matches = rows.where((row) {
        final taskName = row.data['task_name'] as String? ?? '';
        final path = row.data['gcode_path'] as String? ?? '';
        final pathBasename = path.split(RegExp(r'[/\\]')).last;
        return taskName == basename || pathBasename == basename;
      }).toList(growable: false);
      if (matches.isEmpty) return _generateBatchId();

      String? existingBatchId;
      for (final row in matches) {
        final value = row.data['batch_id'] as String?;
        if (value != null && value.isNotEmpty) {
          existingBatchId = value;
          break;
        }
      }
      final batchId = existingBatchId ?? _generateBatchId();
      final ids = matches.map((row) => row.data['id'] as int).toList();
      final placeholders = List.filled(ids.length, '?').join(', ');
      await db.customStatement(
        'UPDATE print_tasks SET batch_id = ? WHERE id IN ($placeholders)',
        [batchId, ...ids],
      );
      return batchId;
    });

    debugPrint(
      '[BatchRecognition] $basename → 批次 $batchId (打印机 $printerSerial, 窗口 ${windowMinutes}min)',
    );
  } catch (e) {
    debugPrint('[BatchRecognition] 识别失败: $e');
  }
}

String _generateBatchId() {
  final now = DateTime.now();
  return 'B${now.millisecondsSinceEpoch}';
}

/// 获取指定批次的所有任务（用于耗材合并 + 进度卡 + 异常对比）
final batchTasksProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
        (ref, batchId) async {
  final db = ref.watch(databaseProvider);
  final rows = await db.customSelect(
    'SELECT * FROM print_tasks WHERE batch_id = ? ORDER BY started_at ASC',
    variables: [Variable<String>(batchId)],
  ).get();
  return rows.map((r) => r.data).toList();
});

/// 获取所有批次列表（最近 50 个）
///
/// 返回字段：batch_id, count（台数）, first_started, last_finished,
/// task_name, success_count, fail_count, total_grams（总消耗克数）,
/// total_cost（总成本）, is_multi_color（是否多色任务）, color_count（颜色数）
final recentBatchesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseProvider);
  // 注意：LEFT JOIN print_task_consumables 会让多色任务产生多行。
  // count/success_count/fail_count 必须用 COUNT(DISTINCT pt.id) 避免放大。
  // 多色检测：取批次内任一任务的 per_filament_grams 数组长度最大值。
  //   per_filament_grams 存储为 JSON 数组文本（如 "[20.5,10.2]"），
  //   用 length() - length(replace(...)) 数逗号法估算数组长度，
  //   逗号数 + 1 = 元素数（空数组 "" / null 视为单色 1）。
  final rows = await db
      .customSelect(
        'SELECT pt.batch_id as batch_id, '
        'COUNT(DISTINCT pt.id) as count, '
        'MIN(pt.started_at) as first_started, '
        'MAX(pt.finished_at) as last_finished, '
        'MIN(pt.task_name) as task_name, '
        'COUNT(DISTINCT CASE WHEN pt.status = "finished" THEN pt.id END) as success_count, '
        'COUNT(DISTINCT CASE WHEN pt.status = "failed" THEN pt.id END) as fail_count, '
        'COALESCE(SUM(ptc.consumed_grams), 0) as total_grams, '
        'COALESCE(SUM(ptc.consumed_grams * ptc.cost_per_kg_snapshot / 1000), 0) as total_cost, '
        'MAX(CASE WHEN pt.per_filament_grams IS NULL OR pt.per_filament_grams = "" THEN 1 '
        '  ELSE length(pt.per_filament_grams) - length(replace(pt.per_filament_grams, ",", "")) + 1 END) as color_count '
        'FROM print_tasks pt '
        'LEFT JOIN print_task_consumables ptc ON ptc.task_id = pt.id '
        'WHERE pt.batch_id IS NOT NULL '
        'GROUP BY pt.batch_id '
        'ORDER BY first_started DESC LIMIT 50',
      )
      .get();
  return rows.map((r) {
    final data = Map<String, dynamic>.from(r.data);
    final colorCount = (data['color_count'] as num?)?.toInt() ?? 1;
    data['is_multi_color'] = colorCount > 1;
    data['color_count'] = colorCount;
    return data;
  }).toList();
});

/// 指定批次的耗材消耗汇总（用于异常对比和详情展示）
///
/// 返回字段：task_id, printer_id, task_name, status, actual_grams,
/// total_consumed_grams, total_cost, started_at, finished_at
final batchConsumptionProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
        (ref, batchId) async {
  final db = ref.watch(databaseProvider);
  final rows = await db.customSelect(
    'SELECT pt.id as task_id, pt.printer_id as printer_id, '
    'pt.task_name as task_name, pt.status as status, '
    'pt.actual_grams as actual_grams, pt.started_at as started_at, '
    'pt.finished_at as finished_at, '
    'COALESCE(SUM(ptc.consumed_grams), 0) as total_consumed_grams, '
    'COALESCE(SUM(ptc.consumed_grams * ptc.cost_per_kg_snapshot / 1000), 0) as total_cost '
    'FROM print_tasks pt '
    'LEFT JOIN print_task_consumables ptc ON ptc.task_id = pt.id '
    'WHERE pt.batch_id = ? '
    'GROUP BY pt.id '
    'ORDER BY pt.started_at ASC',
    variables: [Variable<String>(batchId)],
  ).get();
  return rows.map((r) => r.data).toList();
});

/// 活跃打印机当前批次的进度汇总（用于 Dashboard 批次进度卡）。
///
/// 监听 activePrintTaskProvider 变化，若任务有 batch_id 则查询
/// 同批次所有任务的进度状态，返回汇总信息。
///
/// 返回 null 表示当前活跃任务无批次（单独打印）。
/// 返回字段：batch_id, count, task_name, success_count, fail_count,
/// printing_count, avg_mc_percent, active_task_id
final activeBatchProgressProvider =
    FutureProvider<Map<String, dynamic>?>((ref) async {
  // Only the fields used by this aggregate should invalidate the query.
  // actualGrams and layer telemetry can change independently and previously
  // caused a redundant loading frame for the whole batch card.
  final activeTask = ref.watch(
    activePrintTaskProvider.select(
      (task) => task == null
          ? null
          : (
              id: task.id,
              progress: task.lastMcPercent,
              status: task.status,
            ),
    ),
  );
  if (activeTask == null || activeTask.id == null) return null;

  // 查任务的 batch_id（模型未映射，走 raw SQL）
  final db = ref.watch(databaseProvider);
  final row = await db.customSelect(
    'SELECT batch_id FROM print_tasks WHERE id = ?',
    variables: [Variable<int>(activeTask.id!)],
  ).getSingleOrNull();
  if (row == null) return null;

  final batchId = row.data['batch_id'] as String?;
  if (batchId == null || batchId.isEmpty) return null;

  // 查同批次所有任务
  final rows = await db.customSelect(
    'SELECT id, task_name, status, last_mc_percent, started_at, finished_at, '
    'per_filament_grams '
    'FROM print_tasks WHERE batch_id = ? ORDER BY started_at ASC',
    variables: [Variable<String>(batchId)],
  ).get();

  if (rows.isEmpty) return null;

  int successCount = 0;
  int failCount = 0;
  int printingCount = 0;
  int avgMcPercent = 0;
  int activeCount = 0;
  String? taskName;
  // 多色任务检测：任一任务的 per_filament_grams 数组长度 > 1 即为多色批次
  int maxColorCount = 1;

  for (final r in rows) {
    final status = r.data['status'] as String? ?? '';
    final mc = (r.data['last_mc_percent'] as num?)?.toInt() ?? 0;
    if (status == 'finished') {
      successCount++;
    } else if (status == 'failed' || status == 'cancelled') {
      failCount++;
    } else if (status == 'printing' || status == 'paused') {
      printingCount++;
      avgMcPercent += mc;
      activeCount++;
    }
    taskName ??= r.data['task_name'] as String?;

    // 解析 per_filament_grams（JSON 数组字符串），取颜色数
    final pfg = r.data['per_filament_grams'] as String?;
    if (pfg != null && pfg.isNotEmpty) {
      try {
        final list = pfg.startsWith('[') ? (jsonDecode(pfg) as List) : null;
        if (list != null && list.length > maxColorCount) {
          maxColorCount = list.length;
        }
      } catch (_) {}
    }
  }

  // 活跃任务平均进度
  final avg = activeCount > 0 ? avgMcPercent ~/ activeCount : 100;

  return {
    'batch_id': batchId,
    'count': rows.length,
    'task_name': taskName ?? '',
    'success_count': successCount,
    'fail_count': failCount,
    'printing_count': printingCount,
    'avg_mc_percent': avg,
    'active_task_id': activeTask.id,
    'is_multi_color': maxColorCount > 1,
    'color_count': maxColorCount,
  };
});
