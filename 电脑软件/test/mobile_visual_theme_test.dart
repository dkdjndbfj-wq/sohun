import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_visual_theme.dart';
import 'package:consumable_tracker_desktop/widgets/glass_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('手机保留桌面字号、字重、行高与字距，并使用真实字体回退列表', () {
    for (final desktop in [AppTheme.light(), AppTheme.dark()]) {
      final mobile = buildMobileTheme(desktop);
      final source = _styles(desktop.textTheme);
      final target = _styles(mobile.textTheme);
      for (var i = 0; i < source.length; i++) {
        expect(target[i]?.fontSize, source[i]?.fontSize);
        expect(target[i]?.fontWeight, source[i]?.fontWeight);
        expect(target[i]?.height, source[i]?.height);
        expect(target[i]?.letterSpacing, source[i]?.letterSpacing);
        expect(target[i]?.fontFamily, 'HarmonyOS Sans');
        expect(target[i]?.fontFamilyFallback, contains('Microsoft YaHei UI'));
        expect(target[i]?.fontFamily?.contains(','), isFalse);
      }
      expect(
        mobile.appBarTheme.titleTextStyle?.fontSize,
        desktop.appBarTheme.titleTextStyle?.fontSize,
      );
      expect(
        mobile.appBarTheme.titleTextStyle?.fontWeight,
        desktop.appBarTheme.titleTextStyle?.fontWeight,
      );
    }
  });

  test('浅色玻璃背景下，小号选中标签与错误文字保持可读对比度', () {
    final theme = buildMobileTheme(AppTheme.light());
    final tintedCanvas = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.13),
      mobileCanvasColor(Brightness.light),
    );
    final selected = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.12),
      tintedCanvas,
    );
    expect(
      _contrast(mobileAccentTextColor(theme), selected),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(theme.colorScheme.error, tintedCanvas),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('居中玻璃弹窗复用桌面卡片与模糊，可滚动且关闭后返回原页面', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMobileTheme(AppTheme.light()),
        home: MobileScaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showMobileGlassDialog<void>(
                  context: context,
                  builder: (_) => SizedBox(
                    height: 360,
                    child: ListView(
                      children: [
                        for (var i = 0; i < 30; i++)
                          ListTile(title: Text('条目 $i')),
                      ],
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsWidgets);
    expect(find.byType(GlassCard), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    final surface = tester.getRect(find.byType(GlassCard));
    expect(surface.center, const Offset(400, 300));
    expect(surface.width, lessThanOrEqualTo(560));
    await tester.drag(find.byType(ListView), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(find.text('条目 15').hitTestable(), findsOneWidget);
    Navigator.of(tester.element(find.byType(ListView))).pop();
    await tester.pumpAndSettle();
    expect(find.text('打开').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小屏键盘和两倍字号下居中弹窗可滚动到确认操作', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMobileGlassDialog<void>(
                context: context,
                builder: (context) => SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Text('编辑耗材资料'),
                      for (var i = 0; i < 8; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: TextField(
                            decoration: InputDecoration(labelText: '资料 $i'),
                          ),
                        ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('确认保存'),
                      ),
                    ],
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final surface = tester.getRect(find.byType(GlassCard));
    expect(surface.left, greaterThanOrEqualTo(16));
    expect(surface.right, lessThanOrEqualTo(304));
    expect(surface.bottom, lessThanOrEqualTo(376));
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('确认保存'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

List<TextStyle?> _styles(TextTheme theme) => [
  theme.displayLarge,
  theme.displayMedium,
  theme.displaySmall,
  theme.headlineLarge,
  theme.headlineMedium,
  theme.headlineSmall,
  theme.titleLarge,
  theme.titleMedium,
  theme.titleSmall,
  theme.bodyLarge,
  theme.bodyMedium,
  theme.bodySmall,
  theme.labelLarge,
  theme.labelMedium,
  theme.labelSmall,
];

double _contrast(Color a, Color b) {
  final first = a.computeLuminance(), second = b.computeLuminance();
  return (first > second ? first + 0.05 : second + 0.05) /
      (first > second ? second + 0.05 : first + 0.05);
}
