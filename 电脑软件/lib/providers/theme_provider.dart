import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/theme_color.dart';
import '../data/prefs/theme_prefs.dart';

/// 主题模式 Notifier。
///
/// 启动时从 [ThemePrefs] 加载持久化值，切换时写回。
/// 由 [MaterialApp.themeMode] 监听，切换后整棵树立即重-build 切换亮/暗主题。
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier({
    ThemeMode initialMode = ThemeMode.system,
    bool loadPersisted = true,
  }) : super(initialMode) {
    if (loadPersisted) _load();
  }

  Future<void> _load() async {
    final mode = await ThemePrefs.getMode();
    if (mounted) state = mode;
  }

  Future<void> setMode(ThemeMode mode) async {
    await ThemePrefs.setMode(mode);
    state = mode;
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});

/// 主题色 Notifier（P1 修复：原设置页主题色下拉为空实现，现真正生效）。
///
/// 启动时从 [ThemePrefs] 加载持久化的主题色名称，切换时：
/// 1. 写回持久化
/// 2. 更新 [AppColors] 的运行时主色字段（primary / accent / primaryContainer 等）
/// 3. 通知 state 变化，[MaterialApp] 重新构建 ThemeData
///
/// AppColors 中 primary 等改为非 const 的 static 字段，启动时由本 notifier 赋值。
/// 默认极光绿。切换后所有引用 AppColors.primary 的自定义组件立即变色，
/// 同时 ColorScheme.fromSeed 会让所有 Material 组件跟随。
class ThemeColorNotifier extends StateNotifier<ThemeColorDef> {
  ThemeColorNotifier({
    ThemeColorDef initialColor = ThemeColorDef.auroraGreen,
    bool loadPersisted = true,
  }) : super(initialColor) {
    _apply(initialColor);
    if (loadPersisted) _load();
  }

  Future<void> _load() async {
    final name = await ThemePrefs.getColorName();
    final def = ThemeColorDef.byName(name);
    _apply(def);
    if (mounted) state = def;
  }

  Future<void> setColor(ThemeColorDef def) async {
    _apply(def);
    state = def;
    await ThemePrefs.setColorName(def.name);
  }

  /// 把选中的主题色应用到 AppColors 运行时字段。
  /// primaryContainer / primary50~900 由 seed 派生（用 ColorScheme.fromSeed
  /// 的同款算法简化：这里直接用 seed 的不同透明度近似）。
  void _apply(ThemeColorDef def) {
    AppColors.applyTheme(def.seed, def.accent);
  }
}

final themeColorProvider =
    StateNotifierProvider<ThemeColorNotifier, ThemeColorDef>((ref) {
  return ThemeColorNotifier();
});
