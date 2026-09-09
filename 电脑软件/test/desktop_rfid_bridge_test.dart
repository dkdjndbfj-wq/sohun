import 'dart:typed_data';

import 'package:consumable_tracker_desktop/features/rfid/desktop_rfid_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ams_template_fixture.dart';
import 'support/desktop_rfid_fixture.dart';

void main() {
  late FakeDesktopSerial serial;
  late DesktopRfidBridge bridge;
  setUp(() {
    serial = FakeDesktopSerial();
    bridge = DesktopRfidBridge(transport: serial);
  });
  tearDown(() async {
    bridge.dispose();
    await serial.controller.close();
  });

  test('device enumeration never opens or probes a port', () async {
    expect((await serial.listPorts()).single.isKitCandidate, isTrue);
    expect(serial.openCount, 0);
    expect(serial.requests, isEmpty);
  });
  test(
    'connect verifies kit identity, protocol and reader readiness',
    () async {
      await bridge.connect('COM7');
      expect(bridge.connected, isTrue);
      expect(bridge.readerReady, isTrue);
      expect(bridge.supports('restore'), isTrue);
      expect(serial.requests.single['cmd'], 'hello');
    },
  );
  test('a generic CH340 is not sufficient kit identification', () async {
    serial.validFirmware = false;
    await expectLater(
      bridge.connect('COM7'),
      throwsA(isA<DesktopRfidException>()),
    );
    expect(bridge.connected, isFalse);
    expect(serial.closeCount, greaterThan(0));
  });
  test('reader disconnected is different from serial disconnected', () async {
    serial.ready = false;
    await bridge.connect('COM7');
    expect(bridge.connected, isTrue);
    expect(bridge.readerReady, isFalse);
    await expectLater(bridge.scan(), throwsA(isA<DesktopRfidException>()));
    expect(serial.requests.where((e) => e['cmd'] == 'scan'), isEmpty);
  });
  test(
    'fragmented UTF8 NDJSON survives boot noise and ignores wrong IDs',
    () async {
      await bridge.connect('COM7');
      serial.autoReply = false;
      final future = bridge.scan();
      final request = serial.requests.last;
      serial.controller.add(Uint8List.fromList('ESP-ROM boot\r\n'.codeUnits));
      serial.emit({
        'v': 1,
        'id': 'wrong',
        'event': 'result',
        'uid': 'FFFFFFFF',
      });
      serial.emit({
        'v': 1,
        'id': request['id'],
        'event': 'progress',
        'state': 'verifying',
        'completed': 20,
      }, chunked: true);
      expect(bridge.completed, 20);
      serial.emit({
        'v': 1,
        'id': request['id'],
        'event': 'result',
        'uid': serial.uid,
        'technology': 'mifare_classic',
        'sizeBytes': 1024,
        'blockCount': 64,
        'uidLengthBytes': 4,
      }, chunked: true);
      expect((await future).uid, serial.uid);
    },
  );
  test('NTAG and incomplete scans cannot enter consumable inventory', () async {
    await bridge.connect('COM7');
    serial.scanOverride = {
      'uid': '12345678',
      'technology': 'ntag213',
      'sizeBytes': 144,
      'blockCount': 36,
      'uidLengthBytes': 4,
    };
    await expectLater(bridge.scan(), throwsA(isA<DesktopRfidException>()));
  });
  test('source template validates all local bytes', () async {
    await bridge.connect('COM7');
    expect((await bridge.readTemplate()).id, syntheticAmsTemplate().id);
  });
  test(
    'restore requires explicit risk confirmation and expected target UID',
    () async {
      await bridge.connect('COM7');
      await expectLater(
        bridge.restore(
          syntheticAmsTemplate(),
          targetKind: 'fuid',
          expectedUid: serial.uid,
          confirmed: false,
        ),
        throwsA(isA<DesktopRfidException>()),
      );
      expect(serial.requests.where((r) => r['cmd'] == 'restore'), isEmpty);
      await bridge.restore(
        syntheticAmsTemplate(),
        targetKind: 'fuid',
        expectedUid: serial.uid,
        confirmed: true,
      );
      final request = serial.requests.last;
      expect(request['expectedUid'], serial.uid);
      expect(request['allowUidChange'], true);
      expect(request['template'], syntheticAmsTemplate().toJson());
    },
  );
  test('63 verified blocks is not success', () async {
    await bridge.connect('COM7');
    serial.validVerification = false;
    await expectLater(
      bridge.restore(
        syntheticAmsTemplate(),
        targetKind: 'cuid',
        expectedUid: serial.uid,
        confirmed: true,
      ),
      throwsA(
        isA<DesktopRfidException>().having(
          (e) => e.mayHaveWritten,
          'partial write risk',
          true,
        ),
      ),
    );
  });
  test('one active operation rejects a second without sending it', () async {
    await bridge.connect('COM7');
    serial.autoReply = false;
    final first = bridge.scan();
    final assertion = expectLater(first, throwsA(isA<DesktopRfidException>()));
    await expectLater(bridge.scan(), throwsA(isA<DesktopRfidException>()));
    expect(serial.requests.where((e) => e['cmd'] == 'scan'), hasLength(1));
    await bridge.cancel();
    await assertion;
    expect(bridge.connected, isFalse);
  });
  test(
    'cancel ignores late successful reply and closes uncertain link',
    () async {
      await bridge.connect('COM7');
      serial.autoReply = false;
      final first = bridge.scan();
      final assertion = expectLater(
        first,
        throwsA(isA<DesktopRfidException>()),
      );
      final request = serial.requests.last;
      serial.handle = (r) {
        if (r['cmd'] == 'cancel') {
          serial.result(request, {
            'uid': serial.uid,
            'technology': 'mifare_classic',
            'sizeBytes': 1024,
            'blockCount': 64,
            'uidLengthBytes': 4,
          });
          serial.result(r, {});
        }
      };
      await bridge.cancel();
      await assertion;
      expect(bridge.connected, isFalse);
    },
  );
  test(
    'unplug settles pending operation and cannot accept stale result',
    () async {
      await bridge.connect('COM7');
      serial.autoReply = false;
      final first = bridge.scan();
      final assertion = expectLater(
        first,
        throwsA(isA<DesktopRfidException>()),
      );
      serial.controller.addError(StateError('unplug'));
      await assertion;
      expect(bridge.connected, isFalse);
    },
  );
  test('overlong frame is bounded and disconnects', () async {
    await bridge.connect('COM7');
    serial.autoReply = false;
    final first = bridge.scan();
    final assertion = expectLater(first, throwsA(isA<DesktopRfidException>()));
    serial.controller.add(Uint8List(8193));
    await assertion;
    expect(bridge.connected, isFalse);
  });
  test('timeout ends once and never retries a write automatically', () async {
    bridge.dispose();
    bridge = DesktopRfidBridge(
      transport: serial,
      restoreTimeout: const Duration(milliseconds: 30),
    );
    await bridge.connect('COM7');
    serial.autoReply = false;
    await expectLater(
      bridge.restore(
        syntheticAmsTemplate(),
        targetKind: 'fuid',
        expectedUid: serial.uid,
        confirmed: true,
      ),
      throwsA(isA<DesktopRfidException>()),
    );
    expect(serial.requests.where((r) => r['cmd'] == 'restore'), hasLength(1));
    expect(bridge.connected, isFalse);
  });
  test('device errors never expose raw keys or vendor dump text', () async {
    await bridge.connect('COM7');
    serial.autoReply = false;
    final result = bridge.scan();
    final assertion = expectLater(
      result,
      throwsA(
        isA<DesktopRfidException>().having(
          (e) => e.message,
          'safe message',
          isNot(contains('SECRET')),
        ),
      ),
    );
    serial.emit({
      'v': 1,
      'id': serial.requests.last['id'],
      'event': 'error',
      'code': 'AUTH_FAILED',
      'message': 'SECRET_KEY_RAW_DUMP',
    });
    await assertion;
  });
  testWidgets('heartbeat detects silent device and does not hold a dead link', (
    tester,
  ) async {
    bridge.dispose();
    bridge = DesktopRfidBridge(
      transport: serial,
      now: tester.binding.clock.now,
    );
    await bridge.connect('COM7');
    serial.heartbeat = false;
    await tester.pump(const Duration(seconds: 9));
    expect(bridge.connected, isFalse);
  });

  testWidgets(
    'heartbeat updates reader readiness without confusing it with USB',
    (tester) async {
      bridge.dispose();
      bridge = DesktopRfidBridge(
        transport: serial,
        now: tester.binding.clock.now,
      );
      await bridge.connect('COM7');
      serial.ready = false;
      await tester.pump(const Duration(seconds: 2));
      expect(bridge.connected, isTrue);
      expect(bridge.readerReady, isFalse);
      expect(bridge.state, 'reader_missing');
      expect(bridge.connectionMessage, contains('RC522'));
      await expectLater(bridge.scan(), throwsA(isA<DesktopRfidException>()));
      expect(serial.requests.where((r) => r['cmd'] == 'scan'), isEmpty);

      serial.ready = true;
      await tester.pump(const Duration(seconds: 2));
      expect(bridge.readerReady, isTrue);
      expect(bridge.state, 'ready');
      expect(bridge.connectionMessage, isNull);
      await bridge.disconnect();
    },
  );

  testWidgets(
    'reader loss during restore rejects late success with write uncertainty',
    (tester) async {
      bridge.dispose();
      bridge = DesktopRfidBridge(
        transport: serial,
        now: tester.binding.clock.now,
      );
      await bridge.connect('COM7');
      serial.autoReply = false;
      final write = bridge.restore(
        syntheticAmsTemplate(),
        targetKind: 'fuid',
        expectedUid: serial.uid,
        confirmed: true,
      );
      final request = serial.requests.last;
      final assertion = expectLater(
        write,
        throwsA(
          isA<DesktopRfidException>().having(
            (e) => e.mayHaveWritten,
            'partial write is possible',
            isTrue,
          ),
        ),
      );
      serial.ready = false;
      await tester.pump(const Duration(seconds: 2));
      await assertion;
      serial.result(request, {
        'uid': syntheticAmsTemplate().uid,
        'tagType': 'fuid',
        'templateId': syntheticAmsTemplate().id,
        'verified': true,
        'blocksVerified': 64,
        'amsCompatibility': 'template_restored_unverified',
      });
      expect(bridge.connected, isFalse);
      expect(bridge.readerReady, isFalse);
      expect(bridge.state, 'disconnected');
      expect(serial.requests.where((r) => r['cmd'] == 'restore'), hasLength(1));
    },
  );
}
