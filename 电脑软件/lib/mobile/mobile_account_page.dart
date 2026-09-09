import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/app_auth.dart';
import '../providers/app_auth_provider.dart';
import '../core/app_version.dart';
import '../core/theme/glass_button_theme.dart';
import '../features/updates/app_update_page.dart';
import 'mobile_auth_page.dart';
import 'mobile_visual_theme.dart';

class MobileAccountPage extends ConsumerStatefulWidget {
  const MobileAccountPage({
    super.key,
    required this.themeMode,
    required this.interactionEffectsEnabled,
    required this.onThemeChanged,
    required this.onEffectsChanged,
    this.onOpenInventory,
    this.onOpenDevices,
  });
  final ThemeMode themeMode;
  final bool interactionEffectsEnabled;
  final Future<void> Function(ThemeMode) onThemeChanged;
  final Future<void> Function(bool) onEffectsChanged;
  final VoidCallback? onOpenInventory;
  final VoidCallback? onOpenDevices;

  @override
  ConsumerState<MobileAccountPage> createState() => _MobileAccountPageState();
}

class _MobileAccountPageState extends ConsumerState<MobileAccountPage> {
  bool _busy = false;
  String? _error;
  late ThemeMode _themeMode = widget.themeMode;
  late bool _effects = widget.interactionEffectsEnabled;

  @override
  void didUpdateWidget(covariant MobileAccountPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeMode != widget.themeMode) _themeMode = widget.themeMode;
    if (oldWidget.interactionEffectsEnabled !=
        widget.interactionEffectsEnabled) {
      _effects = widget.interactionEffectsEnabled;
    }
  }

  Future<void> _openAuth({
    MobileAuthMode mode = MobileAuthMode.login,
    String email = '',
  }) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MobileAuthPage(initialMode: mode, email: email),
      ),
    );
    if (mounted) setState(() => _error = null);
  }

  Future<void> _logout() async {
    final userId = ref.read(appAuthProvider).session?.user.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出当前账号？'),
        content: const Text('退出后将切换到本机库存。该账号的本机缓存不会删除，未同步的记录可在重新登录后继续同步。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认退出'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        ref.read(appAuthProvider).session?.user.id != userId) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(appAuthProvider.notifier).logout();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = ref.read(appAuthProvider).session == null
              ? '本机已退出；服务端会话注销未确认，请联网后检查账号。'
              : mobileAccountError(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _appearance() async {
    var mode = _themeMode;
    var effects = _effects;
    var saving = false;
    String? error;
    await showMobileGlassBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          Future<void> save({ThemeMode? newMode, bool? newEffects}) async {
            if (saving) return;
            update(() {
              saving = true;
              error = null;
            });
            try {
              if (newMode != null) await widget.onThemeChanged(newMode);
              if (newEffects != null) await widget.onEffectsChanged(newEffects);
              if (mounted) {
                setState(() {
                  _themeMode = newMode ?? _themeMode;
                  _effects = newEffects ?? _effects;
                });
              }
              if (context.mounted) {
                update(() {
                  mode = newMode ?? mode;
                  effects = newEffects ?? effects;
                });
              }
            } catch (failure) {
              if (context.mounted) {
                update(() => error = mobileAccountError(failure));
              }
            } finally {
              if (context.mounted) update(() => saving = false);
            }
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('外观与交互', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('沿用桌面个人版配色，偏好仅保存在这台设备。'),
                const SizedBox(height: 16),
                for (final value in ThemeMode.values)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_themeLabel(value)),
                    leading: Icon(switch (value) {
                      ThemeMode.system => Icons.brightness_auto_outlined,
                      ThemeMode.light => Icons.light_mode_outlined,
                      ThemeMode.dark => Icons.dark_mode_outlined,
                    }),
                    trailing: mode == value
                        ? Icon(
                            Icons.check_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    selected: mode == value,
                    onTap: saving ? null : () => save(newMode: value),
                  ),
                const Divider(),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('交互动效'),
                  subtitle: const Text('页面转场与操作反馈；尊重系统“减少动画”设置'),
                  value: effects,
                  onChanged: saving ? null : (value) => save(newEffects: value),
                ),
                if (error != null)
                  MobileAccountMessage(message: error!, error: true),
              ],
            ),
          );
        },
      ),
    );
  }

  void _help() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => MobileScaffold(
        appBar: AppBar(
          flexibleSpace: const MobileGlassBar(),
          title: const Text('使用与数据说明'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: const [
            _HelpItem(
              title: '管理很多卷耗材',
              text:
                  '库存按需加载可见条目。使用固定搜索栏查找品牌、型号、颜色或 UID；筛选品牌和材质，按余量或最近更新排序。点击任意一卷查看完整信息和标签记录。',
            ),
            _HelpItem(
              title: '手机与桌面如何同步',
              text:
                  '两端登录同一 sohun 个人账号后共享个人库存。写入先保存本机；网络不可用时保留待同步记录，联网后在库存页下拉刷新。看到“本次云端同步完成”才表示该次同步成功。',
            ),
            _HelpItem(
              title: '本机库存与账号库存',
              text: '未登录时查看本机库存。登录或切换账号后，只显示对应账号的个人库存。退出登录不会清空之前账号的本机缓存。',
            ),
            _HelpItem(
              title: 'NFC 标签的使用边界',
              text:
                  '仅在你发起操作时读取 NFC。写入需要完整有效的拓竹源标签模板和兼容的 UID 卡；AMS 使用源模板参数，sohun 按物理标签 UID 单独记录你的品牌、型号和颜色。回读通过不代表实体 AMS 已验证识别，实际效果仍需在你的标签和设备上确认。',
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(appAuthProvider);
    final user = auth.session?.user;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return MobileScaffold(
      appBar: AppBar(
        flexibleSpace: const MobileGlassBar(),
        title: const Text('我的'),
      ),
      body: SafeArea(
        child: ListView(
          key: const PageStorageKey('mobile-account-page'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            MobileGlassSurface(
              padding: const EdgeInsets.all(18),
              opacity: 0.48,
              elevated: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'SOHUN  /  个人版',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      _AccountAvatar(user: user),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?.displayName ?? '让创作随处接续',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.headlineMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              user?.email ?? '手机登记 · 桌面管理',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  if (user == null) ...[
                    Text(
                      '登录后，与桌面端共用你的个人耗材库。',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const ValueKey('mobile-open-login'),
                      onPressed: _busy ? null : () => _openAuth(),
                      style: glassButtonStyle(
                        context,
                        FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                      child: const Text('登录 / 创建账号'),
                    ),
                  ] else
                    Row(
                      children: [
                        Icon(
                          user.emailVerified
                              ? Icons.verified_user_outlined
                              : Icons.info_outline_rounded,
                          size: 16,
                          color: user.emailVerified
                              ? scheme.primary
                              : scheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            user.emailVerified ? '邮箱已验证' : '邮箱待验证',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        Text(
                          '个人账号',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              MobileAccountMessage(message: _error!, error: true),
            ],
            const _SectionLabel('账户与数据'),
            _AccountGroup(
              children: [
                if (user != null) ...[
                  _AccountTile(
                    icon: Icons.badge_outlined,
                    title: '个人资料',
                    subtitle: '昵称、用户名与个人简介',
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => _MobileProfilePage(user: user),
                      ),
                    ),
                  ),
                  _AccountTile(
                    icon: Icons.mark_email_read_outlined,
                    title: '邮箱验证',
                    subtitle: user.emailVerified
                        ? '已验证 · ${user.email}'
                        : '验证邮箱，完善账号安全',
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => _MobileEmailPage(user: user),
                      ),
                    ),
                  ),
                  _AccountTile(
                    icon: Icons.lock_outline_rounded,
                    title: '重设密码',
                    subtitle: '通过注册邮箱验证身份',
                    onTap: () => _openAuth(
                      mode: MobileAuthMode.reset,
                      email: user.email,
                    ),
                  ),
                ],
                if (widget.onOpenInventory != null)
                  _AccountTile(
                    icon: Icons.inventory_2_outlined,
                    title: '个人耗材库',
                    subtitle: user == null ? '当前为本机库存模式' : '查看库存与本次同步状态',
                    onTap: widget.onOpenInventory!,
                  ),
                if (user == null)
                  _AccountTile(
                    icon: Icons.cloud_outlined,
                    title: '跨端库存',
                    subtitle: '登录同一账号后与桌面端共享',
                    onTap: () => _openAuth(),
                  ),
              ],
            ),
            const _SectionLabel('偏好与工具'),
            _AccountGroup(
              children: [
                if (widget.onOpenDevices != null)
                  _AccountTile(
                    icon: Icons.devices_outlined,
                    title: '设备工作台',
                    subtitle: 'NTAG213 设备标签 · 状态 · 故障 · 保养',
                    onTap: widget.onOpenDevices!,
                  ),
                _AccountTile(
                  icon: Icons.palette_outlined,
                  title: '外观与交互',
                  subtitle: _themeLabel(_themeMode),
                  onTap: _appearance,
                ),
                _AccountTile(
                  icon: Icons.help_outline_rounded,
                  title: '使用与数据说明',
                  subtitle: '同步方式、标签边界与库存管理',
                  onTap: _help,
                ),
                _AccountTile(
                  icon: Icons.system_update_alt_rounded,
                  title: '软件更新',
                  subtitle: '当前版本 ${AppVersion.fullVersion}',
                  onTap: () => AppUpdatePage.show(context),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                for (final type in AppAccountPolicyType.values)
                  TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => MobileAccountPolicyPage(type: type),
                      ),
                    ),
                    child: Text(type.label),
                  ),
              ],
            ),
            if (user != null)
              OutlinedButton(
                onPressed: _busy || auth.isBusy ? null : _logout,
                child: Text(_busy ? '正在退出…' : '退出登录'),
              ),
          ],
        ),
      ),
    );
  }
}

String _themeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => '跟随系统',
  ThemeMode.light => '浅色模式',
  ThemeMode.dark => '深色模式',
};

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({required this.user});
  final AppUser? user;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = user?.displayName.trim() ?? '';
    final fallback = Center(
      child: name.isEmpty
          ? Icon(Icons.person_outline_rounded, color: scheme.primary, size: 30)
          : Text(
              name.characters.first.toUpperCase(),
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(color: scheme.primary),
            ),
    );
    final url = Uri.tryParse(user?.avatarUrl ?? '');
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: url != null && url.scheme == 'https' && url.host.isNotEmpty
          ? Image.network(
              url.toString(),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback,
            )
          : fallback,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
    child: Text(text, style: Theme.of(context).textTheme.labelMedium),
  );
}

class _AccountGroup extends StatelessWidget {
  const _AccountGroup({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => MobileGlassSurface(
    opacity: 0.56,
    child: Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 54, endIndent: 16),
          children[i],
        ],
      ],
    ),
  );
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(
      icon,
      size: 21,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
    minLeadingWidth: 22,
    horizontalTitleGap: 12,
    title: Text(title, style: Theme.of(context).textTheme.titleMedium),
    subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
    trailing: const Icon(Icons.chevron_right_rounded, size: 20),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    onTap: onTap,
  );
}

class _HelpItem extends StatelessWidget {
  const _HelpItem({required this.title, required this.text});
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(text, style: Theme.of(context).textTheme.bodyMedium),
      ],
    ),
  );
}

class _MobileProfilePage extends ConsumerStatefulWidget {
  const _MobileProfilePage({required this.user});
  final AppUser user;
  @override
  ConsumerState<_MobileProfilePage> createState() => _MobileProfilePageState();
}

class _MobileProfilePageState extends ConsumerState<_MobileProfilePage> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.user.displayName);
  late final _bio = TextEditingController(text: widget.user.bio);
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
    if (ref.read(appAuthProvider).session?.user.id != widget.user.id) {
      setState(() => _error = '账号已变化，请返回个人中心重新打开资料。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(appAuthProvider.notifier)
          .updateCurrentUser(
            AppUserUpdateRequest(displayName: _name.text, bio: _bio.text),
          );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('个人资料已保存')));
    } catch (error) {
      if (mounted) setState(() => _error = mobileAccountError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MobileScaffold(
    appBar: AppBar(
      flexibleSpace: const MobileGlassBar(),
      title: const Text('个人资料'),
    ),
    body: SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: _AccountAvatar(
                user: ref.watch(appAuthProvider).session?.user ?? widget.user,
              ),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _name,
              enabled: !_busy,
              maxLength: 40,
              textInputAction: TextInputAction.next,
              validator: (value) =>
                  value?.trim().isNotEmpty == true ? null : '昵称不能为空',
              decoration: const InputDecoration(labelText: '昵称'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _bio,
              enabled: !_busy,
              maxLength: 300,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '个人简介',
                hintText: '分享你的打印兴趣',
              ),
            ),
            const SizedBox(height: 20),
            Text('用户名', style: Theme.of(context).textTheme.labelMedium),
            SelectableText('@${widget.user.handle}'),
            const SizedBox(height: 12),
            Text('注册邮箱', style: Theme.of(context).textTheme.labelMedium),
            SelectableText(widget.user.email),
            const SizedBox(height: 24),
            if (_error != null)
              MobileAccountMessage(message: _error!, error: true),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? '保存中…' : '保存资料'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MobileEmailPage extends ConsumerStatefulWidget {
  const _MobileEmailPage({required this.user});
  final AppUser user;
  @override
  ConsumerState<_MobileEmailPage> createState() => _MobileEmailPageState();
}

class _MobileEmailPageState extends ConsumerState<_MobileEmailPage> {
  final _code = TextEditingController();
  bool _busy = false;
  int _cooldown = 0;
  Timer? _timer;
  String? _error;
  String? _notice;
  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify({bool send = false}) async {
    if (_busy || (send && _cooldown > 0)) return;
    if (ref.read(appAuthProvider).session?.user.id != widget.user.id) {
      setState(() => _error = '账号已变化，请重新打开邮箱验证。');
      return;
    }
    if (!send && !RegExp(r'^\d{8}$').hasMatch(_code.text)) {
      setState(() => _error = '请输入 8 位验证码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final notifier = ref.read(appAuthProvider.notifier);
      if (send) {
        await notifier.requestEmailVerification();
        if (!mounted) return;
        setState(() {
          _notice = '验证码已发送，请查收邮箱。';
          _cooldown = 60;
        });
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          }
          setState(() => _cooldown--);
          if (_cooldown == 0) timer.cancel();
        });
      } else {
        await notifier.confirmEmailVerification(_code.text);
      }
    } catch (error) {
      if (mounted) setState(() => _error = mobileAccountError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(appAuthProvider).session?.user;
    final verified =
        currentUser?.id == widget.user.id && currentUser!.emailVerified;
    return MobileScaffold(
      appBar: AppBar(
        flexibleSpace: const MobileGlassBar(),
        title: const Text('邮箱验证'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              verified
                  ? Icons.verified_user_outlined
                  : Icons.mark_email_unread_outlined,
              size: 44,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 20),
            Text(
              verified ? '你的邮箱已验证' : '验证你的邮箱',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(widget.user.email),
            const SizedBox(height: 24),
            if (!verified) ...[
              TextField(
                controller: _code,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                decoration: const InputDecoration(labelText: '8 位邮箱验证码'),
              ),
              TextButton(
                onPressed: _busy || _cooldown > 0
                    ? null
                    : () => _verify(send: true),
                child: Text(_cooldown > 0 ? '${_cooldown}s 后重发' : '发送验证码'),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _verify(),
                child: Text(_busy ? '处理中…' : '完成验证'),
              ),
            ],
            if (_error != null || _notice != null) ...[
              const SizedBox(height: 16),
              MobileAccountMessage(
                message: _error ?? _notice!,
                error: _error != null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
