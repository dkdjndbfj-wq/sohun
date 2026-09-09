import 'dart:async';
import 'dart:io';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/mobile/ams_tag_template.dart';
import 'package:consumable_tracker_desktop/mobile/ams_template_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_groups.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_brand_launch.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_visual_theme.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_auth_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_account_app.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_writer_page.dart';
import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/widgets/filament_spool_icon.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ams_template_fixture.dart';

void main() {
  testWidgets('切换底部导航保留品牌、型号和库存搜索，快捷入口返回登记页', (tester) async {
    final calls = await _mountApp(tester);
    await tester.enterText(find.byType(TextField).first, '测试品牌');
    await tester.tap(find.text('选择型号'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    final selectedModel = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .toList();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).hitTestable().first, 'PETG');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.tap(find.byTooltip('写入耗材标签'));
    await tester.pumpAndSettle();
    expect(find.text('测试品牌'), findsOneWidget);
    expect(find.text('选择型号'), findsNothing);
    expect(
      tester.widgetList<Text>(find.byType(Text)).map((text) => text.data),
      containsAll(selectedModel.whereType<String>()),
    );
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    expect(find.text('PETG'), findsOneWidget);
    expect(calls, isEmpty, reason: '普通切页不能销毁写入页并触发 NFC 取消');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('系统减少动画时切页立即完成，手机页面有不透明背景', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _mountApp(tester);
    final pageContext = tester.element(find.byType(MobileRfidWriterPage));
    expect(AppMotion.enabled(pageContext), isFalse);
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pump();
    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.controller!.page, 1);
    final background = find.byType(MobileGlassBackground).first;
    final canvas = tester.widget<ColoredBox>(
      find.descendant(of: background, matching: find.byType(ColoredBox)).first,
    );
    expect(canvas.color.a, 1);
    expect(find.byType(BackdropFilter), findsWidgets);
    final typography = Theme.of(pageContext).textTheme;
    expect(
      typography.bodyMedium?.fontSize,
      AppTheme.light().textTheme.bodyMedium?.fontSize,
    );
    expect(typography.bodyMedium?.fontFamily, 'HarmonyOS Sans');
    expect(
      typography.bodyMedium?.fontFamilyFallback,
      contains('Microsoft YaHei UI'),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('320 宽双倍字号与键盘下，NFC 等待、取消和结果均不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final templates = _UiAmsTemplates();
    final nfc = _PendingAmsNfc();
    final sync = _PendingSync();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMobileTheme(AppTheme.light()),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
            viewInsets: EdgeInsets.only(bottom: 240),
          ),
          child: InteractionEffectsScope(
            enabled: false,
            child: MobileRfidWriterPage(
              nfc: nfc,
              sync: sync,
              amsTemplateRepository: templates,
              ownerAccount: 'ui-test|personal',
              loadMaterials: () async => ['PLA+'],
              accountLabel: '测试账号',
              onAccountTap: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _chooseAmsTemplate(tester, templates.template);
    await tester.enterText(find.byType(TextField).first, 'eSUN');
    await tester.ensureVisible(find.text('选择型号'));
    await tester.tap(find.text('选择型号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PLA+'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('靠近标签并写入'));
    await tester.tap(find.text('靠近标签并写入'));
    await _confirmAmsWrite(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(nfc.restores, 1);
    expect(nfc.genericWrites, 0);
    expect(nfc.restored!.blocks, templates.template.blocks);
    expect(find.byKey(const ValueKey('writing')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('取消等待'));
    await tester.tap(find.text('取消等待'));
    await tester.pumpAndSettle();
    expect(nfc.cancelCount, 1);
    expect(sync.saves, 0);
    expect(find.byKey(const ValueKey('writing')), findsNothing);
    expect(find.text('已取消等待'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('写入结果首次出现有淡入过程，待同步事实不会随提示条消失', (tester) async {
    final templates = _UiAmsTemplates();
    final nfc = _PendingAmsNfc();
    final sync = _PendingSync();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMobileTheme(AppTheme.light()),
        home: MobileRfidWriterPage(
          nfc: nfc,
          sync: sync,
          amsTemplateRepository: templates,
          ownerAccount: 'ui-test|personal',
          loadMaterials: () async => ['PLA+'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _chooseAmsTemplate(tester, templates.template);
    await tester.enterText(find.byType(TextField).first, 'eSUN');
    await tester.tap(find.text('选择型号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PLA+'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('靠近标签并写入'));
    await tester.tap(find.text('靠近标签并写入'));
    await _confirmAmsWrite(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(nfc.restores, 1);
    expect(nfc.genericWrites, 0);
    expect(find.byKey(const ValueKey('writing')), findsOneWidget);
    nfc.result.complete(
      RfidWriteSuccess(
        tagId: templates.template.uid,
        tagType: 'CUID',
        verified: true,
        blocksVerified: 64,
        amsCompatibility: 'template_restored_unverified',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('mobile-write-result-content')),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, greaterThan(0));
    expect(fade.opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('已保存到本机 · 云端待同步'), findsOneWidget);
    expect(sync.saves, 1);
    expect(sync.tagId, templates.template.uid);
    expect(sync.draft?.brand, 'eSUN');
    expect(sync.draft?.model, 'PLA+');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('刷新失败后保留离线状态，重试成功才显示同步完成', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final pending = Completer<void>();
    var refreshCount = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          consumablesProvider.overrideWith((ref) => Stream.value([])),
        ],
        child: MaterialApp(
          theme: buildMobileTheme(AppTheme.light()),
          home: MobileInventoryPage(
            sync: _PendingSync(),
            accountLabel: '测试用户',
            loadMaterials: () async => ['PLA+'],
            onRefreshInventory: () async {
              if (++refreshCount == 1) await pending.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final refresh = tester.state<RefreshIndicatorState>(
      find.byType(RefreshIndicator),
    );
    final first = refresh.show();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在同步个人库存…'), findsOneWidget);
    pending.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    await first;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('云端未同步 · 本机库存可用'), findsOneWidget);
    expect(find.textContaining('已连接'), findsNothing);
    final second = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await tester.pumpAndSettle();
    await second;
    expect(find.text('本次云端同步完成'), findsOneWidget);
    expect(refreshCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小屏大字号库存指标自动换行，详情弹层可滚动且不溢出', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _mountApp(tester, size: const Size(320, 640), items: _previewItems);
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mobile-inventory-metrics-grid')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('PLA+'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('PLA+')),
      alignment: 0.35,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('PLA+'));
    await tester.pumpAndSettle();
    expect(find.text('eSUN · PLA+'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('100 卷库存首屏至少完整显示 6 卷，滚动懒加载且搜索固定可用', (tester) async {
    await _mountApp(tester, items: _manyItems);
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('品牌分类'));
    await tester.pumpAndSettle();
    final rows = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'mobile-inventory-row-',
          ),
    );
    final bottom = tester.getRect(find.byType(NavigationBar)).top;
    final viewport = tester.getRect(find.byType(CustomScrollView));
    final visible = rows.evaluate().where((element) {
      final rect = tester.getRect(find.byWidget(element.widget));
      return rect.top >= viewport.top && rect.bottom <= bottom;
    }).length;
    expect(visible, greaterThanOrEqualTo(6));
    expect(rows.evaluate().length, lessThan(25), reason: '不能一次构建 100 张耗材卡');
    for (final icon in tester.widgetList<FilamentSpoolIcon>(
      find.byType(FilamentSpoolIcon),
    )) {
      expect(icon.dimensional, isFalse, reason: '与个人版桌面库存使用同一默认平面图标');
    }
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1700));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mobile-inventory-search')).hitTestable(),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('mobile-inventory-search')),
      '色号 73',
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.text('色号 73'),
      ),
      findsOneWidget,
    );
    expect(find.text('色号 72'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('库存支持余量排序和品牌材质筛选，空结果可恢复', (tester) async {
    await _mountApp(tester, items: _previewItems);
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('品牌分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('库存排序'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .ancestor(
            of: find.text('余量从少到多'),
            matching: find.byWidgetPredicate(
              (widget) => widget is CheckedPopupMenuItem,
            ),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('PETG HF')).dy,
      lessThan(tester.getTopLeft(find.text('PLA+')).dy),
    );
    await tester.tap(find.byTooltip('筛选品牌和材质'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部品牌'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('eSUN').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();
    expect(find.text('PETG HF'), findsNothing);
    expect(find.text('PLA+'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('mobile-inventory-search')),
      '没有这种耗材',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(find.text('PETG HF'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('默认品牌→型号分类聚合 100 卷，按需展开且不合并单卷身份', (tester) async {
    await _mountApp(tester, items: _manyItems);
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    expect(find.byType(MobileInventoryBrandHeader), findsNWidgets(2));
    expect(find.byType(MobileInventoryCategoryRow), findsNWidgets(2));
    final categories = tester.widgetList<MobileInventoryCategoryRow>(
      find.byType(MobileInventoryCategoryRow),
    );
    expect(
      categories.fold(0, (sum, row) => sum + row.category.items.length),
      100,
    );
    expect(
      categories
          .expand((row) => row.category.items)
          .map((item) => item.uid)
          .toSet(),
      hasLength(100),
    );
    final firstCategory = categories.first.category;
    await tester.tap(find.byType(MobileInventoryCategoryRow).first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        ValueKey('mobile-inventory-row-${firstCategory.items.first.id}'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(
        ValueKey('mobile-inventory-row-${firstCategory.items.first.id}'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('品牌启动只播放一次，关闭动画跳过且不阻止首次操作', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MobileBrandLaunch(child: Scaffold(body: Text('首页'))),
      ),
    );
    expect(find.byKey(const ValueKey('mobile-brand-launch')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 360));
    expect(find.byKey(const ValueKey('mobile-brand-launch')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-brand-launch')), findsNothing);
    await tester.pumpWidget(
      const MaterialApp(
        home: MobileBrandLaunch(child: Scaffold(body: Text('资料已更新'))),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('mobile-brand-launch')), findsNothing);
    await tester.pumpWidget(
      const MaterialApp(
        home: InteractionEffectsScope(
          enabled: false,
          child: MobileBrandLaunch(
            key: ValueKey('reduced'),
            child: Scaffold(body: Text('直接进入')),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('mobile-brand-launch')), findsNothing);
    expect(find.text('直接进入').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('我的页面可切换外观并关闭动画，重建不会重播启动页', (tester) async {
    await _mountApp(tester);
    await tester.tap(find.widgetWithText(NavigationDestination, '我的'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('外观与交互'));
    await tester.tap(find.text('外观与交互'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色模式'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(
      AppMotion.enabled(tester.element(find.byType(SwitchListTile))),
      isFalse,
    );
    expect(find.byKey(const ValueKey('mobile-brand-launch')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  // Optional local render QA; normal tests do not depend on host fonts or
  // binary goldens. Run with --update-goldens --dart-define=CAPTURE_MOBILE_UI=true.
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      '渲染手机页面 ${mode.name}',
      (tester) async {
        final previousShadows = debugDisableShadows;
        debugDisableShadows = false;
        try {
          await tester.runAsync(() async {
            const fontPath = String.fromEnvironment(
              'MOBILE_UI_FONT',
              defaultValue: r'C:\Windows\Fonts\msyh.ttc',
            );
            final font = await File(fontPath).readAsBytes();
            for (final family in [
              AppTypography.chineseFontFamily,
              'HarmonyOS Sans',
              'Microsoft YaHei UI',
              'Roboto',
              'Ahem',
            ]) {
              await (FontLoader(
                family,
              )..addFont(Future.value(ByteData.sublistView(font)))).load();
            }
            await (FontLoader('MaterialIcons')
                  ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
                .load();
          });
          final nfcCalls = await _mountApp(
            tester,
            mode: mode,
            items: _catalogPreviewItems,
          );
          await _settleImages(tester);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('../build/mobile-ui/writer-${mode.name}.png'),
          );
          await tester.ensureVisible(find.text('靠近标签并写入'));
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../build/mobile-ui/writer-actions-${mode.name}.png',
            ),
          );
          if (const bool.fromEnvironment('CAPTURE_MOBILE_WRITER_ONLY')) {
            await tester.tap(find.byTooltip('登记帮助'));
            await tester.pumpAndSettle();
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile(
                '../build/mobile-ui/writer-help-${mode.name}.png',
              ),
            );
            Navigator.of(tester.element(find.byType(BottomSheet))).pop();
            await tester.pumpAndSettle();
            await tester.tap(find.text('白色'));
            await tester.pumpAndSettle();
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile(
                '../build/mobile-ui/writer-color-${mode.name}.png',
              ),
            );
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey('mobile-registration-remnant')),
            );
            await tester.pumpAndSettle();
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile(
                '../build/mobile-ui/writer-remnant-${mode.name}.png',
              ),
            );
            expect(nfcCalls, isEmpty);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
            return;
          }
          await tester.tap(find.byType(NavigationDestination).at(1));
          await tester.pumpAndSettle();
          await _settleImages(tester);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('../build/mobile-ui/inventory-${mode.name}.png'),
          );
          await tester.tap(find.byType(MobileInventoryCategoryRow).first);
          await tester.pumpAndSettle();
          await _settleImages(tester);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../build/mobile-ui/inventory-expanded-${mode.name}.png',
            ),
          );
          await tester.tap(find.text('品牌分类'));
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../build/mobile-ui/inventory-list-${mode.name}.png',
            ),
          );
          await tester.tap(find.byTooltip('筛选品牌和材质'));
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../build/mobile-ui/inventory-filter-${mode.name}.png',
            ),
          );
          await tester.tap(find.text('应用筛选'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('mobile-add-inventory')));
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              '../build/mobile-ui/inventory-add-${mode.name}.png',
            ),
          );
          Navigator.of(tester.element(find.byType(BottomSheet))).pop();
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(NavigationDestination, '我的'));
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('../build/mobile-ui/account-${mode.name}.png'),
          );
          await tester.tap(find.byKey(const ValueKey('mobile-open-login')));
          await tester.pumpAndSettle();
          await _settleImages(tester);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('../build/mobile-ui/login-${mode.name}.png'),
          );
          await tester.tap(find.text('注册'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('mobile-auth-submit')),
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('../build/mobile-ui/register-${mode.name}.png'),
          );
          expect(find.byType(MobileAuthPage), findsOneWidget);
          expect(nfcCalls, isEmpty, reason: '页面预览不发起标签读取、写入或权限请求');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          debugDisableShadows = previousShadows;
        }
      },
      skip: !const bool.fromEnvironment('CAPTURE_MOBILE_UI'),
    );
  }
}

Future<void> _settleImages(WidgetTester tester) async {
  final images = find.byType(Image).evaluate().toList();
  await tester.runAsync(
    () => Future.wait([
      for (final element in images)
        precacheImage((element.widget as Image).image, element),
    ]),
  );
  await tester.pumpAndSettle();
}

Future<List<String>> _mountApp(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  ThemeMode mode = ThemeMode.system,
  List<Consumable> items = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(database.close);
  final auth = AppAuthNotifier(
    serverSettings: CommunityServerSettings(
      store: _EmptyOverrideStore(),
      compileTimeBaseUrl: 'https://mobile-preview.example.test',
    ),
    sessionStore: _EmptySessionStore(),
    apiFactory: (_) => throw UnimplementedError(),
  );
  await auth.ready;
  final calls = <String>[];
  const channel = MethodChannel('top.sohun/consumable_rfid');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
    call,
  ) async {
    calls.add(call.method);
    return null;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appAuthProvider.overrideWith((ref) => auth),
        communityApiProvider.overrideWithValue(null),
        // UI previews have no update/telemetry transport or account session.
        communityTelemetryApiProvider.overrideWithValue(null),
        personalConsumablesByOwnerProvider(
          '',
        ).overrideWith((ref) => Stream.value(items)),
      ],
      child: MobileRfidAccountApp(
        themeMode: mode,
        loadMaterials: () async => ['PLA+'],
      ),
    ),
  );
  await tester.pumpAndSettle();
  return calls;
}

final _previewItems = [
  Consumable(
    id: 1,
    uid: 'preview-1',
    manufacturer: 'eSUN',
    model: 'PLA+',
    materialType: 'PLA+',
    colorHex: '#12AB84',
    colorName: '薄荷绿',
    totalGrams: 1000,
    remainingGrams: 760,
    createdAt: DateTime(2026, 9, 6),
    updatedAt: DateTime(2026, 9, 6),
  ),
  Consumable(
    id: 2,
    uid: 'preview-2',
    manufacturer: 'Bambu Lab',
    model: 'PETG HF',
    materialType: 'PETG',
    colorHex: '#E97F52',
    colorName: '珊瑚橙',
    totalGrams: 1000,
    remainingGrams: 120,
    createdAt: DateTime(2026, 9, 6),
    updatedAt: DateTime(2026, 9, 6),
  ),
];

final _manyItems = List.generate(100, (index) {
  final base = _previewItems[index % 2];
  const colors = [
    '#12AB84',
    '#E97F52',
    '#537AEE',
    '#F2D472',
    '#E9E9E9',
    '#242830',
  ];
  return base.copyWith(
    id: index + 100,
    uid: 'density-$index',
    colorName: Value('色号 $index'),
    colorHex: colors[index % colors.length],
    remainingGrams: ((index * 173 + 120) % 1000).toDouble(),
    updatedAt: DateTime(2026, 9, 6).add(Duration(minutes: index)),
  );
});

final _catalogPreviewItems = List.generate(96, (index) {
  const brands = ['Bambu Lab', 'eSUN', 'JAYO', 'Polymaker'];
  const models = ['PLA Basic', 'PETG HF', 'ABS'];
  const colors = [
    '#242830',
    '#12AB84',
    '#E97F52',
    '#537AEE',
    '#F2D472',
    '#E9E9E9',
  ];
  const names = ['曜石黑', '薄荷绿', '珊瑚橙', '海洋蓝', '奶油黄', '象牙白'];
  return _previewItems.first.copyWith(
    id: index + 300,
    uid: 'catalog-preview-$index',
    manufacturer: brands[index ~/ 24],
    model: models[(index ~/ 8) % 3],
    materialType: models[(index ~/ 8) % 3].split(' ').first,
    colorName: Value(names[index % 6]),
    colorHex: colors[index % 6],
    remainingGrams: ((index * 173 + 120) % 1000).toDouble(),
    updatedAt: DateTime(2026, 9, 6).add(Duration(minutes: index)),
  );
});

class _EmptySessionStore implements AppAuthSessionStore {
  @override
  Future<void> clear() async {}
  @override
  Future<AppAuthSession?> read() async => null;
  @override
  Future<void> write(AppAuthSession session) async {}
}

class _EmptyOverrideStore implements CommunityServerOverrideStore {
  @override
  Future<void> clear() async {}
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}

Future<void> _chooseAmsTemplate(
  WidgetTester tester,
  AmsTagTemplate template,
) async {
  await tester.ensureVisible(find.text('兼容标签模板'));
  await tester.tap(find.text('兼容标签模板'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(template.name));
  await tester.tap(find.text(template.name));
  await tester.pumpAndSettle();
}

Future<void> _confirmAmsWrite(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byType(CheckboxListTile));
  await tester.tap(find.byType(CheckboxListTile));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('确认并开始写入'));
  await tester.tap(find.text('确认并开始写入'));
  // The NFC Future remains pending; waiting for all animations would wait on
  // the live progress indicator instead of observing the actual waiting UI.
  await tester.pump();
}

class _UiAmsTemplates implements AmsTemplateRepository {
  final template = syntheticAmsTemplate();

  @override
  Future<List<AmsTagTemplate>> list({required String ownerAccount}) async => [
    template,
  ];

  @override
  Future<AmsTagTemplate?> read(
    String id, {
    required String ownerAccount,
  }) async => id == template.id ? template : null;

  @override
  Future<void> save(
    AmsTagTemplate template, {
    required String ownerAccount,
  }) async {}

  @override
  Future<void> delete(String id, {required String ownerAccount}) async {}
}

class _PendingAmsNfc implements RfidNativeBridge, AmsTemplateNfc {
  final result = Completer<RfidWriteResult>();
  int cancelCount = 0;
  int restores = 0;
  int genericWrites = 0;
  AmsTagTemplate? restored;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<bool> isEnabled() async => true;
  @override
  Future<RfidWriteResult> write(MobileConsumableDraft draft) async {
    genericWrites++;
    return const RfidWriteFailure('retired_profile', '不可使用旧写入入口');
  }

  @override
  Future<AmsTemplateReadResult> readAmsTemplate() async =>
      AmsTemplateReadSuccess(syntheticAmsTemplate());

  @override
  Future<RfidWriteResult> restoreAmsTemplate(
    AmsTagTemplate template, {
    required String targetKind,
    required bool allowUidChange,
    void Function(String state)? onProgress,
  }) {
    expect(targetKind, 'cuid');
    expect(allowUidChange, isTrue);
    restores++;
    restored = template;
    return result.future;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    if (!result.isCompleted) {
      result.complete(const RfidWriteFailure('scan_cancelled', '已取消等待'));
    }
  }
}

class _PendingSync implements MobileInventorySync {
  int saves = 0;
  MobileConsumableDraft? draft;
  String? tagId;

  @override
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) async {
    saves++;
    this.draft = draft;
    this.tagId = tagId;
    return const MobileInventorySaveResult(
      inventoryUid: 'test',
      syncPending: true,
    );
  }
}
