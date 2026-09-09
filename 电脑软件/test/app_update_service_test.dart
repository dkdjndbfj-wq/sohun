import 'dart:async';
import 'dart:convert';

import 'package:consumable_tracker_desktop/core/app_version.dart';
import 'package:consumable_tracker_desktop/core/services/app_update_service.dart';
import 'package:consumable_tracker_desktop/core/services/remote_config_service.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('版本比较兼容 v 前缀、构建号和缺失段', () {
    expect(compareAppVersions('v1.2.0', '1.1.9+12'), greaterThan(0));
    expect(compareAppVersions('1.0', 'v1.0.0'), 0);
    expect(compareAppVersions('1.0.0', '1.0.1'), lessThan(0));
    expect(compareAppVersions('1.0.0+12', 'v1.0.0+2'), greaterThan(0));
    expect(compareAppVersions('1.0.0+1', '1.0.0'), greaterThan(0));
    expect(compareAppVersions('1.0.0+2', 'v1.0.0+2'), 0);
  });

  test('远程配置发布新版本时返回可更新状态和安全下载地址', () async {
    final remote = RemoteConfigService.forTesting(
      _UpdateConfigApi({
        'desktop_latest_version': 'v1.2.0',
        'desktop_download_url':
            'https://github.com/example/sohun-client/releases/download/v1.2.0/sohun-setup-1.2.0-windows-x64.exe',
        'desktop_release_notes': '更顺畅的设置中心',
      }),
    );
    await remote.initialized;
    final service = AppUpdateService(remote);

    final result = await service.checkForUpdates();

    expect(result.phase, AppUpdatePhase.available);
    expect(result.latestVersion, 'v1.2.0');
    expect(result.downloadUri?.host, 'github.com');
    expect(result.releaseNotes, '更顺畅的设置中心');
  });

  test('不安全的更新链接不会进入可打开状态', () async {
    final remote = RemoteConfigService.forTesting(
      _UpdateConfigApi({
        'desktop_latest_version': 'v9.0.0',
        'desktop_download_url': 'http://download.example.com/sohun',
      }),
    );
    await remote.initialized;
    final service = AppUpdateService(remote);

    final result = await service.checkForUpdates();

    expect(result.phase, AppUpdatePhase.available);
    expect(result.downloadUri, isNull);
  });

  test('没有可验证的远程版本信息时不会假装已是最新版本', () async {
    final remote = RemoteConfigService.forTesting(null);
    await remote.initialized;
    final service = AppUpdateService(remote);

    final result = await service.checkForUpdates();

    expect(result.phase, AppUpdatePhase.failed);
    expect(result.message, contains('更新服务'));
  });

  test('旧服务器只返回空功能开关或无效版本时不能报告已是最新版', () async {
    for (final flags in <Map<String, dynamic>>[
      {},
      {'desktop_latest_version': 'not-a-version'},
    ]) {
      final remote = RemoteConfigService.forTesting(_UpdateConfigApi(flags));
      await remote.initialized;
      final service = AppUpdateService(remote);
      try {
        final result = await service.checkForUpdates();
        expect(result.phase, AppUpdatePhase.failed);
        expect(result.message, contains('有效版本信息'));
      } finally {
        service.dispose();
        remote.dispose();
      }
    }
  });

  test('检查过程中销毁服务会安静取消，不向已销毁通知器写状态', () async {
    final api = _PendingUpdateConfigApi();
    final remote = RemoteConfigService.forTesting(api);
    await remote.initialized;
    addTearDown(remote.dispose);
    final service = AppUpdateService(remote);
    final checking = service.checkForUpdates();
    await api.started.future;
    service.dispose();
    api.response.complete(
      CommunityRemoteConfig(
        flags: {'desktop_latest_version': 'v2.0.0'},
        schemaVersion: 1,
        generatedAt: DateTime.now(),
        source: 'test',
      ),
    );
    expect((await checking).message, contains('取消'));
  });

  test('只增加构建号的修复包也会提示更新', () async {
    final fixture = await _createService({
      'desktop_latest_version': 'v1.0.0+2',
    });
    final result = await fixture.service.checkForUpdates();
    expect(result.currentVersion, AppVersion.fullVersion);
    expect(result.hasUpdate, isTrue);
    expect(result.isMandatory, isFalse);
  });

  test('最低支持版本和强制开关各自能触发更新要求', () async {
    for (final policy in [
      {'desktop_min_supported_version': 'v1.0.0+2'},
      {'desktop_force_update': true},
    ]) {
      final fixture = await _createService({
        'desktop_latest_version': 'v1.0.0+3',
        'desktop_download_url': 'https://downloads.example.com/sohun.exe',
        ...policy,
      });
      final result = await fixture.service.checkForUpdates();
      expect(result.phase, AppUpdatePhase.available);
      expect(result.hasUpdate, isTrue);
      expect(result.isMandatory, isTrue);
      expect(result.isChecking, isFalse);
    }
  });

  test('达到最低版本仍能选择稍后更新', () async {
    final fixture = await _createService({
      'desktop_latest_version': 'v1.1.0',
      'desktop_min_supported_version': 'v1.0.0+1',
    });
    expect((await fixture.service.checkForUpdates()).isMandatory, isFalse);
  });

  test('已是最新版时force不制造死循环', () async {
    final current = await _createService({
      'desktop_latest_version': AppVersion.fullVersion,
      'desktop_force_update': true,
    });
    final result = await current.service.checkForUpdates();
    expect(result.phase, AppUpdatePhase.upToDate);
    expect(result.hasUpdate, isFalse);
    expect(result.isMandatory, isFalse);
  });

  test('Android只使用Android元数据，不回退到桌面安装器', () async {
    final fixture = await _createService({
      'desktop_latest_version': 'v9.0.0',
      'desktop_force_update': true,
      'desktop_download_url': 'https://downloads.example.com/windows.exe',
      'android_latest_version': 'v1.0.0+2',
      'android_download_url': 'https://downloads.example.com/android.apk',
      'android_release_notes': '手机修复',
    }, platform: AppUpdatePlatform.android);
    final result = await fixture.service.checkForUpdates();
    expect(result.latestVersion, 'v1.0.0+2');
    expect(result.isMandatory, isFalse);
    expect(result.downloadUri?.path, '/android.apk');
    expect(result.releaseNotes, '手机修复');

    fixture.api.flags = {
      'desktop_latest_version': 'v9.0.0',
      'desktop_download_url': 'https://downloads.example.com/windows.exe',
    };
    final noAndroid = await fixture.service.checkForUpdates();
    expect(noAndroid.phase, AppUpdatePhase.failed);
    expect(noAndroid.downloadUri?.path, '/android.apk');
  });

  test('定时远程刷新无需再点检查就能发布强制状态', () async {
    final fixture = await _createService({
      'desktop_latest_version': 'v1.2.0',
      'desktop_force_update': true,
      'desktop_download_url': 'https://downloads.example.com/sohun.exe',
    });
    await fixture.remote.fetchAndUpdate();
    expect(fixture.service.state.isMandatory, isTrue);
    expect(fixture.service.state.hasUpdate, isTrue);
    expect(fixture.service.state.isChecking, isFalse);
  });

  test('并发检查等待同一完成结果且只发一个请求', () async {
    final api = _PendingUpdateConfigApi();
    final remote = RemoteConfigService.forTesting(api);
    await remote.ready;
    addTearDown(remote.dispose);
    final service = AppUpdateService(remote);
    addTearDown(service.dispose);
    final first = service.checkForUpdates();
    final second = service.checkForUpdates();
    expect(identical(first, second), isTrue);
    await api.started.future;
    expect(service.state.isChecking, isTrue);
    api.response.complete(
      CommunityRemoteConfig(
        flags: {'desktop_latest_version': 'v2.0.0'},
        schemaVersion: 1,
        generatedAt: DateTime.now(),
        source: 'test',
      ),
    );
    final results = await Future.wait([first, second]);
    expect(api.requests, 1);
    expect(results.every((result) => result.hasUpdate), isTrue);
    expect(results.every((result) => !result.isChecking), isTrue);
  });

  test('重试期间和网络失败后都保留已确认强制状态及下载入口', () async {
    final fixture = await _createService(_mandatoryFlags);
    await fixture.service.checkForUpdates();
    fixture.api.nextError = StateError('offline');
    final retry = fixture.service.checkForUpdates();
    expect(fixture.service.state.isChecking, isTrue);
    expect(fixture.service.state.hasUpdate, isTrue);
    expect(fixture.service.state.isMandatory, isTrue);
    final failed = await retry;
    expect(failed.phase, AppUpdatePhase.failed);
    expect(failed.isChecking, isFalse);
    expect(failed.hasUpdate, isTrue);
    expect(failed.isMandatory, isTrue);
    expect(failed.downloadUri?.path, '/sohun.exe');
  });

  test('空配置、较低版本和错误策略不能撤销强制更新', () async {
    final fixture = await _createService(_mandatoryFlags);
    await fixture.service.checkForUpdates();
    for (final invalid in <Map<String, dynamic>>[
      {},
      {'desktop_latest_version': 'v1.0.0', 'desktop_force_update': false},
      {'desktop_latest_version': 'broken'},
      {'desktop_latest_version': 'v2.0.0', 'desktop_force_update': 'false'},
      {'desktop_latest_version': 'v2.0.0'},
      {
        'desktop_latest_version': 'v2.0.0',
        'desktop_min_supported_version': 'v3.0.0',
      },
    ]) {
      fixture.api.flags = invalid;
      final result = await fixture.service.checkForUpdates();
      expect(result.phase, AppUpdatePhase.failed);
      expect(result.isMandatory, isTrue);
      expect(result.latestVersion, 'v2.0.0');
      expect(result.downloadUri?.path, '/sohun.exe');
    }
  });

  test('同版本完整明确的策略可以将强制改为可选', () async {
    final fixture = await _createService(_mandatoryFlags);
    await fixture.service.checkForUpdates();
    fixture.api.flags = {
      ..._mandatoryFlags,
      'desktop_force_update': false,
      'desktop_min_supported_version': '',
    };
    final result = await fixture.service.checkForUpdates();
    expect(result.phase, AppUpdatePhase.available);
    expect(result.isMandatory, isFalse);
    expect(result.hasUpdate, isTrue);
    expect(result.minimumSupportedVersion, isNull);
    expect(result.mandatoryPolicyResolved, isTrue);
  });

  test('缺少明确撤回字段的可选状态不授予跨provider解锁凭据', () async {
    final fixture = await _createService({'desktop_latest_version': 'v2.0.0'});
    final optional = await fixture.service.checkForUpdates();
    expect(optional.hasUpdate, isTrue);
    expect(optional.mandatoryPolicyResolved, isFalse);
    fixture.api.flags = {
      'desktop_latest_version': 'v2.0.0',
      'desktop_force_update': false,
      'desktop_min_supported_version': '',
    };
    expect(
      (await fixture.service.checkForUpdates()).mandatoryPolicyResolved,
      isTrue,
    );
    fixture.api.nextError = StateError('offline');
    final checking = fixture.service.checkForUpdates();
    expect(fixture.service.state.mandatoryPolicyResolved, isFalse);
    expect((await checking).mandatoryPolicyResolved, isFalse);
  });

  test('门禁保留的安全下载地址在更新service重建为空时仍可打开', () async {
    final remote = RemoteConfigService.forTesting(null);
    await remote.ready;
    addTearDown(remote.dispose);
    final opened = <Uri>[];
    final service = AppUpdateService(
      remote,
      openExternalUrl: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    addTearDown(service.dispose);
    expect(await service.openDownloadPage(), isFalse);
    expect(
      await service.openDownloadPage(
        verifiedDownloadUri: Uri.parse(
          'https://downloads.example.com/sohun.exe',
        ),
      ),
      isTrue,
    );
    expect(
      await service.openDownloadPage(
        verifiedDownloadUri: Uri.parse(
          'https://user:secret@downloads.example.com/sohun.exe',
        ),
      ),
      isFalse,
    );
    expect(
      await service.openDownloadPage(
        verifiedDownloadUri: Uri.parse('file:///C:/sohun.exe'),
      ),
      isFalse,
    );
    expect(opened, hasLength(1));
    expect(service.state.hasUpdate, isFalse);
  });

  test('过期强制缓存和最近失败在服务重建后仍能恢复阻挡', () async {
    SharedPreferences.setMockInitialValues({
      'remote_config_cache': jsonEncode(_mandatoryFlags),
      'remote_config_source': 'cached',
      'remote_config_updated_at': 1,
    });
    final api = _UpdateConfigApi({})..nextError = StateError('offline');
    final remote = RemoteConfigService.forTesting(api);
    await remote.ready;
    addTearDown(remote.dispose);
    // 模拟恢复前台先失败，之后新 endpoint/provider 创建更新服务。
    await remote.fetchAndUpdate();
    final service = AppUpdateService(remote);
    addTearDown(service.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(service.state.phase, AppUpdatePhase.failed);
    expect(service.state.isMandatory, isTrue);
    expect(service.state.downloadUri?.path, '/sohun.exe');
  });

  test('强制更新没有安全下载地址时解除门禁且不会调用系统打开器', () async {
    var opened = false;
    final fixture = await _createService({
      ..._mandatoryFlags,
      'desktop_download_url': 'http://downloads.example.com/sohun.exe',
    }, openExternalUrl: (_) async => opened = true);
    final result = await fixture.service.checkForUpdates();
    expect(result.isMandatory, isFalse);
    expect(result.mandatoryPolicyResolved, isTrue);
    expect(result.downloadUri, isNull);
    expect(result.message, contains('已允许继续使用'));
    expect(await fixture.service.openDownloadPage(), isFalse);
    expect(opened, isFalse);
  });

  test('异常URL刷新后重建两个服务仍能打开同一版本已确认的入口', () async {
    final fixture = await _createService(_mandatoryFlags);
    await fixture.service.checkForUpdates();
    fixture.api.flags = {
      ..._mandatoryFlags,
      'desktop_latest_version': '2.0.0',
      'desktop_download_url': 'http://downloads.example.com/wrong.exe',
    };
    await fixture.service.checkForUpdates();
    final restoredRemote = RemoteConfigService.forTesting(null);
    await restoredRemote.ready;
    addTearDown(restoredRemote.dispose);
    final opened = <Uri>[];
    final restored = AppUpdateService(
      restoredRemote,
      openExternalUrl: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    addTearDown(restored.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(restored.state.latestVersion, '2.0.0');
    expect(restored.state.isMandatory, isTrue);
    expect(restored.state.downloadUri?.path, '/sohun.exe');
    expect(await restored.openDownloadPage(), isTrue);
    expect(opened.single.scheme, 'https');
  });

  test('新版本无URL时检查和重启都不会把旧安装包当作新版本打开', () async {
    final fixture = await _createService(_mandatoryFlags);
    await fixture.service.checkForUpdates();
    fixture.api.flags = {
      ..._mandatoryFlags,
      'desktop_latest_version': 'v2.0.0+1',
      'desktop_download_url': '',
    };
    final result = await fixture.service.checkForUpdates();
    expect(result.isMandatory, isFalse);
    expect(result.mandatoryPolicyResolved, isTrue);
    expect(result.downloadUri, isNull);
    final restoredRemote = RemoteConfigService.forTesting(null);
    await restoredRemote.ready;
    addTearDown(restoredRemote.dispose);
    var opened = false;
    final restored = AppUpdateService(
      restoredRemote,
      openExternalUrl: (_) async => opened = true,
    );
    addTearDown(restored.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(restored.state.latestVersion, 'v2.0.0+1');
    expect(restored.state.isMandatory, isFalse);
    expect(restored.state.mandatoryPolicyResolved, isTrue);
    expect(restored.state.downloadUri, isNull);
    expect(await restored.openDownloadPage(), isFalse);
    expect(opened, isFalse);
  });

  test('Android系统打开失败可重试，成功打开也不假装已完成升级', () async {
    final opened = <Uri>[];
    var failOpening = true;
    final fixture = await _createService(
      {
        'android_latest_version': 'v2.0.0',
        'android_force_update': true,
        'android_download_url': 'https://downloads.example.com/sohun.apk',
      },
      platform: AppUpdatePlatform.android,
      openExternalUrl: (uri) async {
        opened.add(uri);
        if (failOpening) throw StateError('no browser');
        return true;
      },
    );
    await fixture.service.checkForUpdates();
    expect(await fixture.service.openDownloadPage(), isFalse);
    failOpening = false;
    expect(await fixture.service.openDownloadPage(), isTrue);
    expect(opened.map((uri) => uri.path), ['/sohun.apk', '/sohun.apk']);
    expect(fixture.service.state.isMandatory, isTrue);
    expect(fixture.service.state.hasUpdate, isTrue);
  });
}

const _mandatoryFlags = <String, dynamic>{
  'desktop_latest_version': 'v2.0.0',
  'desktop_min_supported_version': 'v1.1.0',
  'desktop_force_update': true,
  'desktop_download_url': 'https://downloads.example.com/sohun.exe',
};

Future<
  ({AppUpdateService service, RemoteConfigService remote, _UpdateConfigApi api})
>
_createService(
  Map<String, dynamic> flags, {
  AppUpdatePlatform platform = AppUpdatePlatform.desktop,
  Future<bool> Function(Uri)? openExternalUrl,
}) async {
  final api = _UpdateConfigApi(flags);
  final remote = RemoteConfigService.forTesting(api, platform: platform.name);
  await remote.ready;
  addTearDown(remote.dispose);
  final service = AppUpdateService(
    remote,
    platform: platform,
    openExternalUrl: openExternalUrl,
  );
  addTearDown(service.dispose);
  return (service: service, remote: remote, api: api);
}

class _PendingUpdateConfigApi extends _UpdateConfigApi {
  _PendingUpdateConfigApi() : super({});
  final started = Completer<void>();
  final response = Completer<CommunityRemoteConfig>();

  @override
  Future<CommunityRemoteConfig> fetchRemoteConfig({
    required String appVersion,
    required String platform,
    String? ifNoneMatch,
  }) {
    requests += 1;
    started.complete();
    return response.future;
  }
}

class _UpdateConfigApi implements CommunityTelemetryApi {
  _UpdateConfigApi(this.flags);

  Map<String, dynamic> flags;
  Object? nextError;
  int requests = 0;

  @override
  Future<CommunityRemoteConfig> fetchRemoteConfig({
    required String appVersion,
    required String platform,
    String? ifNoneMatch,
  }) async {
    requests += 1;
    if (nextError != null) throw nextError!;
    return CommunityRemoteConfig(
      flags: flags,
      schemaVersion: 1,
      generatedAt: DateTime.now(),
      source: 'test',
    );
  }

  @override
  Future<CommunityTelemetryBatchResult> submitTelemetryBatch({
    required String installIdHash,
    required List<Map<String, dynamic>> events,
  }) {
    throw UnimplementedError();
  }
}
