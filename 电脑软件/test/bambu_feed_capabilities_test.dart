import 'package:consumable_tracker_desktop/core/services/printer_model_normalizer.dart';
import 'package:consumable_tracker_desktop/data/database/models/printer_feed_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_print_feed.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/seed/printer_seed.dart';
import 'package:flutter_test/flutter_test.dart';

// Reviewed against official BBL.json and the AMS compatibility guide on
// 2026-09-05. Deliberately independent expectations, not generated from code.
const matrix = {
  'X1': (4, 4, 0, 1, 16),
  'X1C': (4, 4, 0, 1, 16),
  'X1E': (4, 4, 0, 1, 16),
  'P1P': (4, 4, 0, 1, 16),
  'P1S': (4, 4, 0, 1, 16),
  'P2S': (8, 4, 0, 1, 20),
  'A1': (4, 4, 1, 1, 16),
  'A1mini': (4, 4, 1, 1, 16),
  'A2L': (4, 4, 1, 1, 19),
  'X2D': (12, 8, 0, 2, 25),
  'H2D': (12, 8, 0, 2, 25),
  'H2D Pro': (12, 8, 0, 2, 25),
  'H2C': (12, 8, 0, 2, 25),
  'H2S': (12, 8, 0, 1, 24),
};

BambuPrinterStatus statusWithUnits(List<AmsUnit> units) => BambuPrinterStatus(
      serial: 'test',
      amsUnits: units,
      amsTrays: units
          .where((unit) => unit.isPresent)
          .expand((unit) => unit.trays)
          .toList(),
    );

void main() {
  test('every official model has a separate, verified capability entry', () {
    expect(PrinterModelNormalizer.knownBambuModels, matrix.keys.toSet());
    expect(
        PrinterPresets.all.where((p) => p.isBambu).map((p) => p.model).toSet(),
        matrix.keys.toSet());
    for (final entry in matrix.entries) {
      final p = PrinterPresets.findByModel(entry.key)!;
      final (units, ht, lite, external, colors) = entry.value;
      expect(p.maxAmsCount, units, reason: entry.key);
      expect(p.maxAms2ProCount, 4, reason: entry.key);
      expect(p.maxAmsHtCount, ht, reason: entry.key);
      expect(p.maxAmsLiteCount, lite, reason: entry.key);
      expect(p.externalInputCount, external, reason: entry.key);
      expect(p.maxChannels, colors, reason: entry.key);
      expect(p.externalCanCoexistWithAms, external == 2, reason: entry.key);
      for (var n = 0; n <= p.maxConfiguredAmsUnits; n++) {
        expect(p.validateAmsTypes(p.defaultAmsTypes(n)), isTrue,
            reason: '${entry.key} default $n');
      }
    }
    expect(PrinterModelNormalizer.sameModel('H2DP', 'H2D'), isFalse);
    expect(PrinterPresets.findByModel('Bambu Lab H2DP')!.model, 'H2D Pro');
    expect(PrinterPresets.findByModel('X1 Carbon')!.model, 'X1C');
    expect(PrinterPresets.findByModel('A3 unknown'), isNull);
  });

  test('limits apply to combinations as well as individual AMS generations',
      () {
    final a1 = PrinterPresets.findByModel('A1')!;
    expect(
        a1.validateAmsTypes([AmsUnitType.amsLite, AmsUnitType.amsHt]), isFalse);
    expect(a1.validateAmsTypes(List.filled(2, AmsUnitType.amsLite)), isFalse);
    final h2 = PrinterPresets.findByModel('H2D')!;
    expect(h2.validateAmsTypes(List.filled(5, AmsUnitType.ams2Pro)), isFalse);
    expect(
        h2.validateAmsTypes([
          ...List.filled(4, AmsUnitType.ams),
          ...List.filled(8, AmsUnitType.amsHt)
        ]),
        isTrue);
    final p1 = PrinterPresets.findByModel('P1S')!;
    expect(
        p1.validateAmsTypes(
            [...List.filled(4, AmsUnitType.ams), AmsUnitType.amsHt]),
        isFalse);
  });

  test(
      'A2L preserves four physical Lite slots while limiting mixed prints to 19 colors',
      () {
    final a2 = PrinterPresets.findByModel('A2L')!;
    final mixed = a2.feedConfiguration(amsCount: 5, amsTypes: [
      AmsUnitType.amsLite,
      ...List.filled(4, AmsUnitType.ams2Pro)
    ]);
    // Physical connectors are preserved; any Lite tube can be the reserved one.
    expect(mixed.amsChannelCount, 20);
    expect(a2.maxChannels, 19);
    expect(
        mixed.slots
            .where((slot) => !slot.isExternal)
            .map((slot) => slot.channelIndex),
        [...List.generate(16, (i) => i), 24, 25, 26, 27]);
    final alone =
        a2.feedConfiguration(amsCount: 1, amsTypes: [AmsUnitType.amsLite]);
    expect(alone.amsChannelCount, 4);
    expect(alone.slots.map((slot) => slot.channelIndex), [24, 25, 26, 27, 255]);
  });

  test(
      'A2L mixed Lite unit bit 12, tray bit 24, sparse slot IDs and physical ID survive',
      () {
    final units = AmsUnit.parseList({
      'ams_exist_bits': '1001',
      'tray_exist_bits': '5000001',
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
            {'id': '2'},
            {'id': '0'},
            {'id': '1'}
          ]
        },
      ]
    });
    expect(units.map((unit) => unit.isPresent), [true, true]);
    final lite = units.last;
    expect(lite.type, AmsUnitType.amsLite);
    expect(lite.id, 16);
    expect(lite.trays.map((tray) => tray.globalSlot), [26, 24, 25]);
    expect(lite.trays.map((tray) => tray.hasFilament), [true, true, false]);
    expect(lite.trays.first.protocolTrayId, 26);
  });

  test('payload distinguishes HT wire IDs, external paths and inactive tools',
      () {
    final payload = buildBambuPrintFeedPayload([-1, 0, 16, 23, 24, 254, 255]);
    expect(payload['use_ams'], isTrue);
    expect(payload['ams_mapping'], [-1, 0, 128, 135, 24, -1, -1]);
    expect(payload['ams_mapping2'], [
      {'ams_id': 255, 'slot_id': 255},
      {'ams_id': 0, 'slot_id': 0},
      {'ams_id': 128, 'slot_id': 0},
      {'ams_id': 135, 'slot_id': 0},
      {'ams_id': 16, 'slot_id': 0},
      {'ams_id': 254, 'slot_id': 0},
      {'ams_id': 255, 'slot_id': 0},
    ]);
    expect(buildBambuPrintFeedPayload([255])['use_ams'], isFalse);
    expect(() => buildBambuPrintFeedPayload([512]), throwsArgumentError);
  });

  group('actual feed routing', () {
    const right = AmsUnit(
        id: 0,
        type: AmsUnitType.ams2Pro,
        isPresent: true,
        extruderId: 0,
        trays: [AmsTray(amsId: 0, slot: 0, hasFilament: true)]);
    const left = AmsUnit(
        id: 1,
        type: AmsUnitType.ams2Pro,
        isPresent: true,
        extruderId: 1,
        trays: [AmsTray(amsId: 1, slot: 0, hasFilament: true)]);

    test('X1C uses one path; X2D retains only the opposite external path', () {
      expect(
          externalFeedAvailability(255,
              externalInputCount: 1,
              amsState: AmsDetectionState.present,
              units: [right]),
          ExternalFeedAvailability.switchRequired);
      expect(
          externalFeedAvailability(254,
              externalInputCount: 2,
              amsState: AmsDetectionState.present,
              units: [right]),
          ExternalFeedAvailability.available);
      expect(
          externalFeedAvailability(255,
              externalInputCount: 2,
              amsState: AmsDetectionState.present,
              units: [right]),
          ExternalFeedAvailability.switchRequired);
      for (final channel in [254, 255]) {
        expect(
            externalFeedAvailability(channel,
                externalInputCount: 2,
                amsState: AmsDetectionState.present,
                units: [right, left]),
            ExternalFeedAvailability.switchRequired);
      }
    });

    test('AMS sensor never unbinds or prompts an external spool', () {
      expect(
          externalFeedSensorReadings(sensors: [false], units: [right]), [null]);
      expect(externalFeedSensorReadings(sensors: [false, true], units: [right]),
          [null, true]);
      expect(externalFeedSensorReadings(sensors: [true, false], units: [left]),
          [true, null]);
      expect(
          externalFeedSensorReadings(
              sensors: [false, false], units: [left, right]),
          [null, null]);
      expect(externalFeedSensorReadings(sensors: [false, false]), [null, null]);
      expect(externalFeedSensorReadings(sensors: [false, true], units: []),
          [false, true]);
    });

    test('X2D AMS + external support requires correct sliced nozzle assignment',
        () {
      String? validate(List<int> mapping,
              {String model = 'X2D',
              Map<int, int> routes = const {0: 0, 1: 1}}) =>
          validateBambuPrintFeed(
              model: model,
              mapping: mapping,
              activeTools: [0, 1],
              status: statusWithUnits([right]),
              toolExtruders: routes);
      expect(validate([0, 254]), isNull);
      expect(validate([0, 255]), contains('喷头不一致'));
      expect(validate([0, 254], model: 'X1C'), contains('不能混用'));
      expect(validate([0, 254], routes: {}), contains('缺少'));
      expect(validate([1, 254]), contains('未连接或没有耗材'));
      expect(validate([0, -1]), contains('尚未指定'));
    });

    test(
        'unit order is not nozzle identity; info routes and unknown remain explicit',
        () {
      final units = AmsUnit.parseList({
        'ams': [
          {'id': '3', 'info': '0103', 'tray': []},
          {'id': '0', 'info': '0e03', 'tray': []}
        ]
      });
      expect(units.first.extruderId, 1);
      expect(units.last.extruderId, isNull);
    });
  });

  test(
      'selected plate nozzle map is independent of tool number and other plates',
      () {
    const xml =
        '<config><plate><metadata key="plater_id" value="1"/><metadata key="filament_maps" value="1 2"/></plate>'
        '<plate><metadata key="plater_id" value="2"/><metadata key="filament_maps" value="2 1"/></plate></config>';
    expect(parseBambuToolExtruders(modelSettingsXml: xml, plateIndex: 2),
        {0: 0, 1: 1});
    expect(
        parseBambuToolExtruders(modelSettingsXml: xml, plateIndex: 3), isEmpty);
    expect(
        parseBambuToolExtruders(
            modelSettingsXml: xml,
            projectSettingsJson: '{"physical_extruder_map":[0,1]}'),
        {0: 0, 1: 1});
    expect(parseBambuToolExtruders(modelSettingsXml: '<broken'), isEmpty);
  });
}
