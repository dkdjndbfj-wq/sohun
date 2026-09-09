import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/production_package_inspector.dart';
import 'package:consumable_tracker_desktop/features/project_orders/personal_plate_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sohun-personal-plate-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('只读取盘缩略图，不需要展开模型网格', () async {
    final file = await _writeSourcePackage(temp);

    final thumbnails = await PersonalPlateEditorStore.readPlateThumbnails(
      file.path,
      plateIndexes: [1, 2],
    );

    expect(thumbnails.keys, containsAll(<int>[1, 2]));
    // The full-size image wins when both variants are present.
    expect(thumbnails[1], orderedEquals(<int>[1, 2, 3]));
    expect(thumbnails[2], orderedEquals(<int>[4, 5]));
  });

  test('使用 build item 的盘面变换读取对象位置和旋转', () async {
    final file = await _writeSourcePackage(temp);

    final document = await PersonalPlateEditorStore.load(
      sourcePath: file.path,
      plateIndex: 1,
      fallbackParts: const <ProductionPartInspection>[],
    );

    expect(document.models, hasLength(2));
    final first = document.models.firstWhere((model) => model.id == '1');
    expect(first.name, '外壳');
    expect(first.x, closeTo(50, .001));
    expect(first.y, closeTo(60, .001));
    expect(first.rotation, closeTo(1.570796, .00001));
  });

  test('布局 sidecar 可以保存并恢复', () async {
    final file = await _writeSourcePackage(temp);
    final original = await PersonalPlateEditorStore.load(
      sourcePath: file.path,
      plateIndex: 1,
      fallbackParts: const <ProductionPartInspection>[],
    );
    final edited = PersonalPlateEditorDocument(
      sourcePath: original.sourcePath,
      plateIndex: original.plateIndex,
      models: [original.models.first.copyWith(x: 123, scale: 1.4)],
    );

    final sidecarPath = await PersonalPlateEditorStore.save(edited);
    expect(sidecarPath, isNotNull);

    final restored = await PersonalPlateEditorStore.load(
      sourcePath: file.path,
      plateIndex: 1,
      fallbackParts: const <ProductionPartInspection>[],
    );
    expect(restored.restored, isTrue);
    expect(restored.models.single.x, closeTo(123, .001));
    expect(restored.models.single.scale, closeTo(1.4, .001));
  });
}

Future<File> _writeSourcePackage(Directory temp) async {
  final archive = Archive()
    ..addFile(_textFile('Metadata/model_settings.config', '''
<config>
  <object id="1"><metadata key="name" value="外壳"/></object>
  <object id="2"><metadata key="name" value="底座"/></object>
  <plate>
    <metadata key="plater_id" value="1"/>
    <model_instance><metadata key="object_id" value="1"/></model_instance>
    <model_instance><metadata key="object_id" value="2"/></model_instance>
  </plate>
</config>
'''))
    ..addFile(_textFile('3D/3dmodel.model', '''
<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
  <build>
    <item objectid="1" transform="0 -1 0 1 0 0 0 0 0 50 60 0"/>
    <item objectid="2" transform="1 0 0 0 1 0 0 0 1 180 190 0"/>
  </build>
</model>
'''))
    ..addFile(ArchiveFile('Metadata/plate_1.png', 3, [1, 2, 3]))
    ..addFile(ArchiveFile('Metadata/plate_1_small.png', 2, [9, 9]))
    ..addFile(ArchiveFile('Metadata/plate_2_small.png', 2, [4, 5]));
  final file = File('${temp.path}${Platform.pathSeparator}source.3mf');
  await file.writeAsBytes(ZipEncoder().encode(archive)!);
  return file;
}

ArchiveFile _textFile(String path, String value) {
  final bytes = utf8.encode(value);
  return ArchiveFile(path, bytes.length, bytes);
}
