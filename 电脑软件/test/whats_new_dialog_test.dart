import 'package:consumable_tracker_desktop/core/releases/app_release_notes.dart';
import 'package:consumable_tracker_desktop/data/prefs/release_notes_prefs.dart';
import 'package:consumable_tracker_desktop/features/updates/whats_new_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('每个版本只自动显示一次更新内容', () async {
    const version = 'v9.9.9+9';
    expect(await ReleaseNotesPrefs.shouldShow(version), isTrue);
    await ReleaseNotesPrefs.markSeen(version);
    expect(await ReleaseNotesPrefs.shouldShow(version), isFalse);
    expect(await ReleaseNotesPrefs.shouldShow('v10.0.0+1'), isTrue);
  });

  testWidgets('本次更新弹层在窄窗口完整展示并可关闭', (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => WhatsNewDialog.show(context),
                  child: const Text('显示更新'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示更新'));
    await tester.pumpAndSettle();

    expect(find.text(AppReleaseNotes.current.title), findsOneWidget);
    expect(find.text('CUID/FUID 可重复入库'), findsOneWidget);
    expect(find.text('个人库存严格隔离'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();
    expect(find.text(AppReleaseNotes.current.title), findsNothing);
  });
}
