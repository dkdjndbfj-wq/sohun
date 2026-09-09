import 'package:flutter/foundation.dart';

/// 打印结果归因类型。
///
/// 持久化枚举必须在 Dart 模型、SQLite、HTTP schema 和 Node 校验中使用同一组稳定值。
enum ResultAttribution {
  /// 精确归因：通过切片产物 hash 精确匹配。
  exact('exact'),

  /// 手动归因：用户明确关联。
  manual('manual'),

  /// 模糊归因：有多个候选，无法精确确定。
  ambiguous('ambiguous'),

  /// 未归因：无法关联参数。
  unknown('unknown');

  final String value;
  const ResultAttribution(this.value);

  static ResultAttribution fromString(String? v) {
    return switch (v) {
      'exact' => ResultAttribution.exact,
      'manual' => ResultAttribution.manual,
      'ambiguous' => ResultAttribution.ambiguous,
      _ => ResultAttribution.unknown,
    };
  }
}

/// 打印技术状态（设备事实，与用户评价分开）。
///
/// 不得把 "任务状态为 finished" 等同于 "打印品质优秀"。
enum TechnicalStatus {
  finished('finished'),
  failed('failed'),
  cancelled('cancelled');

  final String value;
  const TechnicalStatus(this.value);

  static TechnicalStatus fromString(String? v) {
    return switch (v) {
      'failed' => TechnicalStatus.failed,
      'cancelled' => TechnicalStatus.cancelled,
      _ => TechnicalStatus.finished,
    };
  }
}

/// 用户成品结果（用户补充评价，与设备状态分开）。
enum UserOutcome {
  success('success'),
  usable('usable'),
  qualityFailed('quality_failed');

  final String value;
  const UserOutcome(this.value);

  static UserOutcome? fromString(String? v) {
    return switch (v) {
      'success' => UserOutcome.success,
      'usable' => UserOutcome.usable,
      'quality_failed' => UserOutcome.qualityFailed,
      _ => null,
    };
  }
}

/// 证据级别。
enum EvidenceLevel {
  deviceRecorded('device_recorded'),
  userConfirmed('user_confirmed'),
  imported('imported');

  final String value;
  const EvidenceLevel(this.value);

  static EvidenceLevel fromString(String? v) {
    return switch (v) {
      'user_confirmed' => EvidenceLevel.userConfirmed,
      'imported' => EvidenceLevel.imported,
      _ => EvidenceLevel.deviceRecorded,
    };
  }
}

/// 分享同意状态。
///
/// [syncStatus] 复用该枚举；`revoked` 仅用于 sync_status，表示已撤销分享。
enum ShareConsent {
  notShared('not_shared'),
  pending('pending'),
  synced('synced'),
  failed('failed'),
  revokePending('revoke_pending'),
  revoked('revoked');

  final String value;
  const ShareConsent(this.value);

  static ShareConsent fromString(String? v) {
    return switch (v) {
      'pending' => ShareConsent.pending,
      'synced' => ShareConsent.synced,
      'failed' => ShareConsent.failed,
      'revoke_pending' => ShareConsent.revokePending,
      'revoked' => ShareConsent.revoked,
      _ => ShareConsent.notShared,
    };
  }
}

/// 打印结果模型（单一事实来源）。
///
/// 自动采集任务事实（technical_status/estimated_grams/actual_grams 等）和
/// 用户补充评价（rating/user_outcome/quality_score 等）分开存储。
/// 不得把 "finished" 直接显示为 "高质量成功"。
@immutable
class PresetPrintResult {
  final String id;
  final String clientRunId;
  final int taskId;
  final String taskUid;
  final String? snapshotId;
  final String? applicationId;
  final String presetDisplayName;
  final ResultAttribution attribution;
  final String? communityPublicationId;
  final String? communityVersionId;

  /// Immutable publication revision used to validate the preset fingerprint.
  final int? communityRevision;

  /// Optimistic-lock revision of the uploaded community result itself.
  final int? communityResultRevision;
  final String printerModel;
  final double? nozzleDiameter;
  final String? plateType;
  final String? materialProfile;
  final String? materialType;
  final String? materialBatchNo;
  final double? amsHumidity;
  final DateTime? amsHumiditySampledAt;
  final TechnicalStatus technicalStatus;
  final UserOutcome? userOutcome;
  final String? failureCode;
  final String? failureCategory;
  final double estimatedGrams;
  final double actualGrams;
  final int estimatedSeconds;
  final int actualSeconds;
  final int? rating;
  final bool? adhesionOk;
  final int? qualityScore;
  final String? userNote;
  final EvidenceLevel evidenceLevel;
  final ShareConsent shareConsent;
  final ShareConsent syncStatus;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PresetPrintResult({
    required this.id,
    required this.clientRunId,
    required this.taskId,
    this.taskUid = '',
    this.snapshotId,
    this.applicationId,
    this.presetDisplayName = '',
    this.attribution = ResultAttribution.unknown,
    this.communityPublicationId,
    this.communityVersionId,
    this.communityRevision,
    this.communityResultRevision,
    this.printerModel = '',
    this.nozzleDiameter,
    this.plateType,
    this.materialProfile,
    this.materialType,
    this.materialBatchNo,
    this.amsHumidity,
    this.amsHumiditySampledAt,
    this.technicalStatus = TechnicalStatus.finished,
    this.userOutcome,
    this.failureCode,
    this.failureCategory,
    this.estimatedGrams = 0,
    this.actualGrams = 0,
    this.estimatedSeconds = 0,
    this.actualSeconds = 0,
    this.rating,
    this.adhesionOk,
    this.qualityScore,
    this.userNote,
    this.evidenceLevel = EvidenceLevel.deviceRecorded,
    this.shareConsent = ShareConsent.notShared,
    this.syncStatus = ShareConsent.notShared,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 从数据库行构造。
  factory PresetPrintResult.fromRow(Map<String, dynamic> row) {
    return PresetPrintResult(
      id: row['id'] as String,
      clientRunId: row['client_run_id'] as String,
      taskId: row['task_id'] as int,
      taskUid: (row['task_uid'] as String?) ?? '',
      snapshotId: row['snapshot_id'] as String?,
      applicationId: row['application_id'] as String?,
      presetDisplayName: (row['preset_display_name'] as String?) ?? '',
      attribution: ResultAttribution.fromString(row['attribution'] as String?),
      communityPublicationId: row['community_publication_id'] as String?,
      communityVersionId: row['community_version_id'] as String?,
      communityRevision: row['community_revision'] as int?,
      communityResultRevision: row['community_result_revision'] as int?,
      printerModel: (row['printer_model'] as String?) ?? '',
      nozzleDiameter: (row['nozzle_diameter'] as num?)?.toDouble(),
      plateType: row['plate_type'] as String?,
      materialProfile: row['material_profile'] as String?,
      materialType: row['material_type'] as String?,
      materialBatchNo: row['material_batch_no'] as String?,
      amsHumidity: (row['ams_humidity'] as num?)?.toDouble(),
      amsHumiditySampledAt: row['ams_humidity_sampled_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              row['ams_humidity_sampled_at'] as int,
            )
          : null,
      technicalStatus:
          TechnicalStatus.fromString(row['technical_status'] as String?),
      userOutcome: UserOutcome.fromString(row['user_outcome'] as String?),
      failureCode: row['failure_code'] as String?,
      failureCategory: row['failure_category'] as String?,
      estimatedGrams: (row['estimated_grams'] as num?)?.toDouble() ?? 0,
      actualGrams: (row['actual_grams'] as num?)?.toDouble() ?? 0,
      estimatedSeconds: (row['estimated_seconds'] as int?) ?? 0,
      actualSeconds: (row['actual_seconds'] as int?) ?? 0,
      rating: row['rating'] as int?,
      adhesionOk:
          row['adhesion_ok'] == null ? null : (row['adhesion_ok'] as int) != 0,
      qualityScore: row['quality_score'] as int?,
      userNote: row['user_note'] as String?,
      evidenceLevel: EvidenceLevel.fromString(row['evidence_level'] as String?),
      shareConsent: ShareConsent.fromString(row['share_consent'] as String?),
      syncStatus: ShareConsent.fromString(row['sync_status'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }
}
