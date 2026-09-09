import 'dart:convert';
import 'dart:typed_data';

import 'package:consumable_tracker_desktop/mobile/ams_tag_template.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Entirely synthetic: no vendor dump, real keys, or real signature fixtures.
Uint8List syntheticAmsDump() {
  final bytes = Uint8List(1024);
  bytes.setRange(0, 5, [0x12, 0x34, 0x56, 0x78, 0x08]);
  bytes.setRange(32, 35, ascii.encode('PLA'));
  bytes.setRange(64, 73, ascii.encode('PLA Basic'));
  bytes.setRange(80, 86, [0x11, 0x22, 0x33, 0xff, 0xe8, 0x03]);
  bytes.setRange(144, 160, List<int>.generate(16, (i) => i + 1));
  for (var sector = 0; sector < 16; sector++) {
    final offset = (sector * 4 + 3) * 16;
    bytes.setRange(offset, offset + 16, [
      1,
      2,
      3,
      4,
      5,
      6,
      0xff,
      0x07,
      0x80,
      0x69,
      6,
      5,
      4,
      3,
      2,
      1,
    ]);
  }
  for (var block = 40; block < 64; block++) {
    if (block % 4 != 3) {
      bytes.setRange(
        block * 16,
        block * 16 + 16,
        List<int>.generate(16, (i) => block + i),
      );
    }
  }
  return bytes;
}

void main() {
  test('parses immutable full image and read-only source metadata', () {
    final bytes = syntheticAmsDump();
    final expectedId = sha256.convert(bytes).toString();
    final template = AmsTagTemplate.fromBytes(bytes, name: ' 原始模板 ');
    expect(template.id, expectedId);
    expect(template.uid, '12345678');
    expect(template.name, '原始模板');
    expect(template.trayIdentity, '0102030405060708090A0B0C0D0E0F10');
    expect(template.trayIdentityAscii, isEmpty);
    expect(template.material, 'PLA Basic');
    expect(template.colorHex, '#112233');
    expect(template.weightGrams, 1000);
    expect(template.signatureVerified, isFalse);
    bytes.fillRange(0, 1024, 0);
    final exported = template.toBytes()..fillRange(0, 1024, 0);
    expect(exported[0], 0);
    expect(template.uid, '12345678');
    expect(template.toBytes()[0], 0x12);
    expect(() => template.blocks[0] = 'changed', throwsUnsupportedError);
    expect(template.toString(), 'AmsTagTemplate(redacted)');
  });

  test('canonical JSON roundtrip ignores untrusted display metadata', () {
    final source = AmsTagTemplate.fromBytes(syntheticAmsDump());
    final json = {
      ...source.toJson(),
      'material': 'Injected',
      'colorHex': '#FFFFFF',
      'signatureVerified': true,
    };
    final imported = AmsTagTemplate.fromJson(json);
    expect(imported.id, source.id);
    expect(imported.material, 'PLA Basic');
    expect(imported.colorHex, '#112233');
    expect(imported.signatureVerified, isFalse);
    expect(imported.toJson().containsKey('signatureVerified'), isFalse);
  });

  test('detects short dumps, malformed block lengths, UID and BCC changes', () {
    expect(
      () => AmsTagTemplate.fromBytes(Uint8List(1000)),
      throwsFormatException,
    );
    final bcc = syntheticAmsDump()..[4] = 0;
    expect(() => AmsTagTemplate.fromBytes(bcc), throwsFormatException);
    final json = AmsTagTemplate.fromBytes(syntheticAmsDump()).toJson();
    expect(
      () => AmsTagTemplate.fromJson({...json, 'uid': 'DEADBEEF'}),
      throwsFormatException,
    );
    expect(
      () => AmsTagTemplate.fromJson({...json, 'version': 2}),
      throwsFormatException,
    );
    expect(
      () => AmsTagTemplate.fromJson({...json, 'id': '0' * 64}),
      throwsFormatException,
    );
    final blocks = List<String>.from(json['blocks']! as List)..[10] = '?' * 32;
    expect(
      () => AmsTagTemplate.fromJson({...json, 'blocks': blocks}),
      throwsFormatException,
    );
  });

  test(
    'validates every access complement and excludes trailers from signature check',
    () {
      for (var byteOffset = 6; byteOffset < 9; byteOffset++) {
        final bytes = syntheticAmsDump();
        bytes[63 * 16 + byteOffset] ^= 1;
        expect(() => AmsTagTemplate.fromBytes(bytes), throwsFormatException);
      }
      for (final blank in [0, 255]) {
        final bytes = syntheticAmsDump();
        for (var block = 40; block < 64; block++) {
          if (block % 4 != 3) {
            bytes.fillRange(block * 16, block * 16 + 16, blank);
          }
        }
        expect(() => AmsTagTemplate.fromBytes(bytes), throwsFormatException);
      }
      final missingIdentity = syntheticAmsDump()..fillRange(144, 160, 0);
      expect(
        () => AmsTagTemplate.fromBytes(missingIdentity),
        throwsFormatException,
      );
    },
  );

  test(
    'supports binary, plain 64-line TXT, MCT, and canonical JSON imports',
    () {
      final bytes = syntheticAmsDump();
      final original = AmsTagTemplate.fromBytes(bytes);
      final text = original.blocks.join('\r\n');
      final mct = [
        for (var sector = 0; sector < 16; sector++) ...[
          '+Sector: $sector',
          ...original.blocks.skip(sector * 4).take(4),
        ],
      ].join('\n');
      for (final payload in [
        bytes,
        Uint8List.fromList(utf8.encode(text)),
        Uint8List.fromList(utf8.encode(mct)),
        Uint8List.fromList(utf8.encode(jsonEncode(original.toJson()))),
      ]) {
        expect(AmsTagTemplate.importBytes(payload).id, original.id);
      }
      expect(
        AmsTagTemplate.importBytes(
          bytes,
          fileName: r'C:\private\我的原始模板.bin',
        ).name,
        '我的原始模板',
      );
      expect(
        () => AmsTagTemplate.importBytes(
          Uint8List.fromList(
            utf8.encode(mct.replaceFirst('+Sector: 2', '+Sector: 3')),
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => AmsTagTemplate.importBytes(
          Uint8List.fromList(
            utf8.encode(text.split('\r\n').take(63).join('\n')),
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'imports documented upstream raw payload and rejects key contradictions',
    () {
      final original = AmsTagTemplate.fromBytes(syntheticAmsDump());
      final keys = [
        for (var sector = 0; sector < 16; sector++)
          {
            'a': original.blocks[sector * 4 + 3].substring(0, 12).toLowerCase(),
            'b': original.blocks[sector * 4 + 3].substring(20).toLowerCase(),
          },
      ];
      final upstream = <String, dynamic>{
        'brand': 'bambu',
        'uid': original.uid,
        'blocks': original.blocks.map((b) => b.toLowerCase()).toList(),
        'keys': keys,
        'device_id': 'must-not-be-persisted',
      };
      final imported = AmsTagTemplate.fromJson(upstream);
      expect(imported.id, original.id);
      expect(imported.toJson().containsKey('device_id'), isFalse);
      keys[4]['a'] = '0' * 12;
      expect(() => AmsTagTemplate.fromJson(upstream), throwsFormatException);
      expect(
        () => AmsTagTemplate.fromJson({...upstream, 'brand': 'snapmaker'}),
        throwsFormatException,
      );
    },
  );

  test(
    'bounds imports and never includes sensitive source in parser errors',
    () {
      expect(
        () => AmsTagTemplate.importBytes(
          Uint8List(AmsTagTemplate.maxImportBytes + 1),
        ),
        throwsFormatException,
      );
      const secret = '{"blocks": ["SECRET-DUMP-KEYS",';
      try {
        AmsTagTemplate.importBytes(Uint8List.fromList(utf8.encode(secret)));
        fail('Expected invalid JSON to be rejected');
      } on FormatException catch (error) {
        expect(error.source, isNull);
        expect(error.toString().contains('SECRET-DUMP-KEYS'), isFalse);
      }
    },
  );
}
