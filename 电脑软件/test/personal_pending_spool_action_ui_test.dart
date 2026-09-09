import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/features/printers/channel_slot.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:consumable_tracker_desktop/providers/spool_change_provider.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final awaitingSelection in [true, false]) {
    testWidgets(
      awaitingSelection
          ? 'continue after ordinary removal opens spool selection and preserves the pause'
          : 'continue after confirmed maintenance resumes the existing roll',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final id = await db.consumableDao.addConsumable(
          ConsumablesCompanion.insert(
            manufacturer: 'Test',
            model: 'PLA',
            remainingGrams: const Value(415),
          ),
        );
        final printerId = await db.printerDao.addPrinter(
          brand: '拓竹',
          model: 'P1S',
          channelCount: 1,
        );
        var printer = (await db.printerDao.getByIdWithChannels(printerId))!;
        final channelId = printer.channels.single.channel.id;
        await db.printerDao.bindConsumable(channelId, id);
        if (awaitingSelection) {
          await db.printerDao.preparePersonalSpoolReplacement(
            channelId,
            expectedConsumableId: id,
          );
        } else {
          await db.printerDao.pauseChannelRollForMaintenance(channelId);
        }
        printer = (await db.printerDao.getByIdWithChannels(printerId))!;
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            personalInventoryAccountScopeProvider.overrideWithValue(
              const PersonalInventoryAccountScope(
                enforce: false,
                ownerAccount: null,
              ),
            ),
            activePrinterConfigProvider.overrideWithValue(null),
            activePrinterConnectionProvider.overrideWith(
              (ref) => _QuietConnection(),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: ChannelSlot(
                  data: printer.channels.single,
                  printerId: printerId,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('继续使用'));
        await tester.pumpAndSettle();
        final queue = container.read(spoolChangeQueueProvider);
        expect(queue, awaitingSelection ? hasLength(1) : isEmpty);
        if (awaitingSelection) {
          expect(queue.single.isManual, isTrue);
          expect(queue.single.printerId, printerId);
        }
        final current = (await db.printerDao.getByIdWithChannels(
          printerId,
        ))!.channels.single;
        expect(
          current.rollHoldState,
          awaitingSelection
              ? ChannelRollHoldState.awaitingSelection
              : ChannelRollHoldState.loaded,
        );
        expect(current.consumable!.id, id);
        expect(current.consumable!.remainingGrams, 415);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}

class _QuietConnection extends StateNotifier<ActivePrinterState>
    implements ActivePrinterConnectionNotifier {
  _QuietConnection() : super(const ActivePrinterState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
