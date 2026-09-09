import 'dart:async';

import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/studio_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('initialization restores a session bound to the configured server',
      () async {
    final sessionStore = _MemorySessionStore()..value = _session();
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'));
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );

    await notifier.ready;

    expect(notifier.state.status, AppAuthStatus.signedIn);
    expect(notifier.state.user?.id, 'user-1');
    expect(notifier.state.session?.accessToken, 'access-token');
  });

  test('unconfigured operations fail with an explicit configuration error',
      () async {
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: '',
      ),
      sessionStore: _MemorySessionStore(),
      apiFactory: (uri) => _FakeCommunityApi(uri),
    );
    await notifier.ready;

    expect(notifier.state.status, AppAuthStatus.unconfigured);
    expect(
      () => notifier.login(
        AppLoginRequest(email: 'maker@example.com', password: 'secret'),
      ),
      throwsA(
        isA<CommunityApiException>()
            .having(
              (e) => e.message,
              'message',
              'sohun 云服务暂不可用，请稍后重试',
            )
            .having(
              (e) => e.category,
              'category',
              CommunityApiErrorCategory.configuration,
            ),
      ),
    );
  });

  test('login persists only the returned session and logout clears it',
      () async {
    final sessionStore = _MemorySessionStore();
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'));
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;

    await notifier.login(
      AppLoginRequest(email: 'maker@example.com', password: 'not-persisted'),
    );
    expect(sessionStore.value?.accessToken, 'access-token');
    expect(notifier.state.status, AppAuthStatus.signedIn);

    await notifier.logout();
    expect(sessionStore.value, isNull);
    expect(api.logoutCalls, 1);
    expect(notifier.state.status, AppAuthStatus.signedOut);
  });

  test(
      'farm staff login persists the isolated realm and clears first-login password state',
      () async {
    final sessionStore = _MemorySessionStore();
    final api = _FakeCommunityApi(Uri.parse('https://api.sohun.top'));
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://api.sohun.top',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;

    final loggedIn = await notifier.loginFarmStaff(
      FarmStaffLoginRequest(
        organizationCode: 'F1234567890',
        loginName: 'slicer01',
        password: 'Initial!Password123',
      ),
    );
    expect(loggedIn.authRealm, 'farm_staff');
    expect(loggedIn.farmOrganizationCode, 'F1234567890');
    expect(loggedIn.farmStaffLoginName, 'slicer01');
    expect(
      loggedIn.farmStaffRoleCodes,
      containsAll(['slicer', 'inventory_manager']),
    );
    expect(loggedIn.mustChangePassword, isTrue);
    expect(notifier.state.canPublish, isFalse);
    expect(sessionStore.value?.authRealm, 'farm_staff');

    final changed = await notifier.changeFarmInitialPassword(
      FarmInitialPasswordChangeRequest(
        currentPassword: 'Initial!Password123',
        newPassword: 'Changed!Password123',
      ),
    );
    expect(changed.mustChangePassword, isFalse);
    expect(sessionStore.value?.mustChangePassword, isFalse);
  });

  test('remote logout failure still clears the local protected session',
      () async {
    final sessionStore = _MemorySessionStore()..value = _session();
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'))
      ..logoutError = const CommunityApiException(
        '服务器暂时不可用',
        category: CommunityApiErrorCategory.server,
      );
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;

    await expectLater(
      notifier.logout(),
      throwsA(isA<CommunityApiException>()),
    );

    expect(sessionStore.value, isNull);
    expect(api.logoutRefreshToken, 'refresh-token');
    expect(notifier.state.status, AppAuthStatus.signedOut);
    expect(notifier.state.errorMessage, '服务器暂时不可用');
  });

  test('changing endpoint clears credentials and requires a new login',
      () async {
    final overrideStore = _MemoryOverrideStore();
    final sessionStore = _MemorySessionStore()..value = _session();
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: overrideStore,
        compileTimeBaseUrl: 'https://share.example.com',
        allowRuntimeOverride: true,
      ),
      sessionStore: sessionStore,
      apiFactory: (uri) => _FakeCommunityApi(uri),
    );
    await notifier.ready;

    final endpoint =
        await notifier.setEndpoint('https://new-share.example.com/api/');

    expect(endpoint.toString(), 'https://new-share.example.com/api');
    expect(overrideStore.value, 'https://new-share.example.com/api');
    expect(sessionStore.value, isNull);
    expect(notifier.state.status, AppAuthStatus.signedOut);
    expect(
      notifier.state.errorMessage,
      'sohun 云连接已更新，请重新登录',
    );
  });

  test('invalid endpoint probe preserves the current endpoint and session',
      () async {
    final overrideStore = _MemoryOverrideStore();
    final sessionStore = _MemorySessionStore()..value = _session();
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: overrideStore,
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (uri) => _FakeCommunityApi(uri)
        ..healthError = const CommunityApiException(
          '该地址不是 sohun 账号服务器',
          category: CommunityApiErrorCategory.configuration,
        ),
    );
    await notifier.ready;

    await expectLater(
      notifier.setEndpoint('https://wrong.example.com'),
      throwsA(isA<CommunityApiException>()),
    );

    expect(overrideStore.value, isNull);
    expect(sessionStore.value?.accessToken, 'access-token');
    expect(notifier.state.endpoint.toString(), 'https://share.example.com');
    expect(notifier.state.status, AppAuthStatus.signedIn);
    expect(notifier.state.isBusy, isFalse);
  });

  test('endpoint change and logout cannot race an in-flight login', () async {
    final overrideStore = _MemoryOverrideStore();
    final sessionStore = _MemorySessionStore();
    final loginStarted = Completer<void>();
    final loginCompleter = Completer<AppAuthSession>();
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'))
      ..loginStarted = loginStarted
      ..loginCompleter = loginCompleter;
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: overrideStore,
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;

    final login = notifier.login(
      AppLoginRequest(email: 'maker@example.com', password: 'secret'),
    );
    await loginStarted.future;
    expect(notifier.state.isBusy, isTrue);

    await expectLater(
      notifier.setEndpoint('https://new-share.example.com'),
      throwsA(
        isA<CommunityApiException>().having(
          (error) => error.category,
          'category',
          CommunityApiErrorCategory.validation,
        ),
      ),
    );
    await expectLater(
      notifier.logout(),
      throwsA(isA<CommunityApiException>()),
    );

    loginCompleter.complete(_session(accessToken: 'late-login-token'));
    await login;

    expect(overrideStore.value, isNull);
    expect(sessionStore.value?.accessToken, 'late-login-token');
    expect(notifier.state.endpoint.toString(), 'https://share.example.com');
    expect(notifier.state.isBusy, isFalse);
  });

  test('logout cannot clear a session while registration is in flight',
      () async {
    final sessionStore = _MemorySessionStore();
    final registerStarted = Completer<void>();
    final registerCompleter = Completer<AppRegistrationResult>();
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'))
      ..registerStarted = registerStarted
      ..registerCompleter = registerCompleter;
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;

    final registration = notifier.register(_registrationRequest());
    await registerStarted.future;
    await expectLater(
      notifier.logout(),
      throwsA(isA<CommunityApiException>()),
    );

    final registeredSession = _session(accessToken: 'registered-token');
    registerCompleter.complete(
      AppRegistrationResult(
        user: registeredSession.user,
        session: registeredSession,
        verificationRequired: false,
      ),
    );
    await registration;

    expect(sessionStore.value?.accessToken, 'registered-token');
    expect(notifier.state.status, AppAuthStatus.signedIn);
    expect(notifier.state.isBusy, isFalse);
  });

  test('logout refreshes an expired access token before remote revocation',
      () async {
    final sessionStore = _MemorySessionStore();
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'))
      ..loginSession = _session(
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      )
      ..refreshSession = _session(accessToken: 'renewed-for-logout');
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;
    await notifier.login(
      AppLoginRequest(email: 'maker@example.com', password: 'secret'),
    );

    await notifier.logout();

    expect(api.refreshCalls, 1);
    expect(api.logoutCalls, 1);
    expect(api.logoutAccessToken, 'renewed-for-logout');
    expect(sessionStore.value, isNull);
    expect(notifier.state.status, AppAuthStatus.signedOut);
    expect(notifier.state.isBusy, isFalse);
  });

  test('concurrent requests share one access-token refresh', () async {
    final sessionStore = _MemorySessionStore();
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'))
      ..loginSession = _session(
        expiresAt: DateTime.now().add(const Duration(seconds: 10)),
      )
      ..refreshCompleter = Completer<AppAuthSession>();
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;
    await notifier.login(
      AppLoginRequest(email: 'maker@example.com', password: 'secret'),
    );

    final first = notifier.ensureValidSession();
    final second = notifier.ensureValidSession();
    await Future<void>.delayed(Duration.zero);

    expect(api.refreshCalls, 1);
    api.refreshCompleter!.complete(_session(accessToken: 'renewed-token'));
    final sessions = await Future.wait([first, second]);

    expect(
      sessions.map((item) => item.accessToken),
      everyElement('renewed-token'),
    );
    expect(sessionStore.value?.accessToken, 'renewed-token');
  });

  test('expired refresh token clears the protected session', () async {
    final sessionStore = _MemorySessionStore();
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'))
      ..loginSession = _session(
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        refreshExpiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;
    await notifier.login(
      AppLoginRequest(email: 'maker@example.com', password: 'secret'),
    );

    await expectLater(
      notifier.ensureValidSession(),
      throwsA(isA<CommunityApiException>()),
    );

    expect(api.refreshCalls, 0);
    expect(sessionStore.value, isNull);
    expect(notifier.state.status, AppAuthStatus.signedOut);
  });

  test('authentication failure from me clears the protected session', () async {
    final sessionStore = _MemorySessionStore()..value = _session();
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'))
      ..meError = const CommunityApiException(
        '登录已失效',
        category: CommunityApiErrorCategory.authentication,
        statusCode: 401,
      );
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;

    await expectLater(
      notifier.refreshCurrentUser(),
      throwsA(isA<CommunityApiException>()),
    );

    expect(sessionStore.value, isNull);
    expect(notifier.state.status, AppAuthStatus.signedOut);
    expect(notifier.state.session, isNull);
    expect(notifier.state.user, isNull);
    expect(notifier.state.isBusy, isFalse);
  });

  test('authentication failure from profile update clears the session',
      () async {
    final sessionStore = _MemorySessionStore()..value = _session();
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'))
      ..updateMeError = const CommunityApiException(
        '登录已失效',
        category: CommunityApiErrorCategory.authentication,
        statusCode: 401,
      );
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;

    await expectLater(
      notifier.updateCurrentUser(
        AppUserUpdateRequest(displayName: '新显示名'),
      ),
      throwsA(isA<CommunityApiException>()),
    );

    expect(sessionStore.value, isNull);
    expect(notifier.state.status, AppAuthStatus.signedOut);
    expect(notifier.state.session, isNull);
    expect(notifier.state.isBusy, isFalse);
  });

  test('email verification promotes the protected session to signed in',
      () async {
    final sessionStore = _MemorySessionStore()
      ..value = _session(emailVerified: false);
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'));
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;

    expect(notifier.state.status, AppAuthStatus.awaitingEmailVerification);
    await notifier.requestEmailVerification();
    final user = await notifier.confirmEmailVerification('12345678');

    expect(api.verificationRequestCalls, 1);
    expect(api.verificationConfirmCalls, 1);
    expect(user.emailVerified, isTrue);
    expect(sessionStore.value?.user.emailVerified, isTrue);
    expect(notifier.state.status, AppAuthStatus.signedIn);
    expect(notifier.state.isBusy, isFalse);
  });

  test('account deletion clears the local protected session', () async {
    final sessionStore = _MemorySessionStore()..value = _session();
    final api = _FakeCommunityApi(Uri.parse('https://share.example.com'));
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://share.example.com',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => api,
    );
    await notifier.ready;

    await notifier.deleteAccount('StrongPass123');

    expect(api.deleteAccountCalls, 1);
    expect(sessionStore.value, isNull);
    expect(notifier.state.status, AppAuthStatus.signedOut);
    expect(notifier.state.session, isNull);
  });

  test('farm members can use every farm feature regardless of legacy roles', () async {
    final saved = _session(server: 'https://api.sohun.top').copyWith(
      authRealm: 'farm_staff',
      farmOrganizationId: 'farm-1',
      farmStaffMemberId: 'member-1',
      farmStaffRoleCode: 'slicer',
      farmStaffRoleCodes: const ['slicer', 'inventory_manager'],
    );
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'https://api.sohun.top',
      ),
      sessionStore: _MemorySessionStore()..value = saved,
      apiFactory: (uri) => _FakeCommunityApi(uri),
    );
    await notifier.ready;
    final container = ProviderContainer(
      overrides: [
        appAuthProvider.overrideWith((ref) => notifier),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(currentFarmPermissionProvider('plate.slice')),
      isTrue,
    );
    expect(
      container.read(currentFarmPermissionProvider('inventory.adjust')),
      isTrue,
    );
    expect(
      container.read(currentFarmPermissionProvider('finance.manage')),
      isTrue,
    );
    expect(container.read(currentFarmRoleCodesProvider), {'member'});
  });
}

AppRegisterRequest _registrationRequest() {
  return AppRegisterRequest(
    email: 'new-maker@example.com',
    handle: 'new_maker',
    displayName: '新用户',
    password: 'SecurePassword123',
    acceptTerms: true,
  );
}

AppAuthSession _session({
  String server = 'https://share.example.com',
  String accessToken = 'access-token',
  DateTime? expiresAt,
  DateTime? refreshExpiresAt,
  bool emailVerified = true,
}) {
  final now = DateTime.now();
  return AppAuthSession(
    user: AppUser(
      id: 'user-1',
      email: 'maker@example.com',
      handle: 'maker_01',
      displayName: '打印玩家',
      emailVerified: emailVerified,
      createdAt: now,
      updatedAt: now,
    ),
    accessToken: accessToken,
    refreshToken: 'refresh-token',
    expiresAt: expiresAt ?? now.add(const Duration(hours: 1)),
    refreshExpiresAt: refreshExpiresAt ?? now.add(const Duration(days: 30)),
    serverBaseUrl: server,
  );
}

class _MemoryOverrideStore implements CommunityServerOverrideStore {
  String? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
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

class _FakeCommunityApi implements CommunityApi {
  @override
  final Uri baseUri;
  int logoutCalls = 0;
  Object? logoutError;
  String? logoutAccessToken;
  String? logoutRefreshToken;
  int refreshCalls = 0;
  int loginCalls = 0;
  AppAuthSession? loginSession;
  AppAuthSession? refreshSession;
  Completer<void>? loginStarted;
  Completer<AppAuthSession>? loginCompleter;
  Completer<AppAuthSession>? refreshCompleter;
  Completer<void>? registerStarted;
  Completer<AppRegistrationResult>? registerCompleter;
  Object? healthError;
  Object? meError;
  Object? updateMeError;
  int verificationRequestCalls = 0;
  int verificationConfirmCalls = 0;
  int deleteAccountCalls = 0;

  _FakeCommunityApi(this.baseUri);

  @override
  Future<CommunityServiceInfo> health() async {
    final error = healthError;
    if (error != null) throw error;
    return const CommunityServiceInfo(
      service: 'sohun-community',
      apiVersion: 1,
      registrationEnabled: true,
      emailVerificationRequired: false,
      termsVersion: AppAccountAgreement.termsVersion,
      privacyVersion: AppAccountAgreement.privacyVersion,
    );
  }

  @override
  Future<AppAccountPolicyDocument> fetchAccountPolicy(
    AppAccountPolicyType type, {
    String version = 'current',
  }) async {
    return AppAccountPolicyDocument(
      type: type,
      version: AppAccountAgreement.termsVersion,
      isCurrent: true,
      title: type.label,
      effectiveAt: DateTime.utc(2026, 7, 29),
      content: 'policy',
    );
  }

  @override
  Future<AppAuthSession> login(AppLoginRequest request) async {
    loginCalls++;
    loginStarted?.complete();
    final completer = loginCompleter;
    if (completer != null) return completer.future;
    return loginSession ?? _session(server: baseUri.toString());
  }

  @override
  Future<AppAuthSession> loginFarmStaff(FarmStaffLoginRequest request) async {
    loginCalls++;
    return (loginSession ?? _session(server: baseUri.toString())).copyWith(
      authRealm: 'farm_staff',
      farmOrganizationId: 'farm-1',
      farmOrganizationCode: request.organizationCode,
      farmOrganizationName: '测试农场',
      farmStaffMemberId: 'member-1',
      farmStaffLoginName: request.loginName,
      farmStaffRoleCode: 'slicer',
      farmStaffRoleCodes: const ['slicer', 'inventory_manager'],
      mustChangePassword: true,
    );
  }

  @override
  Future<AppAuthSession> changeFarmInitialPassword({
    required String accessToken,
    required FarmInitialPasswordChangeRequest request,
    required AppAuthSession currentSession,
  }) async {
    return currentSession.copyWith(mustChangePassword: false);
  }

  @override
  Future<void> logout({
    required String accessToken,
    required String refreshToken,
  }) async {
    logoutCalls++;
    logoutAccessToken = accessToken;
    logoutRefreshToken = refreshToken;
    final error = logoutError;
    if (error != null) throw error;
  }

  @override
  Future<AppUser> me({required String accessToken}) async {
    final error = meError;
    if (error != null) throw error;
    return _session().user;
  }

  @override
  Future<AppAuthSession> refresh({
    required String refreshToken,
    required AppUser currentUser,
  }) async {
    refreshCalls++;
    final completer = refreshCompleter;
    if (completer != null) return completer.future;
    final configured = refreshSession;
    if (configured != null) return configured.copyWith(user: currentUser);
    return _session(server: baseUri.toString()).copyWith(user: currentUser);
  }

  @override
  Future<AppRegistrationResult> register(AppRegisterRequest request) async {
    registerStarted?.complete();
    final completer = registerCompleter;
    if (completer != null) return completer.future;
    final session = _session(server: baseUri.toString());
    return AppRegistrationResult(
      user: session.user,
      session: session,
      verificationRequired: false,
    );
  }

  @override
  Future<AppUser> updateMe({
    required String accessToken,
    required AppUserUpdateRequest request,
  }) async {
    final error = updateMeError;
    if (error != null) throw error;
    return _session().user;
  }

  @override
  Future<void> requestEmailVerification({required String accessToken}) async {
    verificationRequestCalls++;
  }

  @override
  Future<AppUser> confirmEmailVerification({
    required String accessToken,
    required String code,
  }) async {
    verificationConfirmCalls++;
    return _session().user.copyWith(emailVerified: true);
  }

  @override
  Future<void> requestPasswordReset(AppPasswordResetRequest request) async {}

  @override
  Future<void> confirmPasswordReset(
    AppPasswordResetConfirmation confirmation,
  ) async {}

  @override
  Future<void> deleteAccount({
    required String accessToken,
    required AppAccountDeletionRequest request,
  }) async {
    deleteAccountCalls++;
  }
}
