import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../data/external/community/app_auth_session_store.dart';
import '../data/external/community/community_api_client.dart';
import '../data/models/app_auth.dart';
import '../data/prefs/community_server_settings.dart';

enum AppAuthStatus {
  initializing,
  unconfigured,
  signedOut,
  awaitingEmailVerification,
  signedIn,
  error,
}

const _unset = Object();

class AppAuthState {
  final AppAuthStatus status;
  final Uri? endpoint;
  final AppUser? user;
  final AppAuthSession? session;
  final bool isBusy;
  final String? errorMessage;

  const AppAuthState({
    this.status = AppAuthStatus.initializing,
    this.endpoint,
    this.user,
    this.session,
    this.isBusy = false,
    this.errorMessage,
  });

  bool get isSignedIn => session != null;

  bool get canPublish =>
      session != null &&
      session?.authRealm == 'personal' &&
      user?.emailVerified == true;

  AppAuthState copyWith({
    AppAuthStatus? status,
    Object? endpoint = _unset,
    Object? user = _unset,
    Object? session = _unset,
    bool? isBusy,
    Object? errorMessage = _unset,
  }) {
    return AppAuthState(
      status: status ?? this.status,
      endpoint: endpoint == _unset ? this.endpoint : endpoint as Uri?,
      user: user == _unset ? this.user : user as AppUser?,
      session: session == _unset ? this.session : session as AppAuthSession?,
      isBusy: isBusy ?? this.isBusy,
      errorMessage:
          errorMessage == _unset ? this.errorMessage : errorMessage as String?,
    );
  }
}

typedef CommunityApiFactory = CommunityApi Function(Uri baseUri);

class AppAuthNotifier extends StateNotifier<AppAuthState> {
  final CommunityServerSettings serverSettings;
  final AppAuthSessionStore sessionStore;
  final CommunityApiFactory apiFactory;
  Future<AppAuthSession>? _refreshOperation;
  bool _mutationInProgress = false;

  late final Future<void> ready;

  AppAuthNotifier({
    required this.serverSettings,
    required this.sessionStore,
    required this.apiFactory,
  }) : super(const AppAuthState()) {
    ready = _initialize();
  }

  Future<void> _initialize() async {
    Uri? endpoint;
    try {
      endpoint = await serverSettings.loadBaseUri();
      if (endpoint == null) {
        state = const AppAuthState(status: AppAuthStatus.unconfigured);
        return;
      }

      final saved = await sessionStore.read();
      if (saved == null) {
        state = AppAuthState(
          status: AppAuthStatus.signedOut,
          endpoint: endpoint,
        );
        return;
      }

      if (!_sessionBelongsTo(saved, endpoint)) {
        await sessionStore.clear();
        state = AppAuthState(
          status: AppAuthStatus.signedOut,
          endpoint: endpoint,
          errorMessage: 'sohun 云服务已更新，请重新登录',
        );
        return;
      }

      if (saved.isAccessTokenExpired()) {
        if (saved.isRefreshTokenExpired()) {
          await sessionStore.clear();
          state = AppAuthState(
            status: AppAuthStatus.signedOut,
            endpoint: endpoint,
            errorMessage: '登录已过期，请重新登录',
          );
          return;
        }
        await _restoreByRefresh(endpoint, saved);
        return;
      }

      state = _signedInState(endpoint, saved);
    } catch (error) {
      state = AppAuthState(
        status: AppAuthStatus.error,
        endpoint: endpoint,
        errorMessage: _messageFor(error),
      );
    }
  }

  Future<void> _restoreByRefresh(
    Uri endpoint,
    AppAuthSession saved,
  ) async {
    try {
      final refreshed = await apiFactory(endpoint).refresh(
        refreshToken: saved.refreshToken,
        currentUser: saved.user,
      );
      await sessionStore.write(refreshed);
      state = _signedInState(endpoint, refreshed);
    } on CommunityApiException catch (error) {
      if (error.isAuthenticationFailure) {
        await sessionStore.clear();
        state = AppAuthState(
          status: AppAuthStatus.signedOut,
          endpoint: endpoint,
          errorMessage: '登录已失效，请重新登录',
        );
        return;
      }
      state = AppAuthState(
        status: AppAuthStatus.error,
        endpoint: endpoint,
        user: saved.user,
        session: saved,
        errorMessage: error.message,
      );
    }
  }

  Future<AppRegistrationResult> register(AppRegisterRequest request) async {
    await ready;
    final endpoint = _requireEndpoint();
    _beginOperation();
    try {
      final api = apiFactory(endpoint);
      final service = await api.health();
      if (!service.registrationEnabled) {
        throw const CommunityApiException(
          'sohun 云当前暂停新用户注册',
          category: CommunityApiErrorCategory.permission,
          code: 'registration_disabled',
        );
      }
      if (service.termsVersion != request.termsVersion ||
          service.privacyVersion != request.privacyVersion) {
        throw const CommunityApiException(
          '服务条款或隐私政策已有更新，请更新客户端后重新注册',
          category: CommunityApiErrorCategory.conflict,
          code: 'account_policy_updated',
        );
      }
      final result = await api.register(request);
      final session = result.session;
      await sessionStore.write(session);
      state = AppAuthState(
        status: result.verificationRequired
            ? AppAuthStatus.awaitingEmailVerification
            : AppAuthStatus.signedIn,
        endpoint: endpoint,
        user: result.user,
        session: session,
      );
      return result;
    } catch (error) {
      _failOperation(error, endpoint: endpoint);
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<AppAuthSession> login(AppLoginRequest request) async {
    await ready;
    final endpoint = _requireEndpoint();
    _beginOperation();
    try {
      final session = await apiFactory(endpoint).login(request);
      await sessionStore.write(session);
      state = _signedInState(endpoint, session);
      return session;
    } catch (error) {
      _failOperation(error, endpoint: endpoint);
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<AppAuthSession> loginFarmStaff(FarmStaffLoginRequest request) async {
    await ready;
    final endpoint = _requireEndpoint();
    _beginOperation();
    try {
      final session = await apiFactory(endpoint).loginFarmStaff(request);
      await sessionStore.write(session);
      state = _signedInState(endpoint, session);
      return session;
    } catch (error) {
      _failOperation(error, endpoint: endpoint);
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<AppAuthSession> changeFarmInitialPassword(
    FarmInitialPasswordChangeRequest request,
  ) async {
    await ready;
    final endpoint = _requireEndpoint();
    final current = _requireSession();
    if (current.authRealm != 'farm_staff') {
      throw StateError('当前不是农场员工账号');
    }
    _beginOperation();
    try {
      final session = await apiFactory(endpoint).changeFarmInitialPassword(
        accessToken: current.accessToken,
        request: request,
        currentSession: current,
      );
      await sessionStore.write(session);
      state = _signedInState(endpoint, session);
      return session;
    } catch (error) {
      _failOperation(error, endpoint: endpoint);
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<AppAuthSession> refreshSession() async {
    await ready;
    return _startOrJoinRefresh();
  }

  Future<AppAuthSession> _startOrJoinRefresh() {
    final inFlight = _refreshOperation;
    if (inFlight != null) return inFlight;

    final endpoint = _requireEndpoint();
    final current = _requireSession();
    _beginOperation();

    late final Future<AppAuthSession> sharedOperation;
    sharedOperation =
        _performRefreshSession(endpoint, current).whenComplete(() {
      if (identical(_refreshOperation, sharedOperation)) {
        _refreshOperation = null;
      }
      _endOperation();
    });
    _refreshOperation = sharedOperation;
    return sharedOperation;
  }

  /// Returns a session whose access token is valid for the requested window.
  /// Concurrent callers share one refresh request so page activation cannot
  /// rotate the same refresh token more than once.
  Future<AppAuthSession> ensureValidSession({
    Duration minimumValidity = const Duration(minutes: 1),
  }) async {
    await ready;
    final current = _requireSession();
    if (!current.isAccessTokenExpired(clockSkew: minimumValidity)) {
      return current;
    }
    return _startOrJoinRefresh();
  }

  Future<AppAuthSession> _performRefreshSession(
    Uri endpoint,
    AppAuthSession current,
  ) async {
    try {
      final refreshed = await _requestRefreshedSession(endpoint, current);
      await sessionStore.write(refreshed);
      state = _signedInState(endpoint, refreshed);
      return refreshed;
    } catch (error) {
      await _handleAuthenticatedOperationFailure(
        error,
        endpoint: endpoint,
        current: current,
      );
      rethrow;
    }
  }

  Future<AppUser> refreshCurrentUser() async {
    await ready;
    final endpoint = _requireEndpoint();
    var current = _requireSession();
    _beginOperation();
    try {
      current = await _ensureValidSessionWithinOperation(endpoint, current);
      final user = await apiFactory(endpoint).me(
        accessToken: current.accessToken,
      );
      final updated = current.copyWith(user: user);
      await sessionStore.write(updated);
      state = _signedInState(endpoint, updated);
      return user;
    } catch (error) {
      await _handleAuthenticatedOperationFailure(
        error,
        endpoint: endpoint,
        current: current,
      );
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<AppUser> updateCurrentUser(AppUserUpdateRequest request) async {
    await ready;
    final endpoint = _requireEndpoint();
    var current = _requireSession();
    _beginOperation();
    try {
      current = await _ensureValidSessionWithinOperation(endpoint, current);
      final user = await apiFactory(endpoint).updateMe(
        accessToken: current.accessToken,
        request: request,
      );
      final updated = current.copyWith(user: user);
      await sessionStore.write(updated);
      state = _signedInState(endpoint, updated);
      return user;
    } catch (error) {
      await _handleAuthenticatedOperationFailure(
        error,
        endpoint: endpoint,
        current: current,
      );
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<AppAccountPolicyDocument> fetchAccountPolicy(
    AppAccountPolicyType type,
  ) async {
    await ready;
    final endpoint = _requireEndpoint();
    return apiFactory(endpoint).fetchAccountPolicy(type);
  }

  Future<void> requestEmailVerification() async {
    await ready;
    final endpoint = _requireEndpoint();
    var current = _requireSession();
    _beginOperation();
    try {
      current = await _ensureValidSessionWithinOperation(endpoint, current);
      await apiFactory(endpoint).requestEmailVerification(
        accessToken: current.accessToken,
      );
      state = _signedInState(endpoint, current).copyWith(isBusy: true);
    } catch (error) {
      await _handleAuthenticatedOperationFailure(
        error,
        endpoint: endpoint,
        current: current,
      );
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<AppUser> confirmEmailVerification(String code) async {
    await ready;
    final endpoint = _requireEndpoint();
    var current = _requireSession();
    _beginOperation();
    try {
      current = await _ensureValidSessionWithinOperation(endpoint, current);
      final user = await apiFactory(endpoint).confirmEmailVerification(
        accessToken: current.accessToken,
        code: code,
      );
      final updated = current.copyWith(user: user);
      await sessionStore.write(updated);
      state = _signedInState(endpoint, updated).copyWith(isBusy: true);
      return user;
    } catch (error) {
      await _handleAuthenticatedOperationFailure(
        error,
        endpoint: endpoint,
        current: current,
      );
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<void> requestPasswordReset(String email) async {
    await ready;
    final endpoint = _requireEndpoint();
    _beginOperation();
    try {
      await apiFactory(endpoint).requestPasswordReset(
        AppPasswordResetRequest(email),
      );
      state = state.copyWith(isBusy: true, errorMessage: null);
    } catch (error) {
      _failOperation(
        error,
        endpoint: endpoint,
        user: state.user,
        session: state.session,
      );
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<void> confirmPasswordReset({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await ready;
    final endpoint = _requireEndpoint();
    _beginOperation();
    try {
      await apiFactory(endpoint).confirmPasswordReset(
        AppPasswordResetConfirmation(
          email: email,
          code: code,
          newPassword: newPassword,
        ),
      );
      await sessionStore.clear();
      state = AppAuthState(
        status: AppAuthStatus.signedOut,
        endpoint: endpoint,
        isBusy: true,
      );
    } catch (error) {
      _failOperation(
        error,
        endpoint: endpoint,
        user: state.user,
        session: state.session,
      );
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<void> deleteAccount(String password) async {
    await ready;
    final endpoint = _requireEndpoint();
    var current = _requireSession();
    _beginOperation();
    try {
      current = await _ensureValidSessionWithinOperation(endpoint, current);
      await apiFactory(endpoint).deleteAccount(
        accessToken: current.accessToken,
        request: AppAccountDeletionRequest(password),
      );
      await sessionStore.clear();
      state = AppAuthState(
        status: AppAuthStatus.signedOut,
        endpoint: endpoint,
        isBusy: true,
      );
    } catch (error) {
      await _handleAuthenticatedOperationFailure(
        error,
        endpoint: endpoint,
        current: current,
      );
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<void> logout() async {
    await ready;
    final endpoint = state.endpoint;
    var current = state.session;
    _beginOperation();
    Object? remoteError;
    try {
      if (endpoint != null &&
          current != null &&
          current.isAccessTokenExpired(clockSkew: Duration.zero) &&
          !current.isRefreshTokenExpired()) {
        try {
          current = await _requestRefreshedSession(endpoint, current);
        } catch (error) {
          remoteError = error;
        }
      }

      // Even if refreshing failed, the server still gets a best-effort
      // revocation request with the last locally protected token pair.
      if (endpoint != null && current != null) {
        try {
          await apiFactory(endpoint).logout(
            accessToken: current.accessToken,
            refreshToken: current.refreshToken,
          );
        } catch (error) {
          remoteError ??= error;
        }
      }

      try {
        await sessionStore.clear();
      } catch (error) {
        remoteError ??= error;
      }

      state = AppAuthState(
        status: endpoint == null
            ? AppAuthStatus.unconfigured
            : AppAuthStatus.signedOut,
        endpoint: endpoint,
        errorMessage: remoteError == null ? null : _messageFor(remoteError),
      );
      if (remoteError != null) {
        Error.throwWithStackTrace(remoteError, StackTrace.current);
      }
    } finally {
      _endOperation();
    }
  }

  Future<Uri> setEndpoint(String rawUrl) async {
    await ready;
    final candidate = normalizeCommunityServerUri(rawUrl);
    _beginOperation();
    try {
      await apiFactory(candidate).health();
      final endpoint = await serverSettings.setOverride(candidate.toString());
      await sessionStore.clear();
      state = AppAuthState(
        status: AppAuthStatus.signedOut,
        endpoint: endpoint,
        errorMessage: 'sohun 云连接已更新，请重新登录',
      );
      return endpoint;
    } catch (error) {
      state = state.copyWith(errorMessage: _messageFor(error));
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<Uri?> resetEndpoint() async {
    await ready;
    _beginOperation();
    try {
      final endpoint = await serverSettings.resetOverride();
      await sessionStore.clear();
      state = AppAuthState(
        status: endpoint == null
            ? AppAuthStatus.unconfigured
            : AppAuthStatus.signedOut,
        endpoint: endpoint,
        errorMessage: endpoint == null ? 'sohun 云服务暂不可用' : 'sohun 云连接已重置，请重新登录',
      );
      return endpoint;
    } catch (error) {
      state = state.copyWith(errorMessage: _messageFor(error));
      rethrow;
    } finally {
      _endOperation();
    }
  }

  Future<AppAuthSession> _requestRefreshedSession(
    Uri endpoint,
    AppAuthSession current,
  ) async {
    if (current.isRefreshTokenExpired()) {
      throw const CommunityApiException(
        '登录已过期，请重新登录',
        category: CommunityApiErrorCategory.authentication,
      );
    }
    final refreshed = await apiFactory(endpoint).refresh(
      refreshToken: current.refreshToken,
      currentUser: current.user,
    );
    return refreshed.copyWith(
      authRealm: current.authRealm,
      farmOrganizationId: current.farmOrganizationId,
      farmOrganizationCode: current.farmOrganizationCode,
      farmOrganizationName: current.farmOrganizationName,
      farmStaffMemberId: current.farmStaffMemberId,
      farmStaffLoginName: current.farmStaffLoginName,
      farmStaffRoleCode: current.farmStaffRoleCode,
      farmStaffRoleCodes: current.farmStaffRoleCodes,
      mustChangePassword: current.mustChangePassword,
    );
  }

  Future<AppAuthSession> _ensureValidSessionWithinOperation(
    Uri endpoint,
    AppAuthSession current, {
    Duration minimumValidity = const Duration(minutes: 1),
  }) async {
    if (!current.isAccessTokenExpired(clockSkew: minimumValidity)) {
      return current;
    }
    final refreshed = await _requestRefreshedSession(endpoint, current);
    await sessionStore.write(refreshed);
    state = _signedInState(endpoint, refreshed).copyWith(isBusy: true);
    return refreshed;
  }

  Future<void> _handleAuthenticatedOperationFailure(
    Object error, {
    required Uri endpoint,
    required AppAuthSession current,
  }) async {
    if (error is CommunityApiException && error.isAuthenticationFailure) {
      await sessionStore.clear();
      state = AppAuthState(
        status: AppAuthStatus.signedOut,
        endpoint: endpoint,
        isBusy: true,
        errorMessage: error.message,
      );
      return;
    }
    _failOperation(
      error,
      endpoint: endpoint,
      user: current.user,
      session: current,
    );
  }

  Uri _requireEndpoint() {
    final endpoint = state.endpoint;
    if (endpoint == null) {
      throw const CommunityApiException(
        'sohun 云服务暂不可用，请稍后重试',
        category: CommunityApiErrorCategory.configuration,
      );
    }
    return endpoint;
  }

  AppAuthSession _requireSession() {
    final session = state.session;
    if (session == null) {
      throw const CommunityApiException(
        '请先登录应用账号',
        category: CommunityApiErrorCategory.authentication,
      );
    }
    return session;
  }

  void _beginOperation() {
    if (_mutationInProgress) {
      throw const CommunityApiException(
        '账号操作正在进行，请稍候',
        category: CommunityApiErrorCategory.validation,
      );
    }
    _mutationInProgress = true;
    state = state.copyWith(isBusy: true, errorMessage: null);
  }

  void _endOperation() {
    _mutationInProgress = false;
    if (state.isBusy) {
      state = state.copyWith(isBusy: false);
    }
  }

  void _failOperation(
    Object error, {
    required Uri endpoint,
    AppUser? user,
    AppAuthSession? session,
  }) {
    state = AppAuthState(
      status: AppAuthStatus.error,
      endpoint: endpoint,
      user: user,
      session: session,
      isBusy: _mutationInProgress,
      errorMessage: _messageFor(error),
    );
  }

  static AppAuthState _signedInState(
    Uri endpoint,
    AppAuthSession session,
  ) {
    return AppAuthState(
      status: session.user.emailVerified
          ? AppAuthStatus.signedIn
          : AppAuthStatus.awaitingEmailVerification,
      endpoint: endpoint,
      user: session.user,
      session: session,
    );
  }

  static bool _sessionBelongsTo(AppAuthSession session, Uri endpoint) {
    try {
      return normalizeCommunityServerUri(session.serverBaseUrl) == endpoint;
    } catch (_) {
      return false;
    }
  }

  static String _messageFor(Object error) {
    if (error is CommunityApiException) return error.message;
    if (error is FormatException) return error.message;
    if (error is AppAuthSessionStoreException) return error.message;
    return error.toString();
  }
}

final communityServerOverrideStoreProvider =
    Provider<CommunityServerOverrideStore>((ref) {
  return SharedPreferencesCommunityServerOverrideStore();
});

final communityServerSettingsProvider =
    Provider<CommunityServerSettings>((ref) {
  return CommunityServerSettings(
    store: ref.watch(communityServerOverrideStoreProvider),
  );
});

final appAuthSessionStoreProvider = Provider<AppAuthSessionStore>((ref) {
  return DpapiAppAuthSessionStore();
});

final communityHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final communityApiFactoryProvider = Provider<CommunityApiFactory>((ref) {
  final client = ref.watch(communityHttpClientProvider);
  return (baseUri) => CommunityApiClient(
        baseUri: baseUri,
        httpClient: client,
      );
});

final appAuthProvider =
    StateNotifierProvider<AppAuthNotifier, AppAuthState>((ref) {
  return AppAuthNotifier(
    serverSettings: ref.watch(communityServerSettingsProvider),
    sessionStore: ref.watch(appAuthSessionStoreProvider),
    apiFactory: ref.watch(communityApiFactoryProvider),
  );
});

/// Reusable client entry point for the future community preset providers.
final communityApiProvider = Provider<CommunityApi?>((ref) {
  final endpoint = ref.watch(appAuthProvider.select((state) => state.endpoint));
  if (endpoint == null) return null;
  return ref.watch(communityApiFactoryProvider)(endpoint);
});

final communityPresetApiProvider = Provider<CommunityPresetApi?>((ref) {
  final endpoint = ref.watch(appAuthProvider.select((state) => state.endpoint));
  if (endpoint == null) return null;
  return CommunityApiClient(
    baseUri: endpoint,
    httpClient: ref.watch(communityHttpClientProvider),
  );
});

/// Provides the optional co-creation thank-you wall API implemented by the
/// same community server. Keeping it as a separate capability means existing
/// test doubles and deployments can continue to implement only account APIs.
final communitySupportApiProvider = Provider<CommunitySupportApi?>((ref) {
  final api = ref.watch(communityApiProvider);
  // A concrete client can expose the optional support capability alongside
  // the base account API. Keep the cast explicit because Dart does not always
  // promote an interface implementation across unrelated interface types.
  if (api is CommunitySupportApi) return api as CommunitySupportApi;
  return null;
});

class CommunityApiAccess {
  final CommunityApi api;
  final AppAuthSession? session;

  const CommunityApiAccess({required this.api, this.session});
}

/// Provides the configured client and current app session without exposing
/// either the local author profile or the Bambu Cloud session.
final communityApiAccessProvider = Provider<CommunityApiAccess?>((ref) {
  final api = ref.watch(communityApiProvider);
  if (api == null) return null;
  final session = ref.watch(appAuthProvider.select((state) => state.session));
  return CommunityApiAccess(api: api, session: session);
});
