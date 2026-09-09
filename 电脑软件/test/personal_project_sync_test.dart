import 'dart:typed_data';

import 'package:consumable_tracker_desktop/data/database/daos/studio_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/production_package_inspector.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late StudioDao dao;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dao = StudioDao(database);
    await dao.ensureDefaultWorkspace();
  });

  tearDown(() async {
    dao.dispose();
    await database.close();
  });

  test('拓竹保存后同步项目路径、缩略图并使旧切片失效', () async {
    final workspace = (await dao.getDefaultSnapshot()).workspace;
    final orderId = await dao.addProductionOrder(
      workspaceId: workspace.id,
      orderNo: 'PERSONAL-SYNC-1',
      title: '个人同步测试',
      packages: [
        StudioProductionPackageDraft(
          sourceName: 'old.3mf',
          localPath: 'C:/old.3mf',
          artifactKind: 'bambu3mf',
          plates: [
            StudioProductionPlateDraft(
              plateIndex: 1,
              name: '旧盘名',
              requiredRuns: 1,
              estimatedSeconds: 100,
              estimatedGrams: 10,
              sliceStatus: StudioPlateSliceStatus.sliced,
              thumbnailBytes: Uint8List.fromList(<int>[1]),
              items: [
                StudioOrderItemDraft(
                  sourceKey: 'object:1',
                  name: '模型',
                  perRunQuantity: 1,
                  requiredQuantity: 1,
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final before = await dao.getDefaultSnapshot();
    final package = before.productionPackages
        .singleWhere((item) => item.orderId == orderId);
    final plate = before.productionPlates
        .singleWhere((item) => item.packageId == package.id);

    final inspection = ProductionPackageInspection(
      artifactPath: 'C:/edited.3mf',
      displayName: 'edited',
      kind: ProductionArtifactKind.bambu3mf,
      isSliced: false,
      requiresReview: true,
      artifactSha256: 'edited-hash',
      plates: [
        ProductionPlateInspection(
          plateIndex: 1,
          name: '新盘名',
          hasToolpath: false,
          estimatedSeconds: 0,
          totalLayers: 0,
          toolChangeCount: 0,
          estimatedGrams: 0,
          parts: [
            ProductionPartInspection(
              key: 'object:1',
              name: '模型',
              instancesPerRun: 1,
            ),
          ],
          filaments: const [],
          thumbnailBytes: Uint8List.fromList(<int>[9, 8, 7]),
        ),
      ],
      detectedAt: DateTime.now(),
    );

    final refreshed = await dao.syncProductionPackageFromInspection(
      packageId: package.id,
      localPath: 'C:/edited.3mf',
      inspection: inspection,
    );

    expect(refreshed, 1);
    final after = await dao.getDefaultSnapshot();
    final updatedPackage =
        after.productionPackages.singleWhere((item) => item.id == package.id);
    final updatedPlate =
        after.productionPlates.singleWhere((item) => item.id == plate.id);
    expect(updatedPackage.localPath, endsWith('edited.3mf'));
    expect(updatedPackage.artifactSha256, 'edited-hash');
    expect(updatedPlate.name, '新盘名');
    expect(updatedPlate.sliceStatus, StudioPlateSliceStatus.pending);
    expect(updatedPlate.thumbnailBytes, orderedEquals(<int>[9, 8, 7]));
    expect(updatedPlate.sliceArtifactPath, isNull);
    final updatedItem =
        after.orderItems.singleWhere((item) => item.plateId == updatedPlate.id);
    expect(updatedItem.name, '模型');
  });
}
