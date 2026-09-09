import 'package:consumable_tracker_desktop/core/services/sensitive_data_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const serialLine = 'serial=03900D642930459 printer offline';
  const dllLine = 'stage: official network component loaded '
      '(dll_sha256=1c93940d68fc603fc7b823fafb3f3209cde18e58d529983cd7f207d6b29ffb98)';
  const bearerLine = 'Authorization: Bearer abc123def456ghi789';

  group('SensitiveDataSanitizer 默认（保守）模式', () {
    test('序列号默认仍被脱敏', () {
      final result = SensitiveDataSanitizer.sanitize(serialLine);
      expect(result.text, isNot(contains('03900D642930459')));
      expect(result.redactedCount, greaterThan(0));
    });

    test('dll_sha256 长 hex 默认被脱敏', () {
      final result = SensitiveDataSanitizer.sanitize(dllLine);
      expect(
        result.text,
        isNot(contains('1c93940d68fc603fc7b823fafb3f3209')),
      );
    });
  });

  group('SensitiveDataSanitizer 设备诊断模式（allowDeviceIdentity）', () {
    test('序列号放行（仅用于显式开启的设备诊断上传）', () {
      final result =
          SensitiveDataSanitizer.sanitize(serialLine, allowDeviceIdentity: true);
      expect(result.text, contains('03900D642930459'));
      expect(result.redactedCount, 0);
    });

    test('dll_sha256 指纹放行', () {
      final result = SensitiveDataSanitizer.sanitize(dllLine,
          allowDeviceIdentity: true);
      expect(
        result.text,
        contains('1c93940d68fc603fc7b823fafb3f3209cde18e58d529983cd7f207d6b29ffb98'),
      );
    });

    test('凭据/环境信息即使开启设备标识模式仍被脱敏', () {
      const input = 'serial=03900D642930459 '
          'token=eyJhbGciOiJIUzI1NiJ9.abc.def '
          'access_code=12345678 user@example.com 192.168.1.5 '
          'dll_sha256=1c93940d68fc603fc7b823fafb3f3209cde18e58d529983cd7f207d6b29ffb98';
      final result =
          SensitiveDataSanitizer.sanitize(input, allowDeviceIdentity: true);
      expect(result.text, contains('03900D642930459'));
      expect(result.text, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(result.text, isNot(contains('12345678')));
      expect(result.text, isNot(contains('user@example.com')));
      expect(result.text, isNot(contains('192.168.1.5')));
      expect(
        result.text,
        contains('1c93940d68fc603fc7b823fafb3f3209cde18e58d529983cd7f207d6b29ffb98'),
      );
    });

    test('containsSensitive 与模式一致', () {
      expect(
        SensitiveDataSanitizer.containsSensitive(serialLine),
        isTrue,
      );
      expect(
        SensitiveDataSanitizer.containsSensitive(
          serialLine,
          allowDeviceIdentity: true,
        ),
        isFalse,
      );
      expect(
        SensitiveDataSanitizer.containsSensitive(
          bearerLine,
          allowDeviceIdentity: true,
        ),
        isTrue,
      );
    });
  });
}
