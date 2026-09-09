import 'dart:io';

import 'package:consumable_tracker_desktop/core/theme/theme_brand_assets.dart';
import 'package:consumable_tracker_desktop/core/theme/theme_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('四种主题色的浅色和深色 PNG/ICO 素材都存在', () {
    for (final color in ThemeColorDef.all) {
      expect(color.assetKey, isNotEmpty);
      for (final brightness in Brightness.values) {
        final png = ThemeBrandAssets.png(color, brightness);
        final ico = ThemeBrandAssets.ico(color, brightness);
        expect(File(png).existsSync(), isTrue, reason: 'missing $png');
        expect(File(ico).existsSync(), isTrue, reason: 'missing $ico');
        expect(png, contains(color.assetKey));
      }
    }
  });

  test('主题素材解析不依赖中文展示名', () {
    expect(
      ThemeBrandAssets.png(ThemeColorDef.sakuraPink, Brightness.dark),
      endsWith('sohun_sakura_pink_dark.png'),
    );
    expect(
      ThemeBrandAssets.ico(ThemeColorDef.oceanBlue, Brightness.light),
      endsWith('sohun_ocean_blue_light.ico'),
    );
  });
}
