import 'dart:async';
import 'dart:convert';

import 'package:consumable_tracker_desktop/core/services/printer_fault_monitor.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fault_service.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fault_sync_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/printer_fault.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alice = 'https://fault.example.com|alice|personal';
const _bob = 'https://fault.example.com|bob|personal';
const _countQuota = 'printer_fault_count_quota_exceeded';
const _bytesQuota = 'printer_fault_storage_quota_exceeded';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final code in [_countQuota, _bytesQuota]) {
    test(
      '$code mixed batch preserves rejected rows and still uploads clears',
      () async {
        final api = _Api()
          ..upload = (events, _) async {
            final rejected = events.where((e) => e.eventId == 'new').toList();
            if (rejected.isNotEmpty) throw _quota(code, ['new']);
          };
        final clear = _fault(
          'old',
        ).copyWith(clearedAt: DateTime.utc(2026, 9, 6, 2));
        final app = await _start(api, rows: [clear, _fault('new')]);

        await app.service.sync();

        expect(
          api.uploads.map((batch) => batch.map((e) => e.eventId).toList()),
          [
            ['old', 'new'],
            ['old'],
          ],
        );
        expect(api.uploads.last.single.clearedAt, isNotNull);
        expect((await app.store.pending(_alice)).map((r) => r['id']), ['new']);
        expect(api.reads, 1);
        expect(
          app.container.read(printerFaultSyncStatusProvider),
          contains('配额'),
        );
      },
    );
  }

  test(
    'account-scoped SQL pages rotate past more than 100 rejected rows',
    () async {
      final api = _Api()
        ..upload = (events, _) async {
          final rejected = events
              .where((event) => event.eventId.startsWith('new-'))
              .map((event) => event.eventId)
              .toList();
          if (rejected.isNotEmpty) throw _quota(_countQuota, rejected);
        };
      final app = await _start(
        api,
        rows: [
          ...List.generate(105, (i) => _fault('new-$i')),
          _fault('late-clear').copyWith(clearedAt: DateTime.utc(2026, 9, 6, 2)),
        ],
      );
      await app.store.save('bob-printer', _fault('bob-only'), _bob);

      await app.service.sync();
      expect(api.uploads.single.length, 100);
      app.clock.advance(const Duration(seconds: 15));
      await app.service.sync();

      expect(api.uploads.length, 3);
      expect(api.uploads.last.single.eventId, 'late-clear');
      expect((await app.store.pending(_alice, limit: 200)).length, 105);
      expect((await app.store.pending(_bob)).single['id'], 'bob-only');
      expect(
        api.uploads
            .expand((batch) => batch)
            .any((e) => e.eventId == 'bob-only'),
        isFalse,
      );
      expect(api.reads, 2);
    },
  );

  test(
    'unchanged quota rows cool down, then retry successfully after capacity returns',
    () async {
      var full = true;
      final api = _Api()
        ..upload = (events, _) async {
          if (full) {
            throw _quota(_countQuota, events.map((e) => e.eventId).toList());
          }
        };
      final app = await _start(api, rows: [_fault('new')]);
      await app.service.sync();
      app.clock.advance(const Duration(seconds: 15));
      await app.service.sync();
      expect(api.uploads.length, 1);
      expect((await app.store.pending(_alice)).length, 1);

      full = false;
      app.clock.advance(const Duration(minutes: 5));
      await app.service.sync();
      expect(api.uploads.length, 2);
      expect(await app.store.pending(_alice), isEmpty);
      expect(app.container.read(printerFaultSyncStatusProvider), '已同步到手机账号');
    },
  );

  test(
    'changed lifecycle payload bypasses its old quota cooldown without losing the row',
    () async {
      final api = _Api()
        ..upload = (events, _) async {
          if (events.any((event) => event.readAt == null)) {
            throw _quota(_bytesQuota, ['old']);
          }
        };
      final app = await _start(api, rows: [_fault('old')]);
      await app.service.sync();
      await app.store.save(
        'printer',
        _fault('old').copyWith(readAt: DateTime.utc(2026, 9, 6, 2)),
        _alice,
      );
      app.clock.advance(const Duration(seconds: 15));
      await app.service.sync();

      expect(api.uploads.length, 2);
      expect(api.uploads.last.single.readAt, isNotNull);
      expect(await app.store.pending(_alice), isEmpty);
    },
  );

  test(
    'legacy quota responses have bounded splitting and repeated triggers cannot flood writes',
    () async {
      final api = _Api()..upload = (_, _) async => throw _quota(_countQuota);
      final app = await _start(
        api,
        rows: List.generate(100, (i) => _fault('new-$i')),
      );
      await app.service.sync();
      expect(api.uploads.length, 8);
      for (var i = 0; i < 5; i++) {
        await app.service.sync();
      }
      expect(api.uploads.length, 8);
      expect(api.reads, 6);
      expect((await app.store.pending(_alice)).length, 100);

      app.clock.advance(const Duration(seconds: 15));
      await app.service.sync();
      expect(api.uploads.length, lessThanOrEqualTo(16));
      expect((await app.store.pending(_alice)).length, 100);
    },
  );

  test(
    'an upload network failure still reconciles the phone read state',
    () async {
      final api = _Api()
        ..upload = (_, _) async {
          throw const CommunityApiException(
            'offline',
            category: CommunityApiErrorCategory.network,
          );
        }
        ..fetch = (_, _) async => PrinterFaultPage(
          events: [_fault('old').copyWith(readAt: DateTime.utc(2026, 9, 6, 2))],
          cursor: 1,
          hasMore: false,
        );
      final app = await _start(api, rows: [_fault('old')]);
      await app.service.sync();

      expect(api.reads, 1);
      expect(
        app.container.read(printerFaultMonitorProvider).records.single.readAt,
        isNotNull,
      );
      final pending = await app.store.pending(_alice);
      expect(jsonDecode(pending.single['payload']!)['readAt'], isNotNull);
      expect(
        app.container.read(printerFaultSyncStatusProvider),
        contains('上传待重试'),
      );
    },
  );

  test(
    'legacy quota fallback resumes after its budget instead of starving the end of a page',
    () async {
      final api = _Api()
        ..upload = (events, _) async {
          if (events.any((event) => event.eventId.startsWith('new-'))) {
            throw _quota(_countQuota);
          }
        };
      final app = await _start(
        api,
        rows: [
          ...List.generate(99, (i) => _fault('new-$i')),
          _fault('late-clear').copyWith(clearedAt: DateTime.utc(2026, 9, 6, 2)),
        ],
      );
      for (var round = 0; round < 16; round++) {
        await app.service.sync();
        app.clock.advance(const Duration(seconds: 15));
      }

      expect(
        api.uploads.any(
          (batch) => batch.length == 1 && batch.single.eventId == 'late-clear',
        ),
        isTrue,
      );
      expect((await app.store.pending(_alice)).length, 99);
      expect(api.uploads.length, lessThanOrEqualTo(16 * 8));
    },
  );

  test(
    'authentication rejection stops further requests without dropping queued rows',
    () async {
      final api = _Api()
        ..upload = (_, _) async => throw const CommunityApiException(
          'expired',
          category: CommunityApiErrorCategory.authentication,
          statusCode: 401,
        );
      final app = await _start(api, rows: [_fault('old')]);
      await app.service.sync();
      expect(api.reads, 0);
      expect((await app.store.pending(_alice)).single['id'], 'old');
    },
  );

  test(
    'logout during a rejected upload never starts quota retries or a read request',
    () async {
      final response = Completer<void>();
      final api = _Api()..upload = (_, _) => response.future;
      final app = await _start(api, rows: [_fault('new')]);
      final running = app.service.sync();
      await _settle(() => api.uploads.isNotEmpty);
      app.auth.signOut();
      response.completeError(_quota(_countQuota, ['new']));
      await running;

      expect(api.uploads.length, 1);
      expect(api.reads, 0);
      expect((await app.store.pending(_alice)).single['id'], 'new');
      expect(app.container.read(printerFaultSyncStatusProvider), isNull);
    },
  );

  test(
    'logout and login to the same account invalidates an older successful response',
    () async {
      final response = Completer<void>();
      final api = _Api()..upload = (_, _) => response.future;
      final app = await _start(api, rows: [_fault('old')]);
      final running = app.service.sync();
      await _settle(() => api.uploads.isNotEmpty);
      app.auth.signOut();
      app.auth.signIn('alice');
      response.complete();
      await running;

      expect(api.reads, 0);
      expect((await app.store.pending(_alice)).single['id'], 'old');
      expect(app.container.read(printerFaultSyncStatusProvider), isNull);
    },
  );

  test(
    'an in-flight old-account read does not mark faults or advance its cursor after switching',
    () async {
      final response = Completer<PrinterFaultPage>();
      final api = _Api()..fetch = (_, _) => response.future;
      final app = await _start(api, localRows: [_fault('old')]);
      final running = app.service.sync();
      await _settle(() => api.reads == 1);
      app.auth.signIn('bob');
      response.complete(
        PrinterFaultPage(
          events: [_fault('old').copyWith(readAt: DateTime.utc(2026, 9, 6, 2))],
          cursor: 5,
          hasMore: false,
        ),
      );
      await running;

      expect(
        app.container.read(printerFaultMonitorProvider).records.single.readAt,
        isNull,
      );
      expect(await app.store.pending(_alice), isEmpty);
      expect(await app.store.pending(_bob), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('desktop_fault_read_cursor_$_alice'), isNull);
    },
  );

  test(
    'a newer clear arriving during upload remains queued after the old payload is accepted',
    () async {
      final response = Completer<void>();
      final api = _Api()..upload = (_, _) => response.future;
      final app = await _start(api, rows: [_fault('old')]);
      final running = app.service.sync();
      await _settle(() => api.uploads.isNotEmpty);
      await app.store.save(
        'printer',
        _fault('old').copyWith(clearedAt: DateTime.utc(2026, 9, 6, 2)),
        _alice,
      );
      response.complete();
      await running;

      final pending = await app.store.pending(_alice);
      expect(pending.single['id'], 'old');
      expect(jsonDecode(pending.single['payload']!)['clearedAt'], isNotNull);
    },
  );
}

CommunityApiException _quota(String code, [List<String>? ids]) =>
    CommunityApiException(
      'quota reached',
      category: CommunityApiErrorCategory.conflict,
      statusCode: code == _countQuota ? 409 : 413,
      code: code,
      details: ids == null ? null : {'rejectedEventIds': ids},
    );

PrinterFaultRecord _fault(String id) => PrinterFaultRecord(
  eventId: id,
  printerKey: 'printer',
  printerName: '书房',
  model: 'X1C',
  code: '07004001',
  kind: 'print_error',
  severity: 'error',
  title: '打印异常',
  message: '设备测试提示',
  firstSeenAt: DateTime.utc(2026, 9, 6, 1),
  lastSeenAt: DateTime.utc(2026, 9, 6, 1),
);

class _Clock {
  DateTime now = DateTime.utc(2026, 9, 6, 3);
  void advance(Duration duration) => now = now.add(duration);
}

Future<
  ({
    ProviderContainer container,
    PrinterFaultStore store,
    PrinterFaultSyncService service,
    _Auth auth,
    _Clock clock,
  })
>
_start(
  _Api api, {
  List<PrinterFaultRecord> rows = const [],
  List<PrinterFaultRecord> localRows = const [],
}) async {
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final store = PrinterFaultStore(database);
  await store.initialize();
  for (final row in rows) {
    await store.save('printer', row, _alice);
  }
  for (final row in localRows) {
    await store.save('printer', row, null);
  }
  final auth = _Auth(api);
  await auth.ready;
  final clock = _Clock();
  final container = ProviderContainer(
    overrides: [
      appAuthProvider.overrideWith((ref) => auth),
      communityApiProvider.overrideWithValue(api),
      printerFaultStoreProvider.overrideWithValue(store),
      printerFaultMonitorProvider.overrideWith(
        (ref) => PrinterFaultMonitor(
          store: store,
          knowledge: PrinterFaultService(
            assetLoader: (_) async => '{"schemaVersion":"2","faults":[]}',
          ),
          accountKey: () => printerFaultAccountKey(ref.read(appAuthProvider)),
        ),
      ),
      printerFaultSyncServiceProvider.overrideWith((ref) {
        final service = PrinterFaultSyncService(
          ref,
          now: () => clock.now,
          autoStart: false,
        );
        ref.onDispose(service.dispose);
        return service;
      }),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  return (
    container: container,
    store: store,
    service: container.read(printerFaultSyncServiceProvider),
    auth: auth,
    clock: clock,
  );
}

Future<void> _settle(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(done(), isTrue);
}

class _Api extends Fake implements CommunityApi, PersonalPrinterFaultApi {
  final uploads = <List<PrinterFaultRecord>>[];
  int reads = 0;
  Future<void> Function(List<PrinterFaultRecord>, String)? upload;
  Future<PrinterFaultPage> Function(int, String)? fetch;

  @override
  Future<void> uploadPrinterFaults({
    required String accessToken,
    required List<PrinterFaultRecord> events,
  }) async {
    uploads.add(events);
    await upload?.call(events, accessToken);
  }

  @override
  Future<PrinterFaultPage> fetchPrinterFaults({
    required String accessToken,
    int after = 0,
  }) async {
    reads++;
    return fetch?.call(after, accessToken) ??
        PrinterFaultPage(events: [], cursor: after, hasMore: false);
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
  void signIn(String id) {
    final session = _session(id);
    state = AppAuthState(
      status: AppAuthStatus.signedIn,
      endpoint: Uri.parse(session.serverBaseUrl),
      user: session.user,
      session: session,
    );
  }
}

AppAuthSession _session(String id) {
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
    accessToken: 'access-$id',
    refreshToken: 'refresh-$id',
    expiresAt: now.add(const Duration(hours: 1)),
    refreshExpiresAt: now.add(const Duration(days: 30)),
    serverBaseUrl: 'https://fault.example.com',
  );
}

class _Sessions implements AppAuthSessionStore {
  @override
  Future<AppAuthSession?> read() async => _session('alice');
  @override
  Future<void> write(AppAuthSession session) async {}
  @override
  Future<void> clear() async {}
}
