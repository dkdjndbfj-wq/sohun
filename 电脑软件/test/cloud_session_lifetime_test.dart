import 'dart:convert';

import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  BambuCloudSession session({
    required String token,
    DateTime? expiresAt,
    String? refreshToken,
  }) {
    return BambuCloudSession(
      region: BambuRegion.china,
      email: 'user@example.com',
      accessToken: token,
      username: 'u_123',
      loginAt: DateTime.now().subtract(const Duration(days: 30)),
      refreshToken: refreshToken,
      expiresAt: expiresAt,
    );
  }

  String jwtWithExpiry(DateTime expiry) {
    String part(Map<String, Object> value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    return '${part({'alg': 'none'})}.${part({
          'exp': expiry.millisecondsSinceEpoch ~/ 1000,
        })}.';
  }

  test('服务端有效期优先于登录时间，不再固定六天过期', () {
    final value = session(
      token: 'opaque-token',
      expiresAt: DateTime.now().add(const Duration(days: 300)),
    );

    expect(value.isExpired, isFalse);
    expect(value.effectiveExpiresAt, isNotNull);
  });

  test('旧 JWT session 从 exp 判断真实有效期', () {
    final future = session(
      token: jwtWithExpiry(DateTime.now().add(const Duration(days: 20))),
    );
    final past = session(
      token: jwtWithExpiry(DateTime.now().subtract(const Duration(hours: 1))),
    );

    expect(future.isExpired, isFalse);
    expect(past.isExpired, isTrue);
  });

  test('无法解析有效期的旧 opaque token 交由服务端验证', () {
    final value = session(token: 'legacy-opaque-token');

    expect(value.effectiveExpiresAt, isNull);
    expect(value.isExpired, isFalse);
  });

  test('session JSON 完整保存刷新令牌和有效期', () {
    final expiresAt = DateTime.now().add(const Duration(days: 365));
    final original = session(
      token: 'access-token',
      refreshToken: 'refresh-token',
      expiresAt: expiresAt,
    );
    final restored = BambuCloudSession.fromJson(original.toJson());

    expect(restored.refreshToken, 'refresh-token');
    expect(restored.expiresAt?.toIso8601String(), expiresAt.toIso8601String());
  });
}
