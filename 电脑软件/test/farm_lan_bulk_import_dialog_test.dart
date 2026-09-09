import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_lan_discovery.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connection_store.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_lan_bulk_import_dialog.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('扫描结果可一次配置并批量加入本机工作台', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final store = _MemoryPrinterConnectionStore();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        printerConnectionStoreProvider.overrideWithValue(store),
        printerConnectionBambuStudioSyncEnabledProvider.overrideWithValue(
          false,
        ),
      ],
    );
    addTearDown(container.dispose);
    var trustedCount = 0;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showFarmLanBulkImportDialog(
                    context,
                    ref,
                    discover: _fakeDiscover,
                    confirmTrust: (context, configs) async {
                      trustedCount = configs.length;
                      return true;
                    },
                  ),
                  child: const Text('打开批量扫描'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开批量扫描'));
    await tester.pumpAndSettle();
    expect(find.textContaining('发现 2 台'), findsOneWidget);
    expect(find.text('批量添加 2 台'), findsOneWidget);

    final accessFields = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Access Code',
    );
    expect(accessFields, findsNWidgets(2));
    await tester.enterText(accessFields.at(0), 'CODE0001');
    await tester.enterText(accessFields.at(1), 'CODE0002');
    await tester.tap(find.text('批量添加 2 台'));
    await tester.pumpAndSettle();

    expect(trustedCount, 2);
    expect(container.read(printerConnectionListProvider), hasLength(2));
    expect(store.value, hasLength(2));
    expect(
      await container
          .read(printerDaoProvider)
          .getPrinterIdBySerial('P1S000001'),
      isNotNull,
    );
    expect(
      await container
          .read(printerDaoProvider)
          .getPrinterIdBySerial('A1M000002'),
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('扫描会等待已保存配置加载并只勾选未添加设备', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final store = _MemoryPrinterConnectionStore()
      ..value = const [
        PrinterConnectionConfig(
          serial: 'P1S000001',
          host: '192.168.1.21',
          accessCode: 'OLD00001',
          devProductName: 'P1S',
        ),
      ];
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        printerConnectionStoreProvider.overrideWithValue(store),
        printerConnectionBambuStudioSyncEnabledProvider.overrideWithValue(
          false,
        ),
      ],
    );
    addTearDown(container.dispose);
    var trustedCount = 0;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showFarmLanBulkImportDialog(
                    context,
                    ref,
                    discover: _fakeDiscover,
                    confirmTrust: (context, configs) async {
                      trustedCount = configs.length;
                      return true;
                    },
                  ),
                  child: const Text('打开批量扫描'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开批量扫描'));
    await tester.pumpAndSettle();

    expect(find.text('已添加'), findsOneWidget);
    expect(find.text('批量添加 1 台'), findsOneWidget);
    final accessField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Access Code',
    );
    expect(accessField, findsOneWidget);
    await tester.enterText(accessField, 'CODE0002');
    await tester.tap(find.text('批量添加 1 台'));
    await tester.pumpAndSettle();

    expect(trustedCount, 1);
    expect(store.value, hasLength(2));
    expect(
      store.value.map((config) => config.serial),
      containsAll(<String>['P1S000001', 'A1M000002']),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('同序列号地址变化时自动保留原配置并批量更新', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final store = _MemoryPrinterConnectionStore()
      ..value = const [
        PrinterConnectionConfig(
          serial: 'P1S000001',
          host: '192.168.1.21',
          accessCode: 'OLD00001',
          devProductName: 'P1S',
          displayName: '主力机',
          installedNozzleDiameter: 0.6,
        ),
      ];
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        printerConnectionStoreProvider.overrideWithValue(store),
        printerConnectionBambuStudioSyncEnabledProvider.overrideWithValue(
          false,
        ),
      ],
    );
    addTearDown(container.dispose);
    List<PrinterConnectionConfig> trusted = const [];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showFarmLanBulkImportDialog(
                    context,
                    ref,
                    discover: _fakeMovedPrinterDiscover,
                    confirmTrust: (context, configs) async {
                      trusted = configs.toList(growable: false);
                      return true;
                    },
                  ),
                  child: const Text('打开批量扫描'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开批量扫描'));
    await tester.pumpAndSettle();

    expect(find.text('待更新'), findsOneWidget);
    expect(find.text('批量更新 1 台'), findsOneWidget);
    final accessField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Access Code',
      ),
    );
    expect(accessField.controller?.text, 'OLD00001');

    await tester.tap(find.text('批量更新 1 台'));
    await tester.pumpAndSettle();

    expect(trusted, hasLength(1));
    expect(trusted.single.host, '192.168.1.31');
    expect(trusted.single.accessCode, 'OLD00001');
    expect(trusted.single.displayName, '主力机');
    expect(trusted.single.installedNozzleDiameter, 0.6);
    expect(store.value, hasLength(1));
    expect(store.value.single.host, '192.168.1.31');
    expect(tester.takeException(), isNull);
  });
}

Future<List<DiscoveredBambuPrinter>> _fakeDiscover({
  void Function(String phase, int progress, int total)? onProgress,
  LanScanCancellationToken? cancellationToken,
  bool forceRefresh = false,
}) async {
  onProgress?.call('正在验证 MQTT', 2, 2);
  return const [
    DiscoveredBambuPrinter(
      ip: '192.168.1.21',
      port: 8883,
      serial: 'P1S000001',
      instanceName: 'P1S-000001',
      deviceName: '一号 P1S',
    ),
    DiscoveredBambuPrinter(
      ip: '192.168.1.22',
      port: 8883,
      serial: 'A1M000002',
      instanceName: 'A1 MINI-000002',
      deviceName: '二号 A1 mini',
    ),
  ];
}

Future<List<DiscoveredBambuPrinter>> _fakeMovedPrinterDiscover({
  void Function(String phase, int progress, int total)? onProgress,
  LanScanCancellationToken? cancellationToken,
  bool forceRefresh = false,
}) async {
  return const [
    DiscoveredBambuPrinter(
      ip: '192.168.1.31',
      port: 8883,
      serial: 'P1S000001',
      instanceName: 'P1S-000001',
      deviceName: '扫描名称',
    ),
  ];
}

class _MemoryPrinterConnectionStore implements PrinterConnectionStore {
  List<PrinterConnectionConfig> value = const [];

  @override
  Future<List<PrinterConnectionConfig>> read() async => value;

  @override
  Future<void> write(List<PrinterConnectionConfig> connections) async {
    value = List.unmodifiable(connections);
  }
}
