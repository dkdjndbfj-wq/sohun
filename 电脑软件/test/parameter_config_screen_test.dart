import 'package:consumable_tracker_desktop/features/parameters/parameter_config_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('参数编辑器在桌面与最小窗口下可完整渲染', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: ParameterConfigScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text('新建参数预设'), findsOneWidget);
    expect(find.text('工艺系统预设'), findsOneWidget);
    expect(find.text('预设信息'), findsOneWidget);
    expect(find.text('质量'), findsWidgets);
    expect(find.text('保存为预设'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(1100, 700));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
