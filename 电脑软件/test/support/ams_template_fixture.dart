import 'dart:convert';
import 'dart:typed_data';

import 'package:consumable_tracker_desktop/mobile/ams_tag_template.dart';

/// Structurally valid, deliberately fake signature. Never a usable AMS dump.
AmsTagTemplate syntheticAmsTemplate() {
  final bytes = Uint8List(1024);
  bytes.setRange(0, 5, [1, 2, 3, 4, 4]);
  bytes.setRange(64, 73, ascii.encode('TEST ONLY'));
  bytes.setRange(80, 86, [0x12, 0xAB, 0x34, 0xFF, 0xE8, 3]);
  bytes[144] = 1;
  bytes[640] = 1;
  for (var sector = 0; sector < 16; sector++) {
    final offset = (sector * 4 + 3) * 16;
    bytes.fillRange(offset, offset + 6, 0xFF);
    bytes.setRange(offset + 6, offset + 10, [0xFF, 0x07, 0x80, 0x69]);
    bytes.fillRange(offset + 10, offset + 16, 0xFF);
  }
  return AmsTagTemplate.fromBytes(bytes, name: '测试模板（假签名）');
}
