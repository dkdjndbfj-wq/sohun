import 'dart:async';

import 'sensitive_data_sanitizer.dart';
import 'telemetry_service.dart';

/// 摄像头链路诊断遥测（2026-09-03 所有者策略：设备标识可上传）。
///
/// 只记录桥接摄像头链路的终态事实与有限上下文：结果（自动唤醒/协助唤醒/
/// 失败/出流）、阶段、官方组件 dll_sha256 指纹、最近几条桥接日志。
/// 上传开关默认关闭；只有用户在隐私页显式开启后，事件才会上传 to
/// sohun 云（服务端白名单字段，见 community_server /v1/telemetry/batch）。
///
/// 字段在入库前统一经 SensitiveDataSanitizer（allowDeviceIdentity 模式）
/// 处理：打印机序列号与 dll_sha256 放行，令牌/LAN access code/TTCode/
/// 签名值/邮箱/IP/路径/trayUuid 等一律保留脱敏。
class CameraDiagnosticsTelemetry {
  CameraDiagnosticsTelemetry._();

  static const String eventName = 'camera.bridge';
  static const int _maxBacklog = 50;

  static TelemetryService? _telemetry;
  static final List<_PendingCameraEvent> _backlog = [];

  static void attachTelemetry(TelemetryService service) {
    _telemetry = service;
    final backlog = List<_PendingCameraEvent>.from(_backlog);
    _backlog.clear();
    for (final pending in backlog) {
      unawaited(_send(pending));
    }
  }

  static void detachForTesting() {
    _telemetry = null;
    _backlog.clear();
  }

  /// outcome：stream_started / failed / bridge_exited（resultCategory）。
  static Future<void> record({
    required String serial,
    String? model,
    required String outcome,
    String? stage,
    String? dllSha256,
    String? bridgeTail,
  }) async {
    final pending = _PendingCameraEvent(
      serial: serial,
      model: model,
      outcome: outcome,
      stage: stage,
      dllSha256: dllSha256,
      bridgeTail: bridgeTail,
    );
    final telemetry = _telemetry;
    if (telemetry == null) {
      if (_backlog.length < _maxBacklog) _backlog.add(pending);
      return;
    }
    await _send(pending);
  }

  static void recordDetached({
    required String serial,
    String? model,
    required String outcome,
    String? stage,
    String? dllSha256,
    String? bridgeTail,
  }) {
    unawaited(
      record(
        serial: serial,
        model: model,
        outcome: outcome,
        stage: stage,
        dllSha256: dllSha256,
        bridgeTail: bridgeTail,
      ),
    );
  }

  static Future<void> _send(_PendingCameraEvent pending) async {
    final telemetry = _telemetry;
    if (telemetry == null) return;
    String cleaned(String value) => SensitiveDataSanitizer.sanitize(
          value,
          allowDeviceIdentity: true,
        ).text;

    var tail = cleaned(pending.bridgeTail ?? '');
    if (tail.length > 3500) tail = tail.substring(tail.length - 3500);
    await telemetry.recordEvent(
      eventName: eventName,
      resultCategory: pending.outcome,
      // 字段已在上方用 allowDeviceIdentity 模式脱敏；关闭二次保守脱敏，
      // 避免 sanitizeMap 再次剥掉放行的序列号与 dll_sha256。
      sanitizeAttributes: false,
      attributes: {
        if (pending.serial.isNotEmpty)
          'printerSerial': cleaned(pending.serial).substring(
                0,
                cleaned(pending.serial).length > 120
                    ? 120
                    : cleaned(pending.serial).length,
              ),
        if (pending.model != null && pending.model!.isNotEmpty)
          'printerModel': cleaned(pending.model!).substring(
                0,
                cleaned(pending.model!).length > 120
                    ? 120
                    : cleaned(pending.model!).length,
              ),
        if (pending.stage != null && pending.stage!.isNotEmpty)
          'cameraStage': cleaned(pending.stage!).substring(
                0,
                cleaned(pending.stage!).length > 200
                    ? 200
                    : cleaned(pending.stage!).length,
              ),
        if (pending.dllSha256 != null && pending.dllSha256!.isNotEmpty)
          'dllSha256': cleaned(pending.dllSha256!),
        if (tail.isNotEmpty) 'bridgeTail': tail,
      },
    );
  }
}

class _PendingCameraEvent {
  const _PendingCameraEvent({
    required this.serial,
    required this.model,
    required this.outcome,
    required this.stage,
    required this.dllSha256,
    required this.bridgeTail,
  });

  final String serial;
  final String? model;
  final String outcome;
  final String? stage;
  final String? dllSha256;
  final String? bridgeTail;
}
