import 'dart:async';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../models/preset_print_result.dart';
import '../../models/print_parameter.dart';
import '../../../core/services/preset_fingerprint_service.dart';

export '../models/preset_print_result.dart';

/// 参数效果闭环数据访问层。
///
/// 管理 preset_snapshots / preset_applications / preset_slice_artifacts /
/// preset_print_results 四张表，提供参数快照、应用账本、切片产物绑定和
/// 打印结果的完整 CRUD。
///
/// 核心规则：
/// - 相同 fingerprint schema + hash 复用同一快照行，快照创建后禁止覆盖。
/// - 同一个 print_task 最多生成一条结果主记录（task_id 唯一索引防重复结算）。
/// - 用户补充评分只能更新主观字段，不能改写自动采集的任务事实。
class PresetResultDao extends DatabaseAccessor<AppDatabase> {
  PresetResultDao(super.db);

  static const _uuid = Uuid();

  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  Stream<void> get onChange => _changeController.stream;

  void _emit() {
    if (!_changeController.isClosed) _changeController.add(null);
  }

  // ===== Preset Snapshots =====

  /// 创建或复用参数快照。
  ///
  /// 相同 fingerprint_schema_version + content_hash 复用同一快照行；
  /// 快照创建后禁止覆盖。返回快照 ID。
  Future<String> getOrCreateSnapshot(
    PrintParameterPreset preset, {
    String? presetJsonOverride,
  }) async {
    final fp = PresetFingerprintService.compute(preset);
    final now = DateTime.now().millisecondsSinceEpoch;
    final presetJson = presetJsonOverride ?? preset.toBbsparamJson();

    final id = _uuid.v4();
    await customStatement(
      'INSERT OR IGNORE INTO preset_snapshots(id, fingerprint_schema_version, content_hash, preset_json, created_at) VALUES (?, ?, ?, ?, ?)',
      [id, fp.schemaVersion, fp.contentHash, presetJson, now],
    );
    final stored = await customSelect(
      'SELECT id FROM preset_snapshots WHERE fingerprint_schema_version = ? AND content_hash = ?',
      variables: [Variable(fp.schemaVersion), Variable(fp.contentHash)],
    ).getSingle();
    _emit();
    return stored.read<String>('id');
  }

  /// 按 ID 查询快照。
  Future<Map<String, dynamic>?> getSnapshot(String id) async {
    final row = await customSelect(
      'SELECT * FROM preset_snapshots WHERE id = ?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    return row?.data;
  }

  // ===== Preset Applications =====

  /// 记录参数应用事件。
  ///
  /// 每次 _applyPreset 真正写入成功后调用。返回应用记录 ID。
  Future<String> recordApplication({
    required String snapshotId,
    required String displayName,
    String? localPresetId,
    String? communityPublicationId,
    String? communityVersionId,
    int? communityRevision,
    String? slicerProcessSettingsId,
    String? experimentId,
    String? experimentArm,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await customStatement(
      '''INSERT INTO preset_applications(
        id, snapshot_id, display_name, local_preset_id,
        community_publication_id, community_version_id, community_revision,
        slicer_process_settings_id, experiment_id, experiment_arm, applied_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        snapshotId,
        displayName,
        localPresetId,
        communityPublicationId,
        communityVersionId,
        communityRevision,
        slicerProcessSettingsId,
        experimentId,
        experimentArm,
        now,
      ],
    );
    _emit();
    return id;
  }

  /// 按本地预设 ID 查最近应用记录（候选归因用，不作为精确归因）。
  Future<Map<String, dynamic>?> getLatestApplicationByLocalPreset(
    String localPresetId,
  ) async {
    final row = await customSelect(
      'SELECT * FROM preset_applications WHERE local_preset_id = ? ORDER BY applied_at DESC LIMIT 1',
      variables: [Variable(localPresetId)],
    ).getSingleOrNull();
    return row?.data;
  }

  /// 按社区发布 ID 查应用记录。
  Future<List<Map<String, dynamic>>> getApplicationsByPublication(
    String publicationId,
  ) async {
    final rows = await customSelect(
      'SELECT * FROM preset_applications WHERE community_publication_id = ? ORDER BY applied_at DESC',
      variables: [Variable(publicationId)],
    ).get();
    return rows.map((r) => r.data).toList();
  }

  Future<List<Map<String, dynamic>>> getApplicationsBySlicerSettingsId(
    String settingsId,
  ) async {
    final rows = await customSelect(
      'SELECT * FROM preset_applications '
      'WHERE slicer_process_settings_id = ? ORDER BY applied_at DESC',
      variables: [Variable(settingsId)],
    ).get();
    return rows.map((row) => row.data).toList();
  }

  Future<Map<String, dynamic>?> getApplicationById(String id) async {
    final row = await customSelect(
      'SELECT * FROM preset_applications WHERE id = ?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    return row?.data;
  }

  // ===== Preset Slice Artifacts =====

  /// 绑定切片产物 hash 到应用记录。
  ///
  /// 哈希必须在文件写入完成后异步计算。重复绑定相同 hash 幂等。
  Future<void> bindSliceArtifact({
    required String applicationId,
    required String artifactSha256,
    required int artifactSize,
    int? artifactModifiedAt,
    String artifactKind = 'gcode',
    String localPath = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    await customStatement(
      '''INSERT OR IGNORE INTO preset_slice_artifacts(
        id, application_id, artifact_sha256, artifact_size,
        artifact_modified_at, artifact_kind, local_path, bound_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        applicationId,
        artifactSha256,
        artifactSize,
        artifactModifiedAt,
        artifactKind,
        localPath,
        now,
      ],
    );
    _emit();
  }

  /// 按产物 hash 查应用记录（精确归因核心方法）。
  Future<Map<String, dynamic>?> getApplicationByArtifactHash(
    String sha256Hash,
  ) async {
    final rows = await getApplicationsByArtifactHash(sha256Hash);
    return rows.length == 1 ? rows.single : null;
  }

  /// 返回产物 hash 的全部候选；只有一个候选时才可视为精确归因。
  Future<List<Map<String, dynamic>>> getApplicationsByArtifactHash(
    String sha256Hash,
  ) async {
    final rows = await customSelect(
      'SELECT a.* FROM preset_applications a '
      'JOIN preset_slice_artifacts s ON s.application_id = a.id '
      'WHERE s.artifact_sha256 = ? ORDER BY a.applied_at DESC',
      variables: [Variable(sha256Hash)],
    ).get();
    return rows.map((row) => row.data).toList();
  }

  // ===== Task Attribution Context =====

  Future<void> recordTaskAttribution({
    required int taskId,
    String? snapshotId,
    String? applicationId,
    String presetDisplayName = '',
    ResultAttribution attribution = ResultAttribution.unknown,
    String? communityPublicationId,
    String? communityVersionId,
    int? communityRevision,
    String? artifactSha256,
    String? printSettingsId,
    String? printerSettingsId,
    double? nozzleDiameter,
    String? plateType,
    String? materialProfile,
    String? materialType,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await customStatement(
      '''INSERT INTO preset_task_attributions(
        task_id, snapshot_id, application_id, preset_display_name, attribution,
        community_publication_id, community_version_id, community_revision,
        artifact_sha256, print_settings_id, printer_settings_id,
        nozzle_diameter, plate_type, material_profile, material_type, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(task_id) DO UPDATE SET
        snapshot_id = excluded.snapshot_id,
        application_id = excluded.application_id,
        preset_display_name = excluded.preset_display_name,
        attribution = excluded.attribution,
        community_publication_id = excluded.community_publication_id,
        community_version_id = excluded.community_version_id,
        community_revision = excluded.community_revision,
        artifact_sha256 = excluded.artifact_sha256,
        print_settings_id = excluded.print_settings_id,
        printer_settings_id = excluded.printer_settings_id,
        nozzle_diameter = excluded.nozzle_diameter,
        plate_type = excluded.plate_type,
        material_profile = excluded.material_profile,
        material_type = excluded.material_type''',
      [
        taskId,
        snapshotId,
        applicationId,
        presetDisplayName,
        attribution.value,
        communityPublicationId,
        communityVersionId,
        communityRevision,
        artifactSha256,
        printSettingsId,
        printerSettingsId,
        nozzleDiameter,
        plateType,
        materialProfile,
        materialType,
        now,
      ],
    );
    _emit();
  }

  Future<Map<String, dynamic>?> getTaskAttribution(int taskId) async {
    final row = await customSelect(
      'SELECT * FROM preset_task_attributions WHERE task_id = ?',
      variables: [Variable(taskId)],
    ).getSingleOrNull();
    return row?.data;
  }

  // ===== Preset Print Results =====

  /// 创建或更新打印结果（幂等）。
  ///
  /// 同一个 task_id 最多一条结果记录。重复 MQTT 消息不会重复创建。
  /// 返回结果 ID。
  Future<String> upsertResultForTask({
    required int taskId,
    required String taskUid,
    String? snapshotId,
    String? applicationId,
    String presetDisplayName = '',
    ResultAttribution attribution = ResultAttribution.unknown,
    String? communityPublicationId,
    String? communityVersionId,
    int? communityRevision,
    String printerModel = '',
    double? nozzleDiameter,
    String? plateType,
    String? materialProfile,
    String? materialType,
    String? materialBatchNo,
    double? amsHumidity,
    DateTime? amsHumiditySampledAt,
    TechnicalStatus technicalStatus = TechnicalStatus.finished,
    UserOutcome? userOutcome,
    String? failureCode,
    String? failureCategory,
    double estimatedGrams = 0,
    double actualGrams = 0,
    int estimatedSeconds = 0,
    int actualSeconds = 0,
    EvidenceLevel evidenceLevel = EvidenceLevel.deviceRecorded,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 先查是否已存在（按 task_id 幂等）
    final existing = await customSelect(
      'SELECT id, client_run_id FROM preset_print_results WHERE task_id = ?',
      variables: [Variable(taskId)],
    ).getSingleOrNull();

    if (existing != null) {
      // 已存在：只更新自动采集字段，不覆盖用户补充评价
      final id = existing.read<String>('id');
      await customStatement(
        '''UPDATE preset_print_results SET
          task_uid = ?, snapshot_id = ?, application_id = ?,
          preset_display_name = ?, attribution = ?,
          community_publication_id = ?, community_version_id = ?, community_revision = ?,
          printer_model = ?, nozzle_diameter = ?, plate_type = ?,
          material_profile = ?, material_type = ?, material_batch_no = ?,
          ams_humidity = ?, ams_humidity_sampled_at = ?,
          technical_status = ?, failure_code = ?, failure_category = ?,
          estimated_grams = ?, actual_grams = ?,
          estimated_seconds = ?, actual_seconds = ?,
          evidence_level = ?, updated_at = ?
        WHERE id = ?''',
        [
          taskUid,
          snapshotId,
          applicationId,
          presetDisplayName,
          attribution.value,
          communityPublicationId,
          communityVersionId,
          communityRevision,
          printerModel,
          nozzleDiameter,
          plateType,
          materialProfile,
          materialType,
          materialBatchNo,
          amsHumidity,
          amsHumiditySampledAt?.millisecondsSinceEpoch,
          technicalStatus.value,
          failureCode,
          failureCategory,
          estimatedGrams,
          actualGrams,
          estimatedSeconds,
          actualSeconds,
          evidenceLevel.value,
          now,
          id,
        ],
      );
      _emit();
      return id;
    }

    // 新建
    final id = _uuid.v4();
    final clientRunId = _uuid.v4();
    await customStatement(
      '''INSERT INTO preset_print_results(
        id, client_run_id, task_id, task_uid, snapshot_id, application_id,
        preset_display_name, attribution,
        community_publication_id, community_version_id, community_revision,
        printer_model, nozzle_diameter, plate_type,
        material_profile, material_type, material_batch_no,
        ams_humidity, ams_humidity_sampled_at,
        technical_status, user_outcome, failure_code, failure_category,
        estimated_grams, actual_grams, estimated_seconds, actual_seconds,
        rating, adhesion_ok, quality_score, user_note,
        evidence_level, share_consent, sync_status, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        clientRunId,
        taskId,
        taskUid,
        snapshotId,
        applicationId,
        presetDisplayName,
        attribution.value,
        communityPublicationId,
        communityVersionId,
        communityRevision,
        printerModel,
        nozzleDiameter,
        plateType,
        materialProfile,
        materialType,
        materialBatchNo,
        amsHumidity,
        amsHumiditySampledAt?.millisecondsSinceEpoch,
        technicalStatus.value,
        userOutcome?.value,
        failureCode,
        failureCategory,
        estimatedGrams,
        actualGrams,
        estimatedSeconds,
        actualSeconds,
        null,
        null,
        null,
        null,
        evidenceLevel.value,
        ShareConsent.notShared.value,
        ShareConsent.notShared.value,
        now,
        now,
      ],
    );
    _emit();
    return id;
  }

  /// 更新用户补充评价。
  ///
  /// 只能更新主观字段，不能改写自动采集的任务事实。
  Future<void> updateUserOutcome({
    required String resultId,
    UserOutcome? userOutcome,
    int? rating,
    bool? adhesionOk,
    int? qualityScore,
    String? userNote,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final sets = <String>[];
    final args = <dynamic>[];

    if (userOutcome != null) {
      sets.add('user_outcome = ?');
      args.add(userOutcome.value);
    }
    if (rating != null) {
      // 拒绝非法评分（0、6、NaN 等）
      if (rating < 1 || rating > 5) {
        throw ArgumentError('评分必须在 1-5 之间，收到 $rating');
      }
      sets.add('rating = ?');
      args.add(rating);
    }
    if (adhesionOk != null) {
      sets.add('adhesion_ok = ?');
      args.add(adhesionOk ? 1 : 0);
    }
    if (qualityScore != null) {
      if (qualityScore < 1 || qualityScore > 5) {
        throw ArgumentError('质量评分必须在 1-5 之间，收到 $qualityScore');
      }
      sets.add('quality_score = ?');
      args.add(qualityScore);
    }
    if (userNote != null) {
      sets.add('user_note = ?');
      args.add(userNote);
    }
    if (sets.isEmpty) return;

    sets.add('updated_at = ?');
    args.add(now);
    args.add(resultId);

    await customStatement(
      'UPDATE preset_print_results SET ${sets.join(', ')} WHERE id = ?',
      args,
    );
    _emit();
  }

  /// 按 task_id 查打印结果。
  Future<PresetPrintResult?> getByTaskId(int taskId) async {
    final row = await customSelect(
      'SELECT * FROM preset_print_results WHERE task_id = ?',
      variables: [Variable(taskId)],
    ).getSingleOrNull();
    if (row == null) return null;
    return PresetPrintResult.fromRow(row.data);
  }

  /// 按快照 ID 查所有结果（参数表现汇总用）。
  Future<List<PresetPrintResult>> getBySnapshot(String snapshotId) async {
    final rows = await customSelect(
      'SELECT * FROM preset_print_results WHERE snapshot_id = ? ORDER BY created_at DESC',
      variables: [Variable(snapshotId)],
    ).get();
    return rows.map((r) => PresetPrintResult.fromRow(r.data)).toList();
  }

  /// 按社区发布 ID 查所有结果（社区汇总用）。
  Future<List<PresetPrintResult>> getByPublication(String publicationId) async {
    final rows = await customSelect(
      'SELECT * FROM preset_print_results WHERE community_publication_id = ? ORDER BY created_at DESC',
      variables: [Variable(publicationId)],
    ).get();
    return rows.map((r) => PresetPrintResult.fromRow(r.data)).toList();
  }

  /// 查询待分享的结果（用户开启分享后上传队列用）。
  Future<List<PresetPrintResult>> getPendingShare() async {
    final rows = await customSelect(
      "SELECT * FROM preset_print_results WHERE sync_status IN ('pending', 'failed') ORDER BY created_at ASC",
    ).get();
    return rows.map((r) => PresetPrintResult.fromRow(r.data)).toList();
  }

  /// 更新分享状态。
  Future<void> updateSyncStatus(String resultId, ShareConsent status) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await customStatement(
      'UPDATE preset_print_results SET sync_status = ?, updated_at = ? WHERE id = ?',
      [status.value, now, resultId],
    );
    _emit();
  }

  /// 按结果 ID 查询单条打印结果。
  Future<PresetPrintResult?> getById(String id) async {
    final row = await customSelect(
      'SELECT * FROM preset_print_results WHERE id = ?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    if (row == null) return null;
    return PresetPrintResult.fromRow(row.data);
  }

  /// 更新分享同意状态（可同时更新 sync_status 和服务端结果修订号）。
  ///
  /// [consent] 更新 share_consent 字段；
  /// [syncStatus] 可选，同时更新 sync_status 字段；
  /// [communityResultRevision] 可选，同时更新上传结果的乐观锁修订号。
  Future<void> updateShareConsent(
    String resultId,
    ShareConsent consent, {
    ShareConsent? syncStatus,
    int? communityResultRevision,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final sets = <String>['share_consent = ?'];
    final args = <dynamic>[consent.value];
    if (syncStatus != null) {
      sets.add('sync_status = ?');
      args.add(syncStatus.value);
    }
    if (communityResultRevision != null) {
      sets.add('community_result_revision = ?');
      args.add(communityResultRevision);
    }
    sets.add('updated_at = ?');
    args.add(now);
    args.add(resultId);
    await customStatement(
      'UPDATE preset_print_results SET ${sets.join(', ')} WHERE id = ?',
      args,
    );
    _emit();
  }

  /// 查询待同步的分享或待重试的撤回。
  Future<List<PresetPrintResult>> queryPendingConsent() async {
    final rows = await customSelect(
      "SELECT * FROM preset_print_results "
      "WHERE share_consent IN ('pending', 'revoke_pending') "
      'ORDER BY created_at ASC',
    ).get();
    return rows.map((r) => PresetPrintResult.fromRow(r.data)).toList();
  }

  void dispose() {
    _changeController.close();
  }
}
