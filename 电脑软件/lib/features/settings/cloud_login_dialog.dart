import 'dart:async';

import '../../core/theme/glass_button_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/friendly_error.dart';
import '../../data/external/printer/bambu_cloud_models.dart';
import '../../data/external/printer/bambu_lan_discovery.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../providers/bambu_cloud_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/confirm_dialog.dart';
import '../printers/printer_certificate_trust_dialog.dart';

/// 拓竹云连接独立登录窗口。
///
/// 三步登录流程：
/// 1. 输入区域+账号+密码 → loginWithPassword
/// 2. 密码验证通过后自动发送验证码 → 显示验证码输入框
/// 3. 输入验证码 → loginWithCode → 完成
///
/// 适用场景：电脑和打印机不在同一局域网（如电脑在外、打印机在家）。
class CloudLoginDialog extends ConsumerWidget {
  final bool addAccount;

  const CloudLoginDialog({super.key, this.addAccount = false});

  static Future<void> show(BuildContext context, {bool addAccount = false}) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => CloudLoginDialog(addAccount: addAccount),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cloudState = ref.watch(bambuCloudProvider);

    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          ref.read(bambuCloudProvider.notifier).cancelPendingLogin();
        }
      },
      child: Dialog(
        backgroundColor: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppColors.radiusXl),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 640),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 标题栏
                _DialogHeader(onClose: () => Navigator.of(context).pop()),
                const SizedBox(height: 16),
                // 内容区
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (cloudState.isAwaitingCode)
                          _CodeInputContent(
                            cloudState: cloudState,
                            closeOnSuccess: addAccount,
                          )
                        else if (addAccount)
                          const _PasswordLoginForm(closeOnSuccess: true)
                        else if (cloudState.isLoggedIn)
                          _LoggedInContent(cloudState: cloudState)
                        else
                          const _PasswordLoginForm(),
                        // 错误信息
                        if (cloudState.errorMessage != null) ...[
                          const SizedBox(height: 12),
                          _ErrorBanner(message: cloudState.errorMessage!),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 标题栏。
class _DialogHeader extends StatelessWidget {
  final VoidCallback onClose;
  const _DialogHeader({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.primaryContainer,
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
          ),
          child: Icon(Icons.cloud_outlined, size: 20, color: AppColors.primary),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '拓竹云连接',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              SizedBox(height: 2),
              Text(
                '远程读取打印机状态',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded, size: 18),
          color: AppColors.textTertiary,
          onPressed: onClose,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// 第一步：密码登录表单。
class _PasswordLoginForm extends ConsumerStatefulWidget {
  final bool closeOnSuccess;

  const _PasswordLoginForm({this.closeOnSuccess = false});

  @override
  ConsumerState<_PasswordLoginForm> createState() => _PasswordLoginFormState();
}

class _PasswordLoginFormState extends ConsumerState<_PasswordLoginForm> {
  final _accountCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  BambuRegion _region = BambuRegion.china;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _accountCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final account = _accountCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (account.isEmpty || password.isEmpty) {
      showSnack(
        context,
        _region == BambuRegion.china ? '请填写手机号和密码' : '请填写邮箱和密码',
        error: true,
      );
      return;
    }
    // loginWithPassword 内部会自动发送验证码（如果需要）
    final ok = await ref
        .read(bambuCloudProvider.notifier)
        .loginWithPassword(
          region: _region,
          account: account,
          password: password,
        );
    if (!mounted || !ok) return;
    final cloudState = ref.read(bambuCloudProvider);
    if (widget.closeOnSuccess &&
        cloudState.isLoggedIn &&
        !cloudState.isAwaitingCode) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cloudState = ref.watch(bambuCloudProvider);
    final isChina = _region == BambuRegion.china;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 区域选择
        Row(
          children: [
            const Text(
              '账号区域：',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
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
        // 账号输入
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
        // 密码输入
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
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 14),
        // 登录按钮
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: cloudState.isLoading ? null : _submit,
            icon: cloudState.isLoading
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
        Text(
          _region == BambuRegion.china
              ? '密码仅用于验证身份，验证码将通过短信发送到手机。登录后 token 加密存储在本机。'
              : '密码仅用于验证身份，验证码将通过邮件发送到邮箱。登录后 token 加密存储在本机。',
          style: const TextStyle(
            fontSize: 10,
            color: AppColors.textTertiary,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }
}

/// 第二步：验证码输入。
class _CodeInputContent extends ConsumerStatefulWidget {
  final BambuCloudState cloudState;
  final bool closeOnSuccess;

  const _CodeInputContent({
    required this.cloudState,
    this.closeOnSuccess = false,
  });

  @override
  ConsumerState<_CodeInputContent> createState() => _CodeInputContentState();
}

class _CodeInputContentState extends ConsumerState<_CodeInputContent> {
  final _codeCtrl = TextEditingController();

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitCode() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      showSnack(context, '请输入验证码', error: true);
      return;
    }
    final ok = await ref.read(bambuCloudProvider.notifier).loginWithCode(code);
    if (mounted && ok && widget.closeOnSuccess) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _resendCode() async {
    await ref.read(bambuCloudProvider.notifier).sendCode();
    if (mounted) {
      showSnack(context, '验证码已重新发送');
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.cloudState.pendingAccount!.account;
    final isPhone = !account.contains('@');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 提示：验证码已发送
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
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // 验证码输入
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
        // 提交按钮
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: widget.cloudState.isLoading ? null : _submitCode,
            icon: widget.cloudState.isLoading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded, size: 16),
            label: const Text('验证并登录'),
          ),
        ),
        const SizedBox(height: 8),
        // 重新发送
        Center(
          child: TextButton.icon(
            onPressed: widget.cloudState.isLoading ? null : _resendCode,
            icon: const Icon(Icons.refresh_rounded, size: 14),
            label: const Text('重新发送验证码'),
            style: glassButtonStyle(
              context,
              TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
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

/// 已登录内容：session 信息 + 设备列表。
class _LoggedInContent extends ConsumerWidget {
  final BambuCloudState cloudState;
  const _LoggedInContent({required this.cloudState});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SessionInfo(cloudState: cloudState),
        const SizedBox(height: 12),
        if (cloudState.devices.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(AppColors.radiusMd),
            ),
            child: const Center(
              child: Text(
                '账号下没有绑定的打印机',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
              ),
            ),
          )
        else
          for (final d in cloudState.devices)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _CloudDeviceTile(device: d),
            ),
      ],
    );
  }
}

/// 已登录的 session 信息条。
class _SessionInfo extends ConsumerWidget {
  final BambuCloudState cloudState;
  const _SessionInfo({required this.cloudState});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = cloudState.session!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.successContainer,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: AppColors.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已登录：${session.email}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${session.region == BambuRegion.china ? '中国区' : '海外区'} · ${cloudState.devices.length} 台设备',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: cloudState.isLoading
                ? null
                : () => ref.read(bambuCloudProvider.notifier).refreshDevices(),
            icon: const Icon(Icons.refresh_rounded, size: 14),
            label: const Text('刷新'),
            style: glassButtonStyle(
              context,
              TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                visualDensity: VisualDensity.compact,
              ),
              variant: AppGlassButtonVariant.quiet,
            ),
          ),
          // 与「刷新」拉开间距，避免误点
          const SizedBox(width: 12),
          TextButton.icon(
            // 退出后需重走手机号 + 密码 + 验证码三步，必须二次确认
            onPressed: cloudState.isLoading
                ? null
                : () async {
                    final ok = await AppDialog.confirm(
                      context,
                      '退出拓竹账号',
                      '退出后将断开云端连接，云打印机状态与任务历史将不再更新。\n\n'
                          '重新登录需要再次输入账号密码并完成验证码验证。',
                      confirmText: '退出登录',
                      destructive: true,
                    );
                    if (!ok) return;
                    await ref.read(bambuCloudProvider.notifier).logout();
                  },
            icon: const Icon(Icons.logout, size: 14),
            label: const Text('退出'),
            style: glassButtonStyle(
              context,
              TextButton.styleFrom(
                foregroundColor: AppColors.danger,
                visualDensity: VisualDensity.compact,
              ),
              variant: AppGlassButtonVariant.quiet,
            ),
          ),
        ],
      ),
    );
  }
}

/// 云端设备条目。点击后明确选择“云端模式”为活跃打印机。
///
/// LAN 配置可以另外保存，但它与云端模式是独立连接，不会自动覆盖、回退或
/// 复用另一条链路的状态。
class _CloudDeviceTile extends ConsumerWidget {
  final BambuCloudDevice device;
  const _CloudDeviceTile({required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeSerial = ref.watch(activePrinterSerialProvider);
    final activeConfig = ref.watch(activePrinterConfigProvider);
    final isActive =
        device.devId == activeSerial &&
        activeConfig?.mode == BambuConnectionMode.cloud;
    final lanList = ref.watch(printerConnectionListProvider);

    // 查找同 serial 是否另有独立的 LAN 配置
    PrinterConnectionConfig? lanConfig;
    for (final c in lanList) {
      if (c.serial == device.devId) {
        lanConfig = c;
        break;
      }
    }
    final hasLanConfig = lanConfig != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          unawaited(
            ref
                .read(printerConnectionModeSelectionProvider.notifier)
                .select(device.devId, BambuConnectionMode.cloud),
          );
          ref
              .read(activePrinterSerialProvider.notifier)
              .set(isActive ? null : device.devId);
        },
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isActive
                ? AppColors.primaryContainer
                : AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            border: Border.all(
              color: isActive
                  ? AppColors.primary.withValues(alpha: 0.4)
                  : Colors.transparent,
              width: 1.2,
            ),
          ),
          child: Row(
            children: [
              Icon(
                device.online ? Icons.cloud_done_rounded : Icons.cloud_off,
                size: 16,
                color: device.online
                    ? AppColors.success
                    : AppColors.textTertiary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            device.name.isEmpty ? device.devId : device.name,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _ModeChip(
                          isLanSelected:
                              activeSerial == device.devId &&
                              activeConfig?.mode == BambuConnectionMode.lan,
                          hasLanConfig: hasLanConfig,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${device.devProductName} · ${device.devId}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (hasLanConfig) ...[
                      const SizedBox(height: 2),
                      Text(
                        '另有局域网配置: ${lanConfig.host}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.textTertiary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              // 独立的 LAN 配置菜单
              PopupMenuButton<String>(
                icon: const Icon(
                  Icons.tune,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                tooltip: '连接选项',
                itemBuilder: (_) => [
                  if (!hasLanConfig)
                    const PopupMenuItem(
                      value: 'configure',
                      child: ListTile(
                        leading: Icon(Icons.lan_outlined, size: 18),
                        title: Text('配置局域网连接'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    )
                  else ...[
                    const PopupMenuItem(
                      value: 'edit',
                      child: ListTile(
                        leading: Icon(Icons.edit_outlined, size: 18),
                        title: Text('编辑局域网连接'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: AppColors.danger,
                        ),
                        title: Text(
                          '删除局域网连接',
                          style: TextStyle(color: AppColors.danger),
                        ),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ],
                onSelected: (value) async {
                  if (value == 'configure' || value == 'edit') {
                    final host = await _LanConnectionDialog.show(
                      context,
                      device: device,
                      existingHost: lanConfig?.host ?? '',
                    );
                    if (host == null) return;
                    if (!context.mounted) return;
                    final config = PrinterConnectionConfig.lan(
                      serial: device.devId,
                      host: host,
                      accessCode: device.devAccessCode,
                      devProductName: device.devProductName,
                      displayName: device.name,
                      installedNozzleDiameter: device.nozzleDiameter,
                    );
                    if (!await confirmPrinterCertificateTrust(
                      context,
                      config,
                    )) {
                      return;
                    }
                    if (!context.mounted) return;
                    await ref
                        .read(printerConnectionListProvider.notifier)
                        .add(config);
                    if (context.mounted) {
                      showSnack(context, '局域网连接配置已保存；云端模式保持独立');
                    }
                  } else if (value == 'delete') {
                    await ref
                        .read(printerConnectionListProvider.notifier)
                        .remove(device.devId);
                    if (context.mounted) {
                      showSnack(context, '局域网连接已删除；云端模式不受影响');
                    }
                  }
                },
              ),
              if (isActive)
                Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: AppColors.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 连接模式标签（云 / LAN）。
class _ModeChip extends StatelessWidget {
  final bool isLanSelected;
  final bool hasLanConfig;
  const _ModeChip({required this.isLanSelected, required this.hasLanConfig});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: isLanSelected
            ? AppColors.successContainer
            : AppColors.infoContainer,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
      ),
      child: Text(
        isLanSelected ? 'LAN' : (hasLanConfig ? '云端 · LAN' : '云端'),
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: isLanSelected ? AppColors.success : AppColors.info,
        ),
      ),
    );
  }
}

/// 独立的 LAN 配置对话框。
///
/// 打开后自动用 mDNS 扫描局域网内的拓竹打印机：
/// - 扫描到匹配当前设备的打印机：自动选中并填入 IP
/// - 扫描到其他打印机：列出供用户选择
/// - 扫描不到：回退到手动输入 IP
///
/// accessCode 可由云设备信息预填，但保存后成为独立的 LAN 配置。
/// 云端和 LAN 模式互不回退；用户可在对应入口分别选择使用哪条链路。
class _LanConnectionDialog extends StatefulWidget {
  final BambuCloudDevice device;
  final String existingHost;
  const _LanConnectionDialog({
    required this.device,
    required this.existingHost,
  });

  static Future<String?> show(
    BuildContext context, {
    required BambuCloudDevice device,
    String existingHost = '',
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) =>
          _LanConnectionDialog(device: device, existingHost: existingHost),
    );
  }

  @override
  State<_LanConnectionDialog> createState() => _LanConnectionDialogState();
}

/// mDNS 扫描状态
enum _ScanStatus { scanning, done, error }

class _LanConnectionDialogState extends State<_LanConnectionDialog> {
  late final TextEditingController _hostCtrl;
  _ScanStatus _scanStatus = _ScanStatus.scanning;
  List<DiscoveredBambuPrinter> _discovered = [];
  String? _scanError;
  DiscoveredBambuPrinter? _selected;

  @override
  void initState() {
    super.initState();
    _hostCtrl = TextEditingController(text: widget.existingHost);
    // 如果已有 IP（编辑模式），跳过扫描直接显示
    if (widget.existingHost.isNotEmpty) {
      _scanStatus = _ScanStatus.done;
    } else {
      _startScan();
    }
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _startScan({bool forceRefresh = false}) async {
    setState(() {
      _scanStatus = _ScanStatus.scanning;
      _scanError = null;
    });
    try {
      final printers = await BambuLanDiscovery.discover(
        forceRefresh: forceRefresh,
      );
      // 尝试找到匹配当前设备 serial 的打印机
      DiscoveredBambuPrinter? matched;
      for (final p in printers) {
        if (p.matches(widget.device.devId)) {
          matched = p;
          break;
        }
      }
      if (mounted) {
        setState(() {
          _discovered = printers;
          _scanStatus = _ScanStatus.done;
          if (matched != null) {
            _selected = matched;
            _hostCtrl.text = matched.ip;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _scanStatus = _ScanStatus.error;
          _scanError = friendlyError(e);
        });
      }
    }
  }

  void _selectPrinter(DiscoveredBambuPrinter? p) {
    setState(() {
      _selected = p;
      _hostCtrl.text = p?.ip ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasAccessCode = widget.device.devAccessCode.isNotEmpty;

    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
      ),
      title: Row(
        children: [
          Icon(Icons.lan_outlined, size: 20, color: AppColors.primary),
          const SizedBox(width: 8),
          const Text(
            '配置局域网连接',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          if (_scanStatus != _ScanStatus.scanning)
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 16),
              tooltip: '重新扫描',
              onPressed: () => _startScan(forceRefresh: true),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Access Code 信息条
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(AppColors.radiusSm),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.vpn_key_outlined,
                    size: 14,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Access Code',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      hasAccessCode ? widget.device.devAccessCode : '（未获取到）',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: hasAccessCode
                            ? AppColors.textPrimary
                            : AppColors.danger,
                        fontFamily: 'monospace',
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 扫描结果 / 手动输入
            if (_scanStatus == _ScanStatus.scanning)
              _buildScanning()
            else ...[
              if (_scanStatus == _ScanStatus.done && _discovered.isNotEmpty)
                _buildDiscoveredList(),
              if (_scanStatus == _ScanStatus.done && _discovered.isEmpty)
                _buildNotFoundHint(),
              if (_scanStatus == _ScanStatus.error) _buildErrorHint(),
              const SizedBox(height: 10),
              // 手动输入（始终可用）
              TextField(
                controller: _hostCtrl,
                decoration: const InputDecoration(
                  labelText: '打印机 IP 地址',
                  hintText: '如 192.168.1.50',
                  prefixIcon: Icon(Icons.router_outlined, size: 18),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _scanStatus == _ScanStatus.scanning
              ? null
              : () {
                  final host = _hostCtrl.text.trim();
                  if (host.isEmpty) {
                    showSnack(context, '请输入或选择 IP 地址', error: true);
                    return;
                  }
                  Navigator.of(context).pop(host);
                },
          child: const Text('保存'),
        ),
      ],
    );
  }

  /// 扫描中状态
  Widget _buildScanning() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: const Column(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(height: 12),
          Text(
            '正在扫描局域网内的拓竹打印机...',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          SizedBox(height: 4),
          Text(
            '需与电脑连接同一 WiFi，首次可能需要允许防火墙',
            style: TextStyle(fontSize: 10, color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }

  /// 发现的打印机列表
  Widget _buildDiscoveredList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.wifi_find, size: 14, color: AppColors.success),
            const SizedBox(width: 6),
            Text(
              '发现 ${_discovered.length} 台打印机，点击选择',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.success,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final p in _discovered)
                _DiscoveredPrinterTile(
                  printer: p,
                  selected: p == _selected,
                  isMatch: p.matches(widget.device.devId),
                  onTap: () => _selectPrinter(p),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 未发现打印机提示
  Widget _buildNotFoundHint() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.warningContainer,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
      ),
      child: const Row(
        children: [
          Icon(Icons.wifi_off, size: 14, color: AppColors.warning),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              '未发现局域网打印机，请手动输入 IP（确保打印机和电脑在同一 WiFi）',
              style: TextStyle(fontSize: 10, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// 扫描出错提示
  Widget _buildErrorHint() {
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
              '扫描失败：${_scanError ?? "未知错误"}\n请手动输入 IP，或点击右上角重新扫描',
              style: const TextStyle(fontSize: 10, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// 发现的打印机条目
class _DiscoveredPrinterTile extends StatelessWidget {
  final DiscoveredBambuPrinter printer;
  final bool selected;
  final bool isMatch;
  final VoidCallback onTap;
  const _DiscoveredPrinterTile({
    required this.printer,
    required this.selected,
    required this.isMatch,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primaryContainer
                : AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            border: Border.all(
              color: selected
                  ? AppColors.primary.withValues(alpha: 0.4)
                  : isMatch
                  ? AppColors.success.withValues(alpha: 0.3)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 16,
                color: selected ? AppColors.primary : AppColors.textTertiary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          printer.ip,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace',
                            color: AppColors.textPrimary,
                          ),
                        ),
                        if (isMatch) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.successContainer,
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: const Text(
                              '匹配',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: AppColors.success,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      printer.deviceName.isNotEmpty
                          ? '${printer.deviceName} · ${printer.instanceName}'
                          : printer.instanceName,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
