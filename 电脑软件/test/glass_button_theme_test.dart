import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/glass_button_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/core/theme/personal_desktop_theme.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_visual_theme.dart';
import 'package:consumable_tracker_desktop/widgets/app_button.dart';
import 'package:consumable_tracker_desktop/widgets/app_glass_button.dart';
import 'package:consumable_tracker_desktop/widgets/glass_button_material.dart';
import 'package:consumable_tracker_desktop/widgets/icon_action_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final dark in [false, true]) {
    for (final mobile in [false, true]) {
      testWidgets('所有标准按钮和旧组件共用玻璃并保留操作 dark=$dark mobile=$mobile', (
        tester,
      ) async {
        final base = dark ? AppTheme.dark() : AppTheme.light();
        final theme = mobile
            ? buildMobileTheme(base)
            : buildPersonalDesktopTheme(
                base,
                personalProduct: true,
                studioMode: false,
              );
        var actions = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: InteractionEffectsScope(
              enabled: false,
              child: Scaffold(
                body: Builder(
                  builder: (context) => Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: 220,
                        child: FilledButton(
                          key: const ValueKey('primary'),
                          onPressed: () => actions++,
                          child: const Text('提交'),
                        ),
                      ),
                      OutlinedButton(
                        key: const ValueKey('secondary'),
                        onPressed: () {},
                        child: const Text('取消'),
                      ),
                      TextButton(
                        key: const ValueKey('quiet'),
                        onPressed: () {},
                        child: const Text('了解更多'),
                      ),
                      ElevatedButton(
                        key: const ValueKey('elevated'),
                        onPressed: () {},
                        child: const Text('保存'),
                      ),
                      IconButton(
                        key: const ValueKey('icon'),
                        onPressed: () {},
                        icon: const Icon(Icons.refresh),
                        tooltip: '刷新',
                      ),
                      FilledButton(
                        key: const ValueKey('danger'),
                        onPressed: () {},
                        style: glassButtonStyle(
                          context,
                          FilledButton.styleFrom(
                            backgroundColor: Colors.red,
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                        child: const Text('删除'),
                      ),
                      const FilledButton(
                        key: ValueKey('disabled'),
                        onPressed: null,
                        child: Text('忙碌中'),
                      ),
                      AppButton(
                        key: const ValueKey('legacy'),
                        label: '新增耗材',
                        onPressed: () {},
                      ),
                      const AppGlassButton(
                        key: ValueKey('explicit'),
                        label: '检查更新',
                        onPressed: null,
                      ),
                      DeleteActionButton(
                        key: const ValueKey('delete-icon'),
                        onTap: () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final key in [
          'primary',
          'secondary',
          'quiet',
          'elevated',
          'icon',
          'danger',
          'disabled',
          'legacy',
          'explicit',
          'delete-icon',
        ]) {
          final button = find.byKey(ValueKey(key));
          expect(
            find.descendant(
              of: button,
              matching: find.byType(GlassButtonMaterial),
            ),
            findsOneWidget,
            reason: key,
          );
          expect(
            find.descendant(of: button, matching: find.byType(BackdropFilter)),
            findsOneWidget,
            reason: 'one clipped blur per control: $key',
          );
        }
        final primaryMaterial = tester.widget<Material>(
          find
              .descendant(
                of: find.byKey(const ValueKey('primary')),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(primaryMaterial.color?.a, 0);
        final dangerMaterial = tester.widget<Material>(
          find
              .descendant(
                of: find.byKey(const ValueKey('danger')),
                matching: find.byType(Material),
              )
              .first,
        );
        final dangerInk = dangerMaterial.textStyle!.color!;
        expect(dangerInk.r, greaterThan(dangerInk.g));
        expect(dangerInk.r, greaterThan(dangerInk.b));
        final rect = tester.getRect(find.byKey(const ValueKey('primary')));
        await tester.tapAt(Offset(rect.right - 8, rect.center.dy));
        await tester.pumpAndSettle();
        Focus.of(tester.element(find.text('提交'))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(actions, 2);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('disabled')))
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('商业与未启用主题的按钮保持原样', (tester) async {
    final original = AppTheme.light();
    final farm = buildPersonalDesktopTheme(
      original,
      personalProduct: false,
      studioMode: true,
    );
    expect(identical(original, farm), isTrue);
    expect(farm.extension<GlassButtonsTheme>(), isNull);
    const originalStyle = ButtonStyle(
      backgroundColor: WidgetStatePropertyAll(Colors.red),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: farm,
        home: Builder(
          builder: (context) {
            expect(
              identical(
                glassButtonStyle(context, originalStyle),
                originalStyle,
              ),
              isTrue,
            );
            return Scaffold(
              body: Column(
                children: [
                  FilledButton(onPressed: () {}, child: const Text('商业按钮')),
                  AppButton(label: '原按钮', onPressed: () {}),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GlassButtonMaterial), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分段选中状态保留且关闭动画无位移', (tester) async {
    var selected = 1;
    final theme = buildMobileTheme(AppTheme.light());
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: InteractionEffectsScope(
          enabled: false,
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => GlassSegmentedSurface(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('按品牌')),
                    ButtonSegment(value: 2, label: Text('全部卷')),
                  ],
                  selected: {selected},
                  onSelectionChanged: (values) =>
                      setState(() => selected = values.first),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部卷'));
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(find.byType(GlassButtonMaterial), findsOneWidget);
    final selectedMaterial = tester.widget<Material>(
      find
          .ancestor(of: find.text('全部卷'), matching: find.byType(Material))
          .first,
    );
    expect(selectedMaterial.color!.a, greaterThan(0));
    final otherMaterial = tester.widget<Material>(
      find
          .ancestor(of: find.text('按品牌'), matching: find.byType(Material))
          .first,
    );
    expect(otherMaterial.color!.a, 0);
    for (final animated in tester.widgetList<AnimatedScale>(
      find.byType(AnimatedScale),
    )) {
      expect(animated.duration, Duration.zero);
      expect(animated.scale, 1);
    }
    expect(tester.takeException(), isNull);
  });
}
