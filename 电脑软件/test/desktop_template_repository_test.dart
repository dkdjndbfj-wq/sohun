import 'dart:convert';
import 'dart:typed_data';

import 'package:consumable_tracker_desktop/core/services/windows_dpapi.dart';
import 'package:consumable_tracker_desktop/features/rfid/desktop_template_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ams_template_fixture.dart';

class _Protector implements DataProtector {
  final payloads = <String, Uint8List>{};
  bool fail = false;
  @override
  Future<Uint8List> protect(Uint8List plain) async {
    if (fail) throw StateError('OS failure');
    final token = 'opaque-${payloads.length}';
    payloads[token] = plain;
    return Uint8List.fromList(utf8.encode(token));
  }

  @override
  Future<Uint8List> unprotect(Uint8List encrypted) async {
    if (fail) throw StateError('OS failure');
    return payloads[utf8.decode(encrypted)]!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'desktop vault stores only protected blobs and isolates normalized owners',
    () async {
      final p = _Protector();
      final repo = DesktopTemplateRepository(protector: p);
      await repo.save(
        syntheticAmsTemplate(),
        ownerAccount: ' Alice@Example.com|personal ',
      );
      expect(
        await repo.list(ownerAccount: 'bob@example.com|personal'),
        isEmpty,
      );
      expect(
        (await repo.list(ownerAccount: 'alice@example.com|personal')).single.id,
        syntheticAmsTemplate().id,
      );
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(prefs.getKeys().single)!;
      expect(utf8.decode(base64Decode(stored)), startsWith('opaque-'));
      expect(stored, isNot(contains('blocks')));
    },
  );
  test(
    'protection failure has no plaintext fallback and preserves old vault',
    () async {
      final p = _Protector();
      final repo = DesktopTemplateRepository(protector: p);
      await repo.save(syntheticAmsTemplate(), ownerAccount: 'alice');
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getKeys().single;
      final before = prefs.getString(key);
      p.fail = true;
      await expectLater(
        repo.save(syntheticAmsTemplate(), ownerAccount: 'alice'),
        throwsA(isA<FormatException>()),
      );
      expect(prefs.getString(key), before);
    },
  );
  test(
    'serialized concurrent writes keep owner vault records intact',
    () async {
      final repo = DesktopTemplateRepository(protector: _Protector());
      await Future.wait([
        repo.save(syntheticAmsTemplate(), ownerAccount: 'alice'),
        repo.save(syntheticAmsTemplate(), ownerAccount: 'bob'),
      ]);
      expect(await repo.list(ownerAccount: 'alice'), hasLength(1));
      expect(await repo.list(ownerAccount: 'bob'), hasLength(1));
      await repo.delete(syntheticAmsTemplate().id, ownerAccount: 'bob');
      expect(await repo.list(ownerAccount: 'alice'), hasLength(1));
      expect(await repo.list(ownerAccount: 'bob'), isEmpty);
    },
  );
  test('corrupt blob is not replaced with an empty vault', () async {
    final repo = DesktopTemplateRepository(protector: _Protector());
    await repo.save(syntheticAmsTemplate(), ownerAccount: 'alice');
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getKeys().single;
    await prefs.setString(key, 'corrupt!');
    await expectLater(
      repo.list(ownerAccount: 'alice'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      repo.delete(syntheticAmsTemplate().id, ownerAccount: 'alice'),
      throwsA(isA<FormatException>()),
    );
    expect(prefs.getString(key), 'corrupt!');
  });
}
