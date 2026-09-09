import 'dart:io';

import 'package:consumable_tracker_desktop/data/external/slicer/bambu_studio_slicing_service.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/production_package_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('后台切片参数保留带空格路径并切片全部盘', () {
    final arguments = BambuStudioSlicingService.buildArguments(
      sourcePath: r'C:\订单文件\customer model.3mf',
      outputPath: r'C:\Sohun Data\result.3mf',
    );

    expect(arguments, [
      '--slice',
      '0',
      '--debug',
      '2',
      '--export-3mf',
      r'C:\Sohun Data\result.3mf',
      r'C:\订单文件\customer model.3mf',
    ]);
  });

  test('单盘切片把真实盘号传给 Bambu Studio', () {
    final arguments = BambuStudioSlicingService.buildArguments(
      sourcePath: r'C:\订单文件\multi plate.3mf',
      outputPath: r'C:\Sohun Data\plate-3.3mf',
      plateIndex: 3,
    );

    expect(arguments[0], '--slice');
    expect(arguments[1], '3');
    expect(arguments.last, r'C:\订单文件\multi plate.3mf');
  });

  test('官方 CLI 参数按机器加工艺、耗材、切片命令的顺序生成', () {
    final arguments = BambuStudioSlicingService.buildArguments(
      sourcePath: r'C:\订单文件\project.3mf',
      outputPath: r'C:\Sohun Data\result.3mf',
      plateIndex: 2,
      settingsPaths: const [
        r'C:\profiles\machine.json',
        r'C:\profiles\process.json',
      ],
      filamentSettingsPaths: const [
        r'C:\profiles\pla.json',
        r'C:\profiles\support.json',
      ],
    );

    expect(arguments.take(4), [
      '--load-settings',
      r'C:\profiles\machine.json;C:\profiles\process.json',
      '--load-filaments',
      r'C:\profiles\pla.json;C:\profiles\support.json',
    ]);
    expect(arguments.skip(4).take(2), ['--slice', '2']);
  });

  test('单盘验收只要求所选盘有刀路', () {
    final source = _inspection(toolpathIndexes: const {});
    final output = _inspection(toolpathIndexes: const {1});

    expect(
      BambuStudioSlicingService.findIncompleteSourcePlates(
        source: source,
        output: output,
        expectedPlateIndexes: const {1},
      ),
      isEmpty,
    );
    expect(
      BambuStudioSlicingService.findIncompleteSourcePlates(
        source: source,
        output: output,
        expectedPlateIndexes: const {2},
      ).map((plate) => plate.plateIndex),
      [2],
    );
  });

  test('切片结果沿用源盘对象原名且不会把实例数翻倍', () {
    final source = _inspection(toolpathIndexes: const {});
    final output = _inspection(
      toolpathIndexes: const {1},
      firstPartName: 'Object 1',
    );

    final merged = BambuStudioSlicingService.applySourcePlateMetadata(
      source: source,
      output: output,
    );

    expect(merged.plates.first.parts.single.name, '原始外壳');
    expect(merged.plates.first.parts.single.instancesPerRun, 2);
  });

  test('切片产物清理只删除未引用目录并保护队列历史文件', () async {
    final root = await Directory.systemTemp.createTemp('farm-slices-cleanup-');
    addTearDown(() => root.delete(recursive: true));
    final protectedDirectory = Directory('${root.path}/protected-job');
    final staleDirectory = Directory('${root.path}/stale-job');
    await protectedDirectory.create();
    await staleDirectory.create();
    final protectedArtifact = File('${protectedDirectory.path}/result.3mf');
    await protectedArtifact.writeAsString('protected');
    await File('${staleDirectory.path}/result.3mf').writeAsString('stale');

    final removed =
        await BambuStudioSlicingService.cleanupUnreferencedArtifacts(
      outputRoot: root,
      protectedPaths: {protectedArtifact.path},
      maxDirectories: 0,
    );

    expect(removed, 1);
    expect(await protectedDirectory.exists(), isTrue);
    expect(await staleDirectory.exists(), isFalse);
  });
}

ProductionPackageInspection _inspection({
  required Set<int> toolpathIndexes,
  String firstPartName = '原始外壳',
}) {
  return ProductionPackageInspection(
    artifactPath: 'C:/fixture/project.3mf',
    displayName: '多盘项目',
    kind: ProductionArtifactKind.bambu3mf,
    isSliced: toolpathIndexes.isNotEmpty,
    requiresReview: toolpathIndexes.length < 2,
    plates: [
      ProductionPlateInspection(
        plateIndex: 1,
        name: '外壳盘',
        hasToolpath: toolpathIndexes.contains(1),
        estimatedSeconds: toolpathIndexes.contains(1) ? 1200 : 0,
        totalLayers: toolpathIndexes.contains(1) ? 80 : 0,
        toolChangeCount: 0,
        estimatedGrams: toolpathIndexes.contains(1) ? 18 : 0,
        parts: [
          ProductionPartInspection(
            key: 'object:1',
            name: firstPartName,
            instancesPerRun: 2,
          ),
        ],
        filaments: const [],
      ),
      ProductionPlateInspection(
        plateIndex: 2,
        name: '底座盘',
        hasToolpath: toolpathIndexes.contains(2),
        estimatedSeconds: 0,
        totalLayers: 0,
        toolChangeCount: 0,
        estimatedGrams: 0,
        parts: const [
          ProductionPartInspection(
            key: 'object:2',
            name: '原始底座',
            instancesPerRun: 1,
          ),
        ],
        filaments: const [],
      ),
    ],
    detectedAt: DateTime(2026, 8, 3),
    hasEmbeddedSettings: true,
  );
}
