import 'dart:io';

import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('v48 mobile tag bindings migrate without changing official tray UUIDs',
      () async {
    final directory = await Directory.systemTemp.createTemp('rfid_lifecycle_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/inventory.sqlite');
    final old = AppDatabase.forTestingAtVersion(NativeDatabase(file), 48);
    await old.customStatement('''
      INSERT INTO consumables(
        uid, manufacturer, model, total_grams, remaining_grams,
        tray_uuid, inventory_scope, owner_account
      ) VALUES (
        'legacy-mobile-spool', 'eSUN', 'PLA', 1000, 0,
        '04A1B2C3', 'personal', 'alice@example.com|personal'
      )
    ''');
    await old.customStatement('''
      INSERT INTO consumables(
        uid, manufacturer, model, total_grams, remaining_grams,
        tray_uuid, inventory_scope
      ) VALUES (
        'official-spool', 'Bambu', 'PLA Basic', 1000, 700,
        'official-tray-uuid', 'personal'
      )
    ''');
    await old.customStatement('''
      INSERT INTO rfid_tag_records(
        tag_uid, profile, occurred_at, created_at, updated_at
      ) VALUES ('04:A1:B2:C3', 'ams', 1, 1, 1)
    ''');
    await old.close();

    final database = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(database.close);
    final dao = database.consumableDao;
    final mobile = await dao.getPersonalByUid(
      'legacy-mobile-spool',
      ownerAccount: 'alice@example.com|personal',
    );
    expect(mobile, isNotNull);
    expect(mobile!.trayUuid, isNull);
    expect(mobile.remainingGrams, 0);
    final binding = await dao.getRfidSpoolBindingById(mobile.id);
    expect(binding!.cycle, 1);
    expect(binding.status, 'depleted');
    final history = await dao.getPersonalRfidSpoolHistory(
      '04 a1 b2 c3',
      ownerAccount: 'alice@example.com|personal',
    );
    expect(history.single.inventoryUid, 'legacy-mobile-spool');

    final official = await dao.getPersonalByUid('official-spool');
    expect(official!.trayUuid, 'official-tray-uuid');
    final officialBinding = await dao.getRfidSpoolBindingById(official.id);
    expect(officialBinding!.tagUid, isEmpty);
  });
}
