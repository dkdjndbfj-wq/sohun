import 'dart:async';
import 'dart:io';

import 'package:consumable_tracker_desktop/core/startup/startup_bootstrap_app.dart';
import 'package:consumable_tracker_desktop/core/startup/startup_coordinator.dart';
import 'package:consumable_tracker_desktop/core/startup/startup_handoff.dart';
import 'package:consumable_tracker_desktop/core/startup/startup_window_controller.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/prefs/app_prefs.dart';
import 'package:consumable_tracker_desktop/providers/batch_recognition_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_queue_provider.dart';
import 'package:consumable_tracker_desktop/widgets/sohun_wordmark.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('初始化完成前仅显示启动品牌、阶段说明和真实进度', (tester) async {
    final completer = Completer<StartupResult>();
    late StartupProgressCallback report;
    await tester.pumpWidget(
      ProviderScope(
        child: StartupBootstrapApp(
          startupTask: (callback) {
            report = callback;
            return completer.future;
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('sohun-wordmark')), findsOneWidget);
    expect(find.byKey(const ValueKey('startup-progress-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('application')), findsNothing);
    var semantics = tester.widget<Semantics>(
      find.byKey(const ValueKey('startup-progress-semantics')),
    );
    expect(semantics.properties.label, '正在启动 sohun…');

    report(
      const StartupProgress(
        phase: StartupPhase.migrating,
        value: 0.68,
        label: '正在校验并升级数据…',
      ),
    );
    await tester.pump();
    semantics = tester.widget<Semantics>(
      find.byKey(const ValueKey('startup-progress-semantics')),
    );
    expect(semantics.properties.label, '正在校验并升级数据…');
    final indicator = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('startup-progress-bar')),
    );
    expect(indicator.value, 0.68);
  });

  testWidgets('启动失败停留在错误面板而不进入应用', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: StartupBootstrapApp(
          startupTask: (_) async => throw const StartupFailure(
            title: '无法安全升级数据',
            message: '测试备份失败',
          ),
          appBuilder: (_) => const Text('ready'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('无法安全升级数据'), findsOneWidget);
    expect(find.text('测试备份失败'), findsOneWidget);
    expect(find.text('ready'), findsNothing);
  });

  testWidgets('主应用不会出现在启动窗背后，并在退场完成后才挂载', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          interactionEffectsEnabledProvider.overrideWith((ref) {
            return InteractionEffectsEnabledNotifier(
              initialValue: true,
              loadPersisted: false,
            );
          }),
        ],
        child: StartupBootstrapApp(
          startupTask: (_) async => StartupResult(database),
          appBuilder: (_) => const MaterialApp(home: Text('ready')),
          prepareMainWindow: _noWindowTransition,
          showMainWindow: _noWindowTransition,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    expect(find.byKey(const ValueKey('application')), findsOneWidget);
    expect(find.byKey(const ValueKey('startup')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 899));
    expect(find.byKey(const ValueKey('startup')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    await tester.pump();

    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
    expect(find.byKey(const ValueKey('startup')), findsNothing);
  });

  testWidgets('关闭动效后不增加人工启动等待', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          interactionEffectsEnabledProvider.overrideWith((ref) {
            return InteractionEffectsEnabledNotifier(
              initialValue: false,
              loadPersisted: false,
            );
          }),
        ],
        child: StartupBootstrapApp(
          startupTask: (_) async => StartupResult(database),
          appBuilder: (_) => const MaterialApp(home: Text('ready')),
          prepareMainWindow: _noWindowTransition,
          showMainWindow: _noWindowTransition,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ready'), findsOneWidget);
  });

  testWidgets('启动完成后数据库依赖保持在根 ProviderScope', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: StartupBootstrapApp(
          minimumSplashDuration: Duration.zero,
          startupTask: (_) async => StartupResult(database),
          prepareMainWindow: _noWindowTransition,
          showMainWindow: _noWindowTransition,
          appBuilder: (_) => Consumer(
            builder: (context, ref, child) {
              ref.watch(printQueueStateMachineProvider);
              ref.watch(batchRecognitionProvider);
              return const MaterialApp(home: Text('ready-with-services'));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ready-with-services'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sohun 按 s、o、h、u、n 顺序逐字显现', (tester) async {
    Future<SohunWordmarkPainter> pumpWordmark(double progress) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 308,
              height: 100,
              child: SohunWordmark(progress: progress),
            ),
          ),
        ),
      );
      final customPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const ValueKey('sohun-wordmark')),
          matching: find.byType(CustomPaint),
        ),
      );
      return customPaint.painter! as SohunWordmarkPainter;
    }

    expect((await pumpWordmark(0.1)).revealedLetterCount, 1);
    expect((await pumpWordmark(0.36)).revealedLetterCount, 3);
    expect((await pumpWordmark(1)).revealedLetterCount, 5);
  });

  testWidgets('动画艺术字标使用同一主题渐变且不依赖运行时字体', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SohunWordmark(
          startColor: Color(0xFF00A86B),
          endColor: Color(0xFF42D392),
        ),
      ),
    );
    final painter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byKey(const ValueKey('sohun-wordmark')),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter! as SohunWordmarkPainter;
    expect(painter.startColor, const Color(0xFF00A86B));
    expect(painter.endColor, const Color(0xFF42D392));

    final wordmarkSource =
        File('lib/widgets/sohun_wordmark.dart').readAsStringSync();
    expect(wordmarkSource, contains('List<Path> _letterPaths()'));
    expect(wordmarkSource, contains('StrokeCap.round'));
    expect(wordmarkSource, isNot(contains('TextPainter')));
  });

  testWidgets('工作台字标上报真实落点并在交接末段接管', (tester) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = StartupHandoffController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      StartupHandoffScope(
        controller: controller,
        child: const MaterialApp(
          home: Stack(
            children: [
              Positioned(
                left: 90,
                top: 70,
                width: 132,
                height: 43,
                child: StartupLandingTarget(child: SohunWordmark(glow: true)),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      controller.landingRect,
      const Rect.fromLTWH(90, 70, 132, 43),
    );
    var opacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('startup-landing-target-opacity')),
    );
    expect(opacity.opacity, 0);

    controller.updateProgress(0.93);
    await tester.pump();
    opacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('startup-landing-target-opacity')),
    );
    expect(opacity.opacity, greaterThan(0));
    expect(opacity.opacity, lessThan(1));

    controller.complete();
    await tester.pump();
    opacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('startup-landing-target-opacity')),
    );
    expect(opacity.opacity, 1);
  });

  test('字标归位与窗口展开在同一个进度终点完成', () {
    const startBounds = Rect.fromLTWH(700, 394, 520, 292);
    const targetBounds = Rect.fromLTWH(240, 90, 1440, 900);
    const heroWordmarkBounds = Rect.fromLTWH(746, 650, 132, 43);

    expect(
      StartupWindowController.boundsForProgress(startBounds, targetBounds, 0),
      startBounds,
    );
    expect(
      StartupWindowController.boundsForProgress(startBounds, targetBounds, 1),
      targetBounds,
    );
    expect(
      StartupRevealGeometry.logoRectForProgress(
        0,
        targetRect: heroWordmarkBounds,
      ),
      StartupRevealGeometry.startLogoRect,
    );
    expect(
      StartupRevealGeometry.logoRectForProgress(
        1,
        targetRect: heroWordmarkBounds,
      ),
      heroWordmarkBounds,
    );
    expect(
      StartupRevealGeometry.logoRectForProgress(
        1,
        targetRect: heroWordmarkBounds,
      ),
      isNot(const Rect.fromLTWH(42, 9, 58, 20)),
    );

    expect(
      StartupWindowController.revealSizeForProgress(
        StartupWindowController.splashSize,
        StartupWindowController.mainSize,
        0,
      ),
      StartupWindowController.splashSize,
    );
    expect(
      StartupWindowController.revealSizeForProgress(
        StartupWindowController.splashSize,
        StartupWindowController.mainSize,
        1,
      ),
      StartupWindowController.mainSize,
    );

    final anchored = StartupWindowController.boundsForProgress(
      startBounds,
      targetBounds,
      StartupWindowController.positionAnchorFraction,
    );
    expect(anchored.topLeft, targetBounds.topLeft);
    expect(anchored.size.width, lessThan(targetBounds.size.width));
  });

  test('原生首帧和 Dart 启动窗使用相同的小尺寸', () {
    expect(StartupWindowController.splashSize, const Size(520, 292));
    expect(
      StartupWindowController.splashSize.width,
      lessThan(StartupWindowController.mainMinimumSize.width),
    );

    final nativeEntry = File('windows/runner/main.cpp').readAsStringSync();
    final dartEntry = File('lib/main.dart').readAsStringSync();
    expect(nativeEntry, contains('Win32Window::Size size(520, 292)'));
    expect(
      dartEntry,
      contains('StartupWindowController.prepareSplashWindow('),
    );
    expect(dartEntry, contains('windowManager.waitUntilReadyToShow()'));
  });

  test('Windows 启动展开使用原生裁剪而不是逐帧重排完整界面', () {
    final controller = File('lib/core/startup/startup_window_controller.dart')
        .readAsStringSync();
    final runner = File('windows/runner/flutter_window.cpp').readAsStringSync();
    final bootstrap =
        File('lib/core/startup/startup_bootstrap_app.dart').readAsStringSync();

    expect(controller, contains('consumable_tracker/startup_window'));
    expect(controller, contains("'prepareReveal'"));
    expect(controller, contains("'startReveal'"));
    expect(runner, contains('SetWindowRgn'));
    expect(runner, contains('SetWindowRgn(window, region, FALSE)'));
    expect(runner, contains('SWP_NOREDRAW'));
    expect(runner, contains('kStartupRevealTimerId'));
    expect(bootstrap, contains("ValueKey('startup-native-backing')"));
    expect(bootstrap, contains('startupHandoff?.landingRect'));
    expect(bootstrap, isNot(contains('targetLogoRect')));
  });
}

Future<void> _noWindowTransition() async {}
