// 打印机型号规范化工具。
//
// 抽取唯一的型号规范化逻辑，替代 PrinterDao.normalizeModel、
// printer_image_utils 中 _legacyModelMap、parameter_compatibility_service
// 中散落的同款规则，避免多处规则互相漂移。
//
// 核心约束：
// - X1 Carbon 与 X1C 是等价别名（同一型号），都规范化为 X1C
// - P1S 与 P1P 是不同型号（gcode 不兼容），不能归并
// - A1 与 A1 mini 是不同型号（构建体积不同），不能归并
// - 仅用于 UI 分组时才允许把型号归入"机型组"（如 P1 组），但机型组
//   绝不能作为发送现成 G-code 的安全依据。任务分配必须匹配精确型号
//   + 喷嘴直径。

/// 规范化打印机型号为 canonical ID。
///
/// 输入示例：
///   "X1 Carbon" / "X1C" → "X1C"
///   "A1 mini" / "A1mini" / "A1M" → "A1mini"
///   "P1S 0.4mm nozzle" → "P1S"
///   "Bambu Lab P1S" → "P1S"
///   "@BBL X1C" → "X1C"
///   "H2D Pro" / "H2DP" → "H2D Pro"（独立机型）
class PrinterModelNormalizer {
  PrinterModelNormalizer._();

  /// 已知拓竹 canonical 型号集合。
  static const Set<String> knownBambuModels = {
    'X1',
    'X1C',
    'X1E',
    'X2D',
    'P1P',
    'P1S',
    'P2S',
    'A1',
    'A1mini',
    'A2L',
    'H2D',
    'H2D Pro',
    'H2S',
    'H2C',
  };

  /// 规范化打印机型号字符串。
  ///
  /// 步骤：
  /// 1. 去掉喷嘴后缀（如 " 0.4mm nozzle"）
  /// 2. 去掉品牌前缀（"Bambu Lab " / "@BBL "）
  /// 3. 大写后精确匹配别名，不把未来的 Plus/Pro/二代型号误归并
  /// 4. 未识别或含糊型号返回大写形式（让上层拒绝或要求用户确认）
  static String normalize(String input) {
    if (input.trim().isEmpty) return '';

    var p = input.trim();

    // 去除喷嘴后缀（如 " 0.4mm nozzle" / " 0.4 nozzle"）
    p = p.replaceAll(
      RegExp(r'\s+[0-9.]+\s*(?:mm\s*)?nozzle.*$', caseSensitive: false),
      '',
    );

    // 去品牌前缀
    p = p.replaceAll(RegExp(r'^bambu\s+lab\s+', caseSensitive: false), '');
    p = p.replaceAll(RegExp(r'^@?bbl\s+', caseSensitive: false), '');

    final upper = p.toUpperCase().trim();

    // X1 Carbon / X1C 别名等价
    if (upper == 'X1') return 'X1';
    if (upper == 'X1 CARBON' || upper == 'X1C') return 'X1C';
    if (upper == 'X1E') return 'X1E';
    if (upper == 'X2D') return 'X2D';
    if (upper == 'P1P') return 'P1P';
    if (upper == 'P1S') return 'P1S';
    if (upper == 'P2S') return 'P2S';
    if (upper == 'A1 MINI' || upper == 'A1MINI' || upper == 'A1M') {
      return 'A1mini';
    }
    if (upper == 'A1') return 'A1';
    if (upper == 'A2L') return 'A2L';
    if (upper == 'H2D') return 'H2D';
    if (upper == 'H2S') return 'H2S';
    if (upper == 'H2C') return 'H2C';
    if (upper == 'H2DP' || upper == 'H2DPRO' || upper == 'H2D PRO')
      return 'H2D Pro';

    return upper.isEmpty ? p : upper;
  }

  /// 判断两个型号字符串是否为同一 canonical 型号。
  ///
  /// 用于"任务目标机型 == 打印机机型"的精确匹配。
  /// 注意：这是精确匹配，不是机型组匹配。P1S 与 P1P 返回 false。
  static bool sameModel(String a, String b) {
    final na = normalize(a);
    final nb = normalize(b);
    return na.isNotEmpty && na == nb;
  }

  /// 判断型号是否为已知拓竹机型。
  static bool isKnownBambuModel(String input) {
    return knownBambuModels.contains(normalize(input));
  }

  /// 把 canonical 型号归入机型组（仅用于 UI 分组或候选提示）。
  ///
  /// 注意：机型组**不能**作为发送现成 G-code 的安全依据。
  /// 任务分配必须用 [sameModel] 精确匹配 canonical 型号 + 喷嘴直径。
  static PrinterModelGroupKey? groupOf(String input) {
    final n = normalize(input);
    if (n.isEmpty) return null;
    if (n == 'A1' || n == 'A1mini' || n == 'A2L') {
      return PrinterModelGroupKey.a1;
    }
    if (n == 'P1P' || n == 'P1S' || n == 'P2S') {
      return PrinterModelGroupKey.p1;
    }
    if (n == 'X1' || n == 'X1C' || n == 'X1E' || n == 'X2D') {
      return PrinterModelGroupKey.x1;
    }
    if (n == 'H2D' || n == 'H2D Pro' || n == 'H2S' || n == 'H2C') {
      return PrinterModelGroupKey.h2d;
    }
    return null;
  }
}

/// 机型组 key（仅用于 UI 分组或候选提示，不能作为调度安全依据）。
///
/// 与 scheduler_models.dart 的 PrinterModelGroup 不同：
/// - 这里是纯枚举，没有"组内 gcode 通用"的语义承诺
/// - 仅用作 UI 折叠/分组的 key
/// - 调度匹配必须用 PrinterModelNormalizer.sameModel + 喷嘴直径精确判断
enum PrinterModelGroupKey {
  a1('A1 系列'),
  p1('P1 系列'),
  x1('X1 系列'),
  h2d('H2D 系列');

  final String label;
  const PrinterModelGroupKey(this.label);
}
