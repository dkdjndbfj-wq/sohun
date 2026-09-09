import 'dart:ui' show PointerDeviceKind;

import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/data/prefs/app_prefs.dart';
import 'package:consumable_tracker_desktop/widgets/glass_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('交互动效默认开启并可持久化关闭', () async {
    expect(await AppPrefs.getInteractionEffectsEnabled(), isTrue);
    await AppPrefs.setInteractionEffectsEnabled(false);
    expect(await AppPrefs.getInteractionEffectsEnabled(), isFalse);
  });

  testWidgets('可点击玻璃卡开启动效时悬浮上移三像素', (tester) async {
    await _pumpCard(tester, effectsEnabled: true);
    await _hoverCard(tester);

    final container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(GlassCard),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(container.transform?.storage[13], -3);
    expect(container.duration, isNot(Duration.zero));
  });

  testWidgets('关闭动效后卡片不位移且过渡时长为零', (tester) async {
    await _pumpCard(tester, effectsEnabled: false);
    await _hoverCard(tester);

    final container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(GlassCard),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(container.transform?.storage[13], 0);
    expect(container.duration, Duration.zero);
    final regions = tester.widgetList<MouseRegion>(
      find.descendant(
        of: find.byType(GlassCard),
        matching: find.byType(MouseRegion),
      ),
    );
    expect(
      regions.any((region) => region.cursor == SystemMouseCursors.click),
      isTrue,
    );
  });
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required bool effectsEnabled,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => InteractionEffectsScope(
        enabled: effectsEnabled,
        child: child!,
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 220,
            height: 120,
            child: GlassCard(onTap: () {}, child: const Text('card')),
          ),
        ),
      ),
    ),
  );
}

Future<void> _hoverCard(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await gesture.moveTo(tester.getCenter(find.byType(GlassCard)));
  await tester.pump(const Duration(milliseconds: 250));
  await gesture.removePointer();
}
