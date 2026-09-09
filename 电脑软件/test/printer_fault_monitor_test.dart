import 'dart:convert';
import 'dart:io';
import 'package:consumable_tracker_desktop/core/services/printer_fault_monitor.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fault_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_fault_codes.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_alerts.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const hmsCode = '0300120000020001';
  BambuPrinterStatus status(
    Map<String, dynamic> print, [
    String serial = '094TEST',
  ]) => BambuPrinterStatus.fromMqttJson({'print': print}, serial: serial)!;
  final fixture = jsonEncode({
    'schemaVersion': '2',
    'faults': [
      {
        'code': hmsCode,
        'kind': 'hms',
        'summary': '官方通用原文',
        'source': 'bambu-official',
        'deviceTypes': ['default'],
      },
      {
        'code': hmsCode,
        'kind': 'hms',
        'summary': '设备专属原文',
        'source': 'bambu-official',
        'deviceTypes': ['094'],
      },
      {
        'code': '07004001',
        'kind': 'print_error',
        'summary': '请将耗材退回 AMS',
        'source': 'bambu-official',
        'deviceTypes': ['default'],
      },
      {
        'code': '0500030000010071',
        'kind': 'hms',
        'summary': '',
        'source': 'bambu-official',
        'deviceTypes': ['default'],
      },
    ],
  });
  PrinterFaultService knowledge() =>
      PrinterFaultService(assetLoader: (_) async => fixture);

  test(
    'real MQTT attr/code words and severity follow the official protocol',
    () {
      final parsed = status({
        'hms': [
          {'attr': 0x03001200, 'code': 0x00020001},
        ],
      });
      expect(parsed.hmsAlerts!.single.code, hmsCode);
      expect(parsed.hmsAlerts!.single.severity, 'error');
      for (final level in [1, 2, 3, 4]) {
        final h = PrinterHmsAlert.fromMqttJson({
          'attr': 0x07002100,
          'code': (level << 16) | 4,
        })!;
        expect(
          h.severity,
          {1: 'error', 2: 'error', 3: 'warning', 4: 'info'}[level],
        );
      }
      expect(normalizeBambuFaultCode('HMS_0300-1200-0002-0001'), hmsCode);
    },
  );
  test(
    'print errors remain in their 8 digit namespace, with explicit zero clears',
    () {
      for (final value in [0x07004001, '117456897', '07004001', '0x07004001']) {
        expect(parseBambuPrintError(value), '07004001');
      }
      expect(parseBambuPrintError(0), '');
      expect(parseBambuPrintError(null), isNull);
      expect(parseBambuPrintError('not an error'), isNull);
      expect(parseBambuPrintError(hmsCode), isNull);
    },
  );
  test(
    'malformed HMS data cannot erase a real fault; merged clears retain known state',
    () {
      expect(
        status({
          'hms': [
            {'code': 'bad'},
          ],
        }).hmsAlerts,
        isNull,
      );
      final cleared = status({
        'hms': [
          {'attr': 0x03001200, 'code': 0x00020001},
        ],
      }).copyWith(clearHmsAlerts: true);
      expect(cleared.hmsAlerts, isNull);
      expect(cleared.hasHmsState, isTrue);
    },
  );
  test(
    'device-specific official text, internal suppression, and unknown fallback',
    () async {
      final service = knowledge();
      await service.load();
      final alerts = buildPrinterAlerts(
        status({
          'hms': [
            {'attr': 0x03001200, 'code': 0x00020001},
          ],
        }),
        knowledgeBase: service,
      );
      expect(alerts.single.message, '设备专属原文');
      expect(alerts.single.source, 'bambu-official');
      expect(alerts.single.helpUrl!.queryParameters['d'], '094');
      expect(alerts.single.steps, isEmpty);
      expect(
        buildPrinterAlerts(
          status({
            'hms': [
              {'code': '0500030000010071'},
            ],
          }),
          knowledgeBase: service,
        ),
        isEmpty,
      );
      expect(
        buildPrinterAlerts(
          status({
            'hms': [
              {'code': '9999999900020001'},
            ],
          }),
          knowledgeBase: service,
        ).single.code,
        '9999999900020001',
      );
    },
  );
  test(
    'packaged official catalog preserves namespaces, source evidence and model variants',
    () async {
      final payload =
          jsonDecode(await File(PrinterFaultService.assetPath).readAsString())
              as Map<String, dynamic>;
      expect((payload['sources'] as List).length, 8);
      expect((payload['faults'] as List).length, greaterThan(4000));
      for (final row in payload['faults'] as List) {
        expect(row['source'], 'bambu-official');
        expect((row['code'] as String).length, row['kind'] == 'hms' ? 16 : 8);
        expect(row['deviceTypes'], isNotEmpty);
      }
    },
    skip: const bool.fromEnvironment('SOHUN_CORE_BUILD') &&
            !File(PrinterFaultService.assetPath).existsSync()
        ? 'Core preview omits the imported offline catalog; fixture and online behavior tests still run.'
        : false,
  );

  group('fault lifecycle across printers and subscriptions', () {
    late AppDatabase db;
    late PrinterFaultMonitor monitor;
    String? owner;
    Future<void> observe(
      Map<String, dynamic> data, [
      String serial = '094TEST',
    ]) => monitor.observe(
      serial: serial,
      name: serial == '094TEST' ? '书房打印机' : '工作间打印机',
      status: status(data, serial),
    );
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      owner = 'server|alice|personal';
      monitor = PrinterFaultMonitor(
        store: PrinterFaultStore(db),
        knowledge: knowledge(),
        accountKey: () => owner,
      );
      await monitor.ready;
    });
    tearDown(() async {
      monitor.dispose();
      await db.close();
    });
    final two = {
      'hms': [
        {'attr': 0x03001200, 'code': 0x00020001},
      ],
      'print_error': 0x07004001,
    };
    test(
      'duplicates coalesce, missing fields keep faults, independent clears and recurrence re-alert',
      () async {
        await Future.wait([observe(two), observe(two)]);
        expect(monitor.state.active.length, 2);
        expect(monitor.state.pending.length, 2);
        final oldIds = monitor.state.active.map((r) => r.eventId).toList();
        await monitor.markRead(oldIds);
        expect(monitor.state.pending, isEmpty);
        await observe({'nozzle_temper': 210});
        expect(monitor.state.active.length, 2);
        await observe({'hms': []});
        expect(monitor.state.active.single.kind, 'print_error');
        await observe({'print_error': 0});
        expect(monitor.state.active, isEmpty);
        await observe(two);
        expect(monitor.state.pending.length, 2);
        expect(
          monitor.state.pending.map((r) => r.eventId),
          isNot(anyElement(isIn(oldIds))),
        );
      },
    );
    test(
      'two printers stay independent and outbox captures the originating account',
      () async {
        await observe(two);
        await observe(two, '31BTEST');
        await observe({'hms': [], 'print_error': 0});
        expect(monitor.state.active.length, 2);
        expect(
          monitor.state.active.every((e) => e.printerName == '工作间打印机'),
          isTrue,
        );
        expect((await monitor.store.pending(owner!)).length, 4);
        expect(await monitor.store.pending('server|bob|personal'), isEmpty);
      },
    );
    test(
      'reading does not clear; persistence survives restart and no stale popup before telemetry',
      () async {
        await observe(two);
        await monitor.markRead([monitor.state.active.first.eventId]);
        monitor.dispose();
        monitor = PrinterFaultMonitor(
          store: PrinterFaultStore(db),
          knowledge: knowledge(),
          accountKey: () => owner,
        );
        await monitor.ready;
        expect(monitor.state.active.length, 2);
        expect(monitor.state.pending, isEmpty);
        await observe(two);
        expect(monitor.state.pending.length, 1);
      },
    );
  });
}
