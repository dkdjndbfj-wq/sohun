import 'dart:convert';

import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/community_preset.dart';
import 'package:consumable_tracker_desktop/data/models/print_parameter.dart';
import 'package:consumable_tracker_desktop/providers/parameter_preset_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('社区发布 ID 与拓竹 shareId 严格隔离', () {
    final source = _preset().copyWith(
      shareId: 'bambu-setting-id',
      communityPublicationId: 'stale-community-id',
      communityOwnerId: 'stale-owner',
      communityRevision: 99,
    );
    final publication = CommunityPreset.fromJson(
      _publicationJson(source: source),
    );

    expect(publication.publicationId, 'publication-1');
    expect(publication.owner.handle, 'maker-one');
    expect(publication.preset.id, 'community_publication-1');
    expect(publication.preset.author, 'Maker One');
    expect(publication.preset.shareId, isNull);
    expect(publication.preset.communityPublicationId, isNull);
    expect(publication.preset.communityOwnerId, isNull);
    expect(publication.preset.communityRevision, isNull);
  });

  test('旧服务端缺少作者 ID 和新版可信字段时仍可解析', () {
    final legacyJson = _publicationJson();
    final owner = legacyJson['owner'] as Map<String, dynamic>;
    owner.remove('id');
    legacyJson
      ..remove('trust')
      ..remove('versionId')
      ..remove('contentHash')
      ..remove('applicationCount')
      ..remove('ownedByMe');

    final publication = CommunityPreset.fromJson(legacyJson);

    expect(publication.owner.id, isNull);
    expect(publication.versionId, isNull);
    expect(publication.contentHash, isNull);
    expect(publication.applicationCount, 0);
    expect(publication.ownedByMe, isFalse);
    expect(publication.moderationStatus, 'published');
  });

  test('新服务端响应解析版本事实、应用数和所有权', () {
    final currentJson = _publicationJson()
      ..addAll({
        'versionId': 'version-sha256-1',
        'contentHash': 'content-sha256-1',
        'applicationCount': 27,
        'ownedByMe': true,
        'moderationStatus': 'published',
      });

    final publication = CommunityPreset.fromJson(currentJson);

    expect(publication.versionId, 'version-sha256-1');
    expect(publication.contentHash, 'content-sha256-1');
    expect(publication.applicationCount, 27);
    expect(publication.ownedByMe, isTrue);
    expect(publication.moderationStatus, 'published');
  });

  test('社区参数客户端把关键词和筛选条件发给服务器', () async {
    late http.Request captured;
    final client = CommunityApiClient(
      baseUri: Uri.parse('https://share.example.com'),
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'items': [_publicationJson()],
            'nextCursor': 'next-page',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final page = await client.listPresets(
      query: 'Maker One',
      material: 'Bambu PLA Silk',
      scene: '手办',
      printer: 'Bambu Lab P1S',
      sort: 'newest',
      limit: 24,
      accessToken: 'access-token',
    );

    expect(captured.url.path, '/v1/presets');
    expect(captured.url.queryParameters['q'], 'Maker One');
    expect(captured.url.queryParameters['material'], 'Bambu PLA Silk');
    expect(captured.url.queryParameters['scene'], '手办');
    expect(captured.url.queryParameters['printer'], 'Bambu Lab P1S');
    expect(captured.url.queryParameters['sort'], 'newest');
    expect(captured.headers['Authorization'], 'Bearer access-token');
    expect(page.items.single.owner.displayName, 'Maker One');
    expect(page.nextCursor, 'next-page');
  });

  test('更新社区参数提交 revision，避免覆盖其他设备的新版本', () async {
    late http.Request captured;
    final client = CommunityApiClient(
      baseUri: Uri.parse('https://share.example.com'),
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(_publicationJson(revision: 4)),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await client.updatePublishedPreset(
      accessToken: 'access-token',
      publicationId: 'publication-1',
      revision: 3,
      preset: _preset(),
    );

    expect(captured.method, 'PATCH');
    expect(captured.url.path, '/v1/presets/publication-1');
    expect(jsonDecode(captured.body)['revision'], 3);
    expect(result.revision, 4);
  });

  test('社区元数据可随本地草稿持久化，但不占用 shareId', () {
    final source = _preset().copyWith(
      shareId: 'bambu-setting-id',
      communityPublicationId: 'community-id',
      communityOwnerId: 'owner-id',
      communityRevision: 7,
      communityVisibility: 'unlisted',
    );
    final restored = PrintParameterPreset.fromBbsparamJson(
      source.toBbsparamJson(),
    );

    expect(restored.shareId, 'bambu-setting-id');
    expect(restored.communityPublicationId, 'community-id');
    expect(restored.communityOwnerId, 'owner-id');
    expect(restored.communityRevision, 7);
    expect(restored.communityVisibility, 'unlisted');
  });

  test('删除社区发布时只解除本地草稿的社区关联', () {
    final uploadedAt = DateTime.utc(2026, 7, 27, 12);
    final source = _preset().copyWith(
      shareId: 'bambu-setting-id',
      uploadedAt: uploadedAt,
      serverVersion: '2.6.0.2',
      communityPublicationId: 'community-id',
      communityOwnerId: 'owner-id',
      communityRevision: 7,
      communityVisibility: 'public',
    );

    final detached = source.withoutCommunityPublication();

    expect(detached.id, source.id);
    expect(detached.name, source.name);
    expect(detached.quality, same(source.quality));
    expect(detached.shareId, 'bambu-setting-id');
    expect(detached.uploadedAt, uploadedAt);
    expect(detached.serverVersion, '2.6.0.2');
    expect(detached.communityPublicationId, isNull);
    expect(detached.communityOwnerId, isNull);
    expect(detached.communityRevision, isNull);
    expect(detached.communityVisibility, isNull);
  });

  test('删除社区发布后按发布 ID 清理持久化草稿并保留其他草稿', () async {
    final target = _preset().copyWith(
      shareId: 'bambu-setting-id',
      communityPublicationId: 'publication-to-delete',
      communityOwnerId: 'owner-id',
      communityRevision: 7,
      communityVisibility: 'public',
    );
    final unrelated = _preset().copyWith(
      id: 'other-draft',
      communityPublicationId: 'other-publication',
      communityOwnerId: 'other-owner',
      communityRevision: 2,
      communityVisibility: 'unlisted',
    );
    SharedPreferences.setMockInitialValues({
      'parameter_presets_user': jsonEncode([
        target.toBbsparamMap(),
        unrelated.toBbsparamMap(),
      ]),
    });
    final notifier = ParameterPresetNotifier();
    addTearDown(notifier.dispose);
    await notifier.reload();

    await notifier.clearCommunityPublication('publication-to-delete');

    final retainedTarget = notifier.findById(target.id);
    final retainedUnrelated = notifier.findById(unrelated.id);
    expect(retainedTarget, isNotNull);
    expect(retainedTarget!.shareId, 'bambu-setting-id');
    expect(retainedTarget.communityPublicationId, isNull);
    expect(retainedTarget.communityOwnerId, isNull);
    expect(retainedTarget.communityRevision, isNull);
    expect(retainedTarget.communityVisibility, isNull);
    expect(retainedUnrelated, isNotNull);
    expect(retainedUnrelated!.communityPublicationId, 'other-publication');
    expect(retainedUnrelated.communityOwnerId, 'other-owner');
    expect(retainedUnrelated.communityRevision, 2);
    expect(retainedUnrelated.communityVisibility, 'unlisted');
  });
}

PrintParameterPreset _preset() {
  final now = DateTime.utc(2026, 7, 27);
  return PrintParameterPreset(
    id: 'user-preset',
    name: 'PLA Silk 手办参数',
    description: '亮面外观',
    author: '可编辑本地作者',
    material: 'Bambu PLA Silk',
    scene: '手办',
    compatiblePrinters: const ['Bambu Lab P1S 0.4 nozzle'],
    createdAt: now,
    updatedAt: now,
    quality: const PrintQualityParams(layerHeight: '0.12'),
    strength: const PrintStrengthParams(),
    speed: const PrintSpeedParams(),
    support: const PrintSupportParams(),
    other: const PrintOtherParams(),
  );
}

Map<String, dynamic> _publicationJson({
  PrintParameterPreset? source,
  int revision = 3,
}) {
  return {
    'id': 'publication-1',
    'owner': {
      'id': 'owner-1',
      'handle': 'maker-one',
      'displayName': 'Maker One',
      'avatarUrl': null,
    },
    'preset': (source ?? _preset()).toBbsparamMap(),
    'visibility': 'public',
    'revision': revision,
    'likes': 12,
    'downloads': 34,
    'likedByMe': true,
    'publishedAt': '2026-07-27T10:00:00Z',
    'updatedAt': '2026-07-27T11:00:00Z',
  };
}
