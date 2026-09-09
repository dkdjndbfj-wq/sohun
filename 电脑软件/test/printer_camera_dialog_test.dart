import 'dart:async';
import 'dart:typed_data';

import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/core/services/studio_video_relay_service.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/features/printers/printer_card.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCameraSession implements FarmCameraPreviewSession {
  final StreamController<Uint8List> controller =
      StreamController<Uint8List>.broadcast();
  int disposeCount = 0;

  @override
  Stream<Uint8List> get frames => controller.stream;

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    if (!controller.isClosed) await controller.close();
  }
}

PrinterWithChannels _printer(int id, String name, String serial) {
  final now = DateTime(2026, 1, 1);
  return PrinterWithChannels(
    Printer(
      id: id,
      uid: 'uid-$id',
      name: name,
      brand: 'Bambu Lab',
      model: 'A1',
      channelCount: 0,
      isCustomImage: false,
      createdAt: now,
      updatedAt: now,
    ),
    const <ChannelWithConsumable>[],
    serial: serial,
  );
}

void main() {
  testWidgets('个人版摄像头按钮只打开对应打印机的画面', (tester) async {
    final first = _printer(1, '一号机', 'SERIAL-ONE');
    final second = _printer(2, '二号机', 'SERIAL-TWO');
    final firstConfig = PrinterConnectionConfig.cloud(
      serial: 'SERIAL-ONE',
      devProductName: 'A1',
    );
    final secondConfig = PrinterConnectionConfig.cloud(
      serial: 'SERIAL-TWO',
      devProductName: 'A1',
    );
    final session = _FakeCameraSession();
    String? connectedSerial;
    Future<FarmCameraPreviewSession> connector({
      required PrinterConnectionConfig config,
      required String model,
    }) async {
      connectedSerial = config.serial;
      return session;
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mergedPrinterListProvider
              .overrideWithValue([firstConfig, secondConfig]),
          fleetPrinterStatesProvider
              .overrideWithValue(const <FleetPrinterState>[]),
          farmCameraPreviewConnectorProvider.overrideWithValue(connector),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                PrinterCard(data: first),
                PrinterCard(data: second),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('查看摄像头'), findsNWidgets(2));
    await tester.tap(find.byTooltip('查看摄像头').first);
    await tester.pump();
    await tester.pump();

    expect(connectedSerial, 'SERIAL-ONE');
    final dialog = find.byKey(
      const ValueKey('printer-camera-preview-dialog'),
    );
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('一号机')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('二号机')),
      findsNothing,
    );

    await tester.tap(find.byTooltip('关闭实时画面'));
    await tester.pumpAndSettle();
    expect(session.disposeCount, 1);
    expect(tester.takeException(), isNull);
  });
}
