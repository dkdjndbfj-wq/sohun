import 'dart:io';

import 'package:consumable_tracker_desktop/core/app_identity.dart';
import 'package:consumable_tracker_desktop/core/app_variant.dart';
import 'package:consumable_tracker_desktop/widgets/app_brand_icon.dart';
import 'package:consumable_tracker_desktop/widgets/custom_title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('用户可见品牌与构建产品一致', () {
    expect(AppIdentity.name, AppVariant.isFarm ? 'sohun 农场' : 'sohun');
    expect(AppIdentity.author, '生腌焦糖');
    expect(AppIdentity.iconAsset, 'assets/images/sohun.png');
    expect(
      AppIdentity.trayIconAsset,
      'assets/images/branding/themes/sohun_aurora_green_light.ico',
    );

    final cmake = File('windows/CMakeLists.txt').readAsStringSync();
    final runnerResources = File('windows/runner/Runner.rc').readAsStringSync();
    final nativeEntry = File('windows/runner/main.cpp').readAsStringSync();
    final releaseScript = File('build_release.ps1').readAsStringSync();
    final titleBar =
        File('lib/widgets/custom_title_bar.dart').readAsStringSync();
    final workspaceShell = File('lib/ui/aurora_shell.dart').readAsStringSync();

    expect(cmake, contains('set(BINARY_NAME "sohun")'));
    expect(cmake, contains('set(BINARY_NAME "sohun-farm")'));
    expect(runnerResources, contains('#define SOHUN_PRODUCT_NAME "sohun"'));
    expect(
      runnerResources,
      contains('#define SOHUN_PRODUCT_NAME "sohun Farm"'),
    );
    expect(runnerResources, contains('VALUE "CompanyName", "生腌焦糖"'));
    expect(runnerResources,
        contains('#define SOHUN_ORIGINAL_FILENAME "sohun.exe"'));
    expect(
      runnerResources,
      contains('#define SOHUN_ORIGINAL_FILENAME "sohun-farm.exe"'),
    );
    expect(nativeEntry, contains('L"sohun 农场"'));
    expect(nativeEntry, contains('Local\\\\sohun-desktop-'));
    expect(nativeEntry, contains('Local\\\\sohun-farm-desktop-'));
    expect(releaseScript, contains('"sohun.exe"'));
    expect(releaseScript, contains('dist\\sohun-windows-x64'));
    expect(titleBar, contains('const AppBrandIcon(size: 18, radius: 4)'));
    expect(titleBar, isNot(contains('SohunTitleWordmark')));
    expect(titleBar, isNot(contains('SohunWordmark')));
    expect(workspaceShell, isNot(contains('SohunWordmark')));
  });

  testWidgets('窗口标题栏只显示品牌图标，不显示 sohun 字标', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: CustomTitleBar()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AppBrandIcon), findsOneWidget);
    expect(find.text('sohun'), findsNothing);
  });
}
