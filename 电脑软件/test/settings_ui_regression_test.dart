import 'package:consumable_tracker_desktop/features/settings/settings_sheet.dart';
import 'package:consumable_tracker_desktop/ui/aurora_settings_page.dart';
import 'package:consumable_tracker_desktop/widgets/bambu_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('设置导航按工作流分组并保留清晰图标', (tester) async {
    await _openSettings(tester, const Size(1024, 720));

    expect(find.byIcon(Icons.shield_outlined), findsOneWidget);

    final infoIcons =
        tester.widgetList<BambuIcon>(find.byType(BambuIcon)).where(
              (icon) => icon.name == 'info',
            );
    expect(infoIcons, hasLength(1));

    final spoolIcon =
        tester.widgetList<BambuIcon>(find.byType(BambuIcon)).singleWhere(
              (icon) => icon.name == 'spool',
            );
    expect(spoolIcon.size, 16);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关于与更新页在窄窗口保持检查更新和初始化操作可用', (tester) async {
    await _openSettings(tester, const Size(520, 520));

    await tester.ensureVisible(find.text('关于与更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于与更新'));
    await tester.pumpAndSettle();

    expect(find.text('sohun'), findsNWidgets(2));
    expect(find.text('应用名称'), findsOneWidget);
    expect(find.text('作者'), findsOneWidget);
    expect(find.text('生腌焦糖'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('新版本提醒'), findsOneWidget);
    expect(find.text('自动提醒可选更新；必要更新仍会提示。'), findsOneWidget);
    expect(find.text('重新初始化'), findsOneWidget);
    expect(find.text('重新运行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('外观设置区提供背景装饰与交互动效开关', (tester) async {
    await _openSettings(tester, const Size(1024, 720));

    expect(find.text('背景装饰'), findsOneWidget);
    expect(find.text('交互动效'), findsOneWidget);
    expect(find.text('卡片悬浮、按钮回弹与页面过渡'), findsOneWidget);
  });

  testWidgets('设置页直接展示完整分类而无需二次打开弹窗', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: AuroraSettingsPage())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('打开完整设置'), findsNothing);
    expect(find.text('账号、设备与工作流统一管理'), findsOneWidget);
    expect(find.text('外观与体验'), findsOneWidget);
    expect(find.text('设备与连接'), findsOneWidget);
    expect(find.text('自动化'), findsOneWidget);
    expect(find.text('数据与隐私'), findsOneWidget);
  });

  testWidgets('账号页不再暴露本地作者或服务器地址配置', (tester) async {
    await _openSettings(tester, const Size(1024, 720));

    await tester.tap(find.text('sohun 账号').first);
    await tester.pumpAndSettle();

    expect(find.text('本地作者档案'), findsNothing);
    expect(find.textContaining('配置账号服务器'), findsNothing);
    expect(find.textContaining('服务器地址'), findsNothing);
    expect(find.text('服务准备中'), findsNothing);
    expect(find.textContaining('当前构建暂未接入'), findsNothing);
    expect(find.text('sohun 云'), findsOneWidget);
    expect(find.text('个人账号登录'), findsOneWidget);
    expect(find.text('农场成员登录'), findsOneWidget);
    expect(find.text('个人注册'), findsOneWidget);
    expect(find.text('开通农场管理员账号'), findsOneWidget);
  });
}

Future<void> _openSettings(WidgetTester tester, Size surfaceSize) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => SettingsSheet.show(context),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('打开设置'));
  await tester.pumpAndSettle();
}
