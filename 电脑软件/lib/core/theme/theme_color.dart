import 'package:flutter/material.dart';

/// P1 修复：主题色定义。
///
/// 原设置页"主题色"下拉为空实现。现提供 4 种内置主题色供用户选择，
/// 切换后通过 [ThemeColorNotifier] 持久化并通知整棵树重新构建 ThemeData。
///
/// 每个主题色包含 seed(用于 ColorScheme.fromSeed 生成完整调色板)和
/// accent(渐变副色)。AppColors.primary 等运行时字段会被更新为当前选中的色值。
class ThemeColorDef {
  /// Stable identifier used by persisted resources and themed artwork.
  ///
  /// Keep this independent from [name], which is user-facing and may be
  /// localized later.
  final String assetKey;
  final String name;
  final Color seed;
  final Color accent;

  const ThemeColorDef({
    required this.assetKey,
    required this.name,
    required this.seed,
    required this.accent,
  });

  static const auroraGreen = ThemeColorDef(
    assetKey: 'aurora_green',
    name: '极光绿',
    seed: Color(0xFF00B42A),
    accent: Color(0xFF00A884),
  );

  static const oceanBlue = ThemeColorDef(
    assetKey: 'ocean_blue',
    name: '海洋蓝',
    seed: Color(0xFF2E7BE6),
    accent: Color(0xFF06B6D4),
  );

  static const sakuraPink = ThemeColorDef(
    assetKey: 'sakura_pink',
    name: '樱花粉',
    seed: Color(0xFFEC4899),
    accent: Color(0xFFF472B6),
  );

  static const sunsetOrange = ThemeColorDef(
    assetKey: 'sunset_orange',
    name: '日落橙',
    seed: Color(0xFFF97316),
    accent: Color(0xFFFBBF24),
  );

  static const all = [auroraGreen, oceanBlue, sakuraPink, sunsetOrange];

  static ThemeColorDef byName(String name) =>
      all.firstWhere((c) => c.name == name, orElse: () => auroraGreen);
}
