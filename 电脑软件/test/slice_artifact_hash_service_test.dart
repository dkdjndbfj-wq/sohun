import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:consumable_tracker_desktop/core/services/slice_artifact_hash_service.dart';

void main() {
  test('稳定文件使用流式 SHA-256 生成内容身份', () async {
    final dir = await Directory.systemTemp.createTemp('artifact_hash_test_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/sample.gcode');
    await file.writeAsString('abc');

    final identity = await SliceArtifactHashService.computeStable(file.path);

    expect(identity, isNotNull);
    expect(
      identity!.sha256Hex,
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(identity.size, 3);
  });

  test('空文件不生成最终身份', () async {
    final dir = await Directory.systemTemp.createTemp('artifact_hash_test_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/empty.gcode');
    await file.writeAsBytes(const []);

    expect(await SliceArtifactHashService.computeStable(file.path), isNull);
  });
}
