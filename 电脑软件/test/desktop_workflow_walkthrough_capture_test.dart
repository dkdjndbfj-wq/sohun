import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/print_task_dao.dart';
import 'package:consumable_tracker_desktop/features/usage/usage_log_screen.dart';
import 'package:consumable_tracker_desktop/providers/filament_cost_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_history_provider.dart';
import 'package:consumable_tracker_desktop/providers/stock_alert_provider.dart';
import 'package:consumable_tracker_desktop/providers/usage_provider.dart';
import 'package:consumable_tracker_desktop/ui/workspace_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/desktop_walkthrough_support.dart';

const _capture = bool.fromEnvironment('SOHUN_DESKTOP_GUIDE_CAPTURE');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '10 capture history filtering and task details',
    (tester) async {
      final guide = await DesktopWalkthrough.mount(
        tester,
        segment: '10-print-history',
        seed: _seedHistory,
      );
      try {
        await _startAtPrinters(guide);
        await guide.click(
          find.byKey(const ValueKey('personal-nav-history')),
          '打开打印历史',
          linger: 15,
        );
        await guide.settle();
        expect(find.text('桌面收纳架'), findsOneWidget);
        await guide.click(
          find.byKey(const ValueKey('history-status-filter-finished')),
          '筛选已完成任务',
          linger: 16,
        );
        await guide.settle();
        expect(
          guide.container.read(printHistoryFilterProvider).status,
          PrintTaskStatus.finished,
        );
        expect(find.text('灯罩原型'), findsNothing);
        await guide.click(find.text('桌面收纳架'), '查看任务详情', linger: 20);
        await guide.settle();
        expect(find.text('任务详情'), findsOneWidget);
        await guide.hold(15);
        guide.mark('任务耗材与耗时详情');
        await guide.click(find.byTooltip('关闭').last, '关闭详情');
        await guide.click(
          find.byKey(const ValueKey('history-status-filter-finished')),
          '恢复全部状态',
        );
        await guide.click(
          find.byKey(const ValueKey('print-history-range-month')),
          '查看本月记录',
          linger: 18,
        );
        await guide.settle();
        expect(
          guide.container.read(printHistoryFilterProvider).start,
          isNotNull,
        );
        await guide.finish('打印历史：筛选与查看任务详情');
      } finally {
        await guide.dispose();
      }
    },
    skip: !_capture,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    '11 capture cost estimate',
    (tester) async {
      final guide = await DesktopWalkthrough.mount(
        tester,
        segment: '11-cost-estimate',
        seed: _seedMaterials,
        overrides: [
          consumptionSummaryProvider.overrideWith(
            (ref, range) => Stream.value(
              ConsumptionSummary(
                totalGrams: range == ConsumptionRange.today ? 320 : 2400,
                totalCost: range == ConsumptionRange.today ? 22.08 : 165.60,
                rows: const [],
              ),
            ),
          ),
          consumptionTimelineProvider.overrideWith(
            (ref, range) => Stream.value([
              for (var i = 0; i < 12; i++)
                ConsumptionPoint(
                  time: DateTime.now().subtract(Duration(hours: (11 - i) * 2)),
                  grams: [
                    0,
                    0,
                    12,
                    24,
                    36,
                    20,
                    45,
                    31,
                    52,
                    40,
                    36,
                    24,
                  ][i].toDouble(),
                ),
            ]),
          ),
        ],
      );
      try {
        await _startAtPrinters(guide);
        await guide.click(
          find.byKey(const ValueKey('personal-nav-cost')),
          '打开成本试算',
          linger: 14,
        );
        await guide.type(walkthroughField('报价耗材成本 · 元/kg'), '69', '填写耗材单价');
        await guide.type(walkthroughField('每小时人工费 · 元/小时'), '2', '设置每小时人工费');
        await guide.hold(10);
        final before = tester
            .widget<Text>(find.byKey(const ValueKey('cost-scenario-total')))
            .data;
        await guide.click(
          find.byKey(const ValueKey('cost-preset-0')),
          '选择小件方案',
          linger: 18,
        );
        final small = tester
            .widget<Text>(find.byKey(const ValueKey('cost-scenario-total')))
            .data;
        expect(small, isNot(before));
        await guide.click(
          find.byKey(const ValueKey('cost-preset-2')),
          '选择长任务并比较成本',
          linger: 20,
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('cost-scenario-total')))
              .data,
          isNot(small),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getDouble('cost_quote_filament_price_per_kg'), 69);
        expect(prefs.getDouble('cost_labor_rate'), 2);
        await guide.finish('成本试算：设置单价与比较打印方案');
      } finally {
        await guide.dispose();
      }
    },
    skip: !_capture,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    '12 capture purchase basket and export',
    (tester) async {
      String? exported;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          exported = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      final guide = await DesktopWalkthrough.mount(
        tester,
        segment: '12-purchase-list',
        seed: _seedMaterials,
        overrides: [
          stockAlertsProvider.overrideWith((ref) async => _stockAlerts),
          purchaseListProvider.overrideWith((ref) async => _purchases),
        ],
      );
      try {
        await _startAtPrinters(guide);
        await guide.click(
          find.byKey(const ValueKey('personal-nav-restock')),
          '打开采购清单',
          linger: 16,
        );
        await guide.settle();
        await guide.click(find.text('清空'), '清空默认选择', linger: 12);
        await guide.click(
          find.byKey(
            ValueKey('restock-alert-basket-${_stockAlerts.first.key}'),
          ),
          '加入象牙白耗材',
          linger: 18,
        );
        await guide.click(
          find.byKey(ValueKey('restock-alert-basket-${_stockAlerts[1].key}')),
          '加入曜石黑耗材',
          linger: 18,
        );
        await guide.click(find.text('导出采购清单'), '导出已选采购清单', linger: 16);
        expect(exported, contains('共 2 项'));
        expect(exported, contains('¥690.00'));
        expect(exported, contains('象牙白'));
        expect(exported, contains('曜石黑'));
        expect(find.text('采购清单已复制到剪贴板'), findsOneWidget);
        await guide.finish(
          '采购清单：选择补货耗材与导出',
          extra: {
            'exportDestination': 'in-memory clipboard',
            'selectedRolls': 10,
          },
        );
      } finally {
        await guide.dispose();
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      }
    },
    skip: !_capture,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    '13 capture usage timeline and records',
    (tester) async {
      final guide = await DesktopWalkthrough.mount(
        tester,
        segment: '13-usage-statistics',
        seed: _seedMaterials,
        overrides: [
          usageLogsProvider.overrideWith((ref) => Stream.value(_usageLogs())),
        ],
      );
      try {
        await _startAtPrinters(guide);
        await guide.click(
          find.byKey(const ValueKey('personal-nav-statistics')),
          '打开消耗统计',
          linger: 15,
        );
        await guide.settle();
        final timeline = find.descendant(
          of: find.byType(UsageLogScreen),
          matching: find.byKey(const ValueKey('experience-timeline')),
        );
        final rect = tester.getRect(timeline);
        await guide.moveTo(
          Offset(rect.left + rect.width * 0.92, rect.center.dy),
        );
        await guide.hold(16);
        expect(
          find.byKey(const ValueKey('experience-timeline-tooltip')),
          findsOneWidget,
        );
        guide.mark('悬停查看每日用量');
        await guide.moveTo(
          Offset(rect.left + rect.width * 0.62, rect.center.dy),
        );
        await guide.hold(16);
        final list = find.descendant(
          of: find.byType(UsageLogScreen),
          matching: find.byType(CustomScrollView),
        );
        await guide.scroll(list, 440, linger: 20);
        await guide.scroll(list, -440, linger: 12);
        await guide.finish('消耗统计：每日用量与耗材时间轴');
      } finally {
        await guide.dispose();
      }
    },
    skip: !_capture,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Future<void> _startAtPrinters(DesktopWalkthrough guide) async {
  guide.container.read(workspaceNavigationRequestProvider.notifier).state =
      'printers';
  guide.preludeControls.add('打开打印机页，作为录制起点');
  await guide.settle();
  await guide.hold(10);
}

Future<void> _seedMaterials(AppDatabase db) async {
  final dao = PrinterDao(db);
  await dao.addPrinter(
    brand: 'Creality',
    model: 'K1 Max',
    channelCount: 1,
    name: '桌面工坊 01',
  );
  await dao.addPrinter(
    brand: 'Bambu Lab',
    model: 'P1S',
    channelCount: 4,
    name: '桌面工坊 02',
  );
  for (var i = 0; i < 6; i++) {
    final item = Consumable(
      id: i + 1,
      uid: 'guide-spool-${i + 1}',
      manufacturer: 'eSUN',
      model: i.isEven ? 'PLA+' : 'PETG',
      materialType: i.isEven ? 'PLA' : 'PETG',
      colorHex: [
        '#E8E9E8',
        '#343D43',
        '#12AB84',
        '#527CE5',
        '#F1CE67',
        '#E7784F',
      ][i],
      colorName: ['象牙白', '曜石黑', '薄荷绿', '海洋蓝', '奶油黄', '珊瑚橙'][i],
      totalGrams: 1000,
      remainingGrams: 820 - i * 82,
      createdAt: DateTime.now().subtract(const Duration(days: 15)),
      updatedAt: DateTime.now(),
    );
    await db.into(db.consumables).insert(item.toCompanion(true));
  }
}

Future<void> _seedHistory(AppDatabase db) async {
  await _seedMaterials(db);
  final dao = PrintTaskDao(db);
  final now = DateTime.now();
  const names = ['桌面收纳架', '线轴支架', '工具盒', '灯罩原型', '齿轮样件', '花盆底座'];
  const estimates = [148.0, 74.0, 208.0, 96.0, 42.0, 125.0];
  const actuals = [151.0, 71.0, 213.0, 58.0, 20.0, 121.0];
  const statuses = [
    PrintTaskStatus.finished,
    PrintTaskStatus.finished,
    PrintTaskStatus.finished,
    PrintTaskStatus.failed,
    PrintTaskStatus.cancelled,
    PrintTaskStatus.finished,
  ];
  for (var i = 0; i < names.length; i++) {
    final start = now.subtract(Duration(days: i * 2, hours: 4));
    await dao.create(
      PrintTask(
        uid: 'guide-history-$i',
        printerId: i.isEven ? 1 : 2,
        consumableId: i + 1,
        gcodePath: 'D:/打印项目/${names[i]}.3mf',
        taskName: names[i],
        estimatedGrams: estimates[i],
        estimatedSeconds: 3600 + i * 720,
        actualGrams: actuals[i],
        startedAt: start,
        finishedAt: start.add(Duration(seconds: 3600 + i * 720)),
        lastMcPercent: statuses[i] == PrintTaskStatus.finished ? 100 : 45,
        lastLayer: 80 + i * 12,
        status: statuses[i],
        source: 'local',
        createdAt: start,
        updatedAt: now,
      ),
    );
  }
  dao.dispose();
}

List<UsageLog> _usageLogs() => [
  for (var i = 0; i < 12; i++)
    UsageLog(
      id: i + 1,
      printerId: i.isEven ? 1 : 2,
      channelIndex: 0,
      consumableId: i % 6 + 1,
      consumedGrams: [182.0, 96.0, 245.0, 138.0, 314.0, 72.0][i % 6],
      finished: false,
      note: ['桌面收纳架', '线轴支架', '工具盒', '灯罩', '齿轮样件', '花盆底座'][i % 6],
      loggedAt: DateTime.now().subtract(Duration(days: i, hours: 1)),
    ),
];

const _stockAlerts = [
  StockAlertItem(
    manufacturer: 'eSUN',
    materialType: 'PLA',
    colorHex: '#E8E9E8',
    colorName: '象牙白',
    totalRemainingGrams: 350,
    rollCount: 1,
    lowRollCount: 0,
    costPerKg: 69,
    monthlyConsumptionGrams: 3600,
    estimatedDaysLeft: 2,
    level: StockLevel.critical,
  ),
  StockAlertItem(
    manufacturer: 'eSUN',
    materialType: 'PETG',
    colorHex: '#343D43',
    colorName: '曜石黑',
    totalRemainingGrams: 287,
    rollCount: 1,
    lowRollCount: 0,
    costPerKg: 69,
    monthlyConsumptionGrams: 1500,
    estimatedDaysLeft: 5,
    level: StockLevel.low,
  ),
];

const _purchases = [
  PurchaseSuggestion(
    manufacturer: 'eSUN',
    materialType: 'PLA',
    colorHex: '#E8E9E8',
    colorName: '象牙白',
    currentRemainingGrams: 350,
    monthlyConsumptionGrams: 3600,
    estimatedDaysLeft: 2,
    suggestedPurchaseGrams: 7000,
    suggestedRolls: 7,
    estimatedCost: 483,
    level: StockLevel.critical,
  ),
  PurchaseSuggestion(
    manufacturer: 'eSUN',
    materialType: 'PETG',
    colorHex: '#343D43',
    colorName: '曜石黑',
    currentRemainingGrams: 287,
    monthlyConsumptionGrams: 1500,
    estimatedDaysLeft: 5,
    suggestedPurchaseGrams: 3000,
    suggestedRolls: 3,
    estimatedCost: 207,
    level: StockLevel.low,
  ),
];
