import 'package:flutter/material.dart';

import 'theme_color.dart';

/// Resolves the generated sohun artwork for a theme color and brightness.
abstract final class ThemeBrandAssets {
  static const _root = 'assets/images/branding/themes';
  static const fallbackPng =
      'assets/images/branding/themes/sohun_aurora_green_light.png';
  static const fallbackIco =
      'assets/images/branding/themes/sohun_aurora_green_light.ico';

  static String png(ThemeColorDef color, Brightness brightness) {
    return '$_root/sohun_${color.assetKey}_${_mode(brightness)}.png';
  }

  static String ico(ThemeColorDef color, Brightness brightness) {
    return '$_root/sohun_${color.assetKey}_${_mode(brightness)}.ico';
  }

  static String _mode(Brightness brightness) =>
      brightness == Brightness.dark ? 'dark' : 'light';
}
