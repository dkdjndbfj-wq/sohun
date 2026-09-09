import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/gcode_parser.dart';

void main() {
  test('解析切片预设、打印机、喷嘴、打印板和稳定产物哈希', () async {
    final dir = await Directory.systemTemp.createTemp('gcode_metadata_test_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/sample.gcode');
    await file.writeAsString('''
; HEADER_BLOCK_START
; BambuStudio 02.07.01.57
; total filament weight [g] : 12.5
; total filament length [mm] : 4020
; total layer number: 20
; total estimated time: 12m 5s
; HEADER_BLOCK_END
; CONFIG_BLOCK_START
; print_settings_id = "0.20mm Standard @BBL X1C"
; printer_settings_id = "Bambu Lab X1 Carbon 0.4 nozzle"
; nozzle_diameter = [0.4]
; curr_bed_type = Textured PEI Plate
; filament_type = PLA
; CONFIG_BLOCK_END
; PLATER_BLOCK_START
G1 X0 Y0
''');

    final result = await GcodeParser.parseFile(file.path);

    expect(result, isNotNull);
    expect(result!.printSettingsId, '0.20mm Standard @BBL X1C');
    expect(result.printerSettingsId, 'Bambu Lab X1 Carbon 0.4 nozzle');
    expect(result.nozzleDiameter, 0.4);
    expect(result.plateType, 'Textured PEI Plate');
    expect(result.artifactSha256, hasLength(64));
    expect(result.artifactSize, await file.length());
  });

  test('derives tool-change count when Bambu header omits it', () async {
    final dir = await Directory.systemTemp.createTemp('gcode_changes_test_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/multicolor.gcode');
    await file.writeAsString('''
; HEADER_BLOCK_START
; BambuStudio 02.07.01.57
; total filament weight [g] : 1.0,0,1.0
; filament_type = PETG;PETG;PETG
; filament_colour = #F7D959;#000000;#FFFFFF
; HEADER_BLOCK_END
;LAYER:0
M620 S0A
;LAYER:64
M620 S2A
;LAYER:127
M620 S0A
;LAYER:189
M620 S2A
;LAYER:252
M620 S0A
''');

    final result = await GcodeParser.parseFile(file.path);

    expect(result, isNotNull);
    expect(result!.filaments.map((item) => item.toolIndex), [0, 2]);
    expect(result.filamentChangePoints, hasLength(4));
    expect(result.toolChangeCount, 4);
  });
}
