import 'package:consumable_tracker_desktop/core/services/community_share_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/preset_result_dao.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/print_parameter.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late PresetResultDao dao;
  late _FakeCommunityTrustApi api;
  late CommunityShareService service;
  var automaticSharingEnabled = true;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = PresetResultDao(db);
    api = _FakeCommunityTrustApi();
    service = CommunityShareService(
      apiClient: api,
      resultDao: dao,
      accessTokenProvider: () async => 'test-access-token',
      isShareEnabled: () => automaticSharingEnabled,
    );
  });

  tearDown(() async {
    service.dispose();
    dao.dispose();
    await db.close();
  });

  test('分享使用服务端版本指纹，且不污染参数 revision', () async {
    const versionHash =
        '5df269c466451776bd26542535612d40cbbc76dc08fe453f9ec9e2bb15530edd';
    final preset = _preset();
    final snapshotId = await dao.getOrCreateSnapshot(preset);
    final applicationId = await dao.recordApplication(
      snapshotId: snapshotId,
      displayName: preset.name,
      communityPublicationId: 'publication-1',
      communityVersionId: versionHash,
      communityRevision: 7,
    );
    final resultId = await dao.upsertResultForTask(
      taskId: 101,
      taskUid: 'task-101',
      snapshotId: snapshotId,
      applicationId: applicationId,
      presetDisplayName: preset.name,
      attribution: ResultAttribution.exact,
      communityPublicationId: 'publication-1',
      communityVersionId: versionHash,
      communityRevision: 7,
      printerModel: 'P1S',
      nozzleDiameter: 0.4,
      materialProfile: 'Bambu PLA Basic',
      amsHumidity: 2.5,
      technicalStatus: TechnicalStatus.finished,
      estimatedGrams: 40,
      actualGrams: 41,
      estimatedSeconds: 3600,
      actualSeconds: 3700,
    );
    await dao.updateShareConsent(
      resultId,
      ShareConsent.pending,
      syncStatus: ShareConsent.pending,
    );

    await service.syncPendingShares();

    expect(api.submittedPublicationId, 'publication-1');
    expect(api.submittedPayload?['publicationRevision'], 7);
    expect(api.submittedPayload?['presetFingerprint'], versionHash);
    expect(api.submittedPayload?['humidityBucket'], 'medium');
    expect(api.submittedPayload?.containsKey('serialNumber'), isFalse);
    expect(api.submittedPayload?.containsKey('userNote'), isFalse);

    var stored = await dao.getById(resultId);
    expect(stored?.communityRevision, 7);
    expect(stored?.communityResultRevision, 4);
    expect(stored?.syncStatus, ShareConsent.synced);

    await dao.updateUserOutcome(
      resultId: resultId,
      userOutcome: UserOutcome.usable,
      rating: 4,
    );
    await service.syncUserOutcomeUpdate(resultId);

    expect(api.patchExpectedRevision, 4);
    expect(api.patchPayload, {'userOutcome': 'usable', 'rating': 4});
    stored = await dao.getById(resultId);
    expect(stored?.communityRevision, 7);
    expect(stored?.communityResultRevision, 5);
  });

  test('断网撤回保留意图，关闭自动分享后仍会重试撤回', () async {
    final resultId = await _createSyncedResult(dao);
    api.failNextDelete = true;

    await service.revokeShare(resultId);

    var stored = await dao.getById(resultId);
    expect(stored?.shareConsent, ShareConsent.revokePending);
    expect(stored?.syncStatus, ShareConsent.failed);

    automaticSharingEnabled = false;
    await service.syncPendingShares();

    stored = await dao.getById(resultId);
    expect(api.deleteCalls, 2);
    expect(stored?.shareConsent, ShareConsent.notShared);
    expect(stored?.syncStatus, ShareConsent.revoked);
  });
}

PrintParameterPreset _preset() {
  final now = DateTime.utc(2026, 7, 28);
  return PrintParameterPreset(
    id: 'community-source',
    name: '社区参数',
    material: 'Bambu PLA Basic',
    compatiblePrinters: const ['P1S'],
    createdAt: now,
    updatedAt: now,
    quality: const PrintQualityParams(layerHeight: '0.20'),
    strength: const PrintStrengthParams(),
    speed: const PrintSpeedParams(),
    support: const PrintSupportParams(),
    other: const PrintOtherParams(),
  );
}

Future<String> _createSyncedResult(PresetResultDao dao) async {
  final preset = _preset();
  final snapshotId = await dao.getOrCreateSnapshot(preset);
  final resultId = await dao.upsertResultForTask(
    taskId: 202,
    taskUid: 'task-202',
    snapshotId: snapshotId,
    communityPublicationId: 'publication-2',
    communityVersionId:
        '5df269c466451776bd26542535612d40cbbc76dc08fe453f9ec9e2bb15530edd',
    communityRevision: 2,
  );
  await dao.updateShareConsent(
    resultId,
    ShareConsent.synced,
    syncStatus: ShareConsent.synced,
    communityResultRevision: 3,
  );
  return resultId;
}

class _FakeCommunityTrustApi implements CommunityTrustApi {
  Map<String, dynamic>? submittedPayload;
  String? submittedPublicationId;
  Map<String, dynamic>? patchPayload;
  int? patchExpectedRevision;
  bool failNextDelete = false;
  int deleteCalls = 0;

  @override
  Future<CommunityPrintResultSubmission> submitPrintResult({
    required String accessToken,
    required String publicationId,
    required Map<String, dynamic> payload,
  }) async {
    submittedPublicationId = publicationId;
    submittedPayload = Map<String, dynamic>.from(payload);
    return CommunityPrintResultSubmission(
      id: 'server-result-1',
      clientResultId: payload['clientResultId'] as String,
      revision: 4,
      idempotent: false,
      receivedAt: DateTime.utc(2026, 7, 28),
    );
  }

  @override
  Future<CommunityPrintResultSubmission> patchPrintResult({
    required String accessToken,
    required String publicationId,
    required String clientResultId,
    required int expectedRevision,
    required Map<String, dynamic> payload,
  }) async {
    patchExpectedRevision = expectedRevision;
    patchPayload = Map<String, dynamic>.from(payload);
    return CommunityPrintResultSubmission(
      id: 'server-result-1',
      clientResultId: clientResultId,
      revision: 5,
      idempotent: false,
      receivedAt: DateTime.utc(2026, 7, 28),
    );
  }

  @override
  Future<void> deletePrintResult({
    required String accessToken,
    required String publicationId,
    required String clientResultId,
  }) async {
    deleteCalls++;
    if (failNextDelete) {
      failNextDelete = false;
      throw const CommunityApiException(
        '断网',
        category: CommunityApiErrorCategory.network,
      );
    }
  }

  @override
  Future<CommunityTrustSummary> fetchTrustSummary({
    required String publicationId,
    String? accessToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> putApplication({
    required String accessToken,
    required String publicationId,
    required String clientApplicationId,
  }) =>
      throw UnimplementedError();

  @override
  Future<CommunityReportSubmission> reportPreset({
    required String accessToken,
    required String publicationId,
    required String reason,
    String? note,
  }) =>
      throw UnimplementedError();

  @override
  Future<CommunityAuthorReputation> fetchAuthorReputation({
    required String handle,
  }) =>
      throw UnimplementedError();
}
