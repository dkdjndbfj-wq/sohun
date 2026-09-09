import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/personal_inventory_action_guard.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const alice = PersonalInventoryAccountScope(
    enforce: true,
    ownerAccount: 'alice',
  );
  const bob = PersonalInventoryAccountScope(enforce: true, ownerAccount: 'bob');
  late AppDatabase db;
  late int id;
  late PersonalInventoryAccountScope scope;
  late PersonalInventoryActionGuard guard;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    id = await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(manufacturer: 'Test', model: 'PLA'),
    );
    await db.consumableDao.setOwnerAccount(id, alice.ownerAccount);
    scope = alice;
    guard = PersonalInventoryActionGuard(
      dao: db.consumableDao,
      readScope: () => scope,
    );
  });
  tearDown(() => db.close());

  test(
    'a dialog opened before an account switch cannot deduct stock',
    () async {
      scope = bob;
      await expectLater(
        guard.run(id, () => db.consumableDao.deductOneRoll(id)),
        throwsStateError,
      );
      expect((await db.consumableDao.getById(id))!.remainingGrams, 1000);
    },
  );

  test('ownership changing after a dialog opens rejects its action', () async {
    await db.consumableDao.setOwnerAccount(id, bob.ownerAccount);
    await expectLater(
      guard.run(id, () => db.consumableDao.deleteConsumable(id)),
      throwsStateError,
    );
    expect(await db.consumableDao.getById(id), isNotNull);
  });

  test(
    'an account switch during a write rolls back balance and history',
    () async {
      await expectLater(
        guard.run(id, () async {
          await db.consumableDao.deductOneRoll(id);
          scope = bob;
        }),
        throwsStateError,
      );
      expect((await db.consumableDao.getById(id))!.remainingGrams, 1000);
      expect(await db.select(db.usageLogs).get(), isEmpty);
    },
  );
}
