import 'package:consumable_tracker_desktop/core/services/personal_inventory_sync_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/features/printers/channel_slot.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_task_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:consumable_tracker_desktop/providers/usage_provider.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('owner key binds normalized server and stable user id, not email', () {
    final first = _session(
      id: 'User-A',
      email: 'shared@example.com',
      server: 'HTTPS://Inventory.Example.com:443/',
    );
    final equivalent = _session(
      id: 'User-A',
      email: 'renamed@example.com',
      server: 'https://inventory.example.com',
    );
    final recreated = _session(
      id: 'User-B',
      email: 'shared@example.com',
      server: 'https://inventory.example.com',
    );
    final selfHosted = _session(
      id: 'User-A',
      email: 'shared@example.com',
      server: 'https://self-hosted.example.com',
    );

    final key = PersonalInventorySyncService.ownerAccountFor(first);
    expect(key, PersonalInventorySyncService.ownerAccountFor(equivalent));
    expect(key, isNot(PersonalInventorySyncService.ownerAccountFor(recreated)));
    expect(
      key,
      isNot(PersonalInventorySyncService.ownerAccountFor(selfHosted)),
    );
    expect(key, startsWith('personal:v2:'));
    expect(key, isNot(contains('shared@example.com')));
  });

  test(
    'legacy email owner migrates only UIDs proven by this authenticated account',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final dao = db.consumableDao;
      final session = _session(
        id: 'stable-user-id',
        email: 'legacy@example.com',
        server: 'https://inventory.example.com',
      );
      final legacy = PersonalInventorySyncService.legacyOwnerAccountFor(
        session,
      );
      final next = PersonalInventorySyncService.ownerAccountFor(session);
      final verified = _record('verified-remote-uid');
      final ambiguous = _record('local-only-uid');
      await dao.upsertPersonalInventoryRecord(verified, ownerAccount: legacy);
      await dao.upsertPersonalInventoryRecord(ambiguous, ownerAccount: legacy);

      final api = _InventoryApi(
        PersonalInventorySnapshot(revision: 4, records: [verified]),
      );
      await PersonalInventorySyncService(
        dao: dao,
        api: api,
      ).synchronize(session: session);

      expect(
        await dao.getPersonalByUid(verified.uid, ownerAccount: next),
        isNotNull,
      );
      expect(
        await dao.getPersonalByUid(ambiguous.uid, ownerAccount: next),
        isNull,
      );
      expect(
        await dao.getOwnerAccount(
          (await dao.getByOwnerAccount(legacy)).single.consumable.id,
        ),
        legacy,
      );
      expect(
        api.lastPut?.records.map((row) => row.uid),
        isNot(contains(ambiguous.uid)),
      );
    },
  );

  test(
    'deleted-account re-registration cannot claim legacy rows by email alone',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final dao = db.consumableDao;
      final newAccount = _session(
        id: 'new-user-id',
        email: 'reused@example.com',
        server: 'https://inventory.example.com',
      );
      final legacy = PersonalInventorySyncService.legacyOwnerAccountFor(
        newAccount,
      );
      final old = _record('old-account-local-data');
      final id = await dao.upsertPersonalInventoryRecord(
        old,
        ownerAccount: legacy,
      );
      final api = _InventoryApi(
        const PersonalInventorySnapshot(revision: 0, records: []),
      );

      await PersonalInventorySyncService(
        dao: dao,
        api: api,
      ).synchronize(session: newAccount);

      expect(await dao.getOwnerAccount(id), legacy);
      expect(
        api.lastPut?.records ?? const <PersonalInventoryRecord>[],
        isEmpty,
      );
      expect(
        await dao.getPersonalForOwnerAccount(
          PersonalInventorySyncService.ownerAccountFor(newAccount),
        ),
        isEmpty,
      );
    },
  );

  test(
    'claiming anonymous CUID stock moves its whole lifecycle and receipt ledger',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      const tagUid = 'D021B75E';
      const reportedUid = 'D021B75E00000100';
      const operationUid = '30c3a19f-44c5-46c7-b916-78d73a705001';
      final receipt = await db.consumableDao.addPersonalStockFromRfidCard(
        operationUid: operationUid,
        tagUid: tagUid,
        tagType: 'CUID',
        template: _record('anonymous-material-template'),
        quantity: 2,
        ownerAccount: '',
      );
      final unrelatedId = await db.consumableDao.upsertPersonalInventoryRecord(
        _record('unrelated-anonymous-roll'),
        ownerAccount: null,
      );
      final printerId = await db.printerDao.addPrinter(
        brand: '拓竹',
        model: 'P1S',
        channelCount: 1,
      );
      for (final id in receipt.consumableIds) {
        await db.printerDao.bindSpoolReplacement(
          printerId: printerId,
          channelIndex: 0,
          consumableId: id,
          uniquePhysicalSpool: true,
          confirmedAmsUid: reportedUid,
          sourceTagUid: tagUid,
          sourceTagType: 'CUID',
          sourceOwnerAccount: '',
        );
      }
      await db.consumableDao.rebindPersonalRfidSpool(
        consumableId: receipt.consumableIds.first,
        expectedTagUid: tagUid,
        newTagUid: '11223344',
        newTagType: 'FUID',
        ownerAccount: null,
      );
      final owner = PersonalInventorySyncService.ownerAccountFor(
        _session(id: 'chain-owner', email: 'owner@example.com'),
      );

      expect(
        await db.consumableDao.ensurePersonalConsumableAccess(
          receipt.consumableIds.last,
          ownerAccount: owner,
          claimAnonymous: true,
        ),
        isTrue,
      );
      for (final id in receipt.consumableIds) {
        expect(await db.consumableDao.getOwnerAccount(id), owner);
      }
      expect(await db.consumableDao.getOwnerAccount(unrelatedId), isNull);
      final receiptOwner = await db
          .customSelect(
            'SELECT owner_account FROM personal_stock_receipts '
            'WHERE operation_uid = ?',
            variables: [const Variable(operationUid)],
          )
          .getSingle();
      expect(receiptOwner.read<String>('owner_account'), owner);
      final aliasOwners = await db
          .customSelect(
            'SELECT DISTINCT owner_account FROM personal_ams_uid_aliases '
            'WHERE tag_uid = ?',
            variables: [const Variable(tagUid)],
          )
          .get();
      expect(aliasOwners.map((row) => row.read<String>('owner_account')), [
        owner,
      ]);
      for (final table in ['personal_inventory_events', 'rfid_tag_records']) {
        final owners = await db
            .customSelect(
              'SELECT DISTINCT coalesce(owner_account, \'\') AS owner '
              'FROM $table WHERE lower(trim(inventory_uid)) IN (?, ?)',
              variables: [
                Variable(receipt.inventoryUids.first.toLowerCase()),
                Variable(receipt.inventoryUids.last.toLowerCase()),
              ],
            )
            .get();
        expect(owners.map((row) => row.read<String>('owner')), [owner]);
      }
    },
  );

  test(
    'anonymous receipt claim rejects a component already owned by B',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      const operationUid = '30c3a19f-44c5-46c7-b916-78d73a705002';
      final receipt = await db.consumableDao.addPersonalStockFromRfidCard(
        operationUid: operationUid,
        tagUid: 'A1B2C3D4',
        tagType: 'FUID',
        template: _record('mixed-owner-template'),
        quantity: 2,
        ownerAccount: '',
      );
      final aliceOwner = PersonalInventorySyncService.ownerAccountFor(
        _session(id: 'claim-alice', email: 'same@example.com'),
      );
      final bobOwner = PersonalInventorySyncService.ownerAccountFor(
        _session(id: 'claim-bob', email: 'same@example.com'),
      );
      await db.customUpdate(
        'UPDATE consumables SET owner_account = ? WHERE id = ?',
        variables: [Variable(bobOwner), Variable(receipt.consumableIds.last)],
        updates: {db.consumables},
      );

      expect(
        await db.consumableDao.ensurePersonalConsumableAccess(
          receipt.consumableIds.first,
          ownerAccount: aliceOwner,
          claimAnonymous: true,
        ),
        isFalse,
      );
      expect(
        (await db.consumableDao.getOwnerAccount(receipt.consumableIds.first) ??
                '')
            .trim(),
        isEmpty,
      );
      expect(
        await db.consumableDao.getOwnerAccount(receipt.consumableIds.last),
        bobOwner,
      );
      final receiptOwner = await db
          .customSelect(
            'SELECT owner_account FROM personal_stock_receipts '
            'WHERE operation_uid = ?',
            variables: [const Variable(operationUid)],
          )
          .getSingle();
      expect(receiptOwner.read<String>('owner_account'), isEmpty);
    },
  );

  test(
    'desktop inventory and usage providers switch account scope together',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final alice = _session(id: 'alice', email: 'shared@example.com');
      final bob = _session(id: 'bob', email: 'shared@example.com');
      final aliceOwner = PersonalInventorySyncService.ownerAccountFor(alice);
      final bobOwner = PersonalInventorySyncService.ownerAccountFor(bob);
      final aliceId = await db.consumableDao.upsertPersonalInventoryRecord(
        _record('alice-roll'),
        ownerAccount: aliceOwner,
      );
      final bobId = await db.consumableDao.upsertPersonalInventoryRecord(
        _record('bob-roll'),
        ownerAccount: bobOwner,
      );
      final localId = await db.consumableDao.upsertPersonalInventoryRecord(
        _record('local-roll'),
        ownerAccount: null,
      );
      for (final entry in [(aliceId, 11.0), (bobId, 22.0), (localId, 3.0)]) {
        await db.usageLogDao.addLog(
          UsageLogsCompanion.insert(
            consumableId: Value(entry.$1),
            consumedGrams: Value(entry.$2),
          ),
        );
      }

      final auth = _Auth(alice);
      await auth.ready;
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appAuthProvider.overrideWith((ref) => auth),
        ],
      );
      addTearDown(container.dispose);

      expect(
        (await container.read(
          consumablesProvider.future,
        )).map((row) => row.uid),
        containsAll(<String>['alice-roll', 'local-roll']),
      );
      expect(
        (await container.read(
          consumablesProvider.future,
        )).map((row) => row.uid),
        isNot(contains('bob-roll')),
      );
      expect(
        (await container.read(
          usageLogsProvider.future,
        )).map((row) => row.consumedGrams),
        containsAll(<double>[11, 3]),
      );

      auth.use(bob);
      expect(
        (await container.read(
          consumablesProvider.future,
        )).map((row) => row.uid),
        containsAll(<String>['bob-roll', 'local-roll']),
      );
      expect(
        (await container.read(
          consumablesProvider.future,
        )).map((row) => row.uid),
        isNot(contains('alice-roll')),
      );
      expect(
        (await container.read(
          usageLogsProvider.future,
        )).map((row) => row.consumedGrams),
        containsAll(<double>[22, 3]),
      );
      expect(
        (await container.read(
          usageLogsProvider.future,
        )).map((row) => row.consumedGrams),
        isNot(contains(11)),
      );

      auth.use(null);
      expect(
        (await container.read(
          consumablesProvider.future,
        )).map((row) => row.uid),
        ['local-roll'],
      );
      expect(
        (await container.read(
          usageLogsProvider.future,
        )).map((row) => row.consumedGrams),
        [3],
      );
    },
  );

  testWidgets('desktop spool picker cannot list another account inventory', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final alice = _session(id: 'picker-alice', email: 'same@example.com');
    final bob = _session(id: 'picker-bob', email: 'same@example.com');
    await db.consumableDao.upsertPersonalInventoryRecord(
      _record('alice-picker-roll'),
      ownerAccount: PersonalInventorySyncService.ownerAccountFor(alice),
    );
    await db.consumableDao.upsertPersonalInventoryRecord(
      _record('bob-picker-roll'),
      ownerAccount: PersonalInventorySyncService.ownerAccountFor(bob),
    );
    final auth = _Auth(alice);
    await auth.ready;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appAuthProvider.overrideWith((ref) => auth),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showConsumablePickerForChannel(context, 999),
                child: const Text('打开选择器'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();

    expect(find.textContaining('alice-picker-roll'), findsWidgets);
    expect(find.textContaining('bob-picker-roll'), findsNothing);
    expect(find.text('1 种耗材可供选择'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'bound channel is hidden and immutable for B then restored for A',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final alice = _session(id: 'bound-alice', email: 'same@example.com');
      final bob = _session(id: 'bound-bob', email: 'same@example.com');
      final aliceOwner = PersonalInventorySyncService.ownerAccountFor(alice);
      final bobOwner = PersonalInventorySyncService.ownerAccountFor(bob);
      final aliceId = await db.consumableDao.upsertPersonalInventoryRecord(
        _record('alice-private-channel-roll'),
        ownerAccount: aliceOwner,
      );
      final bobId = await db.consumableDao.upsertPersonalInventoryRecord(
        _record('bob-replacement-roll'),
        ownerAccount: bobOwner,
      );
      final printerId = await db.printerDao.addPrinter(
        brand: '拓竹',
        model: 'P1S',
        channelCount: 1,
      );
      var printer = (await db.printerDao.getByIdWithChannels(printerId))!;
      final channelId = printer.channels.single.channel.id;
      await db.printerDao.bindConsumable(channelId, aliceId);
      printer = (await db.printerDao.getByIdWithChannels(printerId))!;

      final auth = _Auth(alice);
      await auth.ready;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appAuthProvider.overrideWith((ref) => auth),
            activePrinterConfigProvider.overrideWithValue(null),
            activePrinterConnectionProvider.overrideWith(
              (ref) => _QuietConnection(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ChannelSlot(
                data: printer.channels.single,
                printerId: printerId,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('alice-private-channel-roll'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('personal-channel-account-protected')),
        findsNothing,
      );

      auth.use(bob);
      await tester.pump();
      expect(find.text('alice-private-channel-roll'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('alice-private-channel-roll'), findsNothing);
      expect(find.text('其他 Sohun 账号的耗材'), findsOneWidget);
      expect(find.text('更换'), findsNothing);
      expect(find.text('取下'), findsNothing);

      await expectLater(
        db.printerDao.changeRoll(
          channelId: channelId,
          newConsumableId: bobId,
          enforcePersonalOwner: true,
          personalOwnerAccount: bobOwner,
        ),
        throwsStateError,
      );
      await expectLater(
        db.printerDao.unbindChannel(
          channelId,
          enforcePersonalOwner: true,
          personalOwnerAccount: bobOwner,
        ),
        throwsStateError,
      );
      await expectLater(
        db.printerDao.finishChannel(
          channelId,
          enforcePersonalOwner: true,
          personalOwnerAccount: bobOwner,
        ),
        throwsStateError,
      );
      expect(
        await db.printerDao.getConsumableIdByChannel(printerId, 0),
        aliceId,
      );
      expect((await db.consumableDao.getById(aliceId))!.remainingGrams, 900);

      auth.use(alice);
      await tester.pumpAndSettle();
      expect(find.text('alice-private-channel-roll'), findsOneWidget);
      expect(find.text('其他 Sohun 账号的耗材'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  test('print mapping rejects another Sohun account consumable', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final alice = _session(id: 'print-alice', email: 'same@example.com');
    final bob = _session(id: 'print-bob', email: 'same@example.com');
    final aliceId = await db.consumableDao.upsertPersonalInventoryRecord(
      _record('alice-print-roll'),
      ownerAccount: PersonalInventorySyncService.ownerAccountFor(alice),
    );
    final taskId = await db.customInsert('''
      INSERT INTO print_tasks (
        uid, gcode_path, task_name, status, created_at, updated_at
      ) VALUES ('account-print-map', 'account.gcode', 'account', 'printing', 1, 1)
    ''');
    await db.customInsert(
      'INSERT INTO print_task_consumables('
      'task_id, channel_index, tool_index, estimated_grams, created_at, updated_at) '
      'VALUES (?, 0, 0, 10, 1, 1)',
      variables: [Variable<int>(taskId)],
    );
    final auth = _Auth(bob);
    await auth.ready;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appAuthProvider.overrideWith((ref) => auth),
        mergedPrinterListProvider.overrideWithValue(const []),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(printTaskOrchestratorProvider.notifier)
          .applyExternalMulticolorPlan(
            taskId: taskId,
            toolConsumableIds: {0: aliceId},
          ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('其他 Sohun 账号'),
        ),
      ),
    );
    final links = await container
        .read(printTaskConsumableDaoProvider)
        .getByTask(taskId);
    expect(links.single.consumableId, isNull);
    expect((await db.consumableDao.getById(aliceId))!.remainingGrams, 900);
  });
}

PersonalInventoryRecord _record(String uid) {
  final now = DateTime.utc(2026, 9, 9);
  return PersonalInventoryRecord(
    uid: uid,
    manufacturer: 'eSUN',
    model: uid,
    materialType: 'PLA',
    colorHex: '#FFFFFF',
    colorName: uid,
    totalGrams: 1000,
    remainingGrams: 900,
    createdAt: now,
    updatedAt: now,
  );
}

AppAuthSession _session({
  required String id,
  required String email,
  String server = 'https://inventory.example.com',
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
    serverBaseUrl: server,
  );
}

class _InventoryApi implements PersonalInventoryApi {
  _InventoryApi(this.snapshot);

  PersonalInventorySnapshot snapshot;
  PersonalInventorySnapshot? lastPut;

  @override
  Future<PersonalInventorySnapshot> fetchPersonalInventory({
    required String accessToken,
  }) async => snapshot;

  @override
  Future<PersonalInventorySnapshot> replacePersonalInventory({
    required String accessToken,
    required PersonalInventorySnapshot snapshot,
  }) async {
    lastPut = snapshot;
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

class _Auth extends AppAuthNotifier {
  _Auth(AppAuthSession session)
    : super(
        serverSettings: CommunityServerSettings(
          store: _ServerStore(),
          compileTimeBaseUrl: session.serverBaseUrl,
        ),
        sessionStore: _SessionStore(session),
        apiFactory: (_) => _CommunityApi(),
      );

  void use(AppAuthSession? session) {
    state = AppAuthState(
      status: session == null
          ? AppAuthStatus.signedOut
          : AppAuthStatus.signedIn,
      endpoint: Uri.parse(
        session?.serverBaseUrl ?? 'https://inventory.example.com',
      ),
      user: session?.user,
      session: session,
    );
  }
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

class _QuietConnection extends StateNotifier<ActivePrinterState>
    implements ActivePrinterConnectionNotifier {
  _QuietConnection() : super(const ActivePrinterState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
