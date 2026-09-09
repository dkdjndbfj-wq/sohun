import 'dart:io';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_visual_theme.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const outputDirectory = String.fromEnvironment(
    'INTAKE_UI_OUTPUT_DIR',
    defaultValue: '../../artifacts/intake-ui-20260909',
  );
  testWidgets(
    'capture actual mobile inventory intake modes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        final font = await File(
          const String.fromEnvironment(
            'MOBILE_UI_FONT',
            defaultValue: r'C:\Windows\Fonts\msyh.ttc',
          ),
        ).readAsBytes();
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
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            consumablesProvider.overrideWith((ref) => Stream.value(const [])),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildMobileTheme(AppTheme.light()),
            home: InteractionEffectsScope(
              enabled: false,
              child: MobileInventoryPage(
                sync: LocalMobileInventorySync(db.consumableDao),
                loadMaterials: () async => const [
                  'PLA Basic',
                  'PLA+',
                  'PETG HF',
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-add-inventory')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '品牌',
        ),
        'eSUN',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.tap(find.text('选择桌面端型号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PLA+').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('增加数量'));
      await tester.tap(find.byTooltip('增加数量'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('增加数量'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认新增 3 卷'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('$outputDirectory/mobile-rolls.png'),
      );
      await tester.ensureVisible(find.text('按余量入库'));
      await tester.tap(find.text('按余量入库'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('batch-remaining-grams')),
        '375',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.ensureVisible(find.text('确认余量入库'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('增加数量'), findsNothing);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('$outputDirectory/mobile-remaining.png'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    skip: !const bool.fromEnvironment('CAPTURE_INTAKE_UI'),
  );
}
