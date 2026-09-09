import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/features/studio/studio_plate_filament_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('single active channel keeps the multicolor area hidden',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StudioPlateFilamentSummary(
            filaments: [
              StudioPlateFilamentUsage(toolIndex: 0, grams: 12),
              StudioPlateFilamentUsage(toolIndex: 1, grams: 0),
            ],
            toolChangeCount: 0,
          ),
        ),
      ),
    );

    expect(find.text('多色打印'), findsNothing);
    expect(find.byKey(const Key('studio-multicolor-summary')), findsNothing);
  });

  testWidgets('two active channels show per-color and multiplied demand',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StudioPlateFilamentSummary(
            filaments: [
              StudioPlateFilamentUsage(
                toolIndex: 0,
                grams: 22.73,
                materialType: 'PETG',
                colorHex: '#F7D959',
                sku: 'GFG00',
                usedForObject: true,
              ),
              StudioPlateFilamentUsage(
                toolIndex: 2,
                grams: 16.24,
                materialType: 'PETG',
                colorHex: '#FFFFFF',
                usedForObject: true,
                usedForSupport: true,
              ),
            ],
            toolChangeCount: 4,
            requiredRuns: 2,
          ),
        ),
      ),
    );

    expect(find.text('多色打印'), findsOneWidget);
    expect(find.text('2 个有效通道 · 4 次换料'), findsOneWidget);
    expect(
      find.textContaining('通道 1 · PETG · 22.73 g/盘 · 共 45.46 g'),
      findsOneWidget,
    );
    expect(
      find.textContaining('通道 3 · PETG · 16.24 g/盘 · 共 32.48 g'),
      findsOneWidget,
    );
    expect(find.textContaining('模型+支撑'), findsOneWidget);
    expect(
      find.text('切片已识别多色，打印前请确认 AMS/料槽映射。'),
      findsOneWidget,
    );
  });
}
