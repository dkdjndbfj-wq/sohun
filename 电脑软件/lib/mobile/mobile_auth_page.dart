import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/glass_button_theme.dart';
import '../core/theme/interaction_effects.dart';
import '../core/utils/friendly_error.dart';
import '../data/external/community/community_api_client.dart';
import '../data/models/app_auth.dart';
import '../providers/app_auth_provider.dart';
import 'mobile_brand_launch.dart';
import 'mobile_visual_theme.dart';

enum MobileAuthMode { login, register, reset }

/// Mobile presentation only: credentials, policies and session persistence
/// continue through the same validated account provider as the desktop app.
class MobileAuthPage extends ConsumerStatefulWidget {
  const MobileAuthPage({
    super.key,
    this.initialMode = MobileAuthMode.login,
    this.email = '',
  });
  final MobileAuthMode initialMode;
  final String email;

  @override
  ConsumerState<MobileAuthPage> createState() => _MobileAuthPageState();
}

class _MobileAuthPageState extends ConsumerState<MobileAuthPage> {
  final _formKey = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.email);
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _handle = TextEditingController();
  final _name = TextEditingController();
  final _code = TextEditingController();
  late MobileAuthMode _mode = widget.initialMode;
  bool _busy = false;
  bool _obscure = true;
  bool _accepted = false;
  String? _error;
  String? _notice;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    for (final controller in [
      _email,
      _password,
      _confirmation,
      _handle,
      _name,
      _code,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changeMode(MobileAuthMode mode) {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _formKey.currentState?.reset();
    setState(() {
      _mode = mode;
      _error = null;
      _notice = null;
      _password.clear();
      _confirmation.clear();
      _code.clear();
      _obscure = true;
    });
  }

  String? _emailError(String? value) =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value?.trim() ?? '')
      ? null
      : '请输入有效的邮箱地址';

  String? _passwordError(String? value) {
    if (value == null || value.isEmpty) return '请输入密码';
    if (_mode == MobileAuthMode.login) return null;
    if (value.length < 10 || value.length > 128) return '密码须为 10–128 个字符';
    if (!RegExp(r'[A-Z]').hasMatch(value) ||
        !RegExp(r'[a-z]').hasMatch(value) ||
        !RegExp(r'\d').hasMatch(value)) {
      return '请包含大写字母、小写字母和数字';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    if (_mode == MobileAuthMode.register && !_accepted) {
      setState(() => _error = '请阅读并同意服务条款和隐私政策');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final notifier = ref.read(appAuthProvider.notifier);
      switch (_mode) {
        case MobileAuthMode.login:
          await notifier.login(
            AppLoginRequest(email: _email.text, password: _password.text),
          );
        case MobileAuthMode.register:
          await notifier.register(
            AppRegisterRequest(
              email: _email.text,
              password: _password.text,
              handle: _handle.text,
              displayName: _name.text,
              acceptTerms: _accepted,
            ),
          );
        case MobileAuthMode.reset:
          await notifier.confirmPasswordReset(
            email: _email.text,
            code: _code.text,
            newPassword: _password.text,
          );
          if (!mounted) return;
          _password.clear();
          _confirmation.clear();
          _code.clear();
          setState(() {
            _mode = MobileAuthMode.login;
            _notice = '密码已更新，请使用新密码登录。';
          });
          return;
      }
      if (!mounted) return;
      TextInput.finishAutofillContext();
      // Let PopScope allow the successful navigation as well as blocking
      // accidental back gestures while the request is in progress.
      setState(() => _busy = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(true);
      });
    } catch (error) {
      if (mounted) setState(() => _error = mobileAccountError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendResetCode() async {
    if (_busy || _cooldown > 0) return;
    final emailError = _emailError(_email.text);
    if (emailError != null) {
      setState(() => _error = emailError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await ref
          .read(appAuthProvider.notifier)
          .requestPasswordReset(_email.text);
      if (!mounted) return;
      setState(() {
        _notice = '若该邮箱已注册，你将收到 8 位验证码，请同时检查垃圾邮件。';
        _cooldown = 60;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _cooldown--);
        if (_cooldown <= 0) timer.cancel();
      });
    } catch (error) {
      if (mounted) setState(() => _error = mobileAccountError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = ref.watch(
      appAuthProvider.select((state) => state.endpoint != null),
    );
    final register = _mode == MobileAuthMode.register;
    final reset = _mode == MobileAuthMode.reset;
    final title = reset
        ? '找回密码'
        : register
        ? '创建你的账号'
        : '欢迎回到 sohun';
    final action = reset
        ? '更新密码'
        : register
        ? '创建账号'
        : '登录';
    return PopScope(
      canPop: !_busy,
      child: MobileScaffold(
        appBar: AppBar(
          flexibleSpace: const MobileGlassBar(),
          title: Text(reset ? '账号安全' : 'sohun 账号'),
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: MobileGlassSurface(
                  padding: const EdgeInsets.all(18),
                  opacity: 0.5,
                  elevated: true,
                  child: AutofillGroup(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: reset
                                ? Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(15),
                                    ),
                                    child: Icon(
                                      reset
                                          ? Icons.lock_reset_rounded
                                          : Icons.layers_outlined,
                                      color: theme.colorScheme.primary,
                                      size: 26,
                                    ),
                                  )
                                : const MobileBrandMark(size: 56),
                          ),
                          const SizedBox(height: 20),
                          Text(title, style: theme.textTheme.displaySmall),
                          const SizedBox(height: 8),
                          Text(
                            reset
                                ? '通过注册邮箱验证身份，设置新密码。'
                                : '手机登记，桌面管理。每一卷耗材都有迹可循。',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 24),
                          if (!reset) ...[
                            GlassSegmentedSurface(
                              child: SegmentedButton<MobileAuthMode>(
                                showSelectedIcon: false,
                                segments: const [
                                  ButtonSegment(
                                    value: MobileAuthMode.login,
                                    label: Text('登录'),
                                  ),
                                  ButtonSegment(
                                    value: MobileAuthMode.register,
                                    label: Text('注册'),
                                  ),
                                ],
                                selected: {_mode},
                                onSelectionChanged: _busy
                                    ? null
                                    : (value) => _changeMode(value.first),
                              ),
                            ),
                            const SizedBox(height: 24),
                          ],
                          if (!configured) ...[
                            const MobileAccountMessage(
                              message: '此版本尚未配置账号服务。你仍可返回使用本机库存。',
                              error: true,
                            ),
                            const SizedBox(height: 16),
                          ],
                          TextFormField(
                            key: const ValueKey('mobile-auth-email'),
                            controller: _email,
                            enabled: !_busy,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            autocorrect: false,
                            autofillHints: const [
                              AutofillHints.username,
                              AutofillHints.email,
                            ],
                            validator: _emailError,
                            decoration: const InputDecoration(
                              labelText: '邮箱',
                              hintText: 'name@example.com',
                              prefixIcon: Icon(
                                Icons.alternate_email_rounded,
                                size: 20,
                              ),
                            ),
                          ),
                          if (register) ...[
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _handle,
                              enabled: !_busy,
                              autocorrect: false,
                              textInputAction: TextInputAction.next,
                              validator: (value) =>
                                  RegExp(
                                    r'^[a-z0-9][a-z0-9_.-]{2,29}$',
                                  ).hasMatch(value?.trim() ?? '')
                                  ? null
                                  : '使用 3–30 位小写字母、数字、点、下划线或短横线',
                              decoration: const InputDecoration(
                                labelText: '用户名',
                                hintText: '用于识别你的账号',
                                prefixIcon: Icon(
                                  Icons.person_outline_rounded,
                                  size: 20,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _name,
                              enabled: !_busy,
                              maxLength: 40,
                              textInputAction: TextInputAction.next,
                              validator: (value) =>
                                  value?.trim().isNotEmpty == true
                                  ? null
                                  : '请输入昵称',
                              decoration: const InputDecoration(
                                labelText: '昵称',
                                counterText: '',
                                prefixIcon: Icon(
                                  Icons.badge_outlined,
                                  size: 20,
                                ),
                              ),
                            ),
                          ],
                          if (reset) ...[
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _code,
                              enabled: !_busy,
                              keyboardType: TextInputType.number,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.oneTimeCode],
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(8),
                              ],
                              validator: (value) =>
                                  RegExp(r'^\d{8}$').hasMatch(value ?? '')
                                  ? null
                                  : '请输入 8 位验证码',
                              decoration: const InputDecoration(
                                labelText: '邮箱验证码',
                                prefixIcon: Icon(
                                  Icons.mark_email_read_outlined,
                                  size: 20,
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: !configured || _busy || _cooldown > 0
                                    ? null
                                    : _sendResetCode,
                                child: Text(
                                  _cooldown > 0 ? '${_cooldown}s 后重发' : '发送验证码',
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          TextFormField(
                            key: const ValueKey('mobile-auth-password'),
                            controller: _password,
                            enabled: !_busy,
                            obscureText: _obscure,
                            enableSuggestions: false,
                            autocorrect: false,
                            textInputAction: register || reset
                                ? TextInputAction.next
                                : TextInputAction.done,
                            autofillHints: [
                              register || reset
                                  ? AutofillHints.newPassword
                                  : AutofillHints.password,
                            ],
                            validator: _passwordError,
                            onFieldSubmitted: (_) {
                              if (!register && !reset && configured) _submit();
                            },
                            decoration: InputDecoration(
                              labelText: reset ? '新密码' : '密码',
                              helperText: register || reset
                                  ? '10–128 位，包含大写字母、小写字母和数字'
                                  : null,
                              helperMaxLines: 3,
                              prefixIcon: const Icon(
                                Icons.lock_outline_rounded,
                                size: 20,
                              ),
                              suffixIcon: IconButton(
                                tooltip: _obscure ? '显示密码' : '隐藏密码',
                                onPressed: _busy
                                    ? null
                                    : () =>
                                          setState(() => _obscure = !_obscure),
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                          if (register || reset) ...[
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _confirmation,
                              enabled: !_busy,
                              obscureText: _obscure,
                              enableSuggestions: false,
                              autocorrect: false,
                              textInputAction: TextInputAction.done,
                              validator: (value) =>
                                  value == _password.text &&
                                      value?.isNotEmpty == true
                                  ? null
                                  : '两次密码不一致',
                              decoration: const InputDecoration(
                                labelText: '确认密码',
                                prefixIcon: Icon(
                                  Icons.lock_outline_rounded,
                                  size: 20,
                                ),
                              ),
                              onFieldSubmitted: (_) {
                                if (configured) _submit();
                              },
                            ),
                          ] else
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _changeMode(MobileAuthMode.reset),
                                child: const Text('忘记密码？'),
                              ),
                            ),
                          if (register) ...[
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Checkbox(
                                  value: _accepted,
                                  onChanged: _busy
                                      ? null
                                      : (value) => setState(
                                          () => _accepted = value ?? false,
                                        ),
                                ),
                                Expanded(
                                  child: Wrap(
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      const Text('我已阅读并同意'),
                                      for (final type
                                          in AppAccountPolicyType.values)
                                        TextButton(
                                          onPressed: _busy
                                              ? null
                                              : () => Navigator.of(context)
                                                    .push<void>(
                                                      MaterialPageRoute(
                                                        builder: (_) =>
                                                            MobileAccountPolicyPage(
                                                              type: type,
                                                            ),
                                                      ),
                                                    ),
                                          child: Text(type.label),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                          AnimatedSize(
                            duration: AppMotion.duration(
                              context,
                              const Duration(milliseconds: 180),
                            ),
                            alignment: Alignment.topCenter,
                            child: _error == null && _notice == null
                                ? const SizedBox.shrink()
                                : Padding(
                                    padding: const EdgeInsets.only(
                                      top: 12,
                                      bottom: 12,
                                    ),
                                    child: MobileAccountMessage(
                                      message: _error ?? _notice!,
                                      error: _error != null,
                                    ),
                                  ),
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            key: const ValueKey('mobile-auth-submit'),
                            onPressed: !configured || _busy ? null : _submit,
                            style: glassButtonStyle(
                              context,
                              FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(50),
                              ),
                            ),
                            child: _busy
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(action),
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : reset
                                ? () => _changeMode(MobileAuthMode.login)
                                : () => Navigator.pop(context),
                            child: Text(reset ? '返回登录' : '暂不登录，继续使用本机库存'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String mobileAccountError(Object error) {
  if (error is CommunityApiException) return error.message;
  // ArgumentError.toString may contain the rejected password value.
  if (error is ArgumentError) return error.message?.toString() ?? '请检查输入内容';
  return friendlyError(error);
}

class MobileAccountMessage extends StatelessWidget {
  const MobileAccountMessage({
    super.key,
    required this.message,
    this.error = false,
  });
  final String message;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = error ? scheme.error : scheme.primary;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MobileAccountPolicyPage extends ConsumerStatefulWidget {
  const MobileAccountPolicyPage({super.key, required this.type});
  final AppAccountPolicyType type;
  @override
  ConsumerState<MobileAccountPolicyPage> createState() =>
      _MobileAccountPolicyPageState();
}

class _MobileAccountPolicyPageState
    extends ConsumerState<MobileAccountPolicyPage> {
  late Future<AppAccountPolicyDocument> _policy = _load();
  Future<AppAccountPolicyDocument> _load() =>
      ref.read(appAuthProvider.notifier).fetchAccountPolicy(widget.type);
  @override
  Widget build(BuildContext context) => MobileScaffold(
    appBar: AppBar(
      flexibleSpace: const MobileGlassBar(),
      title: Text(widget.type.label),
    ),
    body: FutureBuilder<AppAccountPolicyDocument>(
      future: _policy,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MobileAccountMessage(
                    message: mobileAccountError(snapshot.error!),
                    error: true,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => setState(() => _policy = _load()),
                    child: const Text('重新加载'),
                  ),
                ],
              ),
            ),
          );
        }
        final policy = snapshot.data;
        if (policy == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                policy.title,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                '版本 ${policy.version}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              SelectableText(
                policy.content,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        );
      },
    ),
  );
}
