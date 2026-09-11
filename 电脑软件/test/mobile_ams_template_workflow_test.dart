import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/mobile/ams_tag_template.dart';
import 'package:consumable_tracker_desktop/mobile/ams_template_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_writer_page.dart';
import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';
import 'support/ams_template_fixture.dart';

class _Vault implements AmsTemplateRepository {
  final template = syntheticAmsTemplate();
  final owners = <String>[];
  int saves = 0;
  @override
  Future<List<AmsTagTemplate>> list({required String ownerAccount}) async {
    owners.add(ownerAccount);
    return [template];
  }

  @override
  Future<AmsTagTemplate?> read(
    String id, {
    required String ownerAccount,
  }) async => template;
  @override
  Future<void> save(
    AmsTagTemplate template, {
    required String ownerAccount,
  }) async {
    saves++;
    owners.add(ownerAccount);
  }

  @override
  Future<void> delete(String id, {required String ownerAccount}) async {}
}

class _Nfc implements RfidNativeBridge, AmsTemplateNfc {
  int statusChecks = 0;
  int genericWrites = 0;
  int restores = 0;
  int cancels = 0;
  Completer<RfidWriteResult>? pendingRestore;
  Completer<AmsTemplateReadResult>? pendingRead;
  bool cancellationCompletes = true;
  final progressCallbacks = <void Function(String state)?>[];
  bool verificationFails = false;
  String? returnedTagType;
  String? targetKind;
  AmsTagTemplate? restored;
  @override
  Future<bool> isAvailable() async {
    statusChecks++;
    return true;
  }

  @override
  Future<bool> isEnabled() async {
    statusChecks++;
    return true;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    final pending = pendingRestore;
    if (cancellationCompletes && pending != null && !pending.isCompleted) {
      pending.complete(const RfidWriteFailure('cancelled', '已取消标签操作'));
    }
  }

  @override
  Future<RfidWriteResult> write(MobileConsumableDraft draft) async {
    genericWrites++;
    return const RfidWriteFailure('forbidden', 'unexpected generic write');
  }

  @override
  Future<AmsTemplateReadResult> readAmsTemplate() async =>
      pendingRead?.future ?? AmsTemplateReadSuccess(syntheticAmsTemplate());
  @override
  Future<RfidWriteResult> restoreAmsTemplate(
    AmsTagTemplate template, {
    required String targetKind,
    required bool allowUidChange,
    void Function(String state)? onProgress,
  }) async {
    expect(allowUidChange, isTrue);
    restores++;
    progressCallbacks.add(onProgress);
    restored = template;
    this.targetKind = targetKind;
    if (pendingRestore != null) return pendingRestore!.future;
    return RfidWriteSuccess(
      tagId: template.uid,
      tagType: returnedTagType ?? targetKind.toUpperCase(),
      verified: !verificationFails,
      blocksVerified: verificationFails ? 12 : 64,
      amsCompatibility: 'template_restored_unverified',
    );
  }
}

class _Sync implements MobileInventorySync {
  int saves = 0;
  MobileConsumableDraft? draft;
  String? tagId;
  double? initialGrams;
  Completer<MobileInventorySaveResult>? pending;
  @override
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) async {
    this.draft = draft;
    this.tagId = tagId;
    this.initialGrams = initialGrams;
    saves++;
    if (pending != null) return pending!.future;
    return const MobileInventorySaveResult(inventoryUid: 'local-roll');
  }
}

void main() {
  late _Vault vault;
  late _Nfc nfc;
  late _Sync sync;
  setUp(() {
    vault = _Vault();
    nfc = _Nfc();
    sync = _Sync();
  });

  Future<void> mount(
    WidgetTester tester, {
    String owner = 'alice|personal',
    bool isActive = true,
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(450, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MobileRfidWriterPage(
          isActive: isActive,
          nfc: nfc,
          sync: sync,
          amsTemplateRepository: vault,
          ownerAccount: owner,
          accountIdentity: owner,
          loadMaterials: () async => ['PETG HF'],
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> chooseTemplate(WidgetTester tester) async {
    await tester.tap(find.text('兼容标签模板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(vault.template.name));
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).first, '第三方品牌');
    await tester.tap(find.text('选择型号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PETG HF'));
    await tester.pumpAndSettle();
  }

  Future<void> begin(WidgetTester tester) async {
    await tester.ensureVisible(find.text('靠近标签并写入'));
    await tester.tap(find.text('靠近标签并写入'));
    await tester.pumpAndSettle();
  }

  Future<void> consent(WidgetTester tester) async {
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认并开始写入'));
    await tester.pumpAndSettle();
  }

  Future<void> consentPending(WidgetTester tester) async {
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认并开始写入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  RfidWriteSuccess success() => RfidWriteSuccess(
    tagId: vault.template.uid,
    tagType: 'CUID',
    verified: true,
    blocksVerified: 64,
    amsCompatibility: 'template_restored_unverified',
  );

  for (final grams in [500.0, 1000.0]) {
    testWidgets('first CUID remnant passes $grams g to inventory', (
      tester,
    ) async {
      await mount(tester);
      await chooseTemplate(tester);
      await fill(tester);
      await tester.tap(
        find.byKey(const ValueKey('mobile-registration-remnant')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rfid-initial-grams')),
        '$grams',
      );
      await begin(tester);
      await consent(tester);
      expect(sync.saves, 1);
      expect(sync.initialGrams, grams);
      expect(sync.tagId, vault.template.uid);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'invalid initial weight never starts an irreversible card write',
    (tester) async {
      await mount(tester);
      await chooseTemplate(tester);
      await fill(tester);
      await tester.tap(
        find.byKey(const ValueKey('mobile-registration-remnant')),
      );
      await tester.pumpAndSettle();
      for (final invalid in [
        '0',
        '30',
        '-1',
        'NaN',
        'Infinity',
        '1001',
        '2000',
      ]) {
        await tester.enterText(
          find.byKey(const ValueKey('rfid-initial-grams')),
          invalid,
        );
        await begin(tester);
        expect(find.text('请输入大于 30 且不超过 1000 g 的剩余克数'), findsOneWidget);
        expect(nfc.restores, 0);
        expect(nfc.statusChecks, 0);
        expect(sync.saves, 0);
      }
    },
  );

  testWidgets(
    'roll-count writer uses one fixed kilogram and ignores hidden remainder input',
    (tester) async {
      await mount(tester);
      await chooseTemplate(tester);
      await fill(tester);
      expect(find.text('1 卷 · 1000 g'), findsOneWidget);
      expect(find.byKey(const ValueKey('rfid-initial-grams')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('mobile-registration-remnant')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rfid-initial-grams')),
        '2000',
      );
      await tester.tap(find.byKey(const ValueKey('mobile-registration-whole')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rfid-initial-grams')), findsNothing);
      await begin(tester);
      await consent(tester);
      expect(sync.initialGrams, 1000);
      expect(sync.saves, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelled late success and progress cannot alter the next write',
    (tester) async {
      nfc.cancellationCompletes = false;
      final first = Completer<RfidWriteResult>();
      nfc.pendingRestore = first;
      await mount(tester);
      await chooseTemplate(tester);
      await fill(tester);
      await begin(tester);
      await consentPending(tester);
      await tester.tap(find.text('取消等待'));
      await tester.pumpAndSettle();
      final second = Completer<RfidWriteResult>();
      nfc.pendingRestore = second;
      await begin(tester);
      await consentPending(tester);
      nfc.progressCallbacks.first?.call('awaiting_reselect');
      first.complete(success());
      await tester.pump(const Duration(milliseconds: 350));
      expect(sync.saves, 0);
      expect(nfc.restores, 2);
      expect(find.text('取消等待'), findsOneWidget);
      expect(find.text('请将标签移开，再贴回手机以验证新 UID'), findsNothing);
      second.complete(success());
      await tester.pumpAndSettle();
      expect(sync.saves, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final changeAccount in [false, true]) {
    testWidgets(
      'late success after ${changeAccount ? 'account switch' : 'leaving tab'} never registers inventory',
      (tester) async {
        nfc.cancellationCompletes = false;
        nfc.pendingRestore = Completer<RfidWriteResult>();
        await mount(tester);
        await chooseTemplate(tester);
        await fill(tester);
        await begin(tester);
        await consentPending(tester);
        await mount(
          tester,
          owner: changeAccount ? 'bob|personal' : 'alice|personal',
          isActive: changeAccount,
        );
        nfc.pendingRestore!.complete(success());
        await tester.pumpAndSettle();
        expect(sync.saves, 0);
        expect(nfc.cancels, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cancelled source read cannot save a late template result', (
    tester,
  ) async {
    nfc.pendingRead = Completer<AmsTemplateReadResult>();
    await mount(tester);
    await tester.tap(find.text('兼容标签模板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('读取源标签'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.ensureVisible(find.text('取消读取'));
    await tester.tap(find.text('取消读取'));
    await tester.pumpAndSettle();
    // A best-effort native cancel may never settle its old result future.
    // The user can still pick a saved template and perform the next write.
    await tester.ensureVisible(find.text('兼容标签模板'));
    await chooseTemplate(tester);
    await fill(tester);
    await begin(tester);
    await consent(tester);
    expect(sync.saves, 1);
    nfc.pendingRead!.complete(AmsTemplateReadSuccess(vault.template));
    await tester.pumpAndSettle();
    expect(vault.saves, 0);
    expect(sync.saves, 1);
    expect(find.text(vault.template.name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'template picker is local-only and no NFC checks until explicit read/write',
    (tester) async {
      await mount(tester);
      await chooseTemplate(tester);
      expect(nfc.statusChecks, 0);
      expect(vault.owners, ['alice|personal']);
      expect(sync.saves, 0);
      expect(find.text(vault.template.name), findsOneWidget);
      expect(find.textContaining(vault.template.uid), findsNothing);
      // Identity remains available on demand, without cluttering the form.
      await tester.tap(find.text('兼容标签模板'));
      await tester.pumpAndSettle();
      expect(find.textContaining(vault.template.uid), findsOneWidget);
      expect(nfc.statusChecks, 0);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'FUID write needs confirmation, restores original bytes and syncs only actual spool metadata',
    (tester) async {
      await mount(tester);
      await chooseTemplate(tester);
      await fill(tester);
      await begin(tester);
      expect(nfc.statusChecks, 0);
      expect(nfc.restores, 0);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认并开始写入'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('FUID'));
      await tester.pumpAndSettle();
      expect(find.textContaining('仅能修改一次'), findsOneWidget);
      await consent(tester);
      expect(nfc.targetKind, 'fuid');
      expect(nfc.restored!.blocks, vault.template.blocks);
      expect(nfc.genericWrites, 0);
      expect(sync.saves, 1);
      expect(sync.tagId, vault.template.uid);
      expect(sync.draft!.brand, '第三方品牌');
      expect(sync.draft!.model, 'PETG HF');
      expect(find.text('完整模板与 UID 已回读校验'), findsOneWidget);
      expect(find.text('AMS 兼容性待实机验证'), findsOneWidget);
    },
  );

  testWidgets('partial verification never creates inventory', (tester) async {
    nfc.verificationFails = true;
    await mount(tester);
    await chooseTemplate(tester);
    await fill(tester);
    await begin(tester);
    await consent(tester);
    expect(nfc.restores, 1);
    expect(sync.saves, 0);
    expect(find.textContaining('尚未校验通过'), findsOneWidget);
  });

  testWidgets('verified NTAG response cannot be registered as a consumable', (
    tester,
  ) async {
    nfc.returnedTagType = 'NTAG213';
    await mount(tester);
    await chooseTemplate(tester);
    await fill(tester);
    await begin(tester);
    await consent(tester);
    expect(nfc.restores, 1);
    expect(sync.saves, 0);
    expect(find.text('完整模板或真实 UID 尚未校验通过，未加入库存'), findsOneWidget);
  });

  testWidgets(
    'reading a source saves encrypted template without adding an inventory roll',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('兼容标签模板'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('读取源标签'));
      await tester.pumpAndSettle();
      expect(vault.saves, 1);
      expect(sync.saves, 0);
      expect(nfc.statusChecks, 2);
      expect(find.text(vault.template.name), findsOneWidget);
    },
  );

  testWidgets('account change clears selected local template', (tester) async {
    await mount(tester);
    await chooseTemplate(tester);
    await mount(tester, owner: 'bob|personal');
    expect(find.text('选择模板'), findsOneWidget);
    expect(find.text(vault.template.name), findsNothing);
    expect(find.textContaining(vault.template.uid), findsNothing);
    expect(nfc.statusChecks, 0);
  });

  testWidgets('account change closes the old owner template picker', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('兼容标签模板'));
    await tester.pumpAndSettle();
    expect(find.text(vault.template.name), findsOneWidget);
    await mount(tester, owner: 'bob|personal');
    expect(find.text(vault.template.name), findsNothing);
    expect(find.text('读取源标签'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inventory saving cannot be cancelled or start another card write',
    (tester) async {
      sync.pending = Completer<MobileInventorySaveResult>();
      await mount(tester);
      await chooseTemplate(tester);
      await fill(tester);
      await begin(tester);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认并开始写入'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('取消等待'), findsNothing);
      final saveButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '正在保存库存…'),
      );
      expect(saveButton.onPressed, isNull);
      expect(nfc.restores, 1);
      await mount(tester, isActive: false, settle: false);
      expect(nfc.cancels, 0);
      sync.pending!.complete(
        const MobileInventorySaveResult(inventoryUid: 'saved-roll'),
      );
      await tester.pumpAndSettle();
      expect(find.text('靠近标签并写入'), findsOneWidget);
      expect(sync.saves, 1);
    },
  );

  testWidgets(
    'leaving a kept-alive tab cancels waiting NFC without inventory',
    (tester) async {
      nfc.pendingRestore = Completer<RfidWriteResult>();
      await mount(tester);
      await chooseTemplate(tester);
      await fill(tester);
      await begin(tester);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认并开始写入'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(nfc.restores, 1);
      expect(sync.saves, 0);
      final checksBeforeHiding = nfc.statusChecks;
      await mount(tester, isActive: false);
      expect(nfc.cancels, 1);
      expect(sync.saves, 0);
      expect(nfc.statusChecks, checksBeforeHiding);
      await mount(tester);
      expect(nfc.statusChecks, checksBeforeHiding);
      expect(nfc.restores, 1);
    },
  );

  testWidgets('an inactive writer cannot start NFC even if invoked', (
    tester,
  ) async {
    await mount(tester, isActive: false);
    await tester.ensureVisible(find.text('靠近标签并写入'));
    await tester.tap(find.text('靠近标签并写入'));
    await tester.pumpAndSettle();
    expect(nfc.statusChecks, 0);
    expect(nfc.restores, 0);
    expect(nfc.genericWrites, 0);
    expect(sync.saves, 0);
  });
}
