// 打印队列项模型 + 状态枚举。
//
// 对应 print_tasks 表旁的 print_queue 表（v13 新增）。
// 状态机：queued → printing → waiting_removal → completed（或 cancelled）。
// 农场工单在打印机上报 finish 时已先完成；waiting_removal 只阻止下一项启动。

import 'dart:convert';

/// 队列项状态。
enum PrintQueueStatus {
  /// 待打印，按 sort_order 排序
  queued,

  /// 已发送到打印机，MQTT 监测中
  printing,

  /// 打印完成，等待用户取件确认（无人值守模式跳过此状态）
  waitingRemoval,

  /// 取件确认完成 / 无人值守模式自动完成
  completed,

  /// 用户取消
  cancelled,

  /// 打印机明确上报失败
  failed;

  String get value {
    switch (this) {
      case PrintQueueStatus.queued:
        return 'queued';
      case PrintQueueStatus.printing:
        return 'printing';
      case PrintQueueStatus.waitingRemoval:
        return 'waiting_removal';
      case PrintQueueStatus.completed:
        return 'completed';
      case PrintQueueStatus.cancelled:
        return 'cancelled';
      case PrintQueueStatus.failed:
        return 'failed';
    }
  }

  static PrintQueueStatus fromString(String s) {
    switch (s) {
      case 'queued':
        return PrintQueueStatus.queued;
      case 'printing':
        return PrintQueueStatus.printing;
      case 'waiting_removal':
        return PrintQueueStatus.waitingRemoval;
      case 'completed':
        return PrintQueueStatus.completed;
      case 'cancelled':
        return PrintQueueStatus.cancelled;
      case 'failed':
        return PrintQueueStatus.failed;
      default:
        return PrintQueueStatus.queued;
    }
  }

  bool get isTerminal =>
      this == PrintQueueStatus.completed ||
      this == PrintQueueStatus.cancelled ||
      this == PrintQueueStatus.failed;

  /// 中文显示名
  String get label {
    switch (this) {
      case PrintQueueStatus.queued:
        return '排队中';
      case PrintQueueStatus.printing:
        return '打印中';
      case PrintQueueStatus.waitingRemoval:
        return '等待取件';
      case PrintQueueStatus.completed:
        return '已完成';
      case PrintQueueStatus.cancelled:
        return '已取消';
      case PrintQueueStatus.failed:
        return '已失败';
    }
  }
}

/// 打印队列项数据类。对应 print_queue 表的行。
class PrintQueueItem {
  final int? id;
  final String printerSerial;
  final String gcodePath;
  final String filename;
  final PrintQueueStatus status;
  final int sortOrder;
  final DateTime queuedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final int? printTaskId;

  /// v21：关联调度任务 id。调度器入队时填入，唯一索引防止同一调度任务重复入队。
  /// 手动入队的队列项此字段为 null。
  final int? schedulerTaskId;

  /// v24: the parameter experiment run represented by this queue item.
  final String? experimentRunId;
  final String? experimentSnapshotId;
  final String? experimentApplicationId;
  final String? experimentAttribution;
  final String? artifactSha256;

  /// 调度时确认的工具到 AMS 全局槽位映射。为空时才回退到切片文件内映射。
  final List<int>? amsMapping;

  /// 农场按盘工单。用于把队列状态和耗材结算同步回生产工单。
  final String? studioWorkOrderId;

  /// 同一队列项的物理打印尝试序号。每次失败后重试递增，避免把第二次
  /// 失败误判成第一次失败通知的重复投递。
  final int attemptNo;

  /// Explicit per-item override. NULL keeps the legacy global unattended
  /// preference; false is an intentional manual-removal choice.
  final bool? autoContinue;
  final String? batchId;
  final int? batchIndex;
  final int? batchTotal;

  bool effectiveAutoContinue(bool globalPreference) =>
      autoContinue ?? globalPreference;

  const PrintQueueItem({
    this.id,
    required this.printerSerial,
    required this.gcodePath,
    required this.filename,
    this.status = PrintQueueStatus.queued,
    this.sortOrder = 0,
    required this.queuedAt,
    this.startedAt,
    this.completedAt,
    this.printTaskId,
    this.schedulerTaskId,
    this.experimentRunId,
    this.experimentSnapshotId,
    this.experimentApplicationId,
    this.experimentAttribution,
    this.artifactSha256,
    this.amsMapping,
    this.studioWorkOrderId,
    this.attemptNo = 1,
    this.autoContinue,
    this.batchId,
    this.batchIndex,
    this.batchTotal,
  });

  PrintQueueItem copyWith({
    int? id,
    String? printerSerial,
    String? gcodePath,
    String? filename,
    PrintQueueStatus? status,
    int? sortOrder,
    DateTime? queuedAt,
    DateTime? startedAt,
    DateTime? completedAt,
    int? printTaskId,
    int? schedulerTaskId,
    String? experimentRunId,
    String? experimentSnapshotId,
    String? experimentApplicationId,
    String? experimentAttribution,
    String? artifactSha256,
    List<int>? amsMapping,
    String? studioWorkOrderId,
    int? attemptNo,
    bool? autoContinue,
    String? batchId,
    int? batchIndex,
    int? batchTotal,
  }) {
    return PrintQueueItem(
      id: id ?? this.id,
      printerSerial: printerSerial ?? this.printerSerial,
      gcodePath: gcodePath ?? this.gcodePath,
      filename: filename ?? this.filename,
      status: status ?? this.status,
      sortOrder: sortOrder ?? this.sortOrder,
      queuedAt: queuedAt ?? this.queuedAt,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      printTaskId: printTaskId ?? this.printTaskId,
      schedulerTaskId: schedulerTaskId ?? this.schedulerTaskId,
      experimentRunId: experimentRunId ?? this.experimentRunId,
      experimentSnapshotId: experimentSnapshotId ?? this.experimentSnapshotId,
      experimentApplicationId:
          experimentApplicationId ?? this.experimentApplicationId,
      experimentAttribution:
          experimentAttribution ?? this.experimentAttribution,
      artifactSha256: artifactSha256 ?? this.artifactSha256,
      amsMapping: amsMapping ?? this.amsMapping,
      studioWorkOrderId: studioWorkOrderId ?? this.studioWorkOrderId,
      attemptNo: attemptNo ?? this.attemptNo,
      autoContinue: autoContinue ?? this.autoContinue,
      batchId: batchId ?? this.batchId,
      batchIndex: batchIndex ?? this.batchIndex,
      batchTotal: batchTotal ?? this.batchTotal,
    );
  }

  factory PrintQueueItem.fromMap(Map<String, dynamic> map) {
    return PrintQueueItem(
      id: map['id'] as int?,
      printerSerial: map['printer_serial'] as String,
      gcodePath: map['gcode_path'] as String,
      filename: map['filename'] as String,
      status: PrintQueueStatus.fromString(map['status'] as String),
      sortOrder: map['sort_order'] as int,
      queuedAt: DateTime.fromMillisecondsSinceEpoch(map['queued_at'] as int),
      startedAt: map['started_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['started_at'] as int)
          : null,
      completedAt: map['completed_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['completed_at'] as int)
          : null,
      printTaskId: map['print_task_id'] as int?,
      // v21 列：旧库迁移前可能无此列，fromMap 容错处理
      schedulerTaskId: map['scheduler_task_id'] as int?,
      experimentRunId: map['experiment_run_id'] as String?,
      experimentSnapshotId: map['experiment_snapshot_id'] as String?,
      experimentApplicationId: map['experiment_application_id'] as String?,
      experimentAttribution: map['experiment_attribution'] as String?,
      artifactSha256: map['artifact_sha256'] as String?,
      amsMapping: _decodeAmsMapping(map['ams_mapping_json'] as String?),
      studioWorkOrderId: map['studio_work_order_id'] as String?,
      attemptNo: map['attempt_no'] as int? ?? 1,
      autoContinue: switch (map['auto_continue'] as int?) {
        1 => true,
        0 => false,
        _ => null,
      },
      batchId: map['batch_id'] as String?,
      batchIndex: map['batch_index'] as int?,
      batchTotal: map['batch_total'] as int?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'printer_serial': printerSerial,
      'gcode_path': gcodePath,
      'filename': filename,
      'status': status.value,
      'sort_order': sortOrder,
      'queued_at': queuedAt.millisecondsSinceEpoch,
      'started_at': startedAt?.millisecondsSinceEpoch,
      'completed_at': completedAt?.millisecondsSinceEpoch,
      'print_task_id': printTaskId,
      'scheduler_task_id': schedulerTaskId,
      'experiment_run_id': experimentRunId,
      'experiment_snapshot_id': experimentSnapshotId,
      'experiment_application_id': experimentApplicationId,
      'experiment_attribution': experimentAttribution,
      'artifact_sha256': artifactSha256,
      'ams_mapping_json': amsMapping == null ? null : jsonEncode(amsMapping),
      'studio_work_order_id': studioWorkOrderId,
      'attempt_no': attemptNo,
      'auto_continue': autoContinue == null ? null : (autoContinue! ? 1 : 0),
      'batch_id': batchId,
      'batch_index': batchIndex,
      'batch_total': batchTotal,
    };
  }

  static List<int>? _decodeAmsMapping(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return null;
      return decoded.whereType<num>().map((item) => item.toInt()).toList();
    } catch (_) {
      return null;
    }
  }
}
