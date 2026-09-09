import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/features/printers/add_printer_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('X2D config separates dual external feeds and mixed AMS units',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(760, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 560,
                height: 760,
                child: AddPrinterSheet(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('X2D'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('X2D'));
    await tester.pumpAndSettle();
    expect(find.text('左右 2 个独立外挂料位'), findsOneWidget);
    expect(find.text('双外挂'), findsOneWidget);

    await tester.ensureVisible(find.text('1 组'));
    await tester.tap(find.text('1 组'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<AmsUnitType>), findsOneWidget);
    expect(find.textContaining('AMS 2 Pro'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('4 组'));
    await tester.tap(find.text('4 组'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<AmsUnitType>), findsNWidgets(4));
    expect(find.textContaining('2 个外挂 + 16 个 AMS 料位'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(AddPrinterSheet),
      matchesGoldenFile('goldens/add_printer_x2d_feed_config.png'),
    );
  });
}
