import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/core/theme/personal_desktop_theme.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/features/dashboard/material_playground_hero.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/bambu_account_manager.dart';
import 'package:consumable_tracker_desktop/providers/bambu_cloud_provider.dart';
import 'package:consumable_tracker_desktop/providers/batch_recognition_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_queue_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:consumable_tracker_desktop/providers/slicer_provider.dart';
import 'package:consumable_tracker_desktop/ui/aurora_design.dart';
import 'package:consumable_tracker_desktop/ui/aurora_shell.dart';
import 'package:consumable_tracker_desktop/widgets/app_input.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const desktopWalkthroughSize = Size(1600, 1000);
const _captureKey = ValueKey('desktop-usage-walkthrough');
const _output = String.fromEnvironment(
  'SOHUN_DESKTOP_GUIDE_OUTPUT',
  defaultValue: '../output/sohun-desktop-guide-20261115/frames',
);

/// Finds the editable control, whether its label is in InputDecoration or in
/// the app's labelled AppInput wrapper. It never substitutes a visual control.
Finder walkthroughField(String label) {
  final decorated = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );
  if (decorated.evaluate().isNotEmpty) return decorated;
  return find.descendant(
    of: find.byWidgetPredicate(
      (widget) => widget is AppInput && widget.label == label,
    ),
    matching: find.byType(TextField),
  );
}

/// Real desktop widgets with an isolated, writable in-memory database. The
/// frame sequence records actual mouse actions and actual local form results.
/// No production database, cloud account, printer or slicer is attached.
class DesktopWalkthrough {
  DesktopWalkthrough._(this.tester, this.db, this.directory)
    : _previousShadows = debugDisableShadows;

  final WidgetTester tester;
  final AppDatabase db;
  final Directory directory;
  final bool _previousShadows;
  final _pointer = ValueNotifier(const _PointerState(Offset(1330, 870)));
  final frames = <Map<String, Object>>[];
  final actions = <Map<String, Object>>[];
  final keyFrames = <Map<String, Object>>[];
  final preludeControls = <String>[];
  late TestGesture _mouse;
  late ProviderContainer container;
  int elapsedMs = 0;
  bool _mousePresent = false;
  bool _disposed = false;

  static Future<DesktopWalkthrough> mount(
    WidgetTester tester, {
    required String segment,
    Future<void> Function(AppDatabase db)? seed,
    List<Override> overrides = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final guide = DesktopWalkthrough._(
      tester,
      db,
      Directory('$_output/$segment'),
    );
    try {
      debugDisableShadows = false;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = desktopWalkthroughSize;
      await tester.binding.setSurfaceSize(desktopWalkthroughSize);
      await _loadFonts(tester);
      await tester.runAsync(() async {
        // Open and migrate the database before the first watched query.
        await db.customSelect('SELECT 1').get();
        if (seed != null) await seed(db);
        await guide.directory.create(recursive: true);
      });
      Aurora.applyTheme(primaryColor: const Color(0xFF00B42A), dark: false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appAuthProvider.overrideWith((_) => _QuietAuth()),
            bambuAccountManagerProvider.overrideWith((_) => _QuietAccounts()),
            bambuCloudProvider.overrideWith((_) => _QuietCloud()),
            allCloudDevicesProvider.overrideWith((_) => _QuietDevices()),
            activePrinterConnectionProvider.overrideWith(
              (_) => _QuietConnection(),
            ),
            activePrinterConfigProvider.overrideWithValue(null),
            mergedPrinterListProvider.overrideWithValue(const []),
            slicerWatcherProvider.overrideWith((_) => _QuietSlicer()),
            activeSlicerStatusProvider.overrideWith((_) async => null),
            activeSlicerDetectorProvider.overrideWithValue(null),
            printQueueStateMachineProvider.overrideWith((_) {}),
            batchRecognitionProvider.overrideWith((_) {}),
            activeBatchProgressProvider.overrideWith((_) async => null),
            materialHeroPrinterStatusProvider.overrideWithValue(null),
            ...overrides,
          ],
          child: RepaintBoundary(
            key: _captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _captureTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.noScaling),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    child!,
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _PointerPainter(guide._pointer),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              home: const InteractionEffectsScope(
                enabled: false,
                child: AuroraWorkspace(),
              ),
            ),
          ),
        ),
      );
      guide.container = ProviderScope.containerOf(
        tester.element(find.byType(AuroraWorkspace)),
      );
      await guide.settle();
      final images = find.byType(Image).evaluate().toList();
      await tester.runAsync(
        () => Future.wait([
          for (final element in images)
            precacheImage((element.widget as Image).image, element),
        ]),
      );
      await guide.settle();
      guide._mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await guide._mouse.addPointer(location: guide._pointer.value.position);
      guide._mousePresent = true;
      return guide;
    } catch (_) {
      await guide.dispose();
      rethrow;
    }
  }

  /// Flushes database streams as well as Flutter animation frames. This is
  /// deliberately separate from a captured pause and useful for setup/asserts.
  Future<void> settle() async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> frame({int durationMs = 100}) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(Duration(milliseconds: durationMs));
    expect(tester.takeException(), isNull);
    final name = 'frame_${frames.length.toString().padLeft(4, '0')}.png';
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${directory.path}/$name',
        ).writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      } finally {
        image.dispose();
      }
    });
    frames.add({'file': name, 'durationMs': durationMs});
    elapsedMs += durationMs;
  }

  Future<void> hold(int count) async {
    if (count > 0) await frame(durationMs: count * 100);
  }

  void mark(String control) {
    keyFrames.add({
      'control': control,
      'frameIndex': frames.length - 1,
      'file': frames.last['file']!,
      'endMs': elapsedMs,
    });
  }

  Future<void> moveTo(Offset target, {int count = 7}) async {
    final start = _pointer.value.position;
    for (var index = 1; index <= count; index++) {
      final point = Offset.lerp(
        start,
        target,
        Curves.easeInOutCubic.transform(index / count),
      )!;
      _pointer.value = _PointerState(point);
      await _mouse.moveTo(point);
      await frame();
    }
  }

  Future<void> click(
    Finder finder,
    String control, {
    int linger = 10,
    int moveFrames = 7,
  }) async {
    final target = finder.hitTestable();
    expect(
      target,
      findsOneWidget,
      reason: 'Visible control required: $control',
    );
    final position = tester.getCenter(target);
    actions.add({
      'atMs': elapsedMs,
      'action': 'click',
      'control': control,
      'finder': finder.toString(),
      'x': position.dx,
      'y': position.dy,
    });
    await moveTo(position, count: moveFrames);
    _pointer.value = _PointerState(position, 0);
    await _mouse.down(position);
    await frame();
    await _mouse.up();
    for (var index = 1; index <= 3; index++) {
      _pointer.value = _PointerState(position, index / 4);
      await frame();
    }
    _pointer.value = _PointerState(position);
    await hold(linger);
    mark(control);
  }

  Future<void> type(Finder field, String value, String label) async {
    await click(field, label, linger: 1, moveFrames: 6);
    actions.add({
      'atMs': elapsedMs,
      'action': 'type',
      'control': label,
      'value': value,
    });
    for (var index = 1; index <= value.length; index++) {
      await tester.enterText(field, value.substring(0, index));
      await frame();
    }
    await hold(3);
    mark('$label / 已填写');
  }

  Future<void> scroll(Finder viewport, double delta, {int linger = 14}) async {
    final rectangle = tester.getRect(viewport);
    final point = Offset(rectangle.right - 30, rectangle.center.dy);
    await moveTo(point, count: 6);
    actions.add({
      'atMs': elapsedMs,
      'action': 'mouse-wheel',
      'control': viewport.toString(),
      'deltaY': delta,
    });
    for (var index = 0; index < 6; index++) {
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: Offset(0, delta / 6)),
      );
      await frame();
    }
    await hold(linger);
    mark('滚动后内容');
  }

  Future<void> finish(
    String title, {
    Map<String, Object?> extra = const {},
  }) async {
    final metadata = {
      'title': title,
      'source': 'isolated_widget_fixture',
      'renderedApplication': 'AuroraWorkspace / production Flutter widgets',
      'dataOrigin':
          'Authored business examples stored in NativeDatabase.memory(). All local form submissions are real UI actions against this disposable database.',
      'realDeviceConnections': 0,
      'realInventoryWrites': 0,
      'realPrintsStarted': 0,
      'trainingEligible': false,
      'width': desktopWalkthroughSize.width.toInt(),
      'height': desktopWalkthroughSize.height.toInt(),
      'fps': 10,
      'frameCount': frames.length,
      'durationMs': elapsedMs,
      'preludeControls': preludeControls,
      'actions': actions,
      'keyFrames': keyFrames,
      ...extra,
    };
    await tester.runAsync(() async {
      await File(
        '${directory.path}/frames.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(frames));
      await File(
        '${directory.path}/metadata.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(metadata));
    });
    if (_mousePresent) {
      await _mouse.removePointer();
      _mousePresent = false;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    debugDisableShadows = _previousShadows;
    if (_mousePresent) await _mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.runAsync(db.close);
    _pointer.dispose();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
    await tester.binding.setSurfaceSize(null);
  }
}

class _PointerState {
  const _PointerState(this.position, [this.ripple]);
  final Offset position;
  final double? ripple;
}

class _PointerPainter extends CustomPainter {
  _PointerPainter(this.pointer) : super(repaint: pointer);
  final ValueNotifier<_PointerState> pointer;

  @override
  void paint(Canvas canvas, Size size) {
    final state = pointer.value;
    if (state.ripple case final double progress) {
      canvas.drawCircle(
        state.position,
        5 + 22 * progress,
        Paint()
          ..color = const Color(
            0xFF00AE62,
          ).withValues(alpha: .55 * (1 - progress))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.drawCircle(
        state.position,
        5 + 12 * progress,
        Paint()
          ..color = const Color(
            0xFF00AE62,
          ).withValues(alpha: .15 * (1 - progress)),
      );
    }
    canvas.save();
    canvas.translate(state.position.dx, state.position.dy);
    final arrow = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 25)
      ..lineTo(6, 19)
      ..lineTo(11, 30)
      ..lineTo(15, 28)
      ..lineTo(10, 17)
      ..lineTo(21, 17)
      ..close();
    canvas.drawShadow(arrow, Colors.black.withValues(alpha: .25), 2, false);
    canvas.drawPath(arrow, Paint()..color = Colors.white);
    canvas.drawPath(
      arrow,
      Paint()
        ..color = const Color(0xFF263830)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PointerPainter oldDelegate) =>
      pointer != oldDelegate.pointer;
}

Future<void> _loadFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final regular = await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes();
    final bold = await File(r'C:\Windows\Fonts\msyhbd.ttc').readAsBytes();
    // A button's explicit TextStyle can omit fontFamily and replace the theme
    // style. The headless engine has no Windows font fallback, so register the
    // same Chinese-capable font under its default Windows/generic aliases too.
    // This fixes the real glyph rendering without changing production widgets.
    for (final family in <String>{
      AppTypography.chineseFontFamily,
      ...AppTypography.chineseFontFamilyFallback,
      'Microsoft YaHei',
      'Microsoft YaHei UI',
      'Arial',
      'Segoe UI',
      'Roboto',
      'Ahem',
      AppTypography.monoFontFamily,
    }) {
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.sublistView(regular)))
            ..addFont(Future.value(ByteData.sublistView(bold))))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
}

ThemeData _captureTheme() {
  final theme = buildPersonalDesktopTheme(
    AppTheme.light(),
    personalProduct: true,
    studioMode: false,
  );
  return theme.copyWith(
    snackBarTheme: theme.snackBarTheme.copyWith(
      contentTextStyle: theme.snackBarTheme.contentTextStyle!.copyWith(
        fontFamily: AppTypography.chineseFontFamily,
        fontFamilyFallback: AppTypography.chineseFontFamilyFallback,
      ),
    ),
  );
}

class _QuietAuth extends StateNotifier<AppAuthState>
    implements AppAuthNotifier {
  _QuietAuth() : super(const AppAuthState(status: AppAuthStatus.signedOut));
  @override
  Future<void> get ready => Future.value();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuietAccounts extends StateNotifier<BambuAccountManagerState>
    implements BambuAccountManagerNotifier {
  _QuietAccounts() : super(const BambuAccountManagerState());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuietCloud extends StateNotifier<BambuCloudState>
    implements BambuCloudNotifier {
  _QuietCloud() : super(const BambuCloudState());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuietDevices extends StateNotifier<AllCloudDevicesState>
    implements AllCloudDevicesNotifier {
  _QuietDevices() : super(const AllCloudDevicesState());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuietConnection extends StateNotifier<ActivePrinterState>
    implements ActivePrinterConnectionNotifier {
  _QuietConnection() : super(const ActivePrinterState());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuietSlicer extends StateNotifier<SlicerWatcherState>
    implements SlicerWatcherNotifier {
  _QuietSlicer() : super(const SlicerWatcherState());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
