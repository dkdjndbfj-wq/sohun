import 'package:flutter/material.dart';
import '../../../core/theme/glass_button_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/friendly_error.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/external/printer/bambu_cloud_client.dart';
import '../../../data/external/printer/bambu_cloud_models.dart';
import '../../../data/external/printer/bambu_cloud_session_store.dart';
import '../../../providers/onboarding_provider.dart';
import '../../../widgets/confirm_dialog.dart';

/// 步骤2：拓竹云登录。
///
/// 登录流程（复用 [BambuCloudClient] 静态方法）：
/// 1. 输入区域+账号+密码 → [BambuCloudClient.loginWithPassword]
///    - 少数账号直接返回 token
///    - 多数账号返回 needsCode，自动发送验证码
/// 2. 输入验证码 → [BambuCloudClient.loginWithCode] → 拿到 session
/// 3. 保存 session + 拉取设备列表 → 写入 onboardingProvider → next()
///
/// 已登录（[BambuCloudSessionStore.loadSession] 命中）时直接显示「已登录」状态，
/// 点「下一步」进入后续步骤。
class CloudLoginStep extends ConsumerStatefulWidget {
  const CloudLoginStep({super.key});

  @override
  ConsumerState<CloudLoginStep> createState() => _CloudLoginStepState();
}

class _CloudLoginStepState extends ConsumerState<CloudLoginStep> {
  final _accountCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  BambuRegion _region = BambuRegion.china;
  bool _obscurePassword = true;

  /// 已存在的 session（initState 时从 store 读取）
  BambuCloudSession? _existingSession;

  /// 是否进入验证码阶段
  bool _needsCode = false;

  /// 验证码阶段暂存的账号信息
  _PendingLogin? _pendingLogin;

  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    _accountCtrl.dispose();
    _passwordCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    final session = await BambuCloudSessionStore.loadSession();
    if (!mounted) return;
    if (session != null && !session.isExpired) {
      setState(() => _existingSession = session);
    }
  }

  Future<void> _submitPassword() async {
    final account = _accountCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (account.isEmpty || password.isEmpty) {
      setState(
        () => _error = _region == BambuRegion.china ? '请填写手机号和密码' : '请填写邮箱和密码',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final result = await BambuCloudClient.loginWithPassword(
        region: _region,
        account: account,
        password: password,
      );
      if (result.needsVerificationCode) {
        // 进入验证码阶段，自动发送验证码
        _pendingLogin = _PendingLogin(
          region: _region,
          account: account,
          password: password,
        );
        await BambuCloudClient.sendVerificationCode(
          region: _region,
          account: account,
        );
        if (!mounted) return;
        setState(() {
          _needsCode = true;
          _isLoading = false;
        });
        return;
      }
      // 直接拿到 token
      final session = result.session!;
      await _completeLogin(session, account: account, password: password);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _submitCode() async {
    final pending = _pendingLogin;
    if (pending == null) return;
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '请输入验证码');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final session = await BambuCloudClient.loginWithCode(
        region: pending.region,
        account: pending.account,
        code: code,
      );
      await _completeLogin(
        session,
        account: pending.account,
        password: pending.password,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _resendCode() async {
    final pending = _pendingLogin;
    if (pending == null) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await BambuCloudClient.sendVerificationCode(
        region: pending.region,
        account: pending.account,
      );
      if (!mounted) return;
      setState(() => _isLoading = false);
      if (mounted) {
        showSnack(context, '验证码已重新发送');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = '发送验证码失败：${friendlyError(e)}';
      });
    }
  }

  /// 完成登录：保存 session + 拉取设备列表 + 写入 onboardingProvider + next。
  Future<void> _completeLogin(
    BambuCloudSession session, {
    required String account,
    required String password,
  }) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      // 保存账号凭据（用于 token 过期后自动重登）+ session
      await BambuCloudSessionStore.saveAccount(
        BambuCloudAccount(
          region: session.region,
          email: account,
          password: password,
        ),
      );
      await BambuCloudSessionStore.saveSession(session);

      // 拉取设备列表（含 devAccessCode）
      List<BambuCloudDevice> devices;
      try {
        devices = await BambuCloudClient.getDeviceList(session);
      } catch (_) {
        // 设备列表拉取失败不阻塞流程，记为空
        devices = [];
      }

      if (!mounted) return;
      ref
          .read(onboardingProvider.notifier)
          .setCloudResult(session: session, devices: devices);
      ref.read(onboardingProvider.notifier).next();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = friendlyError(e);
      });
    }
  }

  void _skip() {
    ref.read(onboardingProvider.notifier).next();
  }

  /// 已登录状态：直接进入下一步（不重新拉设备，避免重复请求）。
  Future<void> _proceedWithExistingSession() async {
    final session = _existingSession;
    if (session == null) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    List<BambuCloudDevice> devices;
    try {
      devices = await BambuCloudClient.getDeviceList(session);
    } catch (_) {
      devices = [];
    }
    if (!mounted) return;
    ref
        .read(onboardingProvider.notifier)
        .setCloudResult(session: session, devices: devices);
    ref.read(onboardingProvider.notifier).next();
  }

  @override
  Widget build(BuildContext context) {
    // 已登录态
    if (_existingSession != null) {
      return _buildLoggedIn();
    }
    // 验证码阶段
    if (_needsCode) {
      return _buildCodeInput();
    }
    // 密码登录表单
    return _buildPasswordForm();
  }

  // ===== 已登录态 =====
  Widget _buildLoggedIn() {
    final session = _existingSession!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '登录拓竹账号',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '远程读取打印机状态（电脑和打印机可在不同网络）',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.successContainer,
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                size: 20,
                color: AppColors.success,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '已登录：${session.email}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      session.region == BambuRegion.china ? '中国区' : '海外区',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _isLoading ? null : _proceedWithExistingSession,
                icon: _isLoading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward_rounded, size: 16),
                label: const Text('下一步'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton(
            onPressed: _isLoading
                ? null
                : () {
                    // 退出已登录态，回到登录表单重新登录
                    setState(() => _existingSession = null);
                  },
            child: Text(
              '切换账号',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ===== 密码登录表单 =====
  Widget _buildPasswordForm() {
    final isChina = _region == BambuRegion.china;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '登录拓竹账号',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '远程读取打印机状态（电脑和打印机可在不同网络）',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        // 区域选择
        Row(
          children: [
            Text(
              '账号区域：',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('中国区'),
              selected: isChina,
              onSelected: (_) => setState(() => _region = BambuRegion.china),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('海外区'),
              selected: !isChina,
              onSelected: (_) => setState(() => _region = BambuRegion.overseas),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 账号
        TextField(
          controller: _accountCtrl,
          decoration: InputDecoration(
            labelText: isChina ? '手机号' : '邮箱',
            hintText: isChina ? '请输入手机号' : 'your@email.com',
            prefixIcon: Icon(
              isChina ? Icons.phone_android_outlined : Icons.mail_outline,
              size: 18,
            ),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          keyboardType: isChina
              ? TextInputType.phone
              : TextInputType.emailAddress,
        ),
        const SizedBox(height: 10),
        // 密码
        TextField(
          controller: _passwordCtrl,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            labelText: '密码',
            border: const OutlineInputBorder(),
            isDense: true,
            prefixIcon: const Icon(Icons.lock_outline, size: 18),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 18,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          onSubmitted: (_) => _submitPassword(),
        ),
        const SizedBox(height: 14),
        // 登录按钮
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isLoading ? null : _submitPassword,
            icon: _isLoading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login, size: 16),
            label: const Text('登录'),
          ),
        ),
        const SizedBox(height: 10),
        if (_error != null) _ErrorBanner(message: _error!),
        const SizedBox(height: 8),
        Text(
          '密码仅用于验证身份，验证码将通过短信/邮件发送。登录后 token 加密存储在本机。',
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: _isLoading ? null : _skip,
            child: Text(
              '跳过，稍后登录',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ===== 验证码输入 =====
  Widget _buildCodeInput() {
    final account = _pendingLogin?.account ?? '';
    final isPhone = !account.contains('@');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '登录拓竹账号',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '请输入收到的验证码完成登录',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.infoContainer,
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
          ),
          child: Row(
            children: [
              const Icon(Icons.sms_outlined, size: 18, color: AppColors.info),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '验证码已发送到 ${isPhone ? "手机" : "邮箱"}：\n$account',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _codeCtrl,
          decoration: const InputDecoration(
            labelText: '验证码',
            hintText: '请输入收到的验证码',
            prefixIcon: Icon(Icons.password_outlined, size: 18),
            border: OutlineInputBorder(),
            isDense: true,
          ),
          keyboardType: TextInputType.number,
          onSubmitted: (_) => _submitCode(),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isLoading ? null : _submitCode,
            icon: _isLoading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded, size: 16),
            label: const Text('验证并登录'),
          ),
        ),
        const SizedBox(height: 10),
        if (_error != null) _ErrorBanner(message: _error!),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            onPressed: _isLoading ? null : _resendCode,
            icon: const Icon(Icons.refresh_rounded, size: 14),
            label: const Text('重新发送验证码'),
            style: glassButtonStyle(
              context,
              TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
              ),
              variant: AppGlassButtonVariant.quiet,
            ),
          ),
        ),
      ],
    );
  }
}

/// 验证码阶段暂存的账号信息。
class _PendingLogin {
  final BambuRegion region;
  final String account;
  final String password;
  _PendingLogin({
    required this.region,
    required this.account,
    required this.password,
  });
}

/// 错误提示条。
class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.dangerContainer,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 14,
            color: AppColors.danger,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 11, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}
