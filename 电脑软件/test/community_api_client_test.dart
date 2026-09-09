import 'dart:convert';

import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  Map<String, dynamic> userJson({bool verified = true}) => {
        'id': 'user-1',
        'email': 'maker@example.com',
        'handle': 'maker_01',
        'displayName': '打印玩家',
        'avatarUrl': null,
        'emailVerified': verified,
        'createdAt': '2026-07-27T08:00:00.000Z',
        'updatedAt': '2026-07-27T09:00:00.000Z',
      };

  Map<String, dynamic> authJson({bool verified = true}) => {
        'user': userJson(verified: verified),
        'accessToken': 'access-token',
        'refreshToken': 'refresh-token',
        'expiresAt': '2099-07-27T10:00:00.000Z',
      };

  group('CommunityApiClient request contract', () {
    test('health verifies the sohun account service identity', () async {
      final client = CommunityApiClient(
        baseUri: Uri.parse('https://share.example.com/api'),
        httpClient: MockClient(
          (_) async => _jsonResponse(
            {
              'ok': true,
              'service': 'sohun-community',
              'apiVersion': 1,
              'registrationEnabled': true,
              'emailVerificationRequired': false,
              'termsVersion': AppAccountAgreement.termsVersion,
              'privacyVersion': AppAccountAgreement.privacyVersion,
            },
            200,
          ),
        ),
      );

      final info = await client.health();

      expect(info.isCompatible, isTrue);
      expect(info.registrationEnabled, isTrue);
    });

    test('health rejects incompatible service and API identities', () async {
      final incompatibleIdentities = <Map<String, Object>>[
        {'service': 'unrelated-service', 'apiVersion': 1},
        {'service': 'sohun-community', 'apiVersion': 2},
      ];

      for (final identity in incompatibleIdentities) {
        final client = CommunityApiClient(
          baseUri: Uri.parse('https://share.example.com/api'),
          httpClient: MockClient(
            (_) async => _jsonResponse(
              {
                'ok': true,
                ...identity,
                'registrationEnabled': true,
                'emailVerificationRequired': false,
                'termsVersion': AppAccountAgreement.termsVersion,
                'privacyVersion': AppAccountAgreement.privacyVersion,
              },
              200,
            ),
          ),
        );

        await expectLater(
          client.health(),
          throwsA(
            isA<CommunityApiException>()
                .having(
                  (error) => error.category,
                  'category',
                  CommunityApiErrorCategory.configuration,
                )
                .having(
                  (error) => error.code,
                  'code',
                  'incompatible_server',
                )
                .having(
                  (error) => error.details,
                  'details',
                  identity,
                ),
          ),
        );
      }
    });

    test('register sends the exact endpoint and camelCase body', () async {
      late http.Request captured;
      final client = CommunityApiClient(
        baseUri: Uri.parse('https://share.example.com/api'),
        httpClient: MockClient((request) async {
          captured = request;
          return _jsonResponse(
            {
              ...authJson(verified: false),
              'verificationEmailSent': true,
            },
            201,
          );
        }),
      );

      final result = await client.register(
        AppRegisterRequest(
          email: 'maker@example.com',
          handle: 'maker_01',
          displayName: '打印玩家',
          password: 'StrongPassword123',
          acceptTerms: true,
        ),
      );

      expect(captured.method, 'POST');
      expect(
        captured.url.toString(),
        'https://share.example.com/api/v1/auth/register',
      );
      expect(jsonDecode(captured.body), {
        'email': 'maker@example.com',
        'handle': 'maker_01',
        'displayName': '打印玩家',
        'password': 'StrongPassword123',
        'acceptTerms': true,
        'termsVersion': AppAccountAgreement.termsVersion,
        'privacyVersion': AppAccountAgreement.privacyVersion,
      });
      expect(captured.headers['Authorization'], isNull);
      expect(result.verificationRequired, isTrue);
      expect(result.verificationEmailSent, isTrue);
      expect(result.session.serverBaseUrl, 'https://share.example.com/api');
    });

    test('login and refresh follow the agreed payloads', () async {
      final requests = <http.Request>[];
      final client = CommunityApiClient(
        baseUri: Uri.parse('https://share.example.com'),
        httpClient: MockClient((request) async {
          requests.add(request);
          return _jsonResponse(authJson(), 200);
        }),
      );

      final session = await client.login(
        AppLoginRequest(email: 'maker@example.com', password: 'secret'),
      );
      await client.refresh(
        refreshToken: session.refreshToken,
        currentUser: session.user,
      );

      expect(requests[0].url.path, '/v1/auth/login');
      expect(jsonDecode(requests[0].body), {
        'email': 'maker@example.com',
        'password': 'secret',
      });
      expect(requests[1].url.path, '/v1/auth/refresh');
      expect(jsonDecode(requests[1].body), {
        'refreshToken': 'refresh-token',
      });
    });

    test('GET and PATCH me attach Bearer tokens', () async {
      final requests = <http.Request>[];
      final client = CommunityApiClient(
        baseUri: Uri.parse('https://share.example.com'),
        httpClient: MockClient((request) async {
          requests.add(request);
          return _jsonResponse({'user': userJson()}, 200);
        }),
      );

      await client.me(accessToken: 'access-token');
      await client.updateMe(
        accessToken: 'access-token',
        request: AppUserUpdateRequest(displayName: '新名字'),
      );

      expect(requests[0].method, 'GET');
      expect(requests[0].url.path, '/v1/me');
      expect(requests[0].headers['Authorization'], 'Bearer access-token');
      expect(requests[1].method, 'PATCH');
      expect(requests[1].headers['Authorization'], 'Bearer access-token');
      expect(jsonDecode(requests[1].body), {'displayName': '新名字'});
    });

    test('logout accepts an empty 204 response', () async {
      late http.Request captured;
      final client = CommunityApiClient(
        baseUri: Uri.parse('https://share.example.com'),
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response('', 204);
        }),
      );

      await client.logout(
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
      );

      expect(captured.url.path, '/v1/auth/logout');
      expect(captured.headers['Authorization'], 'Bearer access-token');
      expect(jsonDecode(captured.body), {'refreshToken': 'refresh-token'});
    });

    test('account policy and lifecycle endpoints follow the server contract',
        () async {
      final requests = <http.Request>[];
      final client = CommunityApiClient(
        baseUri: Uri.parse('https://share.example.com'),
        httpClient: MockClient((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/v1/policies/privacy/current':
              return _jsonResponse(
                {
                  'policy': {
                    'type': 'privacy',
                    'version': '2026-07-29',
                    'current': true,
                    'title': 'sohun 隐私政策',
                    'effectiveAt': '2026-07-29T00:00:00.000Z',
                    'content': '可阅读的政策正文',
                  },
                },
                200,
              );
            case '/v1/me/email-verification/confirm':
              return _jsonResponse({'user': userJson()}, 200);
            case '/v1/auth/password-reset/request':
              return _jsonResponse({'ok': true}, 202);
            default:
              return _jsonResponse({'ok': true}, 200);
          }
        }),
      );

      final policy = await client.fetchAccountPolicy(
        AppAccountPolicyType.privacy,
      );
      await client.requestEmailVerification(accessToken: 'access-token');
      final verified = await client.confirmEmailVerification(
        accessToken: 'access-token',
        code: '12345678',
      );
      await client.requestPasswordReset(
        AppPasswordResetRequest('maker@example.com'),
      );
      await client.confirmPasswordReset(
        AppPasswordResetConfirmation(
          email: 'maker@example.com',
          code: '87654321',
          newPassword: 'NewStrongPass123',
        ),
      );
      await client.deleteAccount(
        accessToken: 'access-token',
        request: AppAccountDeletionRequest('StrongPass123'),
      );

      expect(policy.content, '可阅读的政策正文');
      expect(verified.emailVerified, isTrue);
      expect(
        requests.map((request) => request.url.path),
        [
          '/v1/policies/privacy/current',
          '/v1/me/email-verification/request',
          '/v1/me/email-verification/confirm',
          '/v1/auth/password-reset/request',
          '/v1/auth/password-reset/confirm',
          '/v1/me',
        ],
      );
      expect(
        requests[1].headers['Authorization'],
        'Bearer access-token',
      );
      expect(jsonDecode(requests[2].body), {'code': '12345678'});
      expect(jsonDecode(requests[3].body), {'email': 'maker@example.com'});
      expect(jsonDecode(requests[4].body), {
        'email': 'maker@example.com',
        'code': '87654321',
        'newPassword': 'NewStrongPass123',
      });
      expect(requests[5].method, 'DELETE');
      expect(jsonDecode(requests[5].body), {
        'password': 'StrongPass123',
        'confirmation': 'DELETE',
      });
    });

    test('author reputation parses the current score field', () async {
      late http.Request captured;
      final client = CommunityApiClient(
        baseUri: Uri.parse('https://share.example.com'),
        httpClient: MockClient((request) async {
          captured = request;
          return _jsonResponse(
            {
              'data': {
                'handle': 'maker_01',
                'displayName': '打印玩家',
                'publicPresets': 8,
                'nonAuthorSamples': 24,
                'meetsThreshold': true,
                'score': 86.5,
                'badgeLabel': '高可信作者',
                'uniqueUsers': 12,
                'uniquePresetCoverage': 5,
              },
            },
            200,
          );
        }),
      );

      final reputation = await client.fetchAuthorReputation(
        handle: 'maker_01',
      );

      expect(captured.url.path, '/v1/authors/maker_01/reputation');
      expect(reputation.handle, 'maker_01');
      expect(reputation.displayName, '打印玩家');
      expect(reputation.score, 86.5);
      expect(reputation.uniqueUsers, 12);
      expect(reputation.uniquePresetCoverage, 5);
    });

    test('author reputation accepts the legacy reputationScore field',
        () async {
      final client = CommunityApiClient(
        baseUri: Uri.parse('https://share.example.com'),
        httpClient: MockClient(
          (_) async => _jsonResponse(
            {
              'handle': 'legacy_maker',
              'publicPresets': 3,
              'nonAuthorSamples': 11,
              'meetsThreshold': true,
              'reputationScore': 74.25,
            },
            200,
          ),
        ),
      );

      final reputation = await client.fetchAuthorReputation(
        handle: 'legacy_maker',
      );

      expect(reputation.handle, 'legacy_maker');
      expect(reputation.displayName, 'legacy_maker');
      expect(reputation.score, 74.25);
      expect(reputation.uniqueUsers, 0);
      expect(reputation.uniquePresetCoverage, 0);
    });
  });

  group('CommunityApiClient errors', () {
    test('preserves a server-provided Chinese message and category', () async {
      final client = CommunityApiClient(
        baseUri: Uri.parse('https://share.example.com'),
        httpClient: MockClient(
          (_) async => _jsonResponse(
            {'message': '该邮箱已经注册', 'code': 'EMAIL_EXISTS'},
            409,
          ),
        ),
      );

      expect(
        () => client.register(
          AppRegisterRequest(
            email: 'maker@example.com',
            handle: 'maker_01',
            displayName: '打印玩家',
            password: 'StrongPassword123',
            acceptTerms: true,
          ),
        ),
        throwsA(
          isA<CommunityApiException>()
              .having((e) => e.message, 'message', '该邮箱已经注册')
              .having(
                (e) => e.category,
                'category',
                CommunityApiErrorCategory.conflict,
              )
              .having((e) => e.code, 'code', 'EMAIL_EXISTS'),
        ),
      );
    });

    test('rejects a non-object success response as a protocol error', () async {
      final client = CommunityApiClient(
        baseUri: Uri.parse('https://share.example.com'),
        httpClient: MockClient(
          (_) async => http.Response.bytes(
            utf8.encode('[]'),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );

      expect(
        () => client.me(accessToken: 'access-token'),
        throwsA(
          isA<CommunityApiException>().having(
            (e) => e.category,
            'category',
            CommunityApiErrorCategory.protocol,
          ),
        ),
      );
    });

    test('classifies request timeout', () async {
      final client = CommunityApiClient(
        baseUri: Uri.parse('https://share.example.com'),
        requestTimeout: const Duration(milliseconds: 1),
        httpClient: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _jsonResponse({'user': userJson()}, 200);
        }),
      );

      expect(
        () => client.me(accessToken: 'access-token'),
        throwsA(
          isA<CommunityApiException>().having(
            (e) => e.category,
            'category',
            CommunityApiErrorCategory.timeout,
          ),
        ),
      );
    });
  });
}

http.Response _jsonResponse(Object body, int statusCode) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
