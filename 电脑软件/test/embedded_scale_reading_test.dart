import 'package:flutter_test/flutter_test.dart';
import 'package:consumable_tracker_desktop/data/models/embedded_scale_reading.dart';

void main() {
  test('解析 ESP32 重量与 CUID/FUID 数据', () {
    final reading = EmbeddedScaleReading.fromJson({
      'device_id': 'scale-01',
      'gross_weight_g': 934.5,
      'tare_weight_g': 200,
      'cuid': '04AABBCC',
      'measured_at': '2026-09-05T10:00:00Z',
      'calibrated': true,
    });
    expect(reading.grossWeightGrams, 934.5);
    expect(reading.netWeightGrams, 734.5);
    expect(reading.hasTag, isTrue);
    expect(reading.calibrated, isTrue);
  });

  test('拒绝负重量、缺少设备标识或时间戳', () {
    expect(
      () => EmbeddedScaleReading.fromJson({'device_id': 'x', 'weight_g': -1}),
      throwsFormatException,
    );
  });
}
