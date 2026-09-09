import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeCommunityServerUri', () {
    test('normalizes scheme, host, default port and trailing slash', () {
      final uri = normalizeCommunityServerUri(
        ' HTTPS://SHARE.Example.COM:443/api/ ',
      );

      expect(uri.toString(), 'https://share.example.com/api');
    });

    test('keeps valid non-default ports and base paths', () {
      final uri = normalizeCommunityServerUri('http://127.0.0.1:8080/api/v1');
      expect(uri.toString(), 'http://127.0.0.1:8080/api/v1');
    });

    test('rejects unsafe or ambiguous URLs', () {
      for (final value in [
        '',
        'share.example.com',
        'ftp://share.example.com',
        'http://192.168.1.10:27861',
        'http://share.example.com',
        'http://127.attacker.example',
        'http://127.0.0.1.evil.example',
        'https://user:pass@share.example.com',
        'https://share.example.com/api?token=secret',
        'https://share.example.com/api#fragment',
        'https://share.example.com/a/../admin',
        'https://share.example.com/bad path',
      ]) {
        expect(
          () => normalizeCommunityServerUri(value),
          throwsFormatException,
          reason: value,
        );
      }
    });
  });

  group('CommunityServerSettings', () {
    test('uses compile-time value when no runtime override exists', () async {
      final store = _MemoryOverrideStore();
      final settings = CommunityServerSettings(
        store: store,
        compileTimeBaseUrl: 'https://compiled.example.com/api/',
      );

      expect(
        (await settings.loadBaseUri()).toString(),
        'https://compiled.example.com/api',
      );
    });

    test(
        'persists normalized runtime override and reset restores compile value',
        () async {
      final store = _MemoryOverrideStore();
      final settings = CommunityServerSettings(
        store: store,
        compileTimeBaseUrl: 'https://compiled.example.com',
        allowRuntimeOverride: true,
      );

      final selected =
          await settings.setOverride('https://RUNTIME.example.com:443/api/');
      expect(selected.toString(), 'https://runtime.example.com/api');
      expect(store.value, 'https://runtime.example.com/api');
      expect(
        (await settings.loadBaseUri()).toString(),
        'https://runtime.example.com/api',
      );

      final reset = await settings.resetOverride();
      expect(store.value, isNull);
      expect(reset.toString(), 'https://compiled.example.com');
    });

    test('a compiled production endpoint ignores and rejects overrides',
        () async {
      final store = _MemoryOverrideStore()
        ..value = 'https://untrusted.example.com';
      final settings = CommunityServerSettings(
        store: store,
        compileTimeBaseUrl: 'https://official.example.com',
      );

      expect(
        (await settings.loadBaseUri()).toString(),
        'https://official.example.com',
      );
      await expectLater(
        settings.setOverride('https://untrusted.example.com'),
        throwsA(isA<StateError>()),
      );
      expect(store.value, 'https://untrusted.example.com');
    });

    test('empty compile-time value reports an unconfigured server', () async {
      final settings = CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: '',
      );

      expect(await settings.loadBaseUri(), isNull);
    });
  });
}

class _MemoryOverrideStore implements CommunityServerOverrideStore {
  String? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}
