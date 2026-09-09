import 'dart:io';
import 'dart:ui' as ui;

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/data/prefs/app_prefs.dart';
import 'package:consumable_tracker_desktop/data/prefs/onboarding_prefs.dart';
import 'package:consumable_tracker_desktop/providers/onboarding_provider.dart';
import 'package:consumable_tracker_desktop/features/onboarding/onboarding_wizard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const capture = bool.fromEnvironment('ONBOARDING_CAPTURE');
  setUpAll(() async {
    // 可选的本机视觉验收；普通测试不依赖 Windows 字体。
    if (capture) {
      for (final family in [
        AppTypography.chineseFontFamily,
        AppTypography.monoFontFamily,
        'Roboto',
        'Ahem',
      ]) {
        final loader = FontLoader(family);
        loader.addFont(File('C:/Windows/Fonts/msyh.ttc')
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)),);
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('首次设置在桌面宽度显示步骤轨道并可前后切换', (tester) async {
    await _pumpOnboarding(tester, const Size(1180, 760));

    expect(
      find.byKey(const ValueKey('onboarding-step-rail')),
      findsOneWidget,
    );
    expect(find.text('欢迎使用 sohun'), findsOneWidget);
    expect(find.text('耗材工作台'), findsNothing);
    expect(find.text('开始设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) await _capture(tester, 'welcome-light');

    await tester.tap(find.text('开始设置'));
    await tester.pumpAndSettle();

    expect(find.text('登录拓竹账号'), findsWidgets);
    expect(find.text('上一步'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();

    expect(find.text('欢迎使用 sohun'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首次设置在窄窗口收起步骤轨道且操作栏保持可用', (tester) async {
    await _pumpOnboarding(tester, const Size(620, 680));

    expect(
      find.byKey(const ValueKey('onboarding-step-rail')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('onboarding-progress-header')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('onboarding-bottom-bar')),
      findsOneWidget,
    );
    expect(find.text('sohun'), findsOneWidget);
    expect(find.text('开始设置'), findsOneWidget);
    expect(find.text('稍后设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) await _capture(tester, 'welcome-compact');
  });

  testWidgets('视图选择持久化，返回欢迎页仍保持选择', (tester) async {
    await _pumpOnboarding(tester, const Size(1180, 820));
    expect(await AppPrefs.getInventoryFineDetailEnabled(), isFalse);
    await tester.tap(find.byKey(const ValueKey('inventory-fine-choice')));
    await tester.pumpAndSettle();
    expect(await AppPrefs.getInventoryFineDetailEnabled(), isTrue);
    await tester.tap(find.text('开始设置'));
    await tester.pumpAndSettle();
    expect(find.text('跳过此步'), findsOneWidget);
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(OnboardingWizard)),
    );
    expect(container.read(inventoryFineDetailProvider), isTrue);
    await tester.tap(find.byKey(const ValueKey('inventory-simple-choice')));
    await tester.pumpAndSettle();
    expect(await AppPrefs.getInventoryFineDetailEnabled(), isFalse);
  });

  testWidgets('稍后设置可退出引导并保留视图偏好', (tester) async {
    await _pumpOnboarding(tester, const Size(1180, 820));
    await tester.tap(find.byKey(const ValueKey('inventory-fine-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('稍后设置'));
    await tester.pumpAndSettle();
    expect(await OnboardingPrefs.isCompleted(), isTrue);
    expect(await AppPrefs.getInventoryFineDetailEnabled(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('完成摘要准确区分未配置项目并能返回修改', (tester) async {
    await _pumpOnboarding(tester, const Size(1180, 820), dark: true);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(OnboardingWizard)),
    );
    final notifier = container.read(onboardingProvider.notifier);
    for (var i = 0; i < 6; i++) {
      notifier.next();
    }
    await tester.pumpAndSettle();
    expect(find.text('暂未连接'), findsOneWidget);
    expect(find.text('暂未添加'), findsOneWidget);
    expect(find.text('上一步'), findsOneWidget);
    expect(find.text('进入 sohun'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (capture) await _capture(tester, 'complete-dark');
    await tester.tap(find.text('库存视图'));
    await tester.pumpAndSettle();
    expect(find.text('欢迎使用 sohun'), findsOneWidget);
  });

  testWidgets('小窗口及放大字体下操作栏无溢出且可继续', (tester) async {
    await _pumpOnboarding(
      tester,
      const Size(380, 640),
      dark: true,
      textScale: 1.5,
    );
    expect(tester.takeException(), isNull);
    if (capture) await _capture(tester, 'welcome-small-dark');
    await tester.tap(find.text('开始设置'));
    await tester.pumpAndSettle();
    expect(find.text('跳过此步'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(find.text('欢迎使用 sohun'), findsOneWidget);
  });

  testWidgets('中途退出调用保存，保存失败留在引导并提示', (tester) async {
    late _RecordingOnboardingNotifier notifier;
    await tester.binding.setSurfaceSize(const Size(1180, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [onboardingProvider.overrideWith((ref) {
        notifier = _RecordingOnboardingNotifier(ref)..next();
        return notifier;
      }),],
      child: MaterialApp(theme: AppTheme.light(), home: const OnboardingWizard()),
    ),);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并退出'));
    await tester.pumpAndSettle();
    expect(notifier.saveCalls, 1);
    expect(notifier.skipCalls, 0);
    expect(find.text('设置未能保存，请重试。'), findsOneWidget);
    expect(find.text('跳过此步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _RecordingOnboardingNotifier extends OnboardingNotifier {
  _RecordingOnboardingNotifier(super.ref);
  int saveCalls = 0;
  int skipCalls = 0;

  @override
  Future<void> complete() async {
    saveCalls++;
    throw StateError('test save failure');
  }

  @override
  Future<void> skipAll() async { skipCalls++; }
}

Future<void> _pumpOnboarding(
  WidgetTester tester,
  Size surfaceSize, {
  bool dark = false,
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const RepaintBoundary(
          key: ValueKey('onboarding-capture'),
          child: OnboardingWizard(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  final context = tester.element(find.byType(OnboardingWizard));
  final assets = tester.widgetList<Image>(find.byType(Image)).toList();
  await tester.runAsync(() async {
    for (final asset in assets) {
      await precacheImage(asset.image, context);
    }
  });
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('onboarding-capture')),
  );
  await tester.runAsync(() async {
    final snapshot = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await snapshot.toByteData(format: ui.ImageByteFormat.png);
    final output = File('build/onboarding-review/$name.png');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
    snapshot.dispose();
  });
}
