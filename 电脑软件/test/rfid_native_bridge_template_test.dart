import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';
import 'support/ams_template_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(MethodChannelRfidNativeBridge.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  final template = syntheticAmsTemplate();
  late MethodChannelRfidNativeBridge bridge;

  Future<void> emit(Map<String, Object?> event) async {
    final completer = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall('rfidEvent', event)),
      (_) => completer.complete(),
    );
    await completer.future;
  }

  setUp(() => bridge = MethodChannelRfidNativeBridge(methodChannel: channel));
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Dart waits leave delivery grace after both native watchdogs', () {
    expect(
      MethodChannelRfidNativeBridge.defaultAmsTemplateReadWaitTimeout -
          MethodChannelRfidNativeBridge.nativeAmsTemplateReadTimeout,
      MethodChannelRfidNativeBridge.nativeTimeoutDeliveryGrace,
    );
    expect(
      MethodChannelRfidNativeBridge.defaultAmsTemplateRestoreWaitTimeout -
          MethodChannelRfidNativeBridge.nativeAmsTemplateRestoreTimeout,
      MethodChannelRfidNativeBridge.nativeTimeoutDeliveryGrace,
    );
  });

  test('AMS generic write is rejected before native mutation', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return null;
    });
    final result = await bridge.write(
      const MobileConsumableDraft(
        brand: 'third party',
        model: 'PLA',
        color: Color(0xFFFFFFFF),
        colorName: '',
      ),
    );
    expect(result, isA<RfidWriteFailure>());
    expect(calls, 0);
  });

  test('restore requires explicit UID consent', () async {
    final result = await bridge.restoreAmsTemplate(
      template,
      targetKind: 'fuid',
      allowUidChange: false,
    );
    expect((result as RfidWriteFailure).code, 'uid_confirmation_required');
  });

  test(
    'read validates full template and ignores unrelated operation events',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'beginReadAmsTemplate') {
          final id = (call.arguments as Map)['operationId'];
          scheduleMicrotask(() async {
            await emit({'operationId': 'other', 'state': 'failed'});
            await emit({
              'operationId': id,
              'state': 'template_read_success',
              'template': template.toJson(),
            });
          });
        }
        return null;
      });
      final result = await bridge.readAmsTemplate();
      expect((result as AmsTemplateReadSuccess).template.id, template.id);
      expect(result.template.signatureVerified, isFalse);
    },
  );

  test(
    'restore sends unchanged blocks without third party fields and waits for reselect',
    () async {
      final progress = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'beginRestoreAmsTemplate') {
          final args = call.arguments as Map;
          expect(args['record'], isNull);
          expect((args['template'] as Map)['blocks'], template.blocks);
          scheduleMicrotask(() async {
            await emit({
              'operationId': args['operationId'],
              'state': 'awaiting_reselect',
            });
            await emit({
              'operationId': args['operationId'],
              'state': 'success',
              'tagId': template.uid,
              'tagType': 'CUID',
              'verified': true,
              'blocksVerified': 64,
              'amsCompatibility': 'template_restored_unverified',
            });
          });
        }
        return null;
      });
      final result = await bridge.restoreAmsTemplate(
        template,
        targetKind: 'cuid',
        allowUidChange: true,
        onProgress: progress.add,
      );
      expect(progress, ['awaiting_reselect']);
      expect(result, isA<RfidWriteSuccess>());
      expect((result as RfidWriteSuccess).amsCompatibilityVerified, isFalse);
    },
  );

  for (final invalid in [
    {'tagId': 'DEADBEEF', 'verified': true, 'blocksVerified': 64},
    {'tagId': template.uid, 'verified': false, 'blocksVerified': 64},
    {'tagId': template.uid, 'verified': true, 'blocksVerified': 63},
  ]) {
    test(
      'incomplete restore cannot be reported successful: $invalid',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'beginRestoreAmsTemplate') {
            scheduleMicrotask(
              () => emit({
                'operationId': (call.arguments as Map)['operationId'],
                'state': 'success',
                'amsCompatibility': 'template_restored_unverified',
                ...invalid,
              }),
            );
          }
          return null;
        });
        final result = await bridge.restoreAmsTemplate(
          template,
          targetKind: 'cuid',
          allowUidChange: true,
        );
        expect(
          (result as RfidWriteFailure).code,
          'template_verification_incomplete',
        );
      },
    );
  }

  test(
    'template read shares operation lock and cancels without saving',
    () async {
      final begun = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'beginReadAmsTemplate') begun.complete();
        return null;
      });
      final reading = bridge.readAmsTemplate();
      await begun.future;
      expect(
        (await bridge.scanMifareClassic() as RfidScanFailure).code,
        'nfc_busy',
      );
      await bridge.cancel();
      expect(
        (await reading as AmsTemplateReadFailure).code,
        'template_read_cancelled',
      );
    },
  );

  test('native read timeout arrives before the Dart fallback', () async {
    final calls = <String>[];
    bridge = MethodChannelRfidNativeBridge(
      methodChannel: channel,
      amsTemplateReadWaitTimeout: const Duration(milliseconds: 200),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'beginReadAmsTemplate') {
        final id = (call.arguments as Map)['operationId'];
        Future<void>.delayed(const Duration(milliseconds: 20), () async {
          await emit({
            'operationId': id,
            'state': 'cancelled',
            'code': 'OPERATION_TIMEOUT',
            'message': 'native timeout',
          });
        });
      }
      return null;
    });

    final result = await bridge.readAmsTemplate();

    expect((result as AmsTemplateReadFailure).code, 'OPERATION_TIMEOUT');
    expect(calls, ['beginReadAmsTemplate']);
  });

  test('native restore timeout arrives before the Dart fallback', () async {
    final calls = <String>[];
    bridge = MethodChannelRfidNativeBridge(
      methodChannel: channel,
      amsTemplateRestoreWaitTimeout: const Duration(milliseconds: 200),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'beginRestoreAmsTemplate') {
        final id = (call.arguments as Map)['operationId'];
        Future<void>.delayed(const Duration(milliseconds: 20), () async {
          await emit({
            'operationId': id,
            'state': 'cancelled',
            'code': 'OPERATION_TIMEOUT',
            'message': 'native timeout',
          });
        });
      }
      return null;
    });

    final result = await bridge.restoreAmsTemplate(
      template,
      targetKind: 'cuid',
      allowUidChange: true,
    );

    expect((result as RfidWriteFailure).code, 'OPERATION_TIMEOUT');
    expect(calls, ['beginRestoreAmsTemplate']);
  });
}
