import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../providers/app_auth_provider.dart'
    show appAuthProvider, communityHttpClientProvider;
import '../../models/app_auth.dart';
import '../../models/community_preset.dart';
import '../../models/personal_inventory_sync.dart';
import '../../models/personal_inventory_event.dart';
import '../../models/printer_fault.dart';
import '../../models/personal_device.dart';
import '../../models/print_parameter.dart';
import '../../prefs/community_server_settings.dart';

/// 社区参数信任度汇总信息。
///
/// 用于呈现某个公开参数集在社区中收集到的打印结果统计与可信度评估。
class CommunityTrustSummary {
  final String presetId;
  final int revision;
  final int publicSamples;
  final int uniqueUserCount;
  final int outcomeSampleCount;
  final int outcomeUserCount;
  final bool meetsThreshold;
  final bool isHighTrust;
  final double? deviceCompletionRate;
  final int deviceFinishedCount;
  final int deviceFailedCount;
  final int deviceCancelledCount;
  final double? userUsableRate;
  final int userSuccessCount;
  final int userUsableCount;
  final int userQualityFailedCount;
  final double? smoothedUsableRate;
  final double wilsonLowerBound;
  final double? ratingAverage;
  final int ratingCount;
  final int authorSelfTestCount;
  final int printerModelCoverage;
  final DateTime? lastRecordedAt;
  final String? badgeLabel;
  final DateTime? cachedAt;
  final bool isStale;

  const CommunityTrustSummary({
    required this.presetId,
    required this.revision,
    required this.publicSamples,
    required this.uniqueUserCount,
    this.outcomeSampleCount = 0,
    this.outcomeUserCount = 0,
    required this.meetsThreshold,
    required this.isHighTrust,
    this.deviceCompletionRate,
    this.deviceFinishedCount = 0,
    this.deviceFailedCount = 0,
    this.deviceCancelledCount = 0,
    this.userUsableRate,
    this.userSuccessCount = 0,
    this.userUsableCount = 0,
    this.userQualityFailedCount = 0,
    this.smoothedUsableRate,
    required this.wilsonLowerBound,
    this.ratingAverage,
    required this.ratingCount,
    required this.authorSelfTestCount,
    required this.printerModelCoverage,
    this.lastRecordedAt,
    this.badgeLabel,
    this.cachedAt,
    this.isStale = false,
  });

  factory CommunityTrustSummary.fromJson(Map<String, dynamic> json) {
    final data = _unwrapData(json);
    return CommunityTrustSummary(
      presetId: _requiredText(data, 'presetId'),
      revision: _integer(data, 'revision'),
      publicSamples: _integer(data, 'publicSamples'),
      uniqueUserCount: _integer(data, 'uniqueUserCount'),
      outcomeSampleCount: _integer(data, 'outcomeSampleCount'),
      outcomeUserCount: _integer(data, 'outcomeUserCount'),
      meetsThreshold: _boolean(data, 'meetsThreshold'),
      isHighTrust: _boolean(data, 'isHighTrust'),
      deviceCompletionRate: _optionalDouble(data, 'deviceCompletionRate'),
      deviceFinishedCount: _integer(data, 'deviceFinishedCount'),
      deviceFailedCount: _integer(data, 'deviceFailedCount'),
      deviceCancelledCount: _integer(data, 'deviceCancelledCount'),
      userUsableRate: _optionalDouble(data, 'userUsableRate'),
      userSuccessCount: _integer(data, 'userSuccessCount'),
      userUsableCount: _integer(data, 'userUsableCount'),
      userQualityFailedCount: _integer(data, 'userQualityFailedCount'),
      smoothedUsableRate: _optionalDouble(data, 'smoothedUsableRate'),
      wilsonLowerBound: _doubleWithDefault(data, 'wilsonLowerBound', 0.0),
      ratingAverage: _optionalDouble(data, 'ratingAverage'),
      ratingCount: _integer(data, 'ratingCount'),
      authorSelfTestCount: _integer(data, 'authorSelfTestCount'),
      printerModelCoverage: _integer(data, 'printerModelCoverage'),
      lastRecordedAt: _optionalDateTime(data, 'lastRecordedAt'),
      badgeLabel: _optionalText(data, 'badgeLabel'),
      cachedAt: _optionalDateTime(data, 'cachedAt'),
      isStale: data['isStale'] == true,
    );
  }

  CommunityTrustSummary copyWith({DateTime? cachedAt, bool? isStale}) {
    return CommunityTrustSummary(
      presetId: presetId,
      revision: revision,
      publicSamples: publicSamples,
      uniqueUserCount: uniqueUserCount,
      outcomeSampleCount: outcomeSampleCount,
      outcomeUserCount: outcomeUserCount,
      meetsThreshold: meetsThreshold,
      isHighTrust: isHighTrust,
      deviceCompletionRate: deviceCompletionRate,
      deviceFinishedCount: deviceFinishedCount,
      deviceFailedCount: deviceFailedCount,
      deviceCancelledCount: deviceCancelledCount,
      userUsableRate: userUsableRate,
      userSuccessCount: userSuccessCount,
      userUsableCount: userUsableCount,
      userQualityFailedCount: userQualityFailedCount,
      smoothedUsableRate: smoothedUsableRate,
      wilsonLowerBound: wilsonLowerBound,
      ratingAverage: ratingAverage,
      ratingCount: ratingCount,
      authorSelfTestCount: authorSelfTestCount,
      printerModelCoverage: printerModelCoverage,
      lastRecordedAt: lastRecordedAt,
      badgeLabel: badgeLabel,
      cachedAt: cachedAt ?? this.cachedAt,
      isStale: isStale ?? this.isStale,
    );
  }

  Map<String, dynamic> toCacheJson() => {
    'presetId': presetId,
    'revision': revision,
    'publicSamples': publicSamples,
    'uniqueUserCount': uniqueUserCount,
    'outcomeSampleCount': outcomeSampleCount,
    'outcomeUserCount': outcomeUserCount,
    'meetsThreshold': meetsThreshold,
    'isHighTrust': isHighTrust,
    'deviceCompletionRate': deviceCompletionRate,
    'deviceFinishedCount': deviceFinishedCount,
    'deviceFailedCount': deviceFailedCount,
    'deviceCancelledCount': deviceCancelledCount,
    'userUsableRate': userUsableRate,
    'userSuccessCount': userSuccessCount,
    'userUsableCount': userUsableCount,
    'userQualityFailedCount': userQualityFailedCount,
    'smoothedUsableRate': smoothedUsableRate,
    'wilsonLowerBound': wilsonLowerBound,
    'ratingAverage': ratingAverage,
    'ratingCount': ratingCount,
    'authorSelfTestCount': authorSelfTestCount,
    'printerModelCoverage': printerModelCoverage,
    'lastRecordedAt': lastRecordedAt?.toUtc().toIso8601String(),
    'badgeLabel': badgeLabel,
    'cachedAt': cachedAt?.toUtc().toIso8601String(),
    'isStale': isStale,
  };
}

/// 打印结果提交回执。
///
/// 服务端在接收并去重后返回该回执，包含服务端分配的记录 ID、当前修订号
/// 以及是否为幂等命中（同一 clientResultId 重复提交）。
class CommunityPrintResultSubmission {
  final String id;
  final String clientResultId;
  final int revision;
  final bool idempotent;
  final DateTime receivedAt;

  const CommunityPrintResultSubmission({
    required this.id,
    required this.clientResultId,
    required this.revision,
    required this.idempotent,
    required this.receivedAt,
  });

  factory CommunityPrintResultSubmission.fromJson(Map<String, dynamic> json) {
    final data = _unwrapData(json);
    return CommunityPrintResultSubmission(
      id: _requiredText(data, 'id'),
      clientResultId: _requiredText(data, 'clientResultId'),
      revision: _integer(data, 'revision'),
      idempotent: _boolean(data, 'idempotent'),
      receivedAt: _requiredDateTime(data, 'receivedAt'),
    );
  }
}

/// 举报提交回执。
class CommunityReportSubmission {
  final String id;
  final String status;
  final DateTime createdAt;

  const CommunityReportSubmission({
    required this.id,
    required this.status,
    required this.createdAt,
  });

  factory CommunityReportSubmission.fromJson(Map<String, dynamic> json) {
    final data = _unwrapData(json);
    return CommunityReportSubmission(
      id: _requiredText(data, 'id'),
      status: _requiredText(data, 'status'),
      createdAt: _requiredDateTime(data, 'createdAt'),
    );
  }
}

/// A public, privacy-preserving entry in the co-creation thank-you wall.
///
/// The server stores a snapshot of the supporter profile at redemption time;
/// email addresses and account IDs are intentionally never exposed here.
class SupportWallEntry {
  final String id;
  final String displayName;
  final String handle;
  final String? avatarUrl;
  final String? note;
  final String tier;
  final DateTime redeemedAt;

  const SupportWallEntry({
    required this.id,
    required this.displayName,
    required this.handle,
    this.avatarUrl,
    this.note,
    required this.tier,
    required this.redeemedAt,
  });

  factory SupportWallEntry.fromJson(Map<String, dynamic> json) {
    return SupportWallEntry(
      id: _requiredText(json, 'id'),
      displayName: _optionalText(json, 'displayName') ?? '匿名同行者',
      handle: _optionalText(json, 'handle') ?? '',
      avatarUrl: _optionalText(json, 'avatarUrl'),
      note: _optionalText(json, 'note'),
      tier: _optionalText(json, 'tier') ?? '同行支持',
      redeemedAt: _requiredDateTime(json, 'redeemedAt'),
    );
  }
}

class SupportWallPage {
  final List<SupportWallEntry> items;
  final String? nextCursor;

  const SupportWallPage({required this.items, this.nextCursor});

  factory SupportWallPage.fromJson(Map<String, dynamic> json) {
    final data = _unwrapData(json);
    final rawItems = data['items'];
    if (rawItems is! List) {
      throw const FormatException('支持者墙响应缺少 items 列表');
    }
    return SupportWallPage(
      items: rawItems
          .whereType<Map>()
          .map(
            (item) =>
                SupportWallEntry.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false),
      nextCursor: _optionalText(data, 'nextCursor'),
    );
  }
}

class SupportCodeRedemption {
  final SupportWallEntry entry;
  final bool alreadyRedeemed;

  const SupportCodeRedemption({
    required this.entry,
    this.alreadyRedeemed = false,
  });

  factory SupportCodeRedemption.fromJson(Map<String, dynamic> json) {
    final data = _unwrapData(json);
    final rawEntry = data['entry'];
    if (rawEntry is! Map) {
      throw const FormatException('支持码响应缺少支持记录');
    }
    return SupportCodeRedemption(
      entry: SupportWallEntry.fromJson(Map<String, dynamic>.from(rawEntry)),
      alreadyRedeemed: data['alreadyRedeemed'] == true,
    );
  }
}

/// API for the co-creation thank-you wall and third-party support-code claim.
abstract interface class CommunitySupportApi {
  Future<SupportWallPage> listSupporters({String? cursor, int limit});

  Future<SupportCodeRedemption> redeemSupportCode({
    String? accessToken,
    required String code,
    String? note,
  });
}

/// 作者信誉信息。
///
/// 当 [meetsThreshold] 为 false 时，[score] 强制为 null，避免向用户呈现
/// 不可靠的分数。
class CommunityAuthorReputation {
  final String handle;
  final String displayName;
  final int publicPresets;
  final int nonAuthorSamples;
  final bool meetsThreshold;
  final double? score;
  final String? badgeLabel;
  final int uniqueUsers;
  final int uniquePresetCoverage;
  final double? completionPerformance;
  final double? usableRate;
  final double? ratingAverage;
  final int ratingCount;
  final double? diversityPerformance;
  final double? recencyPerformance;

  const CommunityAuthorReputation({
    required this.handle,
    required this.displayName,
    required this.publicPresets,
    required this.nonAuthorSamples,
    required this.meetsThreshold,
    this.score,
    this.badgeLabel,
    this.uniqueUsers = 0,
    this.uniquePresetCoverage = 0,
    this.completionPerformance,
    this.usableRate,
    this.ratingAverage,
    this.ratingCount = 0,
    this.diversityPerformance,
    this.recencyPerformance,
  });

  factory CommunityAuthorReputation.fromJson(Map<String, dynamic> json) {
    final data = _unwrapData(json);
    final meetsThreshold = _boolean(data, 'meetsThreshold');
    return CommunityAuthorReputation(
      handle: _requiredText(data, 'handle'),
      displayName:
          _optionalText(data, 'displayName') ?? _requiredText(data, 'handle'),
      publicPresets: _integer(data, 'publicPresets'),
      nonAuthorSamples: _integer(data, 'nonAuthorSamples'),
      meetsThreshold: meetsThreshold,
      // 当不满足阈值门槛时，强制忽略服务端可能返回的 score，保持空值。
      score: meetsThreshold
          ? (_optionalDouble(data, 'score') ??
                _optionalDouble(data, 'reputationScore'))
          : null,
      badgeLabel: _optionalText(data, 'badgeLabel'),
      uniqueUsers: _integer(data, 'uniqueUsers'),
      uniquePresetCoverage: _integer(data, 'uniquePresetCoverage'),
      completionPerformance: _optionalDouble(data, 'completionPerformance'),
      usableRate: _optionalDouble(data, 'usableRate'),
      ratingAverage: _optionalDouble(data, 'ratingAverage'),
      ratingCount: _integer(data, 'ratingCount'),
      diversityPerformance: _optionalDouble(data, 'diversityPerformance'),
      recencyPerformance: _optionalDouble(data, 'recencyPerformance'),
    );
  }
}

/// 遥测批量提交回执。
///
/// [skipped] 列出被服务端跳过（例如重复或格式不符）的事件及其原因，
/// 每一项为 `({String eventId, String reason})` 记录。
class CommunityTelemetryBatchResult {
  final int received;
  final List<({String eventId, String reason})> skipped;
  final DateTime receivedAt;

  const CommunityTelemetryBatchResult({
    required this.received,
    required this.skipped,
    required this.receivedAt,
  });

  factory CommunityTelemetryBatchResult.fromJson(Map<String, dynamic> json) {
    final data = _unwrapData(json);
    final rawSkipped = data['skipped'];
    final skipped = <({String eventId, String reason})>[];
    if (rawSkipped is List) {
      for (final item in rawSkipped) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          skipped.add((
            eventId: map['eventId']?.toString() ?? '',
            reason: map['reason']?.toString() ?? '',
          ));
        }
      }
    }
    return CommunityTelemetryBatchResult(
      received: _integer(data, 'received'),
      skipped: skipped,
      receivedAt: _requiredDateTime(data, 'receivedAt'),
    );
  }
}

/// 远程配置快照。
///
/// [etag] 来自服务端响应的 ETag 头部，调用方可在下次请求时通过
/// `If-None-Match` 头部回传以触发条件请求。
class CommunityRemoteConfig {
  final Map<String, dynamic> flags;
  final int schemaVersion;
  final DateTime generatedAt;
  final String source;
  final String? etag;

  const CommunityRemoteConfig({
    required this.flags,
    required this.schemaVersion,
    required this.generatedAt,
    required this.source,
    this.etag,
  });

  factory CommunityRemoteConfig.fromJson(
    Map<String, dynamic> json, {
    String? etag,
  }) {
    final data = _unwrapData(json);
    final rawFlags = data['flags'];
    if (rawFlags is! Map) {
      throw const FormatException('remote config flags must be an object');
    }
    return CommunityRemoteConfig(
      flags: Map<String, dynamic>.from(rawFlags),
      schemaVersion: _integer(data, 'schemaVersion'),
      generatedAt: _requiredDateTime(data, 'generatedAt'),
      source: _requiredText(data, 'source'),
      etag: etag,
    );
  }
}

/// Identity and account-policy metadata returned by `GET /health`.
class CommunityServiceInfo {
  static const supportedApiVersion = 1;
  static const supportedServiceNames = {
    'sohun-community',
    'consumable-workbench-community',
  };

  final String service;
  final int apiVersion;
  final bool registrationEnabled;
  final bool emailVerificationRequired;
  final String termsVersion;
  final String privacyVersion;

  const CommunityServiceInfo({
    required this.service,
    required this.apiVersion,
    required this.registrationEnabled,
    required this.emailVerificationRequired,
    required this.termsVersion,
    required this.privacyVersion,
  });

  bool get isCompatible =>
      supportedServiceNames.contains(service) &&
      apiVersion == supportedApiVersion;

  factory CommunityServiceInfo.fromJson(Map<String, dynamic> json) {
    final data = _unwrapData(json);
    return CommunityServiceInfo(
      service: _requiredText(data, 'service'),
      apiVersion: _integer(data, 'apiVersion'),
      registrationEnabled: _boolean(data, 'registrationEnabled'),
      emailVerificationRequired: _boolean(data, 'emailVerificationRequired'),
      termsVersion: _requiredText(data, 'termsVersion'),
      privacyVersion: _requiredText(data, 'privacyVersion'),
    );
  }
}

enum CommunityApiErrorCategory {
  configuration,
  validation,
  authentication,
  permission,
  conflict,
  rateLimit,
  network,
  timeout,
  server,
  protocol,
  unknown,
}

class CommunityApiException implements Exception {
  final String message;
  final CommunityApiErrorCategory category;
  final int? statusCode;
  final String? code;
  final dynamic details;

  const CommunityApiException(
    this.message, {
    required this.category,
    this.statusCode,
    this.code,
    this.details,
  });

  bool get isAuthenticationFailure =>
      category == CommunityApiErrorCategory.authentication;

  @override
  String toString() => message;
}

/// Injectable API boundary for the workbench's own service.
///
/// Community preset methods can be added to this interface without coupling
/// application accounts to Bambu Cloud.
abstract interface class CommunityApi {
  Uri get baseUri;

  Future<CommunityServiceInfo> health();

  Future<AppAccountPolicyDocument> fetchAccountPolicy(
    AppAccountPolicyType type, {
    String version = 'current',
  });

  Future<AppRegistrationResult> register(AppRegisterRequest request);

  Future<AppAuthSession> login(AppLoginRequest request);

  Future<AppAuthSession> loginFarmStaff(FarmStaffLoginRequest request);

  Future<AppAuthSession> changeFarmInitialPassword({
    required String accessToken,
    required FarmInitialPasswordChangeRequest request,
    required AppAuthSession currentSession,
  });

  Future<AppAuthSession> refresh({
    required String refreshToken,
    required AppUser currentUser,
  });

  Future<void> logout({
    required String accessToken,
    required String refreshToken,
  });

  Future<AppUser> me({required String accessToken});

  Future<AppUser> updateMe({
    required String accessToken,
    required AppUserUpdateRequest request,
  });

  Future<void> requestEmailVerification({required String accessToken});

  Future<AppUser> confirmEmailVerification({
    required String accessToken,
    required String code,
  });

  Future<void> requestPasswordReset(AppPasswordResetRequest request);

  Future<void> confirmPasswordReset(AppPasswordResetConfirmation confirmation);

  Future<void> deleteAccount({
    required String accessToken,
    required AppAccountDeletionRequest request,
  });
}

/// Account-scoped inventory sync shared by the desktop and mobile targets.
///
/// This capability is separate from the farm workspace snapshot API. It is
/// keyed by the signed-in sohun account and uses the desktop inventory UID as
/// the stable record identity.
abstract interface class PersonalInventoryApi {
  Future<PersonalInventorySnapshot> fetchPersonalInventory({
    required String accessToken,
  });

  Future<PersonalInventorySnapshot> replacePersonalInventory({
    required String accessToken,
    required PersonalInventorySnapshot snapshot,
  });
}

abstract interface class PersonalPrinterFaultApi {
  Future<PrinterFaultPage> fetchPrinterFaults({required String accessToken, int after = 0});
  Future<void> uploadPrinterFaults({required String accessToken, required List<PrinterFaultRecord> events});
  Future<void> readPrinterFaults({required String accessToken, required List<String> eventIds});
  Future<Map<String, dynamic>> createFaultMonitorLease({required String accessToken});
}

abstract interface class PersonalDeviceApi {
  Future<List<PersonalDevice>> fetchDevices({required String accessToken});
  Future<PersonalDevice> resolveDeviceTag({required String accessToken, required String deviceToken});
  Future<void> uploadDeviceStatus({required String accessToken, required List<Map<String, dynamic>> devices});
  Future<PersonalDevice> updateDevice({required String accessToken, required String printerKey, required Map<String, dynamic> changes});
  Future<PersonalDevice> rotateDeviceTag({required String accessToken, required String printerKey});
  Future<DeviceMaintenancePage> fetchDeviceMaintenance({required String accessToken, required String printerKey, int after = 0});
  Future<DeviceMaintenanceRecord> saveDeviceMaintenance({required String accessToken, required DeviceMaintenanceRecord record});
}

abstract interface class PersonalInventoryEventApi {
  Future<PersonalInventoryEventPage> fetchPersonalInventoryEvents({
    required String accessToken,
    required int afterCursor,
  });
  Future<void> appendPersonalInventoryEvents({
    required String accessToken,
    required List<PersonalInventoryEvent> events,
  });
}

abstract interface class CommunityPresetApi {
  Uri get baseUri;

  Future<CommunityPresetPage> listPresets({
    String? query,
    String? material,
    String? scene,
    String? printer,
    String sort,
    String? cursor,
    int limit,
    bool mine,
    String? accessToken,
  });

  Future<CommunityPreset> publishPreset({
    required String accessToken,
    required PrintParameterPreset preset,
    String visibility,
  });

  Future<CommunityPreset> updatePublishedPreset({
    required String accessToken,
    required String publicationId,
    required int revision,
    required PrintParameterPreset preset,
    String visibility,
  });

  Future<void> deletePublishedPreset({
    required String accessToken,
    required String publicationId,
  });

  Future<CommunityPreset> setPresetLiked({
    required String accessToken,
    required String publicationId,
    required bool liked,
  });

  Future<void> registerPresetDownload(String publicationId);
}

/// Phase E：参数可信度与社区反馈相关接口。
///
/// 通过该接口可获取参数集的信任度汇总、提交/更新/删除打印结果、登记
/// 应用场景、举报参数以及查询作者信誉。
abstract interface class CommunityTrustApi {
  /// 获取指定公开参数集的信任度汇总。
  Future<CommunityTrustSummary> fetchTrustSummary({
    required String publicationId,
    String? accessToken,
  });

  /// 提交一条打印结果。同一 [publicationId] 下以 clientResultId 幂等去重，
  /// 服务端返回 200 表示幂等命中、201 表示新建成功，两者均视为成功。
  Future<CommunityPrintResultSubmission> submitPrintResult({
    required String accessToken,
    required String publicationId,
    required Map<String, dynamic> payload,
  });

  /// 通过 [clientResultId] 修订已有打印结果。当并发更新发生冲突时，
  /// 服务端返回 409，本方法会以 `code='revision_conflict'` 抛出
  /// [CommunityApiException]，并在 `details.currentRevision` 中携带
  /// 服务端当前的修订号，便于调用方重试。
  Future<CommunityPrintResultSubmission> patchPrintResult({
    required String accessToken,
    required String publicationId,
    required String clientResultId,
    required int expectedRevision,
    required Map<String, dynamic> payload,
  });

  /// 删除指定打印结果。
  Future<void> deletePrintResult({
    required String accessToken,
    required String publicationId,
    required String clientResultId,
  });

  /// 登记某参数集被使用于某个客户端应用（例如某型号打印机/切片软件组合）。
  Future<void> putApplication({
    required String accessToken,
    required String publicationId,
    required String clientApplicationId,
  });

  /// 举报指定参数集。返回举报记录回执。
  Future<CommunityReportSubmission> reportPreset({
    required String accessToken,
    required String publicationId,
    required String reason,
    String? note,
  });

  /// 查询某作者的信誉信息。
  Future<CommunityAuthorReputation> fetchAuthorReputation({
    required String handle,
  });
}

/// Phase F：遥测上报与远程配置接口。
abstract interface class CommunityTelemetryApi {
  /// 批量上报遥测事件。请求通过自定义头部 `X-Install-Id-Hash` 标识来源
  /// 安装，无需登录态。
  Future<CommunityTelemetryBatchResult> submitTelemetryBatch({
    required String installIdHash,
    required List<Map<String, dynamic>> events,
  });

  /// 拉取远程配置。可传入 [ifNoneMatch] 进行条件请求；当服务端返回 304
  /// 时，本方法以 `code='not_modified'` 抛出 [CommunityApiException]，
  /// 调用方应捕获并保留本地缓存。
  Future<CommunityRemoteConfig> fetchRemoteConfig({
    required String appVersion,
    required String platform,
    String? ifNoneMatch,
  });
}

class CommunityApiClient
    implements
        CommunityApi,
        PersonalInventoryApi,
        PersonalInventoryEventApi,
        PersonalPrinterFaultApi,
        PersonalDeviceApi,
        CommunityPresetApi,
        CommunityTrustApi,
        CommunityTelemetryApi,
        CommunitySupportApi {
  @override
  final Uri baseUri;
  final http.Client _httpClient;
  final Duration requestTimeout;

  CommunityApiClient({
    required Uri baseUri,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 15),
  }) : baseUri = normalizeCommunityServerUri(baseUri.toString()),
       _httpClient = httpClient ?? http.Client();

  @override
  Future<CommunityServiceInfo> health() async {
    final payload = await _request('GET', '/health');
    final info = CommunityServiceInfo.fromJson(payload);
    if (!info.isCompatible) {
      throw CommunityApiException(
        'sohun 云服务响应不兼容，请稍后重试',
        category: CommunityApiErrorCategory.configuration,
        code: 'incompatible_server',
        details: {'service': info.service, 'apiVersion': info.apiVersion},
      );
    }
    return info;
  }

  @override
  Future<PrinterFaultPage> fetchPrinterFaults({required String accessToken, int after = 0}) async =>
      PrinterFaultPage.fromJson(await _request('GET', '/v1/me/printer-faults',
        accessToken: accessToken, queryParameters: {'after': '$after'}));
  @override
  Future<void> uploadPrinterFaults({required String accessToken, required List<PrinterFaultRecord> events}) async {
    await _request('POST', '/v1/me/printer-faults', accessToken: accessToken,
      body: {'events': events.map((e) => e.toJson()).toList()});
  }
  @override
  Future<void> readPrinterFaults({required String accessToken, required List<String> eventIds}) async {
    await _request('POST', '/v1/me/printer-faults/read', accessToken: accessToken, body: {'eventIds': eventIds});
  }
  @override
  Future<Map<String, dynamic>> createFaultMonitorLease({required String accessToken}) =>
      _request('POST', '/v1/me/printer-faults/monitor', accessToken: accessToken, body: {});

  @override
  Future<List<PersonalDevice>> fetchDevices({required String accessToken}) async {
    final json = await _request('GET', '/v1/me/devices', accessToken: accessToken, queryParameters: {'includeArchived': 'true'});
    return (json['devices'] as List).map((e) => PersonalDevice.fromJson(e as Map<String, dynamic>)).toList();
  }
  @override
  Future<PersonalDevice> resolveDeviceTag({required String accessToken, required String deviceToken}) async =>
      PersonalDevice.fromJson((await _request('GET', '/v1/me/device-tags/${Uri.encodeComponent(deviceToken)}', accessToken: accessToken))['device'] as Map<String, dynamic>);
  @override
  Future<void> uploadDeviceStatus({required String accessToken, required List<Map<String, dynamic>> devices}) async {
    await _request('POST', '/v1/me/devices/status', accessToken: accessToken, body: {'devices': devices});
  }
  @override
  Future<PersonalDevice> updateDevice({required String accessToken, required String printerKey, required Map<String, dynamic> changes}) async =>
      PersonalDevice.fromJson((await _request('PATCH', '/v1/me/devices/${Uri.encodeComponent(printerKey)}', accessToken: accessToken, body: changes))['device'] as Map<String, dynamic>);
  @override
  Future<PersonalDevice> rotateDeviceTag({required String accessToken, required String printerKey}) async =>
      PersonalDevice.fromJson((await _request('POST', '/v1/me/devices/${Uri.encodeComponent(printerKey)}/rotate-tag', accessToken: accessToken, body: {}))['device'] as Map<String, dynamic>);
  @override
  Future<DeviceMaintenancePage> fetchDeviceMaintenance({required String accessToken, required String printerKey, int after = 0}) async =>
      DeviceMaintenancePage.fromJson(await _request('GET', '/v1/me/devices/${printerKey.isEmpty ? '' : '${Uri.encodeComponent(printerKey)}/'}maintenance', accessToken: accessToken, queryParameters: {'after': '$after'}));
  @override
  Future<DeviceMaintenanceRecord> saveDeviceMaintenance({required String accessToken, required DeviceMaintenanceRecord record}) async =>
      DeviceMaintenanceRecord.fromJson((await _request('POST', '/v1/me/devices/${Uri.encodeComponent(record.printerKey)}/maintenance', accessToken: accessToken, body: record.toJson(), acceptableStatuses: const [200, 201]))['record'] as Map<String, dynamic>);

  @override
  Future<AppAccountPolicyDocument> fetchAccountPolicy(
    AppAccountPolicyType type, {
    String version = 'current',
  }) async {
    final normalizedVersion = version.trim();
    if (normalizedVersion != 'current' &&
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(normalizedVersion)) {
      throw const CommunityApiException(
        '政策版本格式不正确',
        category: CommunityApiErrorCategory.validation,
      );
    }
    final payload = await _request(
      'GET',
      '/v1/policies/${type.pathSegment}/$normalizedVersion',
    );
    final data = _unwrapData(payload);
    final rawPolicy = data['policy'];
    if (rawPolicy is! Map) {
      throw const CommunityApiException(
        '政策正文响应格式不正确',
        category: CommunityApiErrorCategory.protocol,
      );
    }
    return AppAccountPolicyDocument.fromJson(
      Map<String, dynamic>.from(rawPolicy),
    );
  }

  @override
  Future<AppRegistrationResult> register(AppRegisterRequest request) async {
    final payload = await _request(
      'POST',
      '/v1/auth/register',
      body: request.toJson(),
      acceptableStatuses: const [200, 201],
    );
    final user = _parseUser(payload);
    final session = _parseSession(payload, user: user);
    return AppRegistrationResult(
      user: user,
      session: session,
      verificationRequired: !user.emailVerified,
      verificationEmailSent:
          _unwrapData(payload)['verificationEmailSent'] == true,
    );
  }

  @override
  Future<AppAuthSession> login(AppLoginRequest request) async {
    final payload = await _request(
      'POST',
      '/v1/auth/login',
      body: request.toJson(),
    );
    final user = _parseUser(payload);
    return _parseSession(payload, user: user);
  }

  @override
  Future<PersonalInventorySnapshot> fetchPersonalInventory({
    required String accessToken,
  }) async {
    final payload = await _request(
      'GET',
      '/v1/me/inventory/snapshot',
      accessToken: accessToken,
    );
    try {
      return PersonalInventorySnapshot.fromJson(_unwrapData(payload));
    } on FormatException catch (error) {
      throw CommunityApiException(
        '个人库存同步响应格式不正确：${error.message}',
        category: CommunityApiErrorCategory.protocol,
      );
    }
  }

  @override
  Future<PersonalInventoryEventPage> fetchPersonalInventoryEvents({
    required String accessToken,
    required int afterCursor,
  }) async {
    final payload = await _request(
      'GET',
      '/v1/me/inventory/events',
      accessToken: accessToken,
      queryParameters: {'after': '$afterCursor', 'limit': '200'},
    );
    try {
      return PersonalInventoryEventPage.fromJson(_unwrapData(payload));
    } on FormatException catch (error) {
      throw CommunityApiException(
        '耗材账本响应格式不正确：${error.message}',
        category: CommunityApiErrorCategory.protocol,
      );
    }
  }

  @override
  Future<void> appendPersonalInventoryEvents({
    required String accessToken,
    required List<PersonalInventoryEvent> events,
  }) async {
    await _request(
      'POST',
      '/v1/me/inventory/events',
      accessToken: accessToken,
      body: {'events': events.map((event) => event.toJson()).toList()},
    );
  }

  @override
  Future<PersonalInventorySnapshot> replacePersonalInventory({
    required String accessToken,
    required PersonalInventorySnapshot snapshot,
  }) async {
    final payload = await _request(
      'PUT',
      '/v1/me/inventory/snapshot',
      accessToken: accessToken,
      body: snapshot.toPutJson(),
    );
    try {
      return PersonalInventorySnapshot.fromJson(_unwrapData(payload));
    } on FormatException catch (error) {
      throw CommunityApiException(
        '个人库存同步响应格式不正确：${error.message}',
        category: CommunityApiErrorCategory.protocol,
      );
    }
  }

  @override
  Future<AppAuthSession> loginFarmStaff(FarmStaffLoginRequest request) async {
    final payload = await _request(
      'POST',
      '/v1/farm/auth/staff-login',
      body: request.toJson(),
    );
    final user = _parseUser(payload);
    final sessionPayload = _unwrapData(payload);
    final organization = sessionPayload['organization'];
    final staff = sessionPayload['staff'];
    if (organization is! Map || staff is! Map) {
      throw const CommunityApiException(
        '农场员工登录响应缺少组织或员工资料',
        category: CommunityApiErrorCategory.protocol,
      );
    }
    sessionPayload['authRealm'] = 'farm_staff';
    sessionPayload['farmOrganizationId'] = organization['id'];
    sessionPayload['farmOrganizationCode'] = organization['organizationCode'];
    sessionPayload['farmOrganizationName'] = organization['displayName'];
    sessionPayload['farmStaffMemberId'] = staff['id'];
    sessionPayload['farmStaffLoginName'] = staff['loginName'];
    sessionPayload['farmStaffRoleCode'] = staff['primaryRoleCode'];
    sessionPayload['farmStaffRoleCodes'] = staff['roleCodes'];
    sessionPayload['mustChangePassword'] =
        sessionPayload['mustChangePassword'] == true;
    return _parseSession(sessionPayload, user: user);
  }

  @override
  Future<AppAuthSession> changeFarmInitialPassword({
    required String accessToken,
    required FarmInitialPasswordChangeRequest request,
    required AppAuthSession currentSession,
  }) async {
    final payload = await _request(
      'POST',
      '/v1/farm/auth/change-initial-password',
      accessToken: accessToken,
      body: request.toJson(),
    );
    final sessionPayload = _unwrapData(payload);
    sessionPayload['authRealm'] = currentSession.authRealm;
    sessionPayload['farmOrganizationId'] = currentSession.farmOrganizationId;
    sessionPayload['farmOrganizationCode'] =
        currentSession.farmOrganizationCode;
    sessionPayload['farmOrganizationName'] =
        currentSession.farmOrganizationName;
    sessionPayload['farmStaffMemberId'] = currentSession.farmStaffMemberId;
    sessionPayload['farmStaffLoginName'] = currentSession.farmStaffLoginName;
    sessionPayload['farmStaffRoleCode'] = currentSession.farmStaffRoleCode;
    sessionPayload['farmStaffRoleCodes'] = currentSession.farmStaffRoleCodes;
    sessionPayload['mustChangePassword'] = false;
    return _parseSession(sessionPayload, user: currentSession.user);
  }

  @override
  Future<AppAuthSession> refresh({
    required String refreshToken,
    required AppUser currentUser,
  }) async {
    if (refreshToken.isEmpty) {
      throw const CommunityApiException(
        '刷新凭据为空，请重新登录',
        category: CommunityApiErrorCategory.authentication,
      );
    }
    final payload = await _request(
      'POST',
      '/v1/auth/refresh',
      body: {'refreshToken': refreshToken},
    );
    final user = _tryParseUser(payload) ?? currentUser;
    return _parseSession(
      payload,
      user: user,
      fallbackRefreshToken: refreshToken,
    );
  }

  @override
  Future<void> logout({
    required String accessToken,
    required String refreshToken,
  }) async {
    if (refreshToken.isEmpty) {
      throw const CommunityApiException(
        '刷新凭据为空，本地会话仍将退出',
        category: CommunityApiErrorCategory.authentication,
      );
    }
    await _request(
      'POST',
      '/v1/auth/logout',
      accessToken: accessToken,
      body: {'refreshToken': refreshToken},
      allowEmpty: true,
      acceptableStatuses: const [200, 204],
    );
  }

  @override
  Future<AppUser> me({required String accessToken}) async {
    final payload = await _request('GET', '/v1/me', accessToken: accessToken);
    return _parseUser(payload);
  }

  @override
  Future<AppUser> updateMe({
    required String accessToken,
    required AppUserUpdateRequest request,
  }) async {
    final payload = await _request(
      'PATCH',
      '/v1/me',
      accessToken: accessToken,
      body: request.toJson(),
    );
    return _parseUser(payload);
  }

  @override
  Future<void> requestEmailVerification({required String accessToken}) async {
    await _request(
      'POST',
      '/v1/me/email-verification/request',
      accessToken: accessToken,
      body: const {},
    );
  }

  @override
  Future<AppUser> confirmEmailVerification({
    required String accessToken,
    required String code,
  }) async {
    final normalizedCode = code.trim();
    if (!RegExp(r'^\d{8}$').hasMatch(normalizedCode)) {
      throw const CommunityApiException(
        '验证码必须为 8 位数字',
        category: CommunityApiErrorCategory.validation,
      );
    }
    final payload = await _request(
      'POST',
      '/v1/me/email-verification/confirm',
      accessToken: accessToken,
      body: {'code': normalizedCode},
    );
    return _parseUser(payload);
  }

  @override
  Future<void> requestPasswordReset(AppPasswordResetRequest request) async {
    await _request(
      'POST',
      '/v1/auth/password-reset/request',
      body: request.toJson(),
      acceptableStatuses: const [200, 202],
    );
  }

  @override
  Future<void> confirmPasswordReset(
    AppPasswordResetConfirmation confirmation,
  ) async {
    await _request(
      'POST',
      '/v1/auth/password-reset/confirm',
      body: confirmation.toJson(),
    );
  }

  @override
  Future<void> deleteAccount({
    required String accessToken,
    required AppAccountDeletionRequest request,
  }) async {
    await _request(
      'DELETE',
      '/v1/me',
      accessToken: accessToken,
      body: request.toJson(),
    );
  }

  @override
  Future<SupportWallPage> listSupporters({
    String? cursor,
    int limit = 30,
  }) async {
    final payload = await _request(
      'GET',
      '/v1/supporters',
      queryParameters: {
        'limit': limit.clamp(1, 100).toString(),
        if (cursor?.trim().isNotEmpty == true) 'cursor': cursor!.trim(),
      },
    );
    try {
      return SupportWallPage.fromJson(payload);
    } on FormatException catch (error) {
      throw CommunityApiException(
        '支持者墙响应格式不正确：${error.message}',
        category: CommunityApiErrorCategory.protocol,
      );
    }
  }

  @override
  Future<SupportCodeRedemption> redeemSupportCode({
    String? accessToken,
    required String code,
    String? note,
  }) async {
    final normalized = code.trim();
    if (normalized.length < 8 || normalized.length > 200) {
      throw const CommunityApiException(
        '卡密长度不正确，请粘贴支付后收到的完整卡密',
        category: CommunityApiErrorCategory.validation,
      );
    }
    final payload = await _request(
      'POST',
      '/v1/supporters/redeem',
      accessToken: accessToken,
      body: {
        'code': normalized,
        if (note?.trim().isNotEmpty == true) 'note': note!.trim(),
      },
      acceptableStatuses: const [200, 201],
    );
    try {
      return SupportCodeRedemption.fromJson(payload);
    } on FormatException catch (error) {
      throw CommunityApiException(
        '支持码响应格式不正确：${error.message}',
        category: CommunityApiErrorCategory.protocol,
      );
    }
  }

  @override
  Future<CommunityPresetPage> listPresets({
    String? query,
    String? material,
    String? scene,
    String? printer,
    String sort = 'recommended',
    String? cursor,
    int limit = 30,
    bool mine = false,
    String? accessToken,
  }) async {
    final payload = await _request(
      'GET',
      '/v1/presets',
      accessToken: accessToken,
      queryParameters: {
        if (query?.trim().isNotEmpty == true) 'q': query!.trim(),
        if (material?.trim().isNotEmpty == true) 'material': material!.trim(),
        if (scene?.trim().isNotEmpty == true) 'scene': scene!.trim(),
        if (printer?.trim().isNotEmpty == true) 'printer': printer!.trim(),
        'sort': sort,
        'limit': limit.clamp(1, 100).toString(),
        if (cursor?.isNotEmpty == true) 'cursor': cursor!,
        if (mine) 'owner': 'me',
      },
    );
    try {
      return CommunityPresetPage.fromJson(_unwrapData(payload));
    } on FormatException catch (error) {
      throw CommunityApiException(
        '社区参数响应格式不正确：${error.message}',
        category: CommunityApiErrorCategory.protocol,
      );
    }
  }

  @override
  Future<CommunityPreset> publishPreset({
    required String accessToken,
    required PrintParameterPreset preset,
    String visibility = 'public',
  }) async {
    final payload = await _request(
      'POST',
      '/v1/presets',
      accessToken: accessToken,
      body: {'preset': preset.toBbsparamMap(), 'visibility': visibility},
    );
    return _parseCommunityPreset(payload);
  }

  @override
  Future<CommunityPreset> updatePublishedPreset({
    required String accessToken,
    required String publicationId,
    required int revision,
    required PrintParameterPreset preset,
    String visibility = 'public',
  }) async {
    final payload = await _request(
      'PATCH',
      '/v1/presets/${Uri.encodeComponent(publicationId)}',
      accessToken: accessToken,
      body: {
        'preset': preset.toBbsparamMap(),
        'visibility': visibility,
        'revision': revision,
      },
    );
    return _parseCommunityPreset(payload);
  }

  @override
  Future<void> deletePublishedPreset({
    required String accessToken,
    required String publicationId,
  }) async {
    await _request(
      'DELETE',
      '/v1/presets/${Uri.encodeComponent(publicationId)}',
      accessToken: accessToken,
      allowEmpty: true,
    );
  }

  @override
  Future<CommunityPreset> setPresetLiked({
    required String accessToken,
    required String publicationId,
    required bool liked,
  }) async {
    final payload = await _request(
      liked ? 'PUT' : 'DELETE',
      '/v1/presets/${Uri.encodeComponent(publicationId)}/like',
      accessToken: accessToken,
    );
    return _parseCommunityPreset(payload);
  }

  @override
  Future<void> registerPresetDownload(String publicationId) async {
    await _request(
      'POST',
      '/v1/presets/${Uri.encodeComponent(publicationId)}/download',
      allowEmpty: true,
    );
  }

  // -- Phase E: CommunityTrustApi ------------------------------------------

  @override
  Future<CommunityTrustSummary> fetchTrustSummary({
    required String publicationId,
    String? accessToken,
  }) async {
    final payload = await _request(
      'GET',
      '/v1/presets/${Uri.encodeComponent(publicationId)}/print-results/summary',
      accessToken: accessToken,
    );
    return CommunityTrustSummary.fromJson(payload);
  }

  @override
  Future<CommunityPrintResultSubmission> submitPrintResult({
    required String accessToken,
    required String publicationId,
    required Map<String, dynamic> payload,
  }) async {
    // 200 表示幂等命中，201 表示新建成功，两者均视为成功。
    final response = await _requestWithHeaders(
      'POST',
      '/v1/presets/${Uri.encodeComponent(publicationId)}/print-results',
      accessToken: accessToken,
      body: payload,
      acceptableStatuses: const [200, 201],
    );
    return CommunityPrintResultSubmission.fromJson(response.body);
  }

  @override
  Future<CommunityPrintResultSubmission> patchPrintResult({
    required String accessToken,
    required String publicationId,
    required String clientResultId,
    required int expectedRevision,
    required Map<String, dynamic> payload,
  }) async {
    try {
      final response = await _requestWithHeaders(
        'PATCH',
        '/v1/presets/${Uri.encodeComponent(publicationId)}'
            '/print-results/${Uri.encodeComponent(clientResultId)}',
        accessToken: accessToken,
        body: {...payload, 'expectedRevision': expectedRevision},
      );
      return CommunityPrintResultSubmission.fromJson(response.body);
    } on CommunityApiException catch (error) {
      if (error.statusCode == 409 && error.code == 'revision_conflict') {
        // 规范化冲突响应：确保 details 为 Map 并携带 currentRevision。
        final rawDetails = error.details;
        final Map<String, dynamic> detailsMap = rawDetails is Map
            ? Map<String, dynamic>.from(rawDetails)
            : <String, dynamic>{};
        throw CommunityApiException(
          error.message,
          category: error.category,
          statusCode: 409,
          code: 'revision_conflict',
          details: detailsMap,
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> deletePrintResult({
    required String accessToken,
    required String publicationId,
    required String clientResultId,
  }) async {
    await _request(
      'DELETE',
      '/v1/presets/${Uri.encodeComponent(publicationId)}'
          '/print-results/${Uri.encodeComponent(clientResultId)}',
      accessToken: accessToken,
      allowEmpty: true,
    );
  }

  @override
  Future<void> putApplication({
    required String accessToken,
    required String publicationId,
    required String clientApplicationId,
  }) async {
    await _request(
      'PUT',
      '/v1/presets/${Uri.encodeComponent(publicationId)}'
          '/applications/${Uri.encodeComponent(clientApplicationId)}',
      accessToken: accessToken,
      allowEmpty: true,
    );
  }

  @override
  Future<CommunityReportSubmission> reportPreset({
    required String accessToken,
    required String publicationId,
    required String reason,
    String? note,
  }) async {
    final payload = await _request(
      'POST',
      '/v1/presets/${Uri.encodeComponent(publicationId)}/reports',
      accessToken: accessToken,
      body: {'reason': reason, if (note != null) 'note': note},
    );
    return CommunityReportSubmission.fromJson(payload);
  }

  @override
  Future<CommunityAuthorReputation> fetchAuthorReputation({
    required String handle,
  }) async {
    final payload = await _request(
      'GET',
      '/v1/authors/${Uri.encodeComponent(handle)}/reputation',
    );
    return CommunityAuthorReputation.fromJson(payload);
  }

  // -- Phase F: CommunityTelemetryApi --------------------------------------

  @override
  Future<CommunityTelemetryBatchResult> submitTelemetryBatch({
    required String installIdHash,
    required List<Map<String, dynamic>> events,
  }) async {
    final payload = await _request(
      'POST',
      '/v1/telemetry/batch',
      extraHeaders: {'X-Install-Id-Hash': installIdHash},
      body: {'events': events},
    );
    return CommunityTelemetryBatchResult.fromJson(payload);
  }

  @override
  Future<CommunityRemoteConfig> fetchRemoteConfig({
    required String appVersion,
    required String platform,
    String? ifNoneMatch,
  }) async {
    // 允许 200 与 304 两种成功状态。304 时响应体通常为空，因此允许空响应。
    final response = await _requestWithHeaders(
      'GET',
      '/v1/config',
      queryParameters: {'appVersion': appVersion, 'platform': platform},
      acceptableStatuses: const [200, 304],
      allowEmpty: true,
      extraHeaders: {if (ifNoneMatch != null) 'If-None-Match': ifNoneMatch},
    );
    if (response.statusCode == 304) {
      throw const CommunityApiException(
        '远程配置未变更',
        category: CommunityApiErrorCategory.protocol,
        code: 'not_modified',
      );
    }
    return CommunityRemoteConfig.fromJson(
      response.body,
      etag: response.headers['etag'],
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? accessToken,
    bool allowEmpty = false,
    Map<String, String>? queryParameters,
    List<int> acceptableStatuses = const [200],
    Map<String, String>? extraHeaders,
  }) async {
    final result = await _requestWithHeaders(
      method,
      path,
      body: body,
      accessToken: accessToken,
      allowEmpty: allowEmpty,
      queryParameters: queryParameters,
      acceptableStatuses: acceptableStatuses,
      extraHeaders: extraHeaders,
    );
    return result.body;
  }

  /// 内部辅助方法：返回解析后的 JSON body、响应 headers 与状态码。
  ///
  /// 之所以拆分出此方法（而非扩展 [_request] 的返回类型），是为了在不破坏
  /// 现有调用方（仅消费 body）的前提下，让 [fetchRemoteConfig] 等需要
  /// 读取响应头（例如 ETag）的方法也能复用同一套错误处理与超时逻辑。
  /// 通过 [acceptableStatuses] 可放宽成功状态码判定（如 304、201）；
  /// 通过 [extraHeaders] 可注入自定义请求头（如 `X-Install-Id-Hash`、
  /// `If-None-Match`）。
  Future<
    ({Map<String, dynamic> body, Map<String, String> headers, int statusCode})
  >
  _requestWithHeaders(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? accessToken,
    bool allowEmpty = false,
    Map<String, String>? queryParameters,
    List<int> acceptableStatuses = const [200],
    Map<String, String>? extraHeaders,
  }) async {
    if (accessToken != null && accessToken.trim().isEmpty) {
      throw const CommunityApiException(
        '登录凭据为空，请重新登录',
        category: CommunityApiErrorCategory.authentication,
      );
    }

    var endpoint = _endpoint(path);
    if (queryParameters != null && queryParameters.isNotEmpty) {
      endpoint = endpoint.replace(queryParameters: queryParameters);
    }
    final request = http.Request(method, endpoint);
    request.headers.addAll({
      'Accept': 'application/json',
      'Accept-Language': 'zh-CN',
      if (body != null) 'Content-Type': 'application/json; charset=utf-8',
      if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      if (extraHeaders != null) ...extraHeaders,
    });
    if (body != null) request.body = jsonEncode(body);

    try {
      final response = await _httpClient
          .send(request)
          .then(http.Response.fromStream)
          .timeout(requestTimeout);
      if (!acceptableStatuses.contains(response.statusCode)) {
        throw _apiError(response);
      }
      if (response.bodyBytes.isEmpty) {
        if (allowEmpty) {
          return (
            body: const <String, dynamic>{},
            headers: response.headers,
            statusCode: response.statusCode,
          );
        }
        throw const CommunityApiException(
          'sohun 云返回了空响应，请稍后重试',
          category: CommunityApiErrorCategory.protocol,
        );
      }
      return (
        body: _decodeJsonObject(response.bodyBytes),
        headers: response.headers,
        statusCode: response.statusCode,
      );
    } on CommunityApiException {
      rethrow;
    } on TimeoutException {
      throw const CommunityApiException(
        '请求超时，请检查网络后重试',
        category: CommunityApiErrorCategory.timeout,
      );
    } on SocketException {
      throw const CommunityApiException(
        '无法连接 sohun 云，请检查网络后重试',
        category: CommunityApiErrorCategory.network,
      );
    } on http.ClientException {
      throw const CommunityApiException(
        '无法连接 sohun 云，请检查网络后重试',
        category: CommunityApiErrorCategory.network,
      );
    } on FormatException {
      throw const CommunityApiException(
        'sohun 云返回的数据格式不正确，请稍后重试',
        category: CommunityApiErrorCategory.protocol,
      );
    }
  }

  Uri _endpoint(String path) {
    final relative = path.startsWith('/') ? path : '/$path';
    return Uri.parse('${baseUri.toString()}$relative');
  }

  AppUser _parseUser(Map<String, dynamic> root) {
    final user = _tryParseUser(root);
    if (user == null) {
      throw const CommunityApiException(
        'sohun 云响应缺少用户资料，请稍后重试',
        category: CommunityApiErrorCategory.protocol,
      );
    }
    return user;
  }

  AppUser? _tryParseUser(Map<String, dynamic> root) {
    final payload = _unwrapData(root);
    final rawUser = payload['user'];
    if (rawUser is Map) {
      return AppUser.fromJson(Map<String, dynamic>.from(rawUser));
    }
    if (payload.containsKey('id') && payload.containsKey('email')) {
      return AppUser.fromJson(payload);
    }
    return null;
  }

  AppAuthSession _parseSession(
    Map<String, dynamic> root, {
    required AppUser user,
    String? fallbackRefreshToken,
  }) {
    final payload = _unwrapData(root);
    final rawSession = payload['session'];
    final session = rawSession is Map
        ? Map<String, dynamic>.from(rawSession)
        : Map<String, dynamic>.from(payload);
    session['user'] = user.toJson();
    session['serverBaseUrl'] = baseUri.toString();
    if (!_hasAnyKey(session, const ['refreshToken', 'refresh_token']) &&
        fallbackRefreshToken != null) {
      session['refreshToken'] = fallbackRefreshToken;
    }
    _normalizeExpiry(session, 'expiresAt', 'expires_at', 'expiresIn');
    _normalizeExpiry(
      session,
      'refreshExpiresAt',
      'refresh_expires_at',
      'refreshExpiresIn',
    );
    try {
      return AppAuthSession.fromJson(session);
    } on FormatException catch (error) {
      throw CommunityApiException(
        '认证响应格式不正确：${error.message}',
        category: CommunityApiErrorCategory.protocol,
      );
    }
  }

  CommunityPreset _parseCommunityPreset(Map<String, dynamic> root) {
    try {
      return CommunityPreset.fromJson(_unwrapData(root));
    } on FormatException catch (error) {
      throw CommunityApiException(
        '社区参数响应格式不正确：${error.message}',
        category: CommunityApiErrorCategory.protocol,
      );
    }
  }

  static void _normalizeExpiry(
    Map<String, dynamic> map,
    String camelKey,
    String snakeKey,
    String durationKey,
  ) {
    if (_hasAnyKey(map, [camelKey, snakeKey])) return;
    final rawDuration = map[durationKey];
    final seconds = rawDuration is num
        ? rawDuration.toInt()
        : int.tryParse(rawDuration?.toString() ?? '');
    if (seconds != null && seconds > 0) {
      map[camelKey] = DateTime.now()
          .add(Duration(seconds: seconds))
          .toUtc()
          .toIso8601String();
    }
  }

  static bool _hasAnyKey(Map<String, dynamic> map, List<String> keys) =>
      keys.any((key) => map[key] != null);
}

Map<String, dynamic> _decodeJsonObject(List<int> bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) throw const FormatException('JSON 根节点不是对象');
  return Map<String, dynamic>.from(decoded);
}

Map<String, dynamic> _unwrapData(Map<String, dynamic> root) {
  final data = root['data'];
  return data is Map ? Map<String, dynamic>.from(data) : root;
}

/// 从 JSON 中读取必填字符串字段；缺失或为空时抛出 [FormatException]。
String _requiredText(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('缺少必填字段：$key');
}

/// 从 JSON 中读取可选字符串字段；缺失、为 null 或空字符串时返回 null。
String? _optionalText(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  return null;
}

/// 从 JSON 中读取整数字段；缺失或无法解析时返回 [defaultValue]。
int _integer(Map<String, dynamic> json, String key, {int defaultValue = 0}) {
  final value = json[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? defaultValue;
  return defaultValue;
}

/// 从 JSON 中读取可选 double 字段；缺失或无法解析时返回 null。
double? _optionalDouble(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// 从 JSON 中读取 double 字段；缺失或无法解析时返回 [defaultValue]。
double _doubleWithDefault(
  Map<String, dynamic> json,
  String key,
  double defaultValue,
) {
  return _optionalDouble(json, key) ?? defaultValue;
}

/// 从 JSON 中读取布尔字段；缺失或类型不符时返回 [defaultValue]。
bool _boolean(
  Map<String, dynamic> json,
  String key, {
  bool defaultValue = false,
}) {
  final value = json[key];
  if (value is bool) return value;
  return defaultValue;
}

/// 从 JSON 中读取可选 DateTime 字段；缺失或无法解析时返回 null。
DateTime? _optionalDateTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}

/// 从 JSON 中读取必填 DateTime 字段；缺失或无法解析时抛出 [FormatException]。
DateTime _requiredDateTime(Map<String, dynamic> json, String key) {
  final value = _optionalDateTime(json, key);
  if (value == null) {
    throw FormatException('缺少必填字段：$key');
  }
  return value;
}

CommunityApiException _apiError(http.Response response) {
  Map<String, dynamic>? json;
  try {
    json = _decodeJsonObject(response.bodyBytes);
  } catch (_) {
    json = null;
  }

  final message = _serverMessage(json) ?? _fallbackMessage(response.statusCode);
  final nestedError = json?['error'];
  final nested = nestedError is Map ? nestedError : const <String, dynamic>{};
  return CommunityApiException(
    message,
    category: _categoryForStatus(response.statusCode),
    statusCode: response.statusCode,
    code: (json?['code'] ?? nested['code'])?.toString(),
    details: json?['errors'] ?? json?['details'] ?? nested['details'],
  );
}

String? _serverMessage(Map<String, dynamic>? json) {
  if (json == null) return null;
  final direct = json['message'];
  if (direct is String && direct.trim().isNotEmpty) return direct.trim();
  final error = json['error'];
  if (error is String && error.trim().isNotEmpty) return error.trim();
  if (error is Map) {
    final nested = error['message'];
    if (nested is String && nested.trim().isNotEmpty) return nested.trim();
  }
  final data = json['data'];
  if (data is Map) {
    final nested = data['message'];
    if (nested is String && nested.trim().isNotEmpty) return nested.trim();
  }
  return null;
}

CommunityApiErrorCategory _categoryForStatus(int statusCode) {
  return switch (statusCode) {
    400 || 422 => CommunityApiErrorCategory.validation,
    401 => CommunityApiErrorCategory.authentication,
    403 => CommunityApiErrorCategory.permission,
    409 => CommunityApiErrorCategory.conflict,
    429 => CommunityApiErrorCategory.rateLimit,
    >= 500 => CommunityApiErrorCategory.server,
    _ => CommunityApiErrorCategory.unknown,
  };
}

String _fallbackMessage(int statusCode) {
  return switch (statusCode) {
    400 || 422 => '提交的信息不符合要求，请检查后重试',
    401 => '登录已失效，请重新登录',
    403 => '当前账号无权执行此操作',
    404 => '当前 sohun 云暂不支持此功能，请更新应用后重试',
    409 => '邮箱或用户名已被使用',
    429 => '操作过于频繁，请稍后重试',
    >= 500 => 'sohun 云暂时不可用，请稍后重试',
    _ => 'sohun 云请求失败（HTTP $statusCode）',
  };
}

/// 提供社区参数信任评价服务的客户端实例。
///
/// 仅在用户已配置分享服务器地址时返回 [CommunityApiClient]，否则返回
/// null。与 [communityPresetApiProvider] 一致，每次 endpoint 变化都会
/// 重新构造客户端。
final communityTrustApiProvider = Provider<CommunityTrustApi?>((ref) {
  final endpoint = ref.watch(appAuthProvider.select((state) => state.endpoint));
  if (endpoint == null) return null;
  return CommunityApiClient(
    baseUri: endpoint,
    httpClient: ref.watch(communityHttpClientProvider),
  );
});

/// 提供社区遥测与远程配置服务的客户端实例。
///
/// 仅在用户已配置分享服务器地址时返回 [CommunityApiClient]，否则返回
/// null。遥测接口本身不需要登录态，但仍依赖服务器地址已配置。
final communityTelemetryApiProvider = Provider<CommunityTelemetryApi?>((ref) {
  final endpoint = ref.watch(appAuthProvider.select((state) => state.endpoint));
  if (endpoint == null) return null;
  return CommunityApiClient(
    baseUri: endpoint,
    httpClient: ref.watch(communityHttpClientProvider),
  );
});
