import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A complete, immutable MIFARE Classic 1K image supplied by the user.
///
/// Structural validation is NOT RSA verification and does not prove AMS
/// acceptance. Never modify signed blocks to insert third-party metadata.
/// This object contains secrets: do not log it or send [toJson] to cloud APIs.
class AmsTagTemplate {
  static const format = 'sohun.ams-template';
  static const version = 1;
  static const byteLength = 1024;
  static const maxImportBytes = 65536;

  final Uint8List _bytes;
  final String id;
  final String uid;
  final String name;
  final List<String> blocks;

  AmsTagTemplate._(Uint8List bytes, this.name)
    : _bytes = bytes.asUnmodifiableView(),
      id = sha256.convert(bytes).toString(),
      uid = _hex(bytes.sublist(0, 4)),
      blocks = List<String>.unmodifiable([
        for (var i = 0; i < 64; i++) _hex(bytes.sublist(i * 16, i * 16 + 16)),
      ]);

  factory AmsTagTemplate.fromBytes(Uint8List bytes, {String? name}) {
    if (bytes.length != byteLength) {
      throw const FormatException('需要完整的 1024 字节 MIFARE Classic 1K 模板。');
    }
    final copy = Uint8List.fromList(bytes);
    if (copy.take(4).every((b) => b == 0) ||
        copy.take(4).every((b) => b == 255)) {
      throw const FormatException('模板中的标签 UID 无效。');
    }
    if ((copy[0] ^ copy[1] ^ copy[2] ^ copy[3]) != copy[4]) {
      throw const FormatException('模板的 UID 与 BCC 校验不一致。');
    }
    for (var sector = 0; sector < 16; sector++) {
      final offset = (sector * 4 + 3) * 16;
      final b6 = copy[offset + 6];
      final b7 = copy[offset + 7];
      final b8 = copy[offset + 8];
      if (((b6 & 15) ^ (b7 >> 4)) != 15 ||
          ((b6 >> 4) ^ (b8 & 15)) != 15 ||
          ((b7 & 15) ^ (b8 >> 4)) != 15) {
        throw FormatException('第 $sector 扇区的访问控制位损坏。');
      }
    }
    // Sectors 10..15 hold the signature; trailers are not signature bytes.
    final signature = <int>[
      for (var block = 40; block < 64; block++)
        if (block % 4 != 3) ...copy.sublist(block * 16, block * 16 + 16),
    ];
    if (signature.every((b) => b == 0) || signature.every((b) => b == 255)) {
      throw const FormatException('模板缺少完整签名区域，不能用空白数据代替。');
    }
    if (copy.sublist(9 * 16, 10 * 16).every((b) => b == 0)) {
      throw const FormatException('模板缺少耗材身份，无法建立 AMS 库存映射。');
    }
    final label = name?.trim();
    if (label != null &&
        (label.length > 80 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(label))) {
      throw const FormatException('模板名称不可包含控制字符，且最多 80 个字符。');
    }
    return AmsTagTemplate._(
      copy,
      label == null || label.isEmpty
          ? '兼容标签 ${_hex(copy.sublist(0, 4))}'
          : label,
    );
  }

  /// Reads our canonical JSON or the upstream raw-tag JSON payload shape.
  ///
  /// Upstream sources: NfcTagProcessor.kt (block 9 is encoded as hex),
  /// TagShareUploader.kt::buildRawPayload (uid/blocks/keys[a,b]/brand).
  /// Its current file-package exporter writes 64-line hex TXT files in ZIP;
  /// ZIP/database/network downloads are deliberately not handled here.
  factory AmsTagTemplate.fromJson(Map<String, dynamic> json) {
    final canonical = json['format'] == format;
    if (json.containsKey('format') && !canonical) {
      throw const FormatException('不支持的模板格式。');
    }
    if (canonical && json['version'] != version) {
      throw const FormatException('不支持的模板版本。');
    }
    if (!canonical &&
        (json['brand'] is! String ||
            (json['brand'] as String).toLowerCase() != 'bambu' ||
            json['keys'] is! List)) {
      throw const FormatException('请选择 Sohun 模板或完整的 Bambu 标签数据。');
    }
    final uidValue = json['uid'];
    if (uidValue is! String ||
        !RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(uidValue)) {
      throw const FormatException('模板必须包含 4 字节 UID。');
    }
    final values = json['blocks'];
    if (values is! List || values.length != 64) {
      throw const FormatException('模板必须包含完整的 64 个区块。');
    }
    final bytes = Uint8List(byteLength);
    for (var index = 0; index < values.length; index++) {
      final value = values[index];
      if (value is! String || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(value)) {
        throw FormatException('第 $index 个区块缺失或格式不正确。');
      }
      bytes.setRange(index * 16, index * 16 + 16, _decodeHex(value));
    }
    if (uidValue.toUpperCase() != _hex(bytes.sublist(0, 4))) {
      throw const FormatException('模板 UID 与制造商区块不一致。');
    }
    if (json['keys'] != null) {
      final keys = json['keys'];
      if (keys is! List || keys.length != 16) {
        throw const FormatException('模板必须包含全部 16 个扇区的密钥。');
      }
      for (var sector = 0; sector < 16; sector++) {
        final key = keys[sector];
        final offset = (sector * 4 + 3) * 16;
        if (key is! Map ||
            key['a'] is! String ||
            key['b'] is! String ||
            (key['a'] as String).toUpperCase() !=
                _hex(bytes.sublist(offset, offset + 6)) ||
            (key['b'] as String).toUpperCase() !=
                _hex(bytes.sublist(offset + 10, offset + 16))) {
          throw FormatException('第 $sector 扇区的密钥与完整区块不一致。');
        }
      }
    }
    final nameValue = json['name'];
    if (nameValue != null && nameValue is! String) {
      throw const FormatException('模板名称格式不正确。');
    }
    final result = AmsTagTemplate.fromBytes(bytes, name: nameValue as String?);
    if (json['id'] != null && json['id'] != result.id) {
      throw const FormatException('模板内容摘要不一致。');
    }
    return result;
  }

  factory AmsTagTemplate.importBytes(Uint8List bytes, {String? fileName}) {
    if (bytes.isEmpty || bytes.length > maxImportBytes) {
      throw const FormatException('模板文件为空或超过 64 KB。');
    }
    String? label;
    if (fileName != null) {
      label = fileName
          .split(RegExp(r'[/\\]'))
          .last
          .replaceFirst(RegExp(r'\.[^.]+$'), '');
      if (label.length > 80) label = label.substring(0, 80);
    }
    if (bytes.length == byteLength) {
      return AmsTagTemplate.fromBytes(bytes, name: label);
    }
    String content;
    try {
      content = utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '').trim();
    } on FormatException {
      throw const FormatException('无法解析模板，请选择 BIN、MFD、MCT、TXT 或 JSON 文件。');
    }
    if (content.startsWith('{')) {
      Object? decoded;
      try {
        decoded = jsonDecode(content);
      } on FormatException {
        // Never expose FormatException.source: it may contain keys/raw blocks.
        throw const FormatException('模板 JSON 格式损坏。');
      }
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('模板 JSON 必须是一个对象。');
      }
      final result = AmsTagTemplate.fromJson(decoded);
      return decoded['name'] == null && label != null
          ? AmsTagTemplate.fromBytes(result._bytes, name: label)
          : result;
    }
    final blocks = <int>[];
    var expectedSector = 0;
    var hasSectorHeaders = false;
    for (final rawLine in const LineSplitter().convert(content)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      final sectorHeader = RegExp(
        r'^\+Sector:\s*(\d+)$',
        caseSensitive: false,
      ).firstMatch(line);
      if (sectorHeader != null) {
        hasSectorHeaders = true;
        final sector = int.parse(sectorHeader.group(1)!);
        if (sector != expectedSector ||
            blocks.length != sector * 64 ||
            sector > 15) {
          throw const FormatException('MCT 扇区顺序错误或区块缺失。');
        }
        expectedSector++;
        continue;
      }
      final hex = line.replaceAll(RegExp(r'\s'), '');
      if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) {
        throw const FormatException('模板包含未知或不完整的区块，不能用于克隆。');
      }
      blocks.addAll(_decodeHex(hex));
      if (blocks.length > byteLength) {
        throw const FormatException('这里只支持完整的 MIFARE Classic 1K 模板。');
      }
    }
    if (hasSectorHeaders && expectedSector != 16) {
      throw const FormatException('MCT 文件缺少完整扇区。');
    }
    return AmsTagTemplate.fromBytes(Uint8List.fromList(blocks), name: label);
  }

  /// The identity used by AMS tray_uuid: 16 raw bytes, uppercase hex.
  String get trayIdentity => blocks[9];
  String get trayIdentityAscii => _asciiBlock(9);
  String get material =>
      _asciiBlock(4).isNotEmpty ? _asciiBlock(4) : _asciiBlock(2);
  String get colorHex => '#${blocks[5].substring(0, 6)}';
  int get weightGrams => _bytes[84] | (_bytes[85] << 8);
  bool get signatureVerified => false;

  Uint8List toBytes() => Uint8List.fromList(_bytes);

  Map<String, Object> toJson() => {
    'format': format,
    'version': version,
    'id': id,
    'uid': uid,
    'name': name,
    'blocks': blocks,
  };

  String _asciiBlock(int block) {
    final source = _bytes.sublist(block * 16, block * 16 + 16);
    final end = source.indexOf(0);
    final value = end < 0 ? source : source.sublist(0, end);
    return value.every((b) => b >= 32 && b <= 126)
        ? ascii.decode(value).trim()
        : '';
  }

  @override
  String toString() => 'AmsTagTemplate(redacted)';

  static String _hex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  static List<int> _decodeHex(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}
