import 'dart:async';
import 'dart:io';
import 'package:consumable_tracker_desktop/core/services/app_update_service.dart';
import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/core/theme/personal_desktop_theme.dart';
import 'package:consumable_tracker_desktop/features/updates/app_update_dialog.dart';
import 'package:consumable_tracker_desktop/features/updates/app_update_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_visual_theme.dart';
import 'package:consumable_tracker_desktop/widgets/personal_desktop_chrome.dart';
import 'package:consumable_tracker_desktop/widgets/app_glass_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _optional = AppUpdateState(
  phase: AppUpdatePhase.available,
  currentVersion: 'v1.0.0+1',
  latestVersion: 'v1.1.0+2',
  releaseNotes: '新增软件更新中心。\n优化更新提醒与版本说明。\n完善网络失败后的重试体验。',
  downloadUri: Uri.parse('https://example.com/sohun/download'),
);
AppUpdateState _mandatory({String? notes}) => AppUpdateState(
  phase: AppUpdatePhase.available,
  currentVersion: _optional.currentVersion,
  latestVersion: _optional.latestVersion,
  releaseNotes: notes ?? _optional.releaseNotes,
  downloadUri: _optional.downloadUri,
  isMandatory: true,
  minimumSupportedVersion: 'v1.1.0',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('可选更新可关闭或跳过；打开页面不冒充安装完成', (tester) async {
    var downloads = 0;
    var skipped = 0;
    await _host(
      tester,
      update: _optional,
      onDownload: () async {
        downloads++;
        return true;
      },
      onSkip: () => skipped++,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    final downloadRect = tester.getRect(
      find.byKey(const ValueKey('update-download')),
    );
    await tester.tapAt(Offset(downloadRect.right - 10, downloadRect.center.dy));
    await tester.pumpAndSettle();
    expect(downloads, 1);
    expect(find.textContaining('下载页面已打开'), findsOneWidget);
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-later')));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('立即更新'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(downloads, 2);
    await tester.tap(find.byKey(const ValueKey('update-skip')));
    await tester.pumpAndSettle();
    expect(skipped, 1);
    expect(find.text('发现新版本'), findsNothing);
  });

  testWidgets('必要更新不接受遮罩Esc系统返回，打开下载后仍阻塞', (tester) async {
    await _host(tester, update: _mandatory(), onDownload: () async => true);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    for (final key in ['update-later', 'update-close', 'update-skip']) {
      expect(find.byKey(ValueKey(key)), findsNothing);
    }
    await tester.tapAt(const Offset(2, 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('更新后继续使用'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-download')));
    await tester.pumpAndSettle();
    expect(find.textContaining('下载页面已打开'), findsOneWidget);
    expect(find.text('更新后继续使用'), findsOneWidget);
  });

  testWidgets('重复点击不重复打开，关闭后平台异常不setState', (tester) async {
    final response = Completer<bool>();
    var calls = 0;
    await _host(
      tester,
      update: _optional,
      onDownload: () {
        calls++;
        return response.future;
      },
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-download')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('update-download')));
    expect(calls, 1);
    await tester.tap(find.byKey(const ValueKey('update-later')));
    await tester.pumpAndSettle();
    response.completeError(StateError('launcher failed'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开失败可重试，成功后仍显示真实浏览器移交', (tester) async {
    var attempts = 0;
    await _host(
      tester,
      update: _optional,
      onDownload: () async {
        if (attempts++ == 0) throw StateError('no browser');
        return true;
      },
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-download')));
    await tester.pumpAndSettle();
    expect(find.textContaining('未能打开下载页面'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-download')));
    await tester.pumpAndSettle();
    expect(find.textContaining('下载页面已打开'), findsOneWidget);
  });

  testWidgets('缺少下载链接禁用空操作并提供重新检查', (tester) async {
    var checked = 0;
    await _host(
      tester,
      update: const AppUpdateState(
        phase: AppUpdatePhase.available,
        latestVersion: 'v2.0.0',
        isMandatory: true,
      ),
      onDownload: () async => throw StateError('must not open'),
      onRetry: () async {
        checked++;
      },
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂未获取到可用下载地址'), findsOneWidget);
    expect(
      tester
          .widget<AppGlassButton>(find.byKey(const ValueKey('update-download')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('update-retry')));
    await tester.pumpAndSettle();
    expect(checked, 1);
  });

  for (final dark in [false, true]) {
    testWidgets('320宽双倍字体与长说明可滚动 dark=$dark', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _host(
        tester,
        update: _mandatory(notes: List.filled(25, '改进页面显示和操作反馈。').join('\n')),
        onDownload: () async => true,
        dark: dark,
        mobile: true,
        textScaler: const TextScaler.linear(2),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('update-download')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('update-download')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('update-download')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('更新中心展示检查失败重试和最新状态，手动可查看更新', (tester) async {
    final service = _TestUpdateService();
    service.next = const AppUpdateState(
      phase: AppUpdatePhase.failed,
      message: '网络暂不可用',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appUpdateServiceProvider.overrideWith((ref) => service)],
        child: MaterialApp(
          theme: _theme(false, true),
          home: const InteractionEffectsScope(
            enabled: false,
            child: AppUpdatePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法检查更新'), findsOneWidget);
    expect(find.text('网络暂不可用'), findsOneWidget);
    service.next = const AppUpdateState(phase: AppUpdatePhase.upToDate);
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();
    expect(find.text('你已是最新版本'), findsOneWidget);
    expect(service.checks, 2);
    service.next = _optional;
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭动画时更新对话框无转场', (tester) async {
    await _host(tester, update: _optional, onDownload: () async => true);
    await tester.tap(find.text('open'));
    await tester.pump();
    final route = ModalRoute.of(tester.element(find.byType(AppUpdatePanel)))!;
    expect(route.animation!.isCompleted, isTrue);
  });

  testWidgets('渲染桌面手机可选必要更新与重试', (tester) async {
    final savedShadows = debugDisableShadows;
    debugDisableShadows = false;
    try {
      await _fonts(tester);
      for (final mobile in [false, true]) {
        for (final dark in [false, true]) {
          await tester.binding.setSurfaceSize(
            mobile ? const Size(390, 844) : const Size(1024, 800),
          );
          for (final mandatory in [false, true]) {
            final name =
                '${mobile ? 'mobile' : 'desktop'}-'
                '${mandatory ? 'required' : 'optional'}-'
                '${dark ? 'dark' : 'light'}';
            await tester.pumpWidget(
              ProviderScope(
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: _theme(dark, mobile),
                  home: InteractionEffectsScope(
                    enabled: false,
                    child: PersonalDesktopBackground(
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Center(
                            child: AppUpdatePanel(
                              key: ValueKey(name),
                              update: mandatory ? _mandatory() : _optional,
                              onDownload: () async => false,
                              onRetry: () async {},
                              onLater: mandatory ? null : () {},
                              onSkipVersion: mandatory ? null : () {},
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await _images(tester);
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile('../build/update-ui/$name.png'),
            );
            if (mandatory && mobile && !dark) {
              await tester.tap(find.byKey(const ValueKey('update-download')));
              await tester.pumpAndSettle();
              await expectLater(
                find.byType(MaterialApp),
                matchesGoldenFile('../build/update-ui/mobile-retry-light.png'),
              );
            }
            expect(tester.takeException(), isNull);
          }
        }
      }
    } finally {
      debugDisableShadows = savedShadows;
      await tester.binding.setSurfaceSize(null);
    }
  }, skip: !const bool.fromEnvironment('CAPTURE_UPDATE_UI'));
}

ThemeData _theme(bool dark, bool mobile) {
  final base = dark ? AppTheme.dark() : AppTheme.light();
  return mobile
      ? buildMobileTheme(base)
      : buildPersonalDesktopTheme(
          base,
          personalProduct: true,
          studioMode: false,
        );
}

Future<void> _host(
  WidgetTester tester, {
  required AppUpdateState update,
  required Future<bool> Function() onDownload,
  Future<void> Function()? onRetry,
  VoidCallback? onSkip,
  bool dark = false,
  bool mobile = false,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: _theme(dark, mobile),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: InteractionEffectsScope(enabled: false, child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => AppUpdateDialog.show(
                  context,
                  update,
                  onDownload: onDownload,
                  onRetry: onRetry,
                  onSkipVersion: onSkip,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _fonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final regular = await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes();
    final bold = await File(r'C:\Windows\Fonts\msyhbd.ttc').readAsBytes();
    for (final family in [
      AppTypography.chineseFontFamily,
      'HarmonyOS Sans',
      'Microsoft YaHei UI',
      'Roboto',
      'Ahem',
    ]) {
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

Future<void> _images(WidgetTester tester) async {
  final elements = find.byType(Image).evaluate().toList();
  await tester.runAsync(
    () => Future.wait([
      for (final element in elements)
        precacheImage((element.widget as Image).image, element),
    ]),
  );
  await tester.pumpAndSettle();
}

class _TestUpdateService extends StateNotifier<AppUpdateState>
    implements AppUpdateService {
  _TestUpdateService() : super(const AppUpdateState());
  AppUpdateState? next;
  int checks = 0;
  @override
  Future<AppUpdateState> checkForUpdates() async {
    checks++;
    state = next ?? state;
    return state;
  }

  @override
  Future<bool> openDownloadPage({Uri? verifiedDownloadUri}) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
