import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_tag_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_writer_page.dart';
import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';

class _FakeNfc implements RfidNativeBridge, RfidTagReader {
  int writes = 0, reads = 0, checks = 0;
  @override
  Future<void> cancel() async {}
  @override
  Future<bool> isAvailable() async {
    checks++;
    return true;
  }

  @override
  Future<bool> isEnabled() async {
    checks++;
    return true;
  }

  @override
  Future<RfidWriteResult> write(MobileConsumableDraft draft) async {
    writes++;
    return const RfidWriteSuccess(tagId: 'test-tag', tagType: 'NTAG213');
  }

  @override
  Future<RfidReadResult> read() async {
    reads++;
    return const RfidReadSuccess(
      draft: MobileConsumableDraft(
        brand: 'eSUN',
        model: 'PLA',
        color: Colors.blue,
        colorName: '蓝',
      ),
      tagId: 'ntag-213-1',
      tagType: 'NTAG213',
      technology: 'NFC_A_MIFARE_ULTRALIGHT',
      bytesRead: 48,
      pagesRead: 36,
    );
  }
}

class _FakeSync implements MobileInventorySync {
  MobileConsumableDraft? saved;
  @override
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) async {
    saved = draft;
    return const MobileInventorySaveResult(inventoryUid: 'fake');
  }
}

void main() {
  testWidgets('耗材模板只回填CUID/FUID资料，未选兼容模板不能调用普通NFC写入', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final repository = _TemplateRepository(database);
    addTearDown(() async {
      repository.dispose();
      await database.close();
    });
    final nfc = _FakeNfc();
    final sync = _FakeSync();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MobileRfidWriterPage(
          nfc: nfc,
          sync: sync,
          ownerAccount: 'alice@example.com|personal',
          tagRepository: repository,
          loadMaterials: () async => ['PETG HF'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('复用耗材模板'));
    await tester.pumpAndSettle();
    expect(
      repository.requestedOwners,
      everyElement('alice@example.com|personal'),
    );
    expect(find.text('eSUN · PETG HF'), findsOneWidget);
    await tester.tap(find.text('eSUN · PETG HF'));
    await tester.pumpAndSettle();
    expect(find.text('eSUN'), findsOneWidget);
    expect(find.text('PETG HF'), findsOneWidget);
    await tester.ensureVisible(find.text('靠近标签并写入'));
    await tester.tap(find.text('靠近标签并写入'));
    await tester.pumpAndSettle();
    expect(find.text('请先选择兼容标签模板'), findsOneWidget);
    expect(nfc.writes, 0);
    expect(nfc.reads, 0);
    expect(nfc.checks, 0);
    expect(sync.saved, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('审计同步失败保留待同步状态，离线保存不立即重复请求', () async {
    final sync = _AuditSync(() => throw StateError('offline'));
    expect(
      await synchronizeMobileAuditRecords(sync, syncPending: false),
      isTrue,
    );
    expect(sync.flushCount, 1);
    expect(
      await synchronizeMobileAuditRecords(sync, syncPending: true),
      isTrue,
    );
    expect(sync.flushCount, 1);
    expect(
      await synchronizeMobileAuditRecords(_FakeSync(), syncPending: false),
      isFalse,
    );
  });

  testWidgets('耗材写入默认只展示CUID/FUID流程，即使桥接还兼容旧NTAG读取接口', (tester) async {
    final nfc = _FakeNfc();
    final sync = _FakeSync();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MobileRfidWriterPage(
          nfc: nfc,
          sync: sync,
          loadMaterials: () async => ['PLA+'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CUID / FUID'), findsOneWidget);
    expect(find.byTooltip('登记帮助'), findsOneWidget);
    expect(find.text('CUID/FUID 专用 · 兼容模板与耗材映射'), findsNothing);
    expect(find.text('兼容标签模板'), findsOneWidget);
    expect(find.text('扫描已写标签'), findsNothing);
    expect(find.textContaining('NTAG213'), findsNothing);
    expect(nfc.reads, 0);
    expect(nfc.writes, 0);
    expect(nfc.checks, 0);
    expect(sync.saved, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

class _TemplateRepository extends MobileRfidTagRepository {
  _TemplateRepository(super.db);
  final requestedOwners = <String?>[];
  int recordCount = 0;

  RfidTagRecord get template => RfidTagRecord(
    tagUid: 'OLD-TEMPLATE-UID',
    tagType: 'CUID',
    profile: 'ams',
    brand: 'eSUN',
    model: 'PETG HF',
    colorHex: '#12AB34',
    colorName: '绿色',
    occurredAt: DateTime(2026, 9, 6),
  );

  @override
  Future<List<RfidTagRecord>> list({
    String? ownerAccount,
    String? tagUid,
    String? profile,
    String? operation,
    int limit = 100,
  }) async {
    requestedOwners.add(ownerAccount);
    return [template, template];
  }

  @override
  Future<List<RfidTagRecord>> listInventoryTagBindings({
    String? ownerAccount,
    int limit = 100,
  }) async {
    requestedOwners.add(ownerAccount);
    return [template];
  }

  @override
  Future<int> record(RfidTagRecord entry) async => ++recordCount;
}

class _AuditSync extends _FakeSync implements MobileInventoryAuditSync {
  _AuditSync(this.onFlush);
  final VoidCallback onFlush;
  int flushCount = 0;
  @override
  Future<void> synchronizeAuditRecords() async {
    flushCount++;
    onFlush();
  }
}
