import 'package:consumable_tracker_desktop/core/services/spool_change_detector.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/features/print_task/spool_change_confirmation_dialog.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/filament_cost_provider.dart';
import 'package:consumable_tracker_desktop/providers/spool_change_provider.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('handles a multi-AMS replacement batch without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(560, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final printerId = await db
        .into(db.printers)
        .insert(
          PrintersCompanion.insert(
            name: const Value('生产车间超长名称打印机'),
            brand: '拓竹',
            model: 'P1S',
            channelCount: const Value(2),
          ),
        );
    await db.customUpdate(
      'UPDATE printers SET serial = ? WHERE id = ?',
      variables: [const Variable('P1-LONG'), Variable(printerId)],
    );
    final oldId = await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'Bambu Lab',
        model: 'PLA Basic',
        materialType: const Value('PLA'),
        remainingGrams: const Value(620),
      ),
    );
    final newId = await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'Bambu Lab',
        model: 'GFA00',
        materialType: const Value('PLA'),
        colorHex: const Value('#00AAFF'),
        colorName: const Value('极光蓝'),
      ),
    );
    await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'eSUN',
        model: 'PETG-HS',
        materialType: const Value('PETG'),
        colorHex: const Value('#FF6600'),
        colorName: const Value('活力橙'),
      ),
    );
    await db
        .into(db.printerChannels)
        .insert(
          PrinterChannelsCompanion.insert(
            printerId: printerId,
            channelIndex: 0,
            label: const Value('A1'),
            consumableId: Value(oldId),
          ),
        );
    await db
        .into(db.printerChannels)
        .insert(
          PrinterChannelsCompanion.insert(
            printerId: printerId,
            channelIndex: 6,
            label: const Value('B3'),
          ),
        );

    final queue = SpoolChangeQueueNotifier();
    final now = DateTime(2026, 8, 2, 15);
    queue.enqueueAll([
      SpoolChangeObservation(
        printerSerial: 'P1-LONG',
        printerLabel: '生产车间超长名称打印机',
        printerId: printerId,
        channelIndex: 0,
        previous: const AmsTray(
          amsId: 0,
          slot: 0,
          trayUuid: 'old-rfid',
          trayInfoIdx: 'GFA00',
          traySubBrands: 'Bambu Lab',
          trayWeight: 1000,
          remain: 62,
          hasFilament: true,
        ),
        current: const AmsTray(
          amsId: 0,
          slot: 0,
          trayInfoIdx: 'GFA00',
          trayType: 'PLA',
          trayColor: '00AAFFFF',
          trayWeight: 1000,
          remain: 100,
          trayTag: 'thirdparty',
          hasFilament: true,
        ),
        detectedAt: now,
        amsOrdinal: 1,
        amsType: AmsUnitType.ams,
      ),
      SpoolChangeObservation(
        printerSerial: 'P1-LONG',
        printerLabel: '生产车间超长名称打印机',
        printerId: printerId,
        channelIndex: 6,
        previous: const AmsTray(
          amsId: 1,
          slot: 2,
          trayTag: 'thirdparty',
          hasFilament: true,
        ),
        current: const AmsTray(
          amsId: 1,
          slot: 2,
          trayType: 'PETG',
          trayColor: 'FF6600FF',
          trayTag: 'thirdparty',
          hasFilament: true,
        ),
        detectedAt: now.add(const Duration(seconds: 4)),
        amsOrdinal: 2,
        amsType: AmsUnitType.ams2Pro,
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          spoolChangeQueueProvider.overrideWith((ref) => queue),
          filamentCostConfigsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SpoolChangeConfirmationDialog()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('发现多卷耗材变化'), findsOneWidget);
    expect(find.textContaining('第 1 台 AMS 1 · 第 1 通道'), findsWidgets);
    expect(find.textContaining('第 2 台 AMS 2 Pro · 第 3 通道'), findsOneWidget);
    expect(find.textContaining('极光蓝'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(SpoolChangeConfirmationDialog),
      matchesGoldenFile('goldens/spool_change_confirmation_dialog.png'),
    );

    await tester.tap(
      find.byKey(const ValueKey('choose-spool-change-consumable')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('spool-change-consumable-picker')),
      findsOneWidget,
    );
    expect(find.text('选择本次装入的耗材卷'), findsWidgets);
    expect(
      find.textContaining('生产车间超长名称打印机 · 第 1 台 AMS 1 · 第 1 通道'),
      findsWidgets,
    );
    expect(find.text('Bambu Lab'), findsWidgets);
    expect(find.text('eSUN'), findsWidgets);
    await expectLater(
      find.byKey(const ValueKey('spool-change-consumable-picker')),
      matchesGoldenFile('goldens/spool_change_consumable_picker_dialog.png'),
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('确认绑定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(queue.state, hasLength(1));
    expect(queue.state.single.channelIndex, 6);
    expect(find.textContaining('第 2 台 AMS 2 Pro · 第 3 通道'), findsWidgets);
    expect(await db.printerDao.getConsumableIdByChannel(printerId, 0), newId);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'detected CUID insertion can continue the bound partial spool without resetting grams',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(620, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final printerId = await db
          .into(db.printers)
          .insert(
            PrintersCompanion.insert(
              name: const Value('余料测试机'),
              brand: '拓竹',
              model: 'P1S',
              channelCount: const Value(1),
            ),
          );
      await db.customUpdate(
        'UPDATE printers SET serial = ? WHERE id = ?',
        variables: [const Variable('P1-REMNANT'), Variable(printerId)],
      );
      final spoolId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          uid: const Value('partial-cuid-roll'),
          manufacturer: 'eSUN',
          model: 'PLA+',
          materialType: const Value('PLA'),
          colorHex: const Value('#2244CC'),
          colorName: const Value('星空蓝'),
          totalGrams: const Value(1000),
          remainingGrams: const Value(415),
        ),
      );
      await db.consumableDao.setRfidSpoolBinding(
        spoolId,
        tagUid: 'D021B75E',
        tagType: 'CUID',
        cycle: 1,
        status: 'active',
      );
      final channelId = await db
          .into(db.printerChannels)
          .insert(
            PrinterChannelsCompanion.insert(
              printerId: printerId,
              channelIndex: 0,
              consumableId: Value(spoolId),
              loadedRemainingGrams: const Value(415),
            ),
          );
      await db.printerDao.pauseChannelRollForMaintenance(channelId);

      final queue = SpoolChangeQueueNotifier();
      queue.enqueue(
        SpoolChangeObservation(
          printerSerial: 'P1-REMNANT',
          printerLabel: '余料测试机',
          printerId: printerId,
          channelIndex: 0,
          previous: const AmsTray(
            amsId: 0,
            slot: 0,
            tagUid: 'D021B75E00000100',
            hasFilament: true,
          ),
          current: const AmsTray(
            amsId: 0,
            slot: 0,
            tagUid: 'D021B75E00000100',
            trayUuid: '11111111222233334444555555555555',
            traySubBrands: 'Bambu Lab',
            trayType: 'PLA',
            trayInfoIdx: 'GFA00',
            trayColor: '2244CCFF',
            trayWeight: 1000,
            remain: 8,
            hasFilament: true,
          ),
          detectedAt: DateTime(2026, 9, 9, 12),
          requiresRfidConfirmation: true,
          rfidCandidateIds: [spoolId],
          rfidCandidateUids: {spoolId: 'D021B75E'},
          rfidCandidateInventoryUids: {spoolId: 'partial-cuid-roll'},
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            spoolChangeQueueProvider.overrideWith((ref) => queue),
            filamentCostConfigsProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SpoolChangeConfirmationDialog()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('检测到耗材装入'), findsOneWidget);
      expect(find.textContaining('继续当前余料卷'), findsOneWidget);
      expect(find.textContaining('415g'), findsWidgets);

      await tester.tap(
        find.byKey(const ValueKey('spool-change-continue-current-remnant')),
      );
      await tester.pumpAndSettle();

      final channel = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single;
      expect(queue.state, isEmpty);
      expect(channel.channel.consumableId, spoolId);
      expect(channel.farmRollPaused, isFalse);
      expect(channel.consumable!.remainingGrams, 415);
      expect((await db.select(db.consumables).get()), hasLength(1));
      expect(await db.select(db.usageLogs).get(), isEmpty);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
