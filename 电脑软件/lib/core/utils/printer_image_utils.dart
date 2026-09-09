import '../../data/seed/printer_seed.dart';

/// 打印机图片工具。统一处理 imageAsset 的 fallback 逻辑。
class PrinterImageUtils {
  PrinterImageUtils._();

  /// 品牌别名映射（双向）。云端/不同来源可能用英文或中文品牌名，
  /// 这里统一映射，保证图片能匹配上预设资源。
  /// key 和 value 都可作为输入，查询时会双向尝试。
  static const Map<String, String> _brandAliases = {
    'Bambu Lab': '拓竹',
    'BambuLab': '拓竹',
    'bambu': '拓竹',
    'Creality': '创想三维',
    '创维三维': '创想三维',
    'Anycubic': '纵维立方',
  };

  /// 旧型号 → 新型号兼容映射。
  ///
  /// 早期版本 `_normalizeModel` 把云端型号归并为大类（X1/P1/H2），
  /// 旧数据库记录的 model 可能是这些大类。现已改为保留细分型号，
  /// 这里做兼容处理，让旧记录也能匹配到正确的预设图片。
  ///
  /// 映射策略：旧大类 → 最常见的细分型号（图片 fallback）。
  static const Map<String, String> _legacyModelMap = {
    'P1': 'P1S', // P1 系列 → P1S（P1S 比 P1P 更常见）
    'H2': 'H2D', // H2 系列 → H2D
  };

  /// 根据打印机数据库记录解析出实际可用的 asset 路径。
  /// 优先使用数据库里的 imageAsset（自定义图片路径或预设 asset）；
  /// 若为空，则按 brand+model 从 PrinterPresets 查找匹配的预设图片。
  ///
  /// **品牌兼容**：brand 可能是中文（"拓竹"）或英文（"Bambu Lab"），
  /// 通过别名映射双向查找。model 也尝试大小写和空格容错。
  /// **旧型号兼容**：旧数据 model 为 "X1"/"P1"/"H2" 大类时，映射到细分型号。
  /// 返回 null 表示无可用图片（由 PrinterImage 组件走 fallback 图标）。
  static String? resolveAsset({
    String? imageAsset,
    required String brand,
    required String model,
  }) {
    if (imageAsset != null && imageAsset.isNotEmpty) {
      return imageAsset;
    }
    final preset = PrinterPresets.findByModel(model, brand: brand);
    if (preset != null) return preset.imageAsset;

    // 收集所有候选品牌名（原名 + 别名映射的双向结果）
    final candidates = <String>{brand};
    final mapped = _brandAliases[brand];
    if (mapped != null) {
      candidates.add(mapped);
    }
    // 反向查找：若 brand 是中文名，加入对应的英文名
    _brandAliases.forEach((en, zh) {
      if (zh == brand) candidates.add(en);
    });

    // 候选型号（原值 + 去空格 + 旧型号兼容映射）
    final modelCandidates = <String>{model, model.replaceAll(' ', '')};
    final legacy = _legacyModelMap[model];
    if (legacy != null) {
      modelCandidates.add(legacy);
    }

    // 遍历所有品牌×型号组合，找到第一个匹配的预设
    for (final b in candidates) {
      for (final m in modelCandidates) {
        final match = PrinterPresets.all
            .where((e) => e.brand == b && e.model == m)
            .map((e) => e.imageAsset)
            .firstOrNull;
        if (match != null) return match;
      }
    }
    return null;
  }
}
