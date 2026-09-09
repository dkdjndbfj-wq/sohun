import 'package:flutter_test/flutter_test.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_alerts.dart';

BambuPrinterStatus status({
  BambuGcodeState state = BambuGcodeState.running,
  String? reason,
}) =>
    BambuPrinterStatus(
      serial: 'TEST',
      gcodeState: state,
      failReason: reason,
    );

void main() {
  test('preserves raw device text without inventing official advice', () {
    final alerts = buildPrinterAlerts(status(reason: 'filament runout'));
    expect(alerts.first.code, 'raw_reason');
    expect(alerts.first.message, 'filament runout');
    expect(alerts.first.source, 'device-report');
  });

  test('keeps unsupported unstructured reasons visible', () {
    expect(
      buildPrinterAlerts(status(reason: 'nozzle clogged')).first.code,
      'raw_reason',
    );
    expect(
      buildPrinterAlerts(status(reason: 'door open')).first.code,
      'raw_reason',
    );
    expect(
      buildPrinterAlerts(status(reason: 'heating failed')).first.code,
      'raw_reason',
    );
  });

  test('adds pause and offline state alerts', () {
    expect(
      buildPrinterAlerts(status(state: BambuGcodeState.pause)),
      isNotEmpty,
    );
    expect(
      buildPrinterAlerts(status(state: BambuGcodeState.offline)).first.code,
      'offline',
    );
  });

  test('falls back to raw reason for unknown failures', () {
    final alerts = buildPrinterAlerts(
      status(state: BambuGcodeState.failed, reason: 'HMS 0700-1234'),
    );
    expect(alerts.first.title, '打印失败');
    expect(alerts.first.message, contains('HMS 0700-1234'));
  });

  test('keeps an unknown diagnostic visible while printing', () {
    final alerts = buildPrinterAlerts(status(reason: 'HMS 0700-9999'));
    expect(alerts.first.code, 'raw_reason');
    expect(alerts.first.message, contains('HMS 0700-9999'));
  });

  test('parses MQTT failure diagnostics', () {
    final parsed = BambuPrinterStatus.fromMqttJson(
      {
        'print': {
          'gcode_state': 'FAILED',
          'fail_reason': 'filament runout',
        },
      },
      serial: 'TEST',
    );
    expect(parsed, isNotNull);
    expect(buildPrinterAlerts(parsed!).first.code, 'failed_raw');
  });

  test('normal running status has no alert', () {
    expect(buildPrinterAlerts(status()), isEmpty);
  });
}
