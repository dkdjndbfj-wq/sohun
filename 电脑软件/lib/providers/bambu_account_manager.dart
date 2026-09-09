import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/external/printer/bambu_cloud_client.dart';
import '../data/external/printer/bambu_cloud_models.dart';
import '../data/external/printer/bambu_cloud_session_store.dart';
import '../data/external/printer/bambu_printer_models.dart';
import '../data/external/slicer/bambu_studio_detector.dart';
import '../data/external/slicer/bambu_studio_lan_config_writer.dart';
import '../data/external/slicer/bambu_studio_switch_user_service.dart';
import 'account_session_coordinator.dart';
import 'bambu_cloud_provider.dart';
import 'printer_connection_provider.dart';

/// 账号健康检查结果（[BambuAccountManagerNotifier.checkAllAccountsHealth] 返回值）。
///
/// 字段含义：
/// - [total]：参与检查的账号总数
/// - [ok]：token 有效的账号数（API 调用成功）
/// - [expired]：token 已过期的账号数（本地判定 + API 401）
/// - [unknown]：网络/服务端错误，无法判定
/// - [errors]：每个失败账号的错误信息，key 为 `email|region_code`
/// - [skipped]：是否因并发保护跳过本次检查
class AccountHealthSummary {
  final int total;
  final int ok;
  final int expired;
  final int unknown;
  final Map<String, String> errors;
  final bool skipped;

  const AccountHealthSummary({
    required this.total,
    required this.ok,
    required this.expired,
    required this.unknown,
    required this.errors,
    this.skipped = false,
  });

  /// 是否所有账号都健康
  bool get allOk => expired == 0 && unknown == 0 && total > 0;

  /// 摘要文案：「3 账号 · 2 有效 · 1 过期 · 0 异常」
  String get summaryText {
    final parts = <String>['$total 账号'];
    if (ok > 0) parts.add('$ok 有效');
    if (expired > 0) parts.add('$expired 过期');
    if (unknown > 0) parts.add('$unknown 异常');
    return parts.join(' · ');
  }
}

/// 多账号管理状态。
class BambuAccountManagerState {
  /// 所有已存储账号。
  final List<BambuCloudAccount> accounts;

  /// 所有已存储的 session，key 为 "email|region_code"。
  /// 用于在不阻塞 UI 的情况下显示 token 状态、最后登录时间等信息。
  final Map<String, BambuCloudSession> sessions;

  /// 当前活跃账号 email。
  final String? activeAccountEmail;

  /// 当前活跃账号区域。
  final BambuRegion? activeRegion;

  /// 是否在加载中。
  final bool isLoading;

  /// 是否在切换中（防止并发切换）。
  final bool isSwitching;

  /// 最后一次错误信息（null 表示无错误）。
  final String? lastError;

  /// 最后一次错误发生时间。
  final DateTime? lastErrorAt;

  /// 上一次切换的源账号 email（用于"撤销切换"功能）。
  ///
  /// 切换成功后设置，3 秒内可调用 [undoSwitch] 切回。
  /// 切换撤销超时或新切换发生时清空。
  final String? lastSwitchedFromEmail;

  /// 上一次切换的源账号 region。
  final BambuRegion? lastSwitchedFromRegion;

  /// Bambu Studio 当前账号与本软件 active account 不一致（启动时检测）。
  ///
  /// true 时 UI 应显示横幅提示用户「Bambu Studio 账号已变更，点击同步」。
  /// 调用 [BambuAccountManagerNotifier.syncFromBambuStudio] 后清除。
  final bool bsAccountMismatch;

  /// Bambu Studio token 写入失败（switch_user_tool 失败）。
  ///
  /// true 时 conf 已改但 token 未写入，BS 重启会显示未登录。
  /// UI 应提示用户「token 写入失败，请在 Bambu Studio 手动登录一次」。
  /// 下次切换账号时清除。
  final bool bsTokenWriteFailed;

  const BambuAccountManagerState({
    this.accounts = const [],
    this.sessions = const {},
    this.activeAccountEmail,
    this.activeRegion,
    this.isLoading = false,
    this.isSwitching = false,
    this.lastError,
    this.lastErrorAt,
    this.lastSwitchedFromEmail,
    this.lastSwitchedFromRegion,
    this.bsAccountMismatch = false,
    this.bsTokenWriteFailed = false,
  });

  bool get hasMultipleAccounts => accounts.length > 1;
  bool get isActive => activeAccountEmail != null;
  bool get hasError => lastError != null;

  /// 是否有任意账号的 token 已过期（用于全局过期提示）。
  bool get hasExpiredAccount => sessions.values.any((s) => s.isExpired);

  /// 是否可以撤销上一次切换。
  bool get canUndoSwitch =>
      lastSwitchedFromEmail != null && lastSwitchedFromRegion != null;

  /// 获取指定账号的 session。
  BambuCloudSession? sessionFor(String email, BambuRegion region) {
    return sessions[_sessionKey(email, region)];
  }

  /// 生成 session map 的 key。
  static String _sessionKey(String email, BambuRegion region) =>
      '$email|${region.code}';

  BambuAccountManagerState copyWith({
    List<BambuCloudAccount>? accounts,
    Map<String, BambuCloudSession>? sessions,
    String? activeAccountEmail,
    BambuRegion? activeRegion,
    bool? isLoading,
    bool? isSwitching,
    String? lastError,
    DateTime? lastErrorAt,
    String? lastSwitchedFromEmail,
    BambuRegion? lastSwitchedFromRegion,
    bool? bsAccountMismatch,
    bool? bsTokenWriteFailed,
    bool clearActive = false,
    bool clearError = false,
    bool clearUndo = false,
    bool clearBsMismatch = false,
    bool clearBsTokenFail = false,
  }) {
    return BambuAccountManagerState(
      accounts: accounts ?? this.accounts,
      sessions: sessions ?? this.sessions,
      activeAccountEmail:
          clearActive ? null : (activeAccountEmail ?? this.activeAccountEmail),
      activeRegion: clearActive ? null : (activeRegion ?? this.activeRegion),
      isLoading: isLoading ?? this.isLoading,
      isSwitching: isSwitching ?? this.isSwitching,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastErrorAt: clearError ? null : (lastErrorAt ?? this.lastErrorAt),
      lastSwitchedFromEmail: clearUndo
          ? null
          : (lastSwitchedFromEmail ?? this.lastSwitchedFromEmail),
      lastSwitchedFromRegion: clearUndo
          ? null
          : (lastSwitchedFromRegion ?? this.lastSwitchedFromRegion),
      bsAccountMismatch: clearBsMismatch
          ? false
          : (bsAccountMismatch ?? this.bsAccountMismatch),
      bsTokenWriteFailed: clearBsTokenFail
          ? false
          : (bsTokenWriteFailed ?? this.bsTokenWriteFailed),
    );
  }

  /// 清除错误状态。
  BambuAccountManagerState clearError() => copyWith(clearError: true);
}

/// 多账号管理器。
///
/// 管理多个拓竹云账号的存储、切换、删除。与 [bambuCloudProvider] 配合：
/// - 账号切换时通过 [accountSessionCoordinatorProvider] 写入新 session，
///   `BambuCloudNotifier` 在构造时 ref.listen 该协调器，自动应用新 session
///   （不再直接调用 `bambuCloudProvider.notifier.setActiveSession`，打破循环依赖）。
/// - 登录成功后由 `BambuCloudNotifier._completeLogin` 调用 [addAccount]。
/// - 登出时由 `BambuCloudNotifier.logout` 调用 [removeAccount]。
/// - 删除活跃账号且无其他账号时，仍直接调用
///   `bambuCloudProvider.notifier.logout(removeFromManager: false)` 清空活跃 session
///   （此路径为单向调用，不构成循环）。
///
/// **错误处理**：
/// - 所有操作失败时记录错误到 state.lastError，不静默吞掉。
/// - 调用方可通过 `ref.read(bambuAccountManagerProvider).lastError` 获取错误信息。
/// - 切换操作有并发保护（isSwitching 标志），防止快速点击导致状态混乱。
class BambuAccountManagerNotifier
    extends StateNotifier<BambuAccountManagerState> {
  BambuAccountManagerNotifier(this._ref)
      : super(const BambuAccountManagerState()) {
    _init();
  }

  final Ref _ref;

  /// P1-15 修复：健康检查互斥锁，避免并发执行
  /// checkAllAccountsHealth 中 isSwitching 检查与设置非原子，
  /// 用 Completer 实现真正的互斥

  /// 初始化：迁移旧单账号数据 + 加载账号列表 + 检测 BS 账号一致性。
  Future<void> _init() async {
    state = state.copyWith(isLoading: true);
    try {
      await BambuCloudSessionStore.migrateFromSingleAccount();
      await refresh();
      // P0 修复：异步操作后检查 mounted
      if (!mounted) return;
      // 启动时检测 Bambu Studio 账号是否与本软件 active account 一致
      await _checkBambuStudioAccountMismatch();
      if (!mounted) return;
      // 启动时拉取所有账号的云端设备列表（多账号聚合）
      await _ref
          .read(allCloudDevicesProvider.notifier)
          .refresh(forceRefresh: true);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        lastError: '初始化失败：$e',
        lastErrorAt: DateTime.now(),
      );
    }
  }

  /// 检测 Bambu Studio 当前账号与本软件 active account 是否一致。
  ///
  /// 读取 BambuStudio.conf 的 `preset_folder`(userId) 和 `region`，
  /// 与本软件 active account 的 userId/region 比较。不一致时设置
  /// `bsAccountMismatch=true`，供 UI 显示横幅提示。
  ///
  /// 静默执行，任何异常都吞掉（BS 未安装/未登录不报错）。
  Future<void> _checkBambuStudioAccountMismatch() async {
    if (!Platform.isWindows) return;
    try {
      if (!BambuStudioLanConfigWriter.isInstalled()) return;

      final bsUserId = BambuStudioLanConfigWriter.getCurrentUserId();
      final bsRegionCode = BambuStudioLanConfigWriter.getCurrentRegion();
      // BS 未登录过（preset_folder 为空）不视为不一致
      if (bsUserId == null || bsUserId.isEmpty) return;

      // LAN-only 模式：本软件从未添加过云账号（accounts 为空），
      // 说明用户主动选择纯 LAN 模式，不应弹 BS 同步横幅打扰。
      if (state.accounts.isEmpty) return;

      // 本软件无 active account 但 BS 有登录账号 → 视为不一致
      if (state.activeAccountEmail == null || state.activeRegion == null) {
        state = state.copyWith(bsAccountMismatch: true);
        return;
      }

      // 提取本软件 active account 的 userId
      final session = state.sessionFor(
        state.activeAccountEmail!,
        state.activeRegion!,
      );
      if (session == null) {
        state = state.copyWith(bsAccountMismatch: true);
        return;
      }
      final localUserId = session.username.startsWith('u_')
          ? session.username.substring(2)
          : session.username;

      // 比较 userId 和 region
      final mismatch =
          localUserId != bsUserId || state.activeRegion!.code != bsRegionCode;
      state = state.copyWith(
        bsAccountMismatch: mismatch,
        clearBsMismatch: !mismatch,
      );
    } catch (_) {
      // 静默吞掉异常，不影响启动
    }
  }

  /// 从 Bambu Studio 同步账号到本软件（反向同步）。
  ///
  /// 读取 BambuStudio.conf 的 userId + region，在本软件账号列表中
  /// 找到匹配的账号并切换为 active account。
  ///
  /// 返回值：
  /// - 成功：true，已切换到匹配的账号
  /// - 失败：false，BS 未安装 / 未登录 / 匹配的账号不在列表里
  ///
  /// 失败原因记录到 state.lastError。
  Future<bool> syncFromBambuStudio() async {
    if (!Platform.isWindows) return false;
    try {
      if (!BambuStudioLanConfigWriter.isInstalled()) {
        state = state.copyWith(
          lastError: '未检测到 Bambu Studio 安装',
          lastErrorAt: DateTime.now(),
        );
        return false;
      }

      final bsUserId = BambuStudioLanConfigWriter.getCurrentUserId();
      final bsRegionCode = BambuStudioLanConfigWriter.getCurrentRegion();
      if (bsUserId == null || bsUserId.isEmpty) {
        state = state.copyWith(
          lastError: 'Bambu Studio 未登录任何账号',
          lastErrorAt: DateTime.now(),
        );
        return false;
      }

      // 遍历所有 session，匹配 userId
      final region = (bsRegionCode == 'Overseas')
          ? BambuRegion.overseas
          : BambuRegion.china;
      String? matchedEmail;
      for (final entry in state.sessions.entries) {
        final s = entry.value;
        final uid =
            s.username.startsWith('u_') ? s.username.substring(2) : s.username;
        if (uid == bsUserId && s.region.code == region.code) {
          matchedEmail = s.email;
          break;
        }
      }

      if (matchedEmail == null) {
        state = state.copyWith(
          lastError: 'Bambu Studio 当前账号 (userId=$bsUserId) 不在本软件账号列表中，'
              '请先登录该账号',
          lastErrorAt: DateTime.now(),
        );
        return false;
      }

      // 切换到匹配的账号（静默，不再反向同步 BS）
      final ok = await _silentSwitch(matchedEmail, region);
      if (ok) {
        state = state.copyWith(clearBsMismatch: true, clearError: true);
      }
      return ok;
    } catch (e) {
      state = state.copyWith(
        lastError: '从 Bambu Studio 同步失败：$e',
        lastErrorAt: DateTime.now(),
      );
      return false;
    }
  }

  /// 刷新账号列表（外部修改后调用）。
  ///
  /// 同时加载所有 session，缓存到 state.sessions 供 UI 显示
  /// token 状态、最后登录时间等信息，避免每个卡片单独异步加载。
  /// 账号列表按 pinned > sortOrder > email 字母序排序后返回。
  Future<void> refresh() async {
    try {
      final accounts = await BambuCloudSessionStore.loadAllAccounts();
      final sessionsList = await BambuCloudSessionStore.loadAllSessions();
      final activeKey = await BambuCloudSessionStore.loadActiveAccountKey();
      // P0 修复：异步操作后检查 mounted
      if (!mounted) return;
      final parsed = _parseActiveKey(activeKey);

      // 构建 session map：key 为 "email|region_code"
      final sessionMap = <String, BambuCloudSession>{};
      for (final s in sessionsList) {
        sessionMap['${s.email}|${s.region.code}'] = s;
      }

      // 排序：pinned 优先 → sortOrder 升序 → lastUsedAt 倒序（最近使用靠前）→ email 字母序
      final sortedAccounts = List<BambuCloudAccount>.from(accounts);
      sortedAccounts.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        if (a.sortOrder != b.sortOrder) {
          return a.sortOrder.compareTo(b.sortOrder);
        }
        // 最近使用排序：lastUsedAt 较新的靠前；都为 null 时退回 email 字母序
        final aTime = a.lastUsedAt;
        final bTime = b.lastUsedAt;
        if (aTime != null && bTime != null) {
          return bTime.compareTo(aTime); // 倒序：b 比 a 新则 b 在前
        }
        if (aTime != null) return -1; // a 有时间，b 没有 → a 在前
        if (bTime != null) return 1; // b 有时间，a 没有 → b 在前
        return a.email.compareTo(b.email);
      });

      if (!mounted) return;
      state = state.copyWith(
        accounts: sortedAccounts,
        sessions: sessionMap,
        activeAccountEmail: parsed?.$1,
        activeRegion: parsed?.$2,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        lastError: '刷新账号列表失败：$e',
        lastErrorAt: DateTime.now(),
      );
    }
  }

  /// 更新账号属性（nickname/pinned/sortOrder/password）。
  ///
  /// 用于：
  /// - 设置/修改账号备注名
  /// - 置顶/取消置顶
  /// - 拖拽排序后写入 sortOrder
  /// - 修改密码（暂未使用）
  Future<bool> updateAccount(BambuCloudAccount updated) async {
    try {
      await BambuCloudSessionStore.upsertAccount(updated);
      await refresh();
      return true;
    } catch (e) {
      state = state.copyWith(
        lastError: '更新账号失败：$e',
        lastErrorAt: DateTime.now(),
      );
      return false;
    }
  }

  /// 批量更新账号排序（拖拽排序后调用）。
  ///
  /// 按传入的 accounts 顺序依次写入 sortOrder = index + 1。
  /// 不修改 pinned 状态（置顶账号的相对顺序保持，但仍排在最前）。
  Future<bool> reorderAccounts(List<BambuCloudAccount> accounts) async {
    try {
      for (var i = 0; i < accounts.length; i++) {
        final a = accounts[i].copyWith(sortOrder: i + 1);
        await BambuCloudSessionStore.upsertAccount(a);
      }
      await refresh();
      return true;
    } catch (e) {
      state = state.copyWith(
        lastError: '排序账号失败：$e',
        lastErrorAt: DateTime.now(),
      );
      return false;
    }
  }

  /// 解析活跃账号 key（"email|region_code"）为 email + region。
  static (String, BambuRegion)? _parseActiveKey(String? key) {
    if (key == null) return null;
    final idx = key.lastIndexOf('|');
    if (idx < 0) return null;
    final email = key.substring(0, idx);
    final regionCode = key.substring(idx + 1);
    final region =
        regionCode == 'Overseas' ? BambuRegion.overseas : BambuRegion.china;
    return (email, region);
  }

  /// 添加新账号（登录成功后调用）。
  ///
  /// 保存账号和 session，但不会切换活跃账号。
  /// 活跃账号的设置由调用方（如 `_completeLogin`）负责。
  Future<void> addAccount({
    required BambuRegion region,
    required String email,
    required String password,
    required BambuCloudSession session,
  }) async {
    try {
      await BambuCloudSessionStore.upsertAccount(
        BambuCloudAccount(region: region, email: email, password: password),
      );
      await BambuCloudSessionStore.upsertSession(session);
      await refresh();
      // 新增账号后刷新所有账号的云端设备列表（多账号聚合）
      _ref.read(allCloudDevicesProvider.notifier).refresh(forceRefresh: true);
    } catch (e) {
      state = state.copyWith(
        lastError: '保存账号失败：$e',
        lastErrorAt: DateTime.now(),
      );
    }
  }

  /// 切换活跃账号。
  ///
  /// 1. 检查是否已在切换中（并发保护）。
  /// 2. 设置 active account。
  /// 3. 通知 [bambuCloudProvider] 用新 session 刷新设备列表。
  /// 4. 记录切换前的活跃账号到 `lastSwitchedFrom*`，供 [undoSwitch] 使用。
  ///
  /// P1-7: 事务性保护——若第 3 步失败，回滚第 2 步的 active account 设置，
  /// 避免存储与 provider 状态不一致。
  ///
  /// 返回 true 表示切换成功；false 表示账号不存在、没有 session 或正在切换中。
  /// 失败原因记录到 state.lastError。
  Future<bool> switchAccount(String email, BambuRegion region) async {
    // 并发保护：正在切换中时拒绝新的切换请求
    if (state.isSwitching) {
      debugPrint('[AccountManager] 切换被拒绝：已有切换在进行中');
      return false;
    }

    // 切换到自己则什么都不做
    if (state.activeAccountEmail == email && state.activeRegion == region) {
      return true;
    }

    // 记录切换前的活跃账号，供 undoSwitch 使用 + 事务回滚
    final previousEmail = state.activeAccountEmail;
    final previousRegion = state.activeRegion;

    state = state.copyWith(isSwitching: true, clearError: true);
    try {
      var session = await BambuCloudSessionStore.loadSessionFor(
        email,
        region,
      );
      if (!mounted) return false;
      if (session == null) {
        state = state.copyWith(
          isSwitching: false,
          lastError: '该账号的登录信息已丢失，请重新登录',
          lastErrorAt: DateTime.now(),
        );
        return false;
      }

      // token 过期检查
      if (session.isExpired) {
        final account = _findAccount(email, region);
        if (account == null) {
          state = state.copyWith(
            isSwitching: false,
            lastError: '该账号的登录凭据已丢失，请重新登录',
            lastErrorAt: DateTime.now(),
          );
          return false;
        }
        final login = await BambuCloudClient.loginWithPassword(
          region: region,
          account: email,
          password: account.password,
        );
        if (login.needsVerificationCode) {
          state = state.copyWith(
            isSwitching: false,
            lastError: '该账号需要验证码确认，请通过“添加账号”重新验证',
            lastErrorAt: DateTime.now(),
          );
          return false;
        }
        session = login.session!;
        await BambuCloudSessionStore.upsertSession(session);
      }

      await BambuCloudSessionStore.setActiveAccount(email, region);
      // 通过 accountSessionCoordinatorProvider 通知 bambuCloudProvider 应用新 session，
      // 打破 bambuAccountManagerProvider ↔ bambuCloudProvider 的直接循环依赖。
      // bambuCloudProvider 在构造时 ref.listen 本协调器，状态变化时自动调用 setActiveSession。
      //
      // 说明：原 try-catch 回滚逻辑已移除，因为 setActiveSession 内部已捕获所有错误
      // （upsertSession 失败只 debugPrint，refreshDevices 失败只写 state.errorMessage），
      // 不会抛出异常，回滚分支实际无法触达。外层 catch 仍保留 setActiveAccount 回滚，
      // 覆盖 upsertAccount/refresh 等步骤的异常。如未来 setActiveSession 改为可抛异常，
      // 需在此处恢复针对它的回滚逻辑（但需通过协调器或回调拿到错误信号）。
      _ref.read(accountSessionCoordinatorProvider.notifier).state = session;
      // 更新 lastUsedAt：切换成功后写入当前时间
      // 注意：必须在 refresh() 之前写入，否则排序仍按旧 lastUsedAt
      final updated = _findAccount(email, region);
      if (updated != null) {
        await BambuCloudSessionStore.upsertAccount(
          updated.copyWith(lastUsedAt: DateTime.now()),
        );
      }
      await refresh();
      if (!mounted) return false;
      // 切换 Bambu Studio 账号配置（preset 目录 + region + iot_environment）
      // 失败不影响本软件的账号切换，只记录日志
      await _switchBambuStudioAccount(session);
      if (!mounted) return false;
      // 记录源账号供撤销；clearUndo=false 保留之前的源（若是 undo 则不覆盖）
      state = state.copyWith(
        isSwitching: false,
        clearError: true,
        lastSwitchedFromEmail: previousEmail,
        lastSwitchedFromRegion: previousRegion,
      );
      // 切换账号后刷新所有账号的云端设备列表（多账号聚合）
      _ref.read(allCloudDevicesProvider.notifier).refresh(forceRefresh: true);
      return true;
    } catch (e) {
      // P0-8 修复：外层 catch 补充回滚 setActiveAccount。
      // 若 upsertAccount/refresh 等步骤异常，setActiveAccount 已指向新账号但
      // provider 状态可能不一致。回滚到原活跃账号保证存储与状态一致。
      final hadPreviousActive = previousEmail != null && previousRegion != null;
      try {
        if (hadPreviousActive) {
          await BambuCloudSessionStore.setActiveAccount(
            previousEmail,
            previousRegion,
          );
        } else {
          await BambuCloudSessionStore.clearActiveAccount();
        }
      } catch (_) {
        // 回滚失败不掩盖原始错误
      }
      if (!mounted) return false;
      state = state.copyWith(
        isSwitching: false,
        lastError: '切换账号失败：$e',
        lastErrorAt: DateTime.now(),
      );
      return false;
    }
  }

  /// 切换 Bambu Studio 的账号配置（conf + token 免密切换）。
  ///
  /// 流程：
  /// 1. 检查 BS 是否安装，未安装静默跳过
  /// 2. 从 [session] 提取 userId（`u_xxx` → `xxx`）和 region
  /// 3. 修改 BambuStudio.conf（会先 kill 正在运行的 BS）
  /// 4. 通过 switch_user_tool.exe 写入 token
  /// 5. token 写入成功 + BS 之前在运行 → 重启 BS
  ///    token 写入失败 → 不重启 BS，设置 `bsTokenWriteFailed=true` 提示手动登录
  ///
  /// 全程 try-catch，失败只记录日志，不影响本软件的账号切换。
  Future<void> _switchBambuStudioAccount(BambuCloudSession session) async {
    if (!Platform.isWindows) return;
    // BS 未安装静默跳过
    if (!BambuStudioLanConfigWriter.isInstalled()) return;
    try {
      // 从 session.username 提取 userId（"u_1234567890" → "1234567890"）
      final username = session.username;
      final userId =
          username.startsWith('u_') ? username.substring(2) : username;
      if (userId.isEmpty) {
        debugPrint('[AccountManager] 无法提取 userId，跳过 Bambu Studio 切换');
        return;
      }

      final wasRunning = await BambuStudioLanConfigWriter.isRunning();
      // 步骤 1: 切换 conf（preset 目录 + region + iot_environment），会先 kill BS
      final ok = await BambuStudioLanConfigWriter.switchAccount(
        userId: userId,
        regionCode: session.region.code,
      );
      if (!ok) {
        debugPrint('[AccountManager] Bambu Studio conf 切换失败');
        // 场景7：conf 切换失败也设置提示标记，让用户知道 BS 未切换成功
        state = state.copyWith(bsTokenWriteFailed: true);
        return;
      }

      // 步骤 2: 通过 switch_user_tool 将 token 加密写入 BambuNetworkEngine.conf
      // 此时 BS 已被步骤 1 kill，不会占用配置文件
      final tokenResult = await BambuStudioSwitchUserService.switchUser(
        session: session,
      );
      debugPrint(
        '[AccountManager] Bambu Studio token 写入: ${tokenResult.success}'
        '${tokenResult.error != null ? ' (${tokenResult.error})' : ''}',
      );

      if (tokenResult.success) {
        // token 写入成功：清除失败标记，如果 BS 之前在运行则重启
        state = state.copyWith(clearBsTokenFail: true);
        // 批量同步当前所有 LAN access code 到 BS conf
        // （BS conf 切换后 user_access_code 可能被重置，需重新写入）
        try {
          final lanList = _ref.read(printerConnectionListProvider);
          final entries = <String, String>{};
          for (final c in lanList) {
            if (c.mode == BambuConnectionMode.lan &&
                c.serial.isNotEmpty &&
                c.accessCode.isNotEmpty) {
              entries[c.serial] = c.accessCode;
            }
          }
          if (entries.isNotEmpty) {
            await BambuStudioLanConfigWriter.writeLanAccessCodes(
              entries: entries,
            );
            debugPrint(
              '[AccountManager] 已同步 ${entries.length} 台 LAN access code 到 BS',
            );
          }
        } catch (e) {
          debugPrint('[AccountManager] 同步 LAN access code 到 BS 失败: $e');
        }
        if (wasRunning) {
          final detector = BambuStudioDetector();
          final launched = await detector.launch();
          debugPrint('[AccountManager] Bambu Studio 重启: $launched');
        }
        debugPrint(
          '[AccountManager] Bambu Studio 账号已切换 → userId=$userId, region=${session.region.code}',
        );
      } else {
        // token 写入失败：不重启 BS（重启会显示未登录），设置失败标记提示用户手动登录
        state = state.copyWith(bsTokenWriteFailed: true);
        debugPrint('[AccountManager] Bambu Studio token 写入失败，不重启 BS，需手动登录');
      }
    } catch (e) {
      debugPrint('[AccountManager] Bambu Studio 切换异常（不影响账号切换）: $e');
    }
  }

  /// 撤销上一次切换（3 秒内调用有效，由 UI 控制时机）。
  ///
  /// 切换回 [lastSwitchedFromEmail]/[lastSwitchedFromRegion]，
  /// 并清空 undo 记录（避免循环撤销）。
  Future<bool> undoSwitch() async {
    final fromEmail = state.lastSwitchedFromEmail;
    final fromRegion = state.lastSwitchedFromRegion;
    if (fromEmail == null || fromRegion == null) return false;

    // 临时清空 undo 记录，避免下一次 undo 又切回去（不支持多步撤销）
    state = state.copyWith(clearUndo: true);

    // 走 silent 切换：不重新记录 lastSwitchedFrom
    return _silentSwitch(fromEmail, fromRegion);
  }

  /// Expire the one-step undo window without changing the active account.
  void expireUndo() {
    if (!state.canUndoSwitch) return;
    state = state.copyWith(clearUndo: true);
  }

  /// 静默切换（不更新 lastSwitchedFrom，用于 undoSwitch）。
  Future<bool> _silentSwitch(String email, BambuRegion region) async {
    if (state.isSwitching) return false;
    state = state.copyWith(isSwitching: true, clearError: true);
    try {
      final session =
          await BambuCloudSessionStore.loadSessionFor(email, region);
      if (!mounted) return false;
      if (session == null || session.isExpired) {
        state = state.copyWith(isSwitching: false);
        return false;
      }
      await BambuCloudSessionStore.setActiveAccount(email, region);
      if (!mounted) return false;
      // 通过协调器通知 bambuCloudProvider 应用新 session（打破循环依赖，详见 switchAccount 注释）
      _ref.read(accountSessionCoordinatorProvider.notifier).state = session;
      // 同步更新 lastUsedAt（与 switchAccount 行为一致）
      final updated = _findAccount(email, region);
      if (updated != null) {
        await BambuCloudSessionStore.upsertAccount(
          updated.copyWith(lastUsedAt: DateTime.now()),
        );
      }
      await refresh();
      if (!mounted) return false;
      state = state.copyWith(isSwitching: false, clearError: true);
      return true;
    } catch (e) {
      if (!mounted) return false;
      state = state.copyWith(
        isSwitching: false,
        lastError: '撤销切换失败：$e',
        lastErrorAt: DateTime.now(),
      );
      return false;
    }
  }

  /// 在当前 state.accounts 中查找指定账号（按 email + region 匹配）。
  BambuCloudAccount? _findAccount(String email, BambuRegion region) {
    for (final a in state.accounts) {
      if (a.email == email && a.region == region) return a;
    }
    return null;
  }

  /// 批量验证所有账号 token 有效性（健康检查）。
  ///
  /// 对每个账号调用 [BambuCloudClient.getDeviceList] 验证 token 是否可用：
  /// - 成功：session 有效，标记为 ok
  /// - 401/认证失败：session 已过期
  /// - 其他错误（网络/服务端）：标记为 unknown，不影响过期判断
  ///
  /// 返回健康统计 [AccountHealthSummary]，调用方可读取做 UI 提示。
  /// 此方法不会修改 session 数据（仅读取验证），失败账号的 session 保留。
  ///
  /// **并发保护**：使用 isSwitching 标志防止与其他切换操作并发；
  /// 单次健康检查预计耗时 N×1s（N=账号数，串行调用避免触发拓竹限流）。
  Future<AccountHealthSummary> checkAllAccountsHealth() async {
    if (state.isSwitching) {
      return AccountHealthSummary(
        total: state.accounts.length,
        ok: 0,
        expired: 0,
        unknown: state.accounts.length,
        errors: const {},
        skipped: true,
      );
    }
    state = state.copyWith(isSwitching: true, clearError: true);
    final errors = <String, String>{}; // key: "email|region", value: 错误信息
    int okCount = 0;
    int expiredCount = 0;
    int unknownCount = 0;
    try {
      for (final account in state.accounts) {
        final key = account.uniqueKey;
        try {
          final session = await BambuCloudSessionStore.loadSessionFor(
            account.email,
            account.region,
          );
          if (!mounted) {
            return AccountHealthSummary(
              total: state.accounts.length,
              ok: okCount,
              expired: expiredCount,
              unknown: unknownCount,
              errors: errors,
            );
          }
          if (session == null) {
            errors[key] = 'session 不存在';
            unknownCount++;
            continue;
          }
          if (session.isExpired) {
            // 本地判定的过期，不需要 API 验证
            errors[key] = 'token 已过期（本地判定）';
            expiredCount++;
            continue;
          }
          // 调用 getDeviceList 验证 token 真实有效性
          await BambuCloudClient.getDeviceList(session);
          okCount++;
        } catch (e) {
          final msg = e is BambuCloudException
              ? e.message
              : e.toString().replaceFirst('BambuCloudException: ', '');
          // P1-6/P1-7: 用 BambuCloudException.category 精确判断 auth 错误
          // （替代旧的字符串匹配，覆盖更准：401/403 都视为认证失效）
          if (e is BambuCloudException &&
              (e.category == BambuCloudErrorCategory.authentication ||
                  e.category == BambuCloudErrorCategory.permission)) {
            errors[key] = 'token 无效：$msg';
            expiredCount++;
          } else {
            errors[key] = '网络错误：$msg';
            unknownCount++;
          }
        }
      }
      // 刷新 state（可能 sessions 中有变化，虽然此方法本身不修改 session）
      await refresh();
      if (!mounted) {
        return AccountHealthSummary(
          total: 0,
          ok: okCount,
          expired: expiredCount,
          unknown: unknownCount,
          errors: errors,
        );
      }
      return AccountHealthSummary(
        total: state.accounts.length,
        ok: okCount,
        expired: expiredCount,
        unknown: unknownCount,
        errors: errors,
      );
    } catch (e) {
      if (!mounted) {
        return AccountHealthSummary(
          total: 0,
          ok: okCount,
          expired: expiredCount,
          unknown: unknownCount,
          errors: errors,
        );
      }
      state = state.copyWith(
        isSwitching: false,
        lastError: '账号健康检查失败：$e',
        lastErrorAt: DateTime.now(),
      );
      return AccountHealthSummary(
        total: state.accounts.length,
        ok: okCount,
        expired: expiredCount,
        unknown: unknownCount,
        errors: errors,
      );
    } finally {
      // 确保状态被复位（如果上面没 refresh 也要复位）
      if (mounted && state.isSwitching) {
        state = state.copyWith(isSwitching: false, clearError: true);
      }
    }
  }

  /// 删除账号。
  ///
  /// 1. 从存储中删除账号和 session。
  /// 2. P1-7: 清理 undo 状态——若删除的是 undo 源账号，清空 undo 记录
  ///    （否则 undoSwitch 会尝试切到已删除的账号）。
  /// 3. 如果删的是活跃账号，切换到第一个；若没有其他账号，清空活跃状态。
  Future<void> removeAccount(String email, BambuRegion region) async {
    try {
      final wasActive =
          state.activeAccountEmail == email && state.activeRegion == region;
      // P1-7: 清理 undo 状态——若 undo 源账号被删除，清空 undo 记录
      final wasUndoSource = state.lastSwitchedFromEmail == email &&
          state.lastSwitchedFromRegion == region;

      await BambuCloudSessionStore.removeAccount(email, region);
      await BambuCloudSessionStore.removeSession(email, region);
      if (!mounted) return;

      if (wasActive) {
        final remaining = await BambuCloudSessionStore.loadAllAccounts();
        if (!mounted) return;
        if (remaining.isNotEmpty) {
          final next = remaining.first;
          // 并发竞争修复：原 switchAccount 失败会回滚到 previousEmail（已被删除的账号），
          // 导致活跃账号指向已删除账号。改为捕获失败后清空活跃态，不依赖回滚。
          try {
            await switchAccount(next.email, next.region);
          } catch (e) {
            // 切换失败：清空活跃态而非回滚到已删除账号
            await BambuCloudSessionStore.clearActiveAccount();
            if (!mounted) return;
            state = state.copyWith(
              clearActive: true,
              clearError: true,
              lastError: '删除账号后切换失败：$e',
              lastErrorAt: DateTime.now(),
            );
          }
          // switchAccount 内部已触发 allCloudDevicesProvider.refresh
        } else {
          // 没有其他账号，清空活跃状态
          await BambuCloudSessionStore.clearActiveAccount();
          if (!mounted) return;
          state = state.copyWith(
            clearActive: true,
            clearError: true,
            clearUndo: wasUndoSource,
          );
          // 清空 bambuCloudProvider 的活跃 session。
          await _ref
              .read(bambuCloudProvider.notifier)
              .logout(removeFromManager: false);
          // 无账号时清空 allCloudDevices（避免幽灵设备残留）
          await _ref
              .read(allCloudDevicesProvider.notifier)
              .refresh(forceRefresh: true);
        }
      } else {
        await refresh();
        if (!mounted) return;
        // undo 状态需在 refresh 后单独清理（refresh 不动 undo 字段）
        if (wasUndoSource) {
          state = state.copyWith(clearUndo: true);
        }
        // 删除非活跃账号也要刷新设备列表（清理已删除账号的幽灵设备）
        _ref.read(allCloudDevicesProvider.notifier).refresh(forceRefresh: true);
      }
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        lastError: '删除账号失败：$e',
        lastErrorAt: DateTime.now(),
      );
      await refresh();
    }
  }

  /// P1-7: 清理长期过期的 session（>30 天）。
  ///
  /// 这些 session 即使保留也无法用于自动重登（token 已失效 6 天以上），
  /// 反而占用加密存储空间。账号密码仍保留，用户可随时重新登录。
  ///
  /// P0-8 修复：跳过当前活跃账号的 session。旧实现会清除活跃账号 session，
  /// 导致应用重启后无法恢复连接（活跃账号指向一个已被删除的 session）。
  /// 活跃账号的 token 过期由正常的重登流程处理，不应在此清理。
  ///
  /// 返回被清理的 session 数量。
  Future<int> cleanupStaleExpiredSessions({int staleDays = 30}) async {
    try {
      // P1-16 修复：清理前等待 allCloudDevicesProvider 当前 refresh 完成，
      // 避免 cleanup 删除 session 时 allCloudDevices 仍持有旧 managerState 快照
      // 导致 ownerMap 残留已删除账号的设备。
      // 等待策略：轮询 isLoading（cleanup 调用频率低，轮询开销可接受）。
      for (var i = 0; i < 50; i++) {
        if (!mounted) return 0;
        final cloudState = _ref.read(allCloudDevicesProvider);
        if (!cloudState.isLoading) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final sessions = await BambuCloudSessionStore.loadAllSessions();
      final now = DateTime.now();
      final staleThreshold = Duration(days: staleDays);
      int cleaned = 0;

      // P0-8：获取当前活跃账号，清理时跳过
      final activeEmail = state.activeAccountEmail;
      final activeRegion = state.activeRegion;

      for (final s in sessions) {
        // P0-8：跳过活跃账号的 session，避免重启后无法恢复连接
        if (activeEmail != null &&
            activeRegion != null &&
            s.email == activeEmail &&
            s.region == activeRegion) {
          continue;
        }
        // 只清理服务端已明确过期且长期未恢复的 session；未知有效期不猜测。
        final expiredAt = s.effectiveExpiresAt;
        if (expiredAt != null && now.difference(expiredAt) > staleThreshold) {
          await BambuCloudSessionStore.removeSession(s.email, s.region);
          cleaned++;
        }
      }

      if (cleaned > 0) {
        await refresh();
        if (!mounted) return cleaned;
        // P1-16 修复：清理后强制刷新 allCloudDevices，让 ownerMap 重新基于
        // 新 sessions 生成（不含已删除账号），避免幽灵设备残留。
        await _ref
            .read(allCloudDevicesProvider.notifier)
            .refresh(forceRefresh: true);
        debugPrint('[AccountManager] 清理了 $cleaned 个长期过期 session');
      }
      return cleaned;
    } catch (e) {
      if (!mounted) return 0;
      state = state.copyWith(
        lastError: '清理过期 session 失败：$e',
        lastErrorAt: DateTime.now(),
      );
      return 0;
    }
  }

  /// 跨账号迁移设备（从源账号解绑）。
  ///
  /// 流程：
  /// 1. 用源账号 session 调用 BambuCloudClient.unbindDevice 解绑设备
  /// 2. 解绑成功后，设备物理上未绑定任何账号
  /// 3. 用户需要在目标账号下手动添加设备
  ///
  /// 返回值：
  /// - 成功返回 true
  /// - 失败返回 false（错误信息记录到 state.lastError）
  Future<bool> migrateDevice({
    required String sourceEmail,
    required BambuRegion sourceRegion,
    required String devId,
    bool force = false,
  }) async {
    try {
      final sourceSession = await BambuCloudSessionStore.loadSessionFor(
        sourceEmail,
        sourceRegion,
      );
      if (sourceSession == null) {
        state = state.copyWith(
          lastError: '源账号 $sourceEmail 的登录信息已丢失，请重新登录后再试',
          lastErrorAt: DateTime.now(),
        );
        return false;
      }
      if (sourceSession.isExpired) {
        state = state.copyWith(
          lastError: '源账号 $sourceEmail 的登录已过期，请重新登录后再试',
          lastErrorAt: DateTime.now(),
        );
        return false;
      }
      await BambuCloudClient.unbindDevice(
        session: sourceSession,
        devId: devId,
        force: force,
      );
      debugPrint('[AccountManager] 设备 $devId 已从 $sourceEmail 解绑');
      return true;
    } catch (e) {
      final msg = e is BambuCloudException
          ? e.message
          : e.toString().replaceFirst('BambuCloudException: ', '');
      // P1-7: 基于 category 给出更精准的错误提示
      String hint;
      if (e is BambuCloudException &&
          e.category == BambuCloudErrorCategory.authentication) {
        hint = '（源账号登录已失效，请重新登录后再试）';
      } else if (e is BambuCloudException &&
          e.category == BambuCloudErrorCategory.permission) {
        hint = '（无权限解绑该设备，可能设备不在此账号名下）';
      } else if (e is BambuCloudException &&
          e.category == BambuCloudErrorCategory.protocol) {
        hint = '（拓竹协议可能已变更，请更新应用）';
      } else if (e is BambuCloudException && e.isRetryable) {
        hint = '（网络/服务器问题，请稍后重试）';
      } else {
        hint = '';
      }
      state = state.copyWith(
        lastError: '设备解绑失败：$msg$hint',
        lastErrorAt: DateTime.now(),
      );
      debugPrint('[AccountManager] 设备迁移失败: $e');
      return false;
    }
  }

  /// 清除错误状态。
  void clearError() {
    state = state.clearError();
  }
}

/// 多账号管理 Provider。
final bambuAccountManagerProvider = StateNotifierProvider<
    BambuAccountManagerNotifier, BambuAccountManagerState>((ref) {
  return BambuAccountManagerNotifier(ref);
});
