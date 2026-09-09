import 'package:consumable_tracker_desktop/core/services/spool_change_detector.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/providers/spool_change_provider.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('spool change telemetry parsing', () {
    test('parses external spool, legacy sensor and load stage', () {
      final status = BambuPrinterStatus.fromMqttJson(
        <String, dynamic>{
          'print': <String, dynamic>{
            'hw_switch_state': 1,
            'mc_print_stage': '24',
            'vt_tray': <String, dynamic>{
              'tray_type': 'PETG',
              'tray_color': '22AAFFFF',
              'tray_sub_brands': 'Local Brand',
              'tray_info_idx': 'manual-petg',
            },
          },
        },
        serial: 'P1',
      );

      expect(status, isNotNull);
      expect(status!.hwSwitchState, 1);
      expect(status.mcPrintStage, 24);
      expect(status.externalTrays, hasLength(1));
      expect(status.externalTrays!.single.trayType, 'PETG');
      expect(status.externalTrays!.single.hasRfidInfo, isFalse);
    });

    test('parses two new-protocol extruder sensors and virtual inputs', () {
      final status = BambuPrinterStatus.fromMqttJson(
        <String, dynamic>{
          'print': <String, dynamic>{
            'extruder': <String, dynamic>{
              'info': <String, dynamic>{
                'right': <String, dynamic>{'id': 0, 'info': 2},
                'left': <String, dynamic>{'id': 1, 'info': 0},
              },
            },
            'vir_slot': <dynamic>[
              <String, dynamic>{'id': '255', 'tray_type': 'PLA'},
              <String, dynamic>{'id': '254', 'tray_type': 'TPU'},
            ],
          },
        },
        serial: 'H2',
      );

      expect(status!.extruderFilamentPresent, [true, false]);
      expect(status.externalTrays!.map((tray) => tray.slot), [0, 1]);
      expect(
        status.externalTrays!.map((tray) => tray.trayType),
        ['PLA', 'TPU'],
      );
    });

    test('incremental copy preserves and updates external telemetry', () {
      final original = BambuPrinterStatus(
        serial: 'P1',
        hwSwitchState: 1,
        mcPrintStage: 22,
        externalTrays: const [
          AmsTray(amsId: -1, slot: 0, trayType: 'PLA'),
        ],
      );

      expect(original.copyWith(mcPercent: 3).hwSwitchState, 1);
      expect(original.copyWith(hwSwitchState: 0).hwSwitchState, 0);
      expect(original.copyWith(mcPrintStage: 24).mcPrintStage, 24);
    });
  });

  group('AMS replacement detector', () {
    test(
        'first snapshot is baseline and direct RFID identity change emits once',
        () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      const first = AmsTray(
        amsId: 0,
        slot: 0,
        trayType: 'PLA',
        trayUuid: 'old',
        trayInfoIdx: 'GFA00',
        hasFilament: true,
      );
      const second = AmsTray(
        amsId: 0,
        slot: 0,
        trayType: 'PLA',
        trayUuid: 'new',
        trayInfoIdx: 'GFA00',
        hasFilament: true,
      );

      expect(
        detector.update(
          printerSerial: 'P1',
          printerLabel: '一号机',
          trays: const [first],
          now: now,
        ),
        isEmpty,
      );
      final events = detector.update(
        printerSerial: 'P1',
        printerLabel: '一号机',
        trays: const [second],
        now: now.add(const Duration(seconds: 1)),
      );

      expect(events, hasLength(1));
      expect(events.single.previous?.trayUuid, 'old');
      expect(events.single.current?.trayUuid, 'new');
    });

    test('multiple mixed-generation AMS slots remain distinct', () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      const units = [
        AmsUnit(
          id: 0,
          type: AmsUnitType.ams,
          isPresent: true,
          trays: [],
        ),
        AmsUnit(
          id: 1,
          type: AmsUnitType.ams2Pro,
          isPresent: true,
          trays: [],
        ),
      ];
      const oldTrays = [
        AmsTray(amsId: 0, slot: 1, trayUuid: 'a', hasFilament: true),
        AmsTray(amsId: 1, slot: 2, trayUuid: 'b', hasFilament: true),
      ];
      detector.update(
        printerSerial: 'P1',
        printerLabel: '工作室',
        trays: oldTrays,
        units: units,
        now: now,
      );
      detector.update(
        printerSerial: 'P1',
        printerLabel: '工作室',
        trays: const [
          AmsTray(amsId: 0, slot: 1, hasFilament: false),
          AmsTray(amsId: 1, slot: 2, hasFilament: false),
        ],
        units: units,
        now: now.add(const Duration(seconds: 2)),
      );
      final events = detector.update(
        printerSerial: 'P1',
        printerLabel: '工作室',
        trays: const [
          AmsTray(amsId: 0, slot: 1, trayUuid: 'c', hasFilament: true),
          AmsTray(amsId: 1, slot: 2, trayUuid: 'd', hasFilament: true),
        ],
        units: units,
        now: now.add(const Duration(seconds: 10)),
      );

      expect(events, hasLength(2));
      expect(events[0].slotLabel, '第 1 台 AMS 1 · 第 2 通道');
      expect(events[1].slotLabel, '第 2 台 AMS 2 Pro · 第 3 通道');
    });

    test('a newly connected occupied AMS slot only establishes a baseline', () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      detector.update(
        printerSerial: 'P1',
        printerLabel: '工作室',
        trays: const [
          AmsTray(amsId: 0, slot: 0, trayUuid: 'a', hasFilament: true),
        ],
        now: now,
      );

      final events = detector.update(
        printerSerial: 'P1',
        printerLabel: '工作室',
        trays: const [
          AmsTray(amsId: 0, slot: 0, trayUuid: 'a', hasFilament: true),
          AmsTray(amsId: 1, slot: 0, trayUuid: 'b', hasFilament: true),
        ],
        now: now.add(const Duration(seconds: 5)),
      );

      expect(events, isEmpty);
    });

    test('stable physical removal emits a personal reason event', () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      const loaded = AmsTray(
        amsId: 0,
        slot: 0,
        trayType: 'PLA',
        trayUuid: 'original',
        hasFilament: true,
      );
      const empty = AmsTray(amsId: 0, slot: 0, hasFilament: false);

      detector.update(
        printerSerial: 'P1',
        printerLabel: '一号机',
        trays: const [loaded],
        now: now,
      );
      expect(
        detector.update(
          printerSerial: 'P1',
          printerLabel: '一号机',
          trays: const [empty],
          now: now.add(const Duration(seconds: 1)),
        ),
        isEmpty,
      );
      final events = detector.update(
        printerSerial: 'P1',
        printerLabel: '一号机',
        trays: const [empty],
        now: now.add(const Duration(seconds: 2)),
      );

      expect(events, hasLength(1));
      expect(events.single.kind, SpoolChangeKind.removed);
      expect(events.single.isRemoval, isTrue);
      expect(events.single.previous?.trayUuid, 'original');
      expect(events.single.current, isNull);
    });

    test('brief AMS sensor bounce does not create removal or insertion events',
        () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      const loaded = AmsTray(
        amsId: 0,
        slot: 0,
        trayUuid: 'same-roll',
        hasFilament: true,
      );
      detector.update(
        printerSerial: 'P1',
        printerLabel: '一号机',
        trays: const [loaded],
        now: now,
      );
      detector.update(
        printerSerial: 'P1',
        printerLabel: '一号机',
        trays: const [AmsTray(amsId: 0, slot: 0, hasFilament: false)],
        now: now.add(const Duration(milliseconds: 100)),
      );
      final events = detector.update(
        printerSerial: 'P1',
        printerLabel: '一号机',
        trays: const [loaded],
        now: now.add(const Duration(milliseconds: 350)),
      );

      expect(events, isEmpty);
    });

    test('partial AMS payload does not look like a removed slot', () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      const loaded = AmsTray(
        amsId: 0,
        slot: 0,
        trayUuid: 'same-roll',
        hasFilament: true,
      );
      detector.update(
        printerSerial: 'P1',
        printerLabel: '一号机',
        trays: const [loaded],
        now: now,
      );
      final events = detector.update(
        printerSerial: 'P1',
        printerLabel: '一号机',
        trays: const [],
        now: now.add(const Duration(seconds: 2)),
      );

      expect(events, isEmpty);
    });
  });

  group('external spool replacement detector', () {
    test('stable external removal emits a personal reason event', () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      detector.update(
        printerSerial: 'P1',
        printerLabel: '外置机',
        trays: const [],
        hwSwitchState: 1,
        now: now,
      );
      detector.update(
        printerSerial: 'P1',
        printerLabel: '外置机',
        trays: const [],
        hwSwitchState: 0,
        now: now.add(const Duration(seconds: 1)),
      );
      final events = detector.update(
        printerSerial: 'P1',
        printerLabel: '外置机',
        trays: const [],
        hwSwitchState: 0,
        now: now.add(const Duration(seconds: 2)),
      );

      expect(events, hasLength(1));
      expect(events.single.kind, SpoolChangeKind.removed);
      expect(events.single.isExternal, isTrue);
      expect(events.single.channelIndex, 255);
    });

    test('unload then load creates an automatic no-AMS event', () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      detector.update(
        printerSerial: 'P1',
        printerLabel: '外置机',
        trays: const [],
        extruderFilamentPresent: const [true],
        now: now,
      );
      detector.update(
        printerSerial: 'P1',
        printerLabel: '外置机',
        trays: const [],
        extruderFilamentPresent: const [false],
        printStage: 22,
        now: now.add(const Duration(seconds: 1)),
      );
      final events = detector.update(
        printerSerial: 'P1',
        printerLabel: '外置机',
        trays: const [],
        externalTrays: const [
          AmsTray(amsId: -1, slot: 0, trayType: 'ABS'),
        ],
        extruderFilamentPresent: const [true],
        printStage: 24,
        now: now.add(const Duration(seconds: 2)),
      );

      expect(events, hasLength(1));
      expect(events.single.isExternal, isTrue);
      expect(events.single.slotLabel, '外挂料位');
      expect(events.single.current?.trayType, 'ABS');
      expect(events.single.hasRfidIdentity, isFalse);
    });

    test('brief sensor bounce without a load operation is ignored', () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      detector.update(
        printerSerial: 'P1',
        printerLabel: '外置机',
        trays: const [],
        hwSwitchState: 1,
        now: now,
      );
      detector.update(
        printerSerial: 'P1',
        printerLabel: '外置机',
        trays: const [],
        hwSwitchState: 0,
        now: now.add(const Duration(milliseconds: 100)),
      );
      final events = detector.update(
        printerSerial: 'P1',
        printerLabel: '外置机',
        trays: const [],
        hwSwitchState: 1,
        now: now.add(const Duration(milliseconds: 250)),
      );

      expect(events, isEmpty);
    });

    test('two external inputs can be replaced in one operation', () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      detector.update(
        printerSerial: 'H2',
        printerLabel: '双喷头',
        trays: const [],
        extruderFilamentPresent: const [true, true],
        now: now,
      );
      detector.update(
        printerSerial: 'H2',
        printerLabel: '双喷头',
        trays: const [],
        extruderFilamentPresent: const [false, false],
        printStage: 22,
        now: now.add(const Duration(seconds: 1)),
      );
      final events = detector.update(
        printerSerial: 'H2',
        printerLabel: '双喷头',
        trays: const [],
        extruderFilamentPresent: const [true, true],
        printStage: 24,
        now: now.add(const Duration(seconds: 2)),
      );

      expect(events.map((event) => event.slotLabel), [
        '外挂料位 R',
        '外挂料位 L',
      ]);
      expect(events.map((event) => event.channelIndex), [255, 254]);
    });

    test('external replacement is detected while an AMS tool is selected', () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      const units = [
        AmsUnit(
          id: 0,
          type: AmsUnitType.ams2Pro,
          extruderId: 1,
          isPresent: true,
          trays: [],
        ),
      ];
      detector.update(
        printerSerial: 'H2D',
        printerLabel: 'H2D 工作站',
        trays: const [],
        units: units,
        trayNow: '0',
        extruderFilamentPresent: const [true, true],
        now: now,
      );
      detector.update(
        printerSerial: 'H2D',
        printerLabel: 'H2D 工作站',
        trays: const [],
        units: units,
        trayNow: '0',
        extruderFilamentPresent: const [false, true],
        printStage: 22,
        now: now.add(const Duration(seconds: 1)),
      );
      final events = detector.update(
        printerSerial: 'H2D',
        printerLabel: 'H2D 工作站',
        trays: const [],
        units: units,
        trayNow: '0',
        extruderFilamentPresent: const [true, true],
        printStage: 24,
        now: now.add(const Duration(seconds: 2)),
      );

      expect(events, hasLength(1));
      expect(events.single.channelIndex, 255);
      expect(events.single.slotLabel, '外挂料位 R');
    });

    test('external spool stays separate from AMS channel zero', () {
      final detector = SpoolChangeDetector();
      final now = DateTime(2026, 8, 2, 12);
      const units = [
        AmsUnit(
          id: 0,
          type: AmsUnitType.ams,
          isPresent: true,
          trays: [],
        ),
      ];
      const trays = [
        AmsTray(amsId: 0, slot: 0, trayUuid: 'ams', hasFilament: true),
      ];
      detector.update(
        printerSerial: 'P1',
        printerLabel: '混合供料',
        trays: trays,
        units: units,
        trayNow: '254',
        hwSwitchState: 1,
        now: now,
      );
      detector.update(
        printerSerial: 'P1',
        printerLabel: '混合供料',
        trays: trays,
        units: units,
        trayNow: '254',
        hwSwitchState: 0,
        printStage: 22,
        now: now.add(const Duration(seconds: 1)),
      );
      final events = detector.update(
        printerSerial: 'P1',
        printerLabel: '混合供料',
        trays: trays,
        units: units,
        trayNow: '254',
        hwSwitchState: 1,
        printStage: 24,
        now: now.add(const Duration(seconds: 2)),
      );

      expect(events.single.channelIndex, 255);
      expect(events.single.slotLabel, '外挂料位');
    });
  });

  test('official RFID arriving later clears the pending unknown prompt', () {
    final queue = SpoolChangeQueueNotifier();
    final detectedAt = DateTime(2026, 8, 2, 12);
    queue.observeAll([
      SpoolChangeObservation(
        printerSerial: 'P1',
        printerLabel: '一号机',
        channelIndex: 0,
        previous: const AmsTray(
          amsId: 0,
          slot: 0,
          trayUuid: 'old',
          hasFilament: true,
        ),
        current: const AmsTray(amsId: 0, slot: 0, hasFilament: true),
        detectedAt: detectedAt,
      ),
    ]);
    queue.observeAll([
      SpoolChangeObservation(
        printerSerial: 'P1',
        printerLabel: '一号机',
        channelIndex: 0,
        previous: const AmsTray(amsId: 0, slot: 0, hasFilament: true),
        current: const AmsTray(
          amsId: 0,
          slot: 0,
          trayUuid: 'new',
          trayInfoIdx: 'GFA00',
          traySubBrands: 'Bambu Lab',
          hasFilament: true,
        ),
        detectedAt: detectedAt.add(const Duration(seconds: 2)),
      ),
    ]);

    expect(queue.state, isEmpty);
  });

  test('an insertion upgrades a pending removal at the same location', () {
    final queue = SpoolChangeQueueNotifier();
    final now = DateTime(2026, 8, 2, 12);
    const old = AmsTray(
      amsId: 0,
      slot: 0,
      trayUuid: 'old',
      hasFilament: true,
    );
    queue.observeAll([
      SpoolChangeObservation(
        printerSerial: 'P1',
        printerLabel: '一号机',
        channelIndex: 0,
        previous: old,
        current: null,
        detectedAt: now,
        kind: SpoolChangeKind.removed,
      ),
    ]);
    queue.observeAll([
      SpoolChangeObservation(
        printerSerial: 'P1',
        printerLabel: '一号机',
        channelIndex: 0,
        previous: old,
        current: const AmsTray(
          amsId: 0,
          slot: 0,
          trayType: 'PLA',
          hasFilament: true,
        ),
        detectedAt: now.add(const Duration(seconds: 2)),
      ),
    ]);

    expect(queue.state, hasLength(1));
    expect(queue.state.single.kind, SpoolChangeKind.inserted);
    expect(queue.state.single.current, isNotNull);
    expect(queue.state.single.previous?.trayUuid, 'old');
  });

  test('insertion is not hidden by a snoozed removal', () {
    final queue = SpoolChangeQueueNotifier();
    final now = DateTime(2026, 8, 2, 12);
    final removal = SpoolChangeObservation(
      printerSerial: 'P1',
      printerLabel: '一号机',
      channelIndex: 0,
      previous: const AmsTray(amsId: 0, slot: 0, hasFilament: true),
      current: null,
      detectedAt: now,
      kind: SpoolChangeKind.removed,
    );
    queue.enqueue(removal);
    queue.snooze(removal);
    queue.enqueue(
      SpoolChangeObservation(
        printerSerial: 'P1',
        printerLabel: '一号机',
        channelIndex: 0,
        previous: removal.previous,
        current: const AmsTray(
          amsId: 0,
          slot: 0,
          trayType: 'PLA',
          hasFilament: true,
        ),
        detectedAt: now.add(const Duration(seconds: 1)),
      ),
    );

    expect(queue.state, hasLength(1));
    expect(queue.state.single.kind, SpoolChangeKind.inserted);
  });

  test('only incomplete AMS identity and external feeds require configuration',
      () {
    final now = DateTime(2026, 8, 2, 12);
    SpoolChangeObservation event(AmsTray tray, {bool external = false}) {
      return SpoolChangeObservation(
        printerSerial: 'P1',
        printerLabel: '一号机',
        channelIndex: external ? 255 : 0,
        previous: null,
        current: tray,
        detectedAt: now,
        isExternal: external,
      );
    }

    expect(
      spoolChangeRequiresConfiguration(
        event(
          const AmsTray(
            amsId: 0,
            slot: 0,
            trayInfoIdx: 'GFA00',
            trayUuid: 'official-uuid',
            traySubBrands: 'Bambu Lab',
            hasFilament: true,
          ),
        ),
      ),
      isFalse,
    );
    expect(
      spoolChangeRequiresConfiguration(
        event(
          const AmsTray(
            amsId: 0,
            slot: 0,
            trayInfoIdx: 'GFA00',
            hasFilament: true,
          ),
        ),
      ),
      isTrue,
    );
    expect(
      spoolChangeRequiresConfiguration(
        event(
          const AmsTray(
            amsId: -1,
            slot: 0,
            trayTag: 'external',
            hasFilament: true,
          ),
          external: true,
        ),
      ),
      isTrue,
    );
    expect(
      spoolChangeRequiresConfiguration(
        SpoolChangeObservation(
          printerSerial: 'P1',
          printerLabel: '一号机',
          channelIndex: 0,
          previous: const AmsTray(
            amsId: 0,
            slot: 0,
            hasFilament: true,
          ),
          current: null,
          detectedAt: now,
          kind: SpoolChangeKind.removed,
        ),
      ),
      isTrue,
    );
  });

  group('replacement inventory transaction', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    Future<int> addPrinter({String serial = 'P1'}) async {
      final id = await db.into(db.printers).insert(
            PrintersCompanion.insert(
              name: const Value('测试打印机'),
              brand: '拓竹',
              model: 'P1S',
            ),
          );
      await db.customUpdate(
        'UPDATE printers SET serial = ? WHERE id = ?',
        variables: [Variable(serial), Variable(id)],
      );
      return id;
    }

    Future<int> addConsumable(String model, double remaining) {
      return db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: model,
          remainingGrams: Value(remaining),
        ),
      );
    }

    test('third-party old spool uses confirmed grams and returns to stock',
        () async {
      final printerId = await addPrinter();
      final oldId = await addConsumable('old', 800);
      final newId = await addConsumable('new', 1000);
      await db.into(db.printerChannels).insert(
            PrinterChannelsCompanion.insert(
              printerId: printerId,
              channelIndex: 0,
              consumableId: Value(oldId),
            ),
          );

      await db.printerDao.bindSpoolReplacement(
        printerId: printerId,
        channelIndex: 0,
        consumableId: newId,
        manualRemainingGrams: 320,
      );

      final old = await db.consumableDao.getById(oldId);
      expect(old!.remainingGrams, 320);
      expect(old.totalGrams, 1000);
      expect(await db.printerDao.getConsumableIdByChannel(printerId, 0), newId);
      final logs = await db.customSelect(
        'SELECT consumed_grams, finished, note FROM usage_logs '
        'WHERE consumable_id = ?',
        variables: [Variable(oldId)],
      ).get();
      expect(logs.single.read<double>('consumed_grams'), 480);
      expect(logs.single.read<bool>('finished'), isFalse);
      expect(logs.single.read<String?>('note'), '换卷时确认的未记账消耗');
    });

    test('empty AMS snapshot preserves old binding until confirmation',
        () async {
      final printerId = await addPrinter();
      final oldId = await addConsumable('old', 640);
      await db.into(db.printerChannels).insert(
            PrinterChannelsCompanion.insert(
              printerId: printerId,
              channelIndex: 0,
              consumableId: Value(oldId),
            ),
          );

      await db.printerDao.syncChannelsFromAms(
        printerId,
        const [AmsTray(amsId: 0, slot: 0, hasFilament: false)],
        autoBindRfid: false,
        unbindEmpty: false,
      );

      expect(await db.printerDao.getConsumableIdByChannel(printerId, 0), oldId);
    });

    test('official RFID spool is auto-created and bound without a prompt',
        () async {
      final printerId = await addPrinter();
      await db.printerDao.syncChannelsFromAms(
        printerId,
        const [
          AmsTray(
            amsId: 0,
            slot: 0,
            trayUuid: 'official-new',
            trayInfoIdx: 'GFA00',
            trayType: 'PLA',
            trayColor: '33AAFFFF',
            traySubBrands: 'Bambu Lab',
            trayWeight: 1000,
            remain: 84,
            hasFilament: true,
          ),
        ],
        autoBindRfid: true,
        unbindEmpty: false,
      );

      final boundId =
          await db.printerDao.getConsumableIdByChannel(printerId, 0);
      expect(boundId, isNotNull);
      final bound = await db.consumableDao.getById(boundId!);
      expect(bound!.trayUuid, 'official-new');
      expect(bound.remainingGrams, 840);
      expect(bound.note, 'RFID 自动建档');
    });

    test('a new official spool replaces an occupied channel automatically',
        () async {
      final printerId = await addPrinter();
      final oldId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Bambu Lab',
          model: 'GFA00',
          materialType: const Value('PLA'),
          colorHex: const Value('#33AAFF'),
          totalGrams: const Value(1000),
          remainingGrams: const Value(640),
        ),
      );
      await db.consumableDao.updateTrayUuid(oldId, 'official-old');
      await db.into(db.printerChannels).insert(
            PrinterChannelsCompanion.insert(
              printerId: printerId,
              channelIndex: 0,
              consumableId: Value(oldId),
            ),
          );

      await db.printerDao.syncChannelsFromAms(
        printerId,
        const [
          AmsTray(
            amsId: 0,
            slot: 0,
            trayUuid: 'official-new',
            trayInfoIdx: 'GFA00',
            trayType: 'PLA',
            trayColor: '33AAFFFF',
            traySubBrands: 'Bambu Lab',
            trayWeight: 1000,
            remain: 100,
            hasFilament: true,
          ),
        ],
        autoBindRfid: true,
        unbindEmpty: false,
      );

      final newId = await db.printerDao.getConsumableIdByChannel(printerId, 0);
      expect(newId, isNot(oldId));
      expect(
        (await db.consumableDao.getById(newId!))!.trayUuid,
        'official-new',
      );
      expect((await db.consumableDao.getById(oldId))!.remainingGrams, 640);
      final logs = await db.customSelect(
        'SELECT finished, note FROM usage_logs WHERE consumable_id = ?',
        variables: [Variable(oldId)],
      ).get();
      expect(logs, isEmpty); // 360g 历史差额不是本次换卷消耗。
    });

    test('AMS HT creates only its reported sparse physical slot', () async {
      final printerId = await addPrinter(serial: 'HT');
      await db.printerDao.syncChannelsFromAms(
        printerId,
        const [AmsTray(amsId: 128, slot: 0, hasFilament: false)],
        autoBindRfid: false,
        unbindEmpty: false,
      );

      final rows = await db.customSelect(
        'SELECT channel_index FROM printer_channels WHERE printer_id = ?',
        variables: [Variable(printerId)],
      ).get();
      expect(rows.map((row) => row.read<int>('channel_index')), [16]);
      expect((await db.printerDao.getById(printerId))!.channelCount, 1);
    });

    test('an RFID spool is unbound from its previous printer when moved',
        () async {
      final firstPrinterId = await addPrinter(serial: 'P1');
      final secondPrinterId = await addPrinter(serial: 'P2');
      final spoolId = await addConsumable('RFID', 700);
      await db.into(db.printerChannels).insert(
            PrinterChannelsCompanion.insert(
              printerId: firstPrinterId,
              channelIndex: 0,
              consumableId: Value(spoolId),
            ),
          );
      await db.into(db.printerChannels).insert(
            PrinterChannelsCompanion.insert(
              printerId: secondPrinterId,
              channelIndex: 0,
            ),
          );

      await db.printerDao.bindSpoolReplacement(
        printerId: secondPrinterId,
        channelIndex: 0,
        consumableId: spoolId,
        uniquePhysicalSpool: true,
      );

      expect(
        await db.printerDao.getConsumableIdByChannel(firstPrinterId, 0),
        isNull,
      );
      expect(
        await db.printerDao.getConsumableIdByChannel(secondPrinterId, 0),
        spoolId,
      );
    });
  });
}
