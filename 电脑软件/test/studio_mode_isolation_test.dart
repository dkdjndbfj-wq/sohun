import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/prefs/app_prefs.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/core/app_variant.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('产品构建决定成员会话能否进入农场工作台', () async {
    final auth = _authNotifier(_staffSession());
    await auth.ready;
    final container = ProviderContainer(
      overrides: [appAuthProvider.overrideWith((ref) => auth)],
    );
    addTearDown(container.dispose);

    expect(
      container.read(studioModeEnabledProvider),
      AppVariant.isFarm,
    );
    await container.read(studioModeEnabledProvider.notifier).setEnabled(false);
    expect(
      container.read(studioModeEnabledProvider),
      AppVariant.isFarm,
    );
  });

  test('产品构建决定普通账号的固定工作台', () async {
    SharedPreferences.setMockInitialValues({'studio_mode_enabled': true});
    final auth = _authNotifier(_personalSession());
    await auth.ready;
    final container = ProviderContainer(
      overrides: [appAuthProvider.overrideWith((ref) => auth)],
    );
    addTearDown(container.dispose);

    expect(
      container.read(studioModeEnabledProvider),
      AppVariant.isFarm,
    );
    await container.read(studioModeEnabledProvider.notifier).setEnabled(true);
    expect(
      container.read(studioModeEnabledProvider),
      AppVariant.isFarm,
    );

    await auth.resetEndpoint();
    expect(
      container.read(studioModeEnabledProvider),
      AppVariant.isFarm,
    );
  });
}

AppAuthNotifier _authNotifier(AppAuthSession session) {
  return AppAuthNotifier(
    serverSettings: CommunityServerSettings(
      store: _MemoryOverrideStore(),
      compileTimeBaseUrl: session.serverBaseUrl,
    ),
    sessionStore: _MemorySessionStore()..value = session,
    apiFactory: (_) => throw UnimplementedError(),
  );
}

AppAuthSession _personalSession() {
  final now = DateTime.now().toUtc();
  return AppAuthSession(
    user: AppUser(
      id: 'personal-user',
      email: 'personal@example.com',
      handle: 'personal_user',
      displayName: '普通用户',
      emailVerified: true,
      createdAt: now,
      updatedAt: now,
    ),
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    expiresAt: now.add(const Duration(hours: 1)),
    refreshExpiresAt: now.add(const Duration(days: 1)),
    serverBaseUrl: 'https://api.sohun.top',
  );
}

AppAuthSession _staffSession() {
  return _personalSession().copyWith(
    authRealm: 'farm_staff',
    farmOrganizationId: 'farm-1',
    farmOrganizationName: '测试农场',
    farmStaffMemberId: 'member-1',
    farmStaffLoginName: 'operator',
  );
}

class _MemoryOverrideStore implements CommunityServerOverrideStore {
  @override
  Future<void> clear() async {}

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
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
