import 'dart:io';

import 'package:consumable_tracker_desktop/core/services/consumable_twin_service.dart';
import 'package:consumable_tracker_desktop/core/services/personal_inventory_sync_service.dart';
import 'package:consumable_tracker_desktop/core/services/spool_change_detector.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/personal_ams_identity.dart';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/data/models/rfid_tag_identity.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/features/print_task/spool_change_confirmation_dialog.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/filament_cost_provider.dart';
import 'package:consumable_tracker_desktop/providers/spool_change_provider.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _tag = 'D021B75E';
const _reported = 'D021B75E00000100';
const _templateUuid = '11111111222233334444555555555555';
const _owner = 'alias@example.com|personal';

AmsTray _tray({String uid = _reported, int slot = 0}) => AmsTray(
  amsId: 0,
  slot: slot,
  tagUid: uid,
  trayUuid: _templateUuid,
  traySubBrands: 'Bambu Lab',
  trayType: 'PETG',
  trayInfoIdx: 'GFG00',
  trayColor: 'FFFFFFFF',
  trayWeight: 1000,
  remain: 33,
  hasFilament: true,
);

Future<int> _spool(
  AppDatabase db, {
  String uid = 'physical-roll-one',
  String tag = _tag,
  String type = 'CUID',
  String? owner = _owner,
  int cycle = 1,
  String status = 'active',
}) async {
  final id = await db.consumableDao.addConsumable(
    ConsumablesCompanion.insert(
      uid: Value(uid),
      manufacturer: 'eSUN',
      model: 'PLA+',
      materialType: const Value('PLA'),
      totalGrams: const Value(1000),
      remainingGrams: const Value(375),
      colorName: const Value('星空蓝'),
      colorHex: const Value('#2244CC'),
    ),
  );
  await db.customUpdate(
    'UPDATE consumables SET owner_account = ? WHERE id = ?',
    variables: [Variable(owner), Variable(id)],
  );
  await db.consumableDao.setRfidSpoolBinding(
    id,
    tagUid: tag,
    tagType: type,
    cycle: cycle,
    status: status,
  );
  return id;
}

AppAuthSession _personalSession({
  String id = 'ams-stock-ui-user',
  String email = 'alias@example.com',
}) {
  final now = DateTime.utc(2026, 9, 9);
  return AppAuthSession(
    user: AppUser(
      id: id,
      email: email,
      handle: id.toLowerCase(),
      displayName: id,
      emailVerified: true,
      createdAt: now,
      updatedAt: now,
    ),
    accessToken: 'access-$id',
    refreshToken: 'refresh-$id',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    refreshExpiresAt: DateTime.now().add(const Duration(days: 30)),
    serverBaseUrl: 'https://inventory.example.com',
  );
}

class _TestAuth extends AppAuthNotifier {
  _TestAuth(AppAuthSession session)
    : super(
        serverSettings: CommunityServerSettings(
          store: _ServerStore(),
          compileTimeBaseUrl: session.serverBaseUrl,
        ),
        sessionStore: _SessionStore(session),
        apiFactory: (_) => _CommunityApi(),
      );
}

class _SessionStore implements AppAuthSessionStore {
  _SessionStore(this.session);

  final AppAuthSession session;

  @override
  Future<AppAuthSession?> read() async => session;

  @override
  Future<void> write(AppAuthSession session) async {}

  @override
  Future<void> clear() async {}
}

class _ServerStore implements CommunityServerOverrideStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}

  @override
  Future<void> clear() async {}
}

class _CommunityApi extends Fake implements CommunityApi {}

Future<int> _printer(AppDatabase db) => db
    .into(db.printers)
    .insert(
      PrintersCompanion.insert(
        brand: '拓竹',
        model: 'P1S',
        name: const Value('工作台'),
        channelCount: const Value(2),
      ),
    );

Future<PersonalStockReceipt> _receivedStock(
  AppDatabase db, {
  int quantity = 2,
  String owner = _owner,
}) => db.consumableDao.addPersonalStockFromRfidCard(
  operationUid: 'ae4743a2-2b61-4c96-84e1-f8c7420450f1',
  tagUid: _tag,
  tagType: 'CUID',
  template: PersonalInventoryRecord(
    uid: 'material-card-template',
    manufacturer: 'eSUN',
    model: 'PLA+',
    materialType: 'PLA',
    colorHex: '#2244CC',
    colorName: '星空蓝',
    totalGrams: 1000,
    remainingGrams: 1000,
    createdAt: DateTime.utc(2026, 9, 9),
    updatedAt: DateTime.utc(2026, 9, 9),
  ),
  quantity: quantity,
  ownerAccount: owner,
);

Future<void> _sync(AppDatabase db, int printer, {List<AmsTray>? trays}) =>
    db.printerDao.syncChannelsFromAms(
      printer,
      trays ?? [_tray()],
      autoBindRfid: true,
      unbindEmpty: false,
    );

Future<void> _confirm(AppDatabase db, int printer, int spool) =>
    db.printerDao.bindSpoolReplacement(
      printerId: printer,
      channelIndex: 0,
      consumableId: spool,
      confirmedAmsUid: _reported,
    );

Future<int> _aliasCount(AppDatabase db) async =>
    (await db
            .customSelect('SELECT COUNT(*) AS n FROM personal_ams_uid_aliases')
            .getSingle())
        .read<int>('n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final type in ['NTAG213', 'NTAG213 CUID', 'CLASSIC', '']) {
    test(
      'unsupported or unconfirmed $type history cannot bind or become a new official spool',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final id = await _spool(db, type: type);
        final printer = await _printer(db);
        final twin = ConsumableTwinService(db);
        for (final reported in [_tag, _reported]) {
          final resolution = (await PersonalAmsIdentityResolver.load(
            db,
          )).resolve(reported);
          expect(resolution.requiresConfirmation, isTrue);
          expect(resolution.isPersonalTag, isFalse);
          expect(resolution.currentConsumableId, isNull);
          expect(resolution.candidates, isEmpty);
          final trays = [_tray(uid: reported)];
          await _sync(db, printer, trays: trays);
          await twin.handleAmsTrays(
            printerId: printer,
            printerSerial: 'INVALID-TYPE',
            trays: trays,
          );
          expect(
            await db.printerDao.getConsumableIdByChannel(printer, 0),
            isNull,
          );
        }
        await expectLater(_confirm(db, printer, id), throwsStateError);
        expect(await _aliasCount(db), 0);
        expect(await db.select(db.consumables).get(), hasLength(1));
        final roll = (await db.consumableDao.getById(id))!;
        expect(roll.remainingGrams, 375);
        expect(await twin.getTimeline(rfidSpoolLedgerKey(roll.uid)), isEmpty);
      },
    );
  }

  test(
    'a previously confirmed alias cannot authorize a changed unsupported card type',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db);
      final printer = await _printer(db);
      await _confirm(db, printer, id);
      await db.consumableDao.setRfidSpoolBinding(
        id,
        tagUid: _tag,
        tagType: 'NTAG213',
        cycle: 1,
        status: 'active',
      );
      final resolved = (await PersonalAmsIdentityResolver.load(
        db,
      )).resolve(_reported);
      expect(resolved.requiresConfirmation, isTrue);
      expect(resolved.isPersonalTag, isFalse);
      expect(resolved.currentConsumableId, isNull);
      expect((await db.consumableDao.getById(id))!.remainingGrams, 375);
    },
  );

  test(
    'full AMS UID suggests confirmation but never changes NFC identity',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db);
      final resolver = await PersonalAmsIdentityResolver.load(db);
      final result = resolver.resolve('d0:21:b7:5e:00:00:01:00');
      expect(result.reportedUid, _reported);
      expect(result.tagUid, _reported);
      expect(result.requiresConfirmation, isTrue);
      expect(result.candidates.single.consumableId, id);
      expect(
        result.collisionKeys,
        containsAll([_tag.toLowerCase(), _reported.toLowerCase()]),
      );
      expect(rfidTagUidEquals(_tag, _reported), isFalse);
      expect(normalizeRfidTagUid(_reported), _reported);
      expect(resolver.resolve('${_tag}FFFFFFFF').requiresConfirmation, isTrue);
      expect(resolver.resolve('04AABBCCDDEEFF').requiresConfirmation, isFalse);
      expect(
        resolver.resolve('04AABBCCDDEEFF112233').tagUid,
        '04AABBCCDDEEFF112233',
      );
    },
  );

  test(
    'owner-scoped AMS candidates and queued events cannot cross accounts',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final aliceOwner = PersonalInventorySyncService.ownerAccountFor(
        _personalSession(id: 'ams-alice', email: 'same@example.com'),
      );
      final bobOwner = PersonalInventorySyncService.ownerAccountFor(
        _personalSession(id: 'ams-bob', email: 'same@example.com'),
      );
      final aliceId = await _spool(
        db,
        uid: 'alice-private-roll',
        owner: aliceOwner,
      );
      final bobId = await _spool(db, uid: 'bob-private-roll', owner: bobOwner);

      final aliceIdentity = (await PersonalAmsIdentityResolver.load(
        db,
        ownerAccount: aliceOwner,
      )).resolve(_reported);
      final bobIdentity = (await PersonalAmsIdentityResolver.load(
        db,
        ownerAccount: bobOwner,
      )).resolve(_reported);
      expect(aliceIdentity.candidates.map((item) => item.consumableId), [
        aliceId,
      ]);
      expect(bobIdentity.candidates.map((item) => item.consumableId), [bobId]);

      final printer = await _printer(db);
      final queue = SpoolChangeQueueNotifier();
      addTearDown(queue.dispose);
      queue.usePersonalOwner(aliceOwner);
      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printer,
        printerSerial: 'ACCOUNT-SWITCH',
        printerLabel: '工作台',
        status: BambuPrinterStatus(
          serial: 'ACCOUNT-SWITCH',
          amsTrays: [_tray()],
        ),
        personalOwnerAccount: aliceOwner,
      );
      expect(queue.state.single.rfidCandidateIds, [aliceId]);

      queue.usePersonalOwner(bobOwner);
      expect(queue.state, isEmpty);
      queue.enqueue(
        SpoolChangeObservation.manualEvent(
          printerSerial: 'ACCOUNT-SWITCH',
          printerLabel: '工作台',
          printerId: printer,
          channelIndex: 0,
        ).forPersonalOwner(aliceOwner),
      );
      expect(queue.state, isEmpty);

      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printer,
        printerSerial: 'ACCOUNT-SWITCH',
        printerLabel: '工作台',
        status: BambuPrinterStatus(
          serial: 'ACCOUNT-SWITCH',
          amsTrays: [_tray()],
        ),
        personalOwnerAccount: bobOwner,
      );
      expect(queue.state.single.rfidCandidateIds, [bobId]);
      expect(queue.state.single.personalOwnerAccount, bobOwner);
    },
  );

  test(
    'unconfirmed template neither creates inventory nor overwrites the registered roll',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db);
      final printer = await _printer(db);
      expect(_tray().isBambuOfficialRfid, isTrue);
      await _sync(db, printer);
      final twin = ConsumableTwinService(db);
      await twin.handleAmsTrays(
        printerId: printer,
        printerSerial: 'AMS-ALIAS',
        trays: [_tray()],
      );
      expect(await db.printerDao.getConsumableIdByChannel(printer, 0), isNull);
      expect((await db.select(db.consumables).get()).length, 1);
      final roll = (await db.consumableDao.getById(id))!;
      expect(roll.remainingGrams, 375);
      expect(roll.manufacturer, 'eSUN');
      expect(roll.materialType, 'PLA');
      expect(await twin.getTimeline(rfidSpoolLedgerKey(roll.uid)), isEmpty);
      final queue = SpoolChangeQueueNotifier();
      addTearDown(queue.dispose);
      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printer,
        printerSerial: 'AMS-ALIAS',
        printerLabel: '工作台',
        status: BambuPrinterStatus(serial: 'AMS-ALIAS', amsTrays: [_tray()]),
        personalOwnerAccount: _owner,
      );
      expect(queue.state.single.requiresRfidConfirmation, isTrue);
      expect(queue.state.single.rfidCandidateIds, [id]);
      expect(queue.state.single.rfidCandidateUids[id], _tag);
      expect(queue.state.single.hasRfidIdentity, isFalse);
    },
  );

  test(
    'confirmation binds the canonical physical roll without adopting template data',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db);
      final printer = await _printer(db);
      await _confirm(db, printer, id);
      await _sync(db, printer);
      await _sync(db, printer);
      final twin = ConsumableTwinService(db);
      await twin.handleAmsTrays(
        printerId: printer,
        printerSerial: 'AMS-ALIAS',
        trays: [_tray()],
      );
      final roll = (await db.consumableDao.getById(id))!;
      expect(await _aliasCount(db), 1);
      expect(await db.printerDao.getConsumableIdByChannel(printer, 0), id);
      expect(roll.remainingGrams, 375);
      expect(roll.totalGrams, 1000);
      expect(roll.trayUuid, isNull);
      expect(
        (await twin.getTimeline(rfidSpoolLedgerKey(roll.uid))).isNotEmpty,
        isTrue,
      );
      expect(await twin.getTimeline(_templateUuid), isEmpty);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(id))!.tagUid,
        _tag,
      );
      expect((await db.select(db.consumables).get()).length, 1);
    },
  );

  test(
    'repeated telemetry preserves the required confirmation until identity changes',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db);
      final printer = await _printer(db);
      final queue = SpoolChangeQueueNotifier();
      addTearDown(queue.dispose);
      Future<void> enqueue() => enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printer,
        printerSerial: 'AMS-ALIAS',
        printerLabel: '工作台',
        status: BambuPrinterStatus(serial: 'AMS-ALIAS', amsTrays: [_tray()]),
        personalOwnerAccount: _owner,
      );
      SpoolChangeObservation observation(AmsTray tray) =>
          SpoolChangeObservation(
            printerSerial: 'AMS-ALIAS',
            printerLabel: '工作台',
            printerId: printer,
            channelIndex: 0,
            previous: null,
            current: tray,
            detectedAt: DateTime.now(),
          ).forPersonalOwner(_owner);
      await enqueue();
      final firstEventId = queue.state.single.eventId;
      await enqueue();
      queue.enqueue(observation(_tray()));
      queue.observeAll([observation(_tray())]);
      expect(queue.state.single.eventId, firstEventId);
      expect(queue.state.single.requiresRfidConfirmation, isTrue);
      expect(queue.state.single.rfidCandidateIds, [id]);
      expect(queue.state.single.rfidCandidateUids[id], _tag);
      queue.observeAll([observation(_tray(uid: '605AC45E00000100'))]);
      expect(queue.state, isEmpty);
    },
  );

  test(
    'invalid confirmation inputs cannot infer or persist a shortened UID',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db);
      for (final uid in [
        _tag,
        '605AC45E00000100',
        '0000000000000000',
        'not-a-tag',
      ]) {
        await expectLater(
          confirmPersonalAmsIdentity(db, consumableId: id, reportedUid: uid),
          throwsStateError,
        );
      }
      expect(await _aliasCount(db), 0);
    },
  );

  test(
    'orphaned or conflicting aliases block fallback to official inventory creation',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _spool(db);
      final printer = await _printer(db);
      await db.customStatement(
        'INSERT INTO personal_ams_uid_aliases VALUES (?, ?, ?, 1)',
        ['orphan@example.com|personal', _reported, _tag],
      );
      expect(
        (await PersonalAmsIdentityResolver.load(
          db,
        )).resolve(_reported).requiresConfirmation,
        isTrue,
      );
      await _sync(db, printer);
      expect(await db.printerDao.getConsumableIdByChannel(printer, 0), isNull);
      await db.customStatement(
        'INSERT INTO personal_ams_uid_aliases VALUES (?, ?, ?, 1)',
        [_owner, _reported, _tag],
      );
      expect(
        (await PersonalAmsIdentityResolver.load(
          db,
        )).resolve(_reported).requiresConfirmation,
        isTrue,
      );
      await _sync(db, printer);
      expect((await db.select(db.consumables).get()).length, 1);
    },
  );

  test('saved alias follows the next cycle after a database restart', () async {
    final dir = await Directory.systemTemp.createTemp('ams_alias_');
    final file = File('${dir.path}/inventory.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
    final oldId = await _spool(db);
    final printer = await _printer(db);
    await _confirm(db, printer, oldId);
    await db.consumableDao.adjustGrams(oldId, 375);
    final replacement = await db.consumableDao.replacePersonalRfidSpool(
      consumableId: oldId,
      initialGrams: 1000,
    );
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    await _sync(db, printer);
    expect(
      await db.printerDao.getConsumableIdByChannel(printer, 0),
      replacement.consumableId,
    );
    expect(replacement.cycle, 2);
    expect(replacement.inventoryUid, isNot('physical-roll-one'));
    expect((await db.consumableDao.getById(oldId))!.remainingGrams, 0);
    expect(
      (await db.consumableDao.getById(
        replacement.consumableId,
      ))!.remainingGrams,
      1000,
    );
    expect(
      (await PersonalAmsIdentityResolver.load(
        db,
      )).resolve(_reported).requiresConfirmation,
      isFalse,
    );
  });

  test(
    'a retired owner alias cannot select another account or an unowned legacy row',
    () async {
      for (final otherOwner in ['other@example.com|personal', null]) {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final oldId = await _spool(db);
        final printer = await _printer(db);
        await _confirm(db, printer, oldId);
        await db.customUpdate(
          'UPDATE printer_channels SET consumable_id = NULL, loaded_remaining_grams = 0',
        );
        await db.consumableDao.updateRfidSpoolLifecycle(
          oldId,
          status: 'retired',
        );
        final otherId = await _spool(db, uid: 'other-roll', owner: otherOwner);
        final identity = (await PersonalAmsIdentityResolver.load(
          db,
        )).resolve(_reported);
        expect(identity.history.map((b) => b.consumableId), [oldId]);
        expect(identity.currentConsumableId, isNull);
        await _sync(db, printer);
        final twin = ConsumableTwinService(db);
        await twin.handleAmsTrays(
          printerId: printer,
          printerSerial: 'AMS-ALIAS',
          trays: [_tray()],
        );
        expect(
          await db.printerDao.getConsumableIdByChannel(printer, 0),
          isNull,
        );
        expect(
          await twin.getTimeline(rfidSpoolLedgerKey('other-roll')),
          isEmpty,
        );
        expect((await db.consumableDao.getById(otherId))!.remainingGrams, 375);
      }
    },
  );

  test(
    'claiming anonymous inventory carries its confirmed AMS identity to the account',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db, owner: null);
      final printer = await _printer(db);
      await _confirm(db, printer, id);
      await db.consumableDao.setOwnerAccount(id, _owner);
      final identity = (await PersonalAmsIdentityResolver.load(
        db,
      )).resolve(_reported);
      expect(identity.aliasOwner, _owner);
      expect(identity.currentConsumableId, id);
      expect(await _aliasCount(db), 1);
      await _sync(db, printer);
      expect(await db.printerDao.getConsumableIdByChannel(printer, 0), id);
    },
  );

  test(
    'a partial owner transfer cannot move the tag history alias or steal another account mapping',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final first = await _spool(db, owner: null);
      final printer = await _printer(db);
      await _confirm(db, printer, first);
      final next = await db.consumableDao.replacePersonalRfidSpool(
        consumableId: first,
        initialGrams: 1000,
      );
      await db.consumableDao.setOwnerAccount(next.consumableId, _owner);
      var identity = (await PersonalAmsIdentityResolver.load(
        db,
      )).resolve(_reported);
      expect(identity.aliasOwner, '');
      expect(identity.currentConsumableId, isNull);
      await expectLater(
        _confirm(db, printer, next.consumableId),
        throwsStateError,
      );
      await db.consumableDao.setOwnerAccount(first, _owner);
      identity = (await PersonalAmsIdentityResolver.load(
        db,
      )).resolve(_reported);
      expect(identity.aliasOwner, _owner);
      expect(identity.currentConsumableId, next.consumableId);
      expect(await _aliasCount(db), 1);
    },
  );

  test(
    'owner update failure rolls back the inventory and its alias together',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db, owner: null);
      final printer = await _printer(db);
      await _confirm(db, printer, id);
      await db.customStatement(
        "CREATE TRIGGER fail_alias_owner BEFORE UPDATE ON personal_ams_uid_aliases BEGIN SELECT RAISE(ABORT, 'test alias failure'); END",
      );
      await expectLater(
        db.consumableDao.setOwnerAccount(id, _owner),
        throwsA(isA<Exception>()),
      );
      expect(await db.consumableDao.getOwnerAccount(id), isNull);
      expect(
        (await PersonalAmsIdentityResolver.load(
          db,
        )).resolve(_reported).aliasOwner,
        '',
      );
    },
  );

  test(
    'simultaneous full and short UID observations are rejected as one tag in two slots',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db);
      final printer = await _printer(db);
      await _confirm(db, printer, id);
      await db.customUpdate(
        'UPDATE printer_channels SET consumable_id = NULL, loaded_remaining_grams = 0',
      );
      final trays = [_tray(), _tray(uid: _tag, slot: 1)];
      await _sync(db, printer, trays: trays);
      final twin = ConsumableTwinService(db);
      await twin.handleAmsTrays(
        printerId: printer,
        printerSerial: 'AMS-ALIAS',
        trays: trays,
      );
      expect(await db.printerDao.getConsumableIdByChannel(printer, 0), isNull);
      expect(await db.printerDao.getConsumableIdByChannel(printer, 1), isNull);
      expect(
        await twin.getTimeline(rfidSpoolLedgerKey('physical-roll-one')),
        isEmpty,
      );
    },
  );

  test(
    'a registered full-length reusable UID takes precedence over prefix candidates',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _spool(db);
      final fullId = await _spool(db, uid: 'full-roll', tag: _reported);
      final printer = await _printer(db);
      final identity = (await PersonalAmsIdentityResolver.load(
        db,
      )).resolve(_reported);
      expect(identity.requiresConfirmation, isFalse);
      expect(identity.currentConsumableId, fullId);
      await _sync(db, printer);
      expect(await db.printerDao.getConsumableIdByChannel(printer, 0), fullId);
    },
  );

  test(
    'confirmation cannot overwrite an existing complete AMS identity',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db);
      await _spool(
        db,
        uid: 'previous-automatic-roll',
        tag: _reported,
        type: 'ams',
      );
      final printer = await _printer(db);
      await expectLater(_confirm(db, printer, id), throwsStateError);
      expect(await _aliasCount(db), 0);
      expect((await db.select(db.consumables).get()).length, 2);
    },
  );

  test(
    'a failed channel handoff rolls back the identity confirmation as well',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db);
      final printer = await _printer(db);
      await db.printerDao.bindSpoolReplacement(
        printerId: printer,
        channelIndex: 1,
        consumableId: id,
      );
      await expectLater(_confirm(db, printer, id), throwsStateError);
      expect(await _aliasCount(db), 0);
      expect(await db.printerDao.getConsumableIdByChannel(printer, 1), id);
      expect(await db.printerDao.getConsumableIdByChannel(printer, 0), isNull);
    },
  );

  test(
    'forked and stale active cycles cannot be confirmed or automatically selected',
    () async {
      for (final conflict in [('active', 1), ('depleted', 1), ('retired', 2)]) {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final id = await _spool(db);
        await _spool(
          db,
          uid: 'conflicting-roll',
          status: conflict.$1,
          cycle: conflict.$2,
        );
        final printer = await _printer(db);
        expect(
          (await PersonalAmsIdentityResolver.load(
            db,
          )).resolve(_tag).currentConsumableId,
          isNull,
        );
        await expectLater(_confirm(db, printer, id), throwsStateError);
        await _sync(db, printer, trays: [_tray(uid: _tag)]);
        expect(
          await db.printerDao.getConsumableIdByChannel(printer, 0),
          isNull,
        );
      }
    },
  );

  test(
    'source-only material card exposes concrete stock UIDs and selection atomically activates one',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final receipt = await _receivedStock(db);
      final printer = await _printer(db);
      final queue = SpoolChangeQueueNotifier();
      addTearDown(queue.dispose);

      await _sync(db, printer);
      expect(await db.printerDao.getConsumableIdByChannel(printer, 0), isNull);
      expect((await db.select(db.consumables).get()), hasLength(2));

      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printer,
        printerSerial: 'AMS-STOCK',
        printerLabel: '工作台',
        status: BambuPrinterStatus(serial: 'AMS-STOCK', amsTrays: [_tray()]),
        personalOwnerAccount: _owner,
      );

      final event = queue.state.single;
      expect(event.requiresRfidConfirmation, isTrue);
      expect(event.rfidCandidateIds.toSet(), receipt.consumableIds.toSet());
      expect(
        event.rfidCandidateInventoryUids.values.toSet(),
        receipt.inventoryUids.toSet(),
      );
      expect(
        event.rfidStockCandidates.keys.toSet(),
        receipt.consumableIds.toSet(),
      );

      final selectedId = receipt.consumableIds.last;
      final selected = event.rfidStockCandidates[selectedId]!;
      await db.printerDao.bindSpoolReplacement(
        printerId: printer,
        channelIndex: 0,
        consumableId: selectedId,
        uniquePhysicalSpool: true,
        confirmedAmsUid: _reported,
        sourceTagUid: selected.tagUid,
        sourceTagType: selected.tagType,
        sourceOwnerAccount: selected.ownerAccount,
      );

      expect(
        await db.printerDao.getConsumableIdByChannel(printer, 0),
        selectedId,
      );
      expect((await db.select(db.consumables).get()), hasLength(2));
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(
          receipt.consumableIds.first,
        ))!.tagUid,
        isEmpty,
      );
      final binding = (await db.consumableDao.getRfidSpoolBindingById(
        selectedId,
      ))!;
      expect(binding.tagUid, _tag);
      expect(binding.inventoryUid, receipt.inventoryUids.last);
      expect(binding.isActive, isTrue);
      expect(await _aliasCount(db), 1);
      final resolved = (await PersonalAmsIdentityResolver.load(
        db,
      )).resolve(_reported);
      expect(resolved.requiresConfirmation, isFalse);
      expect(resolved.currentConsumableId, selectedId);
      await _sync(db, printer);
      expect(
        await db.printerDao.getConsumableIdByChannel(printer, 0),
        selectedId,
      );
      expect((await db.select(db.consumables).get()), hasLength(2));
      final roll = (await db.consumableDao.getById(selectedId))!;
      expect(roll.remainingGrams, 1000);
      expect(roll.trayUuid, isNull);
    },
  );

  test(
    'a reusable material card can offer a replaced roll with its retained remainder',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final receipt = await _receivedStock(db);
      final printer = await _printer(db);
      final firstId = receipt.consumableIds.first;
      final secondId = receipt.consumableIds.last;

      await db.printerDao.bindSpoolReplacement(
        printerId: printer,
        channelIndex: 0,
        consumableId: firstId,
        uniquePhysicalSpool: true,
        confirmedAmsUid: _reported,
        sourceTagUid: _tag,
        sourceTagType: 'CUID',
        sourceOwnerAccount: _owner,
      );
      await db.consumableDao.adjustGrams(firstId, 500);
      await db.printerDao.bindSpoolReplacement(
        printerId: printer,
        channelIndex: 0,
        consumableId: secondId,
        uniquePhysicalSpool: true,
        confirmedAmsUid: _reported,
        sourceTagUid: _tag,
        sourceTagType: 'CUID',
        sourceOwnerAccount: _owner,
      );

      final identity = (await PersonalAmsIdentityResolver.load(
        db,
        ownerAccount: _owner,
      )).resolve(_reported);
      expect(identity.currentConsumableId, secondId);
      expect(
        identity.stockCandidates.map((candidate) => candidate.consumableId),
        [firstId],
      );
      expect((await db.consumableDao.getById(firstId))!.remainingGrams, 500);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(firstId))!.status,
        'replaced',
      );
    },
  );

  test(
    'failed channel write rolls back source-stock activation and AMS alias',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final receipt = await _receivedStock(db, quantity: 1);
      final resolver = await PersonalAmsIdentityResolver.load(db);
      final stock = resolver.resolve(_reported).stockCandidates.single;

      await expectLater(
        db.printerDao.bindSpoolReplacement(
          printerId: 999999,
          channelIndex: 0,
          consumableId: stock.consumableId,
          uniquePhysicalSpool: true,
          confirmedAmsUid: _reported,
          sourceTagUid: stock.tagUid,
          sourceTagType: stock.tagType,
          sourceOwnerAccount: stock.ownerAccount,
        ),
        throwsA(anything),
      );

      expect(await _aliasCount(db), 0);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(
          receipt.consumableIds.single,
        ))!.tagUid,
        isEmpty,
      );
      expect(
        (await PersonalAmsIdentityResolver.load(
          db,
        )).resolve(_reported).currentConsumableId,
        isNull,
      );
    },
  );

  test(
    'changing tag_uid with the same copied tray_uuid is still a physical change',
    () {
      expect(
        SpoolChangeObservation.trayIdentity(_tray()),
        isNot(
          SpoolChangeObservation.trayIdentity(_tray(uid: '605AC45E00000100')),
        ),
      );
    },
  );

  test(
    'v52 migration preserves registered UID and starts with no inferred aliases',
    () async {
      final dir = await Directory.systemTemp.createTemp('ams_alias_migration_');
      final file = File('${dir.path}/inventory.sqlite');
      var db = AppDatabase.forTestingAtVersion(NativeDatabase(file), 52);
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
      final id = await _spool(db);
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect(await _aliasCount(db), 0);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(id))!.tagUid,
        _tag,
      );
      expect((await db.consumableDao.getById(id))!.remainingGrams, 375);
    },
  );

  testWidgets(
    'material-card confirmation requires choosing the concrete inventory UID',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final session = _personalSession();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final receipt = await _receivedStock(db, owner: owner);
      final auth = _TestAuth(session);
      await auth.ready;
      final printer = await _printer(db);
      final queue = SpoolChangeQueueNotifier();
      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printer,
        printerSerial: 'AMS-STOCK-UI',
        printerLabel: '工作台',
        status: BambuPrinterStatus(serial: 'AMS-STOCK-UI', amsTrays: [_tray()]),
        personalOwnerAccount: owner,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appAuthProvider.overrideWith((ref) => auth),
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

      final confirm = find.widgetWithText(FilledButton, '请选择具体卷');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(find.textContaining('可对应多卷库存'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('choose-spool-change-consumable')),
      );
      await tester.pumpAndSettle();
      for (final inventoryUid in receipt.inventoryUids) {
        expect(find.textContaining('库存卷 $inventoryUid'), findsOneWidget);
      }

      await tester.tap(find.textContaining(receipt.inventoryUids.last));
      await tester.pumpAndSettle();
      expect(find.text('已选库存卷：${receipt.inventoryUids.last}'), findsOneWidget);
      expect(find.textContaining('本卷 1kg'), findsOneWidget);
      final selectedConfirm = find.widgetWithText(FilledButton, '确认同款新卷并绑定');
      expect(tester.widget<FilledButton>(selectedConfirm).onPressed, isNotNull);
      await tester.tap(selectedConfirm);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(queue.state, isEmpty);
      expect(
        await db.printerDao.getConsumableIdByChannel(printer, 0),
        receipt.consumableIds.last,
      );
      expect((await db.select(db.consumables).get()), hasLength(2));
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(
          receipt.consumableIds.first,
        ))!.tagUid,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'first confirmation requires choosing a registered tag and retains its actual material',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(560, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await _spool(db, owner: null);
      final printer = await _printer(db);
      final queue = SpoolChangeQueueNotifier();
      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printer,
        printerSerial: 'AMS-ALIAS',
        printerLabel: '工作台',
        status: BambuPrinterStatus(serial: 'AMS-ALIAS', amsTrays: [_tray()]),
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
      final confirm = find.widgetWithText(FilledButton, '确认同一标签并绑定');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(find.textContaining(_reported), findsOneWidget);
      expect(find.text('还是原来的卷'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('choose-spool-change-consumable')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('手机 UID $_tag'), findsOneWidget);
      expect(find.textContaining('375.0g'), findsOneWidget);
      await tester.tap(find.textContaining('eSUN · PLA+'));
      await tester.pumpAndSettle();
      expect(find.textContaining('手机登记 UID：$_tag'), findsOneWidget);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(queue.state, isEmpty);
      expect(await _aliasCount(db), 1);
      expect(await db.printerDao.getConsumableIdByChannel(printer, 0), id);
      final roll = (await db.consumableDao.getById(id))!;
      expect(roll.materialType, 'PLA');
      expect(roll.remainingGrams, 375);
      expect(roll.trayUuid, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
