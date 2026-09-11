import 'package:consumable_tracker_desktop/core/constants/personal_spool_policy.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reuse accepts only finite weights strictly above 30g up to 1000g', () {
    expect(personalSpoolCapacityGrams, 1000);
    for (final grams in [
      double.nan,
      double.infinity,
      -1.0,
      0.0,
      30.0,
      1001.0,
    ]) {
      expect(canReusePersonalSpool(grams), isFalse, reason: '$grams');
    }
    for (final grams in [30.01, 31.0, 415.0, 1000.0]) {
      expect(canReusePersonalSpool(grams), isTrue, reason: '$grams');
    }
  });

  test(
    '30g held stock clears only after explicit confirmation for the same roll',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'PLA',
          totalGrams: const Value(1000),
          remainingGrams: const Value(1000),
        ),
      );
      await db.consumableDao.setRfidSpoolBinding(
        id,
        tagUid: 'AABBCC01',
        tagType: 'CUID',
        cycle: 1,
        status: 'active',
      );
      final printerId = await db.printerDao.addPrinter(
        brand: 'Test',
        model: 'P1',
        channelCount: 1,
      );
      final channelId = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single.channel.id;
      await db.printerDao.bindConsumable(channelId, id);
      await db.consumableDao.adjustGrams(id, 970);
      await db.printerDao.preparePersonalSpoolReplacement(
        channelId,
        expectedConsumableId: id,
      );
      await expectLater(
        db.printerDao.finishChannel(channelId),
        throwsStateError,
      );
      await expectLater(
        db.printerDao.finishChannel(
          channelId,
          expectedConsumableId: id + 1,
          confirmDetectedRemoval: true,
        ),
        throwsStateError,
      );
      expect((await db.consumableDao.getById(id))!.remainingGrams, 30);
      await db.printerDao.finishChannel(
        channelId,
        expectedConsumableId: id,
        confirmDetectedRemoval: true,
      );
      expect((await db.consumableDao.getById(id))!.remainingGrams, 0);
      expect(
        (await db.printerDao.getByIdWithChannels(
          printerId,
        ))!.channels.single.consumable,
        isNull,
      );
    },
  );

  for (final maintenance in [false, true]) {
    for (final grams in [0.0, 30.0, 31.0, 1000.0, 1001.0]) {
      test(
        '${maintenance ? 'maintenance' : 'ordinary removal'} resumes $grams g only when reusable',
        () async {
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(db.close);
          final id = await db.consumableDao.addConsumable(
            ConsumablesCompanion.insert(
              manufacturer: 'Test',
              model: 'PLA',
              totalGrams: const Value(1000),
              remainingGrams: const Value(1000),
            ),
          );
          await db.consumableDao.setRfidSpoolBinding(
            id,
            tagUid: 'AABBCC01',
            tagType: 'CUID',
            cycle: 1,
            status: 'active',
          );
          final printerId = await db.printerDao.addPrinter(
            brand: 'Test',
            model: 'P1',
            channelCount: 1,
          );
          final channelId = (await db.printerDao.getByIdWithChannels(
            printerId,
          ))!.channels.single.channel.id;
          await db.printerDao.bindConsumable(channelId, id);
          if (maintenance) {
            await db.printerDao.pauseChannelRollForMaintenance(channelId);
          } else {
            await db.printerDao.preparePersonalSpoolReplacement(
              channelId,
              expectedConsumableId: id,
            );
          }
          // Simulate a synced balance change while the original roll is held.
          // The 1001g case represents legacy inconsistent data, never new stock.
          await db.customUpdate(
            'UPDATE consumables SET remaining_grams = ? WHERE id = ?',
            variables: [Variable(grams), Variable(id)],
          );
          await db.customUpdate(
            'UPDATE printer_channels SET loaded_remaining_grams = ? WHERE id = ?',
            variables: [Variable(grams), Variable(channelId)],
          );
          final action = maintenance
              ? db.printerDao.resumeChannelRollAfterMaintenance(channelId)
              : db.printerDao.resumePreparedPersonalSpoolReplacement(
                  channelId,
                  expectedConsumableId: id,
                );
          if (canReusePersonalSpool(grams)) {
            await action;
          } else {
            await expectLater(action, throwsStateError);
          }
          final channel = (await db.printerDao.getByIdWithChannels(
            printerId,
          ))!.channels.single;
          expect(
            channel.rollHoldState,
            canReusePersonalSpool(grams)
                ? ChannelRollHoldState.loaded
                : maintenance
                ? ChannelRollHoldState.maintenance
                : ChannelRollHoldState.awaitingSelection,
          );
          expect(channel.consumable!.remainingGrams, grams);
          expect(channel.channel.loadedRemainingGrams, grams);
          expect(channel.consumable!.totalGrams, 1000);
        },
      );
    }
  }
}
