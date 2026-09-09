import 'dart:io';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/core/theme/personal_desktop_theme.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/features/dashboard/material_playground_hero.dart';
import 'package:consumable_tracker_desktop/features/inventory/inventory_screen.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_visual_theme.dart';
import 'package:consumable_tracker_desktop/providers/bambu_account_manager.dart';
import 'package:consumable_tracker_desktop/providers/bambu_cloud_provider.dart';
import 'package:consumable_tracker_desktop/providers/batch_recognition_provider.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_queue_provider.dart';
import 'package:consumable_tracker_desktop/providers/slicer_provider.dart';
import 'package:consumable_tracker_desktop/providers/stock_alert_provider.dart';
import 'package:consumable_tracker_desktop/providers/usage_provider.dart';
import 'package:consumable_tracker_desktop/ui/aurora_design.dart';
import 'package:consumable_tracker_desktop/ui/aurora_shell.dart';
import 'package:consumable_tracker_desktop/widgets/app_button.dart';
import 'package:consumable_tracker_desktop/widgets/glass_button_material.dart';
import 'package:consumable_tracker_desktop/widgets/glass_card.dart';
import 'package:consumable_tracker_desktop/widgets/personal_desktop_chrome.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('个人主题仅显式启用，商业模式与手机版保持原主题', () {
    for (final base in [AppTheme.light(), AppTheme.dark()]) {
      expect(
        identical(
          buildPersonalDesktopTheme(
            base,
            personalProduct: false,
            studioMode: false,
          ),
          base,
        ),
        isTrue,
      );
      expect(
        identical(
          buildPersonalDesktopTheme(
            base,
            personalProduct: true,
            studioMode: true,
          ),
          base,
        ),
        isTrue,
      );
      final personal = _theme(base.brightness);
      expect(personal.extension<PersonalDesktopTheme>(), isNotNull);
      expect(buildMobileTheme(base).extension<PersonalDesktopTheme>(), isNull);
      expect(
        personal.textTheme.bodyMedium?.fontSize,
        base.textTheme.bodyMedium?.fontSize,
      );
      expect(
        personal.textTheme.bodyMedium?.height,
        base.textTheme.bodyMedium?.height,
      );
      expect(personal.textTheme.bodyMedium?.fontFamily, 'HarmonyOS Sans');
      expect(
        personal.textTheme.bodyMedium?.fontFamilyFallback,
        contains('Microsoft YaHei UI'),
      );
      expect(
        personal.filledButtonTheme.style?.minimumSize?.resolve({})?.height,
        36,
      );
    }
  });

  testWidgets('卡片玻璃只在个人作用域生效，列表卡不增加背景模糊', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            Theme(
              data: _theme(Brightness.light),
              child: const GlassCard(
                key: ValueKey('personal-card'),
                child: Text('个人'),
              ),
            ),
            Theme(
              data: AppTheme.light(),
              child: const GlassCard(
                key: ValueKey('original-card'),
                child: Text('原样'),
              ),
            ),
          ],
        ),
      ),
    );
    double opacity(String key) {
      final surface = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(Container),
            ),
          )
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.gradient != null);
      return surface.gradient!.colors.last.a;
    }

    expect(opacity('personal-card'), closeTo(0.6, 0.01));
    expect(opacity('original-card'), closeTo(0.72, 0.01));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('个人主按钮共用玻璃材质，原主题和点击行为保持可用', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            Theme(
              data: _theme(Brightness.light),
              child: AppButton(
                key: const ValueKey('personal-button'),
                label: '新增',
                onPressed: () => taps++,
              ),
            ),
            Theme(
              data: AppTheme.light(),
              child: AppButton(
                key: const ValueKey('original-button'),
                label: '原样',
                onPressed: () {},
              ),
            ),
            Theme(
              data: _theme(Brightness.light),
              child: const AppButton(
                key: ValueKey('disabled-button'),
                label: '禁用',
              ),
            ),
          ],
        ),
      ),
    );
    BoxDecoration decoration(String key) =>
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: find.byKey(ValueKey(key)),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as BoxDecoration;
    final personal = find.descendant(
      of: find.byKey(const ValueKey('personal-button')),
      matching: find.byType(GlassButtonMaterial),
    );
    expect(personal, findsOneWidget);
    expect(
      decoration('original-button').boxShadow!.first.color.a,
      closeTo(0.40, 0.01),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('original-button')),
        matching: find.byType(GlassButtonMaterial),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('personal-button')));
    await tester.tap(find.byKey(const ValueKey('disabled-button')));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('真实桌面工作区切页、搜索及折叠保持可用，关闭动画无过渡', (tester) async {
    await _mount(tester);
    await tester.tap(find.byKey(const ValueKey('personal-nav-inventory')));
    await tester.pumpAndSettle();
    expect(find.byType(InventoryScreen), findsOneWidget);
    final field = find.descendant(
      of: find.byType(InventoryScreen),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '薄荷绿');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.tap(find.byKey(const ValueKey('personal-nav-dashboard')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('personal-nav-inventory')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller?.text, '薄荷绿');
    await tester.tap(find.byTooltip('收起侧边栏'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开侧边栏'), findsOneWidget);
    expect(find.byType(PersonalDesktopChrome), findsNWidgets(2));
    expect(
      AppMotion.enabled(tester.element(find.byType(InventoryScreen))),
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final mode in [Brightness.light, Brightness.dark]) {
    testWidgets('个人弹窗增加遮盖度，显式透明度不被覆盖 ${mode.name}', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(mode),
          home: const Row(
            children: [
              GlassCard(
                key: ValueKey('modal'),
                level: GlassLevel.l3,
                child: Text('弹窗'),
              ),
              GlassCard(
                key: ValueKey('explicit'),
                level: GlassLevel.l3,
                opacity: 0.94,
                child: Text('显式'),
              ),
            ],
          ),
        ),
      );
      double opacity(String key) => tester
          .widgetList<Container>(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(Container),
            ),
          )
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.gradient != null)
          .gradient!
          .colors
          .last
          .a;
      expect(
        opacity('modal'),
        closeTo(mode == Brightness.dark ? 0.88 : 0.82, 0.01),
      );
      expect(opacity('explicit'), closeTo(0.94, 0.01));
      expect(find.byType(BackdropFilter), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄窗口与放大字体的侧栏动画无溢出 ${mode.name}', (tester) async {
      await _mount(
        tester,
        brightness: mode,
        size: const Size(1080, 760),
        effects: true,
        textScaler: const TextScaler.linear(1.25),
      );
      await tester.tap(find.byKey(const ValueKey('personal-nav-inventory')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final tooltip in ['收起侧边栏', '展开侧边栏']) {
        await tester.tap(find.byTooltip(tooltip));
        await tester.pump();
        for (var frame = 0; frame < 14; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            tester.takeException(),
            isNull,
            reason: '$tooltip frame $frame',
          );
        }
        await tester.pumpAndSettle();
      }
      expect(find.byType(InventoryScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets(
      '桌面玻璃预览 ${mode.name}',
      (tester) async {
        final shadows = debugDisableShadows;
        debugDisableShadows = false;
        try {
          await tester.runAsync(() async {
            final regular = await File(
              r'C:\Windows\Fonts\msyh.ttc',
            ).readAsBytes();
            final bold = await File(
              r'C:\Windows\Fonts\msyhbd.ttc',
            ).readAsBytes();
            for (final family in [
              AppTypography.chineseFontFamily,
              'HarmonyOS Sans',
              'Microsoft YaHei UI',
              'Roboto',
              'Ahem',
              AppTypography.monoFontFamily,
            ]) {
              await (FontLoader(family)
                    ..addFont(Future.value(ByteData.sublistView(regular)))
                    ..addFont(Future.value(ByteData.sublistView(bold))))
                  .load();
            }
            await (FontLoader('MaterialIcons')
                  ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
                .load();
          });
          await _mount(tester, brightness: mode);
          await _images(tester);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('../build/desktop-ui/workspace-${mode.name}.png'),
          );
          await tester.tap(
            find.byKey(const ValueKey('personal-nav-inventory')),
          );
          await tester.pumpAndSettle();
          await _images(tester);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('../build/desktop-ui/inventory-${mode.name}.png'),
          );
          await tester.tap(find.byTooltip('收起侧边栏'));
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../build/desktop-ui/inventory-compact-${mode.name}.png',
            ),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          debugDisableShadows = shadows;
        }
      },
      skip: !const bool.fromEnvironment('CAPTURE_DESKTOP_UI'),
    );
  }
}

ThemeData _theme(Brightness brightness) => buildPersonalDesktopTheme(
  brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
  personalProduct: true,
  studioMode: false,
);

Future<void> _mount(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Size size = const Size(1360, 900),
  bool effects = false,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  Aurora.applyTheme(
    primaryColor: const Color(0xFF00B42A),
    dark: brightness == Brightness.dark,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        bambuAccountManagerProvider.overrideWith((ref) => _QuietAccounts()),
        bambuCloudProvider.overrideWith((ref) => _QuietCloud()),
        allCloudDevicesProvider.overrideWith((ref) => _QuietDevices()),
        activePrinterConnectionProvider.overrideWith(
          (ref) => _QuietConnection(),
        ),
        activePrinterConfigProvider.overrideWithValue(null),
        mergedPrinterListProvider.overrideWithValue(const []),
        slicerWatcherProvider.overrideWith((ref) => _QuietSlicer()),
        activeSlicerStatusProvider.overrideWith((ref) async => null),
        activeSlicerDetectorProvider.overrideWithValue(null),
        printQueueStateMachineProvider.overrideWith((ref) {}),
        batchRecognitionProvider.overrideWith((ref) {}),
        activeBatchProgressProvider.overrideWith((ref) async => null),
        consumablesProvider.overrideWith((ref) => Stream.value(_items)),
        personalRfidSpoolBindingsProvider.overrideWith(
          (ref) async => <int, RfidSpoolBinding>{},
        ),
        printersWithChannelsProvider.overrideWith(
          (ref) => Stream.value(const []),
        ),
        usageLogsProvider.overrideWith((ref) => Stream.value(const [])),
        stockAlertsProvider.overrideWith((ref) async => []),
        materialHeroPrinterStatusProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: InteractionEffectsScope(
          enabled: effects,
          child: const AuroraWorkspace(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _images(WidgetTester tester) async {
  final images = find.byType(Image).evaluate().toList();
  await tester.runAsync(
    () => Future.wait([
      for (final element in images)
        precacheImage((element.widget as Image).image, element),
    ]),
  );
  await tester.pumpAndSettle();
}

// These read-only fixture notifiers never load real accounts, scan files,
// connect to printers or start background workflows while capturing visuals.
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

final _items = [
  for (var i = 0; i < 12; i++)
    Consumable(
      id: i + 1,
      uid: 'desktop-preview-$i',
      manufacturer: i < 6 ? 'Bambu Lab' : 'eSUN',
      model: i.isEven ? 'PLA Basic' : 'PETG HF',
      materialType: i.isEven ? 'PLA' : 'PETG',
      colorHex: [
        '#12AB84',
        '#527CE5',
        '#F1CE67',
        '#E7784F',
        '#E8E9E8',
        '#343D43',
      ][i % 6],
      colorName: ['薄荷绿', '海洋蓝', '奶油黄', '珊瑚橙', '象牙白', '曜石黑'][i % 6],
      totalGrams: 1000,
      remainingGrams: (980 - i * 63).toDouble(),
      createdAt: DateTime(2026, 9, 6),
      updatedAt: DateTime(2026, 9, 6),
    ),
];
