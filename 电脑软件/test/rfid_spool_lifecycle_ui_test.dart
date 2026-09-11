import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/personal_inventory_balance_sync.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_event.dart';
import 'package:consumable_tracker_desktop/features/inventory/rfid_spool_replacement_dialog.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/widgets/rfid_spool_history.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'balance conflict requires valid actual grams and records the correction',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      const owner = 'balance@example.com|personal';
      late Consumable spool;
      late List<RfidSpoolBinding> history;
      await tester.runAsync(() async {
        final saved = await MobileInventoryRepository(db.consumableDao)
            .addFromDraft(
              MobileConsumableDraft(
                brand: 'eSUN',
                model: 'PLA',
                color: Colors.blue,
                colorName: '蓝色',
              ),
              tagUid: '04A1B2C3',
              tagType: 'CUID',
              ownerAccount: owner,
              initialGrams: 750,
            );
        spool = (await db.consumableDao.getPersonalByUid(
          saved.inventoryUid,
          ownerAccount: owner,
        ))!;
        await db.consumableDao.retainInventoryBalanceConflict(
          owner,
          'https://example.com',
          PersonalInventoryRecord(
            uid: spool.uid,
            manufacturer: 'eSUN',
            model: 'PLA',
            materialType: 'PLA',
            colorHex: '#0000FF',
            totalGrams: 1000,
            remainingGrams: 700,
            createdAt: spool.createdAt,
            updatedAt: spool.updatedAt,
            rfidTagUid: '04A1B2C3',
          ),
        );
        history = await db.consumableDao.getPersonalRfidSpoolHistory(
          '04A1B2C3',
          ownerAccount: owner,
        );
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            personalInventoryAccountScopeProvider.overrideWithValue(
              const PersonalInventoryAccountScope(
                enforce: true,
                ownerAccount: owner,
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: RfidSpoolHistoryList(
                history: history,
                currentUid: spool.uid,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对余量'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1001');
      await tester.tap(find.text('确认实际余量'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请输入 0 到'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '680.5');
      await tester.tap(find.text('确认实际余量'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        expect(
          (await db.consumableDao.getById(spool.id))!.remainingGrams,
          680.5,
        );
        expect(
          await db.consumableDao.readInventoryBalanceConflicts(
            spool.uid,
            ownerAccount: owner,
          ),
          isEmpty,
        );
        expect(
          (await db.consumableDao.getPersonalInventoryEvents(
            owner,
          )).single.eventType,
          'balance_reconciled',
        );
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('spool history reads synced events only for the roll owner', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    late Consumable spool;
    late List<RfidSpoolBinding> history;
    await tester.runAsync(() async {
      final saved = await MobileInventoryRepository(db.consumableDao)
          .addFromDraft(
            MobileConsumableDraft(
              brand: 'eSUN',
              model: 'PLA',
              color: Colors.blue,
              colorName: '蓝',
            ),
            tagUid: '04D1E2F3',
            tagType: 'CUID',
          );
      spool = (await db.consumableDao.getPersonalByUid(saved.inventoryUid))!;
      await db.consumableDao.setOwnerAccount(spool.id, 'alice|cn');
      for (final owner in ['alice', 'bob']) {
        await db.consumableDao.upsertPersonalInventoryEvents([
          PersonalInventoryEvent(
            eventUid: '$owner-event',
            inventoryUid: spool.uid,
            eventType: 'usage_finished',
            source: 'usage',
            deltaGrams: -25,
            note: '$owner.record',
            occurredAt: DateTime(2026, 9, 6),
          ),
        ], ownerAccount: '$owner|cn');
      }
      history = await db.consumableDao.getPersonalRfidSpoolHistory(
        '04D1E2F3',
        ownerAccount: 'alice|cn',
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          personalInventoryAccountScopeProvider.overrideWithValue(
            const PersonalInventoryAccountScope(
              enforce: true,
              ownerAccount: 'alice|cn',
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: RfidSpoolHistoryList(history: history, currentUid: spool.uid),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('alice.record'), findsOneWidget);
    expect(find.textContaining('已登记消耗 25.0 g'), findsOneWidget);
    expect(find.textContaining('bob.record'), findsNothing);
    expect(find.text('读取记录失败'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'desktop replacement accepts one remnant and preserves a browsable old roll',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      late Consumable old;
      await tester.runAsync(() async {
        final saved = await MobileInventoryRepository(db.consumableDao)
            .addFromDraft(
              MobileConsumableDraft(
                brand: 'eSUN',
                model: 'PLA',
                color: Colors.blue,
                colorName: '蓝',
              ),
              tagUid: '04A1B2C3',
              tagType: 'CUID',
            );
        old = (await db.consumableDao.getPersonalByUid(saved.inventoryUid))!;
        await db.consumableDao.adjustGrams(old.id, 800);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () => showRfidSpoolReplacementDialog(
                    context,
                    db.consumableDao,
                    old,
                  ),
                  child: const Text('换卷'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('换卷'));
      await tester.pumpAndSettle();
      expect(find.text('数量：1 卷 · 1000 g（1 kg）'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.text('按余量入库'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '0');
      await tester.tap(find.text('确认换卷'));
      await tester.pump();
      expect(find.text('请输入大于 30 且不超过 1000 g 的剩余克数'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '1001');
      await tester.tap(find.text('确认换卷'));
      await tester.pump();
      expect(find.text('请输入大于 30 且不超过 1000 g 的剩余克数'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '750');
      await tester.tap(find.text('确认换卷'));
      await tester.pumpAndSettle();
      late List<RfidSpoolBinding> history;
      await tester.runAsync(() async {
        history = await db.consumableDao.getPersonalRfidSpoolHistory(
          '04A1B2C3',
        );
        expect(history, hasLength(2));
        expect(
          (await db.consumableDao.getById(
            history.first.consumableId,
          ))!.remainingGrams,
          750,
        );
        expect((await db.consumableDao.getById(old.id))!.remainingGrams, 200);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: Scaffold(
              body: RfidSpoolHistoryList(history: history, currentUid: old.uid),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 1 卷 · 已换卷'), findsOneWidget);
      expect(find.text('第 2 卷 · 当前卷'), findsOneWidget);
      expect(find.text('库存卷号：${old.uid}'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
