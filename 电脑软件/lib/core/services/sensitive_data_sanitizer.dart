// 统一脱敏器。
//
// 数据策略（2026-09-03 所有者决定，见 TRAE_摄像头唤醒实现任务书.md 与
// diagnostics 隐私页）：
// - 默认模式（保守）：仍按任务书 11.3/11.4/11.5 执行，绝不外发 access
//   token、refresh token、密码、LAN access code、IP、邮箱、打印机序列号、
//   trayUuid、完整文件路径、G-code 内容和用户本地备注。
// - allowDeviceIdentity 模式：仅用于"设备诊断上传"（默认关闭、显式开启），
//   允许携带打印机序列号与 dll_sha256 指纹以便定位设备；令牌、访问码、
//   TTCode、签名值、IP、邮箱、路径、trayUuid 等可用凭据/环境信息
//   仍然永不外发。
//
// 本类被以下位置调用：
// - TelemetryService.recordEvent：写入 telemetry_events 前先脱敏 attributes
// - ErrorLogger.exportLogs：导出错误日志前脱敏 message/stackTrace/context
// - DiagnosticsScreen 导出诊断包：对所有文本字段统一脱敏
// - CommunityShareService：构造上传 payload 时再次校验（防止被外部传入）

import 'dart:convert';

/// 脱敏结果。被替换为占位符的原始值长度计入 [redactedCount]，便于审计。
class SanitizeResult {
  final String text;
  final int redactedCount;

  const SanitizeResult(this.text, this.redactedCount);
}

/// 统一敏感数据脱敏器。
///
/// 所有脱敏入口都返回新字符串，不修改原始输入。
/// 单例无状态，可全局直接调用 `SensitiveDataSanitizer.sanitize(...)`。
class SensitiveDataSanitizer {
  SensitiveDataSanitizer._();

  /// 占位符常量。所有敏感字段统一替换为 `<redacted>`，便于事后扫描。
  static const _placeholder = '<redacted>';

  /// 用户目录路径前缀正则：匹配 Windows、macOS 和 Linux 的用户主目录。
  /// 替换用户名部分为 `<userhome>`，保留后续路径以保持可读性。
  static final _windowsUserPath =
      RegExp(r'([a-z]:\\users\\)[^\\/]+', caseSensitive: false);
  static final _posixUserPath = RegExp(r'(/Users/)[^/]+');
  static final _linuxUserPath = RegExp(r'(/home/)[^/]+');

  /// IPv4 地址正则。0.0.0.0 和 127.0.0.1 不替换（避免破坏本地占位语义）。
  static final _ipv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b');

  /// IPv6 地址正则（简化版，至少包含两个冒号段）。
  /// 排除纯时间戳（如 12:34:56）和端口号（如 8080:8080）。
  /// 要求至少有一个段为 4 位十六进制或包含字母，或地址以 :: 开头/结尾。
  static final _ipv6 = RegExp(
    r'(?<![0-9:])(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}(?![0-9])',
  );

  /// 邮箱正则。
  static final _email = RegExp(
    r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}',
  );

  /// Bambu access code 提示词：`access[_\s-]?code`。
  static final _accessCodeHint =
      RegExp(r'access[_\s-]?code', caseSensitive: false);
  static final _accessCodeValue = RegExp(r'\b(\d{8})\b');

  /// JWT token：三段式 base64url。
  static final _jwt =
      RegExp(r'eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+');

  /// Bearer token 头部。
  static final _bearer =
      RegExp(r'bearer\s+[a-zA-Z0-9._\-]+', caseSensitive: false);

  /// 32+ 位十六进制字符串（常见 token、SHA-256 哈希）。
  static final _longHex = RegExp(r'\b[a-fA-F0-9]{32,}\b');

  /// 通用 token 关键字上下文：`token=xxx` / `"token": "xxx"` 等。
  static final _tokenHint = RegExp(
    "(access[_\\s-]?token|refresh[_\\s-]?token|auth[_\\s-]?token|token|password|secret)[\"']?\\s*[:=]\\s*[\"']?",
    caseSensitive: false,
  );

  /// 标准 UUID（8-4-4-4-12 格式），用于 trayUuid 等拓竹标识符。
  static final _uuid = RegExp(
    r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b',
  );

  /// 打印机序列号上下文：`serial=xxx` / `"serialNumber": "xxx"`。
  static final _serialHint = RegExp(
    "((?:serial[_\\s-]?number|serial|device[_\\s-]?id)[\"']?\\s*[:=]\\s*[\"']?)([a-zA-Z0-9_-]{6,})",
    caseSensitive: false,
  );

  /// URL 中的动态 ID 段：`/v1/presets/<uuid>/...` → `/v1/presets/<id>/...`。
  static final _urlDynamicId = RegExp(
    r'/(v\d+)/(presets|authors|telemetry|config|reports|applications)/([a-zA-Z0-9_-]{8,})',
  );

  /// dll_sha256 指纹（仅 allowDeviceIdentity 模式下放行，用于定位插件版本）。
  static final _dllSha256 =
      RegExp(r'dll_sha256=[0-9a-f]{64}');

  /// 对单条文本执行全量脱敏，返回替换后的文本和替换计数。
  ///
  /// [allowDeviceIdentity] 为 true 时允许保留打印机序列号与 dll_sha256
  /// 指纹（仅用于显式开启的"设备诊断上传"）；可用凭据与环境信息规则不变。
  static SanitizeResult sanitize(String input,
      {bool allowDeviceIdentity = false}) {
    if (input.isEmpty) return const SanitizeResult('', 0);
    var text = input;
    var count = 0;

    // 0. 设备诊断模式下先保护 dll_sha256 指纹（避免被长 hex 规则吞掉）。
    const dllSentinelPrefix = '⟦dllsha';
    final protectedDll = <String, String>{};
    if (allowDeviceIdentity) {
      text = text.replaceAllMapped(_dllSha256, (m) {
        final key = '$dllSentinelPrefix${protectedDll.length}⟧';
        protectedDll[key] = m.group(0)!;
        return key;
      });
    }

    // 1. 用户目录路径（最具体，先替换避免被后续规则破坏）
    text = text.replaceAllMapped(_windowsUserPath, (m) {
      count++;
      return '${m.group(1)}<userhome>';
    });
    text = text.replaceAllMapped(_posixUserPath, (m) {
      count++;
      return '${m.group(1)}<userhome>';
    });
    text = text.replaceAllMapped(_linuxUserPath, (m) {
      count++;
      return '${m.group(1)}<userhome>';
    });

    // 2. 邮箱
    final emailMatches = _email.allMatches(text).toList();
    if (emailMatches.isNotEmpty) {
      text = text.replaceAll(_email, _placeholder);
      count += emailMatches.length;
    }

    // 3. JWT 和 Bearer token（先于 longHex，避免被切碎）
    final jwtMatches = _jwt.allMatches(text).toList();
    if (jwtMatches.isNotEmpty) {
      text = text.replaceAll(_jwt, _placeholder);
      count += jwtMatches.length;
    }
    final bearerMatches = _bearer.allMatches(text).toList();
    if (bearerMatches.isNotEmpty) {
      text = text.replaceAll(_bearer, 'Bearer $_placeholder');
      count += bearerMatches.length;
    }

    // 4. 上下文相关的 access code（仅在提示词附近替换 8 位数字）
    if (_accessCodeHint.hasMatch(text)) {
      final hints = _accessCodeHint.allMatches(text).toList();
      // Match values once, even when multiple hint windows overlap.
      text = text.replaceAllMapped(_accessCodeValue, (value) {
        if (hints.any((hint) =>
            value.start >= hint.end && value.end <= hint.end + 100)) {
          count++;
          return _placeholder;
        }
        return value.group(0)!;
      });
    }

    // 5. 序列号上下文（serial=xxx 形式）；设备诊断模式放行
    if (!allowDeviceIdentity) {
      final serialMatches = _serialHint.allMatches(text).toList();
      if (serialMatches.isNotEmpty) {
        text = text.replaceAllMapped(_serialHint, (m) {
          return '${m.group(1)}$_placeholder';
        });
        count += serialMatches.length;
      }
    }

    // 6. 通用 token 关键字上下文（token=xxx / "token": "xxx"）
    final tokenHintMatches = _tokenHint.allMatches(text).toList();
    if (tokenHintMatches.isNotEmpty) {
      final buffer = StringBuffer();
      var cursor = 0;
      for (final hintMatch in tokenHintMatches) {
        if (hintMatch.start < cursor) continue;
        final hintEnd = hintMatch.end;
        buffer.write(text.substring(cursor, hintEnd));
        // Advance only over this value, not a fixed 200-character window that
        // may contain the next credential and cause overlapping substring cuts.
        final quote = text[hintEnd - 1];
        var tokenEnd = hintEnd;
        if (quote == '"' || quote == "'") {
          // A quoted credential may contain spaces and escaped quote marks.
          while (tokenEnd < text.length && text[tokenEnd] != quote) {
            if (text[tokenEnd] == '\\' && tokenEnd + 1 < text.length) {
              tokenEnd++;
            }
            tokenEnd++;
          }
        } else {
          final endings = RegExp("[\\s\"',}]")
              .allMatches(text, hintEnd).iterator;
          tokenEnd = endings.moveNext() ? endings.current.start : text.length;
        }
        if (tokenEnd > hintEnd) {
          buffer.write(_placeholder);
          count++;
        }
        cursor = tokenEnd;
      }
      buffer.write(text.substring(cursor));
      text = buffer.toString();
    }

    // 7. UUID（包括 trayUuid）— 通用形态，先于 longHex 替换
    final uuidMatches = _uuid.allMatches(text).toList();
    if (uuidMatches.isNotEmpty) {
      text = text.replaceAll(_uuid, _placeholder);
      count += uuidMatches.length;
    }

    // 8. 长 hex 字符串（32+ 位，token / hash）
    final hexMatches = _longHex.allMatches(text).toList();
    if (hexMatches.isNotEmpty) {
      text = text.replaceAll(_longHex, _placeholder);
      count += hexMatches.length;
    }

    // 9. IPv4 地址（最后替换，避免影响版本号等）
    final ipMatches = _ipv4.allMatches(text).where((m) {
      final v = m.group(0)!;
      return v != '0.0.0.0' && v != '127.0.0.1';
    }).toList();
    if (ipMatches.isNotEmpty) {
      text = text.replaceAllMapped(_ipv4, (m) {
        final v = m.group(0)!;
        if (v == '0.0.0.0' || v == '127.0.0.1') return v;
        return '<ip>';
      });
      count += ipMatches.length;
    }

    // 9b. IPv6 地址（任务书 11.7 要求覆盖 IP）
    // 排除常见误匹配：纯时间戳（HH:MM:SS）已被前导/后缀断言过滤，
    // 纯数字段（如 8080:8080）因段数不足或缺少字母时仍可能误匹配，
    // 这里仅替换包含字母或 :: 缩写的 IPv6 地址。
    final ipv6Matches = _ipv6.allMatches(text).where((m) {
      final v = m.group(0)!;
      // 至少包含一个字母（hex letter）或包含 ::
      return v.contains(RegExp(r'[a-fA-F]')) || v.contains('::');
    }).toList();
    if (ipv6Matches.isNotEmpty) {
      text = text.replaceAllMapped(_ipv6, (m) {
        final v = m.group(0)!;
        if (!v.contains(RegExp(r'[a-fA-F]')) && !v.contains('::')) {
          return v;
        }
        return '<ip>';
      });
      count += ipv6Matches.length;
    }

    // 10. URL 动态 ID 段（用于 HTTP 路由模板）
    final urlMatches = _urlDynamicId.allMatches(text).toList();
    if (urlMatches.isNotEmpty) {
      text = text.replaceAllMapped(_urlDynamicId, (m) {
        return '/${m.group(1)}/${m.group(2)}/<id>';
      });
      count += urlMatches.length;
    }

    // 11. 恢复被保护的 dll_sha256 指纹
    if (protectedDll.isNotEmpty) {
      for (final entry in protectedDll.entries) {
        text = text.replaceAll(entry.key, entry.value);
      }
    }

    return SanitizeResult(text, count);
  }

  /// 对 JSON 字符串执行脱敏，返回脱敏后的 JSON 文本。
  /// 先解析 JSON 再对每个字符串值脱敏，避免破坏 JSON 结构。
  static String sanitizeJson(String jsonString) {
    if (jsonString.isEmpty) return jsonString;
    try {
      final decoded = jsonDecode(jsonString);
      final sanitized = _sanitizeObject(decoded);
      return jsonEncode(sanitized);
    } catch (_) {
      // 不是合法 JSON，回退到纯文本脱敏
      return sanitize(jsonString).text;
    }
  }

  /// 对 Map 的所有字符串值递归脱敏。
  static Map<String, dynamic> sanitizeMap(Map<String, dynamic> input) {
    return Map<String, dynamic>.from(_sanitizeObject(input));
  }

  static dynamic _sanitizeObject(dynamic value) {
    if (value is String) {
      return sanitize(value).text;
    }
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        // 键本身也脱敏（防止键名包含敏感信息）
        final sanitizedKey = sanitize(entry.key.toString()).text;
        result[sanitizedKey] = _sanitizeObject(entry.value);
      }
      return result;
    }
    if (value is List) {
      return value.map(_sanitizeObject).toList();
    }
    return value;
  }

  /// 快速判断字符串是否包含敏感信息（用于上传前校验）。
  /// [allowDeviceIdentity] 语义同 [sanitize]。
  static bool containsSensitive(String input,
      {bool allowDeviceIdentity = false}) {
    if (input.isEmpty) return false;
    return _email.hasMatch(input) ||
        _jwt.hasMatch(input) ||
        _bearer.hasMatch(input) ||
        _uuid.hasMatch(input) ||
        _longHex.hasMatch(input) ||
        _windowsUserPath.hasMatch(input) ||
        _posixUserPath.hasMatch(input) ||
        _linuxUserPath.hasMatch(input) ||
        _accessCodeHint.hasMatch(input) ||
        (!allowDeviceIdentity && _serialHint.hasMatch(input)) ||
        _urlDynamicId.hasMatch(input);
  }
}
