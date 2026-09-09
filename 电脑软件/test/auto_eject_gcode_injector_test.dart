import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/auto_eject_gcode_injector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const script = '''
; auto eject
G1 X250 Y220 F6000
G1 X10 Y220 F6000
''';

  test('inserts before executable end marker and remains idempotent', () {
    const source = '''
;LAYER_CHANGE
G1 X10 Y10
; EXECUTABLE_BLOCK_END
M84
''';

    final first = AutoEjectGcodeInjector.injectText(source, script);
    final second = AutoEjectGcodeInjector.injectText(first, script);

    expect(
      first.indexOf(AutoEjectGcodeInjector.beginMarker),
      lessThan(first.indexOf('; EXECUTABLE_BLOCK_END')),
    );
    expect(second, first);
    expect(
      RegExp(RegExp.escape(AutoEjectGcodeInjector.beginMarker))
          .allMatches(second),
      hasLength(1),
    );
  });

  test('injects only selected 3MF plate and preserves source artifact',
      () async {
    final directory = await Directory.systemTemp.createTemp('sohun-eject-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/multi.3mf');
    final archive = Archive()
      ..addFile(_textFile('Metadata/plate_1.gcode', '; plate 1\nM84\n'))
      ..addFile(_textFile('Metadata/plate_8.gcode', '; plate 8\nM84\n'))
      ..addFile(_textFile('[Content_Types].xml', '<Types/>'));
    await source.writeAsBytes(ZipEncoder().encode(archive)!);
    final originalBytes = await source.readAsBytes();

    final outputPath = await AutoEjectGcodeInjector.inject(
      artifactPath: source.path,
      plateIndex: 8,
      gcode: script,
    );
    final output = File(outputPath);
    final decoded = ZipDecoder().decodeBytes(await output.readAsBytes());
    final plate1 = _text(decoded.findFile('Metadata/plate_1.gcode')!);
    final plate8 = _text(decoded.findFile('Metadata/plate_8.gcode')!);

    expect(outputPath, endsWith('_autoeject.3mf'));
    expect(await source.readAsBytes(), originalBytes);
    expect(plate1, isNot(contains(AutoEjectGcodeInjector.beginMarker)));
    expect(plate8, contains(AutoEjectGcodeInjector.beginMarker));
    expect(
      plate8.indexOf(AutoEjectGcodeInjector.beginMarker),
      lessThan(plate8.indexOf('M84')),
    );
  });

  test('plain G-code injection writes a separate artifact', () async {
    final directory = await Directory.systemTemp.createTemp('sohun-eject-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/plate.gcode');
    await source.writeAsString('; source\nM84\n');

    final outputPath = await AutoEjectGcodeInjector.inject(
      artifactPath: source.path,
      plateIndex: 1,
      gcode: script,
    );

    expect(await source.readAsString(), '; source\nM84\n');
    expect(outputPath, endsWith('_autoeject.gcode'));
    expect(await File(outputPath).readAsString(), contains(script.trim()));
  });

  test('batch injection can use a unique output path without replacing source',
      () async {
    final directory = await Directory.systemTemp.createTemp('sohun-batch-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/plate.gcode');
    final batch = '${directory.path}/plate_batch_123.gcode';
    await source.writeAsString('; source\nM84\n');

    final outputPath = await AutoEjectGcodeInjector.inject(
      artifactPath: source.path,
      plateIndex: 1,
      gcode: script,
      outputPath: batch,
    );

    expect(outputPath, batch);
    expect(await source.readAsString(), '; source\nM84\n');
    expect(await File(batch).readAsString(), contains(script.trim()));
  });
}

ArchiveFile _textFile(String path, String value) {
  final bytes = utf8.encode(value);
  return ArchiveFile(path, bytes.length, bytes);
}

String _text(ArchiveFile file) {
  return utf8.decode(file.content as List<int>);
}
