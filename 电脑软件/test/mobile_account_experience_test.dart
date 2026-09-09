import 'dart:async';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_account_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_auth_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_visual_theme.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('登录字段校验、密码可见性、重复提交和失败重试', (tester) async {
    final api = _AccountApi()..pendingLogin = Completer<AppAuthSession>();
    final harness = await _mount(
      tester,
      api: api,
      page: const MobileAuthPage(),
    );
    final submit = find.byKey(const ValueKey('mobile-auth-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('请输入有效的邮箱地址'), findsOneWidget);
    expect(api.loginCalls, 0);
    await tester.enterText(
      find.byKey(const ValueKey('mobile-auth-email')),
      'maker@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mobile-auth-password')),
      'SecretPass123',
    );
    await tester.tap(find.byTooltip('显示密码'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('mobile-auth-password')),
          )
          .controller!
          .text,
      'SecretPass123',
    );
    expect(find.byTooltip('隐藏密码'), findsOneWidget);
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    expect(api.loginCalls, 1);
    api.pendingLogin!.completeError(
      const CommunityApiException(
        '邮箱或密码不正确',
        category: CommunityApiErrorCategory.authentication,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('邮箱或密码不正确'), findsOneWidget);
    api.pendingLogin = null;
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.byType(MobileAuthPage), findsNothing);
    expect(harness.store.value?.user.displayName, '打印玩家');
    expect(api.loginCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('注册必须确认密码并主动同意真实协议，成功后保留验证状态', (tester) async {
    final api = _AccountApi();
    final harness = await _mount(
      tester,
      api: api,
      page: const MobileAuthPage(initialMode: MobileAuthMode.register),
    );
    final fields = find.byType(TextFormField);
    for (final entry in [
      'maker@example.com',
      'maker_01',
      '打印玩家',
      'SecretPass123',
      'SecretPass123',
    ].asMap().entries) {
      await tester.enterText(fields.at(entry.key), entry.value);
    }
    final submit = find.byKey(const ValueKey('mobile-auth-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(api.registration, isNull);
    expect(find.text('请阅读并同意服务条款和隐私政策'), findsOneWidget);
    await tester.ensureVisible(find.text('服务条款'));
    await tester.tap(find.text('服务条款'));
    await tester.pumpAndSettle();
    expect(find.text('来自账号服务的测试政策正文'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.tap(find.byType(Checkbox));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(api.registration?.acceptTerms, isTrue);
    expect(api.registration?.displayName, '打印玩家');
    expect(harness.auth.state.status, AppAuthStatus.awaitingEmailVerification);
    expect(tester.takeException(), isNull);
  });

  testWidgets('找回密码发送验证码有冷却，成功后清空密码并返回登录', (tester) async {
    final api = _AccountApi();
    final harness = await _mount(
      tester,
      api: api,
      page: const MobileAuthPage(
        initialMode: MobileAuthMode.reset,
        email: 'maker@example.com',
      ),
    );
    await tester.tap(find.text('发送验证码'));
    await tester.pumpAndSettle();
    expect(api.resetRequests, 1);
    expect(find.text('60s 后重发'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), '12345678');
    await tester.enterText(fields.at(2), 'NewPassword123');
    await tester.enterText(fields.at(3), 'NewPassword123');
    await tester.ensureVisible(
      find.byKey(const ValueKey('mobile-auth-submit')),
    );
    await tester.tap(find.byKey(const ValueKey('mobile-auth-submit')));
    await tester.pumpAndSettle();
    expect(api.resetConfirmation?.code, '12345678');
    expect(find.text('密码已更新，请使用新密码登录。'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('mobile-auth-password')),
          )
          .controller!
          .text,
      isEmpty,
    );
    expect(harness.store.value, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('个人资料保存使用真实账号接口，退出需要确认', (tester) async {
    final api = _AccountApi();
    final harness = await _mount(
      tester,
      api: api,
      signedIn: true,
      page: _accountPage(),
    );
    await tester.tap(find.text('个人资料'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '新的昵称');
    await tester.enterText(find.byType(TextFormField).last, '喜欢打印实用小物');
    await tester.ensureVisible(find.text('保存资料'));
    await tester.tap(find.text('保存资料'));
    await tester.pumpAndSettle();
    expect(api.profileRequest?.displayName, '新的昵称');
    expect(harness.store.value?.user.displayName, '新的昵称');
    expect(find.text('新的昵称'), findsOneWidget);
    // Let the save snackbar leave before tapping a bottom-of-list action.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('退出登录'),
      250,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.logoutCalls, 0);
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认退出'));
    await tester.pumpAndSettle();
    expect(api.logoutCalls, 1);
    expect(harness.store.value, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('邮箱验证真实提交并更新个人中心状态，不重复发送', (tester) async {
    final api = _AccountApi();
    final harness = await _mount(
      tester,
      api: api,
      signedIn: true,
      page: _accountPage(),
    );
    await tester.tap(find.text('邮箱验证'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送验证码'));
    await tester.pumpAndSettle();
    expect(api.emailRequests, 1);
    await tester.enterText(find.byType(TextField), '12345678');
    await tester.tap(find.text('完成验证'));
    await tester.pumpAndSettle();
    expect(find.text('你的邮箱已验证'), findsOneWidget);
    expect(harness.store.value?.user.emailVerified, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final mode in MobileAuthMode.values) {
    testWidgets('320 宽双倍字号和键盘：${mode.name} 可滚动且无溢出', (tester) async {
      await _mount(
        tester,
        api: _AccountApi(),
        size: const Size(320, 640),
        largeText: true,
        page: MobileAuthPage(initialMode: mode),
      );
      final submit = find.byKey(const ValueKey('mobile-auth-submit'));
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      expect(submit.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  test('表单异常文案不泄露被拒绝的密码', () {
    expect(
      mobileAccountError(
        ArgumentError.value('SecretPass123', 'password', '密码格式不正确'),
      ),
      '密码格式不正确',
    );
  });
}

MobileAccountPage _accountPage() => MobileAccountPage(
  themeMode: ThemeMode.system,
  interactionEffectsEnabled: true,
  onThemeChanged: (_) async {},
  onEffectsChanged: (_) async {},
  onOpenInventory: () {},
);

Future<({AppAuthNotifier auth, _SessionStore store})> _mount(
  WidgetTester tester, {
  required _AccountApi api,
  required Widget page,
  bool signedIn = false,
  Size size = const Size(390, 844),
  bool largeText = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final store = _SessionStore()..value = signedIn ? _session() : null;
  final auth = AppAuthNotifier(
    serverSettings: CommunityServerSettings(
      store: _OverrideStore(),
      compileTimeBaseUrl: 'https://account.example.test',
    ),
    sessionStore: store,
    apiFactory: (_) => api,
  );
  await auth.ready;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appAuthProvider.overrideWith((ref) => auth)],
      child: MaterialApp(
        theme: buildMobileTheme(AppTheme.light()),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(largeText ? 2 : 1),
            viewInsets: largeText
                ? const EdgeInsets.only(bottom: 240)
                : EdgeInsets.zero,
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(
                  context,
                ).push<void>(MaterialPageRoute(builder: (_) => page)),
                child: const Text('打开账号页'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开账号页'));
  await tester.pumpAndSettle();
  return (auth: auth, store: store);
}

AppAuthSession _session() {
  final now = DateTime.now();
  return AppAuthSession(
    user: AppUser(
      id: 'user-1',
      email: 'maker@example.com',
      handle: 'maker_01',
      displayName: '打印玩家',
      emailVerified: false,
      createdAt: now,
      updatedAt: now,
    ),
    accessToken: 'test-access',
    refreshToken: 'test-refresh',
    expiresAt: now.add(const Duration(hours: 1)),
    serverBaseUrl: 'https://account.example.test',
  );
}

class _SessionStore implements AppAuthSessionStore {
  AppAuthSession? value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<AppAuthSession?> read() async => value;
  @override
  Future<void> write(AppAuthSession session) async => value = session;
}

class _OverrideStore implements CommunityServerOverrideStore {
  @override
  Future<void> clear() async {}
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}

class _AccountApi implements CommunityApi {
  Completer<AppAuthSession>? pendingLogin;
  int loginCalls = 0, logoutCalls = 0, resetRequests = 0, emailRequests = 0;
  AppRegisterRequest? registration;
  AppPasswordResetConfirmation? resetConfirmation;
  AppUserUpdateRequest? profileRequest;
  @override
  final Uri baseUri = Uri.parse('https://account.example.test');
  @override
  Future<AppAuthSession> login(AppLoginRequest request) async {
    loginCalls++;
    return pendingLogin?.future ?? _session();
  }

  @override
  Future<CommunityServiceInfo> health() async => const CommunityServiceInfo(
    service: 'sohun',
    apiVersion: 1,
    registrationEnabled: true,
    emailVerificationRequired: true,
    termsVersion: AppAccountAgreement.termsVersion,
    privacyVersion: AppAccountAgreement.privacyVersion,
  );
  @override
  Future<AppRegistrationResult> register(AppRegisterRequest request) async {
    registration = request;
    final session = _session();
    return AppRegistrationResult(
      user: session.user,
      session: session,
      verificationRequired: true,
    );
  }

  @override
  Future<AppAccountPolicyDocument> fetchAccountPolicy(
    AppAccountPolicyType type, {
    String? version,
  }) async => AppAccountPolicyDocument(
    type: type,
    version: AppAccountAgreement.termsVersion,
    isCurrent: true,
    title: type.label,
    effectiveAt: DateTime(2026, 7, 29),
    content: '来自账号服务的测试政策正文',
  );
  @override
  Future<void> requestPasswordReset(AppPasswordResetRequest request) async {
    resetRequests++;
  }

  @override
  Future<void> confirmPasswordReset(
    AppPasswordResetConfirmation confirmation,
  ) async {
    resetConfirmation = confirmation;
  }

  @override
  Future<void> logout({
    required String accessToken,
    required String refreshToken,
  }) async {
    logoutCalls++;
  }

  @override
  Future<AppUser> updateMe({
    required String accessToken,
    required AppUserUpdateRequest request,
  }) async {
    profileRequest = request;
    return _session().user.copyWith(
      displayName: request.displayName,
      bio: request.bio,
    );
  }

  @override
  Future<void> requestEmailVerification({required String accessToken}) async {
    emailRequests++;
  }

  @override
  Future<AppUser> confirmEmailVerification({
    required String accessToken,
    required String code,
  }) async => _session().user.copyWith(emailVerified: true);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
