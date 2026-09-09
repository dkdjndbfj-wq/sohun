import 'dart:async';

import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_client.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_session_store.dart';
import 'package:consumable_tracker_desktop/providers/bambu_cloud_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('consumable_tracker/security'),
      (call) async {
        final bytes = call.arguments as Uint8List;
        return Uint8List.fromList(
          bytes.map((byte) => byte ^ 0xA5).toList(),
        );
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('consumable_tracker/security'),
      null,
    );
  });

  test('旧账号自动续登返回后不能覆盖已切换的账号', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final sessionA = _session('account-a@example.com', 'token-a');
    final sessionAAfterRelogin = _session(
      'account-a@example.com',
      'token-a-new',
    );
    final sessionB = _session('account-b@example.com', 'token-b');
    await BambuCloudSessionStore.upsertAccount(
      const BambuCloudAccount(
        region: BambuRegion.china,
        email: 'account-a@example.com',
        password: 'password-a',
      ),
    );

    final firstFetchStarted = Completer<void>();
    final allowFirstFetchToFail = Completer<void>();
    final reloginStarted = Completer<void>();
    final allowRelogin = Completer<LoginResult>();

    Future<List<BambuCloudDevice>> loadDevices(
      BambuCloudSession session,
    ) async {
      if (session.accessToken == sessionA.accessToken) {
        if (!firstFetchStarted.isCompleted) firstFetchStarted.complete();
        await allowFirstFetchToFail.future;
        throw const BambuCloudException(
          'token expired',
          category: BambuCloudErrorCategory.authentication,
        );
      }
      return const [];
    }

    Future<LoginResult> login({
      required BambuRegion region,
      required String account,
      required String password,
    }) {
      if (!reloginStarted.isCompleted) reloginStarted.complete();
      return allowRelogin.future;
    }

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        bambuCloudProvider.overrideWith(
          (ref) => BambuCloudNotifier(
            ref,
            deviceLoader: loadDevices,
            passwordLogin: login,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(bambuCloudProvider.notifier);

    final firstRequest = notifier.setActiveSession(sessionA);
    await firstFetchStarted.future;
    allowFirstFetchToFail.complete();
    await reloginStarted.future;

    final secondRequest = notifier.setActiveSession(sessionB);
    await secondRequest;
    allowRelogin.complete(LoginResult.success(sessionAAfterRelogin));
    await firstRequest;

    expect(notifier.state.session, same(sessionB));
    expect(notifier.state.devices, isEmpty);
    expect(
      (await BambuCloudSessionStore.loadSessionFor(
        sessionA.email,
        sessionA.region,
      ))
          ?.accessToken,
      sessionA.accessToken,
    );
    expect(
      (await BambuCloudSessionStore.loadSessionFor(
        sessionB.email,
        sessionB.region,
      ))
          ?.accessToken,
      sessionB.accessToken,
    );
  });

  test('切换账号后旧设备刷新不能自动选中旧设备', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final sessionA = _session('account-a@example.com', 'token-a');
    final sessionB = _session('account-b@example.com', 'token-b');
    final fetchAStarted = Completer<void>();
    final allowFetchA = Completer<void>();

    Future<List<BambuCloudDevice>> loadDevices(
      BambuCloudSession session,
    ) async {
      if (session.email == sessionA.email) {
        if (!fetchAStarted.isCompleted) fetchAStarted.complete();
        await allowFetchA.future;
        return const [
          BambuCloudDevice(
            devId: 'old-account-device',
            name: 'Old account printer',
            online: true,
            printStatus: 'IDLE',
            devModelName: 'P1S',
            devProductName: 'P1S',
            devAccessCode: '',
            nozzleDiameter: null,
          ),
        ];
      }
      return const [];
    }

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        bambuCloudProvider.overrideWith(
          (ref) => BambuCloudNotifier(
            ref,
            deviceLoader: loadDevices,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(bambuCloudProvider.notifier);

    final oldRequest = notifier.setActiveSession(sessionA);
    await fetchAStarted.future;

    // Complete the account switch before the old response is released.
    await notifier.setActiveSession(sessionB);
    allowFetchA.complete();
    await oldRequest;

    expect(notifier.state.session, same(sessionB));
    expect(notifier.state.devices, isEmpty);
    expect(container.read(activePrinterSerialProvider), isNull);
  });
}

BambuCloudSession _session(String email, String accessToken) {
  return BambuCloudSession(
    region: BambuRegion.china,
    email: email,
    accessToken: accessToken,
    username: 'u_${email.hashCode.abs()}',
    loginAt: DateTime(2026, 1, 1),
  );
}
