import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:consumable_tracker_desktop/features/rfid/desktop_serial_transport.dart';
import 'package:consumable_tracker_desktop/features/rfid/desktop_rfid_controller.dart';
import 'package:consumable_tracker_desktop/mobile/ams_tag_template.dart';
import 'package:consumable_tracker_desktop/mobile/ams_template_repository.dart';

import 'ams_template_fixture.dart';

class FakeDesktopSerial implements DesktopSerialTransport {
  final controller = StreamController<Uint8List>.broadcast(sync: true);
  final requests = <Map<String, dynamic>>[];
  int openCount = 0, closeCount = 0;
  String uid = 'D021B75E';
  bool ready = true;
  bool validFirmware = true;
  bool autoReply = true;
  bool validVerification = true;
  bool heartbeat = true;
  Map<String, Object>? scanOverride;
  void Function(Map<String, dynamic>)? handle;
  @override
  Stream<Uint8List> get bytes => controller.stream;
  @override
  Future<List<DesktopSerialPort>> listPorts() async => const [
    DesktopSerialPort(
      'COM7',
      'USB-SERIAL CH340 (COM7)',
      hardwareId: 'USB\\VID_1A86&PID_7523',
    ),
  ];
  @override
  Future<void> open(String port) async {
    openCount++;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final request = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    requests.add(request);
    if (handle != null) {
      handle!(request);
      return;
    }
    if (request['cmd'] == 'hello' && heartbeat) {
      result(request, {
        'device': validFirmware ? 'sohun-rfid-bridge' : 'unknown',
        'protocol': 1,
        'readerReady': ready,
        'readerVersion': 0x92,
        'firmware': '0.1.0',
        'deviceId': 'test-kit',
        'capabilities': ['scan', 'read_template', 'restore'],
      });
    } else if (request['cmd'] == 'scan' && autoReply) {
      result(
        request,
        scanOverride ??
            {
              'uid': uid,
              'technology': 'mifare_classic',
              'sizeBytes': 1024,
              'blockCount': 64,
              'sectorCount': 16,
              'uidLengthBytes': 4,
              'defaultKeyReadable': true,
            },
      );
    } else if (request['cmd'] == 'read_template' && autoReply) {
      result(request, {'template': syntheticAmsTemplate().toJson()});
    } else if (request['cmd'] == 'restore' && autoReply) {
      final template = request['template'] as Map;
      result(request, {
        'uid': template['uid'] as String,
        'tagType': request['targetKind'] as String,
        'templateId': template['id'] as String,
        'blocksVerified': validVerification ? 64 : 63,
        'verified': true,
        'amsCompatibility': 'template_restored_unverified',
      });
    } else if (request['cmd'] == 'cancel') {
      result(request, {});
    }
  }

  void result(Map<String, dynamic> request, Map<String, Object> result) =>
      emit({'v': 1, 'id': request['id'], 'event': 'result', ...result});
  void emit(Map<String, Object?> event, {bool chunked = false}) {
    final bytes = Uint8List.fromList(utf8.encode('${jsonEncode(event)}\n'));
    if (chunked) {
      for (final byte in bytes) {
        controller.add(Uint8List.fromList([byte]));
      }
    } else {
      controller.add(bytes);
    }
  }
}

class MemoryRfidJournal implements DesktopRfidJournal {
  final Map<String, List<Map<String, Object>>> stored = {};
  bool fail = false;
  @override
  Future<List<DesktopRfidQueueItem>> load(String owner) async {
    if (fail) throw StateError('test disk failure');
    return [
      for (final item in stored[owner] ?? [])
        DesktopRfidQueueItem.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  @override
  Future<void> save(String owner, List<DesktopRfidQueueItem> items) async {
    if (fail) throw StateError('test disk failure');
    stored[owner] = items.map((i) => i.toJson()).toList();
  }
}

class MemoryDesktopTemplates extends AmsTemplateRepository {
  final templates = <AmsTagTemplate>[];
  @override
  Future<List<AmsTagTemplate>> list({required String ownerAccount}) async =>
      templates;
  @override
  Future<AmsTagTemplate?> read(
    String id, {
    required String ownerAccount,
  }) async {
    for (final template in templates) {
      if (template.id == id) return template;
    }
    return null;
  }

  @override
  Future<void> save(
    AmsTagTemplate template, {
    required String ownerAccount,
  }) async {
    templates.add(template);
  }

  @override
  Future<void> delete(String id, {required String ownerAccount}) async {
    templates.removeWhere((t) => t.id == id);
  }
}
