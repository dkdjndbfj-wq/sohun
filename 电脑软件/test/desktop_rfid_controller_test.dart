import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/features/rfid/desktop_rfid_bridge.dart';
import 'package:consumable_tracker_desktop/features/rfid/desktop_rfid_controller.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ams_template_fixture.dart';
import 'support/desktop_rfid_fixture.dart';

const draft = MobileConsumableDraft(
  brand: 'eSUN',
  model: 'PLA',
  color: Color(0xFF12AB34),
  colorName: '绿',
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late FakeDesktopSerial serial;
  late DesktopRfidBridge bridge;
  late MemoryRfidJournal journal;
  late DesktopRfidController controller;
  bool active = true;
  Future<DesktopRfidController> create({String owner = 'alice'}) async {
    final c = DesktopRfidController(
      bridge: bridge,
      sync: LocalMobileInventorySync(db.consumableDao),
      journal: journal,
      owner: owner,
      isCurrent: () => active,
    );
    await c.ready;
    return c;
  }

  setUp(() async {
    active = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    serial = FakeDesktopSerial();
    bridge = DesktopRfidBridge(transport: serial);
    journal = MemoryRfidJournal();
    controller = await create();
    await bridge.connect('COM7');
  });
  tearDown(() async {
    controller.dispose();
    bridge.dispose();
    await serial.controller.close();
    await db.close();
  });
  Future<int> count() async =>
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM consumables')
              .getSingle())
          .read<int>('n');
  Future<void> scan({
    RfidReceiptMode mode = RfidReceiptMode.individual,
    int quantity = 1,
  }) => controller.enqueueScan(
    draft: draft,
    grams: 1000,
    kind: 'cuid',
    typeConfirmed: true,
    mode: mode,
    quantity: quantity,
  );

  test(
    'read goes to durable queue only; explicit commit reuses real personal DAO',
    () async {
      await scan();
      expect(await count(), 0);
      expect(journal.stored['alice'], hasLength(1));
      await controller.commit();
      expect(await count(), 1);
      expect(controller.items.single.done, true);
      final row = await db.consumableDao.getById(1);
      expect(row?.totalGrams, 1000);
    },
  );
  test('duplicate UID cannot create multiple physical spool entries', () async {
    await scan();
    await expectLater(scan(), throwsA(isA<DesktopRfidException>()));
    await controller.commit();
    await controller.commit();
    expect(await count(), 1);
    await controller.newBatch();
    await scan();
    await controller.commit();
    expect(await count(), 1);
  });
  test(
    'USB reconnect invalidates the old target and requires another scan',
    () async {
      controller.selectTemplate(syntheticAmsTemplate());
      await controller.scanTarget();
      expect(controller.target, isNotNull);
      await bridge.disconnect();
      expect(controller.target, isNull);
      await bridge.connect('COM7');
      await expectLater(
        controller.writeTarget(
          draft: draft,
          grams: 1000,
          kind: 'cuid',
          confirmed: true,
        ),
        throwsA(isA<DesktopRfidException>()),
      );
      expect(serial.requests.where((r) => r['cmd'] == 'restore'), isEmpty);
      expect(controller.template, isNotNull);
      expect(await count(), 0);
    },
  );
  test(
    'one source card receives several independent rolls with no shared binding',
    () async {
      await scan(mode: RfidReceiptMode.stock, quantity: 5);
      await controller.commit();
      expect(await count(), 5);
      final rows = await db
          .customSelect(
            'SELECT rfid_tag_uid, stock_receipt_uid FROM consumables',
          )
          .get();
      expect(rows.map((r) => r.data['rfid_tag_uid']), everyElement(isNull));
      expect(
        rows.map((r) => r.data['stock_receipt_uid']).toSet(),
        hasLength(1),
      );
    },
  );
  test(
    'restart replays same receipt UUID after uncertain UI acknowledgement',
    () async {
      await scan(mode: RfidReceiptMode.stock, quantity: 3);
      final pending = journal.stored['alice']!
          .map((e) => Map<String, Object>.from(e))
          .toList();
      final id = controller.items.single.id;
      await controller.commit();
      expect(await count(), 3);
      journal.stored['alice'] = pending;
      controller.dispose();
      controller = await create();
      expect(controller.items.single.id, id);
      await controller.commit();
      expect(await count(), 3);
      expect(controller.items.single.feedback, contains('未重复新增'));
    },
  );
  test(
    'source template writes only reach queue after 64 blocks and UID verify',
    () async {
      controller.selectTemplate(syntheticAmsTemplate());
      await controller.scanTarget();
      await controller.writeTarget(
        draft: draft,
        grams: 1000,
        kind: 'fuid',
        confirmed: true,
      );
      expect(controller.items.single.writeVerified, true);
      expect(await count(), 0);
      await controller.commit();
      expect(await count(), 1);
      expect(journal.stored.toString(), isNot(contains('blocks')));
      expect(journal.stored.toString(), isNot(contains('template')));
    },
  );
  test(
    'incomplete write verification cannot queue or save inventory',
    () async {
      controller.selectTemplate(syntheticAmsTemplate());
      await controller.scanTarget();
      serial.validVerification = false;
      await expectLater(
        controller.writeTarget(
          draft: draft,
          grams: 1000,
          kind: 'cuid',
          confirmed: true,
        ),
        throwsA(isA<DesktopRfidException>()),
      );
      expect(controller.items, isEmpty);
      expect(await count(), 0);
      expect(controller.target, isNull);
    },
  );
  test('account changes discard late device success', () async {
    serial.autoReply = false;
    final operation = scan();
    active = false;
    serial.result(serial.requests.last, {
      'uid': serial.uid,
      'technology': 'mifare_classic',
      'sizeBytes': 1024,
      'blockCount': 64,
      'uidLengthBytes': 4,
    });
    await operation;
    expect(controller.items, isEmpty);
    expect(await count(), 0);
  });
  test('another account never restores this owner queue', () async {
    await scan();
    controller.dispose();
    controller = await create(owner: 'bob');
    expect(controller.items, isEmpty);
  });
  test('unconfirmed CUID/FUID or invalid quantity performs no scan', () async {
    await expectLater(
      controller.enqueueScan(
        draft: draft,
        grams: 1000,
        kind: 'ntag213',
        typeConfirmed: true,
        mode: RfidReceiptMode.individual,
      ),
      throwsA(isA<DesktopRfidException>()),
    );
    await expectLater(
      scan(mode: RfidReceiptMode.stock, quantity: 101),
      throwsA(isA<DesktopRfidException>()),
    );
    expect(serial.requests.where((e) => e['cmd'] == 'scan'), isEmpty);
  });
  test(
    'a damaged journal blocks new hardware work without replacing data',
    () async {
      controller.dispose();
      journal.fail = true;
      controller = await create();
      expect(controller.journalHealthy, false);
      await expectLater(scan(), throwsA(isA<DesktopRfidException>()));
    },
  );
  test('pending work cannot be silently cleared into a new receipt', () async {
    await scan();
    await expectLater(
      controller.newBatch(),
      throwsA(isA<DesktopRfidException>()),
    );
    expect(controller.items, hasLength(1));
  });
  test(
    'remaining mode stores one real remainder and rejects multi-remainder batches',
    () async {
      await controller.enqueueScan(
        draft: draft,
        grams: 350,
        kind: 'cuid',
        typeConfirmed: true,
        mode: RfidReceiptMode.stock,
        quantity: 1,
      );
      await controller.commit();
      final row = await db.consumableDao.getById(1);
      expect(row?.totalGrams, 350);
      expect(row?.remainingGrams, 350);
      await expectLater(
        controller.enqueueScan(
          draft: draft,
          grams: 350,
          kind: 'cuid',
          typeConfirmed: true,
          mode: RfidReceiptMode.stock,
          quantity: 2,
        ),
        throwsA(isA<DesktopRfidException>()),
      );
      await expectLater(
        controller.enqueueScan(
          draft: draft,
          grams: 1001,
          kind: 'cuid',
          typeConfirmed: true,
          mode: RfidReceiptMode.individual,
        ),
        throwsA(isA<DesktopRfidException>()),
      );
    },
  );
  test(
    'new full-roll registration never normalizes an existing 2kg spool',
    () async {
      await LocalMobileInventorySync(
        db.consumableDao,
      ).save(draft, tagId: serial.uid, tagType: 'cuid', initialGrams: 2000);
      await scan();
      await controller.commit();
      final row = await db.consumableDao.getById(1);
      expect(row?.totalGrams, 2000);
      expect(row?.remainingGrams, 2000);
      expect(await count(), 1);
    },
  );
  test(
    'read or write queue survives ordinary close without redoing USB commands',
    () async {
      await scan();
      final before = serial.requests.length;
      controller.dispose();
      controller = await create();
      expect(controller.items, hasLength(1));
      await controller.commit();
      expect(serial.requests.length, before);
      expect(await count(), 1);
    },
  );
}
