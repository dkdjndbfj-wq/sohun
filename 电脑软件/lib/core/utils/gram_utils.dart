/// 耗材克数格式化工具。统一克数在 UI 上的展示格式。
///
/// 商业化软件需要同时展示「卷数」与「克数」两个维度：
/// - 卷数：粗略库存计量（1 卷 = 1000g），便于快速理解规模
/// - 克数：精确消耗计量，用于切片任务的真实扣减（如 23.5g）
class GramUtils {
  GramUtils._();

  /// 克数比较容差，避免同步或浮点运算产生的极小误差把满卷误判为已使用。
  static const double comparisonToleranceGrams = 0.01;

  /// 每卷标准克数（1 卷 = 1kg）。
  /// 全局统一，未来如需支持 250g/500g/2kg 卷再扩展为 per-record 字段。
  static const double gramsPerRoll = 1000.0;

  /// 克数 → 卷数（向下取整，不足 1 卷按 0 卷计库存可视）。
  static int gramsToRolls(double grams) {
    if (grams <= 0) return 0;
    return (grams / gramsPerRoll).floor();
  }

  /// 卷数 → 克数
  static double rollsToGrams(int rolls) => rolls * gramsPerRoll;

  /// 是否已经从一卷具体耗材中使用过材料。
  ///
  /// [total] 始终代表该卷入库时的容量；[remaining] 小于它才表示余料卷。
  /// 卷规格可以是 250g、750g、1kg 或 2kg，不能用整千克倍数推断。
  static bool isPartiallyUsed(double remaining, double total) {
    if (!remaining.isFinite || !total.isFinite || total <= 0) return false;
    return remaining + comparisonToleranceGrams < total;
  }

  /// 格式化克数为带单位字符串。
  /// - >= 1000g 显示为 `1.2kg`
  /// - < 1000g 显示为 `23.5g`
  /// - 0 显示为 `0g`
  static String formatGrams(double grams) {
    if (grams <= 0) return '0g';
    if (grams >= 1000) {
      final kg = grams / 1000;
      // 整数 kg 显示为 `2kg`，小数显示为 `1.2kg`
      if (kg == kg.roundToDouble()) return '${kg.round()}kg';
      return '${kg.toStringAsFixed(1)}kg';
    }
    // < 1000g 保留 1 位小数（如 23.5g），整数省略小数（如 500g）
    if (grams == grams.roundToDouble()) return '${grams.round()}g';
    return '${grams.toStringAsFixed(1)}g';
  }

  /// 格式化「剩余/总」对比字符串，如 `2.5kg / 3kg` 或 `23.5g / 1kg`。
  static String formatRatio(double remaining, double total) {
    return '${formatGrams(remaining)} / ${formatGrams(total)}';
  }

  /// 卷数 + 克数组合显示，如 `3卷 · 3kg` 或 `0卷 · 23.5g`。
  /// 用于卡片副标题等需要同时展示两个维度的场景。
  static String formatRollsAndGrams(double remainingGrams) {
    final rolls = gramsToRolls(remainingGrams);
    return '$rolls卷 · ${formatGrams(remainingGrams)}';
  }
}
