import '../../../core/services/printer_fault_service.dart';
import 'bambu_printer_models.dart';
import 'bambu_fault_codes.dart';

enum PrinterAlertSeverity { info, warning, error }

class PrinterAlert {
  final PrinterAlertSeverity severity;
  final String title;
  final String message;
  final String? code;
  final List<String> steps;
  final String? resumeCondition;
  final String? safetyNotice;
  final String kind;
  final String source;
  final String? sourceVersion;
  final Uri? helpUrl;

  const PrinterAlert({
    required this.severity,
    required this.title,
    required this.message,
    this.code,
    this.steps = const [],
    this.resumeCondition,
    this.safetyNotice,
    this.kind = 'device_state',
    this.source = 'device-report',
    this.sourceVersion,
    this.helpUrl,
  });
}

/// Converts Bambu printer state and diagnostics into short, user-facing alerts.
/// The raw reason is retained as a fallback so new firmware errors are visible.
List<PrinterAlert> buildPrinterAlerts(
  BambuPrinterStatus status, {
  PrinterFaultService? knowledgeBase,
}) {
  final alerts = <PrinterAlert>[];
  final structuredCodes = <String>{};
  final reason = status.failReason?.trim() ?? '';

  void addStructured(String code, String severity) {
    final normalizedCode = normalizeBambuFaultCode(code);
    if (normalizedCode.isEmpty || !structuredCodes.add(normalizedCode)) return;
    final entry = knowledgeBase?.lookupByCode(
      normalizedCode,
      serial: status.serial,
    );
    if (entry?.isInternal == true) return;
    alerts.add(
      PrinterAlert(
        severity: _severityFromText(entry?.severity ?? severity),
        title: entry?.title ?? '打印机报告故障',
        message: entry?.summary ?? '暂未识别此设备状态码，请记录代码并以打印机屏幕提示为准。',
        code: normalizedCode,
        steps: entry?.steps ?? const [],
        resumeCondition: entry?.resumeCondition,
        safetyNotice: entry?.safetyNotice,
        kind: normalizedCode.length == 16 ? 'hms' : 'print_error',
        source: entry?.source ?? 'device-report',
        sourceVersion: knowledgeBase?.versionFor(status.serial),
        helpUrl: bambuFaultHelpUri(
          normalizedCode,
          deviceType: PrinterFaultService.deviceTypeFor(status.serial),
        ),
      ),
    );
  }

  for (final hms in status.hmsAlerts ?? const <PrinterHmsAlert>[]) {
    addStructured(hms.code, hms.severity);
  }
  if (status.printError?.trim().isNotEmpty == true) {
    addStructured(status.printError!, 'error');
  }

  switch (status.gcodeState) {
    case BambuGcodeState.failed:
      if (alerts.isEmpty) {
        alerts.add(
          PrinterAlert(
            severity: PrinterAlertSeverity.error,
            title: '打印失败',
            message: reason.isEmpty
                ? '打印机报告打印失败，请查看打印机屏幕或拓竹切片软件中的错误详情。'
                : '打印机报告异常：${_cleanReason(reason)}',
            code: reason.isEmpty ? 'failed' : 'failed_raw',
          ),
        );
      }
      break;
    case BambuGcodeState.pause:
      alerts.add(
        PrinterAlert(
          severity: PrinterAlertSeverity.info,
          title: '打印已暂停',
          message: alerts.isEmpty ? '请检查打印机屏幕，确认原因后恢复打印。' : '打印机已暂停，请按设备提示检查。',
          code: 'paused',
        ),
      );
      break;
    case BambuGcodeState.offline:
      alerts.add(
        const PrinterAlert(
          severity: PrinterAlertSeverity.warning,
          title: '打印机暂时离线',
          message: '暂时无法获取实时状态，网络恢复后会自动更新。',
          code: 'offline',
        ),
      );
      break;
    default:
      break;
  }

  // Firmware occasionally reports a diagnostic while keeping gcode_state=RUNNING.
  // Keep that information visible instead of silently dropping an unknown reason.
  if (reason.isNotEmpty &&
      reason != '0' &&
      alerts.every((a) => a.code == 'paused' || a.code == 'offline')) {
    alerts.insert(
      0,
      PrinterAlert(
        severity: PrinterAlertSeverity.warning,
        title: '打印机报告异常',
        message: _cleanReason(reason),
        code: 'raw_reason',
      ),
    );
  }

  return alerts;
}

PrinterAlertSeverity _severityFromText(String value) {
  return switch (value.toLowerCase()) {
    'error' => PrinterAlertSeverity.error,
    'info' => PrinterAlertSeverity.info,
    _ => PrinterAlertSeverity.warning,
  };
}

String _cleanReason(String reason) {
  final cleaned = reason.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.length <= 180) return cleaned;
  return '${cleaned.substring(0, 177)}...';
}
