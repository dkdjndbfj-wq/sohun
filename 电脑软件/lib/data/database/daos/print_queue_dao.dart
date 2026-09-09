// 打印队列 DAO（raw SQL，不走 drift 代码生成）。
//
// 管理 print_queue 表的 CRUD + 状态机推进。
// print_queue 表是 v13 用 raw SQL 创建的，不在 drift 代码生成范围内，
// 所以全部用 customStatement / customSelect + 参数绑定操作。

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database.dart';
import '../models/print_queue_item.dart';

class PrintQueueDao {
  final AppDatabase _db;
  PrintQueueDao(this._db);

  /// Different features create lightweight DAO wrappers around the same
  /// database. The bus is therefore keyed by [AppDatabase], not by DAO
  /// instance, so scheduler/queue/experiment writes all reach subscribers.
  static final Expando<StreamController<void>> _changeControllers =
      Expando<StreamController<void>>('print_queue_change_bus');

  StreamController<void> get _changeController =>
      _changeControllers[_db] ??= StreamController<void>.broadcast();

  Stream<void> get onChange => _changeController.stream;

  void _emit() {
    if (!_changeController.isClosed) _changeController.add(null);
  }

  /// Publishes one consolidated change after a caller commits a transaction
  /// that used the `notify: false` write APIs below.
  void notifyChanged() => _emit();

  /// 获取指定打印机的队列（按 sort_order 排序，仅未取消的）
  Future<List<PrintQueueItem>> getByPrinter(
    String printerSerial, {
    bool includeCancelled = false,
  }) async {
    final sql = includeCancelled
        ? 'SELECT * FROM print_queue WHERE printer_serial = ? ORDER BY sort_order ASC, queued_at ASC'
        : 'SELECT * FROM print_queue WHERE printer_serial = ? AND status != ? ORDER BY sort_order ASC, queued_at ASC';
    final rows = includeCancelled
        ? await _db.customSelect(
            sql,
            variables: [Variable<String>(printerSerial)],
          ).get()
        : await _db.customSelect(
            sql,
            variables: [
              Variable<String>(printerSerial),
              Variable<String>(PrintQueueStatus.cancelled.value),
            ],
          ).get();
    return rows.map((r) => PrintQueueItem.fromMap(r.data)).toList();
  }

  /// 获取队首（sort_order 最小的 queued 项）
  Future<PrintQueueItem?> getHead(String printerSerial) async {
    final rows = await _db.customSelect(
      'SELECT * FROM print_queue WHERE printer_serial = ? AND status = ? ORDER BY sort_order ASC LIMIT 1',
      variables: [
        Variable<String>(printerSerial),
        Variable<String>(PrintQueueStatus.queued.value),
      ],
    ).get();
    if (rows.isEmpty) return null;
    return PrintQueueItem.fromMap(rows.first.data);
  }

  /// 获取指定打印机正在打印的项
  Future<PrintQueueItem?> getPrinting(String printerSerial) async {
    final rows = await _db.customSelect(
      'SELECT * FROM print_queue WHERE printer_serial = ? AND status = ? LIMIT 1',
      variables: [
        Variable<String>(printerSerial),
        Variable<String>(PrintQueueStatus.printing.value),
      ],
    ).get();
    if (rows.isEmpty) return null;
    return PrintQueueItem.fromMap(rows.first.data);
  }

  /// 获取指定打印机等待取件的项
  Future<PrintQueueItem?> getWaitingRemoval(String printerSerial) async {
    final rows = await _db.customSelect(
      'SELECT * FROM print_queue WHERE printer_serial = ? AND status = ? LIMIT 1',
      variables: [
        Variable<String>(printerSerial),
        Variable<String>(PrintQueueStatus.waitingRemoval.value),
      ],
    ).get();
    if (rows.isEmpty) return null;
    return PrintQueueItem.fromMap(rows.first.data);
  }

  /// 获取整支舰队中所有等待人工取件的任务。
  ///
  /// 按打印完成/入队时间排序，保证多台打印机同时完成时，确认弹窗顺序稳定。
  Future<List<PrintQueueItem>> getAllWaitingRemovals() async {
    final rows = await _db
        .customSelect(
          "SELECT * FROM print_queue WHERE status = 'waiting_removal' "
          'ORDER BY COALESCE(completed_at, started_at, queued_at) ASC, id ASC',
        )
        .get();
    return rows.map((row) => PrintQueueItem.fromMap(row.data)).toList();
  }

  /// 监听整支舰队的等待取件任务，包含应用启动时已经遗留的状态。
  Stream<List<PrintQueueItem>> watchAllWaitingRemovals() {
    late final StreamController<List<PrintQueueItem>> controller;
    StreamSubscription<void>? changeSubscription;
    var disposed = false;
    var requestedRevision = 0;
    var publishedRevision = 0;

    Future<void> publishSnapshot() async {
      final revision = ++requestedRevision;
      try {
        final items = await getAllWaitingRemovals();
        if (disposed || controller.isClosed || revision < publishedRevision) {
          return;
        }
        publishedRevision = revision;
        controller.add(items);
      } catch (error, stackTrace) {
        if (!disposed && !controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      }
    }

    controller = StreamController<List<PrintQueueItem>>(
      onListen: () {
        // 先订阅变更再读取初始快照，避免在两者之间漏掉状态更新。
        changeSubscription = onChange.listen((_) {
          unawaited(publishSnapshot());
        });
        unawaited(publishSnapshot());
      },
      onCancel: () async {
        disposed = true;
        await changeSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// 添加到队列末尾，返回新插入的 id
  ///
  /// v21：若 [PrintQueueItem.schedulerTaskId] 非 null，由唯一索引
  /// idx_pq_scheduler_task_unique 保证同一调度任务不会重复入队
  /// （违反约束会抛 SqliteException，调用方应在事务内捕获并回滚）。
  Future<int> enqueue(PrintQueueItem item, {bool notify = true}) async {
    // 修复：原实现「查 MAX(sort_order) + 插入」非原子，并发调用会产生相同
    // sort_order 导致队列顺序错乱。用事务包裹保证原子性。
    final result = await _db.transaction(() async {
      // 获取当前最大 sort_order
      final maxRow = await _db.customSelect(
        'SELECT MAX(sort_order) as max_sort FROM print_queue WHERE printer_serial = ?',
        variables: [Variable<String>(item.printerSerial)],
      ).getSingle();
      final maxSort = (maxRow.data['max_sort'] as int?) ?? 0;
      final sortOrder = maxSort + 1;
      final queuedAt = item.queuedAt.millisecondsSinceEpoch;
      final result = await _db.customInsert(
        'INSERT INTO print_queue (printer_serial, gcode_path, filename, status, sort_order, queued_at, scheduler_task_id, experiment_run_id, experiment_snapshot_id, experiment_application_id, experiment_attribution, artifact_sha256, ams_mapping_json, studio_work_order_id, attempt_no, auto_continue, batch_id, batch_index, batch_total) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable<String>(item.printerSerial),
          Variable<String>(item.gcodePath),
          Variable<String>(item.filename),
          Variable<String>(PrintQueueStatus.queued.value),
          Variable<int>(sortOrder),
          Variable<int>(queuedAt),
          Variable<int>(item.schedulerTaskId),
          Variable<String>(item.experimentRunId),
          Variable<String>(item.experimentSnapshotId),
          Variable<String>(item.experimentApplicationId),
          Variable<String>(item.experimentAttribution),
          Variable<String>(item.artifactSha256),
          Variable<String>(
            item.amsMapping == null ? null : jsonEncode(item.amsMapping),
          ),
          Variable<String>(item.studioWorkOrderId),
          Variable<int>(item.attemptNo),
          Variable<int>(switch (item.autoContinue) {
            true => 1,
            false => 0,
            null => null,
          }),
          Variable<String>(item.batchId),
          Variable<int>(item.batchIndex),
          Variable<int>(item.batchTotal),
        ],
      );
      return result;
    });
    if (notify) _emit();
    return result;
  }

  /// All durable artifacts still referenced by queue history.
  ///
  /// Completed and cancelled rows are included intentionally: their files are
  /// part of the production audit trail and must not be removed by retention
  /// cleanup while the row still exists.
  Future<Set<String>> getAllArtifactPaths() async {
    final rows = await _db
        .customSelect(
          "SELECT DISTINCT gcode_path FROM print_queue WHERE TRIM(gcode_path) != ''",
        )
        .get();
    return {
      for (final row in rows)
        if (row.read<String>('gcode_path').trim().isNotEmpty)
          row.read<String>('gcode_path').trim(),
    };
  }

  /// 打印中、等待取件和排队中的任务总数，用于限制忙机预分派深度。
  Future<int> getActiveCount(String printerSerial) async {
    final row = await _db.customSelect(
      "SELECT COUNT(*) AS cnt FROM print_queue WHERE printer_serial = ? "
      "AND status IN ('queued', 'printing', 'waiting_removal')",
      variables: [Variable<String>(printerSerial)],
    ).getSingle();
    return row.read<int>('cnt');
  }

  /// v21：按 scheduler_task_id 查询队列项。
  ///
  /// 替代旧的"按文件名反查"逻辑。调度器通过此方法精确查找
  /// 某个调度任务对应的队列项，追踪状态推进。
  Future<PrintQueueItem?> getBySchedulerTaskId(int schedulerTaskId) async {
    final rows = await _db.customSelect(
      'SELECT * FROM print_queue WHERE scheduler_task_id = ? LIMIT 1',
      variables: [Variable<int>(schedulerTaskId)],
    ).get();
    if (rows.isEmpty) return null;
    return PrintQueueItem.fromMap(rows.first.data);
  }

  Future<PrintQueueItem?> getByStudioWorkOrderId(String workOrderId) async {
    final rows = await _db.customSelect(
      "SELECT * FROM print_queue WHERE studio_work_order_id = ? "
      "ORDER BY CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END, id DESC LIMIT 1",
      variables: [Variable<String>(workOrderId)],
    ).get();
    if (rows.isEmpty) return null;
    return PrintQueueItem.fromMap(rows.first.data);
  }

  /// Returns the unique queue item assigned to an experiment run.
  Future<PrintQueueItem?> getByExperimentRunId(String experimentRunId) async {
    final rows = await _db.customSelect(
      'SELECT * FROM print_queue WHERE experiment_run_id = ? LIMIT 1',
      variables: [Variable<String>(experimentRunId)],
    ).get();
    if (rows.isEmpty) return null;
    return PrintQueueItem.fromMap(rows.first.data);
  }

  Future<List<PrintQueueItem>> getByBatchId(String batchId) async {
    final rows = await _db.customSelect(
      'SELECT * FROM print_queue WHERE batch_id = ? '
      'ORDER BY batch_index ASC, id ASC',
      variables: [Variable<String>(batchId)],
    ).get();
    return rows.map((row) => PrintQueueItem.fromMap(row.data)).toList();
  }

  /// v21：检查调度任务是否已入队（防止重复入队）。
  Future<bool> isSchedulerTaskEnqueued(int schedulerTaskId) async {
    final rows = await _db.customSelect(
      'SELECT COUNT(*) AS cnt FROM print_queue '
      'WHERE scheduler_task_id = ? AND status != ?',
      variables: [
        Variable<int>(schedulerTaskId),
        Variable<String>(PrintQueueStatus.cancelled.value),
      ],
    ).get();
    return rows.first.read<int>('cnt') > 0;
  }

  /// 更新状态（安全版，逐字段更新）
  Future<void> setStatus(
    int id,
    PrintQueueStatus status, {
    DateTime? startedAt,
    DateTime? completedAt,
    int? printTaskId,
    bool notify = true,
  }) async {
    final setParts = <String>['status = ?'];
    final args = <Variable>[Variable<String>(status.value)];
    if (startedAt != null) {
      setParts.add('started_at = ?');
      args.add(Variable<int>(startedAt.millisecondsSinceEpoch));
    }
    if (completedAt != null) {
      setParts.add('completed_at = ?');
      args.add(Variable<int>(completedAt.millisecondsSinceEpoch));
    }
    if (printTaskId != null) {
      setParts.add('print_task_id = ?');
      args.add(Variable<int>(printTaskId));
    }
    args.add(Variable<int>(id));
    await _db.customUpdate(
      'UPDATE print_queue SET ${setParts.join(', ')} WHERE id = ?',
      variables: args,
      updates: {},
    );
    if (notify) _emit();
  }

  /// Puts a failed item back at the head of its existing queue position.
  /// Reusing the row preserves the unique farm work-order link. Durable loss
  /// history lives in the inventory/activity ledgers, so transient queue
  /// timestamps can be cleared for the new attempt.
  Future<void> retryFailed(int id) async {
    final changed = await _db.customUpdate(
      "UPDATE print_queue SET status = 'queued', attempt_no = attempt_no + 1, "
      'started_at = NULL, '
      'completed_at = NULL, print_task_id = NULL '
      "WHERE id = ? AND status = 'failed'",
      variables: [Variable<int>(id)],
      updates: {},
    );
    if (changed == 0) throw StateError('只有失败的队列任务可以重试');
    _emit();
  }

  Future<void> markQualityRejected(int id) async {
    final changed = await _db.customUpdate(
      "UPDATE print_queue SET status = 'failed', completed_at = ? "
      "WHERE id = ? AND status IN ('waiting_removal', 'completed')",
      variables: [
        Variable<int>(DateTime.now().millisecondsSinceEpoch),
        Variable<int>(id),
      ],
      updates: {},
    );
    if (changed == 0) {
      throw StateError('只有已经打印完成的队列任务才能登记成品不合格');
    }
    _emit();
  }

  /// 删除队列项
  Future<void> delete(int id) async {
    await _db.customStatement(
      'DELETE FROM print_queue WHERE id = ?',
      [id],
    );
    _emit();
  }

  /// 重新排序（拖拽调整顺序）
  Future<void> reorder(List<int> orderedIds) async {
    // 修复：循环内多次 UPDATE 非原子，中途失败会导致排序部分更新、队列顺序混乱。
    // 用事务包裹，任一失败整体回滚。
    await _db.transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await _db.customStatement(
          'UPDATE print_queue SET sort_order = ? WHERE id = ?',
          [i + 1, orderedIds[i]],
        );
      }
    });
    _emit();
  }

  /// 跳过尚未发送的队首任务。
  ///
  /// 绝不在这里取消 printing：那只会改本地数据库，打印机仍会继续运行，
  /// 随后还有可能把下一项发给同一台设备。打印中止必须走连接器 stop 链路。
  Future<PrintQueueItem?> skipCurrent(String printerSerial) async {
    return _db.transaction(() async {
      final head = await getHead(printerSerial);
      if (head?.id != null) {
        await setStatus(head!.id!, PrintQueueStatus.cancelled);
        return head;
      }
      return null;
    });
  }

  /// 清空指定打印机的已完成/已取消项
  Future<void> clearFinished(String printerSerial) async {
    await _db.customStatement(
      "DELETE FROM print_queue WHERE printer_serial = ? AND status IN ('completed', 'cancelled', 'failed')",
      [printerSerial],
    );
    _emit();
    debugPrint('[PrintQueueDao] 已清理 $printerSerial 的已完成项');
  }
}
