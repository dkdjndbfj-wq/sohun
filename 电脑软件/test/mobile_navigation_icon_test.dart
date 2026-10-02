import 'dart:io';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_navigation_icon.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('八枚导航 SVG 均能从正式资产清单解码并在浅深主题渲染', (tester) async {
    await _preloadNavigationAssets(tester);
    for (final brightness in Brightness.values) {
      final theme = buildMobileTheme(
        brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Wrap(
              children: [
                for (final symbol in MobileNavigationSymbol.values)
                  for (final selected in [false, true])
                    MobileNavigationIcon(symbol, selected: selected),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SvgPicture), findsNWidgets(8));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('导航图标继承图标颜色与透明度，保留 26px 光学尺寸且不重复播报', (tester) async {
    const color = Color(0xCC37A991);
    await _preloadNavigationAssets(tester);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: IconTheme(
            data: IconThemeData(color: color, opacity: .5, size: 22),
            child: MobileNavigationIcon(
              MobileNavigationSymbol.inventory,
              selected: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final picture = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(picture.width, 26);
    expect(picture.height, 26);
    expect(
      picture.colorFilter,
      ColorFilter.mode(color.withValues(alpha: color.a * .5), BlendMode.srcIn),
    );
    expect(picture.excludeFromSemantics, isTrue);
    expect(picture.semanticsLabel, isNull);
    expect(tester.getSize(find.byType(SvgPicture)), const Size(26, 26));
    expect(tester.takeException(), isNull);
  });

  // Optional visual QA. Ordinary tests need neither a host font nor goldens.
  // flutter test --update-goldens --dart-define=CAPTURE_MOBILE_NAV=true
  //   test/mobile_navigation_icon_test.dart
  for (final brightness in Brightness.values) {
    testWidgets(
      '渲染定制导航图标 ${brightness.name}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(720, 420));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _loadPreviewFont(tester);
        await _preloadNavigationAssets(tester);
        await tester.pumpWidget(_NavigationPreview(brightness: brightness));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            '../build/mobile-ui/navigation-${brightness.name}.png',
          ),
        );
      },
      skip: !const bool.fromEnvironment('CAPTURE_MOBILE_NAV'),
    );
  }
}

Future<void> _preloadNavigationAssets(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final symbol in MobileNavigationSymbol.values) {
      for (final selected in [false, true]) {
        final icon = MobileNavigationIcon(symbol, selected: selected);
        final picture = await vg.loadPicture(
          SvgAssetLoader(icon.assetPath),
          null,
        );
        expect(picture.size, const Size(32, 32));
        picture.picture.dispose();
      }
    }
  });
}

Future<void> _loadPreviewFont(WidgetTester tester) async {
  await tester.runAsync(() async {
    const path = String.fromEnvironment(
      'MOBILE_UI_FONT',
      defaultValue: r'C:\Windows\Fonts\msyh.ttc',
    );
    final bytes = ByteData.sublistView(await File(path).readAsBytes());
    for (final family in [
      AppTypography.chineseFontFamily,
      'HarmonyOS Sans',
      'Microsoft YaHei UI',
      'Roboto',
      'Ahem',
    ]) {
      await (FontLoader(family)..addFont(Future.value(bytes))).load();
    }
  });
}

const _labels = ['标签读写', '耗材库存', '打印提醒', '我的'];

class _NavigationPreview extends StatelessWidget {
  const _NavigationPreview({required this.brightness});
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final theme = buildMobileTheme(
      brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: MobileScaffold(
        body: Padding(
          padding: const EdgeInsets.fromLTRB(36, 28, 36, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'SOHUN / MOBILE NAVIGATION',
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 2,
                  color: mobileAccentTextColor(theme),
                ),
              ),
              const SizedBox(height: 8),
              Text('少一点装饰，多一点留白', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                '标签感应 · 耗材库存 · 打印提醒 · 个人空间',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 22),
              _PreviewRow(theme: theme, selected: false),
              const Spacer(),
              Text('实际使用 · 26px / 选中耗材库存', style: theme.textTheme.labelMedium),
              const SizedBox(height: 12),
              MobileGlassSurface(
                radius: 22,
                opacity: .64,
                elevated: true,
                child: NavigationBar(
                  height: 64,
                  selectedIndex: 1,
                  destinations: const [
                    NavigationDestination(
                      icon: MobileNavigationIcon(MobileNavigationSymbol.tags),
                      selectedIcon: MobileNavigationIcon(
                        MobileNavigationSymbol.tags,
                        selected: true,
                      ),
                      label: '标签读写',
                    ),
                    NavigationDestination(
                      icon: MobileNavigationIcon(
                        MobileNavigationSymbol.inventory,
                      ),
                      selectedIcon: MobileNavigationIcon(
                        MobileNavigationSymbol.inventory,
                        selected: true,
                      ),
                      label: '耗材库存',
                    ),
                    NavigationDestination(
                      icon: MobileNavigationIcon(
                        MobileNavigationSymbol.printAlerts,
                      ),
                      selectedIcon: MobileNavigationIcon(
                        MobileNavigationSymbol.printAlerts,
                        selected: true,
                      ),
                      label: '打印提醒',
                    ),
                    NavigationDestination(
                      icon: MobileNavigationIcon(
                        MobileNavigationSymbol.account,
                      ),
                      selectedIcon: MobileNavigationIcon(
                        MobileNavigationSymbol.account,
                        selected: true,
                      ),
                      label: '我的',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.theme, required this.selected});
  final ThemeData theme;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '统一细线 · 不叠加外框与徽记',
          style: theme.textTheme.labelMedium,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (var i = 0; i < MobileNavigationSymbol.values.length; i++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: i == 3 ? 0 : 12),
                  child: Container(
                    height: 126,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconTheme(
                          data: IconThemeData(color: color),
                          child: MobileNavigationIcon(
                            MobileNavigationSymbol.values[i],
                            selected: selected,
                            size: 64,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(_labels[i], style: theme.textTheme.labelMedium),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
