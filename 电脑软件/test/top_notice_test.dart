import 'package:consumable_tracker_desktop/widgets/confirm_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('通知显示在顶部并保持紧凑宽度', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showSnack(
                  context,
                  '耗材信息已保存',
                  duration: const Duration(seconds: 10),
                ),
                child: const Text('显示提示'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示提示'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    final notice = find.byKey(const ValueKey('app-top-notice'));
    expect(notice, findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    final rect = tester.getRect(notice);
    expect(rect.top, greaterThanOrEqualTo(54));
    expect(rect.bottom, lessThan(150));
    expect(rect.width, lessThanOrEqualTo(440));
    expect(rect.width, lessThan(500));
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶部通知支持操作按钮并替换上一条消息', (tester) async {
    var actionCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                FilledButton(
                  onPressed: () => showSnack(
                    context,
                    '第一条消息',
                    duration: const Duration(seconds: 10),
                  ),
                  child: const Text('第一条'),
                ),
                FilledButton(
                  onPressed: () => showSnack(
                    context,
                    '账号登录已失效',
                    error: true,
                    duration: const Duration(seconds: 10),
                    actionLabel: '重新登录',
                    onAction: () => actionCount++,
                  ),
                  child: const Text('第二条'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('第一条'));
    await tester.pump();
    await tester.tap(find.text('第二条'));
    await tester.pump(const Duration(milliseconds: 240));

    expect(find.text('第一条消息'), findsNothing);
    expect(find.text('账号登录已失效'), findsOneWidget);
    expect(find.text('重新登录'), findsOneWidget);

    await tester.tap(find.text('重新登录'));
    await tester.pump(const Duration(milliseconds: 180));
    expect(actionCount, 1);
    expect(find.byKey(const ValueKey('app-top-notice')), findsNothing);
  });
}
