import 'dart:io';

import 'package:consumable_tracker_desktop/data/external/slicer/autoclear_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('signed auto-eject marker without motion does not pass safety gate',
      () async {
    final directory = await Directory.systemTemp.createTemp('sohun-clear-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/empty.gcode');
    await file.writeAsString('''
;LAYER_CHANGE
; SOHUN_AUTO_EJECT_BEGIN
M117 auto eject
; SOHUN_AUTO_EJECT_END
M84
''');

    final result = await AutoClearDetector.detect(file.path);

    expect(result.hasAutoClear, isFalse);
    expect(result.matchedFeatures.last, contains('拒绝无人值守'));
  });

  test('auto-eject marker with physical XY push motion passes', () async {
    final directory = await Directory.systemTemp.createTemp('sohun-clear-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/motion.gcode');
    await file.writeAsString('''
;LAYER_CHANGE
; SOHUN_AUTO_EJECT_BEGIN
M140 S0
G1 X0 Y220 F6000
G1 X250 Y220 F6000
G1 X10 Y220 F6000
; SOHUN_AUTO_EJECT_END
M84
''');

    final result = await AutoClearDetector.detect(file.path);

    expect(result.hasAutoClear, isTrue);
    expect(result.score, greaterThanOrEqualTo(AutoClearDetector.threshold));
  });
}
