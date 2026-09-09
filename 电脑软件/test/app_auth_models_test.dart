import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final createdAt = DateTime.utc(2026, 7, 27, 8);
  final updatedAt = DateTime.utc(2026, 7, 27, 9);

  Map<String, dynamic> userJson() => {
        'id': 'user-1',
        'email': 'USER@example.com',
        'handle': 'Maker_01',
        'displayName': '打印玩家',
        'avatarUrl': 'https://cdn.example.com/avatar.png',
        'emailVerified': true,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  group('AppUser', () {
    test('parses the server camelCase contract', () {
      final user = AppUser.fromJson(userJson());

      expect(user.id, 'user-1');
      expect(user.email, 'user@example.com');
      expect(user.handle, 'maker_01');
      expect(user.displayName, '打印玩家');
      expect(user.emailVerified, isTrue);
      expect(user.createdAt.toUtc(), createdAt);
      expect(user.updatedAt.toUtc(), updatedAt);
    });

    test('rejects missing identity fields', () {
      final json = userJson()..remove('handle');
      expect(() => AppUser.fromJson(json), throwsFormatException);
    });
  });

  group('AppAuthSession', () {
    test('round-trips the protected-storage JSON model', () {
      final session = AppAuthSession(
        user: AppUser.fromJson(userJson()),
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        expiresAt: DateTime.utc(2026, 7, 27, 10),
        refreshExpiresAt: DateTime.utc(2026, 8, 27),
        serverBaseUrl: 'https://share.example.com/api',
      );

      final restored = AppAuthSession.fromJson(session.toJson());

      expect(restored.user.id, session.user.id);
      expect(restored.accessToken, session.accessToken);
      expect(restored.refreshToken, session.refreshToken);
      expect(restored.expiresAt.toUtc(), session.expiresAt);
      expect(restored.refreshExpiresAt?.toUtc(), session.refreshExpiresAt);
      expect(restored.serverBaseUrl, session.serverBaseUrl);
    });

    test('checks access and refresh expiry independently', () {
      final now = DateTime.utc(2026, 7, 27, 10);
      final session = AppAuthSession(
        user: AppUser.fromJson(userJson()),
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        expiresAt: now.subtract(const Duration(seconds: 1)),
        refreshExpiresAt: now.add(const Duration(days: 1)),
        serverBaseUrl: 'https://share.example.com',
      );

      expect(session.isAccessTokenExpired(now: now), isTrue);
      expect(session.isRefreshTokenExpired(now: now), isFalse);
    });
  });

  group('request models', () {
    test('registration emits the exact backend contract', () {
      final request = AppRegisterRequest(
        email: ' User@Example.com ',
        handle: 'Maker_01',
        displayName: ' 打印玩家 ',
        password: 'StrongPassword123',
        acceptTerms: true,
      );

      expect(request.toJson(), {
        'email': 'user@example.com',
        'handle': 'maker_01',
        'displayName': '打印玩家',
        'password': 'StrongPassword123',
        'acceptTerms': true,
        'termsVersion': AppAccountAgreement.termsVersion,
        'privacyVersion': AppAccountAgreement.privacyVersion,
      });
    });

    test('login accepts email and never serializes unrelated profile fields',
        () {
      final request = AppLoginRequest(
        email: ' User@Example.com ',
        password: 'secret',
      );

      expect(request.toJson(), {
        'email': 'user@example.com',
        'password': 'secret',
      });
    });

    test('registration validates email, handle and password', () {
      expect(
        () => AppRegisterRequest(
          email: 'invalid',
          handle: 'ok_name',
          displayName: '用户',
          password: 'StrongPassword123',
          acceptTerms: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => AppRegisterRequest(
          email: 'user@example.com',
          handle: '含中文',
          displayName: '用户',
          password: 'StrongPassword123',
          acceptTerms: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => AppRegisterRequest(
          email: 'user@example.com',
          handle: 'maker_01',
          displayName: '用户',
          password: 'short',
          acceptTerms: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => AppRegisterRequest(
          email: 'user@example.com',
          handle: 'maker_01',
          displayName: '用户',
          password: 'StrongPassword123',
          acceptTerms: false,
        ),
        throwsArgumentError,
      );
    });

    test('password reset and deletion emit only their strict contracts', () {
      final reset = AppPasswordResetConfirmation(
        email: ' User@Example.com ',
        code: '12345678',
        newPassword: 'NewStrongPassword123',
      );
      expect(reset.toJson(), {
        'email': 'user@example.com',
        'code': '12345678',
        'newPassword': 'NewStrongPassword123',
      });
      expect(
        AppAccountDeletionRequest('CurrentPassword123').toJson(),
        {
          'password': 'CurrentPassword123',
          'confirmation': 'DELETE',
        },
      );
      expect(
        () => AppPasswordResetConfirmation(
          email: 'user@example.com',
          code: '1234',
          newPassword: 'NewStrongPassword123',
        ),
        throwsArgumentError,
      );
    });
  });

  test('versioned policy document parses readable server content', () {
    final document = AppAccountPolicyDocument.fromJson({
      'type': 'privacy',
      'version': '2026-07-29',
      'current': true,
      'title': 'sohun 隐私政策',
      'effectiveAt': '2026-07-29T00:00:00.000Z',
      'content': '正文',
    });

    expect(document.type, AppAccountPolicyType.privacy);
    expect(document.isCurrent, isTrue);
    expect(document.content, '正文');
  });
}
