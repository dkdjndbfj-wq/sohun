import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../../data/models/print_parameter.dart';

/// 参数预设指纹服务。
///
/// 生成 canonical JSON（键排序、数值格式稳定、去除名称/作者/头像/点赞/下载/发布时间/本地路径等非参数字段），
/// 再用 SHA-256 生成稳定指纹 [presetFingerprint]。
///
/// 核心规则：
/// - 指纹相同代表真正的参数内容相同；仅改名称、作者或社区计数不得改变指纹。
/// - 指纹同时保存 [fingerprintSchemaVersion]；未来 canonical 规则变化时旧指纹仍可解释，
///   不能静默用新规则重算并覆盖历史。
class PresetFingerprintService {
  /// 当前 canonical JSON 规则版本。
  ///
  /// 规则变化时必须递增此版本号，并在数据库中保留旧版本指纹。
  /// 旧版本指纹绝不能用新规则重算覆盖。
  static const int currentSchemaVersion = 2;

  /// 为参数预设生成内容指纹。
  ///
  /// [preset] 的名称、作者、头像、点赞、下载、发布时间、社区 ID 等非参数字段
  /// 不参与指纹计算；只有真实的工艺参数（quality/strength/speed/support/other）
  /// 以及 [inherits]、[compatiblePrinters]、[material]、[scene] 参与计算。
  ///
  /// 返回 (schemaVersion, sha256hex)。
  static PresetFingerprint compute(PrintParameterPreset preset) {
    final canonical = _buildCanonicalMap(preset);
    final jsonStr = _canonicalJsonEncode(canonical);
    final hash = sha256.convert(utf8.encode(jsonStr)).toString();
    return PresetFingerprint(
      schemaVersion: currentSchemaVersion,
      contentHash: hash,
    );
  }

  /// 仅从参数子对象的 Map 生成指纹（用于快照恢复或服务端校验）。
  ///
  /// [paramsMap] 应包含 quality/strength/speed/support/other 五个 key，
  /// 每个 value 是 Map<String,String>。此方法不依赖 [PrintParameterPreset] 模型，
  /// 确保模型字段增减不影响已有指纹。
  static PresetFingerprint computeFromParamMaps({
    required Map<String, Map<String, String>> params,
    String inherits = 'fdm_process_common',
    List<String> compatiblePrinters = const [],
    String? material,
    String? scene,
    String? plateType,
  }) {
    final canonical = <String, dynamic>{
      'inherits': inherits,
      'material': material ?? '',
      'scene': scene ?? '',
      'plateType': plateType ?? '',
      'compatiblePrinters': _sortedList(compatiblePrinters),
      'params': _canonicalParamsMap(params),
    };
    final jsonStr = _canonicalJsonEncode(canonical);
    final hash = sha256.convert(utf8.encode(jsonStr)).toString();
    return PresetFingerprint(
      schemaVersion: currentSchemaVersion,
      contentHash: hash,
    );
  }

  /// 构建 canonical Map：仅包含参数内容，排除所有展示/社交/元数据字段。
  static Map<String, dynamic> _buildCanonicalMap(PrintParameterPreset preset) {
    return <String, dynamic>{
      'inherits': preset.inherits,
      'material': preset.material ?? '',
      'scene': preset.scene ?? '',
      'plateType': preset.plateType ?? '',
      'compatiblePrinters': _sortedList(preset.compatiblePrinters),
      'params': _canonicalParamsMap({
        'quality': preset.quality.toMap(),
        'strength': preset.strength.toMap(),
        'speed': preset.speed.toMap(),
        'support': preset.support.toMap(),
        'other': preset.other.toMap(),
      }),
    };
  }

  /// 对参数 Map 做 canonical 处理：每个子类别按键排序。
  static Map<String, dynamic> _canonicalParamsMap(
    Map<String, Map<String, String>> params,
  ) {
    final result = <String, dynamic>{};
    final sortedKeys = params.keys.toList()..sort();
    for (final key in sortedKeys) {
      final inner = params[key]!;
      final sortedInner = <String, dynamic>{};
      final innerKeys = inner.keys.toList()..sort();
      for (final ik in innerKeys) {
        sortedInner[ik] = _stableValue(inner[ik] ?? '');
      }
      result[key] = sortedInner;
    }
    return result;
  }

  /// 稳定化标量值：去除首尾空白，数值字符串做规范化。
  static String _stableValue(String v) {
    final trimmed = v.trim();
    if (trimmed.isEmpty) return '';
    // 尝试规范化数值：去掉前导零、尾部多余小数零
    final numValue = num.tryParse(trimmed);
    if (numValue != null) {
      // 使用 toString() 保证数值格式稳定
      return numValue.toString();
    }
    return trimmed;
  }

  /// 对字符串列表排序并去重，确保顺序无关。
  static List<String> _sortedList(List<String> input) {
    final set = input.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    return set.toList()..sort();
  }

  /// Canonical JSON 编码：键已排序，使用固定缩进，无尾随空格。
  static String _canonicalJsonEncode(Map<String, dynamic> map) {
    final buffer = StringBuffer();
    _writeCanonicalJson(buffer, map, 0);
    return buffer.toString();
  }

  static void _writeCanonicalJson(
    StringBuffer buffer,
    dynamic value,
    int indent,
  ) {
    final pad = '  ' * indent;
    if (value is Map<String, dynamic>) {
      if (value.isEmpty) {
        buffer.write('{}');
        return;
      }
      buffer.write('{\n');
      final keys = value.keys.toList()..sort();
      for (var i = 0; i < keys.length; i++) {
        buffer.write('$pad  "${keys[i]}": ');
        _writeCanonicalJson(buffer, value[keys[i]], indent + 1);
        if (i < keys.length - 1) buffer.write(',');
        buffer.write('\n');
      }
      buffer.write('$pad}');
    } else if (value is List) {
      if (value.isEmpty) {
        buffer.write('[]');
        return;
      }
      buffer.write('[\n');
      for (var i = 0; i < value.length; i++) {
        buffer.write('$pad  ');
        _writeCanonicalJson(buffer, value[i], indent + 1);
        if (i < value.length - 1) buffer.write(',');
        buffer.write('\n');
      }
      buffer.write('$pad]');
    } else if (value is String) {
      buffer.write(jsonEncode(value));
    } else if (value is num || value is bool) {
      buffer.write(value.toString());
    } else if (value == null) {
      buffer.write('null');
    } else {
      buffer.write(jsonEncode(value.toString()));
    }
  }
}

/// 参数预设指纹：包含 schema 版本和内容哈希。
class PresetFingerprint {
  final int schemaVersion;
  final String contentHash;

  const PresetFingerprint({
    required this.schemaVersion,
    required this.contentHash,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresetFingerprint &&
          schemaVersion == other.schemaVersion &&
          contentHash == other.contentHash;

  @override
  int get hashCode => Object.hash(schemaVersion, contentHash);

  @override
  String toString() =>
      'PresetFingerprint(schema=$schemaVersion, hash=$contentHash)';
}
