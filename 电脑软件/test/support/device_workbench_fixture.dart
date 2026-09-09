import 'dart:async';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/personal_device.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/mobile/device_tag_nfc.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:flutter_test/flutter_test.dart';

const deviceTestOwner = 'https://device.example.com|alice|personal';
const deviceTestKey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const deviceTestToken = '0123456789abcdef0123456789abcdef';
PersonalDevice deviceFixture({
  String key = deviceTestKey,
  String token = deviceTestToken,
  bool archived = false,
  bool stale = false,
}) {
  final now = DateTime.now().subtract(Duration(minutes: stale ? 5 : 0));
  return PersonalDevice(
    printerKey: key,
    deviceToken: token,
    name: '工作台 02',
    model: 'P1S',
    observedAt: now,
    receivedAt: now,
    online: true,
    state: 'running',
    taskName: '模型 A',
    progress: 42,
    remainingMinutes: 18,
    nozzleTemperature: 220,
    bedTemperature: 60,
    archived: archived,
  );
}

AppAuthSession deviceSession({
  String id = 'alice',
  String base = 'https://device.example.com',
  String? token,
}) {
  final now = DateTime.now();
  return AppAuthSession(
    user: AppUser(
      id: id,
      email: '$id@example.com',
      handle: id,
      displayName: id,
      emailVerified: true,
      createdAt: now,
      updatedAt: now,
    ),
    accessToken: token ?? '$id-access',
    refreshToken: '$id-refresh',
    expiresAt: now.add(const Duration(hours: 1)),
    refreshExpiresAt: now.add(const Duration(days: 30)),
    serverBaseUrl: base,
  );
}

class DeviceTestAuth extends AppAuthNotifier {
  DeviceTestAuth(
    CommunityApi api, {
    AppAuthSession? session,
    bool signedOut = false,
  }) : super(
         serverSettings: CommunityServerSettings(
           store: SharedPreferencesCommunityServerOverrideStore(),
           compileTimeBaseUrl:
               session?.serverBaseUrl ?? 'https://device.example.com',
         ),
         sessionStore: _Sessions(signedOut ? null : session ?? deviceSession()),
         apiFactory: (_) => api,
       );
  void switchAccount(AppAuthSession? session) => state = AppAuthState(
    status: session == null ? AppAuthStatus.signedOut : AppAuthStatus.signedIn,
    endpoint: Uri.parse(session?.serverBaseUrl ?? 'https://device.example.com'),
    session: session,
  );
}

class _Sessions implements AppAuthSessionStore {
  _Sessions(this.session);
  final AppAuthSession? session;
  @override
  Future<AppAuthSession?> read() async => session;
  @override
  Future<void> write(AppAuthSession session) async {}
  @override
  Future<void> clear() async {}
}

class DeviceTestApi extends Fake implements CommunityApi, PersonalDeviceApi {
  List<PersonalDevice> devices = [deviceFixture()];
  final Map<String, DeviceMaintenanceRecord> saved = {};
  List<DeviceMaintenanceRecord> remote = [];
  final List<List<Map<String, dynamic>>> uploads = [];
  int fetches = 0, resolves = 0, saves = 0;
  bool offline = false, denied = false;
  Completer<List<PersonalDevice>>? pendingFetch;
  void check() {
    if (offline)
      throw const CommunityApiException(
        'offline',
        category: CommunityApiErrorCategory.network,
      );
  }

  @override
  Future<List<PersonalDevice>> fetchDevices({
    required String accessToken,
  }) async {
    fetches++;
    check();
    return pendingFetch?.future ?? devices;
  }

  @override
  Future<PersonalDevice> resolveDeviceTag({
    required String accessToken,
    required String deviceToken,
  }) async {
    resolves++;
    check();
    if (denied)
      throw const CommunityApiException(
        'not found',
        statusCode: 404,
        category: CommunityApiErrorCategory.validation,
      );
    return devices.singleWhere(
      (d) => d.deviceToken == deviceToken && !d.archived,
    );
  }

  @override
  Future<DeviceMaintenancePage> fetchDeviceMaintenance({
    required String accessToken,
    required String printerKey,
    int after = 0,
  }) async {
    check();
    final records = [...remote, ...saved.values];
    return DeviceMaintenancePage(
      records.skip(after).toList(),
      records.length,
      false,
    );
  }

  @override
  Future<DeviceMaintenanceRecord> saveDeviceMaintenance({
    required String accessToken,
    required DeviceMaintenanceRecord record,
  }) async {
    saves++;
    check();
    saved[record.eventId] = record;
    return record;
  }

  @override
  Future<void> uploadDeviceStatus({
    required String accessToken,
    required List<Map<String, dynamic>> devices,
  }) async {
    check();
    uploads.add(devices);
  }

  @override
  Future<PersonalDevice> updateDevice({
    required String accessToken,
    required String printerKey,
    required Map<String, dynamic> changes,
  }) async {
    check();
    final old = devices.singleWhere((d) => d.printerKey == printerKey);
    final changed = PersonalDevice.fromJson({...old.toJson(), ...changes});
    devices = [
      for (final device in devices)
        if (device.printerKey == printerKey) changed else device,
    ];
    return changed;
  }

  @override
  Future<PersonalDevice> rotateDeviceTag({
    required String accessToken,
    required String printerKey,
  }) async => updateDevice(
    accessToken: accessToken,
    printerKey: printerKey,
    changes: {'deviceToken': 'fedcba9876543210fedcba9876543210'},
  );
}

class DeviceTestNfc implements DeviceTagNfc {
  final uriController = StreamController<String>.broadcast();
  int writes = 0, reads = 0, cancels = 0;
  String? writtenToken, pendingUri;
  Completer<DeviceTagWriteResult>? pendingWrite;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<bool> isEnabled() async => true;
  @override
  Future<DeviceTagReadResult> read() async {
    reads++;
    return const DeviceTagReadSuccess(
      deviceToken: deviceTestToken,
      uri: 'https://sohun.top/device/$deviceTestToken',
      tagId: '04AABBCCDDEEFF',
    );
  }

  @override
  Future<DeviceTagWriteResult> write(String deviceToken) async {
    writes++;
    writtenToken = deviceToken;
    return pendingWrite?.future ??
        DeviceTagWriteSuccess(
          deviceToken: deviceToken,
          uri: DeviceTagUri.forToken(deviceToken).uri,
          tagId: '04AABBCCDDEEFF',
          verified: true,
          bytesWritten: 102,
        );
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<String?> takePendingDeviceUri() async {
    final uri = pendingUri;
    pendingUri = null;
    return uri;
  }

  @override
  Stream<String> get deviceUris => uriController.stream;
  @override
  Future<void> dispose() => uriController.close();
}
