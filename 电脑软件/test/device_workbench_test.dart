import 'dart:async';
import 'dart:convert';
import 'package:consumable_tracker_desktop/core/services/device_workbench_publisher.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/device_workbench_store.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/data/models/personal_device.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/device_workbench_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/device_workbench_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<
    ({
      AppDatabase db,
      DeviceWorkbenchStore store,
      ProviderContainer container,
      DeviceTestAuth auth,
      DeviceWorkbenchController controller,
    })
  >
  start(DeviceTestApi api) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final auth = DeviceTestAuth(api);
    await auth.ready;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appAuthProvider.overrideWith((ref) => auth),
        communityApiProvider.overrideWithValue(api),
      ],
    );
    final subscription = container.listen(deviceWorkbenchProvider, (_, __) {});
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await db.close();
    });
    return (
      db: db,
      store: DeviceWorkbenchStore(db),
      container: container,
      auth: auth,
      controller: container.read(deviceWorkbenchProvider.notifier),
    );
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(done(), isTrue);
  }

  test(
    'desktop publishes only device status and freshness never treats old data as online',
    () {
      final now = DateTime.now();
      final payload = deviceStatusForWorkbench(
        FleetPrinterState(
          serial: 'private-serial',
          displayLabel: '工作台',
          connectionState: PrinterConnectionState.connected,
          lastStatus: BambuPrinterStatus(
            serial: 'private-serial',
            gcodeState: BambuGcodeState.running,
            subtaskName: '模型 A',
            gcodeFile: 'private/local/path.gcode',
            mcPercent: 42,
          ),
          statusUpdatedAt: now,
          isLanCapable: true,
          mode: BambuConnectionMode.lan,
          reportedModel: 'P1S',
          installedNozzleDiameter: 0.4,
          isConnecting: false,
        ),
      );
      expect(jsonEncode(payload), isNot(contains('private')));
      expect(payload.keys, isNot(contains('accessCode')));
      expect(payload['progress'], 42);
      expect(deviceFixture(stale: true).isFresh(now), isFalse);
      expect(deviceFixture().isFresh(now), isTrue);
    },
  );
  test(
    'device cache and maintenance remain separate from consumable inventory',
    () async {
      final app = await start(DeviceTestApi());
      await until(() => app.controller.state.refreshedAt != null);
      await app.controller.addMaintenance(
        key: deviceTestKey,
        kind: 'inspection',
        notes: '运行正常',
        performedAt: DateTime.now(),
      );
      await until(
        () =>
            app.controller.state.records.isNotEmpty &&
            !app.controller.state.records.single.pending,
      );
      expect(await app.db.select(app.db.consumables).get(), isEmpty);
      expect(
        (await app.store.devices(deviceTestOwner)).single.deviceToken,
        deviceTestToken,
      );
      expect(await app.store.devices('other-account'), isEmpty);
      expect(await app.store.maintenance('other-account'), isEmpty);
    },
  );

  test(
    'desktop sharing requires opt-in and does not carry consent to another account',
    () async {
      final api = DeviceTestApi(), auth = DeviceTestAuth(DeviceTestApi());
      await auth.ready;
      final fleet = FleetPrinterState(
        serial: 'printer-private',
        displayLabel: '工作台',
        connectionState: PrinterConnectionState.connected,
        lastStatus: BambuPrinterStatus(serial: 'printer-private'),
        statusUpdatedAt: DateTime.now(),
        isLanCapable: true,
        mode: BambuConnectionMode.lan,
        reportedModel: 'P1S',
        installedNozzleDiameter: 0.4,
        isConnecting: false,
      );
      final container = ProviderContainer(
        overrides: [
          appAuthProvider.overrideWith((ref) => auth),
          communityApiProvider.overrideWithValue(api),
          fleetPrinterStatesProvider.overrideWithValue([fleet]),
        ],
      );
      addTearDown(container.dispose);
      final publisher = container.read(
        deviceWorkbenchPublisherProvider.notifier,
      );
      await until(() => publisher.state.owner != null);
      await publisher.sync();
      expect(api.uploads, isEmpty);
      await publisher.setEnabled(true);
      expect(api.uploads, hasLength(1));
      await publisher.setEnabled(false);
      await publisher.sync();
      expect(api.uploads, hasLength(1));
      auth.switchAccount(deviceSession(id: 'bob'));
      await until(() => publisher.state.owner?.contains('|bob|') == true);
      expect(publisher.state.enabled, isFalse);
      await publisher.sync();
      expect(api.uploads, hasLength(1));
    },
  );
  test(
    'offline maintenance persists, retries the same event and is acknowledged once',
    () async {
      final api = DeviceTestApi();
      final app = await start(api);
      await until(() => app.controller.state.refreshedAt != null);
      api.offline = true;
      await app.controller.addMaintenance(
        key: deviceTestKey,
        kind: 'cleaning',
        notes: '已清洁',
        performedAt: DateTime.now(),
        nextDueAt: DateTime.now().add(const Duration(days: 30)),
      );
      await until(() => app.controller.state.error != null);
      final queued = (await app.store.maintenance(
        deviceTestOwner,
        pendingOnly: true,
      )).single;
      api.offline = false;
      await app.controller.refresh();
      await app.controller.refresh();
      expect(api.saved.keys, [queued.eventId]);
      expect(
        await app.store.maintenance(deviceTestOwner, pendingOnly: true),
        isEmpty,
      );
      expect(app.controller.state.records.single.pending, isFalse);
    },
  );
  test(
    'logout discards a delayed account response without exposing its devices',
    () async {
      final response = Completer<List<PersonalDevice>>();
      final api = DeviceTestApi()..pendingFetch = response;
      final app = await start(api);
      await until(() => api.fetches > 0);
      app.auth.switchAccount(null);
      response.complete([deviceFixture()]);
      await until(() => app.controller.state.owner == null);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(app.controller.state.devices, isEmpty);
      expect(await app.store.devices(deviceTestOwner), isEmpty);
    },
  );
  test(
    'a revoked token never falls back to cache; network failures only use this owner cache',
    () async {
      final api = DeviceTestApi();
      final app = await start(api);
      await until(() => app.controller.state.refreshedAt != null);
      api.offline = true;
      expect(
        (await app.controller.resolve(deviceTestToken)).printerKey,
        deviceTestKey,
      );
      await expectLater(
        app.controller.resolve(deviceTestToken, allowCached: false),
        throwsA(anything),
      );
      api.offline = false;
      api.denied = true;
      await expectLater(
        app.controller.resolve(deviceTestToken),
        throwsStateError,
      );
      expect(await app.store.devices(deviceTestOwner), isEmpty);
    },
  );
  test(
    'maintenance rows cannot be overwritten or assigned to an unowned device',
    () async {
      final app = await start(DeviceTestApi());
      await until(() => app.controller.state.refreshedAt != null);
      final first = DeviceMaintenanceRecord(
        eventId: 'stable-event',
        printerKey: deviceTestKey,
        kind: 'repair',
        notes: '检查',
        performedAt: DateTime.now(),
      );
      await app.store.enqueueMaintenance(deviceTestOwner, first);
      await app.store.enqueueMaintenance(deviceTestOwner, first);
      await expectLater(
        app.store.enqueueMaintenance(
          deviceTestOwner,
          DeviceMaintenanceRecord.fromJson({...first.toJson(), 'notes': '改写'}),
        ),
        throwsStateError,
      );
      await expectLater(
        app.store.enqueueMaintenance('bob', first),
        throwsStateError,
      );
      expect((await app.store.maintenance(deviceTestOwner)).length, 1);
    },
  );
  test(
    'new maintenance completion supersedes an old overdue reminder for the same category',
    () {
      final now = DateTime.now();
      DeviceMaintenanceRecord record(String id, DateTime time, DateTime? due) =>
          DeviceMaintenanceRecord(
            eventId: id,
            printerKey: deviceTestKey,
            kind: 'cleaning',
            notes: '',
            performedAt: time,
            nextDueAt: due,
          );
      final old = record(
        'old-event',
        now.subtract(const Duration(days: 60)),
        now.subtract(const Duration(days: 1)),
      );
      expect(dueDeviceMaintenance([old], now), hasLength(1));
      expect(
        dueDeviceMaintenance([old, record('new-event', now, null)], now),
        isEmpty,
      );
    },
  );
}
