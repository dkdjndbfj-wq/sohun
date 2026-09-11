import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/features/printers/channel_slot.dart';
import 'package:consumable_tracker_desktop/features/print_task/spool_change_confirmation_dialog.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:consumable_tracker_desktop/providers/spool_change_provider.dart';
import 'package:consumable_tracker_desktop/core/services/spool_change_detector.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final awaitingSelection in [true, false]) {
    for (final grams in [415.0, 31.0, 30.0, 0.0]) {
      testWidgets(
        '${awaitingSelection ? 'ordinary removal' : 'maintenance'}: $grams g preserves stock and routes the continuation correctly',
        (tester) async {
          final fixture = await _Fixture.create(
            tester,
            grams: grams,
            awaitingSelection: awaitingSelection,
          );
          try {
            await fixture.mount(
              tester,
              ChannelSlot(data: fixture.channel, printerId: fixture.printerId),
            );
            final reusable = grams > 30;
            expect(find.text('继续使用'), reusable ? findsOneWidget : findsNothing);
            expect(
              find.text('选择其他卷'),
              reusable ? findsNothing : findsOneWidget,
            );
            if (reusable) {
              await tester.runAsync(() async {
                await tester.tap(find.text('继续使用'));
                await _waitFor(
                  () async => awaitingSelection
                      ? fixture.container
                            .read(spoolChangeQueueProvider)
                            .isNotEmpty
                      : (await fixture.readChannel()).rollHoldState ==
                            ChannelRollHoldState.loaded,
                );
              });
              await tester.pumpAndSettle();
            } else {
              await tester.runAsync(() async {
                await tester.tap(find.text('选择其他卷'));
                await _waitFor(
                  () async => fixture.container
                      .read(spoolChangeQueueProvider)
                      .isNotEmpty,
                );
              });
              await tester.pumpAndSettle();
            }
            final queue = fixture.container.read(spoolChangeQueueProvider);
            expect(
              queue,
              !reusable || awaitingSelection ? hasLength(1) : isEmpty,
            );
            if (queue.isNotEmpty) {
              expect(queue.single.isManual, isTrue);
              expect(queue.single.printerId, fixture.printerId);
            }
            final current = await tester.runAsync(fixture.readChannel);
            expect(
              current!.rollHoldState,
              reusable && !awaitingSelection
                  ? ChannelRollHoldState.loaded
                  : awaitingSelection
                  ? ChannelRollHoldState.awaitingSelection
                  : ChannelRollHoldState.maintenance,
            );
            expect(current.consumable!.remainingGrams, grams);
            expect(current.consumable!.totalGrams, 1000);
            expect(tester.takeException(), isNull);
          } finally {
            await fixture.close(tester);
          }
        },
      );
    }
  }

  for (final grams in [31.0, 30.0, 0.0]) {
    testWidgets(
      'explicit current-spool choice respects the $grams g boundary',
      (tester) async {
        final fixture = await _Fixture.create(
          tester,
          grams: grams,
          awaitingSelection: true,
        );
        try {
          fixture.container
              .read(spoolChangeQueueProvider.notifier)
              .enqueue(
                SpoolChangeObservation.manualEvent(
                  printerSerial: 'local-printer-${fixture.printerId}',
                  printerLabel: 'Test printer',
                  printerId: fixture.printerId,
                  channelIndex: fixture.channel.channel.channelIndex,
                ),
              );
          await fixture.mount(tester, const SpoolChangeConfirmationDialog());
          // Drift queries run outside the widget test's fake clock.
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 40));
          });
          await tester.pumpAndSettle();
          final continueButton = find.byKey(
            const ValueKey('spool-change-continue-current-remnant'),
          );
          expect(continueButton, grams > 30 ? findsOneWidget : findsNothing);
          if (grams > 30) {
            await tester.runAsync(() async {
              await tester.tap(continueButton);
              await _waitFor(
                () async =>
                    fixture.container.read(spoolChangeQueueProvider).isEmpty,
              );
            });
            await tester.pumpAndSettle();
          }
          final current = await tester.runAsync(fixture.readChannel);
          expect(
            current!.rollHoldState,
            grams > 30
                ? ChannelRollHoldState.loaded
                : ChannelRollHoldState.awaitingSelection,
          );
          expect(current.consumable!.remainingGrams, grams);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close(tester);
        }
      },
    );
  }

  testWidgets(
    'account switch while removal dialog is open cannot pause the old account spool',
    (tester) async {
      final fixture = await _Fixture.create(
        tester,
        grams: 415,
        awaitingSelection: false,
        paused: false,
      );
      try {
        await fixture.mount(
          tester,
          ChannelSlot(data: fixture.channel, printerId: fixture.printerId),
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('取下'));
          await Future<void>.delayed(const Duration(milliseconds: 40));
        });
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('personal-spool-removal-maintenance')),
          findsOneWidget,
        );
        fixture.container.updateOverrides(
          fixture.overrides(
            const PersonalInventoryAccountScope(
              enforce: true,
              ownerAccount: 'changed-owner',
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('personal-spool-removal-maintenance')),
        );
        await tester.pumpAndSettle();
        final current = await tester.runAsync(fixture.readChannel);
        expect(current!.rollHoldState, ChannelRollHoldState.loaded);
        expect(current.consumable!.remainingGrams, 415);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.close(tester);
      }
    },
  );
}

class _Fixture {
  _Fixture(this.db, this.printerId, this.channel);

  final AppDatabase db;
  final int printerId;
  final ChannelWithConsumable channel;
  late final ProviderContainer container = ProviderContainer(
    overrides: overrides(
      const PersonalInventoryAccountScope(enforce: false, ownerAccount: ''),
    ),
  );

  List<Override> overrides(PersonalInventoryAccountScope scope) => [
    databaseProvider.overrideWithValue(db),
    personalInventoryAccountScopeProvider.overrideWithValue(scope),
    consumablesProvider.overrideWith(
      (ref) => Stream.value([channel.consumable!]),
    ),
    personalIndividualSpoolIdsProvider.overrideWithValue({
      channel.consumable!.id,
    }),
    activePrinterConfigProvider.overrideWithValue(null),
    activePrinterConnectionProvider.overrideWith((ref) => _QuietConnection()),
  ];

  static Future<_Fixture> create(
    WidgetTester tester, {
    required double grams,
    required bool awaitingSelection,
    bool paused = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    return (await tester.runAsync(() async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
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
      final printer = (await db.printerDao.getByIdWithChannels(printerId))!;
      final channelId = printer.channels.single.channel.id;
      await db.printerDao.bindConsumable(channelId, id);
      if (paused) {
        if (awaitingSelection) {
          await db.printerDao.preparePersonalSpoolReplacement(
            channelId,
            expectedConsumableId: id,
          );
        } else {
          await db.printerDao.pauseChannelRollForMaintenance(channelId);
        }
      }
      // Consumption can reach zero while a retained spool is paused. No
      // continuation action may erase or refill that recorded balance.
      await (db.update(db.consumables)..where((row) => row.id.equals(id)))
          .write(ConsumablesCompanion(remainingGrams: Value(grams)));
      final channel = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single;
      return _Fixture(db, printerId, channel);
    }))!;
  }

  Future<ChannelWithConsumable> readChannel() async =>
      (await db.printerDao.getByIdWithChannels(printerId))!.channels.single;

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    container.dispose();
    await tester.runAsync(db.close);
  }
}

Future<void> _waitFor(Future<bool> Function() predicate) async {
  final timeout = DateTime.now().add(const Duration(seconds: 3));
  while (!await predicate()) {
    if (DateTime.now().isAfter(timeout))
      throw StateError('UI action did not complete within 3 seconds');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _QuietConnection extends StateNotifier<ActivePrinterState>
    implements ActivePrinterConnectionNotifier {
  _QuietConnection() : super(const ActivePrinterState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
