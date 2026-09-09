import 'dart:async';

import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/interaction_effects.dart';
import '../../core/utils/friendly_error.dart';
import '../../data/external/printer/bambu_cloud_client.dart';
import '../../data/external/printer/bambu_cloud_models.dart';
import '../../data/external/printer/bambu_cloud_session_store.dart';
import '../../providers/bambu_account_manager.dart';
import '../../providers/bambu_cloud_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/app_input.dart';
import '../../widgets/app_select.dart';
import '../../widgets/confirm_dialog.dart' show AppNoticeTone, showSnack;
import '../../widgets/empty_state.dart';
import '../../widgets/glass_card.dart';
import '../printers/add_printer_sheet.dart';
import '../settings/cloud_login_dialog.dart';

/// 拓竹云账号管理弹窗。
///
/// 展示已保存的所有拓竹账号，支持切换活跃账号、删除账号、添加新账号、
/// 编辑备注名、置顶、拖拽排序、搜索过滤、切换撤销。
/// 账号列表来自 [bambuAccountManagerProvider]；添加账号复用 [CloudLoginDialog]
/// （登录成功后由 `BambuCloudNotifier._completeLogin` 自动调用 `addAccount`）。
///
/// 以 Dialog 形态展示，宽度约 480px，毛玻璃（GlassCard L3）风格，适配暗色模式。
class AccountManagerScreen extends ConsumerStatefulWidget {
  const AccountManagerScreen({super.key});

  /// 打开账号管理弹窗。
  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => const AccountManagerScreen(),
    );
  }

  @override
  ConsumerState<AccountManagerScreen> createState() =>
      _AccountManagerScreenState();
}

class _AccountManagerScreenState extends ConsumerState<AccountManagerScreen> {
  /// 搜索关键词。空字符串表示不过滤。
  String _query = '';

  /// 切换撤销计时器（3 秒后清空 undo 状态）。
  Timer? _undoTimer;

  BambuCloudAccount? _undoSource;
  BambuCloudAccount? _switchedTarget;

  /// 是否正在执行批量健康检查
  bool _healthChecking = false;

  /// 最近一次健康检查结果（null 表示尚未执行过）
  AccountHealthSummary? _lastHealthSummary;

  @override
  void dispose() {
    _undoTimer?.cancel();
    super.dispose();
  }

  /// 执行账号切换，并在当前弹窗内提供可访问的撤销入口。
  Future<void> _switchWithUndo(BambuCloudAccount target) async {
    final manager = ref.read(bambuAccountManagerProvider.notifier);
    final previous = ref.read(bambuAccountManagerProvider);
    final previousEmail = previous.activeAccountEmail;
    final previousAccount = previousEmail == null
        ? null
        : previous.accounts.firstWhere(
            (a) =>
                a.email == previousEmail && a.region == previous.activeRegion,
            orElse: () => previous.accounts.first,
          );

    final ok = await manager.switchAccount(target.email, target.region);
    if (!mounted || !ok) return;

    // 取消之前的撤销计时器（如果连续切换）
    _undoTimer?.cancel();

    setState(() {
      _undoSource = previousAccount;
      _switchedTarget = target;
    });

    _undoTimer = Timer(const Duration(seconds: 5), () {
      manager.expireUndo();
      if (!mounted) return;
      setState(() {
        _undoSource = null;
        _switchedTarget = null;
      });
    });
  }

  Future<void> _undoLastSwitch() async {
    if (_undoSource == null) return;
    _undoTimer?.cancel();
    final ok = await ref
        .read(bambuAccountManagerProvider.notifier)
        .undoSwitch();
    if (!mounted) return;
    setState(() {
      _undoSource = null;
      _switchedTarget = null;
    });
    if (!ok) showSnack(context, '撤销切换失败', error: true);
  }

  /// 拖拽排序回调：把 fromIndex 的账号移到 toIndex。
  Future<void> _onReorder(int fromIndex, int toIndex) async {
    final state = ref.read(bambuAccountManagerProvider);
    final accounts = List<BambuCloudAccount>.from(state.accounts);
    // onReorderItem 已为 fromIndex 之前的位置调整了 toIndex，无需再 -1
    final moved = accounts.removeAt(fromIndex);
    accounts.insert(toIndex, moved);
    await ref
        .read(bambuAccountManagerProvider.notifier)
        .reorderAccounts(accounts);
  }

  /// 编辑账号备注名。
  Future<void> _editNickname(BambuCloudAccount account) async {
    final controller = TextEditingController(text: account.nickname);
    final focusNode = FocusNode();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final result = await AppDialog.show<String>(
      context: context,
      title: '编辑备注名',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '为账号 ${account.email} 设置备注名，方便区分（如"公司账号"）',
            style: TextStyle(
              fontSize: 12,
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          AppInput(
            controller: controller,
            hint: '输入备注名（留空则显示邮箱）',
            onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
          ),
        ],
      ),
      actions: [
        AppButton(
          label: '取消',
          variant: AppButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(null),
        ),
        AppButton(
          label: '保存',
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
        ),
      ],
    );
    focusNode.dispose();
    controller.dispose();
    if (result == null) return;
    final updated = account.copyWith(nickname: result);
    await ref.read(bambuAccountManagerProvider.notifier).updateAccount(updated);
    if (!mounted) return;
    showSnack(context, result.isEmpty ? '已清除备注名' : '已设置备注名：$result');
  }

  /// 切换置顶状态。
  Future<void> _togglePinned(BambuCloudAccount account) async {
    final updated = account.copyWith(pinned: !account.pinned);
    await ref.read(bambuAccountManagerProvider.notifier).updateAccount(updated);
    if (!mounted) return;
    showSnack(context, updated.pinned ? '已置顶 ${account.displayName}' : '已取消置顶');
  }

  /// 显示账号右键菜单（编辑备注/置顶/迁移设备/删除）。
  void _showContextMenu(
    BuildContext context,
    BambuCloudAccount account,
    Offset position,
  ) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final mediaQuery = MediaQuery.of(context);
        const menuWidth = 220.0;
        const menuEstimatedHeight = 280.0;
        // 定位到按钮旁边（position 是按钮的全局坐标）
        double left = position.dx;
        double top = position.dy;
        // 右边界溢出则向左展开
        if (left + menuWidth > mediaQuery.size.width - 12) {
          left = mediaQuery.size.width - menuWidth - 12;
        }
        // 下边界溢出则向上展开
        if (top + menuEstimatedHeight > mediaQuery.size.height - 12) {
          top = mediaQuery.size.height - menuEstimatedHeight - 12;
        }
        left = left.clamp(12.0, mediaQuery.size.width - menuWidth - 12);
        top = top.clamp(
          12.0,
          mediaQuery.size.height - menuEstimatedHeight - 12,
        );
        return Stack(
          children: [
            // 透明遮罩：点击关闭菜单
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => entry.remove(),
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: menuWidth,
                  decoration: BoxDecoration(
                    color: isDark
                        ? AppColors.glassFillL3Dark
                        : AppColors.glassFillL3,
                    borderRadius: BorderRadius.circular(AppColors.radiusLg),
                    border: Border.all(
                      color: isDark
                          ? AppColors.glassBorderDarkMode
                          : AppColors.glassBorder,
                    ),
                    boxShadow: isDark
                        ? AppColors.shadow3Dark
                        : AppColors.shadow3,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Header
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                        child: Row(
                          children: [
                            Text(
                              '账号操作',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? AppColors.textTertiaryDark
                                    : AppColors.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: isDark
                            ? AppColors.dividerDark
                            : AppColors.divider,
                      ),
                      _AccountMenuItem(
                        icon: Icons.edit_outlined,
                        label: account.nickname.isEmpty ? '设置备注名' : '修改备注名',
                        isDark: isDark,
                        onTap: () {
                          entry.remove();
                          _editNickname(account);
                        },
                      ),
                      _AccountMenuItem(
                        icon: account.pinned
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        label: account.pinned ? '取消置顶' : '置顶',
                        isDark: isDark,
                        onTap: () {
                          entry.remove();
                          _togglePinned(account);
                        },
                      ),
                      _AccountMenuItem(
                        icon: Icons.swap_horizontal_circle_outlined,
                        label: '迁移设备',
                        isDark: isDark,
                        onTap: () {
                          entry.remove();
                          showDialog(
                            context: context,
                            builder: (_) => _DeviceMigrateDialog(
                              email: account.email,
                              region: account.region,
                            ),
                          );
                        },
                      ),
                      Divider(
                        height: 1,
                        color: isDark
                            ? AppColors.dividerDark
                            : AppColors.divider,
                      ),
                      _AccountMenuItem(
                        icon: Icons.delete_outline_rounded,
                        label: '删除账号',
                        isDark: isDark,
                        isDanger: true,
                        onTap: () {
                          entry.remove();
                          _confirmDelete(account);
                        },
                      ),
                      const SizedBox(height: 6),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(entry);
  }

  /// 确认删除账号。
  Future<void> _confirmDelete(BambuCloudAccount account) async {
    final confirmed = await AppDialog.confirm(
      context,
      '删除账号',
      '确定要删除账号 ${account.email} 吗？\n\n此操作会清除该账号的登录信息，但本地打印机记录会保留。',
      destructive: true,
      confirmText: '删除',
    );
    if (!confirmed) return;
    await ref
        .read(bambuAccountManagerProvider.notifier)
        .removeAccount(account.email, account.region);
    if (!mounted) return;
    showSnack(context, '已删除账号 ${account.email}');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final state = ref.watch(bambuAccountManagerProvider);

    // 过滤搜索结果：email 或 nickname 包含关键词（不区分大小写）
    final filtered = _query.isEmpty
        ? state.accounts
        : state.accounts.where((a) {
            final q = _query.toLowerCase();
            return a.email.toLowerCase().contains(q) ||
                a.nickname.toLowerCase().contains(q);
          }).toList();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: GlassCard(
          level: GlassLevel.l3,
          blur: 42,
          boxShadow: isDark ? AppColors.shadow4Dark : AppColors.shadow4,
          borderRadius: BorderRadius.circular(AppColors.radiusXl),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                count: state.accounts.length,
                onClose: () => Navigator.of(context).pop(),
              ),
              // 健康概览栏 + 批量检查按钮（有账号时显示）
              if (state.accounts.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                _HealthOverviewBar(
                  state: state,
                  checking: _healthChecking,
                  lastSummary: _lastHealthSummary,
                  onCheck: _runHealthCheck,
                ),
              ],
              // Bambu Studio 同步横幅（账号不一致或 token 写入失败时显示）
              if (state.bsAccountMismatch || state.bsTokenWriteFailed) ...[
                const SizedBox(height: AppSpacing.md),
                _BsSyncBanner(
                  mismatch: state.bsAccountMismatch,
                  tokenFailed: state.bsTokenWriteFailed,
                  onSync: _syncFromBs,
                ),
              ],
              if (_undoSource != null && _switchedTarget != null) ...[
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primaryContainer,
                    borderRadius: BorderRadius.circular(AppColors.radiusMd),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '已切换到 ${_switchedTarget!.displayName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: state.isSwitching ? null : _undoLastSwitch,
                        child: const Text('撤销'),
                      ),
                    ],
                  ),
                ),
              ],
              // 搜索框（仅多账号时显示）
              if (state.accounts.length > 1) ...[
                const SizedBox(height: AppSpacing.md),
                AppInput(
                  hint: '搜索账号（邮箱或备注名）',
                  search: true,
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              Flexible(
                fit: FlexFit.loose,
                child: state.accounts.isEmpty
                    ? const _EmptyContent()
                    : filtered.isEmpty
                    ? _NoSearchResult(query: _query)
                    : ReorderableListView(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        buildDefaultDragHandles: false,
                        onReorderItem: _onReorder,
                        children: [
                          for (int i = 0; i < filtered.length; i++)
                            _AccountCard(
                              key: ValueKey(filtered[i].uniqueKey),
                              account: filtered[i],
                              isActive:
                                  filtered[i].email ==
                                      state.activeAccountEmail &&
                                  filtered[i].region == state.activeRegion,
                              onSwitch: _switchWithUndo,
                              onContextTap: _showContextMenu,
                              index: i,
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: AppSpacing.lg),
              _Footer(
                hasAccounts: state.accounts.isNotEmpty,
                onAdd: () => _openLoginDialog(context, ref),
                onClose: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 打开登录弹窗添加新账号；关闭后刷新账号列表。
  ///
  /// 登录成功由 `BambuCloudNotifier._completeLogin` 自动调用
  /// `BambuAccountManagerNotifier.addAccount`，此处仅需在弹窗关闭后刷新视图。
  Future<void> _openLoginDialog(BuildContext context, WidgetRef ref) async {
    await CloudLoginDialog.show(context, addAccount: true);
    if (!context.mounted) return;
    await ref.read(bambuAccountManagerProvider.notifier).refresh();
  }

  /// 从 Bambu Studio 同步当前登录账号到本软件。
  Future<void> _syncFromBs() async {
    final ok = await ref
        .read(bambuAccountManagerProvider.notifier)
        .syncFromBambuStudio();
    if (!mounted) return;
    final state = ref.read(bambuAccountManagerProvider);
    if (ok) {
      showSnack(context, '已从 Bambu Studio 同步账号');
    } else if (state.lastError != null) {
      showSnack(context, state.lastError!);
    } else {
      showSnack(context, '同步失败');
    }
  }

  /// 执行批量账号健康检查，并在卡片上反映结果。
  ///
  /// - 成功：SnackBar 显示「3 账号 · 2 有效 · 1 过期」
  /// - 跳过：SnackBar 提示「正在切换账号，请稍后再试」
  /// - 失败：SnackBar 显示错误信息
  Future<void> _runHealthCheck() async {
    if (_healthChecking) return;
    setState(() => _healthChecking = true);
    try {
      final summary = await ref
          .read(bambuAccountManagerProvider.notifier)
          .checkAllAccountsHealth();
      if (!mounted) return;
      setState(() => _lastHealthSummary = summary);
      if (summary.skipped) {
        showSnack(
          context,
          '正在切换账号，请稍后再试',
          tone: AppNoticeTone.info,
          duration: const Duration(seconds: 2),
        );
      } else if (summary.allOk) {
        showSnack(
          context,
          '✓ ${summary.summaryText}，全部健康',
          duration: const Duration(seconds: 3),
        );
      } else {
        showSnack(
          context,
          summary.summaryText,
          tone: AppNoticeTone.warning,
          duration: const Duration(seconds: 4),
        );
      }
    } catch (e) {
      if (!mounted) return;
      showSnack(context, '健康检查失败：${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _healthChecking = false);
    }
  }
}

/// Bambu Studio 账号同步横幅。
///
/// 两种显示模式：
/// - [mismatch]=true：检测到 BS 账号与本软件不一致，显示「从 Bambu Studio 同步」按钮
/// - [tokenFailed]=true：token 写入失败，提示用户在 BS 手动登录一次
class _BsSyncBanner extends StatelessWidget {
  final bool mismatch;
  final bool tokenFailed;
  final VoidCallback onSync;

  const _BsSyncBanner({
    required this.mismatch,
    required this.tokenFailed,
    required this.onSync,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 账号不一致用主题色，token 失败用警告色
    final accentColor = mismatch ? AppColors.primary : AppColors.warning;
    final bgColor = isDark
        ? accentColor.withValues(alpha: 0.10)
        : accentColor.withValues(alpha: 0.08);
    final borderColor = accentColor.withValues(alpha: 0.25);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        children: [
          Icon(
            mismatch ? Icons.sync_alt : Icons.warning_amber_rounded,
            size: 16,
            color: accentColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              mismatch
                  ? 'Bambu Studio 账号已变更，点击同步到本软件'
                  : 'Bambu Studio token 写入失败，请在切片软件手动登录一次',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimary,
              ),
            ),
          ),
          if (mismatch)
            TextButton(
              onPressed: onSync,
              style: glassButtonStyle(
                context,
                TextButton.styleFrom(
                  foregroundColor: accentColor,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                variant: AppGlassButtonVariant.quiet,
              ),
              child: const Text('同步', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

/// 账号健康概览栏：实时统计 + 批量检查按钮。
///
/// 实时统计从 [BambuAccountManagerState.sessions] 计算（基于本地 isExpired 判定），
/// 不依赖网络。点击"检查"按钮触发 [BambuAccountManagerNotifier.checkAllAccountsHealth]
/// 主动验证每个账号 token。
class _HealthOverviewBar extends StatelessWidget {
  final BambuAccountManagerState state;
  final bool checking;
  final AccountHealthSummary? lastSummary;
  final VoidCallback onCheck;

  const _HealthOverviewBar({
    required this.state,
    required this.checking,
    required this.lastSummary,
    required this.onCheck,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 实时统计：从 sessions 计算
    final total = state.accounts.length;
    int expired = 0;
    int valid = 0;
    for (final account in state.accounts) {
      final session = state.sessionFor(account.email, account.region);
      if (session == null) {
        // 无 session 视为异常
        expired++;
      } else if (session.isExpired) {
        expired++;
      } else {
        valid++;
      }
    }

    // 颜色：有过期 → 警告色；全部有效 → 成功色
    final bool hasExpired = expired > 0;
    final Color accentColor = hasExpired
        ? AppColors.warning
        : AppColors.success;
    final Color bgColor = isDark
        ? accentColor.withValues(alpha: 0.10)
        : accentColor.withValues(alpha: 0.08);
    final Color borderColor = accentColor.withValues(alpha: 0.25);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        children: [
          Icon(
            hasExpired ? Icons.warning_amber_rounded : Icons.verified_outlined,
            size: 16,
            color: accentColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$total 账号 · $valid 有效${hasExpired ? " · $expired 过期" : ""}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? AppColors.textPrimaryDark
                        : AppColors.textPrimary,
                  ),
                ),
                if (lastSummary != null && lastSummary!.errors.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '上次检查：${lastSummary!.summaryText}'
                      '${lastSummary!.unknown > 0 ? "（含网络异常）" : ""}',
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 批量检查按钮
          _HealthCheckButton(checking: checking, onPressed: onCheck),
        ],
      ),
    );
  }
}

/// 健康检查按钮：checking 时显示 loading，否则显示"检查"图标按钮。
class _HealthCheckButton extends StatelessWidget {
  final bool checking;
  final VoidCallback onPressed;

  const _HealthCheckButton({required this.checking, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (GlassButtonsTheme.enabledOf(context)) {
      return Tooltip(
        message: '检查所有账号 token 是否有效',
        child: AppGlassButton(
          label: checking ? '检查中' : '检查',
          onPressed: checking ? null : onPressed,
          variant: AppGlassButtonVariant.quiet,
          compact: true,
          minimumSize: const Size(0, 28),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          icon: checking
              ? const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_rounded, size: 14),
        ),
      );
    }
    if (checking) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: isDark
                ? AppColors.textSecondaryDark
                : AppColors.textSecondary,
          ),
        ),
      );
    }
    return Tooltip(
      message: '检查所有账号 token 是否有效',
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.refresh_rounded,
                size: 14,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                '检查',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 标题栏：图标 + 标题 + 副标题 + 关闭按钮。
class _Header extends StatelessWidget {
  final int count;
  final VoidCallback onClose;
  const _Header({required this.count, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.primaryContainer,
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
          ),
          child: Icon(
            Icons.manage_accounts,
            size: 20,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '账号管理',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                count > 0 ? '共 $count 个拓竹账号' : '管理已保存的拓竹云账号',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded, size: 18),
          color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          onPressed: onClose,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// 单个账号卡片：拖拽 handle + 头像 + 显示名/邮箱 + 徽章 + 切换按钮。
///
/// 右键或点击更多按钮弹出菜单（编辑备注/置顶/迁移/删除）。
/// 切换走外部回调（支持撤销）。
class _AccountCard extends ConsumerStatefulWidget {
  final BambuCloudAccount account;
  final bool isActive;

  /// 切换回调（由父组件提供，支持撤销 SnackBar）。
  final Future<void> Function(BambuCloudAccount target) onSwitch;

  /// 右键菜单触发回调（position 为菜单弹出的全局坐标）。
  final void Function(
    BuildContext context,
    BambuCloudAccount account,
    Offset position,
  )
  onContextTap;

  /// 在列表中的索引（用于 ReorderableListView 的拖拽 handle key）。
  final int index;

  const _AccountCard({
    required this.account,
    required this.isActive,
    required this.onSwitch,
    required this.onContextTap,
    required this.index,
    super.key,
  });

  @override
  ConsumerState<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends ConsumerState<_AccountCard> {
  bool _switching = false;

  Future<void> _switch() async {
    if (_switching || widget.isActive) return;
    setState(() => _switching = true);
    try {
      await widget.onSwitch(widget.account);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isChina = widget.account.region == BambuRegion.china;

    // 从 managerState 拿 session，显示 token 状态 + 最后登录时间
    final managerState = ref.watch(bambuAccountManagerProvider);
    final session = managerState.sessionFor(
      widget.account.email,
      widget.account.region,
    );
    final isExpired = session?.isExpired ?? false;
    // 活跃账号的设备数从 cloudState 取（已实时拉取）
    final cloudState = ref.watch(bambuCloudProvider);
    final deviceCount = widget.isActive ? cloudState.devices.length : null;
    final loginAt = session?.loginAt;
    final expiresAt = session?.effectiveExpiresAt;

    return GlassCard(
      level: GlassLevel.l2,
      borderRadius: BorderRadius.circular(AppColors.radiusLg),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: (details) {
          widget.onContextTap(context, widget.account, details.globalPosition);
        },
        onLongPressStart: (details) {
          // 移动端/触屏的长按等价于右键
          widget.onContextTap(context, widget.account, details.globalPosition);
        },
        child: Row(
          children: [
            // 拖拽 handle
            ReorderableDragStartListener(
              index: widget.index,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 18,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                ),
              ),
            ),
            _Avatar(email: widget.account.email),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 显示名（优先 nickname，空则 email）
                  if (widget.account.nickname.isNotEmpty) ...[
                    Text(
                      widget.account.nickname,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.account.email,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? AppColors.textTertiaryDark
                            : AppColors.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ] else
                    Text(
                      widget.account.email,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (widget.account.pinned) const _PinnedBadge(),
                      _RegionBadge(isChina: isChina),
                      if (widget.isActive) const _CurrentBadge(),
                      if (isExpired)
                        const _ExpiredBadge()
                      else if (session != null)
                        _TokenOkBadge(expiresAt: expiresAt),
                      if (deviceCount != null)
                        _DeviceCountBadge(count: deviceCount),
                    ],
                  ),
                  if (loginAt != null || widget.account.lastUsedAt != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _buildTimeLine(loginAt, widget.account.lastUsedAt),
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark
                            ? AppColors.textTertiaryDark
                            : AppColors.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            if (widget.isActive)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.check_circle_rounded,
                  size: 20,
                  color: AppColors.primary,
                ),
              )
            else
              AppButton(
                label: _switching ? '切换中' : '切换',
                variant: AppButtonVariant.secondary,
                icon: _switching
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primary,
                        ),
                      )
                    : const Icon(Icons.swap_horiz_rounded, size: 16),
                onPressed: _switch,
              ),
            // 更多操作按钮（点开右键菜单的等价入口）
            IconButton(
              icon: Icon(
                Icons.more_vert_rounded,
                size: 18,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
              tooltip: '更多操作',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                final renderBox = context.findRenderObject() as RenderBox;
                final pos = renderBox.localToGlobal(
                  renderBox.size.center(Offset.zero),
                );
                widget.onContextTap(context, widget.account, pos);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 把 [DateTime] 格式化为相对时间 + 日期。
///
/// - 1 小时内：显示"X 分钟前"
/// - 24 小时内：显示"X 小时前"
/// - 否则：显示"YYYY-MM-DD HH:mm"
String _formatLoginTime(DateTime time) {
  final now = DateTime.now();
  final diff = now.difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  final y = time.year.toString().padLeft(4, '0');
  final m = time.month.toString().padLeft(2, '0');
  final d = time.day.toString().padLeft(2, '0');
  final h = time.hour.toString().padLeft(2, '0');
  final min = time.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $h:$min';
}

/// 构建账号卡片的时间信息行：合并显示最后登录和最后使用。
///
/// - 只有 loginAt：显示"最后登录：X 分钟前"
/// - 只有 lastUsedAt：显示"最后使用：X 分钟前"
/// - 都有：分两行合并为"最后登录：... · 最后使用：..."
/// - 都没有：返回空字符串
String _buildTimeLine(DateTime? loginAt, DateTime? lastUsedAt) {
  final parts = <String>[];
  if (loginAt != null) {
    parts.add('最后登录：${_formatLoginTime(loginAt)}');
  }
  if (lastUsedAt != null) {
    parts.add('最后使用：${_formatLoginTime(lastUsedAt)}');
  }
  return parts.join(' · ');
}

/// 首字母圆形头像，颜色按 email 哈希分配。
class _Avatar extends StatelessWidget {
  final String email;
  const _Avatar({required this.email});

  static final _colors = [
    AppColors.primary,
    AppColors.info,
    AppColors.accent,
    AppColors.warning,
    const Color(0xFFAF52DE), // systemPurple
    const Color(0xFFFF2D55), // systemPink
    const Color(0xFF5AC8FA), // systemCyan
  ];

  @override
  Widget build(BuildContext context) {
    // & 0x7FFFFFFF 保证非负
    final color = _colors[(email.hashCode & 0x7FFFFFFF) % _colors.length];
    final initial = email.isNotEmpty ? email[0].toUpperCase() : '?';
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 区域徽章：中国区=蓝色，海外区=紫色。
class _RegionBadge extends StatelessWidget {
  final bool isChina;
  const _RegionBadge({required this.isChina});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color fg;
    final Color bg;
    final String label;
    if (isChina) {
      fg = AppColors.info;
      bg = isDark
          ? AppColors.infoContainer.withValues(alpha: 0.18)
          : AppColors.infoContainer;
      label = '中国区';
    } else {
      const purple = Color(0xFFAF52DE);
      fg = purple;
      bg = isDark ? purple.withValues(alpha: 0.20) : const Color(0xFFF3E8FF);
      label = '海外区';
    }
    return _Badge(label: label, fg: fg, bg: bg);
  }
}

/// 当前活跃账号徽章：绿色。
class _CurrentBadge extends StatelessWidget {
  const _CurrentBadge();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _Badge(
      label: '当前',
      fg: AppColors.primary,
      bg: isDark
          ? AppColors.primaryContainer.withValues(alpha: 0.20)
          : AppColors.primaryContainer,
      border: AppColors.primary.withValues(alpha: isDark ? 0.6 : 1.0),
    );
  }
}

/// token 已过期徽章：红色。
class _ExpiredBadge extends StatelessWidget {
  const _ExpiredBadge();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _Badge(
      label: '已过期',
      fg: AppColors.danger,
      bg: isDark
          ? AppColors.danger.withValues(alpha: 0.18)
          : AppColors.danger.withValues(alpha: 0.10),
      border: AppColors.danger.withValues(alpha: isDark ? 0.5 : 0.6),
    );
  }
}

/// token 有效徽章：绿色，显示剩余有效时长。
class _TokenOkBadge extends StatelessWidget {
  final DateTime? expiresAt;
  const _TokenOkBadge({this.expiresAt});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    String label = '自动续期';
    if (expiresAt != null) {
      final remaining = expiresAt!.difference(DateTime.now());
      if (remaining.inDays >= 90) {
        label = '长期有效';
      } else if (remaining.inDays > 0) {
        label = '剩 ${remaining.inDays} 天';
      } else if (remaining.inHours > 0) {
        label = '剩 ${remaining.inHours} 小时';
      }
    }
    return _Badge(
      label: label,
      fg: AppColors.success,
      bg: isDark
          ? AppColors.success.withValues(alpha: 0.18)
          : AppColors.success.withValues(alpha: 0.10),
    );
  }
}

/// 设备数量徽章：蓝色。
class _DeviceCountBadge extends StatelessWidget {
  final int count;
  const _DeviceCountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _Badge(
      label: '$count 台设备',
      fg: AppColors.info,
      bg: isDark
          ? AppColors.infoContainer.withValues(alpha: 0.18)
          : AppColors.infoContainer,
    );
  }
}

/// 通用胶囊徽章。
class _Badge extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;
  final Color? border;
  const _Badge({
    required this.label,
    required this.fg,
    required this.bg,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppColors.radiusFull),
        border: border != null ? Border.all(color: border!, width: 1) : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 空状态：无账号时显示。
class _EmptyContent extends StatelessWidget {
  const _EmptyContent();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.account_circle_outlined,
      title: '尚未添加任何拓竹账号',
      subtitle: '点击下方按钮添加',
    );
  }
}

/// 搜索无结果状态。
class _NoSearchResult extends StatelessWidget {
  final String query;
  const _NoSearchResult({required this.query});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 36,
              color:
                  (isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondary)
                      .withValues(alpha: 0.6),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '没有匹配 "$query" 的账号',
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// 置顶徽章：橙色图钉图标。
class _PinnedBadge extends StatelessWidget {
  const _PinnedBadge();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _Badge(
      label: '置顶',
      fg: AppColors.warning,
      bg: isDark
          ? AppColors.warning.withValues(alpha: 0.18)
          : AppColors.warning.withValues(alpha: 0.12),
    );
  }
}

/// 底部操作区：添加账号按钮（始终显示）+ 关闭按钮（有账号时显示）。
class _Footer extends StatelessWidget {
  final bool hasAccounts;
  final VoidCallback onAdd;
  final VoidCallback onClose;
  const _Footer({
    required this.hasAccounts,
    required this.onAdd,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: AppButton(
            label: '添加账号',
            icon: const Icon(Icons.person_add_alt, size: 18),
            onPressed: onAdd,
          ),
        ),
        if (hasAccounts) ...[
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: AppButton(
              label: '关闭',
              variant: AppButtonVariant.secondary,
              onPressed: onClose,
            ),
          ),
        ],
      ],
    );
  }
}

/// 设备迁移对话框：列出指定账号下的所有云端设备，支持两种模式：
///
/// 1. **仅解绑**：从当前账号解绑设备（纯 API 自动化）
/// 2. **解绑并迁移到目标账号**：解绑后自动切换到目标账号，并引导用户
///    通过 PIN 码在软件内完成绑定（纯软件闭环，无需安装 Bambu Studio）
///
/// 解绑流程（逆向自 Bambu Studio 的"移除设备"功能）：
/// - 端点：`DELETE /v1/iot-service/api/user/bind`
/// - 请求体：`{"dev_id": "<序列号>", "force": false}`
///
/// 绑定流程（通过内置 bind_tool.exe 调用 bambu_networking.dll）：
/// - 用户从打印机屏幕获取 PIN 码（设置→网络→WLAN→PIN 码）
/// - 软件调用 bind_tool.exe <PIN> <token.json> 完成纯软件绑定
class _DeviceMigrateDialog extends ConsumerStatefulWidget {
  final String email;
  final BambuRegion region;

  const _DeviceMigrateDialog({required this.email, required this.region});

  @override
  ConsumerState<_DeviceMigrateDialog> createState() =>
      _DeviceMigrateDialogState();
}

class _DeviceMigrateDialogState extends ConsumerState<_DeviceMigrateDialog> {
  List<BambuCloudDevice> _devices = const [];
  bool _loading = true;
  String? _error;
  final Set<String> _migrating = {}; // 正在解绑的 devId
  final Set<String> _migrated = {}; // 已解绑的 devId

  /// 迁移模式: null=未选择, false=仅解绑, true=解绑并切换账号
  bool? _migrateToAccount;

  /// 选中的目标账号 (email)
  String? _targetEmail;
  BambuRegion? _targetRegion;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = await BambuCloudSessionStore.loadSessionFor(
        widget.email,
        widget.region,
      );
      if (session == null) {
        setState(() {
          _error = '账号 session 不存在，请重新登录';
          _loading = false;
        });
        return;
      }
      if (session.isExpired) {
        setState(() {
          _error = '该账号 token 已过期，请重新登录后重试';
          _loading = false;
        });
        return;
      }
      final devices = await BambuCloudClient.getDeviceList(session);
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  /// 获取可选的目标账号列表 (排除源账号)
  List<BambuCloudAccount> get _targetAccounts {
    final accounts = ref.read(bambuAccountManagerProvider).accounts;
    return accounts
        .where((a) => !(a.email == widget.email && a.region == widget.region))
        .toList();
  }

  Future<void> _migrateDevice(BambuCloudDevice device) async {
    // 根据模式构建确认文案
    String title;
    String message;
    if (_migrateToAccount == true && _targetEmail != null) {
      title = '迁移设备到 $_targetEmail';
      message =
          '将设备 ${device.devProductName}（${device.devId}）'
          '从 ${widget.email} 迁移到 $_targetEmail？\n\n'
          '操作步骤：\n'
          '1. 从 ${widget.email} 解绑该设备\n'
          '2. 自动切换到账号 $_targetEmail\n'
          '3. 在弹出的添加打印机页面输入 PIN 码完成绑定\n\n'
          '请在打印机屏幕获取 PIN 码：设置 → 网络 → WLAN → PIN 码';
    } else {
      title = '解绑设备';
      message =
          '确定要从账号 ${widget.email} 解绑设备 '
          '${device.devProductName}（${device.devId}）吗？\n\n'
          '解绑后该设备将不再显示在此账号下。';
    }

    final confirmed = await AppDialog.confirm(
      context,
      title,
      message,
      destructive: true,
      confirmText: _migrateToAccount == true ? '迁移' : '解绑',
    );
    if (!confirmed) return;

    setState(() => _migrating.add(device.devId));
    try {
      // 步骤 1: 解绑
      final ok = await ref
          .read(bambuAccountManagerProvider.notifier)
          .migrateDevice(
            sourceEmail: widget.email,
            sourceRegion: widget.region,
            devId: device.devId,
            force: false,
          );
      if (!mounted) return;
      if (ok) {
        setState(() {
          _migrated.add(device.devId);
          _migrating.remove(device.devId);
        });

        if (_migrateToAccount == true && _targetEmail != null) {
          // 步骤 2: 切换到目标账号
          showSnack(context, '设备已解绑，正在切换到 $_targetEmail...');
          final switched = await ref
              .read(bambuAccountManagerProvider.notifier)
              .switchAccount(_targetEmail!, _targetRegion!);
          if (!mounted) return;

          if (switched) {
            // 步骤 3: 关闭迁移对话框，打开添加打印机页面引导 PIN 码绑定
            Navigator.of(context).pop();
            showSnack(context, '已切换到 $_targetEmail，请输入 PIN 码完成绑定');
            AddPrinterSheet.show(context);
          } else {
            final err = ref.read(bambuAccountManagerProvider).lastError;
            showSnack(context, '解绑成功但切换账号失败：${err ?? "未知错误"}', error: true);
          }
        } else {
          showSnack(context, '设备 ${device.devId} 已解绑');
        }
      } else {
        setState(() => _migrating.remove(device.devId));
        final err = ref.read(bambuAccountManagerProvider).lastError;
        showSnack(context, '解绑失败：${err ?? "请检查网络或稍后重试"}', error: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _migrating.remove(device.devId));
      showSnack(context, '解绑失败：${friendlyError(e)}', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 620),
        child: GlassCard(
          level: GlassLevel.l3,
          blur: 42,
          boxShadow: isDark ? AppColors.shadow4Dark : AppColors.shadow4,
          borderRadius: BorderRadius.circular(AppColors.radiusXl),
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题
              Row(
                children: [
                  const Icon(
                    Icons.swap_horizontal_circle,
                    size: 22,
                    color: AppColors.info,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '设备管理',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? AppColors.textPrimaryDark
                                : AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          '账号 ${widget.email} (${widget.region.code})',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              // 模式选择
              _buildModeSelector(isDark),
              const SizedBox(height: AppSpacing.sm),
              // 设备列表
              Flexible(fit: FlexFit.loose, child: _buildBody(isDark)),
            ],
          ),
        ),
      ),
    );
  }

  /// 模式选择器: 仅解绑 / 解绑并迁移到目标账号
  Widget _buildModeSelector(bool isDark) {
    final targetAccounts = _targetAccounts;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (isDark ? AppColors.primary : AppColors.primary).withValues(
          alpha: 0.06,
        ),
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 模式选择按钮组
          Row(
            children: [
              Expanded(
                child: _buildModeOption(
                  isDark,
                  icon: Icons.link_off,
                  label: '仅解绑',
                  selected: _migrateToAccount == false,
                  onTap: () => setState(() {
                    _migrateToAccount = false;
                    _targetEmail = null;
                    _targetRegion = null;
                  }),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _buildModeOption(
                  isDark,
                  icon: Icons.swap_horiz_rounded,
                  label: '迁移到其他账号',
                  selected: _migrateToAccount == true,
                  enabled: targetAccounts.isNotEmpty,
                  onTap: targetAccounts.isEmpty
                      ? null
                      : () => setState(() {
                          _migrateToAccount = true;
                          if (_targetEmail == null &&
                              targetAccounts.isNotEmpty) {
                            _targetEmail = targetAccounts.first.email;
                            _targetRegion = targetAccounts.first.region;
                          }
                        }),
                ),
              ),
            ],
          ),
          // 目标账号下拉选择
          if (_migrateToAccount == true) ...[
            const SizedBox(height: AppSpacing.sm),
            if (targetAccounts.isEmpty)
              const Text(
                '没有其他账号可选，请先在账号管理中添加目标账号',
                style: TextStyle(fontSize: 11, color: AppColors.warning),
              )
            else
              AppSelect<String>(
                value: _targetEmail,
                label: '目标账号',
                items: targetAccounts.map((a) {
                  return DropdownMenuItem<String>(
                    value: a.email,
                    child: Text(
                      '${a.displayName} (${a.region.code})',
                      style: const TextStyle(fontSize: 12),
                    ),
                  );
                }).toList(),
                onChanged: (v) {
                  final acc = targetAccounts.where((a) => a.email == v).first;
                  setState(() {
                    _targetEmail = v;
                    _targetRegion = acc.region;
                  });
                },
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildModeOption(
    bool isDark, {
    required IconData icon,
    required String label,
    required bool selected,
    bool enabled = true,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppColors.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.15)
              : (isDark ? AppColors.surfaceDark : AppColors.surface).withValues(
                  alpha: 0.5,
                ),
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
          border: Border.all(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.5)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: !enabled
                  ? AppColors.textSecondary.withValues(alpha: 0.4)
                  : selected
                  ? AppColors.primary
                  : (isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondary),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: !enabled
                      ? AppColors.textSecondary.withValues(alpha: 0.4)
                      : selected
                      ? AppColors.primary
                      : (isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 40,
                color: AppColors.danger,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: '重试',
                variant: AppButtonVariant.secondary,
                onPressed: _loadDevices,
              ),
            ],
          ),
        ),
      );
    }
    if (_devices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.devices_other,
                size: 40,
                color: AppColors.textSecondary.withValues(alpha: 0.5),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                '该账号下没有绑定任何设备',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: _devices.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (_, i) => _buildDeviceItem(_devices[i], isDark),
          ),
        ),
        if (_migrateToAccount == true && _targetEmail != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppColors.radiusMd),
              border: Border.all(
                color: AppColors.success.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.lightbulb_outline,
                  size: 14,
                  color: AppColors.success,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '迁移流程：点击"迁移"→ 自动解绑并切换到 '
                    '$_targetEmail → 在弹出的添加打印机页面输入打印机 PIN 码'
                    '（设置→网络→WLAN→PIN 码）完成绑定',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDeviceItem(BambuCloudDevice device, bool isDark) {
    final isMigrating = _migrating.contains(device.devId);
    final isMigrated = _migrated.contains(device.devId);
    final isTransferMode = _migrateToAccount == true && _targetEmail != null;

    return GlassCard(
      level: GlassLevel.l2,
      borderRadius: BorderRadius.circular(AppColors.radiusLg),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(
            isMigrated
                ? Icons.check_circle_rounded
                : device.online
                ? Icons.print_rounded
                : Icons.print_disabled,
            size: 20,
            color: isMigrated
                ? AppColors.success
                : device.online
                ? AppColors.primary
                : AppColors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.devProductName.isNotEmpty
                      ? device.devProductName
                      : device.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? AppColors.textPrimaryDark
                        : AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  device.devId,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (isMigrated)
            const Text(
              '已解绑',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.success,
                fontWeight: FontWeight.w600,
              ),
            )
          else if (isMigrating)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            AppButton(
              label: isTransferMode ? '迁移' : '解绑',
              variant: isTransferMode
                  ? AppButtonVariant.primary
                  : AppButtonVariant.secondary,
              icon: Icon(
                isTransferMode ? Icons.swap_horiz_rounded : Icons.link_off,
                size: 14,
              ),
              onPressed: () => _migrateDevice(device),
            ),
        ],
      ),
    );
  }
}

/// 账号操作菜单项：图标 + 文字，支持 hover 高亮与危险态（删除）。
class _AccountMenuItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isDark;
  final bool isDanger;
  final VoidCallback onTap;

  const _AccountMenuItem({
    required this.icon,
    required this.label,
    required this.isDark,
    required this.onTap,
    this.isDanger = false,
  });

  @override
  State<_AccountMenuItem> createState() => _AccountMenuItemState();
}

class _AccountMenuItemState extends State<_AccountMenuItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.isDanger
        ? AppColors.danger
        : (widget.isDark ? AppColors.textPrimaryDark : AppColors.textPrimary);
    final bgColor = widget.isDanger
        ? AppColors.danger.withValues(alpha: _hovering ? 0.10 : 0)
        : (widget.isDark ? Colors.white : AppColors.primary).withValues(
            alpha: _hovering ? 0.06 : 0,
          );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.duration(
            context,
            const Duration(milliseconds: 150),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          color: bgColor,
          child: Row(
            children: [
              Icon(widget.icon, size: 17, color: color),
              const SizedBox(width: 12),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
