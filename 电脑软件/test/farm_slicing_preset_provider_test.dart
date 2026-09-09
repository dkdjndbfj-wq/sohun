import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:consumable_tracker_desktop/providers/farm_slicing_preset_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory source;
  late Directory support;
  late FarmSlicingPresetsNotifier notifier;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('farm-slicing-presets-');
    source = await Directory('${root.path}/source').create();
    support = await Directory('${root.path}/support').create();
    notifier = FarmSlicingPresetsNotifier(
      supportDirectory: () async => support,
    );
    await notifier.ready;
  });

  tearDown(() async {
    notifier.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('完整配置会按机器、工艺和耗材自动分类并识别精确喷嘴', () async {
    final files = await _writeCompletePreset(source);

    final candidate = await notifier.inspectImportFiles([
      files.filament,
      files.process,
      files.machine,
    ]);

    expect(candidate.displayModel, 'A1');
    expect(candidate.nozzleDiameter, .4);
    expect(candidate.machineConfigName, 'Bambu Lab A1 0.4 nozzle');
    expect(candidate.processConfigName, '0.20mm Standard @BBL A1');
    expect(candidate.filamentConfigNames, ['Bambu PLA Basic @BBL A1']);
  });

  test('缺少完整机器字段的继承型片段会被拒绝', () async {
    final files = await _writeCompletePreset(source);
    final machine = File(files.machine);
    final json =
        jsonDecode(await machine.readAsString()) as Map<String, dynamic>;
    json.remove('machine_start_gcode');
    json['inherits'] = 'fdm_bbl_3dp_001_common';
    await machine.writeAsString(jsonEncode(json));

    expect(
      () => notifier.inspectImportFiles([files.machine, files.process]),
      throwsA(
        isA<FarmSlicingPresetException>().having(
          (error) => error.message,
          'message',
          contains('完整配置'),
        ),
      ),
    );
  });

  test('工艺或耗材声明的机型喷嘴不兼容时拒绝导入', () async {
    final files = await _writeCompletePreset(
      source,
      compatiblePrinter: 'Bambu Lab A1 0.6 nozzle',
    );

    expect(
      () => notifier.inspectImportFiles([
        files.machine,
        files.process,
        files.filament,
      ]),
      throwsA(
        isA<FarmSlicingPresetException>().having(
          (error) => error.message,
          'message',
          contains('不兼容'),
        ),
      ),
    );
  });

  test('同机型同喷嘴允许多个命名方案且托管副本不依赖原文件', () async {
    final files = await _writeCompletePreset(source);
    final candidate = await notifier.inspectImportFiles([
      files.machine,
      files.process,
      files.filament,
    ]);

    final highQuality = await notifier.importCandidate(
      candidate: candidate,
      name: '高质量',
    );
    final supports = await notifier.importCandidate(
      candidate: candidate,
      name: '有支撑',
    );
    await source.delete(recursive: true);

    expect(notifier.compatiblePresets('Bambu Lab A1', .4), hasLength(2));
    expect(await File(highQuality.machineSettingsPath).exists(), isTrue);
    expect(await File(highQuality.processSettingsPath).exists(), isTrue);
    expect(
      await File(highQuality.filamentSettingsPaths.single).exists(),
      isTrue,
    );
    expect(supports.name, '有支撑');
    expect(
      () => notifier.importCandidate(candidate: candidate, name: '高质量'),
      throwsA(isA<FarmSlicingPresetException>()),
    );
  });

  test('相同机型的不同喷嘴不会出现在同一兼容列表', () async {
    final firstFiles = await _writeCompletePreset(source);
    final first = await notifier.inspectImportFiles([
      firstFiles.machine,
      firstFiles.process,
    ]);
    await notifier.importCandidate(candidate: first, name: '0.4 标准');

    final source06 = await Directory('${root.path}/source-06').create();
    final secondFiles = await _writeCompletePreset(
      source06,
      nozzle: .6,
      compatiblePrinter: 'Bambu Lab A1 0.6 nozzle',
    );
    final second = await notifier.inspectImportFiles([
      secondFiles.machine,
      secondFiles.process,
    ]);
    await notifier.importCandidate(candidate: second, name: '0.6 标准');

    expect(
      notifier.compatiblePresets('A1', .4).map((item) => item.name),
      ['0.4 标准'],
    );
    expect(
      notifier.compatiblePresets('A1', .6).map((item) => item.name),
      ['0.6 标准'],
    );
  });

  test('切片前会复检托管文件、指纹以及目标机型喷嘴', () async {
    final files = await _writeCompletePreset(source);
    final candidate = await notifier.inspectImportFiles([
      files.machine,
      files.process,
      files.filament,
    ]);
    final preset = await notifier.importCandidate(
      candidate: candidate,
      name: '生产参数',
    );

    await notifier.validateManagedPreset(
      preset,
      model: 'A1',
      nozzleDiameter: .4,
    );
    expect(
      () => notifier.validateManagedPreset(
        preset,
        model: 'A1',
        nozzleDiameter: .6,
      ),
      throwsA(isA<FarmSlicingPresetException>()),
    );

    await File(preset.processSettingsPath).writeAsString('{}');
    expect(
      () => notifier.validateManagedPreset(
        preset,
        model: 'A1',
        nozzleDiameter: .4,
      ),
      throwsA(
        isA<FarmSlicingPresetException>().having(
          (error) => error.message,
          'message',
          contains('修改或损坏'),
        ),
      ),
    );
  });
}

Future<({String machine, String process, String filament})>
    _writeCompletePreset(
  Directory directory, {
  double nozzle = .4,
  String? compatiblePrinter,
}) async {
  final nozzleText = nozzle.toStringAsFixed(1);
  final compatible = compatiblePrinter ?? 'Bambu Lab A1 $nozzleText nozzle';
  final machine = File('${directory.path}/machine-$nozzleText.json');
  final process = File('${directory.path}/process-$nozzleText.json');
  final filament = File('${directory.path}/filament-$nozzleText.json');
  await machine.writeAsString(
    jsonEncode({
      'type': 'machine',
      'name': 'Bambu Lab A1 $nozzleText nozzle',
      'printer_model': 'Bambu Lab A1',
      'nozzle_diameter': [nozzleText],
      'printable_area': ['0x0', '256x0', '256x256', '0x256'],
      'machine_start_gcode': 'G28',
      'machine_end_gcode': 'M84',
    }),
  );
  await process.writeAsString(
    jsonEncode({
      'type': 'process',
      'name': '0.20mm Standard @BBL A1',
      'layer_height': ['0.2'],
      'compatible_printers': [compatible],
    }),
  );
  await filament.writeAsString(
    jsonEncode({
      'type': 'filament',
      'name': 'Bambu PLA Basic @BBL A1',
      'filament_type': ['PLA'],
      'filament_diameter': ['1.75'],
      'compatible_printers': [compatible],
    }),
  );
  return (
    machine: machine.path,
    process: process.path,
    filament: filament.path,
  );
}
