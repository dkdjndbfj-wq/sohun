import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:consumable_tracker_desktop/core/services/printer_fault_monitor.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fault_service.dart';
import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/features/diagnostics/printer_fault_center.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const capture = bool.fromEnvironment('FAULT_UI_CAPTURE');
  testWidgets('fault center and popup fit desktop themes and a narrow phone', (
    tester,
  ) async {
    if (capture)
      await tester.runAsync(() async {
        final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
        for (final family in [
          AppTypography.chineseFontFamily,
          'monospace',
          'Roboto',
          'Ahem',
        ]) {
          await (FontLoader(
            family,
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    late AppDatabase db;
    late PrinterFaultMonitor monitor;
    await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      monitor = PrinterFaultMonitor(
        store: PrinterFaultStore(db),
        knowledge: PrinterFaultService(
          assetLoader: (_) async => jsonEncode({
            'faults': [
              {
                'code': '07004001',
                'kind': 'print_error',
                'source': 'bambu-official',
                'deviceTypes': ['default'],
                'summary': '检测到禁用AMS时仍从AMS加载料，请将耗材退回AMS并从料盘支架加载新料后重新发起打印。',
              },
              {
                'code': '0700210000020004',
                'kind': 'hms',
                'source': 'bambu-official',
                'deviceTypes': ['default'],
                'summary': 'AMS A 槽位2耗材可能断在工具头。',
              },
            ],
          }),
        ),
        accountKey: () => null,
      );
      await monitor.ready;
      await monitor.observe(
        serial: '094TEST',
        name: '书房 · X1 Carbon',
        model: 'X1 Carbon',
        status: BambuPrinterStatus(serial: '094TEST', printError: '07004001'),
      );
      await monitor.observe(
        serial: '31BTEST',
        name: '工作间 · X2D',
        model: 'X2D',
        status: BambuPrinterStatus(
          serial: '31BTEST',
          hmsAlerts: [
            PrinterHmsAlert.fromMqttJson({
              'attr': 0x07002100,
              'code': 0x00020004,
            })!,
          ],
        ),
      );
    });
    final boundaryKey = GlobalKey();
    final nav = GlobalKey<NavigatorState>();
    Future<void> save(String name) async {
      if (!capture) return;
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final file = File('build/fault-ui/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final dark in [false, true]) {
      tester.view.reset();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 840);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            printerFaultMonitorProvider.overrideWith((ref) => monitor),
          ],
          child: RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              navigatorKey: nav,
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              home: const Scaffold(body: Center(child: Text('个人工作台'))),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      showPrinterFaultCenter(nav.currentContext!);
      await tester.pumpAndSettle();
      expect(find.text('打印机故障中心'), findsOneWidget);
      expect(find.text('书房 · X1 Carbon'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await save('desktop-${dark ? 'dark' : 'light'}');
      nav.currentState!.pop();
      await tester.pumpAndSettle();
    }
    showPrinterFaultPopup(
      nav.currentContext!,
      monitor.state.pending.map((e) => e.eventId).toSet(),
    );
    await tester.pumpAndSettle();
    expect(find.text('知道了'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await save('popup-dark');
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(360, 780);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          home: Scaffold(
            body: SafeArea(
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    PrinterFaultCard(fault: monitor.state.records.first),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await save('phone-large-text');
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.reset();
    await tester.runAsync(db.close);
  });
}
