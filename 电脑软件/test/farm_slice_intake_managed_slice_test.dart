import 'package:consumable_tracker_desktop/data/external/slicer/production_package_inspector.dart';
import 'package:consumable_tracker_desktop/providers/farm_slice_intake_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Sohun 内部切片不会进入全局新切片弹窗队列', () async {
    final notifier = FarmSliceIntakeNotifier();
    addTearDown(notifier.dispose);
    final inspection = _inspection('C:/Temp/bamboo_model/internal.gcode');

    await notifier.runManagedSlice(
      () async {
        notifier.submit(inspection);
        return inspection;
      },
      inspectionOf: (result) => result,
    );
    await Future<void>.delayed(const Duration(milliseconds: 2300));

    expect(notifier.state.pending, isEmpty);
    expect(notifier.state.deferred, isEmpty);
  });

  test('内部切片期间另一个项目的手动切片仍会进入弹窗队列', () async {
    final notifier = FarmSliceIntakeNotifier();
    addTearDown(notifier.dispose);
    const managedSource = 'C:/orders/managed-project.3mf';
    final managed = _inspection(
      'C:/Temp/bamboo_model/managed.gcode',
      correlationKey: managedSource,
      projectPath: managedSource,
    );
    final manual = _inspection(
      'C:/Temp/bamboo_model/manual.gcode',
      correlationKey: 'C:/orders/manual-project.3mf',
      projectPath: 'C:/orders/manual-project.3mf',
    );

    await notifier.runManagedSlice(
      () async {
        notifier.submit(managed);
        notifier.submit(manual);
        return managed;
      },
      inspectionOf: (result) => result,
      sourcePath: managedSource,
    );
    await Future<void>.delayed(const Duration(milliseconds: 2300));

    expect(notifier.state.pending, hasLength(1));
    expect(
      notifier.state.pending.single.inspection.artifactPath,
      manual.artifactPath,
    );
    expect(notifier.state.deferred, isEmpty);
  });

  test('同一来源的内部中间产物和延迟事件都不会进入弹窗队列', () async {
    final notifier = FarmSliceIntakeNotifier();
    addTearDown(notifier.dispose);
    const source = 'C:/orders/same-project.3mf';
    final intermediate = _inspection(
      'C:/Temp/bamboo_model/intermediate.gcode',
      correlationKey: source,
      projectPath: source,
    );
    final result = _inspection(
      'C:/app/farm_slices/job/result.3mf',
      correlationKey: source,
      projectPath: source,
    );

    await notifier.runManagedSlice(
      () async {
        notifier.submit(intermediate);
        return result;
      },
      inspectionOf: (inspection) => inspection,
      sourcePath: source,
    );
    notifier.submit(intermediate);
    await Future<void>.delayed(const Duration(milliseconds: 2300));

    expect(notifier.state.pending, isEmpty);
    expect(notifier.state.deferred, isEmpty);
  });
}

ProductionPackageInspection _inspection(
  String path, {
  String? correlationKey,
  String? projectPath,
}) {
  return ProductionPackageInspection(
    artifactPath: path,
    displayName: '内部切片',
    kind: ProductionArtifactKind.gcode,
    isSliced: true,
    requiresReview: false,
    correlationKey: correlationKey,
    projectPath: projectPath,
    plates: const [
      ProductionPlateInspection(
        plateIndex: 1,
        name: '第 1 盘',
        hasToolpath: true,
        estimatedSeconds: 1200,
        totalLayers: 80,
        toolChangeCount: 0,
        estimatedGrams: 18,
        parts: [
          ProductionPartInspection(
            key: 'part-1',
            name: '测试件',
            instancesPerRun: 1,
          ),
        ],
        filaments: [],
      ),
    ],
    detectedAt: DateTime(2026, 8, 5, 20),
  );
}
