import 'dart:async';

import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/device_workbench_store.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/personal_device.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/device_workbench_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/device_workbench_fixture.dart';

class _DelayedDeviceApi extends DeviceTestApi {
  Completer<PersonalDevice>? pendingResolve;
  Completer<void>? pendingMutation;
  Object? mutationFailure, rejectedMutation;
  int mutations = 0;

  @override
  Future<PersonalDevice> resolveDeviceTag({
    required String accessToken,
    required String deviceToken,
  }) {
    if (pendingResolve case final pending?) {
      resolves++;
      return pending.future;
    }
    return super.resolveDeviceTag(
      accessToken: accessToken,
      deviceToken: deviceToken,
    );
  }

  @override
  Future<PersonalDevice> updateDevice({
    required String accessToken,
    required String printerKey,
    required Map<String, dynamic> changes,
  }) async {
    mutations++;
    if (rejectedMutation case final failure?) throw failure;
    final result = await super.updateDevice(
      accessToken: accessToken,
      printerKey: printerKey,
      changes: changes,
    );
    await pendingMutation?.future;
    if (mutationFailure case final failure?) throw failure;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(done(), isTrue);
  }

  Future<
    ({
      DeviceWorkbenchController controller,
      DeviceWorkbenchStore store,
      DeviceTestAuth auth,
    })
  >
  start(_DelayedDeviceApi api) async {
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
    final controller = container.read(deviceWorkbenchProvider.notifier);
    await until(() => controller.state.refreshedAt != null);
    return (
      controller: controller,
      store: DeviceWorkbenchStore(db),
      auth: auth,
    );
  }

  for (final archive in [false, true]) {
    final action = archive ? 'archive' : 'rotation';
    Future<void> mutate(DeviceWorkbenchController controller) => archive
        ? controller.updateDevice(deviceTestKey, {'archived': true})
        : controller.rotateTag(deviceTestKey);

    test(
      'late refresh cannot undo $action or revive an old offline tag',
      () async {
        final api = _DelayedDeviceApi();
        final app = await start(api);
        final previous = api.devices.single;
        final pending = Completer<List<PersonalDevice>>();
        api.pendingFetch = pending;
        final refreshed = app.controller.refresh();
        await until(() => api.fetches == 2);
        await mutate(app.controller);
        api.pendingFetch = null;
        pending.complete([previous]);
        await refreshed;
        final cached = (await app.store.devices(deviceTestOwner)).single;
        expect(cached.archived, archive);
        if (!archive) expect(cached.deviceToken, isNot(deviceTestToken));
        api.offline = true;
        await expectLater(
          app.controller.resolve(deviceTestToken),
          throwsA(anything),
        );
        expect(app.controller.state.busy, isFalse);
      },
    );

    test(
      'late tag resolution cannot undo $action or revive an old offline tag',
      () async {
        final api = _DelayedDeviceApi();
        final app = await start(api);
        final previous = api.devices.single;
        final pending = Completer<PersonalDevice>();
        api.pendingResolve = pending;
        final resolved = app.controller.resolve(deviceTestToken);
        await until(() => api.resolves == 1);
        await mutate(app.controller);
        api.pendingResolve = null;
        api.offline = true;
        final rejected = expectLater(resolved, throwsStateError);
        pending.complete(previous);
        await rejected;
        final cached = (await app.store.devices(deviceTestOwner)).single;
        expect(cached.archived, archive);
        if (!archive) expect(cached.deviceToken, isNot(deviceTestToken));
        await expectLater(
          app.controller.resolve(deviceTestToken),
          throwsA(anything),
        );
      },
    );
  }

  test(
    'pending device mutation blocks conflicting writes and old cached resolution',
    () async {
      final api = _DelayedDeviceApi();
      final app = await start(api);
      final pending = Completer<void>();
      api.pendingMutation = pending;
      final rotated = app.controller.rotateTag(deviceTestKey);
      await until(() => api.mutations == 1);
      await expectLater(
        app.controller.updateDevice(deviceTestKey, {'archived': true}),
        throwsStateError,
      );
      api.offline = true;
      await expectLater(
        app.controller.resolve(deviceTestToken),
        throwsStateError,
      );
      api.offline = false;
      pending.complete();
      await rotated;
      expect(api.mutations, 1);
    },
  );

  test(
    'authoritative tag denial invalidates an older pending device list',
    () async {
      final api = _DelayedDeviceApi();
      final app = await start(api);
      final previous = api.devices.single;
      final pending = Completer<List<PersonalDevice>>();
      api.pendingFetch = pending;
      final refreshed = app.controller.refresh();
      await until(() => api.fetches == 2);
      api.denied = true;
      await expectLater(
        app.controller.resolve(deviceTestToken),
        throwsStateError,
      );
      api.pendingFetch = null;
      pending.complete([previous]);
      expect(await refreshed, isFalse);
      expect(await app.store.devices(deviceTestOwner), isEmpty);
      api.offline = true;
      await expectLater(
        app.controller.resolve(deviceTestToken),
        throwsA(anything),
      );
    },
  );

  test(
    'lost mutation response forgets old identity until online recovery',
    () async {
      final api = _DelayedDeviceApi();
      final app = await start(api);
      api.mutationFailure = const CommunityApiException(
        'response lost',
        category: CommunityApiErrorCategory.network,
      );
      await expectLater(
        app.controller.rotateTag(deviceTestKey),
        throwsA(anything),
      );
      expect(await app.store.devices(deviceTestOwner), isEmpty);
      api.offline = true;
      await expectLater(
        app.controller.resolve(deviceTestToken),
        throwsA(anything),
      );
      api.offline = false;
      api.mutationFailure = null;
      expect(await app.controller.refresh(), isTrue);
      expect(
        app.controller.state.devices.single.deviceToken,
        isNot(deviceTestToken),
      );
    },
  );

  test(
    'rejected camera validation preserves cache and permits a subsequent mutation',
    () async {
      final api = _DelayedDeviceApi();
      final app = await start(api);
      api.rejectedMutation = const CommunityApiException(
        'invalid camera URL',
        statusCode: 400,
        category: CommunityApiErrorCategory.validation,
      );
      await expectLater(
        app.controller.updateDevice(deviceTestKey, {
          'cameraUrl': 'http://invalid',
        }),
        throwsA(anything),
      );
      expect(
        (await app.store.devices(deviceTestOwner)).single.deviceToken,
        deviceTestToken,
      );
      api.rejectedMutation = null;
      await app.controller.rotateTag(deviceTestKey);
      expect(
        (await app.store.devices(deviceTestOwner)).single.deviceToken,
        isNot(deviceTestToken),
      );
    },
  );

  test(
    'old account mutation completion cannot populate the new account cache',
    () async {
      final api = _DelayedDeviceApi();
      final app = await start(api);
      final pending = Completer<void>();
      api.pendingMutation = pending;
      final rotated = app.controller.rotateTag(deviceTestKey);
      await until(() => api.mutations == 1);
      final bobDevice = deviceFixture(key: 'b' * 64, token: 'b' * 32);
      api.devices = [bobDevice];
      app.auth.switchAccount(deviceSession(id: 'bob'));
      await until(() => app.controller.state.owner?.contains('|bob|') == true);
      pending.complete();
      await rotated;
      await until(() => app.controller.state.refreshedAt != null);
      const bobOwner = 'https://device.example.com|bob|personal';
      expect(
        (await app.store.devices(bobOwner)).single.printerKey,
        bobDevice.printerKey,
      );
      expect(
        app.controller.state.devices.single.printerKey,
        bobDevice.printerKey,
      );
      // Switching back while offline must not restore the identity invalidated
      // by the already-submitted old-account mutation.
      expect(await app.store.devices(deviceTestOwner), isEmpty);
    },
  );
}
