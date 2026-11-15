import 'package:consumable_tracker_desktop/core/services/cluster_planning_service.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_observation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cluster_screen_test.dart' as fixtures;

void main() {
  final now = DateTime(2026, 11, 11, 16);
  ClusterPrinter printer({
    DateTime? observedAt,
    BambuGcodeState state = BambuGcodeState.running,
    PrinterConnectionState connection = PrinterConnectionState.connected,
    int? percent = 35,
    List<String> blockers = const [],
  }) => ClusterPrinter(
    source: fixtures.fixture().printers.first.source,
    state: FleetPrinterState(
      serial: 'test',
      displayLabel: '设备',
      connectionState: connection,
      lastStatus: BambuPrinterStatus(
        serial: 'test',
        gcodeState: state,
        mcPercent: percent,
      ),
      statusUpdatedAt: observedAt ?? now,
      isLanCapable: true,
      mode: BambuConnectionMode.lan,
      reportedModel: 'P1S',
      installedNozzleDiameter: .4,
      isConnecting: false,
    ),
    activeQueueCount: 1,
    availableAfterSeconds: null,
    blockers: blockers,
  );

  test('missing telemetry is unknown, never connected or healthy', () {
    final result = ClusterDeviceObservation.from(
      fixtures.fixture().printers.first,
      now: now,
    );
    expect(result.label, '状态未知');
    expect(result.needsAttention, isTrue);
    expect(result.printing, isFalse);
    expect(result.progress, isNull);
  });

  test('fresh running evidence supplies progress but is not a score', () {
    final result = ClusterDeviceObservation.from(printer(), now: now);
    expect(result.label, '打印中');
    expect(result.progress, .35);
    expect(result.printing, isTrue);
    expect(result.fresh, isTrue);
  });

  test(
    'stale, future and disconnected observations never imply live printing',
    () {
      for (final device in [
        printer(observedAt: now.subtract(const Duration(hours: 1))),
        printer(observedAt: now.add(const Duration(minutes: 1))),
        printer(connection: PrinterConnectionState.disconnected),
      ]) {
        final result = ClusterDeviceObservation.from(device, now: now);
        expect(result.needsAttention, isTrue);
        expect(result.printing, isFalse);
        expect(result.progress, isNull);
      }
    },
  );

  test(
    'finished never claims cleared bed and fault blockers remain visible',
    () {
      final result = ClusterDeviceObservation.from(
        printer(state: BambuGcodeState.finish, blockers: ['待核对']),
        now: now,
      );
      expect(result.label, '打印结束');
      expect(result.needsAttention, isTrue);
      expect(result.progress, isNull);
    },
  );

  test('invalid progress is unknown, not clipped into a convincing value', () {
    for (final percent in [-1, 101]) {
      expect(
        ClusterDeviceObservation.from(
          printer(percent: percent),
          now: now,
        ).progress,
        isNull,
      );
    }
  });

  test(
    'machine delay distinguishes zero, missing and positive lower bound',
    () {
      expect(clusterMachineWait(null), '机器等待未知');
      expect(clusterMachineWait(-1), '机器等待未知');
      expect(clusterMachineWait(0), '机器等待 0 分');
      expect(clusterMachineWait(600), '机器等待 ≥10 分');
      expect(clusterDuration(0), '—');
    },
  );
}
