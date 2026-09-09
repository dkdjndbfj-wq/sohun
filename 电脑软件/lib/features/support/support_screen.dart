import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/scheduler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/utils/public_image_url.dart';
import '../../data/external/community/community_api_client.dart';
import '../../data/models/app_auth.dart';
import '../../providers/app_auth_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/sohun_wordmark.dart';
import '../settings/settings_sheet.dart';
import 'embedded_support_shop.dart';

/// Third-party payment + account-linked (or anonymous) public thank-you wall.
class SupportScreen extends ConsumerStatefulWidget {
  const SupportScreen({super.key});

  @override
  ConsumerState<SupportScreen> createState() => _SupportScreenState();
}

enum _SupportClaimMode { account, login, anonymous }

class _SupportScreenState extends ConsumerState<SupportScreen> {
  final _codeController = TextEditingController();
  final _noteController = TextEditingController();
  List<SupportWallEntry> _entries = const [];
  bool _loadingWall = true;
  bool _redeeming = false;
  String? _wallError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadWall());
  }

  @override
  void dispose() {
    _codeController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadWall() async {
    CommunitySupportApi? api;
    AppAuthState? auth;
    try {
      // Wait for the persisted endpoint/session to be restored.  Reading the
      // provider on the first frame can otherwise race initialization and make
      // a configured server look like an unconfigured one.
      await ref.read(appAuthProvider.notifier).ready;
      auth = ref.read(appAuthProvider);
      api = ref.read(communitySupportApiProvider);
    } on StateError {
      if (mounted) setState(() => _loadingWall = false);
      return;
    }
    if (api == null) {
      if (mounted) {
        setState(() {
          _loadingWall = false;
          _wallError = auth?.status == AppAuthStatus.unconfigured ||
                  auth?.endpoint == null
              ? '尚未配置 sohun 云服务器，暂时无法同步共创致谢墙'
              : '当前云服务尚未启用共创致谢墙';
        });
      }
      return;
    }
    if (mounted) setState(() => _loadingWall = true);
    try {
      final page = await api.listSupporters(limit: 60);
      if (!mounted) return;
      setState(() {
        _entries = page.items;
        _wallError = null;
        _loadingWall = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingWall = false;
        _wallError = _wallErrorMessage(error, auth?.endpoint);
      });
    }
  }

  String _wallErrorMessage(Object error, Uri? endpoint) {
    final message = friendlyError(error);
    if (error is CommunityApiException && error.statusCode == 404) {
      return 'sohun 云服务器已连接，但尚未部署共创致谢接口，请更新服务器后重试。';
    }
    final host = endpoint?.host.toLowerCase();
    final local = host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '[::1]';
    if (local) {
      return '无法连接 sohun 云服务（${endpoint!}）。请检查网络或服务状态；自托管版本可通过 APP_API_BASE_URL 指定服务器。';
    }
    return message;
  }

  Future<void> _redeemCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      showSnack(context, '请先粘贴支付后收到的卡密', error: true);
      return;
    }
    try {
      await ref.read(appAuthProvider.notifier).ready;
    } on StateError {
      showSnack(context, '账号服务尚未初始化，请稍后重试', error: true);
      return;
    }
    final api = ref.read(communitySupportApiProvider);
    if (api == null) {
      final auth = ref.read(appAuthProvider);
      showSnack(
        context,
        auth.status == AppAuthStatus.unconfigured || auth.endpoint == null
            ? '尚未配置 sohun 云服务器，暂时无法同步共创致谢墙'
            : '当前云服务尚未启用共创致谢墙',
        error: true,
      );
      return;
    }

    final auth = ref.read(appAuthProvider);
    final personalAccount = auth.isSignedIn &&
        auth.session?.authRealm != 'farm_staff' &&
        auth.user?.emailVerified == true;
    var claimMode = personalAccount
        ? _SupportClaimMode.account
        : await _chooseClaimMode(auth);
    if (!mounted || claimMode == null) return;
    if (claimMode == _SupportClaimMode.login) {
      final loggedIn = await promptSohunLogin(context, ref);
      if (!loggedIn || !mounted) return;
      final updatedAuth = ref.read(appAuthProvider);
      if (!updatedAuth.isSignedIn ||
          updatedAuth.session?.authRealm == 'farm_staff' ||
          updatedAuth.user?.emailVerified != true) {
        showSnack(context, '账号登录成功后还需要完成邮箱验证，或选择匿名加入', error: true);
        return;
      }
      claimMode = _SupportClaimMode.account;
    }

    setState(() => _redeeming = true);
    try {
      final session = claimMode == _SupportClaimMode.account
          ? await ref.read(appAuthProvider.notifier).ensureValidSession()
          : null;
      final result = await api.redeemSupportCode(
        accessToken: session?.accessToken,
        code: code,
        note: _noteController.text,
      );
      if (!mounted) return;
      _codeController.clear();
      _noteController.clear();
      showSnack(
        context,
        result.alreadyRedeemed ? '这枚卡密已经绑定到当前账号' : '已加入共创致谢墙，感谢你的支持！',
      );
      await _loadWall();
    } catch (error) {
      if (mounted) {
        showSnack(
          context,
          _wallErrorMessage(error, ref.read(appAuthProvider).endpoint),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  Future<_SupportClaimMode?> _chooseClaimMode(AppAuthState auth) {
    final hasAccount = auth.isSignedIn &&
        auth.user != null &&
        auth.session?.authRealm != 'farm_staff';
    return showDialog<_SupportClaimMode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择致谢方式'),
        content: Text(
          hasAccount
              ? '当前账号还未完成邮箱验证。你可以先去设置完成验证，也可以匿名加入致谢墙。'
              : '登录后会显示你的账号头像、昵称和留言；如果不想登录，也可以匿名加入致谢墙。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_SupportClaimMode.anonymous),
            child: const Text('匿名加入'),
          ),
          if (!hasAccount)
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_SupportClaimMode.login),
              child: const Text('登录后绑定'),
            )
          else
            FilledButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await SettingsSheet.show(context);
              },
              child: const Text('去设置验证'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppAuthState? auth;
    try {
      auth = ref.watch(appAuthProvider);
    } on StateError {
      // Isolated widget previews may omit ProviderScope.
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 900;
        final horizontal =
            constraints.maxWidth < 600 ? AppSpacing.lg : AppSpacing.xxxl;
        return SingleChildScrollView(
          padding:
              EdgeInsets.fromLTRB(horizontal, AppSpacing.xxxl, horizontal, 56),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1160),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HeroCard(
                    user: auth?.user,
                    endpoint: auth?.endpoint,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  if (compact)
                    _RedeemCard(
                      codeController: _codeController,
                      noteController: _noteController,
                      redeeming: _redeeming,
                      onRedeem: _redeemCode,
                    )
                  else
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 6,
                            child: _WallCard(
                              entries: _entries,
                              loading: _loadingWall,
                              error: _wallError,
                              endpoint: auth?.endpoint,
                              onRefresh: _loadWall,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.xl),
                          Expanded(
                            flex: 4,
                            child: _RedeemCard(
                              codeController: _codeController,
                              noteController: _noteController,
                              redeeming: _redeeming,
                              onRedeem: _redeemCode,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (compact) ...[
                    const SizedBox(height: AppSpacing.xl),
                    _WallCard(
                      entries: _entries,
                      loading: _loadingWall,
                      error: _wallError,
                      endpoint: auth?.endpoint,
                      onRefresh: _loadWall,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  const SalcaraPromoCard(),
                  const SizedBox(height: AppSpacing.xl),
                  const SupportShopEmbed(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A small, first-party promotional entry point kept separate from the
/// payment WebView. The destination is opened in the user's browser so its
/// own login/session and any future site navigation remain isolated from the
/// support-code flow.
class SalcaraPromoCard extends StatelessWidget {
  const SalcaraPromoCard({super.key});

  static final Uri siteUri = Uri.parse('https://salcara.top/');

  Future<void> _open(BuildContext context) async {
    final opened =
        await launchUrl(siteUri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('无法打开 Salcara，请复制 https://salcara.top/ 访问')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 17, 16, 17),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          colors: dark
              ? const [Color(0xFF17372E), Color(0xFF10231F)]
              : [const Color(0xFFE9F7E9), scheme.surface],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.22)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 580;
          final identity = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: dark ? 0.12 : 0.75),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: Image.asset(
                    'assets/images/sohun.png',
                    fit: BoxFit.cover,
                    semanticLabel: 'Sohun 图标',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Salcara 中转站',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '查看服务说明与渠道状态',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final action = FilledButton.icon(
            onPressed: () => unawaited(_open(context)),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('访问 Salcara'),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                identity,
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerLeft, child: action),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: identity),
              const SizedBox(width: 16),
              action,
            ],
          );
        },
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.user,
    required this.endpoint,
  });

  final AppUser? user;
  final Uri? endpoint;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final title = dark ? AppColors.textPrimaryDark : AppColors.textPrimary;
    final body = dark ? AppColors.textSecondaryDark : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          colors: dark
              ? const [Color(0xFF19352F), Color(0xFF152522)]
              : [scheme.primaryContainer.withValues(alpha: 0.82), Colors.white],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: dark ? 0.16 : 0.10),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 640;
          final copy = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                width: 128,
                height: 34,
                child: SohunWordmark(glow: true),
              ),
              const SizedBox(height: 14),
              Text(
                '一起把 Sohun 做得更好',
                style: TextStyle(
                  color: title,
                  fontFamily: AppTypography.chineseFontFamily,
                  fontSize: narrow ? 28 : 36,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Text(
                  '感谢每一位愿意支持独立开发的同行者。商城已经嵌入本页下方，支付完成后，把返回的卡密绑定到你的账号，头像、昵称和留言会出现在所有人都能看到的共创致谢墙。',
                  style: TextStyle(color: body, height: 1.65, fontSize: 13),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ProfileAvatar(user: user, endpoint: endpoint, size: 36),
                  const SizedBox(width: 10),
                  Text(
                    user == null ? '登录后可绑定卡密' : '当前身份：${user!.displayName}',
                    style: TextStyle(
                      color: title,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          );
          final authorAvatar = _AuthorAvatarBadge(dark: dark);
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                copy,
                const SizedBox(height: 18),
                Align(alignment: Alignment.centerRight, child: authorAvatar),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: copy),
              const SizedBox(width: 28),
              authorAvatar,
            ],
          );
        },
      ),
    );
  }
}

class _AuthorAvatarBadge extends StatelessWidget {
  const _AuthorAvatarBadge({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = dark ? Colors.white : scheme.onPrimaryContainer;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 118,
          height: 118,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: dark ? 0.12 : 0.68),
            borderRadius: BorderRadius.circular(34),
            border: Border.all(
              color: Colors.white.withValues(alpha: dark ? 0.24 : 0.72),
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: dark ? 0.24 : 0.14),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(29),
            child: Image.asset(
              'assets/images/author_avatar.jpg',
              fit: BoxFit.cover,
              semanticLabel: 'Sohun 作者头像',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Sohun 作者',
          style: TextStyle(
            color: foreground.withValues(alpha: 0.78),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

class _RedeemCard extends StatelessWidget {
  const _RedeemCard({
    required this.codeController,
    required this.noteController,
    required this.redeeming,
    required this.onRedeem,
  });

  final TextEditingController codeController;
  final TextEditingController noteController;
  final bool redeeming;
  final VoidCallback onRedeem;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF18201E) : scheme.surface,
        borderRadius: BorderRadius.circular(24),
        border:
            Border.all(color: scheme.outlineVariant.withValues(alpha: 0.62)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.redeem_rounded, color: scheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '绑定支持卡密',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '登录可关联头像和昵称；也可以匿名登记。每枚卡密只会使用一次。',
            style: TextStyle(
                fontSize: 11, color: scheme.onSurfaceVariant, height: 1.45),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: codeController,
            enabled: !redeeming,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '支持卡密',
              hintText: '粘贴支付后收到的卡密',
              prefixIcon: Icon(Icons.key_rounded, size: 18),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: noteController,
            enabled: !redeeming,
            maxLength: 30,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '留言（最多 30 字，可选）',
              hintText: '给后来者留一句话',
              prefixIcon: Icon(Icons.chat_bubble_outline_rounded, size: 18),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '快速留言 · 最多 30 字',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final message in const ['继续加油！', '期待下一版', '感谢分享'])
                ActionChip(
                  label: Text(message),
                  onPressed:
                      redeeming ? null : () => noteController.text = message,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: AppButton(
              label: redeeming ? '正在绑定…' : '绑定并加入致谢墙',
              icon: redeeming
                  ? const SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline_rounded, size: 17),
              onPressed: redeeming ? null : onRedeem,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '商城已嵌入本页下方，向下滚动即可选择支持商品。',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _WallCard extends StatelessWidget {
  const _WallCard({
    required this.entries,
    required this.loading,
    required this.error,
    required this.endpoint,
    required this.onRefresh,
  });

  final List<SupportWallEntry> entries;
  final bool loading;
  final String? error;
  final Uri? endpoint;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF18201E) : scheme.surface,
        borderRadius: BorderRadius.circular(24),
        border:
            Border.all(color: scheme.outlineVariant.withValues(alpha: 0.62)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, color: scheme.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '共创致谢',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface),
                ),
              ),
              IconButton(
                tooltip: '刷新致谢墙',
                onPressed: loading ? null : () => unawaited(onRefresh()),
                icon: const Icon(Icons.refresh_rounded, size: 19),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('每一条留言，都是 Sohun 继续生长的动力',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          if (loading)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(28),
                    child: CircularProgressIndicator()))
          else if (error != null)
            _WallMessage(
                icon: Icons.cloud_off_rounded, text: error!, action: onRefresh)
          else if (entries.isEmpty)
            const _WallMessage(
                icon: Icons.waving_hand_rounded, text: '还没有公开致谢记录，成为第一位同行者吧')
          else
            _SupportMarquee(entries: entries, endpoint: endpoint),
        ],
      ),
    );
  }
}

/// A lightweight, dependency-free QQ-style ticker for the public thank-you
/// wall. Two copies of the row are rendered so the reset at the end of a cycle
/// is visually seamless. The scroll controller is driven by a ticker instead
/// of a timer so it stays in sync with Flutter's frame scheduler.
class _SupportMarquee extends StatefulWidget {
  const _SupportMarquee({required this.entries, required this.endpoint});

  final List<SupportWallEntry> entries;
  final Uri? endpoint;

  @override
  State<_SupportMarquee> createState() => _SupportMarqueeState();
}

class _SupportMarqueeState extends State<_SupportMarquee>
    with SingleTickerProviderStateMixin {
  static const _speed = 30.0;

  late final ScrollController _controller;
  late final Ticker _ticker;
  Duration? _lastTick;
  bool _positionedAtCycleStart = false;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _ticker = createTicker(_onTick)..start();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _positionAtCycleStart());
  }

  @override
  void didUpdateWidget(covariant _SupportMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entries != widget.entries) {
      _positionedAtCycleStart = false;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _positionAtCycleStart());
    }
  }

  void _positionAtCycleStart() {
    if (!mounted || !_controller.hasClients) return;
    final cycle = _cycleExtent;
    if (cycle <= 0) return;
    _controller.jumpTo(
      cycle.clamp(0, _controller.position.maxScrollExtent).toDouble(),
    );
    _positionedAtCycleStart = true;
  }

  double get _cycleExtent {
    if (!_controller.hasClients) return 0;
    final position = _controller.position;
    if (position.maxScrollExtent <= 0 || position.viewportDimension <= 0) {
      return 0;
    }
    // The row is duplicated, so the first cycle is half of the total content
    // extent (viewport + max scroll extent).
    return (position.maxScrollExtent + position.viewportDimension) / 2;
  }

  void _onTick(Duration elapsed) {
    final previous = _lastTick;
    _lastTick = elapsed;
    if (previous == null || !mounted || !_controller.hasClients) return;
    if (!_positionedAtCycleStart) {
      _positionAtCycleStart();
      return;
    }
    final position = _controller.position;
    final cycle = _cycleExtent;
    if (cycle <= 0 || position.maxScrollExtent <= 0) return;
    final delta =
        (elapsed - previous).inMicroseconds / Duration.microsecondsPerSecond;
    var next = position.pixels - delta * _speed;
    if (next <= 0) next += cycle;
    _controller.jumpTo(next.clamp(0, position.maxScrollExtent).toDouble());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ClipRect(
        child: ListView.builder(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: widget.entries.length * 2,
          itemBuilder: (context, index) {
            final entry = widget.entries[index % widget.entries.length];
            return Padding(
              padding: EdgeInsets.only(
                left: index == 0 ? 4 : 0,
                right: index == widget.entries.length * 2 - 1 ? 4 : 12,
              ),
              child: _SupportBubble(
                entry: entry,
                endpoint: widget.endpoint,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SupportBubble extends StatelessWidget {
  const _SupportBubble({required this.entry, required this.endpoint});

  final SupportWallEntry entry;
  final Uri? endpoint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = parsePublicHttpsImageUrl(
      entry.avatarUrl,
      trustedOrigin: endpoint,
    );
    final message = entry.note?.trim().isNotEmpty == true
        ? entry.note!.trim()
        : '感谢支持 Sohun';
    return Semantics(
      label: '${entry.displayName}：$message，${entry.tier}',
      container: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _AvatarImage(uri: avatar, fallback: entry.displayName, size: 38),
          const SizedBox(width: 7),
          Container(
            constraints: const BoxConstraints(maxWidth: 248),
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 8),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.82),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(7),
                topRight: Radius.circular(16),
                bottomRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
              ),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.16)),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 166),
                      child: Text(
                        entry.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onPrimaryContainer,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      entry.tier,
                      style: TextStyle(
                        color: scheme.primary,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.9),
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WallMessage extends StatelessWidget {
  const _WallMessage({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Future<void> Function()? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 12),
        child: Column(
          children: [
            Icon(icon, size: 32, color: scheme.primary.withValues(alpha: 0.8)),
            const SizedBox(height: 8),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            if (action != null) ...[
              const SizedBox(height: 8),
              TextButton(
                  onPressed: () => unawaited(action!()),
                  child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar(
      {required this.user, required this.endpoint, required this.size});

  final AppUser? user;
  final Uri? endpoint;
  final double size;

  @override
  Widget build(BuildContext context) {
    return _AvatarImage(
      uri: parsePublicHttpsImageUrl(user?.avatarUrl, trustedOrigin: endpoint),
      fallback: user?.displayName ?? '?',
      size: size,
    );
  }
}

class _AvatarImage extends StatelessWidget {
  const _AvatarImage(
      {required this.uri, required this.fallback, required this.size});

  final Uri? uri;
  final String fallback;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial =
        fallback.isEmpty ? '?' : fallback.characters.first.toUpperCase();
    final fallbackWidget = Center(
      child: Text(initial,
          style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w800,
              fontSize: size * 0.38)),
    );
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.primaryContainer,
          border: Border.all(color: scheme.surface, width: 2)),
      child: uri == null
          ? fallbackWidget
          : Image.network(uri.toString(),
              fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallbackWidget),
    );
  }
}
