import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/external/printer/bambu_cloud_models.dart';
import '../../providers/bambu_account_manager.dart';
import '../../providers/bambu_cloud_provider.dart';
import '../features/account/account_manager_screen.dart';
import 'bambu_icon.dart';
import '../core/theme/glass_button_theme.dart';
import 'glass_button_material.dart';

/// 顶栏账号快速切换器。
///
/// 点击展开 PopupMenu，显示所有账号，支持一键切换。
/// 仅在已登录时显示；多账号时显示 "+N" 徽章。
class AccountQuickSwitcher extends ConsumerWidget {
  const AccountQuickSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final managerState = ref.watch(bambuAccountManagerProvider);
    final cloudState = ref.watch(bambuCloudProvider);

    // 未登录且无账号时不显示
    if (managerState.accounts.isEmpty && !cloudState.isLoggedIn) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeEmail = managerState.activeAccountEmail;
    final hasMultiple = managerState.hasMultipleAccounts;

    return PopupMenuButton<_AccountMenuItem>(
      onSelected: (item) => item.onTap(context, ref),
      offset: const Offset(0, 44),
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 340),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        side: BorderSide(
          color: isDark ? AppColors.glassBorderDarkMode : AppColors.glassBorder,
        ),
      ),
      color: isDark ? AppColors.surfaceDark : AppColors.surface,
      child: _Trigger(
        email: activeEmail,
        isDark: isDark,
        hasMultiple: hasMultiple,
        accountCount: managerState.accounts.length,
        isSwitching: managerState.isSwitching,
      ),
      itemBuilder: (ctx) => _buildItems(managerState, cloudState, isDark),
    );
  }

  List<PopupMenuItem<_AccountMenuItem>> _buildItems(
    BambuAccountManagerState managerState,
    BambuCloudState cloudState,
    bool isDark,
  ) {
    final items = <PopupMenuItem<_AccountMenuItem>>[];

    // 账号列表
    for (final account in managerState.accounts) {
      final isActive =
          account.email == managerState.activeAccountEmail &&
          account.region == managerState.activeRegion;
      final session = cloudState.session;
      final isExpired = isActive && session != null && session.isExpired;
      final deviceCount = isActive ? cloudState.devices.length : null;

      items.add(
        PopupMenuItem(
          value: _AccountMenuItem(
            onTap: isActive
                ? (_, __) {}
                : (context, ref) {
                    ref
                        .read(bambuAccountManagerProvider.notifier)
                        .switchAccount(account.email, account.region);
                  },
          ),
          child: _AccountRow(
            email: account.email,
            region: account.region,
            isActive: isActive,
            isExpired: isExpired,
            deviceCount: deviceCount,
            isDark: isDark,
          ),
        ),
      );
    }

    // 分隔线
    items.add(
      const PopupMenuItem(enabled: false, height: 1, child: Divider(height: 1)),
    );

    // 管理账号
    items.add(
      PopupMenuItem(
        value: _AccountMenuItem(
          onTap: (context, ref) => AccountManagerScreen.show(context),
        ),
        child: Row(
          children: [
            Icon(
              Icons.settings_outlined,
              size: 16,
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Text(
              '管理账号',
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

    return items;
  }
}

/// 快速切换器的触发按钮（头像 + 邮箱首字母 + 多账号徽章）。
class _Trigger extends StatelessWidget {
  final String? email;
  final bool isDark;
  final bool hasMultiple;
  final int accountCount;
  final bool isSwitching;

  const _Trigger({
    this.email,
    required this.isDark,
    required this.hasMultiple,
    required this.accountCount,
    required this.isSwitching,
  });

  @override
  Widget build(BuildContext context) {
    final initial = email != null && email!.isNotEmpty
        ? email![0].toUpperCase()
        : '?';

    final trigger = Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppColors.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头像
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.primary.withValues(alpha: 0.8),
                      AppColors.accent.withValues(alpha: 0.8),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(AppColors.radiusFull),
                ),
                child: Center(
                  child: isSwitching
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : Text(
                          initial,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
              // 多账号徽章
              if (hasMultiple && !isSwitching)
                Positioned(
                  right: -4,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(AppColors.radiusFull),
                      border: Border.all(
                        color: isDark
                            ? AppColors.surfaceDark
                            : AppColors.surface,
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      '+${accountCount - 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 6),
          BambuIcon(
            name: 'drop_down',
            size: 16,
            color: isDark
                ? AppColors.textSecondaryDark
                : AppColors.textSecondary,
            applyColorFilter: true,
          ),
        ],
      ),
    );
    return GlassButtonsTheme.enabledOf(context)
        ? GlassButtonMaterial(
            variant: AppGlassButtonVariant.quiet,
            shape: const StadiumBorder(),
            child: trigger,
          )
        : trigger;
  }
}

/// PopupMenu 中的账号行。
class _AccountRow extends StatelessWidget {
  final String email;
  final BambuRegion region;
  final bool isActive;
  final bool isExpired;
  final int? deviceCount;
  final bool isDark;

  const _AccountRow({
    required this.email,
    required this.region,
    required this.isActive,
    required this.isExpired,
    this.deviceCount,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final subColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return Row(
      children: [
        // 头像
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: isActive
                ? AppColors.primary.withValues(alpha: 0.15)
                : (isDark
                      ? AppColors.surfaceVariantDark
                      : AppColors.surfaceVariant),
            borderRadius: BorderRadius.circular(AppColors.radiusFull),
            border: isActive
                ? Border.all(color: AppColors.primary, width: 1.5)
                : null,
          ),
          child: Center(
            child: Text(
              email.isNotEmpty ? email[0].toUpperCase() : '?',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: isActive ? AppColors.primary : subColor,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 邮箱 + 状态
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                email,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  // 区域徽章
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: region == BambuRegion.china
                          ? AppColors.info.withValues(alpha: 0.12)
                          : AppColors.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppColors.radiusSm),
                    ),
                    child: Text(
                      region == BambuRegion.china ? '中国区' : '海外区',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: region == BambuRegion.china
                            ? AppColors.info
                            : AppColors.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 设备数
                  if (deviceCount != null) ...[
                    Text(
                      '$deviceCount 台设备',
                      style: TextStyle(fontSize: 10, color: subColor),
                    ),
                    const SizedBox(width: 6),
                  ],
                  // token 过期
                  if (isExpired) ...[
                    const Text(
                      '已过期',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.danger,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  // 当前标记
                  if (isActive && !isExpired)
                    const Text(
                      '当前',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        // 选中勾
        if (isActive)
          Icon(Icons.check_circle_rounded, size: 16, color: AppColors.primary),
      ],
    );
  }
}

/// PopupMenu 项的回调包装。
class _AccountMenuItem {
  final void Function(BuildContext context, WidgetRef ref) onTap;

  const _AccountMenuItem({required this.onTap});
}
