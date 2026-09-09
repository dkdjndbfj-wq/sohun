import 'dart:convert';
import 'dart:io';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/mobile/device_tag_nfc.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/device_workbench_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../support/device_workbench_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real HTTP: desktop status, device tag, two phone ledgers, revoked and foreign tokens',
    () => HttpOverrides.runWithHttpOverrides(() async {
      SharedPreferences.setMockInitialValues({});
      final server = await Process.start('node', [
        'test/fixtures/personal_inventory_http_server.mjs',
      ]);
      final errors = StringBuffer();
      final stderr = server.stderr.transform(utf8.decoder).listen(errors.write);
      addTearDown(() async {
        try {
          server.stdin.writeln('stop');
          await server.stdin.flush();
        } on IOException {
          /* A startup failure already closed the pipe. */
        }
        final exit = await server.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            server.kill();
            return -1;
          },
        );
        await stderr.cancel();
        expect(exit, 0, reason: errors.toString());
      });
      final base = await server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 20))
          .catchError(
            (Object error) => throw StateError('本地设备测试服务未启动：$error\n$errors'),
          );
      final httpClient = http.Client();
      addTearDown(httpClient.close);
      final api = CommunityApiClient(
        baseUri: Uri.parse(base),
        httpClient: httpClient,
      );
      Future<AppAuthSession> register(String name) async {
        final response = await httpClient.post(
          Uri.parse('$base/v1/auth/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': '$name@example.com',
            'handle': name,
            'displayName': name,
            'password': 'StrongPass123!',
            'acceptTerms': true,
            'termsVersion': '2026-07-29',
            'privacyVersion': '2026-07-29',
          }),
        );
        expect(response.statusCode, 201, reason: response.body);
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return AppAuthSession(
          user: AppUser.fromJson(data['user'] as Map<String, dynamic>),
          accessToken: data['accessToken'] as String,
          refreshToken: data['refreshToken'] as String,
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          serverBaseUrl: base,
        );
      }

      final alice = await register('device_alice'),
          bob = await register('device_bob');
      await api.uploadDeviceStatus(
        accessToken: alice.accessToken,
        devices: [
          {
            'printerKey': deviceTestKey,
            'name': '工作台 02',
            'model': 'P1S',
            'online': true,
            'state': 'running',
            'progress': 42,
            'remainingMinutes': 18,
            'nozzleTemperature': 220,
            'bedTemperature': 60,
            'taskName': '模型 A',
            'observedAt': DateTime.now().toUtc().toIso8601String(),
          },
        ],
      );
      final device = (await api.fetchDevices(
        accessToken: alice.accessToken,
      )).single;
      final link = DeviceTagUri.forToken(device.deviceToken);
      expect(DeviceTagUri.parse(link.uri)!.token, device.deviceToken);
      Future<
        ({
          ProviderContainer container,
          AppDatabase db,
          DeviceWorkbenchController controller,
        })
      >
      phone() async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final auth = DeviceTestAuth(api, session: alice);
        await auth.ready;
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            communityApiProvider.overrideWithValue(api),
            appAuthProvider.overrideWith((ref) => auth),
          ],
        );
        final sub = container.listen(deviceWorkbenchProvider, (_, __) {});
        addTearDown(() async {
          sub.close();
          container.dispose();
          await db.close();
        });
        return (
          container: container,
          db: db,
          controller: container.read(deviceWorkbenchProvider.notifier),
        );
      }

      Future<void> until(bool Function() done, String Function() reason) async {
        for (var i = 0; i < 200 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(done(), isTrue, reason: reason());
      }

      final first = await phone();
      await until(
        () => first.controller.state.refreshedAt != null,
        () => '首台手机设备同步：${first.controller.state.error}',
      );
      expect(
        (await first.controller.resolve(link.token)).printerKey,
        deviceTestKey,
      );
      await first.controller.addMaintenance(
        key: deviceTestKey,
        kind: 'lubrication',
        notes: '导轨已润滑',
        performedAt: DateTime.now(),
        nextDueAt: DateTime.now().add(const Duration(days: 30)),
      );
      await until(
        () =>
            first.controller.state.records.isNotEmpty &&
            !first.controller.state.records.single.pending,
        () =>
            '维护上传：${first.controller.state.error}，pending=${first.controller.state.records.map((r) => r.pending).toList()}',
      );
      final second = await phone();
      await until(
        () => second.controller.state.refreshedAt != null,
        () => '第二台手机设备同步：${second.controller.state.error}',
      );
      expect(
        second.controller.state.records.single.eventId,
        first.controller.state.records.single.eventId,
      );
      expect(second.controller.state.records.single.notes, '导轨已润滑');
      await second.controller.refresh();
      expect(second.controller.state.records, hasLength(1));
      expect(await first.db.select(first.db.consumables).get(), isEmpty);
      expect(await second.db.select(second.db.consumables).get(), isEmpty);
      await expectLater(
        api.resolveDeviceTag(
          accessToken: bob.accessToken,
          deviceToken: device.deviceToken,
        ),
        throwsA(
          isA<CommunityApiException>().having(
            (e) => e.statusCode,
            'status',
            404,
          ),
        ),
      );
      final replacement = await api.rotateDeviceTag(
        accessToken: alice.accessToken,
        printerKey: deviceTestKey,
      );
      expect(replacement.deviceToken, isNot(device.deviceToken));
      await expectLater(
        first.controller.resolve(device.deviceToken),
        throwsStateError,
      );
      expect(
        (await first.controller.resolve(replacement.deviceToken)).printerKey,
        deviceTestKey,
      );
    }, _LocalHttpOverrides()),
    skip: !const bool.fromEnvironment('RUN_INVENTORY_HTTP_TESTS'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

// The controller needs WidgetsBinding; this local-only integration still
// exercises actual sockets instead of the binding's synthetic HTTP 400 stub.
class _LocalHttpOverrides extends HttpOverrides {}
