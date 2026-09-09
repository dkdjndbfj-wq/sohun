import 'dart:async';

import 'package:consumable_tracker_desktop/mobile/device_tag_nfc.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const token = '0123456789abcdef0123456789abcdef';
  const uri = 'https://sohun.top/device/$token';
  const channel = MethodChannel(MethodChannelDeviceTagNfc.channelName);
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MethodChannelDeviceTagNfc bridge;
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall)? handler;

  Future<void> event(String method, Object? data) async {
    final done = Completer<void>();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, data)),
      (_) => done.complete(),
    );
    await done.future;
  }

  Map<String, Object> success(String id, String state) => {
    'operationId': id,
    'state': state,
    'deviceToken': token,
    'uri': uri,
    'tagId': '04AABBCCDDEE11',
    'tagType': 'NTAG213',
    'verified': true,
    'bytesWritten': 100,
  };

  setUp(() {
    calls.clear();
    handler = null;
    bridge = MethodChannelDeviceTagNfc(
      methodChannel: channel,
      operationTimeout: const Duration(milliseconds: 200),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler?.call(call);
    });
  });

  tearDown(() async {
    await bridge.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('device URI accepts only exact supported entries', () {
    expect(DeviceTagUri.parse(uri)?.token, token);
    expect(DeviceTagUri.parse('sohun://device/$token')?.uri, uri);
    expect(DeviceTagUri.forToken(token).appUri, 'sohun://device/$token');
    for (final bad in [
      '$uri?accessCode=secret',
      '$uri#secret',
      '$uri/',
      '$uri\n',
      'https://sohun.top:443/device/$token',
      'https://person@sohun.top/device/$token',
      'https://sohun.top.attacker.invalid/device/$token',
      'https://sohun.top/device/%30${token.substring(1)}',
      'sohun://device/$token?secret=1',
      'sohun://device:90/$token',
      'http://sohun.top/device/$token',
    ]) {
      expect(DeviceTagUri.parse(bad), isNull, reason: bad);
    }
  });

  test('invalid tokens fail before activating native NFC', () async {
    for (final bad in [uri, '04AABBCCDDEE11', 'eSUN PLA blue', '$token\n']) {
      expect(() => DeviceTagUri.forToken(bad), throwsFormatException);
      expect(await bridge.write(bad), isA<DeviceTagWriteFailure>());
    }
    expect(calls, isEmpty);
  });

  test('write uses only device token and requires verified readback', () async {
    handler = (call) async {
      if (call.method != 'beginWrite') return null;
      final args = call.arguments as Map;
      expect(args.keys.toSet(), {'operationId', 'deviceToken'});
      expect(args['deviceToken'], token);
      await event(
        'deviceTagEvent',
        success(args['operationId'] as String, 'write_success'),
      );
      return {'state': 'awaiting_tag'};
    };
    final result = await bridge.write(token) as DeviceTagWriteSuccess;
    expect(result.uri, uri);
    expect(result.deviceToken, token);
    expect(result.tagId, '04AABBCCDDEE11');
    expect(result.verified, isTrue);
    expect(result.bytesWritten, 100);
    expect(
      calls.every((call) => call.method != 'beginRestoreAmsTemplate'),
      isTrue,
    );
  });

  test('read routes to the isolated device channel', () async {
    handler = (call) async {
      if (call.method == 'beginRead') {
        final args = call.arguments as Map;
        expect(args.keys.toSet(), {'operationId'});
        return success(args['operationId'] as String, 'read_success');
      }
      return null;
    };
    final result = await bridge.read() as DeviceTagReadSuccess;
    expect(result.deviceToken, token);
    expect(result.uri, uri);
  });

  test(
    'write rejects incomplete, wrong-token and wrong-carrier success',
    () async {
      for (final update in <Map<String, Object>>[
        {'verified': false},
        {'bytesWritten': 0},
        {'deviceToken': 'ffffffffffffffffffffffffffffffff'},
        {'tagType': 'CUID'},
        {'tagId': 'AABBCCDD'},
        {'uri': '$uri?secret=1'},
      ]) {
        handler = (call) async => call.method == 'beginWrite'
            ? {
                ...success(
                  (call.arguments as Map)['operationId'] as String,
                  'write_success',
                ),
                ...update,
              }
            : null;
        expect(await bridge.write(token), isA<DeviceTagWriteFailure>());
      }
    },
  );

  test('an event from an older operation cannot complete this read', () async {
    handler = (call) async {
      if (call.method == 'beginRead') {
        await event('deviceTagEvent', success('old-operation', 'read_success'));
        return success(
          (call.arguments as Map)['operationId'] as String,
          'read_success',
        );
      }
      return null;
    };
    expect(await bridge.read(), isA<DeviceTagReadSuccess>());
  });

  test(
    'native NFC busy, locked and unavailable failures stay explicit',
    () async {
      for (final code in ['NFC_BUSY', 'TAG_LOCKED', 'NFC_UNAVAILABLE']) {
        handler = (call) async => throw PlatformException(code: code);
        final result = await bridge.write(token) as DeviceTagWriteFailure;
        expect(result.code, code);
      }
    },
  );

  test('only one bridge operation may wait for NFC', () async {
    final started = Completer<void>();
    handler = (call) async {
      if (call.method == 'beginRead') started.complete();
      return null;
    };
    final first = bridge.read();
    await started.future;
    final second = await bridge.write(token) as DeviceTagWriteFailure;
    expect(second.code, 'NFC_BUSY');
    await bridge.cancel();
    expect(await first, isA<DeviceTagReadFailure>());
    expect(calls.where((call) => call.method.startsWith('begin')).length, 1);
  });

  test(
    'cancel preserves native verified completion in the handoff race',
    () async {
      final started = Completer<void>();
      handler = (call) async {
        if (call.method == 'beginWrite') started.complete();
        if (call.method == 'cancel') {
          return success(
            (call.arguments as Map)['operationId'] as String,
            'write_success',
          );
        }
        return null;
      };
      final pending = bridge.write(token);
      await started.future;
      await bridge.cancel();
      expect(await pending, isA<DeviceTagWriteSuccess>());
    },
  );

  test(
    'timeout cancels the native reader and does not report success',
    () async {
      final result = await bridge.write(token) as DeviceTagWriteFailure;
      expect(result.code, 'OPERATION_TIMEOUT');
      expect(calls.map((call) => call.method), ['beginWrite', 'cancel']);
    },
  );

  test('cold-start pending URI is validated and canonicalized', () async {
    handler = (call) async => 'sohun://device/$token';
    expect(await bridge.takePendingDeviceUri(), uri);
    handler = (call) async => '$uri?secret=1';
    expect(await bridge.takePendingDeviceUri(), isNull);
  });

  test('warm launch emits only validated device entry URIs', () async {
    final received = <String>[];
    final subscription = bridge.deviceUris.listen(received.add);
    await event('deviceUri', '$uri?secret=1');
    await event('deviceUri', 'sohun://device/$token');
    await Future<void>.delayed(Duration.zero);
    expect(received, [uri]);
    await subscription.cancel();
  });

  test(
    'disposing cancels the active reader and prevents later operations',
    () async {
      final started = Completer<void>();
      handler = (call) async {
        if (call.method == 'beginRead') started.complete();
        return null;
      };
      final read = bridge.read();
      await started.future;
      await bridge.dispose();
      expect(await read, isA<DeviceTagReadFailure>());
      expect(await bridge.write(token), isA<DeviceTagWriteFailure>());
      expect(calls.map((call) => call.method), ['beginRead', 'cancel']);
    },
  );

  test(
    'NFC status and missing plugin are handled without exceptions',
    () async {
      handler = (call) async => {'available': true, 'enabled': false};
      expect(await bridge.isAvailable(), isTrue);
      expect(await bridge.isEnabled(), isFalse);
      handler = (call) async => throw MissingPluginException();
      expect(await bridge.isAvailable(), isFalse);
      expect(await bridge.isEnabled(), isFalse);
      expect(await bridge.read(), isA<DeviceTagReadFailure>());
    },
  );
}
