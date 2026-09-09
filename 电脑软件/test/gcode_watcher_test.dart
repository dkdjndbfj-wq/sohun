import 'dart:io';

import 'package:consumable_tracker_desktop/data/external/slicer/gcode_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late GcodeWatcher watcher;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('slicer_watch_');
    watcher = GcodeWatcher(
      directoryPath: directory.path,
      onSliceCompleted: (_) {},
    );
  });
  tearDown(() async {
    await watcher.stop();
    await directory.delete(recursive: true);
  });

  test('重复扫描保留既有切片，同路径覆盖后读取新克数', () async {
    final file = File('${directory.path}/part.gcode');
    await file.writeAsString(_gcode(12));
    expect((await watcher.scanExisting()).single.totalGrams, 12);
    expect((await watcher.scanExisting()).single.totalGrams, 12);
    await file.writeAsString(_gcode(25));
    expect((await watcher.scanExisting()).single.totalGrams, 25);
  });

  test('停止监听会取消仍在等待文件完整的旧扫描', () async {
    await File(
      '${directory.path}/incomplete.3mf',
    ).writeAsString('incomplete zip');
    final scan = watcher.scanExisting();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await watcher.stop();
    expect(await scan.timeout(const Duration(seconds: 2)), isEmpty);
  });

  test('不完整的旧切片不会让手动扫描一直等待', () async {
    await File(
      '${directory.path}/incomplete.3mf',
    ).writeAsString('incomplete zip');
    final results = await watcher.scanExisting().timeout(
      const Duration(seconds: 3),
    );
    expect(results, isEmpty);
  });
}

String _gcode(int grams) =>
    '''
; BambuStudio 02.07.01.57
; total filament weight [g] : $grams
; total layer number: 5
; model printing time: 1m; total estimated time: 1m
G1 X10 Y10 E1
M84
''';
