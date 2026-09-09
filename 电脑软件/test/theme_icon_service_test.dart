import 'package:consumable_tracker_desktop/core/services/theme_icon_service.dart';
import 'package:consumable_tracker_desktop/core/theme/theme_brand_assets.dart';
import 'package:consumable_tracker_desktop/core/theme/theme_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('窗口和托盘始终使用亮色品牌图并去重重复请求', () async {
    final windowAssets = <String>[];
    final trayAssets = <String>[];
    final service = ThemeIconService(
      supportsWindowIcon: true,
      setWindowIcon: (asset) async => windowAssets.add(asset),
      setTrayIcon: (asset) async => trayAssets.add(asset),
    );

    await service.apply(
      color: ThemeColorDef.oceanBlue,
      brightness: Brightness.dark,
    );
    await service.apply(
      color: ThemeColorDef.oceanBlue,
      brightness: Brightness.dark,
    );

    final expected =
        ThemeBrandAssets.ico(ThemeColorDef.oceanBlue, Brightness.light);
    expect(windowAssets, [expected]);
    expect(trayAssets, [expected]);
    expect(service.currentIconAsset, expected);
  });

  test('通知清除时恢复最后一次成功应用的托盘图标', () async {
    final trayAssets = <String>[];
    final service = ThemeIconService(
      supportsWindowIcon: false,
      setTrayIcon: (asset) async => trayAssets.add(asset),
    );

    await service.apply(
      color: ThemeColorDef.sunsetOrange,
      brightness: Brightness.light,
    );
    await service.restoreTrayIcon();

    final expected =
        ThemeBrandAssets.ico(ThemeColorDef.sunsetOrange, Brightness.light);
    expect(trayAssets, [expected, expected]);
  });
}
