import '../services/sensitive_data_sanitizer.dart';

/// Legacy helper/vendor output is untrusted diagnostic text. Drop credential
/// envelopes wholesale before allowing a line into callbacks, results or logs.
String sanitizeNativeAccountLog(String text) => text
    .split('\n')
    .map((line) {
      if (RegExp(
        r'\b(?:access[_ -]?token|refresh[_ -]?token|token|password|secret|'
        r'login_info|authkey|ttcode|profile\s+body)\b\s*["\x27]?\s*[:=]|'
        r'ping_bind\s*\(|\bPIN\s*[:=]',
        caseSensitive: false,
      ).hasMatch(line)) {
        return '[native credential output redacted]';
      }
      return SensitiveDataSanitizer.sanitize(line).text;
    })
    .join('\n');
