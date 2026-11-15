import 'dart:io';
import 'dart:ui' as ui;

import 'package:consumable_tracker_desktop/widgets/app_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _iconBoundary = ValueKey('cluster-icon-boundary');
const _previewBoundary = ValueKey('cluster-icon-preview');
const _selectedColor = Color(0xFF00AA4F);

Color _idleColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFFDDE5E0)
    : const Color(0xFF4E5C54);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cluster SVG is a self-contained 24px vector asset', () async {
    final source = await rootBundle.loadString(AppIconData.cluster.path);
    final document = XmlDocument.parse(source);
    final svg = document.rootElement;
    expect(svg.name.local, 'svg');
    expect(svg.getAttribute('viewBox'), '0 0 24 24');
    expect(svg.getAttribute('width'), '24');
    expect(svg.getAttribute('height'), '24');
    expect(svg.getAttribute('stroke'), 'currentColor');
    expect(document.findAllElements('image'), isEmpty);
    expect(document.findAllElements('script'), isEmpty);
    expect(document.findAllElements('text'), isEmpty);
  });

  for (final brightness in Brightness.values) {
    for (final selected in [false, true]) {
      for (final size in [20.0, 22.0, 24.0]) {
        testWidgets(
          'cluster ${brightness.name} selected=$selected renders at ${size.toInt()}px',
          (tester) async {
            final color = selected ? _selectedColor : _idleColor(brightness);
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(brightness: brightness),
                home: Center(
                  child: RepaintBoundary(
                    key: _iconBoundary,
                    child: AppIcon(
                      AppIconData.cluster,
                      size: size,
                      color: color,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.byType(SvgPicture), findsOneWidget);
            expect(tester.getSize(find.byType(SvgPicture)), Size.square(size));
            expect(
              tester.widget<SvgPicture>(find.byType(SvgPicture)).colorFilter,
              ColorFilter.mode(color, BlendMode.srcIn),
            );
            expect(tester.takeException(), isNull);

            // Inspect rendered pixels, not only widget properties: this catches
            // missing/invalid SVG assets and ineffective currentColor tinting.
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(_iconBoundary),
            );
            await tester.runAsync(() async {
              final rendered = await boundary.toImage(pixelRatio: 2);
              try {
                final bytes = await rendered.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                );
                var opaquePixels = 0;
                final argb = color.toARGB32();
                for (
                  var offset = 0;
                  offset < bytes!.lengthInBytes;
                  offset += 4
                ) {
                  if (bytes.getUint8(offset + 3) != 255) continue;
                  opaquePixels++;
                  expect(
                    bytes.getUint8(offset),
                    closeTo((argb >> 16) & 255, 1),
                  );
                  expect(
                    bytes.getUint8(offset + 1),
                    closeTo((argb >> 8) & 255, 1),
                  );
                  expect(bytes.getUint8(offset + 2), closeTo(argb & 255, 1));
                }
                expect(opaquePixels, greaterThan(40));
              } finally {
                rendered.dispose();
              }
            });
          },
        );
      }
    }
  }

  testWidgets(
    'capture cluster navigation icon preview',
    (tester) async {
      tester.view.physicalSize = const Size(760, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: RepaintBoundary(
            key: _previewBoundary,
            child: ColoredBox(
              color: const Color(0xFFE8EDE9),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  children: [
                    Expanded(child: _previewCard(Brightness.light)),
                    const SizedBox(width: 20),
                    Expanded(child: _previewCard(Brightness.dark)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_previewBoundary),
      );
      await tester.runAsync(() async {
        final rendered = await boundary.toImage(pixelRatio: 2);
        try {
          final bytes = await rendered.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final folder = Directory('../output/mifu-ui');
          await folder.create(recursive: true);
          await File(
            '${folder.path}/cluster-navigation-icon-preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          rendered.dispose();
        }
      });
    },
    skip: !const bool.fromEnvironment('CLUSTER_ICON_CAPTURE'),
  );
}

Widget _previewCard(Brightness brightness) {
  final background = brightness == Brightness.dark
      ? const Color(0xFF202824)
      : const Color(0xFFF8FAF8);
  return DecoratedBox(
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AppIcon(AppIconData.cluster, size: 104, color: _idleColor(brightness)),
        const SizedBox(height: 30),
        for (final selected in [false, true]) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final size in [20.0, 22.0, 24.0])
                Container(
                  width: 54,
                  height: 42,
                  margin: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: selected
                        ? _selectedColor.withValues(alpha: .10)
                        : null,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: AppIcon(
                    AppIconData.cluster,
                    size: size,
                    color: selected ? _selectedColor : _idleColor(brightness),
                  ),
                ),
            ],
          ),
          if (!selected) const SizedBox(height: 6),
        ],
      ],
    ),
  );
}
