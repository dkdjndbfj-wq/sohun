import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/printer_feed_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/seed/printer_seed.dart';
import 'package:consumable_tracker_desktop/providers/spool_change_provider.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dual-extruder presets expose two external feed inputs', () {
    expect(PrinterPresets.findByModel('X2D')!.externalInputCount, 2);
    expect(PrinterPresets.findByModel('H2D')!.externalInputCount, 2);
    expect(PrinterPresets.findByModel('H2C')!.externalInputCount, 2);
    expect(PrinterPresets.findByModel('H2S')!.externalInputCount, 1);
  });

  test(
      'X1C preserves the switchable external path without counting an extra color',
      () {
    final preset = PrinterPresets.findByModel('X1C')!;
    expect(preset.feedConfiguration(amsCount: 0).externalInputCount, 1);
    expect(preset.feedConfiguration(amsCount: 1).externalInputCount, 1);
    expect(preset.feedConfiguration(amsCount: 2).externalInputCount, 1);
    expect(preset.externalCanCoexistWithAms, isFalse);
    expect(preset.maxChannels, 16);
  });

  test('mixed AMS generations keep external and physical slots distinct', () {
    const configuration = PrinterFeedConfiguration(
      externalInputCount: 2,
      amsTypes: [AmsUnitType.ams2Pro, AmsUnitType.amsHt],
    );

    expect(configuration.channelCount, 7);
    expect(
      configuration.slots.map((slot) => slot.channelIndex),
      [0, 1, 2, 3, 16, 254, 255],
    );
    expect(
      configuration.slots.firstWhere((slot) => slot.channelIndex == 16).label,
      '第 2 台 AMS HT · 第 1 通道',
    );
  });

  group('printer feed DAO reconciliation', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    test('configured X2D stores external and mixed AMS slots', () async {
      final printerId = await db.printerDao.addPrinterWithFeedConfiguration(
        brand: '拓竹',
        model: 'X2D',
        feedConfiguration: const PrinterFeedConfiguration(
          externalInputCount: 2,
          amsTypes: [AmsUnitType.ams2Pro, AmsUnitType.amsHt],
        ),
      );

      final printer = await db.printerDao.getByIdWithChannels(printerId);
      expect(printer!.printer.channelCount, 7);
      expect(
        printer.channels.map((item) => item.channel.channelIndex),
        [0, 1, 2, 3, 16, 254, 255],
      );
    });

    test('live dual external report migrates legacy A and keeps its binding',
        () async {
      final printerId = await db.printerDao.addPrinter(
        brand: '拓竹',
        model: 'X2D',
        channelCount: 1,
      );
      final consumableId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'PLA',
        ),
      );
      final before = await db.printerDao.getByIdWithChannels(printerId);
      await db.printerDao.bindConsumable(
        before!.channels.single.channel.id,
        consumableId,
      );

      await db.printerDao.syncExternalFeedChannels(
        printerId,
        externalInputCount: 2,
        hasAms: false,
      );

      final after = await db.printerDao.getByIdWithChannels(printerId);
      expect(
        after!.channels.map((item) => item.channel.channelIndex),
        [254, 255],
      );
      expect(
        after.channels
            .firstWhere(
              (item) => item.channel.channelIndex == externalFeedRightChannel,
            )
            .channel
            .consumableId,
        consumableId,
      );
    });

    test('AMS synchronization preserves external feeds and records generation',
        () async {
      final printerId = await db.printerDao.addPrinterWithFeedConfiguration(
        brand: '拓竹',
        model: 'H2D',
        feedConfiguration: const PrinterFeedConfiguration(
          externalInputCount: 2,
          amsTypes: [],
        ),
      );
      const units = [
        AmsUnit(
          id: 0,
          type: AmsUnitType.ams2Pro,
          isPresent: true,
          trays: [
            AmsTray(amsId: 0, slot: 0, hasFilament: false),
          ],
        ),
        AmsUnit(
          id: 128,
          type: AmsUnitType.amsHt,
          isPresent: true,
          trays: [
            AmsTray(amsId: 128, slot: 0, hasFilament: false),
          ],
        ),
      ];
      await db.printerDao.syncChannelsFromAms(
        printerId,
        const [
          AmsTray(amsId: 0, slot: 0, hasFilament: false),
          AmsTray(amsId: 128, slot: 0, hasFilament: false),
        ],
        amsUnits: units,
        autoBindRfid: false,
        unbindEmpty: false,
      );

      final printer = await db.printerDao.getByIdWithChannels(printerId);
      expect(
        printer!.channels.map((item) => item.channel.channelIndex),
        [0, 16, 254, 255],
      );
      expect(
        printer.channels
            .firstWhere((item) => item.channel.channelIndex == 0)
            .channel
            .label,
        '第 1 台 AMS 2 Pro · 第 1 通道',
      );
      expect(
        printer.channels
            .firstWhere((item) => item.channel.channelIndex == 16)
            .channel
            .label,
        '第 2 台 AMS HT · 第 1 通道',
      );
    });

    test(
        'explicit no-AMS report removes AMS slots but preserves external feeds',
        () async {
      final printerId = await db.printerDao.addPrinterWithFeedConfiguration(
        brand: '拓竹',
        model: 'H2D',
        feedConfiguration: const PrinterFeedConfiguration(
          externalInputCount: 2,
          amsTypes: [AmsUnitType.ams2Pro, AmsUnitType.amsHt],
        ),
      );

      await db.printerDao.syncChannelsFromAms(
        printerId,
        const <AmsTray>[],
        amsUnits: const <AmsUnit>[],
        autoBindRfid: false,
      );

      final printer = await db.printerDao.getByIdWithChannels(printerId);
      expect(
        printer!.channels.map((item) => item.channel.channelIndex),
        [externalFeedLeftChannel, externalFeedRightChannel],
      );
      expect(printer.printer.channelCount, 2);
    });

    test(
        'external empty sensor clears the slot and same stock row reloads 1000g',
        () async {
      final printerId = await db.printerDao.addPrinterWithFeedConfiguration(
        brand: '拓竹',
        model: 'A1',
        feedConfiguration: const PrinterFeedConfiguration(
          externalInputCount: 1,
          amsTypes: [],
        ),
      );
      final consumableId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Farm PLA',
          model: 'White',
          remainingGrams: const Value(2000),
        ),
      );
      var printer = await db.printerDao.getByIdWithChannels(printerId);
      final channelId = printer!.channels.single.channel.id;
      await db.printerDao.bindConsumable(channelId, consumableId);
      expect(
        (await db.printerDao.getByIdWithChannels(printerId))!
            .channels
            .single
            .channel
            .loadedRemainingGrams,
        1000,
      );

      await db.printerDao.syncExternalFeedOccupancy(
        printerId,
        const [false],
      );
      printer = await db.printerDao.getByIdWithChannels(printerId);
      expect(printer!.channels.single.channel.consumableId, isNull);
      expect(printer.channels.single.channel.loadedRemainingGrams, 0);

      await db.printerDao.changeRoll(
        channelId: channelId,
        newConsumableId: consumableId,
      );
      printer = await db.printerDao.getByIdWithChannels(printerId);
      expect(printer!.channels.single.channel.consumableId, consumableId);
      expect(printer.channels.single.channel.loadedRemainingGrams, 1000);
    });

    test('an unidentified spool loaded before monitoring still prompts',
        () async {
      final printerId = await db.printerDao.addPrinterWithFeedConfiguration(
        brand: '拓竹',
        model: 'P1S',
        feedConfiguration: const PrinterFeedConfiguration(
          externalInputCount: 1,
          amsTypes: [AmsUnitType.ams],
        ),
      );
      const thirdParty = AmsTray(
        amsId: 0,
        slot: 2,
        trayType: 'PETG',
        trayColor: 'FF6600FF',
        trayTag: 'thirdparty',
        hasFilament: true,
      );
      final status = BambuPrinterStatus(
        serial: 'P1',
        amsTrays: [thirdParty],
        amsUnits: [
          const AmsUnit(
            id: 0,
            type: AmsUnitType.ams,
            isPresent: true,
            trays: [thirdParty],
          ),
        ],
      );
      final queue = SpoolChangeQueueNotifier();

      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printerId,
        printerSerial: 'P1',
        printerLabel: '工作室 P1S',
        status: status,
      );

      expect(queue.state, hasLength(1));
      expect(queue.state.single.slotLabel, '第 1 台 AMS 1 · 第 3 通道');
    });

    test('startup empty telemetry prompts for a still-bound personal roll',
        () async {
      final printerId = await db.printerDao.addPrinterWithFeedConfiguration(
        brand: '拓竹',
        model: 'P1S',
        feedConfiguration: const PrinterFeedConfiguration(
          externalInputCount: 1,
          amsTypes: [AmsUnitType.ams],
        ),
      );
      final consumableId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'eSUN',
          model: 'PLA+',
          remainingGrams: const Value(640),
        ),
      );
      final printer = await db.printerDao.getByIdWithChannels(printerId);
      await db.printerDao.bindConsumable(
        printer!.channels
            .firstWhere((item) => item.channel.channelIndex == 0)
            .channel
            .id,
        consumableId,
      );
      final queue = SpoolChangeQueueNotifier();
      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printerId,
        printerSerial: 'P1',
        printerLabel: '工作室 P1S',
        status: BambuPrinterStatus(
          serial: 'P1',
          amsTrays: const [],
          amsUnits: const [],
        ),
      );

      expect(queue.state, hasLength(1));
      expect(queue.state.single.isRemoval, isTrue);
      expect(queue.state.single.channelIndex, 0);
    });
  });
}
