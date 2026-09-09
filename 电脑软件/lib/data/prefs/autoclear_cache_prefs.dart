// G-code 自动清件检测缓存。
//
// 按 gcode 文件 basename 缓存启发式扫描结果，避免重复扫描大文件。
// 缓存结构：Map<filename, _CachedEntry>
//   - filename: gcode 文件 basename（如 "支架_v3.gcode"）
//   - entry.score: 启发式评分
//   - entry.hasAutoClear: 自动检测结果
//   - entry.manualOverride: 用户手动覆盖值（true=含/false=不含/null=未覆盖）
//   - entry.detectedAt: 检测时间戳（毫秒）
//
// 最终判定优先级（见 [AutoclearCachePrefs.getFinalFlag]）：
//   手动覆盖 > 自动检测
//
// 绑定到文件粒度：同文件名不同路径视为同一文件（用户已选文件粒度方案）。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 单个文件的自动清件检测结果缓存项。
class AutoclearCacheEntry {
  /// 启发式评分（自动检测的原始分数）
  final int score;

  /// 自动检测结果
  final bool hasAutoClear;

  /// 命中的特征列表
  final List<String> matchedFeatures;

  /// 用户手动覆盖值。
  /// - true：用户标记为「含自动清件」
  /// - false：用户标记为「不含自动清件」
  /// - null：未手动覆盖，用自动检测结果
  final bool? manualOverride;

  /// 检测时间戳（毫秒）
  final int detectedAt;

  const AutoclearCacheEntry({
    required this.score,
    required this.hasAutoClear,
    required this.matchedFeatures,
    required this.manualOverride,
    required this.detectedAt,
  });

  /// 最终判定的 hasAutoClear 值（手动覆盖优先）
  bool get finalFlag => manualOverride ?? hasAutoClear;

  /// 是否已手动覆盖
  bool get hasManualOverride => manualOverride != null;

  Map<String, dynamic> toJson() => {
        'score': score,
        'hasAutoClear': hasAutoClear,
        'features': matchedFeatures,
        'override': manualOverride,
        'ts': detectedAt,
      };

  factory AutoclearCacheEntry.fromJson(Map<String, dynamic> json) {
    return AutoclearCacheEntry(
      score: (json['score'] as num?)?.toInt() ?? 0,
      hasAutoClear: json['hasAutoClear'] as bool? ?? false,
      matchedFeatures: (json['features'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      manualOverride: json['override'] as bool?,
      detectedAt: (json['ts'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// G-code 自动清件检测缓存持久化。
class AutoclearCachePrefs {
  AutoclearCachePrefs._();

  static const _key = 'autoclear_cache_v1';

  /// 加载所有缓存条目。
  static Future<Map<String, AutoclearCacheEntry>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map(
        (k, v) => MapEntry(
          k,
          AutoclearCacheEntry.fromJson(v as Map<String, dynamic>),
        ),
      );
    } catch (_) {
      return {};
    }
  }

  /// 获取单个文件的缓存条目。不存在返回 null。
  static Future<AutoclearCacheEntry?> get(String filename) async {
    final all = await loadAll();
    return all[filename];
  }

  /// 获取最终的 hasAutoClear 判定值。
  /// 缓存不存在返回 null（表示尚未检测）。
  static Future<bool?> getFinalFlag(String filename) async {
    final entry = await get(filename);
    return entry?.finalFlag;
  }

  /// 写入或更新缓存条目（自动检测结果）。
  /// 保留已有的 manualOverride 字段（不覆盖用户的手动标记）。
  static Future<void> setDetection({
    required String filename,
    required int score,
    required bool hasAutoClear,
    required List<String> matchedFeatures,
  }) async {
    final all = await loadAll();
    final existing = all[filename];
    all[filename] = AutoclearCacheEntry(
      score: score,
      hasAutoClear: hasAutoClear,
      matchedFeatures: matchedFeatures,
      // 保留用户已有的手动覆盖
      manualOverride: existing?.manualOverride,
      detectedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _save(all);
  }

  /// 设置手动覆盖值。
  /// [value] 传 null 清除覆盖（回退到自动检测结果）。
  static Future<void> setManualOverride(
    String filename,
    bool? value,
  ) async {
    final all = await loadAll();
    final existing = all[filename];
    if (existing == null) {
      // 文件尚未自动检测过，仅记手动覆盖
      all[filename] = AutoclearCacheEntry(
        score: 0,
        hasAutoClear: value ?? false,
        matchedFeatures: const [],
        manualOverride: value,
        detectedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } else {
      all[filename] = AutoclearCacheEntry(
        score: existing.score,
        hasAutoClear: existing.hasAutoClear,
        matchedFeatures: existing.matchedFeatures,
        manualOverride: value,
        detectedAt: existing.detectedAt,
      );
    }
    await _save(all);
  }

  /// 删除单个文件的缓存。
  static Future<void> remove(String filename) async {
    final all = await loadAll();
    if (all.remove(filename) == null) return;
    await _save(all);
  }

  /// 清空所有缓存。
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<void> _save(Map<String, AutoclearCacheEntry> all) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(
      all.map((k, v) => MapEntry(k, v.toJson())),
    );
    await prefs.setString(_key, json);
  }
}
