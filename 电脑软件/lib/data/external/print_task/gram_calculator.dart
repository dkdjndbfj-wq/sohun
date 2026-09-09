import '../../database/daos/print_task_dao.dart';
import '../slicer/slice_result.dart';

/// 克数计算模式。
///
/// - [coarse]：粗略模式，按 mc_percent 比例估算（公式简单，多色任务有偏差）
/// - [precise]：精细模式，按层号查 layerCumulativeGrams 表（准确，需 G-code 含 ;LAYER:N）
enum CalculationMode { coarse, precise }

/// 克数计算引擎。把打印机实时进度快照换算成已消耗克数。
///
/// 支持两种模式：
///
/// **粗略模式** [CalculationMode.coarse]
/// - 公式：`actualGrams = estimatedGrams × mcPercent / 100`
/// - 优点：实现简单，任何 G-code 都能算
/// - 缺点：mc_percent 是按 G-code 行数算的，不是按耗材量算的，
///   多色任务中换料前的层 mc_percent 低但耗材已耗很多，会有偏差
///
/// **精细模式** [CalculationMode.precise]
/// - 公式：`actualGrams = layerCumulativeGrams[currLayer]`
/// - 优点：按真实挤出量累加，准确度高
/// - 缺点：需要 G-code 含 `;LAYER:N` 注释（BambuStudio/PrusaSlicer 都有），
///   且首次启动需要全量扫描 G-code（大文件较慢，应在 isolate 中做）
/// - 容错：
///   1. layerCumulativeGrams 为空 / currLayer 超出范围 → 回退粗略模式
///   2. **层号错位检测**：MQTT 上报层号可能与 G-code `;LAYER:N` 编号不一致
///      （首层校准层、天空层、不同切片软件层号起始值差异），
///      导致精细模式算出的克数与粗略模式严重偏离。
///      检测条件：当精细模式结果与粗略模式偏差 > 50% 且绝对差 > 5g 时
///      判定为错位，自动回退粗略模式。
class GramCalculator {
  GramCalculator._();

  /// 层号错位检测阈值：精细模式与粗略模式偏差超过此比例且绝对差超过此克数
  /// 才判定为错位。避免在任务早期（克数小）误判。
  static const double _misalignmentRatio = 0.5; // 50%
  static const double _misalignmentAbsGrams = 5.0; // 5g

  /// 计算当前已消耗克数。
  ///
  /// [task] 当前任务（含 estimatedGrams、lastMcPercent、lastLayer）
  /// [slice] 切片解析结果（含 layerCumulativeGrams，可为 null）
  /// [mode] 计算模式
  static double calculate({
    required PrintTask task,
    SliceResult? slice,
    CalculationMode mode = CalculationMode.coarse,
  }) {
    if (task.estimatedGrams <= 0) return 0;

    switch (mode) {
      case CalculationMode.coarse:
        return _coarse(task);

      case CalculationMode.precise:
        final precise = _precise(task, slice);
        if (precise == null) return _coarse(task); // 解析数据不可用

        // 只有 MQTT 层号在映射中精确命中时才做错位检测。稀疏层表的
        // 空层回退、以及打印机已超过切片最大层号的完成态，应信任映射结果；
        // 否则会错误回退到按行数估算的粗略克数。
        final hasExactLayer =
            slice?.layerCumulativeGrams?.containsKey(task.lastLayer) ?? false;
        final coarse = _coarse(task);
        if (hasExactLayer && _isMisaligned(precise, coarse)) {
          // 错位时回退粗略模式，避免精细模式反而更不准
          return coarse;
        }
        return precise;
    }
  }

  /// 判定精细模式与粗略模式是否错位。
  ///
  /// 错位条件：偏差比例 > [_misalignmentRatio] **且** 绝对差 > [_misalignmentAbsGrams]。
  /// 双条件避免任务早期（克数小、绝对差也小）和接近完成（粗略模式接近满量）误判。
  ///
  /// 边界 case：
  /// - coarse = 0（任务刚开始 mcPercent=0）：精细模式任何正数都被判定错位
  ///   → 此时应回退粗略（即 0），符合预期（任务刚开始还没消耗）
  /// - coarse 接近 estimatedGrams（mcPercent 接近 100）：精细模式若小于 coarse
  ///   偏差比例会很大，但实际可能是精细模式更准 → 不在边界 case 触发
  ///   （通过绝对差 > 5g 的双条件过滤）
  static bool _isMisaligned(double precise, double coarse) {
    if (coarse <= 0) {
      // 粗略为 0 但精细有值：判定错位（任务刚开始 mcPercent=0 还没消耗）
      return precise > _misalignmentAbsGrams;
    }
    final diffRatio = ((precise - coarse).abs()) / coarse;
    final diffAbs = (precise - coarse).abs();
    return diffRatio > _misalignmentRatio && diffAbs > _misalignmentAbsGrams;
  }

  /// 粗略模式：按 mc_percent 比例算。
  /// mc_percent 是打印机报的 G-code 行数进度（0-100）。
  static double _coarse(PrintTask task) {
    final percent = task.lastMcPercent.clamp(0, 100);
    return task.estimatedGrams * percent / 100.0;
  }

  /// 精细模式：按层号查 layerCumulativeGrams 表。
  /// 返回 null 表示解析数据不可用，调用方应回退粗略模式。
  static double? _precise(PrintTask task, SliceResult? slice) {
    final layerMap = slice?.layerCumulativeGrams;
    if (layerMap == null || layerMap.isEmpty) return null;

    // currLayer 超出范围：用最大层号的克数
    // 注意：必须用「最大层号」而非 layerMap.length（条目数）作为上界。
    // layerMap 是稀疏 Map<层号, 累计克数>，G-code 跳层时 length < maxLayer，
    // 用 length 判断会在打印中途就误判为「已超出」并返回全部克数，造成大幅超扣。
    final maxLayer = layerMap.keys.reduce((a, b) => a > b ? a : b);
    if (task.lastLayer >= maxLayer) {
      return layerMap[maxLayer];
    }

    // currLayer 在表中：直接取
    if (layerMap.containsKey(task.lastLayer)) {
      return layerMap[task.lastLayer]!;
    }

    // currLayer 不在表中（可能有空层）：取不大于 currLayer 的最大层号
    final candidateKeys =
        layerMap.keys.where((k) => k <= task.lastLayer).toList()..sort();
    if (candidateKeys.isEmpty) return 0.0;
    return layerMap[candidateKeys.last];
  }

  /// 计算多色任务的每槽克数预估。
  /// 粗略模式按总进度等比例缩放每个槽位的预计克数。
  /// 精细模式只能给总数，无法拆分到每槽（G-code 精细解析是累计值）。
  static List<double> calculatePerFilament({
    required PrintTask task,
    SliceResult? slice,
    CalculationMode mode = CalculationMode.coarse,
  }) {
    if (task.perFilamentGrams.isEmpty) return const [];

    final totalActual = calculate(
      task: task,
      slice: slice,
      mode: mode,
    );

    if (task.estimatedGrams <= 0) {
      return List.filled(task.perFilamentGrams.length, 0.0);
    }

    // 按 perFilamentGrams 的占比拆分总实际克数
    return task.perFilamentGrams
        .map((g) => g / task.estimatedGrams * totalActual)
        .toList();
  }

  /// 估算任务剩余时长（秒）。
  /// 基于已耗时长 / 已耗进度 × 剩余进度。
  /// 任务刚开始（progress=0）时返回切片预估时长。
  static int estimateRemainingSeconds({
    required PrintTask task,
  }) {
    if (task.lastMcPercent >= 100) return 0;
    if (task.lastMcPercent <= 0) return task.estimatedSeconds;

    final elapsed = task.elapsedSeconds;
    if (elapsed <= 0) return task.estimatedSeconds;

    // remaining = elapsed × (100 - percent) / percent
    final remaining = elapsed * (100 - task.lastMcPercent) / task.lastMcPercent;
    return remaining.round();
  }
}
