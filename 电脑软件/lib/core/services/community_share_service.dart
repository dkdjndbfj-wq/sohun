// 社区打印结果分享服务。
//
// 任务书 10.2 要求：
// - 用户可对已完成的打印结果开启/关闭社区分享。
// - 开启后异步上传到社区服务器，上传内容仅限白名单字段，禁止泄露序列号、
//   trayUuid、文件路径、用户备注、账号信息等敏感数据。
// - 所有上传必须经过隐私守卫（SensitiveDataSanitizer）双重校验。
// - 已同步结果可增量更新主观评价（PATCH），可撤销（DELETE）。
// - 服务在社区服务器未配置时为 no-op，不阻塞 UI。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/database/daos/preset_result_dao.dart';
import '../../data/external/community/community_api_client.dart';
import 'sensitive_data_sanitizer.dart';

/// 社区打印结果分享服务。
///
/// 负责将本地打印结果（用户同意分享的部分）安全上传到社区服务器，
/// 以及增量更新和撤销。所有上传操作必须通过 [_passesPrivacyGuard] 校验。
class CommunityShareService {
  CommunityShareService({
    required CommunityTrustApi? apiClient,
    required PresetResultDao resultDao,
    required Future<String?> Function() accessTokenProvider,
    required bool Function() isShareEnabled,
  })  : _apiClient = apiClient,
        _resultDao = resultDao,
        _accessTokenProvider = accessTokenProvider,
        _isShareEnabled = isShareEnabled {
    _startTimer();
  }

  final CommunityTrustApi? _apiClient;
  final PresetResultDao _resultDao;
  final Future<String?> Function() _accessTokenProvider;
  final bool Function() _isShareEnabled;

  Timer? _timer;
  bool _isSyncing = false;

  static const _syncInterval = Duration(minutes: 2);

  // ===== 分享同意管理 =====

  /// 设置某条打印结果的分享同意。
  ///
  /// [consented] 为 true 时标记为 pending 并立即尝试同步；
  /// 为 false 时等价于 [revokeShare]。
  Future<void> setShareConsent(String resultId, bool consented) async {
    if (consented) {
      // 用户同意分享：标记为 pending，排队等待同步
      await _resultDao.updateShareConsent(
        resultId,
        ShareConsent.pending,
        syncStatus: ShareConsent.pending,
      );
      // 立即尝试同步一次（不等定时器）
      unawaited(syncPendingShares());
    } else {
      await revokeShare(resultId);
    }
  }

  // ===== 同步队列 =====

  /// 同步所有待分享（share_consent='pending'）的结果。
  ///
  /// 在以下任一条件不满足时为 no-op：
  /// - 正在同步中（防止重入）
  /// - 分享总开关已关闭
  /// - 社区服务器未配置（apiClient 为 null）
  /// - 用户未登录（无 access token）
  Future<void> syncPendingShares() async {
    if (_isSyncing) return;
    if (_apiClient == null) return;
    final shareEnabled = _isShareEnabled();

    final accessToken = await _accessTokenProvider();
    if (accessToken == null) return;

    _isSyncing = true;
    try {
      final pending = await _resultDao.queryPendingConsent();
      for (final result in pending) {
        try {
          if (result.shareConsent == ShareConsent.revokePending) {
            await _revokeOne(result, accessToken);
          } else if (shareEnabled) {
            await _syncOne(result, accessToken);
          }
        } catch (error) {
          // 单条失败不影响其他条目
          debugPrint(
            '[CommunityShare] 同步单条异常(resultId=${result.id})：$error',
          );
        }
      }
    } catch (error) {
      debugPrint('[CommunityShare] syncPendingShares 异常：$error');
    } finally {
      _isSyncing = false;
    }
  }

  /// 同步单条结果。
  Future<void> _syncOne(PresetPrintResult result, String accessToken) async {
    // 校验必须是社区参数（有 communityPublicationId），本地预设不可分享
    if (result.communityPublicationId == null) {
      debugPrint(
        '[CommunityShare] 跳过本地结果 ${result.id}：无 communityPublicationId',
      );
      await _resultDao.updateShareConsent(
        result.id,
        ShareConsent.failed,
        syncStatus: ShareConsent.failed,
      );
      return;
    }

    if (result.communityRevision == null) {
      debugPrint('[CommunityShare] 跳过结果 ${result.id}：无社区参数 revision');
      await _resultDao.updateShareConsent(
        result.id,
        ShareConsent.failed,
        syncStatus: ShareConsent.failed,
      );
      return;
    }

    // New servers use the content hash as the opaque version ID. This keeps
    // legacy server hashes usable while schema-v2 local snapshots remain the
    // fallback for older responses without versionId/contentHash.
    String? presetFingerprint = result.communityVersionId;
    if (presetFingerprint == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(presetFingerprint)) {
      presetFingerprint = null;
    }
    if (result.snapshotId != null) {
      final snapshot = await _resultDao.getSnapshot(result.snapshotId!);
      presetFingerprint ??= snapshot?['content_hash'] as String?;
    }
    if (presetFingerprint == null) {
      debugPrint('[CommunityShare] 跳过结果 ${result.id}：无 presetFingerprint');
      await _resultDao.updateShareConsent(
        result.id,
        ShareConsent.failed,
        syncStatus: ShareConsent.failed,
      );
      return;
    }

    final payload = _buildPayload(result, presetFingerprint);
    if (!_passesPrivacyGuard(payload)) {
      debugPrint(
        '[CommunityShare] 拒绝上传：隐私守卫未通过，resultId=${result.id}',
      );
      await _resultDao.updateShareConsent(
        result.id,
        ShareConsent.failed,
        syncStatus: ShareConsent.failed,
      );
      return;
    }

    try {
      final submission = await _apiClient!.submitPrintResult(
        accessToken: accessToken,
        publicationId: result.communityPublicationId!,
        payload: payload,
      );
      // 成功：更新 sync_status='synced'，存储服务端分配的修订号
      await _resultDao.updateShareConsent(
        result.id,
        ShareConsent.synced,
        syncStatus: ShareConsent.synced,
        communityResultRevision: submission.revision,
      );
    } on CommunityApiException catch (error) {
      if (error.statusCode == 409) {
        // 修订/指纹冲突：标记为 failed，不自动重试
        debugPrint(
          '[CommunityShare] 提交冲突(resultId=${result.id})，标记为 failed：$error',
        );
        await _resultDao.updateShareConsent(
          result.id,
          ShareConsent.failed,
          syncStatus: ShareConsent.failed,
        );
      } else if (error.category == CommunityApiErrorCategory.network ||
          error.category == CommunityApiErrorCategory.timeout) {
        // 网络错误：保持 pending，下次同步周期重试
        debugPrint(
          '[CommunityShare] 网络错误(resultId=${result.id})，保持 pending：$error',
        );
      } else {
        debugPrint(
          '[CommunityShare] 提交失败(resultId=${result.id})，标记为 failed：$error',
        );
        await _resultDao.updateShareConsent(
          result.id,
          ShareConsent.failed,
          syncStatus: ShareConsent.failed,
        );
      }
    } catch (error) {
      debugPrint('[CommunityShare] 提交异常(resultId=${result.id})：$error');
    }
  }

  /// 构造上传 payload（仅包含白名单字段）。
  ///
  /// 严格排除：序列号、trayUuid、文件路径、文件名、用户备注、账号字段。
  Map<String, dynamic> _buildPayload(
    PresetPrintResult result,
    String presetFingerprint,
  ) {
    return {
      'clientResultId': result.clientRunId,
      'publicationRevision': result.communityRevision,
      'presetFingerprint': presetFingerprint,
      'technicalStatus': result.technicalStatus.value,
      'userOutcome': result.userOutcome?.value,
      'printerModel': result.printerModel,
      'nozzleDiameter': result.nozzleDiameter,
      'materialProfile': result.materialProfile,
      'plateType': result.plateType,
      'humidityBucket': _mapHumidityBucket(result.amsHumidity),
      'estimatedSeconds': result.estimatedSeconds,
      'actualSeconds': result.actualSeconds,
      'estimatedGrams': result.estimatedGrams,
      'actualGrams': result.actualGrams,
      'rating': result.rating,
      'recordedAt': result.createdAt.toIso8601String(),
    };
  }

  /// AMS 湿度读数映射到桶标签。
  ///
  /// Bambu AMS 湿度传感器常见读数为 1-4 级，映射到语义桶便于聚合统计。
  String? _mapHumidityBucket(double? humidity) {
    if (humidity == null) return null;
    if (humidity <= 1) return 'low';
    if (humidity <= 3) return 'medium';
    return 'high';
  }

  // ===== 增量更新主观评价 =====

  /// 对已同步结果增量更新主观评价（rating/userOutcome）。
  ///
  /// 通过 PATCH 接口携带 expectedRevision 进行乐观锁更新。
  /// 409 冲突时从服务端响应更新本地修订号，不自动覆盖。
  Future<void> syncUserOutcomeUpdate(String resultId) async {
    if (_apiClient == null) return;

    final result = await _resultDao.getById(resultId);
    if (result == null) return;
    // 仅对已同步的结果执行增量更新
    if (result.syncStatus != ShareConsent.synced) return;
    if (result.communityPublicationId == null) return;
    final revision = result.communityResultRevision;
    if (revision == null) return;

    final accessToken = await _accessTokenProvider();
    if (accessToken == null) return;

    final payload = {
      'userOutcome': result.userOutcome?.value,
      'rating': result.rating,
    };
    if (!_passesPrivacyGuard(payload)) {
      debugPrint('[CommunityShare] 增量更新隐私守卫未通过，resultId=$resultId');
      return;
    }

    try {
      final submission = await _apiClient.patchPrintResult(
        accessToken: accessToken,
        publicationId: result.communityPublicationId!,
        clientResultId: result.clientRunId,
        expectedRevision: revision,
        payload: payload,
      );
      await _resultDao.updateShareConsent(
        resultId,
        ShareConsent.synced,
        syncStatus: ShareConsent.synced,
        communityResultRevision: submission.revision,
      );
    } on CommunityApiException catch (error) {
      if (error.statusCode == 409 && error.code == 'revision_conflict') {
        // 从服务端响应中提取当前修订号，更新本地，不自动覆盖
        final details = error.details;
        if (details is Map) {
          final currentRevision = details['currentRevision'];
          if (currentRevision is int) {
            await _resultDao.updateShareConsent(
              resultId,
              ShareConsent.synced,
              syncStatus: ShareConsent.synced,
              communityResultRevision: currentRevision,
            );
          }
        }
        debugPrint(
          '[CommunityShare] 修订冲突(resultId=$resultId)，已同步服务端修订号',
        );
      } else {
        debugPrint('[CommunityShare] 增量更新失败(resultId=$resultId)：$error');
      }
    } catch (error) {
      debugPrint('[CommunityShare] 增量更新异常(resultId=$resultId)：$error');
    }
  }

  // ===== 撤销分享 =====

  /// 撤销某条结果的分享。
  ///
  /// 若结果已同步，先调用服务端 DELETE 删除远程记录。
  /// 成功后本地标记 share_consent='not_shared'、sync_status='revoked'。
  /// 网络失败时保持 share_consent='pending'、sync_status='failed' 以便下次重试。
  Future<void> revokeShare(String resultId) async {
    final result = await _resultDao.getById(resultId);
    if (result == null) return;

    // 已同步的结果需要先删除远程记录
    if ((result.syncStatus == ShareConsent.synced ||
            result.shareConsent == ShareConsent.revokePending) &&
        result.communityPublicationId != null) {
      final accessToken = await _accessTokenProvider();
      if (accessToken == null || _apiClient == null) {
        await _markRevokePending(resultId);
        return;
      }
      await _resultDao.updateShareConsent(
        resultId,
        ShareConsent.revokePending,
        syncStatus: ShareConsent.failed,
      );
      await _revokeOne(result, accessToken);
      return;
    }

    // 更新本地：撤销
    await _resultDao.updateShareConsent(
      resultId,
      ShareConsent.notShared,
      syncStatus: ShareConsent.revoked,
    );
  }

  Future<void> _markRevokePending(String resultId) async {
    await _resultDao.updateShareConsent(
      resultId,
      ShareConsent.revokePending,
      syncStatus: ShareConsent.failed,
    );
  }

  Future<void> _revokeOne(
    PresetPrintResult result,
    String accessToken,
  ) async {
    if (_apiClient == null || result.communityPublicationId == null) {
      await _markRevokePending(result.id);
      return;
    }
    try {
      await _apiClient.deletePrintResult(
        accessToken: accessToken,
        publicationId: result.communityPublicationId!,
        clientResultId: result.clientRunId,
      );
    } on CommunityApiException catch (error) {
      if (error.statusCode != 404) {
        await _markRevokePending(result.id);
        debugPrint('[CommunityShare] 撤销分享失败(resultId=${result.id})：$error');
        return;
      }
    } catch (error) {
      await _markRevokePending(result.id);
      debugPrint('[CommunityShare] 撤销分享异常(resultId=${result.id})：$error');
      return;
    }
    await _resultDao.updateShareConsent(
      result.id,
      ShareConsent.notShared,
      syncStatus: ShareConsent.revoked,
    );
  }

  // ===== 应用记录上报 =====

  /// 上报参数应用记录（用户将社区参数应用到切片器时调用）。
  ///
  /// 幂等：服务端负责去重。
  Future<void> uploadApplicationRecord(
    String publicationId,
    String clientApplicationId,
  ) async {
    if (_apiClient == null) return;
    if (!_isShareEnabled()) return;

    final accessToken = await _accessTokenProvider();
    if (accessToken == null) return;

    try {
      await _apiClient.putApplication(
        accessToken: accessToken,
        publicationId: publicationId,
        clientApplicationId: clientApplicationId,
      );
    } on CommunityApiException catch (error) {
      debugPrint(
        '[CommunityShare] 应用记录上报失败(publicationId=$publicationId)：$error',
      );
    } catch (error) {
      debugPrint(
        '[CommunityShare] 应用记录上报异常(publicationId=$publicationId)：$error',
      );
    }
  }

  // ===== 隐私守卫 =====

  /// 上传前隐私校验。
  ///
  /// 1. 显式禁止字段检查（trayUuid、serial、路径、备注、账号字段等）。
  /// 2. [SensitiveDataSanitizer.containsSensitive] 检测未预期敏感数据。
  ///    注意：clientResultId（UUID）和 presetFingerprint（hash）是协议要求的
  ///    合法字段，校验时临时排除，避免误判。
  /// 3. [SensitiveDataSanitizer.sanitizeMap] 作为最终安全网：若探针被脱敏后
  ///    发生变化，说明含未预期敏感数据，拒绝上传。
  bool _passesPrivacyGuard(Map<String, dynamic> payload) {
    // 1. 显式禁止字段检查
    const forbiddenKeys = {
      'trayUuid',
      'tray_uuid',
      'serialNumber',
      'serial_number',
      'serial',
      'filePath',
      'file_path',
      'fileName',
      'file_name',
      'localPath',
      'userNote',
      'user_note',
      'ipAddress',
      'ip_address',
      'ip',
      'accessToken',
      'access_token',
      'refreshToken',
      'refresh_token',
      'email',
      'password',
    };
    for (final key in payload.keys) {
      if (forbiddenKeys.contains(key)) {
        debugPrint('[CommunityShare] 隐私守卫拒绝：payload 含禁止字段 $key');
        return false;
      }
    }

    // 2. 构造探针：排除合法的 UUID/hash 字段后检查
    final probe = Map<String, dynamic>.from(payload);
    probe.remove('clientResultId');
    probe.remove('presetFingerprint');
    final probeJson = jsonEncode(probe);
    if (SensitiveDataSanitizer.containsSensitive(probeJson)) {
      debugPrint('[CommunityShare] 隐私守卫拒绝：payload 含未预期的敏感数据');
      return false;
    }

    // 3. sanitizeMap 最终安全网：若探针脱敏后发生变化则拒绝
    final sanitizedProbe = SensitiveDataSanitizer.sanitizeMap(probe);
    if (jsonEncode(sanitizedProbe) != probeJson) {
      debugPrint('[CommunityShare] 隐私守卫拒绝：sanitizeMap 检测到待脱敏内容');
      return false;
    }

    return true;
  }

  // ===== 定时同步 =====

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_syncInterval, (_) => _tick());
  }

  Future<void> _tick() async {
    try {
      await syncPendingShares();
    } catch (error) {
      debugPrint('[CommunityShare] 定时同步异常：$error');
    }
  }

  /// 释放资源（取消定时器）。
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
