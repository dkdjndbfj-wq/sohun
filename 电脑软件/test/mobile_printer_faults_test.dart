import 'dart:async';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/printer_fault.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_printer_faults.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const owner = 'https://fault.example.com|alice|personal';
  late List<MethodCall> nativeCalls;
  late bool allowed;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    nativeCalls = [];
    allowed = true;
    messenger.setMockMethodCallHandler(MobilePrinterFaultController.channel, (
      call,
    ) async {
      nativeCalls.add(call);
      return switch (call.method) {
        'status' => {
          'accountKey': owner,
          'enabled': true,
          'allowed': allowed,
          'expiresAt': DateTime.now()
              .add(const Duration(days: 7))
              .toIso8601String(),
        },
        'permission' || 'requestPermission' => allowed,
        'configure' || 'clear' => true,
        'takeOpenRequest' => false,
        _ => null,
      };
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(
      MobilePrinterFaultController.channel,
      null,
    ),
  );
  Future<
    ({
      ProviderContainer container,
      _Auth auth,
      MobilePrinterFaultController controller,
    })
  >
  start(_Api api) async {
    final auth = _Auth(api);
    await auth.ready;
    final container = ProviderContainer(
      overrides: [
        appAuthProvider.overrideWith((ref) => auth),
        communityApiProvider.overrideWithValue(api),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(mobilePrinterFaultProvider.notifier);
    return (container: container, auth: auth, controller: controller);
  }

  Future<void> settle(bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(done(), isTrue);
  }

  test(
    'logout drops an in-flight account response and clears background notifications',
    () async {
      final response = Completer<PrinterFaultPage>();
      final api = _Api()..fetch = (_) => response.future;
      final app = await start(api);
      await settle(() => api.requests > 0);
      app.auth.signOut();
      response.complete(
        PrinterFaultPage(events: [_fault()], cursor: 1, hasMore: false),
      );
      await settle(() => nativeCalls.any((c) => c.method == 'clear'));
      expect(app.container.read(mobilePrinterFaultProvider).records, isEmpty);
      expect(app.container.read(mobilePrinterFaultProvider).signedIn, isFalse);
      expect(nativeCalls.where((c) => c.method == 'deliver'), isEmpty);
    },
  );
  test(
    'all pages are reconciled before a cleared fault reaches native notifications',
    () async {
      final api = _Api()
        ..fetch = (after) async => after == 0
            ? PrinterFaultPage(events: [_fault()], cursor: 1, hasMore: true)
            : PrinterFaultPage(
                events: [_fault().copyWith(clearedAt: DateTime.now())],
                cursor: 2,
                hasMore: false,
              );
      final app = await start(api);
      await settle(() => nativeCalls.any((c) => c.method == 'deliver'));
      final state = app.container.read(mobilePrinterFaultProvider);
      expect(state.records.single.active, isFalse);
      expect(state.syncedAt, isNotNull);
      final delivery =
          nativeCalls.firstWhere((c) => c.method == 'deliver').arguments as Map;
      expect((delivery['events'] as List).single['clearedAt'], isNotNull);
    },
  );
  test(
    'denied notification permission never creates or enables a background lease',
    () async {
      allowed = false;
      final api = _Api();
      final app = await start(api);
      await settle(
        () => app.container.read(mobilePrinterFaultProvider).syncedAt != null,
      );
      await app.controller.setBackgroundEnabled(true);
      expect(api.leases, 0);
      expect(nativeCalls.where((c) => c.method == 'configure'), isEmpty);
      expect(
        app.container.read(mobilePrinterFaultProvider).permissionAllowed,
        isFalse,
      );
    },
  );
}

PrinterFaultRecord _fault() => PrinterFaultRecord(
  eventId: 'event-1',
  printerKey: 'printer-1',
  printerName: '书房',
  model: 'X1C',
  code: '07004001',
  kind: 'print_error',
  severity: 'error',
  title: '打印任务异常',
  message: '设备测试提示',
  firstSeenAt: DateTime.now().subtract(const Duration(minutes: 2)),
  lastSeenAt: DateTime.now(),
);

class _Api extends Fake implements CommunityApi, PersonalPrinterFaultApi {
  int requests = 0, leases = 0;
  Future<PrinterFaultPage> Function(int)? fetch;
  @override
  Future<PrinterFaultPage> fetchPrinterFaults({
    required String accessToken,
    int after = 0,
  }) async {
    requests++;
    return fetch?.call(after) ??
        const PrinterFaultPage(events: [], cursor: 0, hasMore: false);
  }

  @override
  Future<Map<String, dynamic>> createFaultMonitorLease({
    required String accessToken,
  }) async {
    leases++;
    return {};
  }
}

class _Auth extends AppAuthNotifier {
  _Auth(_Api api)
    : super(
        serverSettings: CommunityServerSettings(
          store: SharedPreferencesCommunityServerOverrideStore(),
          compileTimeBaseUrl: 'https://fault.example.com',
        ),
        sessionStore: _Sessions(),
        apiFactory: (_) => api,
      );
  void signOut() => state = AppAuthState(
    status: AppAuthStatus.signedOut,
    endpoint: Uri.parse('https://fault.example.com'),
  );
}

class _Sessions implements AppAuthSessionStore {
  @override
  Future<AppAuthSession?> read() async {
    final now = DateTime.now();
    return AppAuthSession(
      user: AppUser(
        id: 'alice',
        email: 'alice@example.com',
        handle: 'alice',
        displayName: 'Alice',
        emailVerified: true,
        createdAt: now,
        updatedAt: now,
      ),
      accessToken: 'test-access',
      refreshToken: 'test-refresh',
      expiresAt: now.add(const Duration(hours: 1)),
      refreshExpiresAt: now.add(const Duration(days: 30)),
      serverBaseUrl: 'https://fault.example.com',
    );
  }

  @override
  Future<void> write(AppAuthSession session) async {}
  @override
  Future<void> clear() async {}
}
