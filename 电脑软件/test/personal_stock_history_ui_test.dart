import 'package:consumable_tracker_desktop/core/services/personal_inventory_sync_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/personal_inventory_balance_sync.dart';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/features/inventory/inventory_screen.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/filament_cost_provider.dart';
import 'package:consumable_tracker_desktop/providers/stock_alert_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'desktop unbound received spool opens its receipt and resolves a balance conflict',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final auth = _Auth(session);
      await tester.runAsync(() => auth.ready);
      const operation = '8bccb30f-5da8-48d0-988f-ab01e23b0b01';
      late Consumable item;
      await tester.runAsync(() async {
        final template = PersonalInventoryRecord(
          uid: 'template',
          manufacturer: 'eSUN',
          model: 'PLA',
          materialType: 'PLA',
          colorHex: '#2244CC',
          totalGrams: 1000,
          remainingGrams: 1000,
          createdAt: DateTime.utc(2026, 9, 9),
          updatedAt: DateTime.utc(2026, 9, 9),
        );
        final receipt = await db.consumableDao.addPersonalStockFromRfidCard(
          operationUid: operation,
          tagUid: 'D021B75E',
          tagType: 'CUID',
          template: template,
          quantity: 1,
          ownerAccount: owner,
        );
        item = (await db.consumableDao.getById(receipt.consumableIds.single))!;
        await db.consumableDao.retainInventoryBalanceConflict(
          owner,
          'https://inventory.example.com',
          template.copyWith(
            uid: item.uid,
            remainingGrams: 800,
            sourceRfidTagUid: 'D021B75E',
            sourceRfidTagType: 'CUID',
            stockReceiptUid: operation,
            stockReceiptIndex: 0,
            stockReceiptQuantity: 1,
          ),
        );
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appAuthProvider.overrideWith((ref) => auth),
            filamentCostConfigsProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
            hasCriticalStockAlertProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(home: InventoryScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('生命周期'));
      await tester.pumpAndSettle();
      expect(find.text('eSUN PLA · 本卷记录'), findsOneWidget);
      expect(find.text('独立库存卷 · 可用'), findsOneWidget);
      expect(find.textContaining('来源资料卡：D021B75E · CUID'), findsOneWidget);
      expect(find.textContaining('入库批次：$operation'), findsOneWidget);
      expect(find.textContaining('资料卡确认入库'), findsOneWidget);
      expect(find.textContaining('尚未绑定物理标签'), findsOneWidget);
      expect(find.text('复用标签，换入新卷'), findsNothing);
      await tester.ensureVisible(find.text('核对余量'));
      await tester.tap(find.text('核对余量'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '777.5');
      await tester.tap(find.text('确认实际余量'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        expect(
          (await db.consumableDao.getById(item.id))!.remainingGrams,
          777.5,
        );
        expect(
          await db.consumableDao.readInventoryBalanceConflicts(
            item.uid,
            ownerAccount: owner,
          ),
          isEmpty,
        );
        final binding = await db.consumableDao.getRfidSpoolBindingById(item.id);
        expect(binding!.tagUid, isEmpty);
        final source = (await db.consumableDao.getPersonalRfidStockSourcesMap([
          item.id,
        ]))[item.id]!;
        expect(source.receiptUid, operation);
        final events = await db.consumableDao.getPersonalInventoryEvents(owner);
        expect(
          events.map((event) => event.eventType),
          contains('balance_reconciled'),
        );
        expect(events.map((event) => event.rfidTagUid), everyElement(isNull));
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  for (final switchAccount in [false, true]) {
    testWidgets(
      'legacy aggregate balance dialog handles account switch: $switchAccount',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final session = _session();
        final owner = PersonalInventorySyncService.ownerAccountFor(session);
        final auth = _Auth(session);
        await tester.runAsync(() => auth.ready);
        late int id;
        final record = PersonalInventoryRecord(
          uid: 'legacy-aggregate',
          manufacturer: 'Legacy',
          model: 'PLA',
          materialType: 'PLA',
          colorHex: '#2244CC',
          totalGrams: 3000,
          remainingGrams: 1800,
          createdAt: DateTime.utc(2026, 9, 9),
          updatedAt: DateTime.utc(2026, 9, 9),
        );
        await tester.runAsync(() async {
          id = await db.consumableDao.upsertPersonalInventoryRecord(
            record,
            ownerAccount: owner,
          );
          await db.consumableDao.retainInventoryBalanceConflict(
            owner,
            session.serverBaseUrl,
            record.copyWith(remainingGrams: 1600),
          );
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              appAuthProvider.overrideWith((ref) => auth),
              filamentCostConfigsProvider.overrideWith(
                (ref) => Stream.value(const []),
              ),
              hasCriticalStockAlertProvider.overrideWithValue(false),
            ],
            child: const MaterialApp(home: InventoryScreen()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('生命周期'));
        await tester.pumpAndSettle();
        expect(find.text('确认实际余量'), findsOneWidget);
        await tester.enterText(find.byType(TextField).last, '1500');
        if (switchAccount) {
          auth.switchTo(_session(id: 'another-account'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('确认实际余量'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          expect(
            (await db.consumableDao.getById(id))!.remainingGrams,
            switchAccount ? 1800 : 1500,
          );
          final conflicts = await db.consumableDao
              .readInventoryBalanceConflicts(record.uid, ownerAccount: owner);
          expect(conflicts, switchAccount ? isNotEmpty : isEmpty);
        });
        if (switchAccount) expect(find.textContaining('账号已切换'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}

AppAuthSession _session({String id = 'receipt-ui-user'}) {
  final now = DateTime.now();
  return AppAuthSession(
    user: AppUser(
      id: id,
      email: 'receipt-ui@example.com',
      handle: 'receipt_ui_user',
      displayName: 'Receipt UI User',
      emailVerified: true,
      createdAt: now,
      updatedAt: now,
    ),
    accessToken: 'access',
    refreshToken: 'refresh',
    expiresAt: now.add(const Duration(hours: 1)),
    serverBaseUrl: 'https://inventory.example.com',
  );
}

class _Auth extends AppAuthNotifier {
  void switchTo(AppAuthSession session) {
    state = AppAuthState(
      status: AppAuthStatus.signedIn,
      session: session,
      user: session.user,
      endpoint: Uri.parse(session.serverBaseUrl),
    );
  }

  _Auth(AppAuthSession session)
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
