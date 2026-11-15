import 'dart:convert';

import 'package:consumable_tracker_desktop/widgets/bambu_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const _coreBuild = bool.fromEnvironment('SOHUN_CORE_BUILD');

class _IconBundle extends CachingAssetBundle {
  _IconBundle({this.svg});
  final String? svg;
  int loads = 0;

  @override
  Future<ByteData> load(String key) {
    loads++;
    if (key.startsWith('assets/images/bambu_icons/') && svg != null) {
      return Future.value(
        ByteData.sublistView(Uint8List.fromList(utf8.encode(svg!))),
      );
    }
    throw FlutterError('Missing test icon: $key');
  }
}

Future<_IconBundle> _pumpIcon(
  WidgetTester tester,
  BambuIcon icon, {
  String? svg,
  Color themeColor = Colors.purple,
}) async {
  final bundle = _IconBundle(svg: svg);
  await tester.pumpWidget(
    DefaultAssetBundle(
      bundle: bundle,
      child: MaterialApp(
        home: IconTheme(
          data: IconThemeData(color: themeColor),
          child: Center(child: icon),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return bundle;
}

void main() {
  test('navigation and common actions retain distinct functional glyphs', () {
    expect(BambuIcon.fallbackIcon('tab_home_active'), Icons.home_outlined);
    expect(BambuIcon.fallbackIcon('printer'), Icons.print_outlined);
    expect(
      BambuIcon.fallbackIcon('tab_filament_active'),
      Icons.inventory_2_outlined,
    );
    expect(
      BambuIcon.fallbackIcon('monitor_item_cost'),
      Icons.payments_outlined,
    );
    expect(
      BambuIcon.fallbackIcon('monitor_item_prediction'),
      Icons.insights_outlined,
    );
    expect(
      BambuIcon.fallbackIcon('tab_presets_active'),
      Icons.dashboard_customize_outlined,
    );
    expect(BambuIcon.fallbackIcon('firmware_management'), Icons.memory);
    expect(BambuIcon.fallbackIcon('search'), Icons.search);
    expect(BambuIcon.fallbackIcon('settings'), Icons.settings_outlined);
    expect(BambuIcon.fallbackIcon('help'), Icons.help_outline);
  });

  testWidgets('missing status SVG preserves glyph, size and explicit color', (
    tester,
  ) async {
    await _pumpIcon(
      tester,
      const BambuIcon(name: 'warning', size: 19, color: Colors.orange),
    );
    final fallback = tester.widget<Icon>(
      find.byIcon(Icons.warning_amber_rounded),
    );
    expect(fallback.size, 19);
    expect(fallback.color, Colors.orange);
    expect(tester.getSize(find.byType(BambuIcon)), const Size.square(19));
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown missing SVG inherits icon color without error artwork', (
    tester,
  ) async {
    await _pumpIcon(tester, const BambuIcon(name: 'new-unmapped-action'));
    final fallback = tester.widget<Icon>(find.byIcon(Icons.widgets_outlined));
    expect(fallback.color, Colors.purple);
    expect(tester.takeException(), isNull);
  });

  testWidgets('color filter and fallback share the requested control color', (
    tester,
  ) async {
    await _pumpIcon(
      tester,
      const BambuIcon(
        name: 'confirm',
        color: Colors.green,
        applyColorFilter: true,
      ),
    );
    expect(tester.widget<Icon>(find.byIcon(Icons.check)).color, Colors.green);
    expect(
      tester.widget<ColorFiltered>(find.byType(ColorFiltered)).colorFilter,
      const ColorFilter.mode(Colors.green, BlendMode.srcIn),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'available SVG renders outside Core; Core skips excluded assets',
    (tester) async {
      final bundle = await _pumpIcon(
        tester,
        const BambuIcon(name: 'search', size: 31),
        svg:
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
            '<path fill="#00aa00" d="M2 2h20v20H2z"/></svg>',
      );
      if (_coreBuild) {
        expect(find.byType(SvgPicture), findsNothing);
        expect(find.byIcon(Icons.search), findsOneWidget);
        expect(bundle.loads, 0);
      } else {
        expect(find.byType(SvgPicture), findsOneWidget);
        expect(find.byType(Icon), findsNothing);
        expect(bundle.loads, 1);
      }
      expect(tester.getSize(find.byType(BambuIcon)), const Size.square(31));
      expect(tester.takeException(), isNull);
    },
  );
}
