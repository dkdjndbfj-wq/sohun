import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/features/studio/studio_work_order_materials.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  StudioWorkOrderMaterial material({
    required int toolIndex,
    required StudioWorkOrderMaterialStatus status,
    int? consumableId,
    double estimated = 12,
    double reserved = 0,
    double consumed = 0,
  }) {
    final now = DateTime(2026, 8, 4);
    return StudioWorkOrderMaterial(
      id: 'material-$toolIndex',
      workspaceId: 'workspace',
      workOrderId: 'work-order',
      productionPlateId: 'plate',
      toolIndex: toolIndex,
      materialType: 'PETG',
      colorHex: toolIndex == 0 ? '#F7D959' : '#FFFFFF',
      estimatedGrams: estimated,
      consumableId: consumableId,
      reservedGrams: reserved,
      consumedGrams: consumed,
      status: status,
      createdAt: now,
      updatedAt: now,
    );
  }

  testWidgets('unallocated work order reports every material channel',
      (tester) async {
    var managed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudioWorkOrderMaterialSummary(
            materials: [
              material(
                toolIndex: 0,
                status: StudioWorkOrderMaterialStatus.unallocated,
              ),
              material(
                toolIndex: 2,
                status: StudioWorkOrderMaterialStatus.unallocated,
              ),
            ],
            onManage: () => managed = true,
          ),
        ),
      ),
    );

    expect(find.text('待分配 2 个耗材通道'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('studio-manage-work-order-materials')),
    );
    expect(managed, isTrue);
  });

  testWidgets('reserved and settled ledgers show distinct totals',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              StudioWorkOrderMaterialSummary(
                materials: [
                  material(
                    toolIndex: 0,
                    status: StudioWorkOrderMaterialStatus.reserved,
                    consumableId: 1,
                    estimated: 22.73,
                    reserved: 22.73,
                  ),
                  material(
                    toolIndex: 2,
                    status: StudioWorkOrderMaterialStatus.reserved,
                    consumableId: 2,
                    estimated: 16.24,
                    reserved: 16.24,
                  ),
                ],
              ),
              StudioWorkOrderMaterialSummary(
                materials: [
                  material(
                    toolIndex: 0,
                    status: StudioWorkOrderMaterialStatus.settled,
                    consumableId: 1,
                    consumed: 21.5,
                  ),
                  material(
                    toolIndex: 2,
                    status: StudioWorkOrderMaterialStatus.settled,
                    consumableId: 2,
                    consumed: 15,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('已预留 39.0 g'), findsOneWidget);
    expect(find.text('耗材已结算 36.5 g'), findsOneWidget);
  });
}
