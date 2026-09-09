import 'dart:async';

import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ams_template_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(MethodChannelRfidNativeBridge.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  const draft = MobileConsumableDraft(
    brand: 'eSUN',
    model: 'PLA',
    color: Color(0xFFFFFFFF),
    colorName: '白色',
  );
  late MethodChannelRfidNativeBridge bridge;
  final calls = <MethodCall>[];

  Future<void> emit(Map<String, Object?> event) async {
    final completed = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall('rfidEvent', event)),
      (_) => completed.complete(),
    );
    await completed.future;
  }

  setUp(() {
    calls.clear();
    bridge = MethodChannelRfidNativeBridge(methodChannel: channel);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'legacy NTAG profiles fail without NFC discovery or record writes',
    () async {
      for (final profile in ['ntag213', 'NTAG213', ' nTaG213 ']) {
        final result = await bridge.writeProfile(draft, profile: profile);
        expect((result as RfidWriteFailure).code, 'unsupported_tag_purpose');
      }
      await bridge.cancel();
      expect(calls, isEmpty);
    },
  );

  test(
    'legacy NTAG reader cannot start NFC or return an inventory draft',
    () async {
      final result = await bridge.read();
      expect((result as RfidReadFailure).code, 'unsupported_tag_purpose');
      await bridge.cancel();
      expect(calls, isEmpty);
    },
  );

  test('status and existing profile errors remain available', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'available': true, 'enabled': true};
    });
    expect(await bridge.isAvailable(), isTrue);
    expect(await bridge.isEnabled(), isTrue);
    expect(
      (await bridge.write(draft) as RfidWriteFailure).code,
      'ams_template_required',
    );
    expect(
      (await bridge.writeProfile(draft, profile: 'unknown') as RfidWriteFailure)
          .code,
      'invalid_profile',
    );
    expect(calls.map((call) => call.method), ['getStatus', 'getStatus']);
  });

  test(
    'rejected NTAG calls do not replace an active Classic scan handler',
    () async {
      final started = Completer<String>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'beginScan') {
          started.complete((call.arguments as Map)['operationId'] as String);
        }
        return null;
      });
      final scan = bridge.scanMifareClassic();
      final operationId = await started.future;
      expect(
        (await bridge.read() as RfidReadFailure).code,
        'unsupported_tag_purpose',
      );
      expect(
        (await bridge.writeProfile(draft, profile: 'ntag213')
                as RfidWriteFailure)
            .code,
        'unsupported_tag_purpose',
      );
      await emit({
        'operationId': operationId,
        'state': 'scan_success',
        'tag': {
          'uid': 'D021B75E',
          'type': 'CLASSIC',
          'technology': 'MIFARE_CLASSIC',
          'uidLengthBytes': 4,
        },
      });
      final result = await scan as RfidMifareScanSuccess;
      expect(result.tagId, 'D021B75E');
      expect(result.tagType, 'CLASSIC');
      expect(calls.map((call) => call.method), ['beginScan']);
    },
  );

  test(
    'rejected NTAG calls preserve a verified CUID template restoration',
    () async {
      final template = syntheticAmsTemplate();
      final started = Completer<String>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'beginRestoreAmsTemplate') {
          final args = call.arguments as Map;
          expect(args['targetKind'], 'cuid');
          expect(args['record'], isNull);
          expect((args['template'] as Map)['blocks'], template.blocks);
          started.complete(args['operationId'] as String);
        }
        return null;
      });
      final restore = bridge.restoreAmsTemplate(
        template,
        targetKind: 'cuid',
        allowUidChange: true,
      );
      final operationId = await started.future;
      expect(
        (await bridge.read() as RfidReadFailure).code,
        'unsupported_tag_purpose',
      );
      expect(
        (await bridge.writeProfile(draft, profile: 'ntag213')
                as RfidWriteFailure)
            .code,
        'unsupported_tag_purpose',
      );
      await emit({
        'operationId': operationId,
        'state': 'success',
        'tagId': template.uid,
        'tagType': 'CUID',
        'verified': true,
        'blocksVerified': 64,
        'amsCompatibility': 'template_restored_unverified',
      });
      expect(await restore, isA<RfidWriteSuccess>());
      expect(calls.map((call) => call.method), ['beginRestoreAmsTemplate']);
    },
  );
}
