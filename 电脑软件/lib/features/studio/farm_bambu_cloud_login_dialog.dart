import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/external/printer/bambu_cloud_models.dart';
import '../../providers/bambu_account_manager.dart';
import '../../providers/bambu_cloud_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_theme.dart';
import 'farm_ui/farm_feedback.dart';

Future<void> showFarmBambuCloudLoginDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const FarmBambuCloudLoginDialog(),
  );
}

class FarmBambuCloudLoginDialog extends ConsumerStatefulWidget {
  const FarmBambuCloudLoginDialog({super.key});

  @override
  ConsumerState<FarmBambuCloudLoginDialog> createState() =>
      _FarmBambuCloudLoginDialogState();
}

class _FarmBambuCloudLoginDialogState
    extends ConsumerState<FarmBambuCloudLoginDialog> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  BambuRegion _region = BambuRegion.china;
  bool _obscurePassword = true;
  bool _finishing = false;

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final account = _account.text.trim();
    final password = _password.text;
    if (account.isEmpty || password.isEmpty) {
      showSnack(
        context,
        _region == BambuRegion.china ? '请填写手机号和密码' : '请填写邮箱和密码',
        error: true,
      );
      return;
    }
    final ok = await ref.read(bambuCloudProvider.notifier).loginWithPassword(
          region: _region,
          account: account,
          password: password,
        );
    if (!mounted || !ok) return;
    final state = ref.read(bambuCloudProvider);
    if (state.isLoggedIn && !state.isAwaitingCode) {
      await _finishLogin(account);
    }
  }

  Future<void> _verifyCode() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      showSnack(context, '请输入验证码', error: true);
      return;
    }
    final ok = await ref.read(bambuCloudProvider.notifier).loginWithCode(code);
    if (mounted && ok) {
      await _finishLogin(
        ref.read(bambuCloudProvider).session?.email ?? '拓竹账号',
      );
    }
  }

  Future<void> _finishLogin([String? account]) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    try {
      await ref
          .read(allCloudDevicesProvider.notifier)
          .refresh(forceRefresh: true);
      if (!mounted) return;
      final devices = ref.read(allCloudDevicesProvider).devices.length;
      unawaited(
        recordCurrentFarmActivity(
          ref,
          actionCode: 'printer.cloud_account_synced',
          entityType: 'printer_account',
          entityId: account ?? 'saved_accounts',
          summary: '同步拓竹云端账号及 $devices 台设备',
        ).catchError((Object _) {}),
      );
      showSnack(context, '拓竹账号已登录，已同步 $devices 台云端设备');
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _finishing = false);
      showSnack(context, '云端设备同步失败：$error', error: true);
    }
  }

  void _close() {
    ref.read(bambuCloudProvider.notifier).cancelPendingLogin();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cloud = ref.watch(bambuCloudProvider);
    final accounts = ref.watch(bambuAccountManagerProvider).accounts;
    final devices = ref.watch(allCloudDevicesProvider).devices;
    final waitingCode = cloud.isAwaitingCode;
    final pending = cloud.pendingAccount;
    final busy = cloud.isLoading || _finishing;
    final scheme = Theme.of(context).colorScheme;

    return Dialog(
      key: const ValueKey('farm-bambu-cloud-login-dialog'),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FarmPalette.radius),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: FarmVisual.primary.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(FarmPalette.radius),
                    ),
                    child: Icon(
                      Icons.cloud_outlined,
                      color: FarmVisual.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '拓竹账号',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text('登录后自动同步账号下的云端打印机'),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭拓竹账号登录',
                    onPressed: busy ? null : _close,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              if (accounts.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(FarmPalette.radius),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.account_circle_outlined, size: 19),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '已登录 ${accounts.length} 个拓竹账号 · 已同步 ${devices.length} 台设备',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      TextButton(
                        onPressed: busy ? null : () => _finishLogin(),
                        child: const Text('立即同步'),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (!waitingCode) ...[
                Row(
                  children: [
                    const Text('账号区域'),
                    const SizedBox(width: 10),
                    ChoiceChip(
                      key: const ValueKey('farm-bambu-region-china'),
                      label: const Text('中国区'),
                      selected: _region == BambuRegion.china,
                      onSelected: busy
                          ? null
                          : (_) => setState(() => _region = BambuRegion.china),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      key: const ValueKey('farm-bambu-region-overseas'),
                      label: const Text('海外区'),
                      selected: _region == BambuRegion.overseas,
                      onSelected: busy
                          ? null
                          : (_) =>
                              setState(() => _region = BambuRegion.overseas),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('farm-bambu-account'),
                  controller: _account,
                  enabled: !busy,
                  keyboardType: _region == BambuRegion.china
                      ? TextInputType.phone
                      : TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: _region == BambuRegion.china ? '手机号' : '邮箱地址',
                    prefixIcon: Icon(
                      _region == BambuRegion.china
                          ? Icons.phone_android_outlined
                          : Icons.mail_outline,
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('farm-bambu-password'),
                  controller: _password,
                  enabled: !busy,
                  obscureText: _obscurePassword,
                  onSubmitted: (_) => _login(),
                  decoration: InputDecoration(
                    labelText: '密码',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                      onPressed: busy
                          ? null
                          : () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 13),
                FilledButton.icon(
                  key: const ValueKey('farm-bambu-login'),
                  onPressed: busy ? null : _login,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login_rounded),
                  label: const Text('登录拓竹账号'),
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: FarmVisual.primary.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(FarmPalette.radius),
                  ),
                  child: Text(
                    '验证码已发送至 ${pending?.account ?? '当前账号'}，请输入短信或邮件中的验证码。',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('farm-bambu-code'),
                  controller: _code,
                  enabled: !busy,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _verifyCode(),
                  decoration: const InputDecoration(
                    labelText: '验证码',
                    prefixIcon: Icon(Icons.password_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: busy
                          ? null
                          : () =>
                              ref.read(bambuCloudProvider.notifier).sendCode(),
                      child: const Text('重新发送'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      key: const ValueKey('farm-bambu-verify'),
                      onPressed: busy ? null : _verifyCode,
                      icon: const Icon(Icons.verified_outlined),
                      label: const Text('确认并同步设备'),
                    ),
                  ],
                ),
              ],
              if (cloud.errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  cloud.errorMessage!,
                  style: TextStyle(color: scheme.error, fontSize: 11),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                _region == BambuRegion.china
                    ? '中国区使用手机号登录，验证码通过短信发送。账号凭据和 Token 加密保存在本机。'
                    : '海外区使用邮箱登录，验证码通过邮件发送。账号凭据和 Token 加密保存在本机。',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
