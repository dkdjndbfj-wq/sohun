import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/threemf_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sohun-threemf-parser-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('reads Bambu Studio 2.7 total layers from inclusive layer ranges',
      () async {
    final file = File('${temp.path}${Platform.pathSeparator}sliced.3mf');
    final archive = Archive()
      ..addFile(
        _textFile('Metadata/slice_info.config', '''
<config><plate>
  <metadata key="index" value="1"/>
  <metadata key="prediction" value="60190"/>
  <filament id="1" used_g="531.72" used_m="176.85" type="PETG" color="#F7D959"/>
  <layer_filament_lists>
    <layer_filament_list filament_list="0" layer_ranges="0 1216"/>
  </layer_filament_lists>
</plate></config>
'''),
      );
    await file.writeAsBytes(ZipEncoder().encode(archive)!);

    final result = await ThreemfParser.parseFile(file.path);

    expect(result, isNotNull);
    expect(result!.totalLayers, 1217);
  });

  test('reads sparse Bambu tools as zero-based and counts four color changes',
      () async {
    final file = File('${temp.path}${Platform.pathSeparator}multicolor.3mf');
    final archive = Archive()
      ..addFile(
        _textFile('Metadata/slice_info.config', '''
<config><plate>
  <metadata key="index" value="8"/>
  <metadata key="prediction" value="6335"/>
  <filament id="1" used_g="22.73" used_m="7.56" type="PETG" color="#F7D959" tray_info_idx="GFG00" group_id="0" nozzle_diameter="0.40" volume_type="Standard" used_for_object="true" used_for_support="false"/>
  <filament id="3" used_g="16.24" used_m="5.40" type="PETG" color="#FFFFFF"/>
  <layer_filament_lists>
    <layer_filament_list filament_list="0" layer_ranges="0 63,127 188,252 326"/>
    <layer_filament_list filament_list="2" layer_ranges="64 126,189 251"/>
  </layer_filament_lists>
</plate></config>
'''),
      );
    await file.writeAsBytes(ZipEncoder().encode(archive)!);

    final result = await ThreemfParser.parseFile(file.path, plateIndex: 8);

    expect(result, isNotNull);
    expect(result!.filaments.map((item) => item.toolIndex), [0, 2]);
    expect(result.toolChangeCount, 4);
    expect(result.totalLayers, 327);
    expect(result.filaments.first.sku, 'GFG00');
    expect(result.filaments.first.usedForObject, isTrue);
    expect(result.filaments.first.usedForSupport, isFalse);
    expect(result.filaments.first.groupId, 0);
    expect(result.filaments.first.nozzleDiameter, 0.4);
    expect(result.filaments.first.volumeType, 'Standard');
  });
}

ArchiveFile _textFile(String path, String value) {
  final bytes = utf8.encode(value);
  return ArchiveFile(path, bytes.length, bytes);
}
