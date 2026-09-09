import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/features/studio/studio_operations_screens.dart';
import 'package:consumable_tracker_desktop/providers/farm_material_type_catalog_provider.dart';
import 'package:consumable_tracker_desktop/providers/studio_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('批量入库通过带代号的型号页选择耗材', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 8, 6, 12);
    final snapshot = StudioSnapshot(
      workspace: StudioWorkspace(
        id: 'farm-model-picker-test',
        name: '测试农场',
        createdAt: now,
        updatedAt: now,
      ),
      members: const [],
      customers: const [],
      orders: const [],
      workOrders: const [],
      quotes: const [],
      inventoryEvents: const [],
      inventoryBatches: const [],
      shareLinks: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          studioSnapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
          farmConsumablesProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          currentFarmPermissionProvider.overrideWith((ref, code) => true),
          farmMaterialTypeCatalogProvider.overrideWith(
            (ref) async => const [
              'PLA Basic',
              'PETG Basic',
            ],
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: StudioBatchInventoryScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('批量入库'));
    await tester.pumpAndSettle();

    final modelField = find.byKey(
      const ValueKey('farm-batch-model-picker-0'),
    );
    expect(modelField, findsOneWidget);
    expect(
      find.descendant(of: modelField, matching: find.byType(TextField)),
      findsNothing,
    );

    await tester.tap(modelField);
    await tester.pumpAndSettle();

    expect(find.text('选择耗材类型'), findsOneWidget);
    expect(find.text('PB'), findsOneWidget);
    expect(find.text('GB'), findsOneWidget);
    expect(find.textContaining('Bambu'), findsNothing);

    await tester.tap(find.text('PETG Basic'));
    await tester.pumpAndSettle();

    expect(find.text('PETG Basic'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.decoration?.labelText == '材质',
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
