import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/printer_feed_models.dart';
import 'package:consumable_tracker_desktop/features/printers/channel_slot.dart';
import 'package:consumable_tracker_desktop/features/printers/printer_card.dart';
import 'package:consumable_tracker_desktop/ui/aurora_design.dart';
import 'package:consumable_tracker_desktop/widgets/empty_state.dart';
import 'package:consumable_tracker_desktop/widgets/glass_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('玻璃空状态不会扩展成过长卡片', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmptyState(
            bambuIconName: 'scheduler',
            title: '暂无调度任务',
            useGlass: true,
          ),
        ),
      ),
    );

    final cardSize = tester.getSize(find.byType(GlassCard));
    expect(cardSize.width, lessThanOrEqualTo(480));
    expect(cardSize.height, lessThan(240));
    expect(tester.takeException(), isNull);
  });

  testWidgets('四通道完整显示且无需卡片内滚动', (tester) async {
    await _pumpPrinterCard(tester, channelCount: 4);

    expect(find.byType(ChannelSlot), findsNWidgets(4));
    expect(
      find.descendant(
        of: find.byType(PrinterCard),
        matching: find.byType(ListView),
      ),
      findsNothing,
    );
    expect(find.byTooltip('点击耗材卷配置'), findsNothing);
    expect(find.byTooltip('更多操作'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('超过四通道后使用卡片内部滚动', (tester) async {
    await _pumpPrinterCard(tester, channelCount: 5);

    expect(find.byType(ChannelSlot), findsNWidgets(5));
    expect(
      find.descendant(
        of: find.byType(PrinterCard),
        matching: find.byType(ListView),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(PrinterCard),
        matching: find.byType(Scrollbar),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('单个外挂料位保持单卡片宽度，不会拉满整行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 7, 26);
    final printer = Printer(
      id: 2,
      uid: 'external-only',
      name: '外挂打印机',
      brand: '拓竹',
      model: 'A1',
      channelCount: 1,
      isCustomImage: false,
      createdAt: now,
      updatedAt: now,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 560,
                height: 470,
                child: PrinterCard(
                  data: PrinterWithChannels(
                    printer,
                    [
                      ChannelWithConsumable(
                        PrinterChannel(
                          id: 20,
                          printerId: printer.id,
                          channelIndex: externalFeedRightChannel,
                          label: '外挂料位',
                          loadedRemainingGrams: 0,
                          updatedAt: now,
                        ),
                        null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final slotSize = tester.getSize(find.byType(ChannelSlot));
    expect(slotSize.width, lessThan(300));
    expect(slotSize.width, greaterThan(150));
    expect(tester.takeException(), isNull);
  });

  testWidgets('X1C 配置了 AMS 后不显示外挂料位', (tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 7, 26);
    final printer = Printer(
      id: 3,
      uid: 'x1c-ams',
      name: 'X1C',
      brand: '拓竹',
      model: 'X1C',
      channelCount: 5,
      isCustomImage: false,
      createdAt: now,
      updatedAt: now,
    );
    final channels = [
      for (var index = 0; index < 4; index++)
        ChannelWithConsumable(
          PrinterChannel(
            id: 30 + index,
            printerId: printer.id,
            channelIndex: index,
            label: '第 1 台 AMS · 第 ${index + 1} 通道',
            loadedRemainingGrams: 0,
            updatedAt: now,
          ),
          null,
        ),
      ChannelWithConsumable(
        PrinterChannel(
          id: 34,
          printerId: printer.id,
          channelIndex: externalFeedRightChannel,
          label: '外挂料位',
          loadedRemainingGrams: 0,
          updatedAt: now,
        ),
        null,
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 560,
                height: 470,
                child: PrinterCard(
                  data: PrinterWithChannels(printer, channels),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ChannelSlot), findsNWidgets(4));
    expect(find.text('外挂料位'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('工作台物理料位的单卷显示永不超过 1000g', (tester) async {
    await _pumpPrinterCard(
      tester,
      channelCount: 1,
      remainingGrams: 2500,
    );

    expect(find.text('1000g'), findsOneWidget);
    expect(find.text('2500g'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('Aurora 令牌跟随主题色与明暗模式', () {
    const blue = Color(0xFF1677FF);
    const pink = Color(0xFFFF4D8D);

    Aurora.applyTheme(primaryColor: blue, dark: false);
    expect(Aurora.primary, blue);
    expect(Aurora.panelStrong, const Color(0xF2FFFFFF));

    Aurora.applyTheme(primaryColor: pink, dark: true);
    expect(Aurora.primary, pink);
    expect(Aurora.text, const Color(0xFFE8ECE9));
    expect(Aurora.panelStrong, const Color(0xF22A312D));

    Aurora.applyTheme(primaryColor: const Color(0xFF00B42A), dark: false);
  });
}

Future<void> _pumpPrinterCard(
  WidgetTester tester, {
  required int channelCount,
  double? remainingGrams,
}) async {
  await tester.binding.setSurfaceSize(const Size(500, 600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final now = DateTime(2026, 7, 26);
  final printer = Printer(
    id: 1,
    uid: 'test-printer',
    name: '测试打印机',
    brand: '拓竹',
    model: 'P1S',
    channelCount: channelCount,
    isCustomImage: false,
    createdAt: now,
    updatedAt: now,
  );
  final channels = List.generate(
    channelCount,
    (index) => ChannelWithConsumable(
      PrinterChannel(
        id: index + 1,
        printerId: printer.id,
        channelIndex: index,
        label: String.fromCharCode(65 + index),
        loadedRemainingGrams: remainingGrams ?? 0,
        updatedAt: now,
      ),
      index == 0 && remainingGrams != null
          ? Consumable(
              id: 1,
              uid: 'test-consumable',
              manufacturer: '测试品牌',
              model: 'PLA',
              materialType: 'PLA',
              colorHex: '#22C55E',
              totalGrams: remainingGrams,
              remainingGrams: remainingGrams,
              createdAt: now,
              updatedAt: now,
            )
          : null,
    ),
  );

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              height: 470,
              child: PrinterCard(
                data: PrinterWithChannels(printer, channels),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
