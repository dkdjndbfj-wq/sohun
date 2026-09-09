import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/personal_inventory_balance_sync.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_sync.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'mobile unbound received spool opens its receipt and resolves a balance conflict',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const owner = 'receipt-ui@example.com|personal';
      const operation = '8bccb30f-5da8-48d0-988f-ab01e23b0b01';
      late Consumable item;
      await tester.runAsync(() async {
        final template = PersonalInventoryRecord(
          uid: 'template',
          manufacturer: 'eSUN',
          model: 'PLA',
          materialType: 'PLA',
          colorHex: '#2244CC',
          totalGrams: 2000,
          remainingGrams: 2000,
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
            remainingGrams: 1800,
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
            personalInventoryAccountScopeProvider.overrideWithValue(
              const PersonalInventoryAccountScope(
                enforce: true,
                ownerAccount: owner,
              ),
            ),
            personalConsumablesByOwnerProvider(
              owner,
            ).overrideWith((ref) => Stream.value([item])),
          ],
          child: MaterialApp(
            home: MobileInventoryPage(
              sync: LocalMobileInventorySync(db.consumableDao),
              ownerAccount: owner,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('PLA').first);
      await tester.pumpAndSettle();
      expect(find.text('复用周期'), findsNothing);
      await tester.ensureVisible(find.text('查看本卷入库与消耗记录'));
      await tester.tap(find.text('查看本卷入库与消耗记录'));
      await tester.pumpAndSettle();
      expect(find.text('独立库存卷 · 可用'), findsOneWidget);
      expect(find.textContaining('来源资料卡：D021B75E · CUID'), findsOneWidget);
      expect(find.textContaining('入库批次：$operation'), findsOneWidget);
      expect(find.textContaining('资料卡确认入库'), findsOneWidget);
      expect(find.textContaining('尚未绑定物理标签'), findsOneWidget);
      expect(find.text('复用标签，换入新卷'), findsNothing);
      await tester.ensureVisible(find.text('核对余量'));
      await tester.tap(find.text('核对余量'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '1777.5');
      await tester.tap(find.text('确认实际余量'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        expect(
          (await db.consumableDao.getById(item.id))!.remainingGrams,
          1777.5,
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
}
