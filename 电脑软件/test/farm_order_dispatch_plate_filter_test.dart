import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_order_dispatch_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('生产调度过滤无对象、无切片事实的空盘', () {
    final now = DateTime(2026, 8, 5, 12);
    StudioProductionPlate plate(
      String id, {
      int estimatedSeconds = 0,
    }) =>
        StudioProductionPlate(
          id: id,
          workspaceId: 'farm',
          orderId: 'order',
          packageId: 'package',
          plateIndex: id == 'empty' ? 1 : 2,
          name: id,
          requiredRuns: 1,
          estimatedSeconds: estimatedSeconds,
          estimatedGrams: 0,
          createdAt: now,
        );

    final snapshot = StudioSnapshot(
      workspace: StudioWorkspace(
        id: 'farm',
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
      productionPlates: [
        plate('empty'),
        plate('with-item'),
        plate('legacy-with-toolpath-facts', estimatedSeconds: 900),
      ],
      orderItems: [
        StudioOrderItem(
          id: 'item',
          workspaceId: 'farm',
          orderId: 'order',
          packageId: 'package',
          plateId: 'with-item',
          sourceKey: 'object:1',
          name: '外壳',
          perRunQuantity: 1,
          requiredQuantity: 1,
          createdAt: now,
        ),
      ],
    );

    expect(
      farmDispatchablePlatesForOrder(snapshot, 'order').map((item) => item.id),
      ['with-item', 'legacy-with-toolpath-facts'],
    );
  });
}
