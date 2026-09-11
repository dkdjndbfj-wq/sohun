import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:consumable_tracker_desktop/core/startup/startup_bootstrap_app.dart';
import 'package:consumable_tracker_desktop/core/startup/startup_coordinator.dart';
import 'package:consumable_tracker_desktop/core/startup/startup_window_controller.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/prefs/app_prefs.dart';
import 'package:consumable_tracker_desktop/providers/batch_recognition_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/onboarding_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_queue_provider.dart';
import 'package:consumable_tracker_desktop/providers/theme_provider.dart';
import 'package:consumable_tracker_desktop/widgets/sohun_wordmark.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _captureDirectory = String.fromEnvironment('STARTUP_SCREENSHOT_DIR');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_captureDirectory.isEmpty) return;
    final windowsDirectory = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final font = File('$windowsDirectory/Fonts/msyh.ttc');
    if (!await font.exists()) {
      throw StateError(
        'Startup capture requires the installed Windows Chinese font',
      );
    }
    final data = ByteData.sublistView(await font.readAsBytes());
    for (final family in [AppTypography.chineseFontFamily, 'Roboto']) {
      final loader = FontLoader(family)..addFont(Future.value(data));
      await loader.load();
    }
  });
  final windowCalls = <MethodCall>[];
  final nativeRevealCalls = <MethodCall>[];
  const windowChannel = MethodChannel('window_manager');
  const revealChannel = MethodChannel('consumable_tracker/startup_window');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    windowCalls.clear();
    nativeRevealCalls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call);
      if (call.method.startsWith('is') || call.method == 'hasShadow') {
        return false;
      }
      if (call.method == 'getBounds') {
        return <String, double>{'x': 0, 'y': 0, 'width': 1440, 'height': 900};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(revealChannel, (call) async {
      nativeRevealCalls.add(call);
      return null;
    });
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, null);
    messenger.setMockMethodCallHandler(revealChannel, null);
  });

  testWidgets('初始化完成前只显示启动品牌、阶段说明和真实进度', (tester) async {
    final completer = Completer<StartupResult>();
    late StartupProgressCallback report;
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(),
        child: StartupBootstrapApp(
          startupTask: (callback) {
            report = callback;
            return completer.future;
          },
        ),
      ),
    );
    try {
      await tester.pump();
      expect(find.byKey(const ValueKey('startup-brand')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('startup-progress-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('application')), findsNothing);
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const ValueKey('startup-progress-semantics')),
            )
            .properties
            .label,
        '正在启动 sohun…',
      );
      report(
        const StartupProgress(
          phase: StartupPhase.migrating,
          value: 0.68,
          label: '正在校验并升级数据…',
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const ValueKey('startup-progress-semantics')),
            )
            .properties
            .label,
        '正在校验并升级数据…',
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('startup-progress-bar')),
            )
            .value,
        0.68,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('startup-progress-bar')),
            )
            .value,
        0.68,
        reason: '进度不能随动画时间伪造增长',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('启动失败停留在错误面板，不创建或进入主应用', (tester) async {
    var appCreations = 0;
    var shows = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(),
        child: StartupBootstrapApp(
          startupTask: (_) async =>
              throw const StartupFailure(title: '无法安全升级数据', message: '测试备份失败'),
          appBuilder: (_) {
            appCreations++;
            return const Text('ready');
          },
          prepareMainWindow: _noWindowTransition,
          showMainWindow: () async {
            shows++;
          },
        ),
      ),
    );
    try {
      await tester.pumpAndSettle();
      expect(find.text('无法安全升级数据'), findsOneWidget);
      expect(find.text('测试备份失败'), findsOneWidget);
      expect(find.text('ready'), findsNothing);
      expect(appCreations, 0);
      expect(shows, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('初始化快时立即开始180ms交接，不等待品牌动画，主应用仅创建一次', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final result = Completer<StartupResult>();
    var appCreations = 0;
    var appMounts = 0;
    var prepares = 0;
    var shows = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(),
        child: StartupBootstrapApp(
          startupTask: (_) => result.future,
          appBuilder: (_) {
            appCreations++;
            return _MountCounter(onMount: () => appMounts++);
          },
          prepareMainWindow: () async {
            prepares++;
          },
          showMainWindow: () async {
            shows++;
          },
        ),
      ),
    );
    try {
      final completedAt = tester.binding.clock.now();
      result.complete(StartupResult(database));
      await _pumpMicroFrames(tester);
      expect(tester.binding.clock.now(), completedAt);
      expect(prepares, 1, reason: '不能等待280ms品牌淡入或旧900ms最短停留');
      expect(shows, 0);
      expect(appCreations, 1);
      expect(appMounts, 1);
      expect(find.byKey(const ValueKey('application')), findsOneWidget);
      expect(find.byKey(const ValueKey('startup')), findsOneWidget);
      expect(_applicationIgnoresInput(tester), isTrue);
      await tester.pump(const Duration(milliseconds: 179));
      expect(find.byKey(const ValueKey('startup')), findsOneWidget);
      // Flutter completes an interpolation on the first frame strictly after
      // its duration. A zero-time pump at exactly 180ms cannot complete it.
      await tester.pump(const Duration(milliseconds: 2));
      await _pumpMicroFrames(tester);
      expect(find.byKey(const ValueKey('startup')), findsNothing);
      expect(_applicationIgnoresInput(tester), isFalse);
      expect(shows, 1);
      expect(appCreations, 1);
      expect(appMounts, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(database.close);
    }
  });

  for (final systemReducedMotion in [false, true]) {
    testWidgets('${systemReducedMotion ? '系统减少动画' : '软件关闭动效'}后不增加启动等待', (
      tester,
    ) async {
      if (systemReducedMotion) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
      }
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      var shows = 0;
      final startedAt = tester.binding.clock.now();
      await tester.pumpWidget(
        ProviderScope(
          overrides: _overrides(effects: systemReducedMotion),
          child: StartupBootstrapApp(
            minimumSplashDuration: const Duration(seconds: 5),
            startupTask: (_) async => StartupResult(database),
            appBuilder: (_) => const MaterialApp(home: Text('ready')),
            prepareMainWindow: _noWindowTransition,
            showMainWindow: () async {
              shows++;
            },
          ),
        ),
      );
      try {
        await _pumpMicroFrames(tester);
        expect(tester.binding.clock.now(), startedAt);
        expect(shows, 1);
        expect(find.byKey(const ValueKey('startup')), findsNothing);
        expect(find.text('ready'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(database.close);
      }
    });
  }

  testWidgets('启动交接完成后主应用服务仍使用根ProviderScope的同一数据库', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final observedDatabases = <AppDatabase>[];
    final root = ProviderContainer(
      overrides: [
        ..._overrides(effects: false),
        databaseProvider.overrideWithValue(database),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: root,
        child: StartupBootstrapApp(
          startupTask: (_) async => StartupResult(database),
          prepareMainWindow: _noWindowTransition,
          showMainWindow: _noWindowTransition,
          appBuilder: (_) => Consumer(
            builder: (context, ref, child) {
              observedDatabases.add(ref.watch(databaseProvider));
              ref.watch(printQueueStateMachineProvider);
              ref.watch(batchRecognitionProvider);
              return const MaterialApp(home: Text('ready-with-services'));
            },
          ),
        ),
      ),
    );
    try {
      await tester.pumpAndSettle();
      expect(find.text('ready-with-services'), findsOneWidget);
      expect(observedDatabases, isNotEmpty);
      expect(observedDatabases.every((db) => identical(db, database)), isTrue);
      expect(identical(root.read(databaseProvider), database), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      root.dispose();
      await tester.runAsync(database.close);
    }
  });

  test('原生首帧与Dart启动和主窗口均固定1440x900', () {
    expect(StartupWindowController.mainSize, const Size(1440, 900));
    expect(
      StartupWindowController.splashSize,
      StartupWindowController.mainSize,
    );
    final nativeEntry = File('windows/runner/main.cpp').readAsStringSync();
    expect(nativeEntry, contains('Win32Window::Size size(1440, 900)'));
    final dartEntry = File('lib/main.dart').readAsStringSync();
    expect(dartEntry, contains('StartupWindowController.prepareSplashWindow('));
  });

  testWidgets('交接动画逐帧不会请求原生裁剪或窗口尺寸变化', (tester) async {
    for (var frame = 0; frame <= 120; frame++) {
      StartupWindowController.updateMainWindowTransition(frame / 120);
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(windowCalls, isEmpty);
    expect(nativeRevealCalls, isEmpty);
    await StartupWindowController.finishMainWindowTransition();
    expect(windowCalls.map((call) => call.method), contains('show'));
    expect(
      windowCalls.map((call) => call.method),
      isNot(contains('setBounds')),
    );
    expect(nativeRevealCalls, isEmpty);
  });

  testWidgets('独立SohunWordmark仍按s、o、h、u、n逐字显现', (tester) async {
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

  testWidgets('独立艺术字组件保留主题渐变且不依赖运行时字体', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SohunWordmark(
          startColor: Color(0xFF00A86B),
          endColor: Color(0xFF42D392),
        ),
      ),
    );
    final painter =
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byKey(const ValueKey('sohun-wordmark')),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as SohunWordmarkPainter;
    expect(painter.startColor, const Color(0xFF00A86B));
    expect(painter.endColor, const Color(0xFF42D392));
    final wordmarkSource = File(
      'lib/widgets/sohun_wordmark.dart',
    ).readAsStringSync();
    expect(wordmarkSource, contains('List<Path> _letterPaths()'));
    expect(wordmarkSource, isNot(contains('TextPainter')));
  });

  if (_captureDirectory.isNotEmpty) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('capture actual startup ${mode.name}', (tester) async {
        await tester.binding.setSurfaceSize(StartupWindowController.mainSize);
        final captureKey = GlobalKey();
        final waiting = Completer<StartupResult>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: _overrides(effects: false, themeMode: mode),
            child: RepaintBoundary(
              key: captureKey,
              child: StartupBootstrapApp(
                startupTask: (report) {
                  report(
                    const StartupProgress(
                      phase: StartupPhase.migrating,
                      value: 0.68,
                      label: '正在校验并升级数据…',
                    ),
                  );
                  return waiting.future;
                },
              ),
            ),
          ),
        );
        try {
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          await tester.pump();
          final boundary =
              captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            // Rasterization and PNG encoding use real engine work; executing
            // either inside FakeAsync can stall without advancing a frame.
            final image = await boundary
                .toImage(pixelRatio: 1)
                .timeout(const Duration(seconds: 10));
            try {
              final bytes = await image
                  .toByteData(format: ui.ImageByteFormat.png)
                  .timeout(const Duration(seconds: 10));
              expect(bytes, isNotNull);
              final directory = Directory(_captureDirectory);
              await directory.create(recursive: true);
              await File(
                '${directory.path}/startup-${mode.name}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.binding.setSurfaceSize(null);
        }
      });
    }
  }
}

List<Override> _overrides({
  bool effects = true,
  ThemeMode themeMode = ThemeMode.light,
}) => [
  interactionEffectsEnabledProvider.overrideWith(
    (ref) => InteractionEffectsEnabledNotifier(
      initialValue: effects,
      loadPersisted: false,
    ),
  ),
  onboardingCompletedProvider.overrideWith((ref) async => true),
  themeModeProvider.overrideWith(
    (ref) => ThemeModeNotifier(initialMode: themeMode, loadPersisted: false),
  ),
  themeColorProvider.overrideWith(
    (ref) => ThemeColorNotifier(loadPersisted: false),
  ),
];

Future<void> _pumpMicroFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump();
  }
}

bool _applicationIgnoresInput(WidgetTester tester) => tester
    .widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('application')),
            matching: find.byType(IgnorePointer),
          )
          .first,
    )
    .ignoring;

class _MountCounter extends StatefulWidget {
  const _MountCounter({required this.onMount});
  final VoidCallback onMount;
  @override
  State<_MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<_MountCounter> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const MaterialApp(home: Text('ready'));
}

Future<void> _noWindowTransition() async {}
