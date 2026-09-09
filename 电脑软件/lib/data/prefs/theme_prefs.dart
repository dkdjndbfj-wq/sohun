import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式持久化。
///
/// 保存用户选择的主题模式（跟随系统 / 浅色 / 深色），重启后恢复。
/// 默认跟随系统（ThemeMode.system）。
class ThemePrefs {
  ThemePrefs._();

  static const _key = 'theme_mode';
  static const _colorKey = 'theme_color_name';

  /// 读取持久化的主题模式。未设置时返回 [ThemeMode.system]。
  static Future<ThemeMode> getMode() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    switch (v) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }

  /// 写入主题模式。
  static Future<void> setMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }

  /// 读取持久化的主题色名称。未设置时返回 '极光绿'（默认）。
  static Future<String> getColorName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_colorKey) ?? '极光绿';
  }

  /// 写入主题色名称。
  static Future<void> setColorName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_colorKey, name);
  }
}
