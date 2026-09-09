import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses the read-only MIFARE Classic scan event', () async {
    const channel = MethodChannel(MethodChannelRfidNativeBridge.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMethodCodec();

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') {
        return <String, Object>{'available': true, 'enabled': true};
      }
      if (call.method == 'beginScan') {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final operationId = args['operationId']?.toString();
        Future<void>.microtask(() {
          final event = <String, Object?>{
            'event': 'state',
            'operationId': operationId,
            'state': 'scan_success',
            'code': 'SCAN_OK',
            'tag': <String, Object?>{
              'technology': 'MIFARE_CLASSIC',
              'type': 'CLASSIC',
              'uid': 'A1B2C3D4',
              'sizeBytes': 1024,
              'blockCount': 64,
              'sectorCount': 16,
              'uidLengthBytes': 4,
              'defaultKeyAuthenticatedSectors': 16,
              'defaultKeyReadableSectors': 16,
              'defaultKeyReadableBlocks': 16,
              'defaultKeyReadable': true,
              'verification': 'metadata_only',
            },
          };
          messenger.handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(MethodCall('rfidEvent', event)),
            (_) {},
          );
        });
        return <String, Object?>{
          'operationId': operationId,
          'state': 'awaiting_tag',
        };
      }
      return null;
    });

    final bridge = MethodChannelRfidNativeBridge(methodChannel: channel);
    final result = await bridge.scanMifareClassic();

    expect(result, isA<RfidMifareScanSuccess>());
    final success = result as RfidMifareScanSuccess;
    expect(success.tagId, 'A1B2C3D4');
    expect(success.tagType, 'CLASSIC');
    expect(success.sizeBytes, 1024);
    expect(success.blockCount, 64);
    expect(success.sectorCount, 16);
    expect(success.uidLengthBytes, 4);
    expect(success.hasFourByteUid, isTrue);
    expect(success.defaultKeyReadable, isTrue);
    expect(success.defaultKeyReadableBlocks, 16);

    messenger.setMockMethodCallHandler(channel, null);
  });
}
