import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/features/support/embedded_support_shop.dart';
import 'package:consumable_tracker_desktop/features/support/support_screen.dart';
import 'package:consumable_tracker_desktop/widgets/sohun_wordmark.dart';

void main() {
  Widget buildSubject() {
    return MaterialApp(
      theme: AppTheme.light(),
      home: const InteractionEffectsScope(
        enabled: false,
        child: Scaffold(body: SupportScreen()),
      ),
    );
  }

  testWidgets('支持页提供支持商城、卡密绑定和共创致谢墙', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pump();

    expect(find.byType(SohunWordmark), findsOneWidget);
    expect(find.text('一起把 Sohun 做得更好'), findsOneWidget);
    expect(find.text('绑定支持卡密'), findsOneWidget);
    expect(find.text('支持卡密'), findsOneWidget);
    expect(find.text('共创致谢'), findsOneWidget);
    expect(find.text('Salcara 中转站'), findsOneWidget);
    expect(find.text('访问 Salcara'), findsOneWidget);
    expect(find.text('打开支持商城'), findsNothing);
    expect(find.text('还没有卡密？去支持商城'), findsNothing);
    expect(find.byType(SupportShopEmbed), findsOneWidget);
    expect(find.byType(AspectRatio), findsNothing);
  });

  testWidgets('支持页在窄窗口改为纵向布局且不溢出', (tester) async {
    tester.view.physicalSize = const Size(700, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('一起把 Sohun 做得更好'), findsOneWidget);
    expect(find.text('绑定支持卡密'), findsOneWidget);
    expect(find.text('共创致谢'), findsOneWidget);
    expect(find.text('Salcara 中转站'), findsOneWidget);
    expect(find.byType(SupportShopEmbed), findsOneWidget);
  });
}
