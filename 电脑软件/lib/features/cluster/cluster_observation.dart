import '../../core/services/cluster_planning_service.dart';
import '../../data/database/models/scheduler_models.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/printer/printer_connector.dart';

/// Presentation of observed facts only. This must never grant dispatch rights.
class ClusterDeviceObservation {
  const ClusterDeviceObservation({
    required this.label,
    required this.needsAttention,
    this.printing = false,
    this.fresh = false,
    this.progress,
  });

  final String label;
  final bool needsAttention, printing, fresh;
  final double? progress;

  factory ClusterDeviceObservation.from(
    ClusterPrinter printer, {
    DateTime? now,
  }) {
    final state = printer.state;
    if (state == null || state.lastStatus == null) {
      return const ClusterDeviceObservation(
        label: '状态未知',
        needsAttention: true,
      );
    }
    if (state.connectionState != PrinterConnectionState.connected) {
      return ClusterDeviceObservation(
        label: state.isConnecting ? '连接中' : '未连接',
        needsAttention: true,
      );
    }
    final age = state.statusUpdatedAt == null
        ? null
        : (now ?? DateTime.now()).difference(state.statusUpdatedAt!);
    if (age == null ||
        age.isNegative ||
        age > SchedulingConfig.defaults.staleStatusThreshold) {
      return const ClusterDeviceObservation(
        label: '状态待更新',
        needsAttention: true,
      );
    }
    final status = state.lastStatus!;
    final label = switch (status.gcodeState) {
      BambuGcodeState.running => '打印中',
      BambuGcodeState.prepare || BambuGcodeState.init => '准备中',
      BambuGcodeState.pause => '已暂停',
      BambuGcodeState.finish => '打印结束',
      BambuGcodeState.idle => '空闲',
      BambuGcodeState.failed => '打印异常',
      BambuGcodeState.offline => '设备离线',
      _ => '状态待确认',
    };
    final printing = status.gcodeState == BambuGcodeState.running;
    final percent = status.mcPercent;
    return ClusterDeviceObservation(
      label: label,
      printing: printing,
      fresh: true,
      needsAttention:
          printer.blockers.isNotEmpty ||
          !{
            BambuGcodeState.running,
            BambuGcodeState.prepare,
            BambuGcodeState.init,
            BambuGcodeState.finish,
            BambuGcodeState.idle,
          }.contains(status.gcodeState),
      progress: printing && percent != null && percent >= 0 && percent <= 100
          ? percent / 100
          : null,
    );
  }
}

String clusterMachineWait(int? seconds) {
  if (seconds == null || seconds < 0) return '机器等待未知';
  if (seconds == 0) return '机器等待 0 分';
  return '机器等待 ≥${clusterDuration(seconds)}';
}

String clusterDuration(int seconds) => seconds <= 0
    ? '—'
    : seconds < 3600
    ? '${(seconds / 60).ceil()} 分'
    : '${(seconds / 3600).toStringAsFixed(1)} 时';

String clusterTimestamp(DateTime value) {
  final local = value.toLocal();
  String pad(int value) => '$value'.padLeft(2, '0');
  return '${pad(local.month)}-${pad(local.day)} '
      '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
}
