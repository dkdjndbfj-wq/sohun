import 'package:flutter_test/flutter_test.dart';
import 'package:consumable_tracker_desktop/data/models/embedded_scale_device.dart';

void main() {
  test('设备配置校验地址、皮重和稳定采样参数', () {
    const device = EmbeddedScaleDevice(
      deviceId: 'esp32-scale-01',
      endpoint: 'http://192.168.1.20/reading',
      tareWeightGrams: 240,
    );
    expect(device.isValid, isTrue);
  });

  test('拒绝无协议地址和不合理稳定参数', () {
    const device = EmbeddedScaleDevice(
      deviceId: 'x',
      endpoint: '192.168.1.20',
      stabilitySamples: 1,
    );
    expect(device.isValid, isFalse);
  });
}
