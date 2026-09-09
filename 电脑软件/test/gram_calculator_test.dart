import 'package:consumable_tracker_desktop/data/database/models/print_task.dart';
import 'package:consumable_tracker_desktop/data/external/print_task/gram_calculator.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/slice_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// GramCalculator 单元测试。
///
/// 覆盖核心算法的正确性：
/// - 粗略模式：按 mcPercent 比例换算
/// - 精细模式：按层号查 layerCumulativeGrams 表
/// - 多色任务按 perFilamentGrams 占比拆分
/// - 剩余时长估算
///
/// 这些算法是耗材扣减的核心，错了会直接导致库存不准。
void main() {
  group('GramCalculator.calculate - 粗略模式', () {
    test('estimatedGrams <= 0 时返回 0（防御性）', () {
      final task = _makeTask(estimatedGrams: 0, lastMcPercent: 50);
      expect(
        GramCalculator.calculate(
          task: task,
          mode: CalculationMode.coarse,
        ),
        0,
      );
    });

    test('mcPercent=0 返回 0', () {
      final task = _makeTask(estimatedGrams: 100, lastMcPercent: 0);
      expect(
        GramCalculator.calculate(task: task, mode: CalculationMode.coarse),
        0,
      );
    });

    test('mcPercent=50 返回 estimatedGrams × 50%', () {
      final task = _makeTask(estimatedGrams: 100, lastMcPercent: 50);
      expect(
        GramCalculator.calculate(task: task, mode: CalculationMode.coarse),
        50,
      );
    });

    test('mcPercent=100 返回 estimatedGrams 全量', () {
      final task = _makeTask(estimatedGrams: 100, lastMcPercent: 100);
      expect(
        GramCalculator.calculate(task: task, mode: CalculationMode.coarse),
        100,
      );
    });

    test('mcPercent > 100 被 clamp 到 100', () {
      final task = _makeTask(estimatedGrams: 100, lastMcPercent: 150);
      expect(
        GramCalculator.calculate(task: task, mode: CalculationMode.coarse),
        100,
      );
    });

    test('mcPercent < 0 被 clamp 到 0', () {
      final task = _makeTask(estimatedGrams: 100, lastMcPercent: -10);
      expect(
        GramCalculator.calculate(task: task, mode: CalculationMode.coarse),
        0,
      );
    });

    test('多色任务 100g/3 色各占 1/3，进度 50% → 总 50g', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 50,
        perFilamentGrams: const [33.33, 33.33, 33.34],
      );
      expect(
        GramCalculator.calculate(task: task, mode: CalculationMode.coarse),
        closeTo(50, 0.01),
      );
    });
  });

  group('GramCalculator.calculate - 精细模式', () {
    test('layerCumulativeGrams 为 null → 回退粗略', () {
      final task = _makeTask(estimatedGrams: 100, lastMcPercent: 50);
      final slice = SliceResult(
        filePath: '/test.gcode',
        taskName: 'test',
        filaments: const [],
        estimatedSeconds: 0,
        toolChangeCount: 0,
        totalLayers: 0,
        slicerName: 'BambuStudio',
      );
      expect(
        GramCalculator.calculate(
          task: task,
          slice: slice,
          mode: CalculationMode.precise,
        ),
        50,
      );
    });

    test('layerCumulativeGrams 为空 Map → 回退粗略', () {
      final task = _makeTask(estimatedGrams: 100, lastMcPercent: 50);
      final slice = _makeSlice(layerCumulativeGrams: const {});
      expect(
        GramCalculator.calculate(
          task: task,
          slice: slice,
          mode: CalculationMode.precise,
        ),
        50,
      );
    });

    test('currLayer 在表中 → 直接取该层累计克数', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 50,
        lastLayer: 5,
      );
      // 累计克数：5 层时已消耗 30g
      final slice = _makeSlice(
        layerCumulativeGrams: {
          0: 5.0,
          1: 10.0,
          2: 15.0,
          3: 20.0,
          4: 25.0,
          5: 30.0,
          6: 35.0,
          7: 40.0,
        },
      );
      expect(
        GramCalculator.calculate(
          task: task,
          slice: slice,
          mode: CalculationMode.precise,
        ),
        30,
      );
    });

    test('currLayer 超出最大层号 → 取最大层号的克数', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 99,
        lastLayer: 999, // 超出表
      );
      final slice = _makeSlice(
        layerCumulativeGrams: {
          0: 5.0,
          1: 10.0,
          2: 15.0, // 最大层
        },
      );
      expect(
        GramCalculator.calculate(
          task: task,
          slice: slice,
          mode: CalculationMode.precise,
        ),
        15,
      );
    });

    test('currLayer 不在表中（空层场景）→ 取不大于 currLayer 的最大层号', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 30,
        lastLayer: 2, // 层 2 不在表中（被空层跳过）
      );
      final slice = _makeSlice(
        layerCumulativeGrams: {
          0: 5.0,
          1: 10.0,
          // 层 2 缺失
          3: 20.0,
        },
      );
      expect(
        GramCalculator.calculate(
          task: task,
          slice: slice,
          mode: CalculationMode.precise,
        ),
        10, // 取不大于 2 的最大层号（1）的值
      );
    });

    test('currLayer=0 且表中有层 0 → 取层 0 的值', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 1,
        lastLayer: 0,
      );
      final slice = _makeSlice(
        layerCumulativeGrams: {
          0: 2.5,
          1: 5.0,
        },
      );
      expect(
        GramCalculator.calculate(
          task: task,
          slice: slice,
          mode: CalculationMode.precise,
        ),
        2.5,
      );
    });
  });

  group('GramCalculator.calculatePerFilament - 多色拆分', () {
    test('perFilamentGrams 为空 → 返回空列表', () {
      final task = _makeTask(estimatedGrams: 100, lastMcPercent: 50);
      expect(
        GramCalculator.calculatePerFilament(
          task: task,
          mode: CalculationMode.coarse,
        ),
        isEmpty,
      );
    });

    test('3 色均分（各 1/3），总进度 60% → 各色 20g', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 60,
        perFilamentGrams: const [33.33, 33.33, 33.34],
      );
      final result = GramCalculator.calculatePerFilament(
        task: task,
        mode: CalculationMode.coarse,
      );
      expect(result.length, 3);
      // 总和应接近 60g
      expect(result.fold(0.0, (a, b) => a + b), closeTo(60, 0.01));
      // 每色应接近 20g（按占比均分）
      for (final g in result) {
        expect(g, closeTo(20, 0.01));
      }
    });

    test('2 色不均分（80/20），总进度 50% → 主色 40g 副色 10g', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 50,
        perFilamentGrams: const [80, 20],
      );
      final result = GramCalculator.calculatePerFilament(
        task: task,
        mode: CalculationMode.coarse,
      );
      expect(result.length, 2);
      expect(result[0], closeTo(40, 0.01));
      expect(result[1], closeTo(10, 0.01));
    });

    test('estimatedGrams <= 0 → 每色返回 0', () {
      final task = _makeTask(
        estimatedGrams: 0,
        lastMcPercent: 50,
        perFilamentGrams: const [10, 20, 30],
      );
      final result = GramCalculator.calculatePerFilament(
        task: task,
        mode: CalculationMode.coarse,
      );
      expect(result, [0.0, 0.0, 0.0]);
    });
  });

  group('GramCalculator.estimateRemainingSeconds - 剩余时长', () {
    test('mcPercent >= 100 → 返回 0（已完成）', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 100,
        startedAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
      expect(GramCalculator.estimateRemainingSeconds(task: task), 0);
    });

    test('mcPercent <= 0 → 返回切片预估时长', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 0,
        estimatedSeconds: 3600,
      );
      expect(GramCalculator.estimateRemainingSeconds(task: task), 3600);
    });

    test('mcPercent=50 已耗 1 小时 → 剩余约 1 小时', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 50,
        estimatedSeconds: 7200,
        startedAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
      // remaining = elapsed(3600) × (100-50)/50 = 3600
      expect(
        GramCalculator.estimateRemainingSeconds(task: task),
        closeTo(3600, 5),
      );
    });

    test('mcPercent=25 已耗 30 分钟 → 剩余约 90 分钟', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 25,
        estimatedSeconds: 7200,
        startedAt: DateTime.now().subtract(const Duration(minutes: 30)),
      );
      // remaining = 1800 × (100-25)/25 = 5400 秒 = 90 分钟
      expect(
        GramCalculator.estimateRemainingSeconds(task: task),
        closeTo(5400, 5),
      );
    });

    test('startedAt 为 null → 返回切片预估时长', () {
      final task = _makeTask(
        estimatedGrams: 100,
        lastMcPercent: 50,
        estimatedSeconds: 3600,
        // startedAt 不传，默认 null
      );
      expect(GramCalculator.estimateRemainingSeconds(task: task), 3600);
    });
  });
}

/// 构造测试用 PrintTask。
PrintTask _makeTask({
  double estimatedGrams = 100,
  int estimatedSeconds = 3600,
  int lastMcPercent = 0,
  int lastLayer = 0,
  List<double> perFilamentGrams = const [],
  DateTime? startedAt,
}) {
  return PrintTask(
    uid: 'test-uid',
    gcodePath: '/test.gcode',
    taskName: 'test',
    estimatedGrams: estimatedGrams,
    estimatedSeconds: estimatedSeconds,
    actualGrams: 0,
    startedAt: startedAt,
    lastMcPercent: lastMcPercent,
    lastLayer: lastLayer,
    status: PrintTaskStatus.printing,
    source: 'screen',
    perFilamentGrams: perFilamentGrams,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

/// 构造测试用 SliceResult（仅填 layerCumulativeGrams）。
SliceResult _makeSlice({Map<int, double>? layerCumulativeGrams}) {
  return SliceResult(
    filePath: '/test.gcode',
    taskName: 'test',
    filaments: const [],
    estimatedSeconds: 0,
    toolChangeCount: 0,
    totalLayers: layerCumulativeGrams?.length ?? 0,
    slicerName: 'BambuStudio',
    layerCumulativeGrams: layerCumulativeGrams,
  );
}
