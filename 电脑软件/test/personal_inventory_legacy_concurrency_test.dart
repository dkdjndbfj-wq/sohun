import 'package:consumable_tracker_desktop/core/services/personal_inventory_sync_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/personal_inventory_balance_sync.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late ConsumableDao dao;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dao = database.consumableDao;
  });

  tearDown(() => database.close());

  test('legacy aggregate stock combines concurrent offline deltas', () async {
    final session = _session();
    final owner = PersonalInventorySyncService.ownerAccountFor(session);
    final initial = _record('legacy-shared', remainingGrams: 1000);
    final id = await dao.upsertPersonalInventoryRecord(
      initial,
      ownerAccount: owner,
    );
    final api = _InventoryApi(
      PersonalInventorySnapshot(revision: 1, records: [initial]),
    );
    final service = PersonalInventorySyncService(dao: dao, api: api);

    // Establish the common 1000 g ancestor, then let two offline clients
    // independently consume 200 g and 300 g from it.
    await service.synchronize(session: session);
    await dao.adjustGrams(id, 200);
    api.snapshot = PersonalInventorySnapshot(
      revision: 2,
      records: [
        initial.copyWith(
          remainingGrams: 700,
          updatedAt: DateTime.utc(2026, 9, 10),
        ),
      ],
    );

    await service.synchronize(session: session);

    expect(api.snapshot.records.single.remainingGrams, 500);
    expect((await dao.getById(id))!.remainingGrams, 500);
    expect(
      await dao.readInventoryBalanceConflicts(initial.uid, ownerAccount: owner),
      isEmpty,
    );
  });

  test(
    'legacy balance without a common ancestor is retained for review',
    () async {
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final local = _record('legacy-unknown', remainingGrams: 800);
      final id = await dao.upsertPersonalInventoryRecord(
        local,
        ownerAccount: owner,
      );
      final remote = local.copyWith(
        remainingGrams: 700,
        updatedAt: DateTime.utc(2026, 9, 10),
      );
      final api = _InventoryApi(
        PersonalInventorySnapshot(revision: 1, records: [remote]),
      );
      final service = PersonalInventorySyncService(dao: dao, api: api);

      await expectLater(
        service.synchronize(session: session),
        throwsA(
          isA<CommunityApiException>().having(
            (error) => error.code,
            'code',
            'inventory_balance_conflict',
          ),
        ),
      );
      expect((await dao.getById(id))!.remainingGrams, 800);
      expect(api.snapshot.records.single.remainingGrams, 700);

      final conflict = (await dao.readInventoryBalanceConflicts(
        local.uid,
        ownerAccount: owner,
      )).single;
      await dao.reconcilePersonalInventoryBalance(id, conflict, 650);
      await service.synchronize(session: session);

      expect(api.snapshot.records.single.remainingGrams, 650);
      expect((await dao.getById(id))!.remainingGrams, 650);
    },
  );
}

PersonalInventoryRecord _record(String uid, {required double remainingGrams}) {
  final now = DateTime.utc(2026, 9, 9);
  return PersonalInventoryRecord(
    uid: uid,
    manufacturer: 'Legacy',
    model: 'Aggregate PLA',
    materialType: 'PLA',
    colorHex: '#FFFFFF',
    totalGrams: 1000,
    remainingGrams: remainingGrams,
    createdAt: now,
    updatedAt: now,
  );
}

AppAuthSession _session() {
  final now = DateTime.utc(2026, 9, 9);
  return AppAuthSession(
    user: AppUser(
      id: 'legacy-user',
      email: 'legacy@example.com',
      handle: 'legacy_user',
      displayName: 'Legacy User',
      emailVerified: true,
      createdAt: now,
      updatedAt: now,
    ),
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    expiresAt: now.add(const Duration(hours: 1)),
    serverBaseUrl: 'https://inventory.example.com',
  );
}

class _InventoryApi implements PersonalInventoryApi {
  _InventoryApi(this.snapshot);

  PersonalInventorySnapshot snapshot;

  @override
  Future<PersonalInventorySnapshot> fetchPersonalInventory({
    required String accessToken,
  }) async => snapshot;

  @override
  Future<PersonalInventorySnapshot> replacePersonalInventory({
    required String accessToken,
    required PersonalInventorySnapshot snapshot,
  }) async {
    this.snapshot = PersonalInventorySnapshot(
      revision: snapshot.revision + 1,
      records: snapshot.records,
      materialCatalog: snapshot.materialCatalog,
      deletedUids: snapshot.deletedUids,
      events: snapshot.events,
    );
    return this.snapshot;
  }
}
