import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_auto_eject_gcode_screen.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:consumable_tracker_desktop/providers/studio_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('机型页只保存脚本模板，不再提供全局启用开关', (tester) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime(2026, 8, 5);
    final printer = PrinterWithChannels(
      Printer(
        id: 1,
        uid: 'printer-a1',
        name: 'A1 生产机',
        brand: 'Bambu Lab',
        model: 'Bambu Lab A1',
        channelCount: 1,
        isCustomImage: false,
        createdAt: now,
        updatedAt: now,
      ),
      const [],
      serial: 'A1-TEST',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value([printer]),
          ),
          currentFarmPermissionProvider.overrideWith((ref, code) => true),
        ],
        child: const MaterialApp(
          home: Scaffold(body: FarmAutoEjectGcodeScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未配置'), findsOneWidget);
    expect(find.text('此机型启用自动取件'), findsNothing);

    await tester.tap(find.text('配置脚本'));
    await tester.pumpAndSettle();

    expect(find.text('此机型启用自动取件'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(
      find.textContaining('保存不等于启用'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'G1 X10 Y220 F6000');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('脚本已保存'), findsOneWidget);
    expect(find.text('已启用'), findsNothing);
    expect(find.text('此机型启用自动取件'), findsNothing);
    expect(tester.takeException(), null);
  });
}
