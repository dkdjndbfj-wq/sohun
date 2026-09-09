import 'package:consumable_tracker_desktop/features/studio/farm_material_color_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('农场耗材颜色弹窗支持完整调色和任意 HEX', (tester) async {
    final hex = TextEditingController(text: '#FFFFFF');
    final name = TextEditingController();
    final mode = TextEditingController(text: 'solid');
    final secondary = TextEditingController();
    addTearDown(() {
      hex.dispose();
      name.dispose();
      mode.dispose();
      secondary.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: FarmMaterialColorField(
                hexController: hex,
                nameController: name,
                modeController: mode,
                secondaryHexController: secondary,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(FarmMaterialColorField));
    await tester.pumpAndSettle();

    expect(find.text('自由调色'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('farm-color-hue-slider')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('farm-color-saturation-slider')),
      findsOneWidget,
    );
    expect(find.text('明度'), findsNothing);

    final hexField = find.byKey(const ValueKey('farm-color-hex-field'));
    await tester.enterText(hexField, '#123456');
    await tester.tap(find.text('多色'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('farm-secondary-color-hex-field')),
      '#654321',
    );
    await tester.tap(find.text('使用此颜色'));
    await tester.pumpAndSettle();

    expect(hex.text, '#123456');
    expect(mode.text, 'multi');
    expect(secondary.text, '#654321');
    expect(tester.takeException(), isNull);
  });
}
