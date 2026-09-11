import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/features/inventory/consumable_card.dart';
import 'package:consumable_tracker_desktop/features/inventory/inventory_screen.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/filament_cost_provider.dart';
import 'package:consumable_tracker_desktop/providers/stock_alert_provider.dart';
import 'package:consumable_tracker_desktop/widgets/stock_bar.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppDatabase db;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Future<Consumable> add(
    double grams, {
    String? tag,
    double? total,
    String? colorName,
  }) async {
    final id = await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: '验收品牌',
        model: 'PLA',
        remainingGrams: Value(grams),
        totalGrams: Value(total ?? 1000),
        colorHex: const Value('#2244CC'),
        colorName: Value(colorName),
      ),
    );
    if (tag != null) {
      await db.consumableDao.setRfidSpoolBinding(
        id,
        tagUid: tag,
        tagType: 'CUID',
        cycle: 1,
        status: grams > 0 ? 'active' : 'depleted',
      );
    }
    return (await db.consumableDao.getById(id))!;
  }

  Future<Consumable> addReceivedSpool({double grams = 750}) async {
    final receipt = await db.consumableDao.addPersonalStockFromRfidCard(
      operationUid: '8bccb30f-5da8-48d0-988f-ab01e23b0b02',
      tagUid: 'D021B75E',
      tagType: 'CUID',
      quantity: 1,
      template: PersonalInventoryRecord(
        uid: 'ui-template',
        manufacturer: '验收品牌',
        model: 'PLA',
        materialType: 'PLA',
        colorHex: '#2244CC',
        colorName: '资料卡入库卷',
        totalGrams: 1000,
        remainingGrams: grams,
        createdAt: DateTime.utc(2026, 9, 9),
        updatedAt: DateTime.utc(2026, 9, 9),
      ),
    );
    return (await db.consumableDao.getById(receipt.consumableIds.single))!;
  }

  Future<void> render(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          filamentCostConfigsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          hasCriticalStockAlertProvider.overrideWithValue(false),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('six partially used rolls count as six in the brand summary', (
    tester,
  ) async {
    for (var i = 0; i < 6; i++) {
      await add(750, total: 1000);
    }
    await render(tester, const InventoryScreen());
    expect(find.text('6 卷  ·  4.5kg'), findsOneWidget);
    expect(find.textContaining('0 卷  ·'), findsNothing);
    await unmount(tester);
  });

  testWidgets('500 g remnant and full 1 kg tagged roll each count as one', (
    tester,
  ) async {
    await add(500, tag: 'AABBCC01');
    await add(1000, tag: 'AABBCC02');
    await add(0, tag: 'AABBCC03', total: 1000);
    await render(tester, const InventoryScreen());
    expect(find.text('2 卷  ·  1.5kg'), findsOneWidget);
    expect(find.text('1 卷'), findsNothing);
    expect(find.text('500g'), findsWidgets);
    expect(find.text('1kg'), findsWidgets);
    await unmount(tester);
  });

  testWidgets(
    'selection keeps actual remaining weight against the fixed 1 kg capacity',
    (tester) async {
      final item = await add(875, tag: 'AABBCC01', total: 1000);
      await render(
        tester,
        Center(
          child: SizedBox(
            width: 280,
            height: 300,
            child: MaterialShelfCard(
              item: item,
              selectionMode: true,
              selectionDisplayGrams: 750,
            ),
          ),
        ),
      );
      final bar = tester.widget<StockBar>(find.byType(StockBar));
      expect(bar.remaining, 750);
      expect(bar.total, 1000);
      await unmount(tester);
    },
  );

  testWidgets('full tagged concrete spool has no aggregate +/- controls', (
    tester,
  ) async {
    final item = await add(1000, total: 1000, tag: 'AABBCC01');
    await render(
      tester,
      Center(
        child: SizedBox(width: 360, child: ConsumableCard(item: item)),
      ),
    );
    expect(find.byIcon(Icons.add_rounded), findsNothing);
    expect(find.byIcon(Icons.remove_rounded), findsNothing);
    expect(find.text('1 卷'), findsNothing);
    await unmount(tester);
  });

  testWidgets(
    'full source-receipt spool has no aggregate +/- controls on shelf card',
    (tester) async {
      final item = await addReceivedSpool(grams: 1000);
      await render(
        tester,
        Center(
          child: SizedBox(
            width: 280,
            height: 300,
            child: MaterialShelfCard(item: item),
          ),
        ),
      );
      expect(find.byIcon(Icons.add_rounded), findsNothing);
      expect(find.byIcon(Icons.remove_rounded), findsNothing);
      expect(find.text('按克数管理此具体卷'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets('inventory sorts a full 1 kg spool before a used 1 kg spool', (
    tester,
  ) async {
    final used = await add(
      415,
      total: 1000,
      colorName: 'A-used-first-alphabetically',
    );
    final full = await add(
      1000,
      total: 1000,
      colorName: 'Z-full-last-alphabetically',
    );
    await render(tester, const InventoryScreen());
    final usedPosition = tester.getTopLeft(
      find.byKey(ValueKey('material-shelf-surface-${used.id}')),
    );
    final fullPosition = tester.getTopLeft(
      find.byKey(ValueKey('material-shelf-surface-${full.id}')),
    );
    expect(fullPosition.dx, lessThan(usedPosition.dx));
    await unmount(tester);
  });
}
