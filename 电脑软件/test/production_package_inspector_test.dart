import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/production_package_inspector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sohun-production-inspector-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('多盘切片按模型实例计数，不把多材质组件误算为多个成品', () async {
    final file = File('${temp.path}${Platform.pathSeparator}farm-job.3mf');
    final archive = Archive()
      ..addFile(
        _textFile('Metadata/model_settings.config', '''
<config>
  <object id="1">
    <metadata key="name" value="三色徽章"/>
    <part id="11"><metadata key="name" value="红色组件"/><metadata key="source_file" value="badge.step"/><metadata key="source_object_id" value="1"/></part>
    <part id="12"><metadata key="name" value="白色组件"/><metadata key="source_file" value="badge.step"/><metadata key="source_object_id" value="1"/></part>
  </object>
  <object id="2"><metadata key="name" value="底座"/><part id="21"><metadata key="source_file" value="base.stl"/><metadata key="source_object_id" value="1"/></part></object>
  <plate><metadata key="plater_id" value="1"/><metadata key="plater_name" value="徽章盘"/><model_instance><metadata key="object_id" value="1"/></model_instance><model_instance><metadata key="object_id" value="1"/></model_instance></plate>
  <plate><metadata key="plater_id" value="2"/><metadata key="plater_name" value="底座盘"/><model_instance><metadata key="object_id" value="2"/></model_instance></plate>
</config>
'''),
      )
      ..addFile(
        _textFile('Metadata/slice_info.config', '''
<config><header><header_item key="X-BBL-Client-Version" value="02.07.01.57"/></header>
<plate><metadata key="index" value="1"/><metadata key="prediction" value="3600"/><metadata key="layer_num" value="120"/><filament id="1" used_g="24.5" type="PLA" color="#FF0000"/></plate>
<plate><metadata key="index" value="2"/><metadata key="prediction" value="1800"/><metadata key="layer_num" value="80"/><filament id="1" used_g="12.0" type="PETG" color="#FFFFFF"/></plate>
</config>
'''),
      )
      ..addFile(
        _textFile(
          'Metadata/project_settings.config',
          jsonEncode({
            'printer_model': 'Bambu Lab A1',
            'nozzle_diameter': ['0.4'],
            'print_settings_id': '0.20mm Standard @BBL A1',
            'filament_settings_id': ['Bambu PLA Basic @BBL A1'],
            'filament_vendor': ['Bambu Lab'],
            'filament_type': ['PLA'],
            'version': '02.07.01.57',
          }),
        ),
      )
      ..addFile(_textFile('Metadata/plate_1.gcode', '; plate 1'))
      ..addFile(_textFile('Metadata/plate_2.gcode', '; plate 2'));
    await file.writeAsBytes(ZipEncoder().encode(archive)!);

    final result = await ProductionPackageInspector.inspect(file.path);

    expect(result, isNotNull);
    expect(result!.isUsable, isTrue);
    expect(result.plates, hasLength(2));
    expect(result.targetModel, 'Bambu Lab A1');
    expect(result.nozzleDiameter, 0.4);
    expect(result.declaredFilamentCount, 1);
    expect(result.hasEmbeddedSettings, isTrue);
    expect(result.slicerVersion, '02.07.01.57');
    expect(result.plates[0].parts, hasLength(1));
    expect(result.plates[0].parts.single.name, '三色徽章');
    expect(result.plates[0].parts.single.instancesPerRun, 2);
    expect(result.plates[0].parts.single.componentNames, hasLength(2));
    expect(result.plates[0].estimatedGrams, 24.5);
    expect(result.plates[0].filaments.single.vendor, 'Bambu Lab');
    expect(result.plates[0].filaments.single.materialType, 'PLA Basic');
    expect(result.plates[1].parts.single.name, '底座');
  });

  test('未切片的 Bambu 3MF 仍读取模型实例并进入待切片阶段', () async {
    final file = File('${temp.path}${Platform.pathSeparator}project-only.3mf');
    final archive = Archive()
      ..addFile(
        _textFile('Metadata/model_settings.config', '''
<config><object id="1"><metadata key="name" value="测试件"/></object><plate><metadata key="plater_id" value="1"/><model_instance><metadata key="object_id" value="1"/></model_instance></plate></config>
'''),
      )
      ..addFile(
        _textFile(
          'Metadata/project_settings.config',
          jsonEncode({
            'printer_model': 'Bambu Lab A1',
            'nozzle_diameter': ['0.4'],
            'print_settings_id': '0.20mm Standard @BBL A1',
            'filament_settings_id': ['Bambu PLA Basic @BBL A1'],
          }),
        ),
      );
    await file.writeAsBytes(ZipEncoder().encode(archive)!);

    final result = await ProductionPackageInspector.inspect(file.path);

    expect(result, isNotNull);
    expect(result!.isSliced, isFalse);
    expect(result.isUsable, isFalse);
    expect(result.plates.single.parts.single.name, '测试件');
    expect(result.plates.single.parts.single.instancesPerRun, 1);
    expect(result.targetModel, 'Bambu Lab A1');
    expect(result.nozzleDiameter, 0.4);
    expect(result.declaredFilamentCount, 1);
    expect(result.hasEmbeddedSettings, isTrue);
    expect(result.warning, contains('未完成切片'));
  });

  test('部分切片的多盘项目可使用已切盘，并明确保留其他待切盘', () async {
    final file = File('${temp.path}${Platform.pathSeparator}partial.3mf');
    final archive = Archive()
      ..addFile(
        _textFile('Metadata/model_settings.config', '''
<config>
  <object id="1"><metadata key="name" value="外壳"/></object>
  <object id="2"><metadata key="name" value="底座"/></object>
  <plate><metadata key="plater_id" value="1"/><metadata key="plater_name" value="外壳盘"/><model_instance><metadata key="object_id" value="1"/></model_instance></plate>
  <plate><metadata key="plater_id" value="2"/><metadata key="plater_name" value="底座盘"/><model_instance><metadata key="object_id" value="2"/></model_instance></plate>
</config>
'''),
      )
      ..addFile(
        _textFile('Metadata/slice_info.config', '''
<config><plate><metadata key="index" value="1"/><metadata key="prediction" value="900"/></plate></config>
'''),
      )
      ..addFile(_textFile('Metadata/plate_1.gcode', '; plate 1'));
    await file.writeAsBytes(ZipEncoder().encode(archive)!);

    final result = await ProductionPackageInspector.inspect(file.path);

    expect(result, isNotNull);
    expect(result!.isUsable, isTrue);
    expect(result.isFullySliced, isFalse);
    expect(result.incompletePlates.map((item) => item.plateIndex), [2]);
    expect(result.plates[0].parts.single.name, '外壳');
    expect(result.plates[1].parts.single.name, '底座');
  });

  test('对象名是自动编号时回退到原始源文件名并保持盘归属', () async {
    final file = File('${temp.path}${Platform.pathSeparator}names.3mf');
    final archive = Archive()
      ..addFile(
        _textFile('Metadata/model_settings.config', '''
<config>
  <object id="11"><metadata key="name" value="Object 11"/><part id="111"><metadata key="name" value="Default-111"/><metadata key="source_file" value="models/dragon_head.stl"/></part></object>
  <object id="12"><metadata key="name" value="对象 12"/><part id="121"><metadata key="source_file" value="base.step"/></part></object>
  <plate><metadata key="plater_id" value="1"/><model_instance><metadata key="object_id" value="11"/></model_instance></plate>
  <plate><metadata key="plater_id" value="2"/><model_instance><metadata key="object_id" value="12"/></model_instance></plate>
</config>
'''),
      );
    await file.writeAsBytes(ZipEncoder().encode(archive)!);

    final result = await ProductionPackageInspector.inspect(file.path);

    expect(result, isNotNull);
    expect(result!.plates[0].parts.single.name, 'dragon_head');
    expect(result.plates[1].parts.single.name, 'base');
    expect(
      result.plates.expand((plate) => plate.parts).map((part) => part.name),
      isNot(contains('Object 11')),
    );
  });

  test('标准源 3MF 直接读取对象名称和 build 实例数量', () async {
    final file = File('${temp.path}${Platform.pathSeparator}source-model.3mf');
    final archive = Archive()
      ..addFile(
        _textFile('3D/3dmodel.model', '''
<model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
  <resources>
    <object id="1" name="外壳" type="model"><mesh/></object>
    <object id="2" name="底座" type="model"><mesh/></object>
  </resources>
  <build>
    <item objectid="1"/>
    <item objectid="1"/>
    <item objectid="2"/>
  </build>
</model>
'''),
      );
    await file.writeAsBytes(ZipEncoder().encode(archive)!);

    final result = await ProductionPackageInspector.inspect(file.path);

    expect(result, isNotNull);
    expect(result!.isSliced, isFalse);
    expect(result.slicerName, '3MF');
    expect(result.hasEmbeddedSettings, isFalse);
    expect(result.plates, hasLength(1));
    expect(result.plates.single.name, contains('Bambu Studio'));
    expect(result.plates.single.parts, hasLength(2));
    final shell = result.plates.single.parts.singleWhere(
      (part) => part.name == '外壳',
    );
    expect(shell.instancesPerRun, 2);
  });
  test('Bambu Studio 2.7 layer_ranges is used when layer_num is absent',
      () async {
    final file = File(
      '${temp.path}${Platform.pathSeparator}layer-ranges-only.3mf',
    );
    final archive = Archive()
      ..addFile(
        _textFile('Metadata/model_settings.config', '''
<config>
  <object id="1"><metadata key="name" value="part.stl"/></object>
  <plate><metadata key="plater_id" value="1"/><model_instance><metadata key="object_id" value="1"/></model_instance></plate>
</config>
'''),
      )
      ..addFile(
        _textFile('Metadata/slice_info.config', '''
<config><plate>
  <metadata key="index" value="1"/>
  <metadata key="prediction" value="60190"/>
  <filament id="1" used_g="531.72" type="PETG" color="#F7D959"/>
  <layer_filament_lists>
    <layer_filament_list filament_list="0" layer_ranges="0 1216"/>
  </layer_filament_lists>
</plate></config>
'''),
      )
      ..addFile(_textFile('Metadata/plate_1.gcode', '; plate 1'));
    await file.writeAsBytes(ZipEncoder().encode(archive)!);

    final result = await ProductionPackageInspector.inspect(file.path);

    expect(result, isNotNull);
    expect(result!.plates.single.totalLayers, 1217);
  });

  test('Bambu 2.7 multicolor plate keeps channels and reconstructs changes',
      () async {
    final file = File('${temp.path}${Platform.pathSeparator}multicolor.3mf');
    final archive = Archive()
      ..addFile(
        _textFile('Metadata/model_settings.config', '''
<config>
  <object id="1"><metadata key="name" value="painted-part.stl"/></object>
  <plate><metadata key="plater_id" value="8"/><metadata key="plater_name" value="左多色配件"/><model_instance><metadata key="object_id" value="1"/></model_instance></plate>
</config>
'''),
      )
      ..addFile(
        _textFile('Metadata/slice_info.config', '''
<config><plate>
  <metadata key="index" value="8"/>
  <metadata key="prediction" value="6335"/>
  <filament id="1" tray_info_idx="GFG00" type="PETG" color="#F7D959" used_g="22.73" group_id="0" nozzle_diameter="0.40" volume_type="Standard" used_for_object="true" used_for_support="false"/>
  <filament id="2" type="PETG" color="#000000" used_g="0"/>
  <filament id="3" tray_info_idx="GFG00" type="PETG" color="#FFFFFF" used_g="16.24" group_id="0" nozzle_diameter="0.40" volume_type="Standard" used_for_object="true" used_for_support="false"/>
  <layer_filament_lists>
    <layer_filament_list filament_list="0" layer_ranges="0 63,127 188,252 326"/>
    <layer_filament_list filament_list="2" layer_ranges="64 126,189 251"/>
  </layer_filament_lists>
</plate></config>
'''),
      )
      ..addFile(
        _textFile('Metadata/plate_8.gcode', '''
; EXECUTABLE_BLOCK_START
M620 S0A
M620 S2A
M620 S0A
M620 S2A
M620 S0A
'''),
      );
    await file.writeAsBytes(ZipEncoder().encode(archive)!);

    final result = await ProductionPackageInspector.inspect(file.path);

    expect(result, isNotNull);
    final plate = result!.plates.single;
    expect(plate.totalLayers, 327);
    expect(plate.toolChangeCount, 4);
    expect(plate.activeFilaments.map((item) => item.toolIndex), [0, 2]);
    expect(plate.activeFilaments.map((item) => item.grams), [22.73, 16.24]);
    expect(plate.isMulticolor, isTrue);
    expect(plate.activeFilaments.first.sku, 'GFG00');
    expect(plate.activeFilaments.first.usedForObject, isTrue);
    expect(plate.activeFilaments.first.usedForSupport, isFalse);
    expect(plate.activeFilaments.first.nozzleDiameter, 0.4);
  });

  test('zero-usage channel does not turn a single-color plate multicolor', () {
    const plate = ProductionPlateInspection(
      plateIndex: 1,
      name: 'single',
      hasToolpath: true,
      estimatedSeconds: 1,
      totalLayers: 1,
      toolChangeCount: 0,
      estimatedGrams: 10,
      parts: [],
      filaments: [
        ProductionFilamentInspection(toolIndex: 0, grams: 10),
        ProductionFilamentInspection(toolIndex: 1, grams: 0),
      ],
    );

    expect(plate.activeFilaments, hasLength(1));
    expect(plate.isMulticolor, isFalse);
  });
}

ArchiveFile _textFile(String path, String value) {
  final bytes = utf8.encode(value);
  return ArchiveFile(path, bytes.length, bytes);
}
