import 'dart:async';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_colors.dart';
import 'package:consumable_tracker_desktop/widgets/app_select.dart';
import 'package:consumable_tracker_desktop/widgets/bambu_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('拓竹选择器可展开并更新选中项', (tester) async {
    var value = 'PLA';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: StatefulBuilder(
                builder: (context, setState) => AppSelect<String>(
                  value: value,
                  label: '材质',
                  items: const [
                    DropdownMenuItem(value: 'PLA', child: Text('PLA')),
                    DropdownMenuItem(value: 'PETG', child: Text('PETG')),
                    DropdownMenuItem(value: 'ABS', child: Text('ABS')),
                  ],
                  onChanged: (next) => setState(() => value = next ?? value),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(AppSelect<String>));
    await tester.pumpAndSettle();
    expect(find.text('PETG'), findsOneWidget);

    await tester.tap(find.text('PETG'));
    await tester.pumpAndSettle();
    expect(value, 'PETG');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击选择器外部后取消焦点高光', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 100),
              SizedBox(
                width: 280,
                child: AppSelect<String>(
                  value: 'PLA',
                  label: '材质',
                  items: const [
                    DropdownMenuItem(value: 'PLA', child: Text('PLA')),
                    DropdownMenuItem(value: 'PETG', child: Text('PETG')),
                  ],
                  onChanged: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(AppSelect<String>));
    await tester.pumpAndSettle();
    expect(_selectBorderColor(tester), AppColors.primary);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(_selectBorderColor(tester), isNot(AppColors.primary));
  });

  testWidgets('可空筛选器会展示并选择实际选项', (tester) async {
    String? value;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 220,
              child: AppSelect<String?>(
                value: value,
                items: const [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text('全部材料'),
                  ),
                  DropdownMenuItem<String?>(
                    value: 'PLA',
                    child: Text('PLA'),
                  ),
                  DropdownMenuItem<String?>(
                    value: 'PETG',
                    child: Text('PETG'),
                  ),
                ],
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(AppSelect<String?>));
    await tester.pumpAndSettle();
    expect(find.text('PETG'), findsOneWidget);
    await tester.tap(find.text('PETG'));
    await tester.pumpAndSettle();
    expect(value, 'PETG');
  });

  testWidgets('参数分类拓竹 SVG 均可加载', (tester) async {
    const icons = [
      'param_strength',
      'param_support',
      'param_flow',
      'param_retraction',
      'param_plate',
      'param_nozzle',
      'param_mechanical',
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              for (final icon in icons) BambuIcon(name: icon, size: 18),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择器会等待打开前刷新完成再展示菜单', (tester) async {
    final refresh = Completer<void>();
    var refreshCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              child: AppSelect<String>(
                value: 'a',
                items: const [
                  DropdownMenuItem(value: 'a', child: Text('预设 A')),
                  DropdownMenuItem(value: 'b', child: Text('预设 B')),
                ],
                onOpen: () async {
                  refreshCount++;
                  await refresh.future;
                },
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(AppSelect<String>));
    await tester.pump();
    expect(refreshCount, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    refresh.complete();
    await tester.pumpAndSettle();
    expect(find.text('预设 B'), findsOneWidget);
  });
}

Color _selectBorderColor(WidgetTester tester) {
  final animated = tester.widgetList<AnimatedContainer>(
    find.descendant(
      of: find.byType(AppSelect<String>),
      matching: find.byType(AnimatedContainer),
    ),
  );
  final decoration = animated
      .map((widget) => widget.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((decoration) => decoration.border != null);
  return (decoration.border! as Border).top.color;
}
