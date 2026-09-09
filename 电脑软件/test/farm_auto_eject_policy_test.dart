import 'package:consumable_tracker_desktop/features/studio/farm_auto_eject_policy.dart';
import 'package:consumable_tracker_desktop/providers/farm_printer_model_profile_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('旧版机型全局开关不会恢复，但保留脚本模板', () {
    final profile = FarmPrinterModelProfile.fromJson({
      'modelKey': 'bambu-lab-a1',
      'displayName': 'Bambu Lab A1',
      'autoEjectEnabled': true,
      'autoEjectGcode': 'G1 X10 Y220',
    });

    expect(profile.autoEjectEnabled, isFalse);
    expect(profile.hasAutoEjectScript, isTrue);
    expect(profile.toJson()['autoEjectEnabled'], isFalse);
  });

  test('目标个数按整盘数量向上换算盘数', () {
    expect(requiredBatchRuns(targetQuantity: 100, objectsPerPlate: 12), 9);
    expect(requiredBatchRuns(targetQuantity: 24, objectsPerPlate: 12), 2);
    expect(requiredBatchRuns(targetQuantity: 0, objectsPerPlate: 12), 0);
  });

  test('批量打印机池同时要求精确机型和喷嘴一致', () {
    expect(
      isBatchPrinterCompatible(
        targetModel: 'Bambu Lab A1 0.4 nozzle',
        targetNozzle: .4,
        printerModel: 'A1',
        installedNozzle: .4,
      ),
      isTrue,
    );
    expect(
      isBatchPrinterCompatible(
        targetModel: 'A1',
        targetNozzle: .4,
        printerModel: 'A1 mini',
        installedNozzle: .4,
      ),
      isFalse,
    );
    expect(
      isBatchPrinterCompatible(
        targetModel: 'A1',
        targetNozzle: .4,
        printerModel: 'A1',
        installedNozzle: .6,
      ),
      isFalse,
    );
  });

  test('每轮只分给空闲打印机并遵守每台盘数上限', () {
    expect(
      allocateBatchRound(
        remainingRuns: 10,
        idlePrinterCount: 3,
        maxRunsPerPrinter: 2,
      ),
      [2, 2, 2],
    );
    expect(
      allocateBatchRound(
        remainingRuns: 4,
        idlePrinterCount: 3,
        maxRunsPerPrinter: 2,
      ),
      [2, 1, 1],
    );
  });

  test('旧产物或取件方式变化时必须重新切片', () {
    bool rebuild(bool? artifactFlag, bool requested) =>
        mustRebuildPlateArtifact(
          isSliced: true,
          artifactPath: 'C:/slices/plate_1.3mf',
          sameTarget: true,
          artifactAutoEjectEnabled: artifactFlag,
          useAutoEject: requested,
        );

    expect(rebuild(null, false), isTrue);
    expect(rebuild(false, false), isFalse);
    expect(rebuild(false, true), isTrue);
    expect(rebuild(true, false), isTrue);
    expect(rebuild(true, true), isFalse);
  });
}
