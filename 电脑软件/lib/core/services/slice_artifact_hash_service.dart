import 'dart:io';

import 'package:crypto/crypto.dart';

/// 已稳定切片产物的内容身份。
class SliceArtifactIdentity {
  final String sha256Hex;
  final int size;
  final DateTime modifiedAt;

  const SliceArtifactIdentity({
    required this.sha256Hex,
    required this.size,
    required this.modifiedAt,
  });
}

/// 以流式方式计算 G-code/3MF 的 SHA-256，并拒绝半写入文件。
class SliceArtifactHashService {
  SliceArtifactHashService._();

  static Future<SliceArtifactIdentity?> computeStable(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;

    final before = await file.stat();
    if (before.size <= 0) return null;

    final digest = await sha256.bind(file.openRead()).first;
    final after = await file.stat();
    if (before.size != after.size ||
        before.modified.millisecondsSinceEpoch !=
            after.modified.millisecondsSinceEpoch) {
      return null;
    }

    return SliceArtifactIdentity(
      sha256Hex: digest.toString(),
      size: after.size,
      modifiedAt: after.modified,
    );
  }
}
