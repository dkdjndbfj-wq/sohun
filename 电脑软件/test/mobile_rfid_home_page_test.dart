import 'dart:async';
import 'dart:io';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/mobile/ams_tag_template.dart';
import 'package:consumable_tracker_desktop/mobile/ams_template_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_home_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_visual_theme.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ams_template_fixture.dart';

class _Vault implements AmsTemplateRepository {
  _Vault(this.templates);
  final List<AmsTagTemplate> templates;
  int saves = 0;

  @override
  Future<List<AmsTagTemplate>> list({required String ownerAccount}) async =>
      templates;

  @override
  Future<AmsTagTemplate?> read(
    String id, {
    required String ownerAccount,
  }) async => templates.where((item) => item.id == id).firstOrNull;

  @override
  Future<void> save(
    AmsTagTemplate template, {
    required String ownerAccount,
  }) async {
    saves++;
  }

  @override
  Future<void> delete(String id, {required String ownerAccount}) async {}
}

class _Nfc implements RfidNativeBridge, AmsTemplateNfc {
  _Nfc(this.readResult);
  AmsTemplateReadResult readResult;
  int availableChecks = 0;
  int enabledChecks = 0;
  int reads = 0;
  int restores = 0;
  int cancels = 0;
  String? targetKind;
  AmsTagTemplate? restored;
  bool available = true;
  bool enabled = true;
  bool throwRead = false;
  bool verified = true;
  Completer<AmsTemplateReadResult>? pendingRead;

  @override
  Future<bool> isAvailable() async {
    availableChecks++;
    return available;
  }

  @override
  Future<bool> isEnabled() async {
    enabledChecks++;
    return enabled;
  }

  @override
  Future<AmsTemplateReadResult> readAmsTemplate() async {
    reads++;
    if (throwRead) throw StateError('test read failure');
    if (pendingRead != null) return pendingRead!.future;
    return readResult;
  }

  @override
  Future<RfidWriteResult> restoreAmsTemplate(
    AmsTagTemplate template, {
    required String targetKind,
    required bool allowUidChange,
    void Function(String state)? onProgress,
  }) async {
    restores++;
    restored = template;
    this.targetKind = targetKind;
    return RfidWriteSuccess(
      tagId: template.uid,
      tagType: targetKind.toUpperCase(),
      technology: 'MIFARE_CLASSIC',
      blocksWritten: 64,
      blocksVerified: 64,
      verified: verified,
      amsCompatibility: 'template_restored_unverified',
    );
  }

  @override
  Future<RfidWriteResult> write(MobileConsumableDraft draft) async =>
      const RfidWriteFailure('unexpected', 'unexpected');

  @override
  Future<void> cancel() async => cancels++;
}

class _Sync implements MobileInventorySync, MobileInventoryStockSync {
  bool requiresReplacement = false;
  final saved = <MobileConsumableDraft>[];
  final received =
      <({MobileConsumableDraft draft, int quantity, double grams})>[];

  @override
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) async {
    saved.add(draft);
    return MobileInventorySaveResult(
      inventoryUid: 'written-roll',
      requiresReplacement: requiresReplacement,
    );
  }

  @override
  Future<MobileStockReceiptResult> receiveFromCard(
    MobileConsumableDraft draft, {
    required String operationUid,
    required String tagUid,
    required String tagType,
    required int quantity,
    required double initialGrams,
  }) async {
    received.add((draft: draft, quantity: quantity, grams: initialGrams));
    return MobileStockReceiptResult(
      PersonalStockReceipt(
        operationUid: operationUid,
        inventoryUids: List.generate(quantity, (index) => 'roll-$index'),
        consumableIds: List.generate(quantity, (index) => index + 1),
        replayed: false,
      ),
    );
  }
}

void main() {
  late AmsTagTemplate template;
  late _Nfc nfc;
  late _Vault vault;
  late _Sync sync;

  setUp(() {
    template = syntheticAmsTemplate();
    nfc = _Nfc(AmsTemplateReadSuccess(template));
    vault = _Vault([template]);
    sync = _Sync();
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildMobileTheme(dark ? AppTheme.dark() : AppTheme.light()),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: MobileRfidHomePage(
          nfc: nfc,
          sync: sync,
          loadMaterials: () async => [
            'Bambu PLA Basic',
            'eSUN PETG',
            'Generic ABS',
          ],
          amsTemplateRepository: vault,
          ownerAccount: 'reader|personal',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('首页自动检测 NFC 且只有读取主操作', (tester) async {
    await mount(tester);

    expect(nfc.availableChecks, 1);
    expect(nfc.enabledChecks, 1);
    expect(find.text('NFC 已就绪'), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-reader-primary')), findsOneWidget);
    expect(find.text('读取 CUID / FUID'), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-new-card-brand')), findsNothing);
    expect(find.text('兼容标签模板'), findsNothing);
  });

  testWidgets('已有卡展示独立读取弹窗并按卷数入库', (tester) async {
    await mount(tester);

    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pumpAndSettle();

    expect(nfc.reads, 1);
    expect(vault.saves, 1);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('读取到耗材资料'), findsOneWidget);
    expect(find.text('拓竹'), findsOneWidget);
    expect(find.text('按卷数'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add_circle_outline_rounded));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('mobile-read-roll-count')),
          )
          .controller!
          .text,
      '2',
    );
    await tester.tap(find.byKey(const ValueKey('mobile-read-confirm-stock')));
    await tester.pumpAndSettle();

    expect(sync.received, hasLength(1));
    expect(sync.received.single.quantity, 2);
    expect(sync.received.single.grams, 1000);
  });

  testWidgets('空白卡进入独立写入弹窗并去除材质品牌前缀', (tester) async {
    nfc.readResult = const AmsTemplateReadFailure('BLANK_TAG', '空白卡没有有效模板');
    await mount(tester);

    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pumpAndSettle();

    expect(find.text('写入新卡'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byKey(const ValueKey('mobile-new-card-brand')), findsOneWidget);
    expect(find.text('Bambu PLA Basic'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('mobile-new-card-brand')),
      'Bambu Lab',
    );
    await tester.tap(find.byKey(const ValueKey('mobile-new-card-material')));
    await tester.pumpAndSettle();
    expect(find.text('Bambu PLA Basic'), findsNothing);
    expect(find.text('PLA'), findsOneWidget);
    expect(find.text('PETG'), findsOneWidget);
    await tester.tap(find.text('PETG').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('mobile-new-card-write')),
    );
    await tester.tap(find.byKey(const ValueKey('mobile-new-card-write')));
    await tester.pumpAndSettle();

    expect(nfc.restores, 1);
    expect(nfc.targetKind, 'cuid');
    expect(nfc.restored, same(template));
    expect(sync.saved, hasLength(1));
    expect(sync.saved.single.brand, '拓竹');
    expect(sync.saved.single.model, 'PETG');
  });

  testWidgets('读卡失败保留明确反馈，不把受保护卡当成新卡', (tester) async {
    nfc.readResult = const AmsTemplateReadFailure(
      'AUTH_FAILED',
      '标签认证失败，请重新贴紧',
    );
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('标签认证失败，请重新贴紧'), findsOneWidget);
    expect(nfc.restores, 0);
    expect(sync.received, isEmpty);
    nfc.throwRead = true;
    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pumpAndSettle();
    expect(find.textContaining('读取暂时中断'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('mobile-reader-primary')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('取消等待后迟到的读卡结果不会打开弹窗或入库', (tester) async {
    nfc.pendingRead = Completer<AmsTemplateReadResult>();
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pump();
    nfc.pendingRead!.complete(AmsTemplateReadSuccess(template));
    await tester.pumpAndSettle();
    expect(nfc.cancels, 1);
    expect(find.byType(Dialog), findsNothing);
    expect(sync.received, isEmpty);
    expect(vault.saves, 0);
  });

  testWidgets('余量拒绝30克及超容量，31克按一卷保存', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按克数'));
    await tester.pumpAndSettle();
    for (final grams in ['30', '1001']) {
      await tester.enterText(
        find.byKey(const ValueKey('mobile-read-grams')),
        grams,
      );
      await tester.tap(find.byKey(const ValueKey('mobile-read-confirm-stock')));
      await tester.pumpAndSettle();
      expect(sync.received, isEmpty);
      expect(find.text('余量必须大于 30 g 且不超过 1000 g'), findsOneWidget);
    }
    await tester.enterText(
      find.byKey(const ValueKey('mobile-read-grams')),
      '31',
    );
    await tester.tap(find.byKey(const ValueKey('mobile-read-confirm-stock')));
    await tester.pumpAndSettle();
    expect(sync.received.single.grams, 31);
    expect(sync.received.single.quantity, 1);
  });

  testWidgets('可直接输入100卷，关闭对话框不入库', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mobile-read-roll-count')),
      '100',
    );
    await tester.tap(find.byKey(const ValueKey('mobile-read-confirm-stock')));
    await tester.pumpAndSettle();
    expect(sync.received.single.quantity, 100);
    await tester.ensureVisible(
      find.byKey(const ValueKey('mobile-reader-primary')),
    );
    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(sync.received, hasLength(1));
  });

  testWidgets('新卡颜色也为居中弹窗，无模板不能写入', (tester) async {
    nfc.readResult = const AmsTemplateReadFailure('BLANK_TAG', '空白卡');
    vault.templates.clear();
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-new-card-color')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNWidgets(2));
    expect(find.byType(BottomSheet), findsNothing);
    Navigator.of(tester.element(find.byType(Dialog).last)).pop();
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有源模板'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(nfc.restores, 0);
  });

  testWidgets('首页和写入表单适配320宽双倍字号及键盘', (tester) async {
    nfc.readResult = const AmsTemplateReadFailure('BLANK_TAG', '空白卡');
    await mount(tester, size: const Size(320, 640), textScale: 2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('mobile-reader-primary')),
    );
    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('mobile-new-card-brand')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('mobile-new-card-brand')),
      'Bambu',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('mobile-new-card-write')),
    );
    expect(
      find.byKey(const ValueKey('mobile-new-card-write')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets(
      '读卡界面视觉验收 ${dark ? 'dark' : 'light'}',
      (tester) async {
        // UI examples only: retain the deliberately fake signature fixture.
        // Never distribute an actual card dump as a screenshot dependency.
        final previewBytes = template.toBytes();
        previewBytes.fillRange(64, 80, 0);
        previewBytes.setRange(64, 68, 'PETG'.codeUnits);
        previewBytes.setRange(80, 83, [0x3B, 0x82, 0xF6]);
        template = AmsTagTemplate.fromBytes(
          previewBytes,
          name: 'PETG 界面示例（假签名）',
        );
        nfc.readResult = AmsTemplateReadSuccess(template);
        vault.templates
          ..clear()
          ..add(template);
        await tester.runAsync(() async {
          final font = ByteData.sublistView(
            await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes(),
          );
          for (final family in [
            'HarmonyOS Sans',
            'Microsoft YaHei UI',
            'Roboto',
            'Ahem',
          ]) {
            await (FontLoader(family)..addFont(Future.value(font))).load();
          }
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
        await mount(tester, dark: dark);
        final mode = dark ? 'dark' : 'light';
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('../build/mobile-ui/reader-$mode.png'),
        );
        await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('../build/mobile-ui/read-dialog-$mode.png'),
        );
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        nfc.readResult = const AmsTemplateReadFailure('BLANK_TAG', '空白卡');
        await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('mobile-new-card-brand')),
          'Bambu',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('mobile-new-card-material')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('PETG').last);
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('../build/mobile-ui/new-card-dialog-$mode.png'),
        );
        expect(tester.takeException(), isNull);
      },
      skip: !const bool.fromEnvironment('CAPTURE_MOBILE_READER'),
    );
  }
}
