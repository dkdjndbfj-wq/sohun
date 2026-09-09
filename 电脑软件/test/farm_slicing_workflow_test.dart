import 'package:flutter_test/flutter_test.dart';

import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_slicing_workflow.dart';

void main() {
  test('实体打印机精确机型和喷嘴会成为切片目标', () {
    final candidate = _candidate(id: 1, model: 'A1', nozzle: .4);

    final target = requireFarmSlicingTarget([candidate]);

    expect(target.model, 'A1');
    expect(target.nozzleDiameter, .4);
    expect(target.printerLabels, ['设备 1']);
  });

  test('喷嘴未知时不能用默认 0.4 猜测后切片', () {
    final candidate = _candidate(id: 1, model: 'A1', nozzle: null);

    expect(
      () => requireFarmSlicingTarget([candidate]),
      throwsA(
        isA<FarmSlicingWorkflowException>().having(
          (error) => error.message,
          'message',
          contains('喷嘴直径未知'),
        ),
      ),
    );
  });

  test('同一盘选择不同喷嘴的打印机时拒绝共用一次切片', () {
    final first = _candidate(id: 1, model: 'A1', nozzle: .4);
    final second = _candidate(id: 2, model: 'A1', nozzle: .6);

    expect(
      () => requireFarmSlicingTarget([first, second]),
      throwsA(
        isA<FarmSlicingWorkflowException>().having(
          (error) => error.message,
          'message',
          contains('相同机型和喷嘴'),
        ),
      ),
    );
  });

  test('同一盘选择不同精确机型时拒绝共用一次切片', () {
    final first = _candidate(id: 1, model: 'A1', nozzle: .4);
    final second = _candidate(id: 2, model: 'A1 mini', nozzle: .4);

    expect(
      () => requireFarmSlicingTarget([first, second]),
      throwsA(isA<FarmSlicingWorkflowException>()),
    );
  });
}

FarmSlicingPrinterCandidate _candidate({
  required int id,
  required String model,
  required double? nozzle,
}) {
  final now = DateTime(2026, 8, 6);
  final serial = 'SERIAL-$id';
  final printer = PrinterWithChannels(
    Printer(
      id: id,
      uid: 'printer-$id',
      name: '设备 $id',
      brand: 'Bambu Lab',
      model: model,
      channelCount: 1,
      isCustomImage: false,
      createdAt: now,
      updatedAt: now,
    ),
    const [],
    serial: serial,
  );
  final state = FleetPrinterState(
    serial: serial,
    displayLabel: '设备 $id',
    connectionState: PrinterConnectionState.connected,
    lastStatus: null,
    statusUpdatedAt: now,
    isLanCapable: true,
    mode: BambuConnectionMode.lan,
    reportedModel: model,
    installedNozzleDiameter: nozzle,
    isConnecting: false,
  );
  return FarmSlicingPrinterCandidate(printer: printer, state: state);
}
