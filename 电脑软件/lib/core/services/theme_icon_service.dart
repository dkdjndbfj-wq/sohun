import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/theme_brand_assets.dart';
import '../theme/theme_color.dart';

/// Keeps the Windows window/taskbar icon and tray icon on the same theme asset.
class ThemeIconService {
  ThemeIconService({
    Future<void> Function(String asset)? setWindowIcon,
    Future<void> Function(String asset)? setTrayIcon,
    bool? supportsWindowIcon,
  })  : _setWindowIcon = setWindowIcon ?? _defaultSetWindowIcon,
        _setTrayIcon = setTrayIcon ?? _defaultSetTrayIcon,
        _supportsWindowIcon = supportsWindowIcon ?? Platform.isWindows;

  final Future<void> Function(String asset) _setWindowIcon;
  final Future<void> Function(String asset) _setTrayIcon;
  final bool _supportsWindowIcon;
  String? _currentIconAsset;

  static Future<void> _defaultSetWindowIcon(String asset) {
    return windowManager.setIcon(asset);
  }

  static Future<void> _defaultSetTrayIcon(String asset) {
    return trayManager.setIcon(asset);
  }

  String get currentIconAsset =>
      _currentIconAsset ?? ThemeBrandAssets.fallbackIco;

  Future<void> apply({
    required ThemeColorDef color,
    required Brightness brightness,
    bool force = false,
  }) async {
    // 图标始终使用亮色系列；深色主题只改变承载背景，不把默认品牌图标
    // 替换成黑底版本。
    final iconBrightness =
        brightness == Brightness.dark ? Brightness.light : brightness;
    final asset = ThemeBrandAssets.ico(color, iconBrightness);
    if (!force && asset == _currentIconAsset) return;

    if (_supportsWindowIcon) {
      await _setWindowIcon(asset);
    }
    await _setTrayIcon(asset);
    _currentIconAsset = asset;
  }

  Future<void> restoreTrayIcon() => _setTrayIcon(currentIconAsset);
}

final themeIconServiceProvider = Provider<ThemeIconService>((ref) {
  return ThemeIconService();
});
