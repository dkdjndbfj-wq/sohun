import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/daos/printer_dao.dart';
import '../data/external/printer/bambu_cloud_client.dart';
import '../data/external/printer/bambu_cloud_models.dart';
import '../data/external/printer/bambu_cloud_session_store.dart';
import '../data/external/printer/bambu_printer_models.dart';
import 'account_session_coordinator.dart';
import 'bambu_account_manager.dart';
import 'database_provider.dart';
import 'printer_connection_provider.dart';

/// 云连接状态。
///
/// - idle：未登录
/// - loading：登录中 / 拉取设备中
/// - awaitingCode：密码已验证，等待用户输入验证码
/// - authenticated：已登录且有 session
/// - error：登录或拉取失败
class BambuCloudState {
  final BambuCloudSession? session;
  final List<BambuCloudDevice> devices;
  final String? errorMessage;
  final bool isLoading;

  /// 密码登录后需要验证码时，保存待验证的账号信息。
  final PendingAccount? pendingAccount;

  const BambuCloudState({
    this.session,
    this.devices = const [],
    this.errorMessage,
    this.isLoading = false,
    this.pendingAccount,
  });

  bool get isLoggedIn => session != null;
  bool get isAwaitingCode => pendingAccount != null;

  /// 把云端设备转成可用于连接的 config 列表。
  List<PrinterConnectionConfig> toCloudConfigs() {
    if (session == null) return [];
    return devices
        .where((d) => d.devId.isNotEmpty)
        .map(
          (d) => PrinterConnectionConfig.cloud(
            serial: d.devId,
            devProductName: d.devProductName,
            displayName: d.name,
            installedNozzleDiameter: d.nozzleDiameter,
          ),
        )
        .toList();
  }

  BambuCloudState copyWith({
    BambuCloudSession? session,
    List<BambuCloudDevice>? devices,
    String? errorMessage,
    bool? isLoading,
    PendingAccount? pendingAccount,
    bool clearError = false,
    bool clearSession = false,
    bool clearPending = false,
  }) {
    return BambuCloudState(
      session: clearSession ? null : (session ?? this.session),
      devices: devices ?? this.devices,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isLoading: isLoading ?? this.isLoading,
      pendingAccount:
          clearPending ? null : (pendingAccount ?? this.pendingAccount),
    );
  }
}

/// 密码验证通过后、验证码登录前，暂存的账号信息。
class PendingAccount {
  final BambuRegion region;
  final String account;
  final String password;

  const PendingAccount({
    required this.region,
    required this.account,
    required this.password,
  });
}

typedef BambuCloudDeviceLoader = Future<List<BambuCloudDevice>> Function(
  BambuCloudSession session,
);

typedef BambuCloudPasswordLogin = Future<LoginResult> Function({
  required BambuRegion region,
  required String account,
  required String password,
});

/// 云连接状态管理。
///
/// 验证码登录流程：
/// 1. [loginWithPassword] → 密码验证通过后 state 进入 awaitingCode
/// 2. [sendCode] → 发送短信/邮件验证码
/// 3. [loginWithCode] → 用验证码换 token，完成登录
class BambuCloudNotifier extends StateNotifier<BambuCloudState> {
  BambuCloudNotifier(
    this._ref, {
    BambuCloudDeviceLoader? deviceLoader,
    BambuCloudPasswordLogin? passwordLogin,
  })  : _deviceLoader = deviceLoader ?? BambuCloudClient.getDeviceList,
        _passwordLogin = passwordLogin ?? BambuCloudClient.loginWithPassword,
        super(const BambuCloudState()) {
    // 监听账号会话协调器：账号切换时由 bambuAccountManagerProvider 写入新 session，
    // 这里被动应用，避免 bambuAccountManagerProvider 直接调用本 notifier（打破循环依赖）。
    // 回调为同步触发，内部的 async 工作（refreshDevices 等）fire-and-forget，
    // 错误已在 setActiveSession / refreshDevices 内部捕获并写入 state.errorMessage，
    // 不会抛出到此处。
    _ref.listen<BambuCloudSession?>(
      accountSessionCoordinatorProvider,
      (previous, next) {
        if (next != null) {
          // 应用新 session（账号切换）
          setActiveSession(next);
        } else if (previous != null) {
          // 清空 session（账号被删除后清空活跃态）
          _sessionGeneration++;
          _refreshGeneration++;
          state = const BambuCloudState();
        }
      },
    );
    _restoreSession();
  }

  final Ref _ref;
  PrinterDao get _printerDao => _ref.read(printerDaoProvider);
  final BambuCloudDeviceLoader _deviceLoader;
  final BambuCloudPasswordLogin _passwordLogin;

  /// 会话代际。每次切换/登出/替换 session 都递增。
  ///
  /// 仅比较 access token 不够：同一账号续登会换 token，且不同请求可能在
  /// 同一 token 下交错完成。代际让所有异步副作用都绑定到一次明确的会话。
  int _sessionGeneration = 0;

  /// 设备列表刷新请求代际。相同 session 的并发刷新也只允许最后一次请求
  /// 回写状态，避免旧响应覆盖较新的设备列表或错误。
  int _refreshGeneration = 0;

  bool _sameSession(BambuCloudSession? current, BambuCloudSession expected) {
    return current != null &&
        current.email == expected.email &&
        current.region == expected.region &&
        current.accessToken == expected.accessToken;
  }

  bool _isCurrentGeneration(int generation) =>
      mounted && generation == _sessionGeneration;

  bool _isCurrentSession(
    BambuCloudSession expected,
    int generation,
  ) {
    return mounted &&
        generation == _sessionGeneration &&
        _sameSession(state.session, expected);
  }

  bool _isCurrentRefresh({
    required BambuCloudSession expected,
    required int sessionGeneration,
    required int refreshGeneration,
  }) {
    return _isCurrentSession(expected, sessionGeneration) &&
        refreshGeneration == _refreshGeneration;
  }

  /// Install a session and invalidate every async operation belonging to the
  /// previous session. Returns the generation associated with [session].
  int _activateSession(BambuCloudSession session) {
    _sessionGeneration++;
    _refreshGeneration++;
    state = BambuCloudState(session: session);
    return _sessionGeneration;
  }

  /// 启动时从加密存储恢复 session。
  Future<void> _restoreSession() async {
    final restoreGeneration = _sessionGeneration;
    final session = await BambuCloudSessionStore.loadSession();
    if (!mounted || restoreGeneration != _sessionGeneration) return;
    if (session == null) return;

    if (session.isExpired) {
      // session 过期，用保存的账号密码重登
      // Resolve credentials by the session's identity rather than the global
      // active-account pointer. The pointer may change while restoration is
      // awaiting storage, and using it here could relogin the wrong account.
      final account = await BambuCloudSessionStore.loadAccountFor(
        session.email,
        session.region,
      );
      if (!mounted || restoreGeneration != _sessionGeneration) return;
      if (account == null) return;
      // Bind the pending relogin to this session generation. A concurrent
      // account switch or logout will invalidate it before it can write state.
      final sessionGeneration = _activateSession(session);
      // 自动重登走密码登录流程（可能需要验证码，但自动重登时无法让用户输入，
      // 所以直接尝试密码登录，若需要验证码则忽略，等用户手动重新登录）
      await _autoRelogin(
        region: account.region,
        account: account.email,
        password: account.password,
        expectedSession: session,
        expectedSessionGeneration: sessionGeneration,
      );
      return;
    }

    // 修复旧版 bug：如果保存的 username 不是 u_ 开头（旧代码用 token 本身当 username），
    // 重新从 Preference API 解析正确的 username 并更新 session。
    var fixedSession = session;
    if (!session.username.startsWith('u_')) {
      try {
        if (!mounted || restoreGeneration != _sessionGeneration) return;
        final correctUsername =
            await BambuCloudClient.resolveUsernameForSession(session);
        if (!mounted || restoreGeneration != _sessionGeneration) return;
        if (correctUsername.startsWith('u_')) {
          fixedSession = BambuCloudSession(
            region: session.region,
            email: session.email,
            accessToken: session.accessToken,
            username: correctUsername,
            loginAt: session.loginAt,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt,
            refreshExpiresAt: session.refreshExpiresAt,
          );
          if (!mounted || restoreGeneration != _sessionGeneration) return;
          await BambuCloudSessionStore.saveSession(fixedSession);
        }
      } catch (e) {
        debugPrint('[BambuCloud] 修复 username 失败: $e');
      }
    }

    if (!mounted || restoreGeneration != _sessionGeneration) return;
    _activateSession(fixedSession);
    await refreshDevices();
  }

  /// 自动重登（token 过期时）。无法处理验证码场景。
  ///
  /// 失败时不清空错误信息，让 UI 能主动提示用户重新登录，
  /// 而非静默清空 session 导致用户困惑。
  ///
  /// P1-6: 基于错误分类给出针对性提示：
  /// - authentication → 账号密码错误，需手动重登
  /// - network/server/rateLimit → 网络或服务器问题，稍后自动恢复（保留 session 允许重试）
  /// - protocol → 协议变更，提示用户更新应用
  Future<void> _autoRelogin({
    required BambuRegion region,
    required String account,
    required String password,
    required BambuCloudSession expectedSession,
    required int expectedSessionGeneration,
    int? expectedRefreshGeneration,
  }) async {
    bool isCurrent() {
      if (!_isCurrentSession(expectedSession, expectedSessionGeneration)) {
        return false;
      }
      return expectedRefreshGeneration == null ||
          expectedRefreshGeneration == _refreshGeneration;
    }

    try {
      final result = await _passwordLogin(
        region: region,
        account: account,
        password: password,
      );
      if (!isCurrent()) return;
      if (result.needsVerificationCode) {
        // 按原账号删除 session。不能调用 clearSession()，因为它依赖全局
        // active account，切账号后会误删新账号。
        await BambuCloudSessionStore.removeSession(
          expectedSession.email,
          expectedSession.region,
        );
        if (!isCurrent()) return;
        _sessionGeneration++;
        _refreshGeneration++;
        state = BambuCloudState(
          errorMessage: '账号 $account 的登录已过期，且该账号需要验证码登录，请手动重新登录',
        );
        return;
      }
      final session = result.session!;
      if (session.email != expectedSession.email ||
          session.region != expectedSession.region ||
          !isCurrent()) {
        return;
      }
      await BambuCloudSessionStore.saveSession(session);
      if (!isCurrent()) return;
      _activateSession(session);
      await refreshDevices();
    } catch (e) {
      // 自动重登失败，告知用户具体原因
      debugPrint('[BambuCloud] 自动重登失败: $e');
      if (!isCurrent()) return;
      final msg = e is BambuCloudException
          ? e.message
          : e.toString().replaceFirst('BambuCloudException: ', '');
      final isTransient = e is BambuCloudException && e.isRetryable;
      final isProtocol = e is BambuCloudException &&
          e.category == BambuCloudErrorCategory.protocol;

      // 网络/服务器/限流错误：不清 session，允许下次 refreshDevices 重试
      if (isTransient) {
        if (!isCurrent()) return;
        state = BambuCloudState(
          session: state.session,
          errorMessage: '账号 $account 自动重登因网络/服务器问题失败：$msg。'
              '已保留登录状态，稍后会自动重试。',
        );
        return;
      }

      // 认证/权限/协议错误：清 session，提示用户手动处理
      await BambuCloudSessionStore.removeSession(
        expectedSession.email,
        expectedSession.region,
      );
      if (!isCurrent()) return;
      _sessionGeneration++;
      _refreshGeneration++;
      state = BambuCloudState(
        errorMessage: isProtocol
            ? '账号 $account 自动重登失败：$msg。'
                '拓竹云协议可能已变更，请更新应用或手动重新登录'
            : '账号 $account 自动重登失败：$msg，请手动重新登录',
      );
    }
  }

  /// 第一步：用密码登录。
  ///
  /// 若账号需要验证码，state 进入 awaitingCode（pendingAccount 保存账号信息）。
  /// 若直接成功（少数账号），完成登录。
  Future<bool> loginWithPassword({
    required BambuRegion region,
    required String account,
    required String password,
  }) async {
    final loginGeneration = ++_sessionGeneration;
    _refreshGeneration++;
    state =
        state.copyWith(isLoading: true, clearError: true, clearPending: true);
    try {
      final result = await BambuCloudClient.loginWithPassword(
        region: region,
        account: account,
        password: password,
      );
      if (!_isCurrentGeneration(loginGeneration)) return false;
      if (result.needsVerificationCode) {
        // 需要验证码：保留原账号 session/设备，避免取消新增账号时丢失当前连接。
        state = state.copyWith(
          isLoading: false,
          clearError: true,
          pendingAccount: PendingAccount(
            region: region,
            account: account,
            password: password,
          ),
        );
        // 自动发送验证码
        return sendCode(expectedGeneration: loginGeneration);
      }
      // 直接成功
      final session = result.session!;
      return _completeLogin(
        session,
        region,
        account,
        password,
        expectedSessionGeneration: loginGeneration,
      );
    } catch (e) {
      if (!_isCurrentGeneration(loginGeneration)) return false;
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString().replaceFirst('BambuCloudException: ', ''),
      );
      return false;
    }
  }

  /// 用户关闭登录弹窗时取消待验证流程，但保留原有已登录账号。
  void cancelPendingLogin() {
    if (!state.isAwaitingCode) return;
    _sessionGeneration++;
    _refreshGeneration++;
    state = state.copyWith(
      isLoading: false,
      clearPending: true,
      clearError: true,
    );
  }

  /// 第二步：发送验证码。
  ///
  /// 使用 pendingAccount 中的账号信息。
  Future<bool> sendCode({int? expectedGeneration}) async {
    final pending = state.pendingAccount;
    if (pending == null) return false;
    final generation = expectedGeneration ?? ++_sessionGeneration;
    if (expectedGeneration == null) _refreshGeneration++;
    if (!_isCurrentGeneration(generation)) return false;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await BambuCloudClient.sendVerificationCode(
        region: pending.region,
        account: pending.account,
      );
      if (!_isCurrentGeneration(generation)) return false;
      state = state.copyWith(isLoading: false);
      return true;
    } catch (e) {
      if (!_isCurrentGeneration(generation)) return false;
      state = state.copyWith(
        isLoading: false,
        errorMessage:
            '发送验证码失败：${e.toString().replaceFirst('BambuCloudException: ', '')}',
      );
      return false;
    }
  }

  /// 第三步：用验证码换 token，完成登录。
  Future<bool> loginWithCode(String code) async {
    final pending = state.pendingAccount;
    if (pending == null) return false;
    final loginGeneration = ++_sessionGeneration;
    _refreshGeneration++;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final session = await BambuCloudClient.loginWithCode(
        region: pending.region,
        account: pending.account,
        code: code,
      );
      if (!_isCurrentGeneration(loginGeneration)) return false;
      return _completeLogin(
        session,
        pending.region,
        pending.account,
        pending.password,
        expectedSessionGeneration: loginGeneration,
      );
    } catch (e) {
      if (!_isCurrentGeneration(loginGeneration)) return false;
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString().replaceFirst('BambuCloudException: ', ''),
      );
      return false;
    }
  }

  /// 完成登录：持久化 + 拉取设备。
  ///
  /// 调用 addAccount（内部 upsertAccount + upsertSession + refresh），
  /// 再设置活跃账号，避免重复写入。
  Future<bool> _completeLogin(
    BambuCloudSession session,
    BambuRegion region,
    String account,
    String password, {
    required int expectedSessionGeneration,
  }) async {
    // 1. 保存账号 + session 到多账号存储（addAccount 内部做 upsert）
    try {
      await _ref.read(bambuAccountManagerProvider.notifier).addAccount(
            region: region,
            email: account,
            password: password,
            session: session,
          );
    } catch (e) {
      // 保存失败不阻塞登录流程，但记录到 state
      debugPrint('[BambuCloud] 保存账号到多账号存储失败: $e');
    }
    if (!_isCurrentGeneration(expectedSessionGeneration)) return false;
    // 2. 设为活跃账号
    await BambuCloudSessionStore.setActiveAccount(account, region);
    if (!_isCurrentGeneration(expectedSessionGeneration)) return false;
    // 3. 更新当前 session state + 拉取设备
    _activateSession(session);
    await refreshDevices();
    // refreshDevices may yield while another account is activated. Keep the
    // login result scoped to the account that initiated it; a same-account
    // token refresh is still allowed to replace the access token.
    if (!mounted ||
        state.session?.email != session.email ||
        state.session?.region != session.region) {
      return false;
    }
    // 4. 通知账号管理器刷新（活跃账号状态变了）
    try {
      await _ref.read(bambuAccountManagerProvider.notifier).refresh();
    } catch (e) {
      debugPrint('[BambuCloud] 通知账号管理器刷新失败: $e');
    }
    return mounted &&
        state.session?.email == session.email &&
        state.session?.region == session.region;
  }

  /// 用已有 session 直接设置当前活跃 session（账号切换时调用）。
  ///
  /// 不走登录流程，直接用 session 刷新设备列表。
  /// 供 `BambuAccountManagerNotifier.switchAccount` 调用。
  Future<void> setActiveSession(BambuCloudSession session) async {
    final sessionGeneration = _activateSession(session);
    try {
      await BambuCloudSessionStore.upsertSession(session);
    } catch (e) {
      debugPrint('[BambuCloud] setActiveSession 保存 session 失败: $e');
    }
    if (!_isCurrentSession(session, sessionGeneration)) return;
    await refreshDevices();
  }

  /// 重新拉取设备列表。
  Future<void> refreshDevices() async {
    final session = state.session;
    if (session == null) return;
    final sessionGeneration = _sessionGeneration;
    final refreshGeneration = ++_refreshGeneration;
    bool isCurrent() => _isCurrentRefresh(
          expected: session,
          sessionGeneration: sessionGeneration,
          refreshGeneration: refreshGeneration,
        );
    // 并发竞争修复：记录发起时的 session + 请求代际，响应返回后校验。
    // 防止切账号或较新的刷新请求被旧结果覆盖。
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final devices = await _deviceLoader(session);
      if (!isCurrent()) return;
      state = state.copyWith(devices: devices, isLoading: false);
      // 同步云端设备到本地 printers 表，使云模式用户可创建打印任务。
      // 单台设备同步失败不影响整体流程。
      for (final device in devices) {
        if (!isCurrent()) return;
        try {
          await _printerDao.upsertCloudDevice(device);
        } catch (e) {
          debugPrint('[BambuCloud] 同步设备 ${device.devId} 到本地失败: $e');
        }
        if (!isCurrent()) return;
      }
      if (!isCurrent()) return;
      // 自动选中第一台在线设备作为活跃打印机，让其自动连接云 MQTT。
      // 这样用户登录后无需手动点选就能在主界面看到实时任务进度。
      // 若已有活跃打印机则不覆盖用户选择。
      final activeSerial = _ref.read(activePrinterSerialProvider);
      if (activeSerial == null) {
        final onlineDevice = devices.where((d) => d.online).firstOrNull;
        if (onlineDevice != null) {
          if (!isCurrent()) return;
          await _ref
              .read(printerConnectionModeSelectionProvider.notifier)
              .select(onlineDevice.devId, BambuConnectionMode.cloud);
          if (!isCurrent()) return;
          await _ref
              .read(activePrinterSerialProvider.notifier)
              .set(onlineDevice.devId);
          if (!isCurrent()) return;
        }
      }
    } catch (e) {
      // 响应到达后校验：若期间已切账号或已有更新请求，丢弃本次错误。
      if (!isCurrent()) return;
      // P1-6: 基于错误分类针对性处理
      final msg = e is BambuCloudException
          ? e.message
          : e.toString().replaceFirst('BambuCloudException: ', '');

      if (e is BambuCloudException &&
          e.category == BambuCloudErrorCategory.authentication) {
        // 401 认证失败：优先使用 DPAPI 加密保存的凭据透明续登。
        // 服务端若要求验证码，_autoRelogin 会给出明确的手动验证提示。
        final account = await BambuCloudSessionStore.loadAccountFor(
          session.email,
          session.region,
        );
        if (!isCurrent()) return;
        if (account != null &&
            account.email == session.email &&
            account.region == session.region) {
          await _autoRelogin(
            region: account.region,
            account: account.email,
            password: account.password,
            expectedSession: session,
            expectedSessionGeneration: sessionGeneration,
            expectedRefreshGeneration: refreshGeneration,
          );
        } else {
          await BambuCloudSessionStore.removeSession(
            session.email,
            session.region,
          );
          if (!isCurrent()) return;
          _sessionGeneration++;
          _refreshGeneration++;
          state = BambuCloudState(
            errorMessage: '登录已失效：$msg，请重新登录',
          );
        }
        return;
      }

      if (e is BambuCloudException &&
          e.category == BambuCloudErrorCategory.protocol) {
        // 404 协议变更：保留 session（用户或可继续使用 LAN），但提示更新应用
        if (!isCurrent()) return;
        state = state.copyWith(
          isLoading: false,
          errorMessage: '拓竹云协议可能已变更：$msg，请更新应用。'
              '如已配置 LAN 直连可继续使用。',
        );
        return;
      }

      // 网络/服务器/限流/权限：保留 session，提示稍后重试
      if (!isCurrent()) return;
      state = state.copyWith(
        isLoading: false,
        errorMessage: '拉取设备列表失败：$msg',
      );
    }
  }

  /// 退出登录。
  ///
  /// - [removeFromManager] 为 true（默认）时，同时从多账号存储中删除当前账号。
  ///   `removeAccount` 会自动切换到下一个账号或清空活跃状态。
  /// - [removeFromManager] 为 false 时，仅清除活跃 session，保留多账号存储中的
  ///   账号记录。供"仅切换不删除"或账号被删除后清空活跃 session 使用。
  Future<void> logout({bool removeFromManager = true}) async {
    final session = state.session;
    // 使所有正在进行的刷新/自动续登失效。后续清理只能在该代际仍为当前
    // 时回写 state，避免登出旧账号时把切换后的账号清空。
    final logoutGeneration = ++_sessionGeneration;
    _refreshGeneration++;

    if (removeFromManager && session != null) {
      // 从多账号存储中删除账号；removeAccount 会处理活跃账号切换或清空。
      try {
        await _ref
            .read(bambuAccountManagerProvider.notifier)
            .removeAccount(session.email, session.region);
        return;
      } catch (e) {
        // 失败时回退到下方清理
        debugPrint('[BambuCloud] removeAccount 失败，回退到本地清理: $e');
      }
    }

    // 仅清除活跃 session（保留多账号存储中的账号记录）。
    // 直接用当前 session 信息删除，避免依赖活跃 key（可能已被 removeAccount 清除）。
    if (session != null) {
      try {
        await BambuCloudSessionStore.removeSession(
          session.email,
          session.region,
        );
      } catch (e) {
        debugPrint('[BambuCloud] removeSession 失败: $e');
      }
    }
    // The active-account pointer is shared by all sessions. Re-check the
    // generation immediately before clearing it so a concurrent account
    // switch cannot be undone by an older logout operation.
    if (!mounted || logoutGeneration != _sessionGeneration) return;
    await BambuCloudSessionStore.clearActiveAccount();
    if (!mounted || logoutGeneration != _sessionGeneration) return;
    state = const BambuCloudState();
  }
}

/// 云连接状态 Provider。
final bambuCloudProvider =
    StateNotifierProvider<BambuCloudNotifier, BambuCloudState>((ref) {
  return BambuCloudNotifier(ref);
});
