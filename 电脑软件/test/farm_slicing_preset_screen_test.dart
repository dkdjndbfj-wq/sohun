import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_slicing_preset_screen.dart';
import 'package:consumable_tracker_desktop/providers/farm_slicing_preset_provider.dart';
import 'package:consumable_tracker_desktop/providers/studio_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('卡片由当前连接机型喷嘴生成并在卡片内按导入时间滚动', (tester) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final presets = <FarmSlicingPreset>[
      _preset('高质量', 1),
      _preset('有支撑', 2),
      for (var index = 3; index <= 8; index++) _preset('方案 $index', index),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fleetPrinterStatesProvider.overrideWithValue([
            _fleet('A1-1', 'Bambu Lab A1', .4),
            _fleet('A1-2', 'A1', .4),
            _fleet('A1-06', 'A1', .6),
            _fleet(
              'P1S-1',
              'P1S',
              .4,
              connectionState: PrinterConnectionState.disconnected,
            ),
          ]),
          farmSlicingPresetsProvider.overrideWith(
            (ref) => _PresetNotifier(presets),
          ),
          currentFarmPermissionProvider.overrideWith((ref, code) => true),
        ],
        child: const MaterialApp(
          home: Scaffold(body: FarmSlicingPresetScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('A1'), findsNWidgets(2));
    expect(find.text('0.4 mm 喷嘴 · 2 台已连接'), findsOneWidget);
    expect(find.text('0.6 mm 喷嘴 · 1 台已连接'), findsOneWidget);
    expect(find.text('P1S'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '导入'), findsNWidgets(2));
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('高质量'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.text('有支撑'), findsOneWidget);
    expect(find.byType(Scrollbar), findsOneWidget);
    expect(tester.getSize(find.byType(Card).first).height, 390);

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(ListView)),
        scrollDelta: const Offset(0, 280),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('方案 8'), findsOneWidget);

    tester.view.physicalSize = const Size(760, 700);
    await tester.pumpAndSettle();
    expect(find.text('A1'), findsNWidgets(2));
    expect(find.widgetWithText(OutlinedButton, '导入'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有已连接且规格完整的设备时不允许从全局导入', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fleetPrinterStatesProvider.overrideWithValue(const []),
          currentFarmPermissionProvider.overrideWith((ref, code) => true),
        ],
        child: const MaterialApp(
          home: Scaffold(body: FarmSlicingPresetScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前没有规格完整的已连接打印机'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '导入'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _PresetNotifier extends FarmSlicingPresetsNotifier {
  _PresetNotifier(List<FarmSlicingPreset> presets)
      : super(supportDirectory: () async => Directory.systemTemp) {
    state = presets;
  }
}

FarmSlicingPreset _preset(String name, int order) => FarmSlicingPreset(
      id: 'preset-$order',
      name: name,
      modelKey: 'a1',
      displayModel: 'A1',
      nozzleDiameter: .4,
      machineSettingsPath: 'C:/managed/$order/machine.json',
      processSettingsPath: 'C:/managed/$order/process.json',
      filamentSettingsPaths: const [],
      machineConfigName: 'Bambu Lab A1 0.4 nozzle',
      processConfigName: '0.20mm Standard @BBL A1',
      filamentConfigNames: const [],
      fingerprint: 'fingerprint-$order',
      createdAt: DateTime(2026, 8, order),
    );

FleetPrinterState _fleet(
  String serial,
  String model,
  double nozzle, {
  PrinterConnectionState connectionState = PrinterConnectionState.connected,
}) =>
    FleetPrinterState(
      serial: serial,
      displayLabel: serial,
      connectionState: connectionState,
      lastStatus: null,
      statusUpdatedAt: DateTime(2026, 8, 6),
      isLanCapable: true,
      mode: BambuConnectionMode.lan,
      reportedModel: model,
      installedNozzleDiameter: nozzle,
      isConnecting: false,
    );
