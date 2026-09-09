import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/features/printers/printers_screen.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';

void main() {
  testWidgets('打印机工作室只通过设备台卡片选择真实设备', (tester) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime(2026, 7, 31);
    PrinterWithChannels printer(int id, String name) => PrinterWithChannels(
          Printer(
            id: id,
            uid: 'printer-$id',
            name: name,
            brand: 'Bambu Lab',
            model: id == 1 ? 'X1 Carbon' : 'P1S',
            channelCount: 0,
            isCustomImage: false,
            createdAt: now,
            updatedAt: now,
          ),
          const <ChannelWithConsumable>[],
        );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value([
              printer(1, '一号工作台'),
              printer(2, '二号工作台'),
            ]),
          ),
        ],
        child: const MaterialApp(
          home: InteractionEffectsScope(
            enabled: false,
            child: PrintersScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('studio-printer-1')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('previous-printer-button')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('next-printer-button')), findsNothing);
    expect(find.byKey(const ValueKey('printer-stage-navigator')), findsNothing);

    await tester.tap(find.text('二号工作台'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('studio-printer-2')), findsOneWidget);
    expect(find.text('二号工作台'), findsWidgets);
  });
}
