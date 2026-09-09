import 'dart:async';

import 'package:consumable_tracker_desktop/data/database/daos/consumable_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_connector.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:consumable_tracker_desktop/providers/bambu_account_manager.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('同一打印机的并行 MQTT 连接使用不同且稳定的 Client ID', () async {
    const config = PrinterConnectionConfig(
      serial: '01P00A123456789',
      host: '192.168.1.20',
      accessCode: '12345678',
    );
    final workbench = BambuPrinterConnector(config);
    final workbenchId = workbench.mqttClientId;
    final fleet = BambuPrinterConnector(config);
    addTearDown(workbench.dispose);
    addTearDown(fleet.dispose);

    expect(workbench.mqttClientId, isNot(fleet.mqttClientId));
    expect(workbenchId, startsWith('sohun_'));
    expect(workbench.mqttClientId.length, lessThanOrEqualTo(32));
    expect(workbench.mqttClientId, workbenchId);
  });

  test('设备展示元数据刷新不重连，端点或认证变化才重连', () {
    const previous = PrinterConnectionConfig(
      serial: 'P1',
      host: '192.168.1.20',
      accessCode: '12345678',
      displayName: '旧名称',
      devProductName: 'P1S',
      installedNozzleDiameter: 0.4,
    );
    const metadataOnly = PrinterConnectionConfig(
      serial: 'P1',
      host: '192.168.1.20',
      accessCode: '12345678',
      displayName: '新名称',
      devProductName: 'P1S New',
      installedNozzleDiameter: 0.6,
    );
    const newCredential = PrinterConnectionConfig(
      serial: 'P1',
      host: '192.168.1.20',
      accessCode: '87654321',
    );

    expect(
      printerConnectionEndpointChanged(previous, metadataOnly),
      isFalse,
    );
    expect(
      printerConnectionEndpointChanged(previous, newCredential),
      isTrue,
    );
  });

  test('同一打印机的云端与局域网配置按明确模式选择且互不转换', () {
    const lan = PrinterConnectionConfig(
      serial: 'DUAL-MODE-1',
      host: '192.168.1.20',
      accessCode: '12345678',
      mode: BambuConnectionMode.lan,
    );
    final cloud = PrinterConnectionConfig.cloud(
      serial: 'DUAL-MODE-1',
      devProductName: 'A1',
    );

    final lanSelected = selectEffectivePrinterConnections(
      lanConfigs: const [lan],
      cloudConfigs: [cloud],
      selectedModes: const {'DUAL-MODE-1': BambuConnectionMode.lan},
    );
    final cloudSelected = selectEffectivePrinterConnections(
      lanConfigs: const [lan],
      cloudConfigs: [cloud],
      selectedModes: const {'DUAL-MODE-1': BambuConnectionMode.cloud},
    );

    expect(lanSelected.single.mode, BambuConnectionMode.lan);
    expect(lanSelected.single.host, '192.168.1.20');
    expect(cloudSelected.single.mode, BambuConnectionMode.cloud);
    expect(cloudSelected.single.host, isEmpty);
    expect(cloudSelected.single.accessCode, isEmpty);
  });

  test('云端 MQTT/视频凭据按设备归属账号选择，不随 active account 串线', () {
    final ownerSession = BambuCloudSession(
      region: BambuRegion.china,
      email: 'owner@example.com',
      accessToken: 'owner-token',
      username: 'u_owner',
      loginAt: DateTime(2026, 1, 1),
    );
    final activeSession = BambuCloudSession(
      region: BambuRegion.china,
      email: 'active@example.com',
      accessToken: 'active-token',
      username: 'u_active',
      loginAt: DateTime(2026, 1, 1),
    );
    final state = BambuAccountManagerState(
      sessions: {
        'owner@example.com|China': ownerSession,
        'active@example.com|China': activeSession,
      },
      activeAccountEmail: activeSession.email,
      activeRegion: activeSession.region,
    );

    expect(
      cloudSessionForPrinterSerial(
        serial: 'OWNER-PRINTER',
        ownerMap: const {'OWNER-PRINTER': 'owner@example.com|China'},
        accountState: state,
      ),
      same(ownerSession),
    );
    expect(
      cloudSessionForPrinterSerial(
        serial: 'UNKNOWN-PRINTER',
        ownerMap: const {},
        accountState: state,
      ),
      isNull,
    );
  });

  test('异步恢复模式偏好不会覆盖用户刚选择的模式', () async {
    SharedPreferences.setMockInitialValues({
      'printer_connection_mode_selection_v1': '{"RACE":"cloud"}',
    });
    final notifier = PrinterConnectionModeSelectionNotifier();
    addTearDown(notifier.dispose);

    await notifier.select('RACE', BambuConnectionMode.lan);
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state['RACE'], BambuConnectionMode.lan);
  });

  test('调速指令发送 1..4 档位而不是显示倍率', () {
    final payload = buildPrintSpeedPayload(
      profileLevel: BambuSpeedProfile.sport.level,
      sequenceId: '27',
    );

    expect(payload['print'], {
      'sequence_id': '27',
      'command': 'print_speed',
      'param': '3',
    });
    expect(
      () => buildPrintSpeedPayload(profileLevel: 125, sequenceId: '28'),
      throwsArgumentError,
    );
  });

  test('速度档位优先读取 spd_lvl，并兼容旧固件仅上报倍率', () {
    expect(
      BambuSpeedProfile.fromTelemetry(level: 4, multiplier: 100),
      BambuSpeedProfile.ludicrous,
    );
    expect(
      BambuSpeedProfile.fromTelemetry(multiplier: 124),
      BambuSpeedProfile.sport,
    );
  });

  test('设备聚合列表暂时为空时不会清除活跃打印机', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        mergedPrinterListProvider.overrideWith((ref) => const []),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(activePrinterSerialProvider.notifier)
        .set('SERIAL-STABLE');
    expect(container.read(activePrinterConfigProvider), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(activePrinterSerialProvider), 'SERIAL-STABLE');
  });

  test('相同云设备重复同步不会改 updatedAt 或触发无效写入', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    const device = BambuCloudDevice(
      devId: 'CLOUD-STABLE',
      name: '工作机',
      online: true,
      printStatus: 'RUNNING',
      devModelName: 'N/A',
      devProductName: 'P1S',
      devAccessCode: '',
      nozzleDiameter: 0.4,
    );

    await db.printerDao.upsertCloudDevice(device);
    final id = await db.printerDao.getPrinterIdBySerial(device.devId);
    final before = (await db.printerDao.getByIdWithChannels(id!))!.printer;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.printerDao.upsertCloudDevice(device);
    final after = (await db.printerDao.getByIdWithChannels(id))!.printer;

    expect(after.updatedAt, before.updatedAt);
  });

  test('RFID 物理卷解绑其他槽位后 updatedAt 仍按 Drift 秒存储', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final printerId = await db.printerDao.addPrinter(
      brand: 'Test',
      model: 'Two slots',
      channelCount: 2,
    );
    final consumableId = await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'Test',
        model: 'PLA',
      ),
    );
    final channels = (await db.printerDao.getByIdWithChannels(printerId))!
        .channels
        .map((entry) => entry.channel)
        .toList();
    await db.printerDao.bindConsumable(channels[0].id, consumableId);

    await db.printerDao.bindSpoolReplacement(
      printerId: printerId,
      channelIndex: 1,
      consumableId: consumableId,
      uniquePhysicalSpool: true,
    );

    final updated = (await db.printerDao.getByIdWithChannels(printerId))!
        .channels
        .first
        .channel
        .updatedAt;
    expect(updated.year, inInclusiveRange(2025, 2035));
  });

  test('云设备事实不变时刷新结果可复用，在线状态变化才触发更新', () {
    const device = BambuCloudDevice(
      devId: 'CLOUD-STABLE',
      name: '工作机',
      online: true,
      printStatus: 'RUNNING',
      devModelName: 'N/A',
      devProductName: 'P1S',
      devAccessCode: '',
      nozzleDiameter: 0.4,
    );

    expect(cloudDeviceListsEquivalent(const [device], const [device]), isTrue);
    expect(
      cloudDeviceListsEquivalent(
        const [device],
        [device.copyWith(online: false)],
      ),
      isFalse,
    );
  });

  test(
      'dashboard printer facts ignore gram ticks but keep active-boundary changes',
      () async {
    final now = DateTime(2026, 8, 3);
    final printer = Printer(
      id: 1,
      uid: 'printer-1',
      name: 'Workbench',
      brand: 'Bambu Lab',
      model: 'P1S',
      channelCount: 1,
      isCustomImage: false,
      createdAt: now,
      updatedAt: now,
    );
    Consumable spool() => Consumable(
          id: 1,
          uid: 'spool-1',
          manufacturer: 'Bambu Lab',
          model: 'PLA Basic',
          materialType: 'PLA',
          colorHex: '#00AE42',
          totalGrams: 1000,
          remainingGrams: 0,
          createdAt: now,
          updatedAt: now,
        );
    PrinterWithChannels snapshot(double loadedRemainingGrams) =>
        PrinterWithChannels(
          printer,
          [
            ChannelWithConsumable(
              PrinterChannel(
                id: 1,
                printerId: 1,
                channelIndex: 0,
                label: 'A',
                consumableId: 1,
                loadedRemainingGrams: loadedRemainingGrams,
                updatedAt: now,
              ),
              spool(),
            ),
          ],
          serial: 'SERIAL-1',
        );
    DashboardPrinterSummary summary(double loadedRemainingGrams) =>
        DashboardPrinterSummary.from(snapshot(loadedRemainingGrams));

    expect(summary(900), summary(899.2));
    expect(summary(899.2), isNot(summary(0)));

    final stream = StreamController<List<PrinterWithChannels>>();
    final container = ProviderContainer(
      overrides: [
        printersWithChannelsProvider.overrideWith((ref) => stream.stream),
      ],
    );
    addTearDown(stream.close);
    addTearDown(container.dispose);
    final notifications = <DashboardPrinterListState>[];
    final subscription = container.listen(
      dashboardPrinterListProvider.select((state) => state),
      (_, next) => notifications.add(next),
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    stream.add([snapshot(900)]);
    await pumpEventQueue();
    final stableNotificationCount = notifications.length;

    stream.add([snapshot(899.2)]);
    await pumpEventQueue();
    expect(notifications.length, stableNotificationCount);

    stream.add([snapshot(0)]);
    await pumpEventQueue();
    expect(notifications.length, stableNotificationCount + 1);
  });

  test('物理料位每次最多占用一卷且不能超过库存卷数', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final printerId = await db.printerDao.addPrinter(
      brand: 'Test',
      model: 'Three slots',
      channelCount: 3,
    );
    final consumableId = await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'Test',
        model: 'PLA',
        remainingGrams: const Value(1500),
        totalGrams: const Value(1500),
      ),
    );
    final printer = (await db.printerDao.getByIdWithChannels(printerId))!;

    await db.printerDao.bindConsumable(
      printer.channels[0].channel.id,
      consumableId,
    );
    await db.printerDao.bindConsumable(
      printer.channels[1].channel.id,
      consumableId,
    );
    await expectLater(
      db.printerDao.bindConsumable(
        printer.channels[2].channel.id,
        consumableId,
      ),
      throwsA(isA<StateError>()),
    );

    expect(inventoryRollCount(1500), 2);
    expect(singleRollAvailableGrams(1500), 1000);
    expect(
      singleRollAvailableGrams(1500, alreadyBoundRolls: 1),
      500,
    );
  });

  test('RFID 异常上报也不能把单卷写成超过 1000g', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'Bambu',
        model: 'PLA',
      ),
    );

    await db.consumableDao.updateRfidSync(
      consumableId: id,
      remainingGrams: 1450,
    );

    expect((await db.consumableDao.getById(id))!.remainingGrams, 1000);
  });
}
