import 'dart:convert';
import 'dart:ui';

import 'package:consumable_tracker_desktop/data/external/slicer/bambu_system_preset_loader.dart';
import 'package:consumable_tracker_desktop/data/models/print_parameter.dart';
import 'package:consumable_tracker_desktop/data/models/community_preset.dart';
import 'package:consumable_tracker_desktop/providers/community_preset_provider.dart';
import 'package:consumable_tracker_desktop/ui/aurora_parameter_plaza.dart';
import 'package:consumable_tracker_desktop/widgets/printer_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('参数编辑器从资产清单枚举所有机型的工艺预设并过滤非预设文件', () async {
    // Use a synthetic manifest: licensed Bambu resources are deliberately not
    // included in public-source checkouts and must not be a unit-test dependency.
    final expectedNames = [
      for (final model in ['A1', 'P1P', 'X1C'])
        for (var index = 1; index <= 15; index++)
          '0.${index}mm Test @BBL $model',
    ]..sort();
    _mockAssetManifest([
      for (final name in expectedNames.reversed)
        'assets/bambu_presets/process/$name.json',
      'assets/bambu_presets/process/fdm_process_common.json',
      'assets/bambu_presets/process/.gitkeep',
      'assets/bambu_presets/filament/Generic PLA.json',
      'assets/bambu_presets/process_other/Other.json',
    ]);
    final names = await BambuSystemPresetLoader.getAllProcessPresetNames();
    expect(names, expectedNames);
    expect(names.length, greaterThan(40));
    expect(names.any((name) => name.contains('@BBL A1')), isTrue);
    expect(names.any((name) => name.contains('@BBL P1P')), isTrue);
    expect(names.any((name) => name.contains('@BBL X1C')), isTrue);
  });

  test('未安装可选官方资源时返回空列表，不生成无法加载的预设', () async {
    _mockAssetManifest(['assets/bambu_presets/process/.gitkeep']);
    expect(await BambuSystemPresetLoader.getAllProcessPresetNames(), isEmpty);
  });

  test('兼容打印机字段可持久化往返', () {
    final now = DateTime(2026, 7, 27);
    final preset = PrintParameterPreset(
      id: 'user_test',
      name: '测试预设',
      compatiblePrinters: const [
        'Bambu Lab X1 Carbon 0.4 nozzle',
        'Bambu Lab P1S 0.4 nozzle',
      ],
      createdAt: now,
      updatedAt: now,
      quality: const PrintQualityParams(),
      strength: const PrintStrengthParams(),
      speed: const PrintSpeedParams(),
      support: const PrintSupportParams(),
      other: const PrintOtherParams(),
    );

    final restored = PrintParameterPreset.fromBbsparamJson(
      preset.toBbsparamJson(),
    );
    expect(restored.compatiblePrinters, preset.compatiblePrinters);
  });

  testWidgets('参数广场筛选器包含材料、场景、打印机和排序选项', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AuroraParameterPlazaPage())),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('广场预设'), findsWidgets);
    expect(find.text('全部材料'), findsOneWidget);
    expect(find.text('全部场景'), findsOneWidget);
    expect(find.text('全部打印机'), findsOneWidget);
    expect(find.text('推荐排序'), findsOneWidget);
    expect(find.text('按材料'), findsNothing);
    expect(find.text('按场景'), findsNothing);

    await tester.tap(find.text('全部材料'));
    await tester.pumpAndSettle();
    expect(find.text('选择材料'), findsOneWidget);
    expect(find.textContaining('搜索材料型号'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'PLA Silk');
    await tester.pumpAndSettle();
    expect(find.text('Bambu PLA Silk'), findsOneWidget);
    expect(find.text('Generic PLA Silk'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部打印机'));
    await tester.pumpAndSettle();
    expect(find.text('选择打印机'), findsOneWidget);
    expect(find.byType(PrinterImage), findsAtLeastNWidgets(10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('广场只显示社区参数并展示真实作者，不显示拓竹默认卡片', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          communityPresetFeedProvider.overrideWith(
            (ref) => _StaticCommunityFeedNotifier(
              ref,
              CommunityPresetFeedState(
                items: [_communityPreset()],
                hasLoaded: true,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: AuroraParameterPlazaPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('社区 PLA Silk'), findsOneWidget);
    expect(find.textContaining('Maker One'), findsOneWidget);
    expect(find.textContaining('@BBL'), findsNothing);
    expect(find.text('Bambu Lab'), findsNothing);
    expect(find.text('我的发布'), findsOneWidget);
    expect(find.text('本地草稿'), findsOneWidget);

    final preview = find.byKey(
      const ValueKey('preset-preview-community_publication-1'),
    );
    expect(preview, findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(preview));
    await tester.pump();
    expect(
      find.descendant(of: preview, matching: find.text('查看参数')),
      findsOneWidget,
    );
  });

  testWidgets('图标刷新和页面重新激活分别只触发一次刷新', (tester) async {
    late _StaticCommunityFeedNotifier feed;
    final container = ProviderContainer(
      overrides: [
        communityPresetFeedProvider.overrideWith((ref) {
          feed = _StaticCommunityFeedNotifier(
            ref,
            const CommunityPresetFeedState(hasLoaded: true),
          );
          return feed;
        }),
      ],
    );
    addTearDown(container.dispose);
    final scope = UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: AuroraParameterPlazaPage()),
      ),
    );
    await tester.pumpWidget(scope);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final afterInitialLoad = feed.refreshCount;

    await tester.tap(find.byTooltip('刷新当前参数列表'));
    await tester.pump();
    expect(feed.refreshCount, afterInitialLoad + 1);

    container.read(parameterPlazaActivationProvider.notifier).state++;
    await tester.pump();
    expect(feed.refreshCount, afterInitialLoad + 2);
  });

  testWidgets('两个社区预设可加入实验台并展开真实参数对比', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          communityPresetFeedProvider.overrideWith(
            (ref) => _StaticCommunityFeedNotifier(
              ref,
              CommunityPresetFeedState(
                items: [_communityPreset(), _communityPresetTwo()],
                hasLoaded: true,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: AuroraParameterPlazaPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byTooltip('加入对比实验台').first);
    await tester.pump();
    await tester.tap(find.byTooltip('加入对比实验台').first);
    await tester.pump();

    expect(find.text('参数对比实验台'), findsOneWidget);
    expect(find.textContaining('参数差异'), findsOneWidget);
    expect(find.text('展开对比'), findsOneWidget);

    await tester.tap(find.text('展开对比'));
    await tester.pumpAndSettle();
    expect(find.text('社区 PLA Silk'), findsWidgets);
    expect(find.text('社区 PETG Fast'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

void _mockAssetManifest(List<String> assets) {
  rootBundle.evict('AssetManifest.bin');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler('flutter/assets', (message) async {
    final key = utf8.decode(
      message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes),
    );
    if (key != 'AssetManifest.bin') return null;
    return const StandardMessageCodec().encodeMessage({
      for (final asset in assets)
        asset: [
          {'asset': asset},
        ],
    });
  });
  addTearDown(() {
    rootBundle.evict('AssetManifest.bin');
    messenger.setMockMessageHandler('flutter/assets', null);
  });
}

class _StaticCommunityFeedNotifier extends CommunityPresetFeedNotifier {
  int refreshCount = 0;

  _StaticCommunityFeedNotifier(super.ref, CommunityPresetFeedState initial) {
    state = initial;
  }

  @override
  Future<void> refresh({
    CommunityPresetQuery? query,
    bool force = false,
  }) async {
    refreshCount++;
  }
}

CommunityPreset _communityPreset() {
  final now = DateTime(2026, 7, 27);
  return CommunityPreset(
    publicationId: 'publication-1',
    owner: const CommunityPresetOwner(
      id: 'owner-1',
      handle: 'maker-one',
      displayName: 'Maker One',
    ),
    preset: PrintParameterPreset(
      id: 'community_publication-1',
      name: '社区 PLA Silk',
      author: 'Maker One',
      material: 'Bambu PLA Silk',
      scene: '手办',
      compatiblePrinters: const ['Bambu Lab P1S 0.4 nozzle'],
      createdAt: now,
      updatedAt: now,
      quality: const PrintQualityParams(),
      strength: const PrintStrengthParams(),
      speed: const PrintSpeedParams(),
      support: const PrintSupportParams(),
      other: const PrintOtherParams(),
    ),
    visibility: 'public',
    revision: 1,
    likes: 2,
    downloads: 5,
    likedByMe: false,
    publishedAt: now,
    updatedAt: now,
  );
}

CommunityPreset _communityPresetTwo() {
  final now = DateTime(2026, 7, 28);
  return CommunityPreset(
    publicationId: 'publication-2',
    owner: const CommunityPresetOwner(
      id: 'owner-2',
      handle: 'maker-two',
      displayName: 'Maker Two',
    ),
    preset: PrintParameterPreset(
      id: 'community_publication-2',
      name: '社区 PETG Fast',
      author: 'Maker Two',
      material: 'Bambu PETG Basic',
      scene: '功能件',
      compatiblePrinters: const ['Bambu Lab P1S 0.4 nozzle'],
      createdAt: now,
      updatedAt: now,
      quality: const PrintQualityParams(layerHeight: '0.24'),
      strength: const PrintStrengthParams(wallLoops: '3'),
      speed: const PrintSpeedParams(outerWallSpeed: '120'),
      support: const PrintSupportParams(),
      other: const PrintOtherParams(),
    ),
    visibility: 'public',
    revision: 1,
    likes: 4,
    downloads: 9,
    likedByMe: false,
    publishedAt: now,
    updatedAt: now,
  );
}
