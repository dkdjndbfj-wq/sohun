import 'dart:async';
import 'dart:convert';

import 'package:consumable_tracker_desktop/core/app_version.dart';
import 'package:consumable_tracker_desktop/core/services/remote_config_service.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTelemetryApi implements CommunityTelemetryApi {
  final List<Object> responses = [];
  final List<String?> requestedEtags = [];
  final List<String> requestedPlatforms = [];
  final List<String> requestedVersions = [];

  @override
  Future<CommunityRemoteConfig> fetchRemoteConfig({
    required String appVersion,
    required String platform,
    String? ifNoneMatch,
  }) async {
    requestedEtags.add(ifNoneMatch);
    requestedPlatforms.add(platform);
    requestedVersions.add(appVersion);
    final response = responses.removeAt(0);
    if (response is Future<CommunityRemoteConfig>) return await response;
    if (response is CommunityRemoteConfig) return response;
    throw response;
  }

  @override
  Future<CommunityTelemetryBatchResult> submitTelemetryBatch({
    required String installIdHash,
    required List<Map<String, dynamic>> events,
  }) {
    throw UnimplementedError();
  }
}

CommunityRemoteConfig _config({
  Map<String, dynamic> flags = const {},
  int schemaVersion = 1,
  String? etag = '"config-v1"',
}) {
  return CommunityRemoteConfig(
    flags: flags,
    schemaVersion: schemaVersion,
    generatedAt: DateTime.now().toUtc(),
    source: 'community_server',
    etag: etag,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('空 flags 是有效快照，持久化 ETag/source/time 并通知 Riverpod 监听者', () async {
    final api = _FakeTelemetryApi()..responses.add(_config());
    final service = RemoteConfigService.forTesting(api);
    await service.initialized;
    final container = ProviderContainer(
      overrides: [remoteConfigServiceProvider.overrideWith((ref) => service)],
    );
    final states = <RemoteConfigState>[];
    final subscription = container.listen(
      remoteConfigServiceProvider,
      (_, next) => states.add(next),
      fireImmediately: true,
    );

    await container.read(remoteConfigServiceProvider.notifier).fetchAndUpdate();

    final state = container.read(remoteConfigServiceProvider);
    expect(state.flags, isEmpty);
    expect(state.source, 'community_server');
    expect(state.updatedAtMillis, greaterThan(0));
    expect(state.etag, '"config-v1"');
    expect(states.last.source, 'community_server');
    expect(states, hasLength(greaterThanOrEqualTo(2)));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('remote_config_cache'), '{}');
    expect(prefs.getString('remote_config_source'), 'community_server');
    expect(prefs.getString('remote_config_etag'), '"config-v1"');
    expect(prefs.getInt('remote_config_updated_at'), greaterThan(0));

    subscription.close();
    container.dispose();
  });

  test('ETag 会用于条件请求，304 只刷新时间且保留现有 flags', () async {
    SharedPreferences.setMockInitialValues({
      'remote_config_cache': '{"community_feed_enhanced":false}',
      'remote_config_source': 'community_server',
      'remote_config_etag': '"cached-v1"',
      'remote_config_updated_at': 1,
    });
    final api = _FakeTelemetryApi()
      ..responses.add(
        const CommunityApiException(
          'not modified',
          category: CommunityApiErrorCategory.protocol,
          statusCode: 304,
          code: 'not_modified',
        ),
      );
    final service = RemoteConfigService.forTesting(api);
    await service.initialized;

    await service.fetchAndUpdate();

    expect(api.requestedEtags, ['"cached-v1"']);
    expect(service.getFlag('community_feed_enhanced'), isFalse);
    expect(service.getConfigSource(), 'community_server');
    expect(service.getLastUpdated(), greaterThan(1));
    expect(service.getETag(), '"cached-v1"');
    service.dispose();
  });

  test('非法 schema 或已知 flag 类型不覆盖 last-known-good', () async {
    SharedPreferences.setMockInitialValues({
      'remote_config_cache': '{"community_feed_enhanced":false}',
      'remote_config_source': 'cached',
      'remote_config_etag': '"known-good"',
      'remote_config_updated_at': 123,
    });
    final api = _FakeTelemetryApi()
      ..responses.add(_config(schemaVersion: 0, etag: '"bad-schema"'))
      ..responses.add(
        _config(
          flags: {'community_feed_enhanced': 'not-a-bool'},
          etag: '"bad-type"',
        ),
      );
    final service = RemoteConfigService.forTesting(api);
    await service.initialized;

    await service.fetchAndUpdate();
    await service.fetchAndUpdate();

    expect(service.getFlag('community_feed_enhanced'), isFalse);
    expect(service.getConfigSource(), 'cached');
    expect(service.getLastUpdated(), 123);
    expect(service.getETag(), '"known-good"');
    service.dispose();
  });

  test('CommunityRemoteConfig 拒绝非 object 的 flags 字段', () {
    expect(
      () => CommunityRemoteConfig.fromJson({
        'flags': 'invalid',
        'schemaVersion': 1,
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'source': 'community_server',
      }),
      throwsFormatException,
    );
  });

  test('同时触发启动和手动刷新时共用同一请求', () async {
    final pending = Completer<CommunityRemoteConfig>();
    final api = _FakeTelemetryApi()..responses.add(pending.future);
    final service = RemoteConfigService.forTesting(api);
    addTearDown(service.dispose);
    await service.initialized;
    final first = service.fetchAndUpdate();
    final second = service.fetchAndUpdate();
    pending.complete(_config(flags: {'community_feed_enhanced': false}));
    await Future.wait([first, second]);
    expect(api.requestedEtags, hasLength(1));
    expect(service.getFlag('community_feed_enhanced'), isFalse);
  });

  test('已销毁服务的迟到响应不污染下一实例的持久化配置', () async {
    final pending = Completer<CommunityRemoteConfig>();
    final api = _FakeTelemetryApi()..responses.add(pending.future);
    final service = RemoteConfigService.forTesting(api);
    await service.initialized;
    final running = service.fetchAndUpdate();
    await Future<void>.delayed(Duration.zero);
    service.dispose();
    pending.complete(_config(flags: {'desktop_latest_version': 'v9.0.0'}));
    await running;
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('remote_config_cache'), isNull);
    expect(prefs.getString('remote_config_etag'), isNull);
  });

  test('Android查询带上平台与构建号，接受独立强制更新字段', () async {
    final api = _FakeTelemetryApi()
      ..responses.add(
        _config(
          flags: {
            'android_latest_version': 'v1.1.0+2',
            'android_min_supported_version': 'v1.0.0+2',
            'android_force_update': true,
            'android_download_url': 'https://downloads.example.com/sohun.apk',
          },
        ),
      );
    final service = RemoteConfigService.forTesting(api, platform: 'android');
    addTearDown(service.dispose);
    await service.fetchAndUpdate();
    expect(api.requestedPlatforms, ['android']);
    expect(api.requestedVersions, [AppVersion.fullVersion]);
    expect(service.state.flags['android_force_update'], isTrue);
    expect(service.state.flags['android_min_supported_version'], 'v1.0.0+2');
    expect(service.state.flags.containsKey('desktop_download_url'), isFalse);
  });

  test('损坏或回退的更新策略不清除强制缓存和其他已知flags', () async {
    const known = {
      'desktop_latest_version': 'v2.0.0',
      'desktop_force_update': true,
      'desktop_min_supported_version': 'v1.1.0',
      'desktop_download_url': 'https://downloads.example.com/sohun.exe',
      'community_feed_enhanced': false,
    };
    final api = _FakeTelemetryApi()..responses.add(_config(flags: known));
    final service = RemoteConfigService.forTesting(api);
    addTearDown(service.dispose);
    await service.fetchAndUpdate();
    for (final flags in <Map<String, dynamic>>[
      {},
      {
        'desktop_latest_version': 'v1.0.0',
        'desktop_force_update': false,
        'desktop_min_supported_version': '',
      },
      {'desktop_latest_version': 'v2.0.0', 'desktop_force_update': false},
      {'desktop_latest_version': 'v2.0.0', 'desktop_force_update': 'true'},
      {
        'desktop_latest_version': 'v2.0.0',
        'desktop_min_supported_version': 'not-a-version',
      },
      {
        'desktop_latest_version': 'v2.0.0',
        'desktop_min_supported_version': 'v2.0.0+1',
      },
    ]) {
      api.responses.add(_config(flags: flags, etag: '"broken"'));
      await service.fetchAndUpdate();
      expect(service.state.flags, known);
      expect(service.state.fetchError, 'invalid_config');
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('remote_config_cache')!), known);
    }
  });

  test('同级完整策略可撤回强制要求并保留新版其他flags', () async {
    final api = _FakeTelemetryApi()
      ..responses.add(
        _config(
          flags: {
            'desktop_latest_version': 'v2.0.0',
            'desktop_force_update': true,
          },
        ),
      )
      ..responses.add(
        _config(
          flags: {
            'desktop_latest_version': 'v2.0.0',
            'desktop_force_update': false,
            'desktop_min_supported_version': '',
            'community_feed_enhanced': false,
          },
        ),
      );
    final service = RemoteConfigService.forTesting(api);
    addTearDown(service.dispose);
    await service.fetchAndUpdate();
    await service.fetchAndUpdate();
    expect(service.state.fetchError, isNull);
    expect(service.state.flags['desktop_force_update'], isFalse);
    expect(service.state.flags['community_feed_enhanced'], isFalse);
  });

  test('失败会通知观察者但不修改缓存，随后304恢复可用状态', () async {
    final api = _FakeTelemetryApi()
      ..responses.add(_config(flags: {'desktop_latest_version': 'v2.0.0'}))
      ..responses.add(StateError('offline'))
      ..responses.add(
        const CommunityApiException(
          'not modified',
          category: CommunityApiErrorCategory.protocol,
          statusCode: 304,
          code: 'not_modified',
        ),
      );
    final service = RemoteConfigService.forTesting(api);
    addTearDown(service.dispose);
    await service.fetchAndUpdate();
    final states = <RemoteConfigState>[];
    final removeListener = service.addListener(
      states.add,
      fireImmediately: false,
    );
    addTearDown(removeListener);
    await service.fetchAndUpdate();
    expect(states.last.fetchError, 'unavailable');
    expect(service.state.flags['desktop_latest_version'], 'v2.0.0');
    await service.fetchAndUpdate();
    expect(states.last.fetchError, isNull);
    expect(service.state.flags['desktop_latest_version'], 'v2.0.0');
  });

  test('同一规范版本丢失安全URL时持久化保留旧入口且继续更新其他flags', () async {
    const safeUrl = 'https://downloads.example.com/sohun.exe';
    final api = _FakeTelemetryApi()
      ..responses.add(
        _config(
          flags: {
            'desktop_latest_version': 'v2.0.0+1',
            'desktop_force_update': true,
            'desktop_download_url': safeUrl,
            'community_feed_enhanced': true,
          },
        ),
      );
    final service = RemoteConfigService.forTesting(api);
    addTearDown(service.dispose);
    await service.fetchAndUpdate();
    for (final damagedUrl in <String?>[
      null,
      '',
      '  ',
      'http://downloads.example.com/sohun.exe',
      'https://user:secret@downloads.example.com/sohun.exe',
      'file:///C:/sohun.exe',
    ]) {
      api.responses.add(
        _config(
          flags: {
            'desktop_latest_version': '2.0.0+1',
            'desktop_force_update': true,
            if (damagedUrl != null) 'desktop_download_url': damagedUrl,
            'community_feed_enhanced': false,
          },
        ),
      );
      await service.fetchAndUpdate();
      expect(service.state.fetchError, isNull);
      expect(service.state.flags['desktop_download_url'], safeUrl);
      expect(service.state.flags['community_feed_enhanced'], isFalse);
      final restored = RemoteConfigService.forTesting(null);
      await restored.ready;
      expect(restored.state.flags['desktop_download_url'], safeUrl);
      expect(restored.state.flags['desktop_force_update'], isTrue);
      restored.dispose();
    }
  });

  test('Android新构建不能借用旧包，完整撤回策略仍可与同版URL合并', () async {
    const safeUrl = 'https://downloads.example.com/sohun.apk';
    final api = _FakeTelemetryApi()
      ..responses.add(
        _config(
          flags: {
            'android_latest_version': 'v2.0.0+1',
            'android_force_update': true,
            'android_min_supported_version': 'v1.1.0',
            'android_download_url': safeUrl,
          },
        ),
      )
      ..responses.add(
        _config(
          flags: {
            'android_latest_version': '2.0.0+1',
            'android_force_update': false,
            'android_min_supported_version': '',
            'android_download_url': '',
            'community_feed_enhanced': false,
          },
        ),
      )
      ..responses.add(
        _config(
          flags: {
            'android_latest_version': 'v2.0.0+2',
            'android_force_update': true,
            'android_download_url': '',
          },
        ),
      );
    final service = RemoteConfigService.forTesting(api, platform: 'android');
    addTearDown(service.dispose);
    await service.fetchAndUpdate();
    await service.fetchAndUpdate();
    expect(service.state.fetchError, isNull);
    expect(service.state.flags['android_force_update'], isFalse);
    expect(service.state.flags['android_min_supported_version'], '');
    expect(service.state.flags['android_download_url'], safeUrl);
    expect(service.state.flags['community_feed_enhanced'], isFalse);
    await service.fetchAndUpdate();
    expect(service.state.flags['android_latest_version'], 'v2.0.0+2');
    expect(service.state.flags['android_download_url'], '');
    final restored = RemoteConfigService.forTesting(null, platform: 'android');
    await restored.ready;
    expect(restored.state.flags['android_download_url'], '');
    restored.dispose();
  });
}
