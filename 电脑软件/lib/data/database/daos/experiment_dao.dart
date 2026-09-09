// 参数实验平台数据访问层。
//
// 任务书 Phase D 要求：
// - 新增 parameter_experiments / experiment_variants / experiment_runs 三张表 DAO。
// - 外键删除策略：删除参数预设不删除已执行实验的快照
//   （ON DELETE SET NULL 保留快照历史）。
// - 每次运行锁定参数 fingerprint，参数被修改后必须创建新变体 revision。
// - 默认交替顺序 A-B-A-B；多变体可采用确定性轮换。
// - 自动结果来自 preset_print_results，用户评分从同一结果表读取。
// - 已有结果的实验采用归档，不级联删历史。

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../models/experiment_models.dart';

/// 参数实验 DAO。
///
/// 管理 parameter_experiments / experiment_variants / experiment_runs 三张表。
class ExperimentDao extends DatabaseAccessor<AppDatabase> {
  ExperimentDao(super.db);

  static const _uuid = Uuid();

  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  Stream<void> get onChange => _changeController.stream;

  void _emit() {
    if (!_changeController.isClosed) _changeController.add(null);
  }

  // ===== Parameter Experiments =====

  /// 创建实验。
  Future<String> createExperiment({
    required String name,
    String goal = '',
    String? baselineSnapshotId,
    String controlVariables = '',
    String evaluationMetrics = 'usable_rate',
    int targetRepeats = 3,
  }) async {
    final id = _uuid.v4();
    final uid = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await customStatement(
      '''INSERT INTO parameter_experiments(
        id, experiment_uid, name, goal, baseline_snapshot_id,
        control_variables, evaluation_metrics, status, target_repeats,
        created_at, updated_at, archived_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)''',
      [
        id,
        uid,
        name,
        goal,
        baselineSnapshotId,
        controlVariables,
        evaluationMetrics,
        ExperimentStatus.draft.value,
        targetRepeats,
        now,
        now,
      ],
    );
    _emit();
    return id;
  }

  /// 更新实验状态。
  Future<void> updateStatus(
    String experimentId,
    ExperimentStatus status, {
    DateTime? archivedAt,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await customStatement(
      'UPDATE parameter_experiments SET status = ?, updated_at = ?, archived_at = ? WHERE id = ?',
      [
        status.value,
        now,
        archivedAt?.millisecondsSinceEpoch,
        experimentId,
      ],
    );
    _emit();
  }

  /// 按 ID 查询实验。
  Future<ParameterExperiment?> getById(String id) async {
    final row = await customSelect(
      'SELECT * FROM parameter_experiments WHERE id = ?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    return row == null ? null : ParameterExperiment.fromRow(row.data);
  }

  /// 查询所有实验（按创建时间倒序）。
  Future<List<ParameterExperiment>> getAll() async {
    final rows = await customSelect(
      'SELECT * FROM parameter_experiments ORDER BY created_at DESC',
    ).get();
    return rows.map((r) => ParameterExperiment.fromRow(r.data)).toList();
  }

  /// 监听所有实验变化。
  ///
  /// 先发射当前快照，避免广播变更流在首次打开页面时没有事件，导致 UI
  /// 永远停留在 loading。后续单次查询失败只记录日志，监听仍保持有效。
  Stream<List<ParameterExperiment>> watchAll() async* {
    yield await getAll();
    try {
      await for (final _ in _changeController.stream) {
        try {
          yield await getAll();
        } catch (error) {
          debugPrint('[ExperimentDao] watchAll 查询失败: $error');
        }
      }
    } catch (error) {
      debugPrint('[ExperimentDao] watchAll 流异常: $error');
    }
  }

  /// 删除实验（仅允许 draft 状态；有运行结果的采用归档）。
  /// 任务书要求：删除未运行实验有确认；已有结果的实验采用归档，不级联删历史。
  Future<void> deleteExperiment(String id) async {
    await customStatement(
      'DELETE FROM parameter_experiments WHERE id = ?',
      [id],
    );
    _emit();
  }

  // ===== Experiment Variants =====

  /// 创建变体。
  Future<String> createVariant({
    required String experimentId,
    required String label,
    String? snapshotId,
    String diffSummary = '',
    int revision = 1,
  }) async {
    final id = _uuid.v4();
    final uid = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await customStatement(
      '''INSERT INTO experiment_variants(
        id, variant_uid, experiment_id, label, snapshot_id,
        diff_summary, revision, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [id, uid, experimentId, label, snapshotId, diffSummary, revision, now],
    );
    _emit();
    return id;
  }

  /// 查询实验的所有变体。
  Future<List<ExperimentVariant>> getVariants(String experimentId) async {
    final rows = await customSelect(
      'SELECT * FROM experiment_variants WHERE experiment_id = ? ORDER BY label ASC',
      variables: [Variable(experimentId)],
    ).get();
    return rows.map((r) => ExperimentVariant.fromRow(r.data)).toList();
  }

  Future<ExperimentVariant?> getVariantById(String variantId) async {
    final row = await customSelect(
      'SELECT * FROM experiment_variants WHERE id = ?',
      variables: [Variable(variantId)],
    ).getSingleOrNull();
    return row == null ? null : ExperimentVariant.fromRow(row.data);
  }

  /// 查询变体的最新 revision。
  /// 参数被修改后必须创建新变体 revision。
  Future<int> getLatestRevision(String experimentId, String label) async {
    final row = await customSelect(
      'SELECT MAX(revision) AS max_rev FROM experiment_variants WHERE experiment_id = ? AND label = ?',
      variables: [Variable(experimentId), Variable(label)],
    ).getSingleOrNull();
    final maxRev = row?.read<int?>('max_rev');
    return maxRev ?? 0;
  }

  // ===== Experiment Runs =====

  /// 创建运行（含交替顺序）。
  ///
  /// 任务书要求：默认交替顺序 A-B-A-B；多变体采用确定性轮换。
  Future<String> createRun({
    required String experimentId,
    required String variantId,
    required int runOrder,
    int? taskId,
    String? resultId,
    RunStatus status = RunStatus.pending,
  }) async {
    final id = _uuid.v4();
    final uid = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await customStatement(
      '''INSERT INTO experiment_runs(
        id, run_uid, experiment_id, variant_id, run_order,
        task_id, result_id, status, created_at, completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)''',
      [
        id,
        uid,
        experimentId,
        variantId,
        runOrder,
        taskId,
        resultId,
        status.value,
        now,
      ],
    );
    _emit();
    return id;
  }

  /// 更新运行状态。
  Future<void> updateRunStatus(
    String runId,
    RunStatus status, {
    int? taskId,
    String? resultId,
    DateTime? completedAt,
  }) async {
    final sets = <String>['status = ?'];
    final args = <dynamic>[status.value];
    if (taskId != null) {
      sets.add('task_id = ?');
      args.add(taskId);
    }
    if (resultId != null) {
      sets.add('result_id = ?');
      args.add(resultId);
    }
    if (completedAt != null) {
      sets.add('completed_at = ?');
      args.add(completedAt.millisecondsSinceEpoch);
    }
    args.add(runId);
    await customStatement(
      'UPDATE experiment_runs SET ${sets.join(', ')} WHERE id = ?',
      args,
    );
    _emit();
  }

  /// 查询实验的所有运行（按运行序号排序）。
  Future<List<ExperimentRun>> getRuns(String experimentId) async {
    final rows = await customSelect(
      'SELECT * FROM experiment_runs WHERE experiment_id = ? ORDER BY run_order ASC',
      variables: [Variable(experimentId)],
    ).get();
    return rows.map((r) => ExperimentRun.fromRow(r.data)).toList();
  }

  /// 按 ID 查询单次实验运行。
  Future<ExperimentRun?> getRunById(String runId) async {
    final row = await customSelect(
      'SELECT * FROM experiment_runs WHERE id = ?',
      variables: [Variable(runId)],
    ).getSingleOrNull();
    return row == null ? null : ExperimentRun.fromRow(row.data);
  }

  /// 所有已被实验运行占用的真实打印任务 ID。
  Future<Set<int>> getLinkedTaskIds() async {
    final rows = await customSelect(
      'SELECT task_id FROM experiment_runs WHERE task_id IS NOT NULL',
    ).get();
    return rows.map((row) => row.read<int>('task_id')).toSet();
  }

  /// 将真实终态打印结果关联到一次实验运行，并在全部运行结束后完成实验。
  Future<void> linkRunToTerminalResult({
    required String runId,
    required int taskId,
    required String resultId,
    required RunStatus status,
  }) async {
    if (!status.isTerminal) {
      throw ArgumentError.value(status, 'status', '必须是终态运行状态');
    }

    await transaction(() async {
      final row = await customSelect(
        'SELECT * FROM experiment_runs WHERE id = ?',
        variables: [Variable(runId)],
      ).getSingleOrNull();
      if (row == null) throw StateError('实验运行不存在: $runId');
      final run = ExperimentRun.fromRow(row.data);

      final duplicate = await customSelect(
        'SELECT id FROM experiment_runs '
        'WHERE id != ? AND (task_id = ? OR result_id = ?) LIMIT 1',
        variables: [Variable(runId), Variable(taskId), Variable(resultId)],
      ).getSingleOrNull();
      if (duplicate != null) {
        throw StateError('该打印结果已关联到其他实验运行');
      }

      if (run.status.isTerminal) {
        if (run.taskId == taskId &&
            run.resultId == resultId &&
            run.status == status) {
          return;
        }
        if (run.status != status ||
            (run.taskId != null && run.taskId != taskId) ||
            run.resultId != null) {
          throw StateError('已经结束的实验运行不能改绑打印结果');
        }
        await customStatement(
          'UPDATE experiment_runs SET task_id = COALESCE(task_id, ?), '
          'result_id = ?, completed_at = COALESCE(completed_at, ?) '
          'WHERE id = ?',
          [
            taskId,
            resultId,
            DateTime.now().millisecondsSinceEpoch,
            runId,
          ],
        );
        return;
      }
      if (run.status != RunStatus.pending &&
          run.status != RunStatus.queued &&
          run.status != RunStatus.printing) {
        throw StateError('当前实验运行状态不能关联打印结果');
      }

      final experiment = await customSelect(
        'SELECT status FROM parameter_experiments WHERE id = ?',
        variables: [Variable(run.experimentId)],
      ).getSingle();
      final experimentStatus =
          ExperimentStatus.fromString(experiment.read<String>('status'));
      if (experimentStatus != ExperimentStatus.running &&
          experimentStatus != ExperimentStatus.paused) {
        throw StateError('仅进行中或已暂停的实验可以关联打印结果');
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      await customStatement(
        'UPDATE experiment_runs SET task_id = ?, result_id = ?, '
        'status = ?, completed_at = ? WHERE id = ?',
        [taskId, resultId, status.value, now, runId],
      );

      final remaining = await customSelect(
        "SELECT COUNT(*) AS cnt FROM experiment_runs "
        "WHERE experiment_id = ? AND status NOT IN "
        "('completed', 'failed', 'cancelled', 'skipped')",
        variables: [Variable(run.experimentId)],
      ).getSingle();
      if (remaining.read<int>('cnt') == 0) {
        await customStatement(
          'UPDATE parameter_experiments SET status = ?, updated_at = ? '
          'WHERE id = ? AND status IN (?, ?)',
          [
            ExperimentStatus.completed.value,
            now,
            run.experimentId,
            ExperimentStatus.running.value,
            ExperimentStatus.paused.value,
          ],
        );
      }
    });
    _emit();
  }

  /// 查询变体的所有运行。
  Future<List<ExperimentRun>> getRunsByVariant(String variantId) async {
    final rows = await customSelect(
      'SELECT * FROM experiment_runs WHERE variant_id = ? ORDER BY run_order ASC',
      variables: [Variable(variantId)],
    ).get();
    return rows.map((r) => ExperimentRun.fromRow(r.data)).toList();
  }

  Future<ExperimentRun?> getRunByTaskId(int taskId) async {
    final row = await customSelect(
      'SELECT * FROM experiment_runs WHERE task_id = ? LIMIT 1',
      variables: [Variable(taskId)],
    ).getSingleOrNull();
    return row == null ? null : ExperimentRun.fromRow(row.data);
  }

  /// 计算下一个交替顺序号（基于现有运行数）。
  ///
  /// 默认交替顺序 A-B-A-B：第 N 个运行 = N+1。
  /// 多变体采用确定性轮换：variantIndex = (currentRunCount) % variantCount。
  Future<int> nextRunOrder(String experimentId) async {
    final row = await customSelect(
      'SELECT COUNT(*) AS cnt FROM experiment_runs WHERE experiment_id = ?',
      variables: [Variable(experimentId)],
    ).getSingleOrNull();
    final cnt = row?.read<int?>('cnt') ?? 0;
    return cnt + 1;
  }

  /// 关联运行到打印任务（用户入队/启动后调用）。
  Future<void> markRunQueued(String runId) async {
    final updated = await customUpdate(
      'UPDATE experiment_runs SET status = ? WHERE id = ? AND status = ?',
      variables: [
        Variable(RunStatus.queued.value),
        Variable(runId),
        Variable(RunStatus.pending.value),
      ],
      updates: {},
    );
    if (updated != 1) {
      throw StateError('实验运行已入队、已开始或已结束');
    }
    _emit();
  }

  Future<void> bindRunToTask(
    String runId,
    int taskId, {
    RunStatus status = RunStatus.printing,
  }) async {
    if (status != RunStatus.queued && status != RunStatus.printing) {
      throw ArgumentError.value(status, 'status', '任务绑定状态必须是 queued/printing');
    }
    await transaction(() async {
      final duplicate = await customSelect(
        'SELECT id FROM experiment_runs WHERE id != ? AND task_id = ? LIMIT 1',
        variables: [Variable(runId), Variable(taskId)],
      ).getSingleOrNull();
      if (duplicate != null) throw StateError('打印任务已被其他实验运行占用');

      final updated = await customUpdate(
        "UPDATE experiment_runs SET task_id = ?, status = ? "
        "WHERE id = ? AND status IN ('pending', 'queued', 'printing')",
        variables: [Variable(taskId), Variable(status.value), Variable(runId)],
        updates: {},
      );
      if (updated != 1) throw StateError('实验运行不存在或已经结束');
    });
    _emit();
  }

  Future<void> markRunTerminal(String runId, RunStatus status) async {
    if (!status.isTerminal) {
      throw ArgumentError.value(status, 'status', '必须是终态');
    }
    await transaction(() async {
      final row = await customSelect(
        'SELECT experiment_id, status FROM experiment_runs WHERE id = ?',
        variables: [Variable(runId)],
      ).getSingleOrNull();
      if (row == null) throw StateError('实验运行不存在: $runId');
      final current = RunStatus.fromString(row.read<String>('status'));
      if (current.isTerminal) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      await customStatement(
        'UPDATE experiment_runs SET status = ?, completed_at = ? WHERE id = ?',
        [status.value, now, runId],
      );
      final experimentId = row.read<String>('experiment_id');
      final remaining = await customSelect(
        "SELECT COUNT(*) AS cnt FROM experiment_runs WHERE experiment_id = ? "
        "AND status NOT IN ('completed', 'failed', 'cancelled', 'skipped')",
        variables: [Variable(experimentId)],
      ).getSingle();
      if (remaining.read<int>('cnt') == 0) {
        await customStatement(
          'UPDATE parameter_experiments SET status = ?, updated_at = ? '
          'WHERE id = ? AND status IN (?, ?)',
          [
            ExperimentStatus.completed.value,
            now,
            experimentId,
            ExperimentStatus.running.value,
            ExperimentStatus.paused.value,
          ],
        );
      }
    });
    _emit();
  }

  /// 关联运行到打印结果（任务终态时调用）。
  Future<void> bindRunToResult(String runId, String resultId) async {
    await customStatement(
      'UPDATE experiment_runs SET result_id = ? WHERE id = ?',
      [resultId, runId],
    );
    _emit();
  }

  void dispose() {
    _changeController.close();
  }
}
