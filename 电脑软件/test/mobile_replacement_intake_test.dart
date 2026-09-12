import 'dart:async';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_tag_repository.dart';
import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ownerA = 'replacement-a@example.com|personal';
const _ownerB = 'replacement-b@example.com|personal';
const _tagA = '04A1B2C3';
const _tagB = '04D4E5F6';

class _RecordingSync implements MobileInventorySync {
  _RecordingSync(this.repository, this.owner, {this.pending});

  final MobileInventoryRepository repository;
  final String owner;
  final Completer<MobileInventorySaveResult>? pending;
  final calls =
      <
        ({double grams, String? tag, String? type, bool replace, String? uid})
      >[];

  @override
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) {
    calls.add((
      grams: initialGrams,
      tag: tagId,
      type: tagType,
      replace: forceNewCycle,
      uid: expectedInventoryUid,
    ));
    return pending?.future ??
        repository.addFromDraft(
          draft,
          tagUid: tagId,
          tagType: tagType,
          ownerAccount: owner,
          forceNewCycle: forceNewCycle,
          initialGrams: initialGrams,
          expectedInventoryUid: expectedInventoryUid,
        );
  }
}

class _Fixture {
  _Fixture(this.db, {Completer<MobileInventorySaveResult>? pending}) {
    syncA = _RecordingSync(
      MobileInventoryRepository(db.consumableDao),
      _ownerA,
      pending: pending,
    );
    syncB = _RecordingSync(
      MobileInventoryRepository(db.consumableDao),
      _ownerB,
    );
    tagsA = MobileRfidTagRepository(db);
    tagsB = MobileRfidTagRepository(db);
  }

  final AppDatabase db;
  final account = ValueNotifier(_ownerA);
  late final _RecordingSync syncA;
  late final _RecordingSync syncB;
  late final MobileRfidTagRepository tagsA;
  late final MobileRfidTagRepository tagsB;
  late Consumable itemA;
  late Consumable itemB;

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() {
      account.dispose();
      tagsA.dispose();
      tagsB.dispose();
    });
    await tester.runAsync(() async {
      final repository = MobileInventoryRepository(db.consumableDao);
      Future<Consumable> seed(String owner, String tag) async {
        final saved = await repository.addFromDraft(
          const MobileConsumableDraft(
            brand: 'eSUN',
            model: 'PLA',
            color: Colors.blue,
            colorName: '蓝',
          ),
          ownerAccount: owner,
          tagUid: tag,
          tagType: 'CUID',
        );
        final item = (await db.consumableDao.getPersonalByUid(
          saved.inventoryUid,
          ownerAccount: owner,
        ))!;
        await db.consumableDao.adjustGrams(item.id, 750);
        return (await db.consumableDao.getById(item.id))!;
      }

      itemA = await seed(_ownerA, _tagA);
      itemB = await seed(_ownerB, _tagB);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          personalConsumablesByOwnerProvider(
            _ownerA,
          ).overrideWith((ref) => Stream.value([itemA])),
          personalConsumablesByOwnerProvider(
            _ownerB,
          ).overrideWith((ref) => Stream.value([itemB])),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ValueListenableBuilder<String>(
            valueListenable: account,
            builder: (context, owner, child) => MobileInventoryPage(
              ownerAccount: owner,
              accountIdentity: owner,
              sync: owner == _ownerA ? syncA : syncB,
              tagRepository: owner == _ownerA ? tagsA : tagsB,
              loadMaterials: () async => const ['PLA'],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openReplacement(WidgetTester tester) async {
    await tester.tap(find.text('PLA').first);
    await tester.pumpAndSettle();
    final action = find.text('旧版标签链路：换入新卷');
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('换入新耗材卷'), findsOneWidget);
  }
}

void main() {
  late AppDatabase db;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  testWidgets('手机标签换卷整卷固定1000g，不要求输入重量且保留旧余料', (tester) async {
    final fixture = _Fixture(db);
    await fixture.mount(tester);
    await fixture.openReplacement(tester);
    expect(find.text('换入 1 卷 · 1000 g'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      findsNothing,
    );
    await tester.tap(find.text('创建新周期'));
    await tester.pumpAndSettle();
    expect(fixture.syncA.calls, [
      (
        grams: 1000.0,
        tag: _tagA,
        type: 'CUID',
        replace: true,
        uid: fixture.itemA.uid,
      ),
    ]);
    await tester.runAsync(() async {
      final history = await db.consumableDao.getPersonalRfidSpoolHistory(
        _tagA,
        ownerAccount: _ownerA,
      );
      expect(history, hasLength(2));
      final current = (await db.consumableDao.getById(
        history.first.consumableId,
      ))!;
      expect(current.totalGrams, 1000);
      expect(current.remainingGrams, 1000);
      expect(
        (await db.consumableDao.getById(fixture.itemA.id))!.remainingGrams,
        250,
      );
      expect(
        await fixture.tagsA.count(ownerAccount: _ownerA, operation: 'bind'),
        1,
      );
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('手机标签换卷余量模式只输入375g并且仅创建一个新周期', (tester) async {
    final fixture = _Fixture(db);
    await fixture.mount(tester);
    await fixture.openReplacement(tester);
    await tester.tap(find.text('按余量入库'));
    await tester.pumpAndSettle();
    final grams = find.byKey(const ValueKey('replacement-remaining-grams'));
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      findsOneWidget,
    );
    expect(find.text('换入 1 卷 · 1000 g'), findsNothing);
    await tester.enterText(grams, '375');
    await tester.tap(find.text('创建新周期'));
    await tester.pumpAndSettle();
    expect(fixture.syncA.calls, hasLength(1));
    expect(fixture.syncA.calls.single.grams, 375);
    await tester.runAsync(() async {
      final history = await db.consumableDao.getPersonalRfidSpoolHistory(
        _tagA,
        ownerAccount: _ownerA,
      );
      expect(history, hasLength(2));
      final current = (await db.consumableDao.getById(
        history.first.consumableId,
      ))!;
      expect(current.totalGrams, 1000);
      expect(current.remainingGrams, 375);
      expect(
        (await db.consumableDao.getById(fixture.itemA.id))!.remainingGrams,
        250,
      );
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('换卷保存等待中切换账号，迟到结果不写入B标签记录或显示成功', (tester) async {
    final pending = Completer<MobileInventorySaveResult>();
    final fixture = _Fixture(db, pending: pending);
    await fixture.mount(tester);
    await fixture.openReplacement(tester);
    await tester.tap(find.text('创建新周期'));
    await tester.pumpAndSettle();
    expect(fixture.syncA.calls, hasLength(1));

    fixture.account.value = _ownerB;
    await tester.pumpAndSettle();
    pending.complete(
      const MobileInventorySaveResult(
        inventoryUid: 'late-account-a-replacement',
        rfidTagUid: _tagA,
        rfidTagCycle: 2,
        createdNewCycle: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(fixture.syncB.calls, isEmpty);
    expect(find.textContaining('已创建第'), findsNothing);
    expect(find.textContaining('换卷失败'), findsNothing);
    await tester.runAsync(() async {
      expect(await fixture.tagsA.list(operation: 'bind'), isEmpty);
      expect(await fixture.tagsB.list(ownerAccount: _ownerB), isEmpty);
      expect(
        (await db.consumableDao.getById(fixture.itemB.id))!.remainingGrams,
        250,
      );
    });
    // A's pending flag must not leave B's replacement action disabled.
    await fixture.openReplacement(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
