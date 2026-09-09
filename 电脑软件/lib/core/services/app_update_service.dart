import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_version.dart';
import 'remote_config_service.dart';

enum AppUpdatePhase { idle, checking, upToDate, available, failed }

/// Windows/macOS/Linux 共用桌面发行通道，Android 使用独立安装包通道。
enum AppUpdatePlatform { desktop, android }

class AppUpdateState {
  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.currentVersion = AppVersion.fullVersion,
    this.latestVersion,
    this.minimumSupportedVersion,
    this.isMandatory = false,
    this.isChecking = false,
    this.mandatoryPolicyResolved = false,
    this.releaseNotes,
    this.downloadUri,
    this.checkedAt,
    this.message,
  });

  final AppUpdatePhase phase;
  final String currentVersion;
  final String? latestVersion;
  final String? minimumSupportedVersion;
  final bool isMandatory;
  final bool isChecking;

  /// 仅由有效快照明确允许继续时置 true，供跨 provider 的强制门禁解锁。
  final bool mandatoryPolicyResolved;
  final String? releaseNotes;
  final Uri? downloadUri;
  final DateTime? checkedAt;
  final String? message;

  /// 重试或失败不代表已经安装更新，也不能解除已确认的强制更新。
  bool get hasUpdate =>
      latestVersion != null &&
      isValidAppReleaseVersion(latestVersion!) &&
      compareAppVersions(latestVersion!, currentVersion) > 0;

  AppUpdateState copyWith({
    AppUpdatePhase? phase,
    String? latestVersion,
    String? minimumSupportedVersion,
    bool? isMandatory,
    bool? isChecking,
    bool? mandatoryPolicyResolved,
    String? releaseNotes,
    Uri? downloadUri,
    DateTime? checkedAt,
    String? message,
  }) {
    return AppUpdateState(
      phase: phase ?? this.phase,
      currentVersion: currentVersion,
      latestVersion: latestVersion ?? this.latestVersion,
      minimumSupportedVersion:
          minimumSupportedVersion ?? this.minimumSupportedVersion,
      isMandatory: isMandatory ?? this.isMandatory,
      isChecking: isChecking ?? this.isChecking,
      mandatoryPolicyResolved:
          mandatoryPolicyResolved ?? this.mandatoryPolicyResolved,
      releaseNotes: releaseNotes ?? this.releaseNotes,
      downloadUri: downloadUri ?? this.downloadUri,
      checkedAt: checkedAt ?? this.checkedAt,
      message: message,
    );
  }
}

/// 使用远程配置的同一 HTTPS/缓存边界检查应用版本。
///
/// 只消费实际远程快照，内置版本不是“已经是最新版”的证据。订阅配置
/// 刷新使启动、恢复前台和定时拉取都能更新策略，不依赖用户打开设置。
class AppUpdateService extends StateNotifier<AppUpdateState> {
  AppUpdateService(
    this._remoteConfig, {
    String currentVersion = AppVersion.fullVersion,
    AppUpdatePlatform? platform,
    Future<bool> Function(Uri)? openExternalUrl,
  }) : _platform =
           platform ??
           (Platform.isAndroid
               ? AppUpdatePlatform.android
               : AppUpdatePlatform.desktop),
       _openExternalUrl = openExternalUrl ?? _launchExternal,
       super(AppUpdateState(currentVersion: currentVersion)) {
    _removeRemoteListener = _remoteConfig.addListener(
      _onRemoteSnapshot,
      fireImmediately: false,
    );
    // 已初始化的 provider 也可能在进入设置后才首次创建更新服务。
    // 微任务避免在 Riverpod 构建其他 provider 时同步修改通知器状态。
    Future<void>.microtask(() async {
      await _remoteConfig.ready;
      if (mounted) _onRemoteSnapshot(_remoteConfig.state);
    });
  }

  final RemoteConfigService _remoteConfig;
  final AppUpdatePlatform _platform;
  final Future<bool> Function(Uri) _openExternalUrl;
  late final void Function() _removeRemoteListener;
  Future<AppUpdateState>? _checkOperation;

  static const _cancelled = AppUpdateState(
    phase: AppUpdatePhase.failed,
    message: '更新检查已取消',
  );

  /// 合并启动、手动与前台恢复的并发检查，所有调用方等待同一个最终结果。
  Future<AppUpdateState> checkForUpdates() {
    if (!mounted) return Future.value(_cancelled);
    return _checkOperation ??= _checkForUpdates().whenComplete(() {
      _checkOperation = null;
    });
  }

  Future<AppUpdateState> _checkForUpdates() async {
    state = state.copyWith(
      phase: AppUpdatePhase.checking,
      isChecking: true,
      mandatoryPolicyResolved: false,
    );
    try {
      await _remoteConfig.ready;
      if (!mounted) return _cancelled;
      await _remoteConfig.fetchAndUpdate();
      if (!mounted) return _cancelled;
      _applySnapshot(_remoteConfig.state, isChecking: false);
    } catch (_) {
      if (!mounted) return _cancelled;
      _fail('暂时无法检查更新，请稍后重试', isChecking: false);
    }
    return state;
  }

  void _onRemoteSnapshot(RemoteConfigState snapshot) {
    if (!mounted) return;
    // 没有配置更新服务时保持安静，手动检查时再显示可重试的失败状态。
    if (snapshot.source == 'built_in' && !state.hasUpdate) return;
    _applySnapshot(snapshot, isChecking: state.isChecking);
  }

  void _applySnapshot(RemoteConfigState snapshot, {required bool isChecking}) {
    if (snapshot.fetchError != null) {
      // 更新服务可能在一次网络失败后才被 UI 创建。先恢复缓存中已确认的
      // 策略，再报告失败，防止 provider 重建或冷启动绕过强制要求。
      if (!state.hasUpdate && snapshot.source != 'built_in') {
        _applySnapshot(
          RemoteConfigState(
            flags: snapshot.flags,
            source: snapshot.source,
            updatedAtMillis: snapshot.updatedAtMillis,
            etag: snapshot.etag,
          ),
          isChecking: isChecking,
        );
      }
      _fail(
        snapshot.fetchError == 'invalid_config'
            ? '更新服务尚未提供有效版本信息，请稍后重试'
            : '暂时无法连接更新服务，请检查网络后重试',
        isChecking: isChecking,
      );
      return;
    }
    if (snapshot.source == 'built_in' || snapshot.updatedAtMillis == 0) {
      _fail('暂时无法连接更新服务，请检查网络后重试', isChecking: isChecking);
      return;
    }

    final prefix = _platform.name;
    final latest = _stringFlag(snapshot, '${prefix}_latest_version');
    final minimum = _stringFlag(snapshot, '${prefix}_min_supported_version');
    final force = snapshot.flags['${prefix}_force_update'];
    if (latest == null ||
        !isValidAppReleaseVersion(latest) ||
        (minimum != null && !isValidAppReleaseVersion(minimum)) ||
        (force != null && force is! bool) ||
        (minimum != null && compareAppVersions(minimum, latest) > 0)) {
      _fail('更新服务尚未提供有效版本信息，请稍后重试', isChecking: isChecking);
      return;
    }

    final available = compareAppVersions(latest, state.currentVersion) > 0;
    final freshDownloadUri = _safeDownloadUri(
      _stringFlag(snapshot, '${prefix}_download_url'),
    );
    // A transient omission for the same version keeps the last verified URL.
    // A different version can never borrow an older installer.
    final downloadUri =
        freshDownloadUri ??
        (latest == state.latestVersion ? state.downloadUri : null);
    final mandatoryRequested =
        available &&
        (force == true ||
            (minimum != null &&
                compareAppVersions(state.currentVersion, minimum) < 0));
    final invalidMandatoryConfiguration =
        mandatoryRequested && downloadUri == null;
    final mandatory = mandatoryRequested && downloadUri != null;

    // 缓存过期仍可恢复曾下发的强制策略；过期快照不能宣告最新或解锁。
    if (snapshot.isStale && !mandatory && !invalidMandatoryConfiguration) {
      _fail('暂时无法连接更新服务，请检查网络后重试', isChecking: isChecking);
      return;
    }
    if (state.hasUpdate &&
        (compareAppVersions(latest, state.latestVersion!) < 0 ||
            (state.isMandatory &&
                !mandatory &&
                !invalidMandatoryConfiguration &&
                // 缺失字段可能来自旧服务器，撤回需要完整、显式的策略。
                (force != false ||
                    !snapshot.flags.containsKey(
                      '${prefix}_min_supported_version',
                    ))))) {
      _fail('更新配置暂未确认，保留上次检查结果', isChecking: isChecking);
      return;
    }
    state = AppUpdateState(
      phase: snapshot.isStale && !invalidMandatoryConfiguration
          ? AppUpdatePhase.failed
          : (available ? AppUpdatePhase.available : AppUpdatePhase.upToDate),
      currentVersion: state.currentVersion,
      latestVersion: latest,
      minimumSupportedVersion: minimum,
      isMandatory: mandatory,
      isChecking: isChecking,
      mandatoryPolicyResolved:
          !isChecking &&
          !mandatory &&
          (invalidMandatoryConfiguration ||
              (!snapshot.isStale &&
                  (!available ||
                      (force == false &&
                          snapshot.flags.containsKey(
                            '${prefix}_min_supported_version',
                          ))))),
      releaseNotes: _stringFlag(snapshot, '${prefix}_release_notes'),
      downloadUri: downloadUri,
      checkedAt: DateTime.now(),
      message: invalidMandatoryConfiguration
          ? '强制更新配置缺少有效下载地址，已允许继续使用'
          : snapshot.isStale
          ? '暂时无法连接更新服务，仍需更新后继续使用'
          : (mandatory
                ? '此版本需要更新后才能继续使用'
                : (available ? '发现新版本 $latest' : '当前已是最新版本')),
    );
  }

  void _fail(String message, {required bool isChecking}) {
    state = state.copyWith(
      phase: AppUpdatePhase.failed,
      isChecking: isChecking,
      mandatoryPolicyResolved: false,
      checkedAt: DateTime.now(),
      message: message,
    );
  }

  /// 仅打开受校验的 HTTPS 下载页，由浏览器和系统安装器完成实际更新。
  /// 返回成功不代表已经下载安装，也不会清除强制更新状态。
  Future<bool> openDownloadPage({Uri? verifiedDownloadUri}) async {
    if (!mounted) return false;
    final uri = _safeDownloadUri(
      (verifiedDownloadUri ?? state.downloadUri)?.toString(),
    );
    if (uri == null || (verifiedDownloadUri == null && !state.hasUpdate)) {
      return false;
    }
    try {
      return await _openExternalUrl(uri);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _launchExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  @override
  void dispose() {
    _removeRemoteListener();
    super.dispose();
  }

  String? _stringFlag(RemoteConfigState snapshot, String key) {
    final value = snapshot.flags[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// 比较 v1.2.3、1.2.3+4。构建号按整数比较，缺省构建号视为 0。
/// 为现有非更新调用方保留缺少末尾版本段的兼容，更新元数据另外严格校验。
int compareAppVersions(String left, String right) =>
    compareRemoteReleaseVersions(left, right);

Uri? _safeDownloadUri(String? value) {
  if (value == null || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      !uri.isAbsolute ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

final appUpdateServiceProvider =
    StateNotifierProvider<AppUpdateService, AppUpdateState>((ref) {
      return AppUpdateService(ref.watch(remoteConfigServiceProvider.notifier));
    });
