import 'package:consumable_tracker_desktop/core/utils/native_account_log.dart';
import 'package:consumable_tracker_desktop/core/services/sensitive_data_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('带空格与转义引号的凭据完整脱敏，长凭据不受 200 字符窗口限制', () {
    const quoted = r'''password="secret with \"quoted\" spaces" token='another secret' ''';
    final result = SensitiveDataSanitizer.sanitize(quoted).text;
    expect(result, isNot(contains('secret')));
    expect(result, isNot(contains('spaces')));
    expect(result, isNot(contains('quoted')));
    final long = List.filled(300, 'q').join();
    expect(SensitiveDataSanitizer.sanitize('token=$long').text, 'token=<redacted>');
  });
  test('原生账号日志不暴露令牌片段、登录包、PIN 或用户资料', () {
    const text =
        '[+] token = test-token-prefix...\n'
        '[*] login_info = {"token":"sample-access","refreshToken":"sample-refresh"}\n'
        '=== ping_bind("123456") ===\n'
        '[*] profile body: {"email":"somebody@example.com"}\n'
        'PIN=123456\n'
        '[+] ping_bind = 0\n[+] 成功\n';
    final safe = sanitizeNativeAccountLog(text);
    for (final secret in [
      'test-token-prefix',
      'sample-access',
      'sample-refresh',
      '123456',
      'somebody@example.com',
    ]) {
      expect(safe, isNot(contains(secret)));
    }
    expect(safe, contains('ping_bind = 0'));
    expect(safe, contains('成功'));
  });

  test('相邻的多个凭据字段均脱敏，不因扫描窗口交叠而崩溃', () {
    final safe = SensitiveDataSanitizer.sanitize(
      'token=sample-access refreshToken=sample-refresh password=sample-password',
    ).text;
    for (final secret in [
      'sample-access',
      'sample-refresh',
      'sample-password',
    ]) {
      expect(safe, isNot(contains(secret)));
    }
  });

  test('相邻访问码提示的窗口交叠也不会崩溃或遗漏第二个码', () {
    final safe = SensitiveDataSanitizer.sanitize(
      'access_code=12345678 access code=87654321',
    ).text;
    expect(safe, isNot(contains('12345678')));
    expect(safe, isNot(contains('87654321')));
  });
}
