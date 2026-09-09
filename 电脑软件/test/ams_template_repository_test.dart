import 'package:consumable_tracker_desktop/mobile/ams_tag_template.dart';
import 'package:consumable_tracker_desktop/mobile/ams_template_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ams_tag_template_test.dart' show syntheticAmsDump;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('top.sohun/rfid_template_vault');
  const repository = MethodChannelAmsTemplateRepository();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'uses only native device vault and isolates normalized accounts',
    () async {
      final storage = <String, Map<String, Map<String, Object?>>>{};
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = Map<String, Object?>.from(call.arguments as Map);
        final owner = args['ownerAccount']! as String;
        final values = storage.putIfAbsent(owner, () => {});
        switch (call.method) {
          case 'listTemplates':
            return values.values.toList();
          case 'readTemplate':
            return values[args['id']];
          case 'saveTemplate':
            final template = Map<String, Object?>.from(
              args['template']! as Map,
            );
            values[template['id']! as String] = template;
            return null;
          case 'deleteTemplate':
            values.remove(args['id']);
            return null;
        }
        throw MissingPluginException();
      });
      final template = AmsTagTemplate.fromBytes(syntheticAmsDump());
      await repository.save(template, ownerAccount: ' Alice@Example.COM ');
      expect(
        (await repository.list(ownerAccount: 'alice@example.com')).single.id,
        template.id,
      );
      expect(await repository.list(ownerAccount: 'bob@example.com'), isEmpty);
      expect(await repository.list(ownerAccount: ''), isEmpty);
      expect(
        await repository.read(template.id, ownerAccount: 'bob@example.com'),
        isNull,
      );
      expect(
        (await repository.read(
          template.id,
          ownerAccount: 'alice@example.com',
        ))?.id,
        template.id,
      );
      await repository.delete(template.id, ownerAccount: 'bob@example.com');
      expect(
        await repository.list(ownerAccount: 'alice@example.com'),
        hasLength(1),
      );
      await repository.delete(template.id, ownerAccount: 'alice@example.com');
      expect(await repository.list(ownerAccount: 'alice@example.com'), isEmpty);
    },
  );

  test(
    'fails closed for missing native storage instead of plaintext fallback',
    () async {
      await expectLater(
        repository.list(ownerAccount: ''),
        throwsA(isA<MissingPluginException>()),
      );
    },
  );

  test(
    'rejects corrupt stored payload without exposing its contents',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => [
          {'blocks': 'secret-material'},
        ],
      );
      try {
        await repository.list(ownerAccount: 'alice');
        fail('Expected corruption to fail closed');
      } on FormatException catch (error) {
        expect(error.source, isNull);
        expect(error.toString().contains('secret-material'), isFalse);
      }
    },
  );

  test(
    'rejects oversized vault responses and unsafe identifiers locally',
    () async {
      var called = false;
      messenger.setMockMethodCallHandler(channel, (_) async {
        called = true;
        return [];
      });
      await expectLater(
        repository.read('../anything', ownerAccount: ''),
        throwsFormatException,
      );
      await expectLater(
        repository.list(ownerAccount: 'alice\nother'),
        throwsFormatException,
      );
      expect(called, isFalse);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => List.generate(129, (_) => {}),
      );
      await expectLater(
        repository.list(ownerAccount: ''),
        throwsFormatException,
      );
    },
  );
}
