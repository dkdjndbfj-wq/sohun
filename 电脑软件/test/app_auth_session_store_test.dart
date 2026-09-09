import 'dart:typed_data';

import 'package:consumable_tracker_desktop/core/services/windows_dpapi.dart';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('DPAPI store round-trips a session without plaintext token storage',
      () async {
    final store = DpapiAppAuthSessionStore(protector: _XorProtector());
    final session = _session();

    await store.write(session);
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('app_auth_session_dpapi_v1');

    expect(stored, startsWith('dpapi:v1:'));
    expect(stored, isNot(contains(session.accessToken)));
    expect(stored, isNot(contains(session.refreshToken)));

    final restored = await store.read();
    expect(restored?.user.id, session.user.id);
    expect(restored?.accessToken, session.accessToken);
    expect(restored?.refreshToken, session.refreshToken);
    expect(restored?.serverBaseUrl, session.serverBaseUrl);
  });

  test('store rejects plaintext and unknown legacy formats', () async {
    SharedPreferences.setMockInitialValues({
      'app_auth_session_dpapi_v1': '{"accessToken":"plaintext"}',
    });
    final store = DpapiAppAuthSessionStore(protector: _XorProtector());

    expect(
      store.read,
      throwsA(isA<AppAuthSessionStoreException>()),
    );
  });

  test('protection failure is fail-closed and writes nothing', () async {
    final store = DpapiAppAuthSessionStore(protector: _FailingProtector());

    expect(
      () => store.write(_session()),
      throwsA(isA<AppAuthSessionStoreException>()),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('app_auth_session_dpapi_v1'), isFalse);
  });

  test('session storage can be replaced by an injected implementation',
      () async {
    final store = _MemorySessionStore();
    await store.write(_session());

    expect((await store.read())?.user.handle, 'maker_01');
    await store.clear();
    expect(await store.read(), isNull);
  });
}

AppAuthSession _session() {
  final now = DateTime.utc(2026, 7, 27);
  return AppAuthSession(
    user: AppUser(
      id: 'user-1',
      email: 'maker@example.com',
      handle: 'maker_01',
      displayName: '打印玩家',
      emailVerified: true,
      createdAt: now,
      updatedAt: now,
    ),
    accessToken: 'sensitive-access-token',
    refreshToken: 'sensitive-refresh-token',
    expiresAt: now.add(const Duration(hours: 1)),
    refreshExpiresAt: now.add(const Duration(days: 30)),
    serverBaseUrl: 'https://share.example.com',
  );
}

class _XorProtector implements DataProtector {
  @override
  Future<Uint8List> protect(Uint8List plaintext) async =>
      Uint8List.fromList(plaintext.map((byte) => byte ^ 0xA5).toList());

  @override
  Future<Uint8List> unprotect(Uint8List ciphertext) async =>
      Uint8List.fromList(ciphertext.map((byte) => byte ^ 0xA5).toList());
}

class _FailingProtector implements DataProtector {
  @override
  Future<Uint8List> protect(Uint8List plaintext) {
    throw const DpapiException('DPAPI unavailable');
  }

  @override
  Future<Uint8List> unprotect(Uint8List ciphertext) {
    throw const DpapiException('DPAPI unavailable');
  }
}

class _MemorySessionStore implements AppAuthSessionStore {
  AppAuthSession? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<AppAuthSession?> read() async => value;

  @override
  Future<void> write(AppAuthSession session) async => value = session;
}
