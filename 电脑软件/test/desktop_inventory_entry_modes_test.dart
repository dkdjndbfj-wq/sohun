import 'dart:io';

import 'package:consumable_tracker_desktop/core/theme/app_curves.dart';
import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/core/theme/personal_desktop_theme.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/filament_cost_config_dao.dart';
import 'package:consumable_tracker_desktop/features/inventory/add_consumable_sheet.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/material_catalog_provider.dart';
import 'package:consumable_tracker_desktop/widgets/app_button.dart';
import 'package:consumable_tracker_desktop/widgets/app_input.dart';
import 'package:consumable_tracker_desktop/widgets/glass_card.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Future<void> open(
    WidgetTester tester, {
    Consumable? edit,
    String? farm,
    bool dark = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final theme = buildPersonalDesktopTheme(
      dark ? AppTheme.dark() : AppTheme.light(),
      personalProduct: true,
      studioMode: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          materialCatalogProvider.overrideWith((ref) async => ['PLA', 'PETG']),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: AppButton(
                  label: '新增耗材',
                  onPressed: () => AddConsumableSheet.show(
                    context,
                    edit: edit,
                    farmWorkspaceId: farm,
                    initialManufacturer: 'eSUN',
                    initialMaterial: 'PLA',
                    initialColorHex: '#82CFAE',
                    initialColorName: '薄荷绿',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新增耗材'));
    await tester.pumpAndSettle();
  }

  Finder appInput(String label) => find.descendant(
    of: find.byWidgetPredicate((w) => w is AppInput && w.label == label),
    matching: find.byType(TextField),
  );
  Future<void> enter(WidgetTester tester, Finder field, String value) async {
    await Scrollable.ensureVisible(tester.element(field), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.enterText(field, value);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester, {bool edit = false}) async {
    final button = find.widgetWithText(AppButton, edit ? '保存修改' : '保存');
    await Scrollable.ensureVisible(tester.element(button), alignment: 1);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'roll-count entry stores three distinct 1kg rolls with all parameters and existing price semantics',
    (tester) async {
      await open(tester);
      await enter(
        tester,
        find.byKey(const ValueKey('desktop-entry-roll-count')),
        '3',
      );
      await enter(tester, appInput('密度 (g/cm³)'), '1.24');
      await enter(tester, appInput('推荐温度 (℃)'), '210');
      await enter(tester, appInput('单价（元/卷）'), '88');
      await save(tester);
      await tester.runAsync(() async {
        final rows = await db.consumableDao.getPersonal();
        expect(rows, hasLength(3));
        expect(rows.map((r) => r.uid).toSet(), hasLength(3));
        expect(rows.map((r) => r.totalGrams), everyElement(1000));
        expect(rows.map((r) => r.remainingGrams), everyElement(1000));
        for (final row in rows) {
          expect(
            await db.consumableDao.isIndividualPersonalSpool(row.id),
            isTrue,
          );
          expect(await db.consumableDao.getOwnerAccount(row.id), isNull);
          final params = await db.consumableDao.getParams(row.id);
          expect(params.density, 1.24);
          expect(params.recommendedNozzleTemp, 210);
        }
        final costDao = FilamentCostConfigDao(db);
        final cost = await costDao.matchCost(
          vendor: 'eSUN',
          materialType: 'PLA',
          colorHex: '#82CFAE',
        );
        expect(cost!.costPerKg, 88);
        costDao.dispose();
      });
      await unmount(tester);
    },
  );

  testWidgets(
    'remaining entry ignores hidden roll count and records only the actual remnant intake',
    (tester) async {
      await open(tester);
      await enter(
        tester,
        find.byKey(const ValueKey('desktop-entry-roll-count')),
        '3',
      );
      final mode = find.byKey(const ValueKey('desktop-entry-remaining-mode'));
      await tester.ensureVisible(mode);
      await tester.tap(mode);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-entry-roll-count')),
        findsNothing,
      );
      await enter(tester, appInput('剩余克数（g）'), '375.5');
      await save(tester);
      await tester.runAsync(() async {
        final row = (await db.consumableDao.getPersonal()).single;
        expect(row.totalGrams, 1000);
        expect(row.remainingGrams, 375.5);
        expect(
          await db.consumableDao.isIndividualPersonalSpool(row.id),
          isTrue,
        );
      });
      await unmount(tester);
    },
  );

  testWidgets(
    'invalid roll counts are rejected without silent clamping and 100 rolls is accepted',
    (tester) async {
      await open(tester);
      for (final count in ['0', '-1', '1.5', '101', '999', '']) {
        await enter(
          tester,
          find.byKey(const ValueKey('desktop-entry-roll-count')),
          count,
        );
        await save(tester);
        expect(find.text('请输入 1 到 100 的整数卷数'), findsOneWidget);
        expect(await db.consumableDao.getPersonal(), isEmpty);
      }
      await enter(
        tester,
        find.byKey(const ValueKey('desktop-entry-roll-count')),
        '100',
      );
      await save(tester);
      expect(await db.consumableDao.getPersonal(), hasLength(100));
      await unmount(tester);
    },
  );

  testWidgets('remaining grams must be finite and inside one 1kg roll', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(
      find.byKey(const ValueKey('desktop-entry-remaining-mode')),
    );
    await tester.pumpAndSettle();
    for (final grams in ['0', '-1', '1000.1', '2000', 'NaN', 'Infinity', '']) {
      await enter(tester, appInput('剩余克数（g）'), grams);
      await save(tester);
      expect(find.text('请输入大于 0 且不超过 1000 g 的剩余克数'), findsOneWidget);
      expect(await db.consumableDao.getPersonal(), isEmpty);
    }
    await enter(tester, appInput('剩余克数（g）'), '1000');
    await save(tester);
    expect((await db.consumableDao.getPersonal()).single.remainingGrams, 1000);
    await unmount(tester);
  });

  testWidgets(
    'editing metadata does not expose entry modes or change exact existing weight',
    (tester) async {
      final id = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'eSUN',
          model: 'PLA',
          totalGrams: const Value(2000),
          remainingGrams: const Value(375.25),
        ),
      );
      final item = (await db.consumableDao.getById(id))!;
      await open(tester, edit: item);
      expect(find.text('按卷数入库'), findsNothing);
      expect(find.text('按余量入库'), findsNothing);
      expect(
        find.byKey(const ValueKey('desktop-entry-roll-count')),
        findsNothing,
      );
      await enter(tester, appInput('备注（可选）'), '只改备注');
      await save(tester, edit: true);
      final saved = (await db.consumableDao.getById(id))!;
      expect(saved.remainingGrams, 375.25);
      expect(saved.totalGrams, 2000);
      expect(saved.note, '只改备注');
      await unmount(tester);
    },
  );

  testWidgets(
    'farm entry retains aggregate stock and its existing upper limit',
    (tester) async {
      await open(tester, farm: 'farm-entry-test');
      expect(find.text('按卷数入库'), findsNothing);
      expect(find.text('按余量入库'), findsNothing);
      await enter(
        tester,
        find.byKey(const ValueKey('desktop-entry-roll-count')),
        '101',
      );
      await save(tester);
      expect(await db.consumableDao.getPersonal(), isEmpty);
      final row = (await db.consumableDao.getFarm('farm-entry-test')).single;
      expect(row.remainingGrams, 101000);
      expect(row.totalGrams, 101000);
      await unmount(tester);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'entry controls retain glass surface, AppButton and AppInput in ${dark ? 'dark' : 'light'} theme',
      (tester) async {
        await open(tester, dark: dark);
        expect(find.byType(GlassCard), findsOneWidget);
        final rolls = tester.widget<AppButton>(
          find.byKey(const ValueKey('desktop-entry-rolls-mode')),
        );
        expect(rolls.variant, AppButtonVariant.primary);
        final remaining = find.byKey(
          const ValueKey('desktop-entry-remaining-mode'),
        );
        expect(
          tester.widget<AppButton>(remaining).variant,
          AppButtonVariant.secondary,
        );
        final route = ModalRoute.of(
          tester.element(find.byType(AddConsumableSheet)),
        )!;
        expect(route.transitionDuration, AppCurves.durationModal);
        await tester.tap(remaining);
        await tester.pumpAndSettle();
        expect(
          tester.widget<AppButton>(remaining).variant,
          AppButtonVariant.primary,
        );
        expect(
          find.byKey(const ValueKey('desktop-entry-remaining-grams')),
          findsOneWidget,
        );
        expect(
          tester.widget(
            find.byKey(const ValueKey('desktop-entry-remaining-grams')),
          ),
          isA<AppInput>(),
        );
        final context = tester.element(find.byType(AddConsumableSheet));
        expect(
          Theme.of(context).brightness,
          dark ? Brightness.dark : Brightness.light,
        );
        expect(PersonalDesktopTheme.of(context), isNotNull);
        await unmount(tester);
      },
    );
  }

  testWidgets(
    'capture real desktop intake modes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(1100, 850);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(() async {
        final bytes = await File(
          'C:/Windows/Fonts/HarmonyOS_Sans_SC_Regular.ttf',
        ).readAsBytes();
        for (final family in [
          'HarmonyOS Sans',
          AppTypography.chineseFontFamily,
        ]) {
          final loader = FontLoader(family)
            ..addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
        }
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      await open(tester);
      await enter(
        tester,
        find.byKey(const ValueKey('desktop-entry-roll-count')),
        '3',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      Scrollable.of(
        tester.element(find.byKey(const ValueKey('desktop-entry-roll-count'))),
      ).position.jumpTo(0);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../../artifacts/intake-ui-20260909/desktop-rolls.png',
        ),
      );
      final remainingMode = find.byKey(
        const ValueKey('desktop-entry-remaining-mode'),
      );
      await Scrollable.ensureVisible(
        tester.element(remainingMode),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(remainingMode);
      await tester.pumpAndSettle();
      await enter(tester, appInput('剩余克数（g）'), '375');
      FocusManager.instance.primaryFocus?.unfocus();
      Scrollable.of(tester.element(appInput('剩余克数（g）'))).position.jumpTo(0);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../../artifacts/intake-ui-20260909/desktop-remaining.png',
        ),
      );
      await unmount(tester);
    },
    skip: !const bool.fromEnvironment('CAPTURE_INTAKE_UI'),
  );
}
