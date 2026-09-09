import 'package:consumable_tracker_desktop/core/services/spool_change_detector.dart';
import 'package:consumable_tracker_desktop/core/services/printer_model_normalizer.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/printer_feed_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_feed_telemetry.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_print_feed.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/seed/printer_seed.dart';
import 'package:consumable_tracker_desktop/providers/spool_change_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

BambuPrinterStatus decode(Map<String, dynamic> print) =>
    BambuPrinterStatus.fromMqttJson({'print': print}, serial: 'test')!;

void main() {
  test(
      'new model suffixes and numeric shared routing cannot masquerade as old fixed hardware',
      () {
    expect(PrinterModelNormalizer.isKnownBambuModel('A1 Mini Plus'), isFalse);
    expect(PrinterModelNormalizer.isKnownBambuModel('X1 Carbon 2'), isFalse);
    expect(PrinterModelNormalizer.normalize('Bambu Lab X1 Carbon 0.4 nozzle'),
        'X1C');
    final units = AmsUnit.parseList({
      'ams': [
        {'id': '0', 'info': 0xe03}
      ]
    });
    expect(units.single.usesFilamentTrackSwitch, isTrue);
    expect(units.single.extruderId, isNull);
  });
  test(
      'inactive tools cannot enable AMS or encode stale channels in an external print',
      () {
    final payload = buildBambuPrintFeedPayload([255, 0, 999], activeTools: [0]);
    expect(payload['use_ams'], isFalse);
    expect(payload['ams_mapping'], [-1, -1, -1]);
    expect(payload['ams_mapping2'], [
      {'ams_id': 255, 'slot_id': 0},
      {'ams_id': 255, 'slot_id': 255},
      {'ams_id': 255, 'slot_id': 255},
    ]);
  });
  test('incremental units, trays, route and occupancy merge by physical ID',
      () {
    final cache = BambuFeedTelemetryCache();
    BambuPrinterStatus update(Map<String, dynamic> ams) =>
        BambuPrinterStatus.fromMqttJson(
            cache.merge({
              'print': {'ams': ams}
            }),
            serial: 'test')!;
    update({
      'ams_exist_bits': '3',
      'tray_exist_bits': '11',
      'ams': [
        {
          'id': '0',
          'info': '0003',
          'tray': [
            {'id': '0', 'tray_uuid': 'roll-a'}
          ]
        },
        {
          'id': '1',
          'info': '0103',
          'tray': [
            {'id': '0', 'tray_uuid': 'roll-b'}
          ]
        },
      ]
    });
    final partial = update({
      'ams': [
        {'id': '1', 'humidity': 12}
      ]
    });
    expect(partial.amsUnits!.map((u) => u.extruderId), [0, 1]);
    expect(partial.amsTrays!.map((t) => t.hasFilament), [true, true]);
    expect(partial.amsTrays!.map((t) => t.trayUuid), ['roll-a', 'roll-b']);
    final unloaded = update({'tray_exist_bits': '1'});
    expect(unloaded.amsTrays!.map((t) => t.hasFilament), [true, false]);
    final disconnected = update({'ams_exist_bits': '0'});
    expect(detectedAmsState(disconnected), AmsDetectionState.absent);
    cache.clear();
    final reconnected = update({
      'ams': [
        {
          'id': '1',
          'tray': [
            {'id': '0'}
          ]
        }
      ]
    });
    expect(reconnected.amsUnits!.single.extruderId, isNull);
    expect(reconnected.amsTrays!.single.hasFilamentObservation, isFalse);
  });

  test('sparse extruder observation never invents an empty opposite nozzle',
      () {
    final partial = decode({
      'extruder': {
        'info': [
          {'id': 1, 'info': 2}
        ]
      }
    });
    expect(partial.extruderFilamentPresent, [null, true]);
    expect(
        externalFeedSensorReadings(
            sensors: partial.extruderFilamentPresent, units: []),
        [null, true]);
    final cache = BambuFeedTelemetryCache();
    cache.merge({
      'print': {
        'extruder': {
          'info': [
            {'id': 0, 'info': 2}
          ]
        }
      }
    });
    final merged = BambuPrinterStatus.fromMqttJson(
        cache.merge({
          'print': {
            'extruder': {
              'info': [
                {'id': 1, 'info': 0}
              ]
            }
          }
        }),
        serial: 'test')!;
    expect(merged.extruderFilamentPresent, [true, false]);
    expect(
        detectedAmsState(decode({
          'ams': {'ams_exist_bits': '0'}
        })),
        AmsDetectionState.absent);
  });

  test('missing occupancy does not start a spool removal event', () {
    final detector = SpoolChangeDetector();
    final start = DateTime(2026, 9, 5);
    detector.update(
        printerSerial: 'test',
        printerLabel: 'test',
        trays: const [AmsTray(amsId: 0, slot: 0, hasFilament: true)],
        now: start);
    final unknown = AmsTray.parseList({
      'ams': [
        {
          'id': '0',
          'tray': [
            {'id': '0'}
          ]
        }
      ]
    });
    for (var second = 1; second <= 10; second++) {
      expect(
          detector.update(
              printerSerial: 'test',
              printerLabel: 'test',
              trays: unknown,
              now: start.add(Duration(seconds: second))),
          isEmpty);
    }
  });

  test('X2D left primary AMS and right auxiliary external match slice routes',
      () {
    final state = decode({
      'ams': {
        'ams_exist_bits': '1',
        'tray_exist_bits': '1',
        'ams': [
          {
            'id': '0',
            'info': '0103',
            'tray': [
              {'id': '0'}
            ]
          }
        ]
      }
    });
    expect(
        validateBambuPrintFeed(
            model: 'X2D',
            mapping: [0, 255],
            activeTools: [0, 1],
            status: state,
            toolExtruders: {0: 1, 1: 0}),
        isNull);
    expect(
        validateBambuPrintFeed(
            model: 'X2D',
            mapping: [0, 254],
            activeTools: [0, 1],
            status: state,
            toolExtruders: {0: 1, 1: 0}),
        isNotNull);
  });

  test('FTS blocks external and unverified shared routing before upload', () {
    final state = decode({
      'ams': {
        'ams_exist_bits': '1',
        'tray_exist_bits': '1',
        'ams': [
          {
            'id': '0',
            'info': '0e03',
            'tray': [
              {'id': '0'}
            ]
          }
        ]
      }
    });
    expect(
        validateBambuPrintFeed(
            model: 'X2D',
            mapping: [255],
            activeTools: [0],
            status: state,
            toolExtruders: {0: 0}),
        contains('FTS'));
    expect(
        validateBambuPrintFeed(
            model: 'X2D',
            mapping: [0],
            activeTools: [0],
            status: state,
            toolExtruders: {0: 0}),
        contains('共享进料'));
    expect(
        validateBambuPrintFeed(
            model: 'X1C',
            mapping: [255, 255],
            activeTools: [0, 1],
            status: null),
        contains('多个切片工具'));
  });

  test('A2L can use slot four; mixing cannot use all four Lite inlets', () {
    final state = decode({
      'ams': {
        'ams_exist_bits': '1001',
        'tray_exist_bits': 'f000001',
        'ams': [
          {
            'id': '0',
            'info': '0003',
            'tray': [
              {'id': '0'}
            ]
          },
          {
            'id': '16',
            'info': '0005',
            'tray': [
              for (var slot = 0; slot < 4; slot++) {'id': '$slot'}
            ]
          }
        ]
      }
    });
    expect(
        validateBambuPrintFeed(
            model: 'A2L',
            mapping: [0, 25, 26, 27],
            activeTools: [0, 1, 2, 3],
            status: state),
        isNull);
    expect(
        validateBambuPrintFeed(
            model: 'A2L',
            mapping: [0, 24, 25, 26, 27],
            activeTools: [0, 1, 2, 3, 4],
            status: state),
        contains('让出一路'));
    // A standard AMS still occupies an inlet when this particular job does
    // not select any of its trays.
    expect(
        validateBambuPrintFeed(
            model: 'A2L',
            mapping: [24, 25, 26, 27],
            activeTools: [0, 1, 2, 3],
            status: state),
        contains('让出一路'));
  });

  test(
      'external occupancy index zero only unbinds right; unknown preserves left',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final printerId = await db.printerDao.addPrinterWithFeedConfiguration(
        brand: '拓竹',
        model: 'X2D',
        feedConfiguration:
            PrinterPresets.findByModel('X2D')!.feedConfiguration(amsCount: 0));
    final printer = (await db.printerDao.getByIdWithChannels(printerId))!;
    for (final channel in printer.channels) {
      final id = await db.consumableDao.addConsumable(
          ConsumablesCompanion.insert(
              manufacturer: 'test', model: '${channel.channel.channelIndex}'));
      await db.printerDao.bindConsumable(channel.channel.id, id);
    }
    await db.printerDao.syncExternalFeedOccupancy(printerId, [false, null]);
    final after = (await db.printerDao.getByIdWithChannels(printerId))!;
    expect(
        after.channels
            .firstWhere((c) => c.channel.channelIndex == 255)
            .channel
            .consumableId,
        isNull);
    expect(
        after.channels
            .firstWhere((c) => c.channel.channelIndex == 254)
            .channel
            .consumableId,
        isNotNull);
  });

  test('partial AMS occupancy preserves database binding and startup prompts',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final printerId = await db.printerDao.addPrinterWithFeedConfiguration(
        brand: '拓竹',
        model: 'X1C',
        feedConfiguration:
            PrinterPresets.findByModel('X1C')!.feedConfiguration(amsCount: 1));
    final printer = (await db.printerDao.getByIdWithChannels(printerId))!;
    final channel =
        printer.channels.firstWhere((c) => c.channel.channelIndex == 0).channel;
    final id = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(manufacturer: 'test', model: 'PLA'));
    await db.printerDao.bindConsumable(channel.id, id);
    final unknown = decode({
      'ams': {
        'ams': [
          {
            'id': '0',
            'info': '0003',
            'tray': [
              {'id': '0'}
            ]
          }
        ]
      }
    });
    await db.printerDao.syncChannelsFromAms(printerId, unknown.amsTrays!,
        amsUnits: unknown.amsUnits);
    expect(await db.printerDao.getConsumableIdByChannel(printerId, 0), id);
    final queue = SpoolChangeQueueNotifier();
    await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printerId,
        printerSerial: 'test',
        printerLabel: 'test',
        status: unknown);
    expect(queue.state, isEmpty);
  });
}
