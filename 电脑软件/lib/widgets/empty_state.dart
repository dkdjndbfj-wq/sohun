import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import 'app_button.dart';
import 'bambu_icon.dart';
import 'glass_card.dart';

/// 通用空状态占位（v5 升级：走 GlassCard 体系 + 可选拓竹 SVG 图标）。
///
/// 圆形浅底图标徽章 + 清晰标题副标题层次 + AppButton 操作。
class EmptyState extends StatelessWidget {
  final IconData? icon;
  final String? bambuIconName;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 是否走 GlassCard 包装。默认 false（保持原居中布局）。
  ///
  /// true 时用 GlassCard L2 包裹，适合嵌在卡片网格中。
  final bool useGlass;

  const EmptyState({
    super.key,
    this.icon,
    this.bambuIconName,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.useGlass = false,
  }) : assert(
          icon != null || bambuIconName != null,
          '必须提供 icon 或 bambuIconName 之一',
        );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 圆形浅底图标徽章
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.primaryContainer,
              shape: BoxShape.circle,
              border: Border.all(
                color: isDark
                    ? AppColors.primary.withValues(alpha: 0.2)
                    : AppColors.primary100,
                width: 1,
              ),
            ),
            alignment: Alignment.center,
            child: bambuIconName != null
                ? BambuIcon(
                    name: bambuIconName!,
                    size: 28,
                    color: AppColors.primary,
                    applyColorFilter: true,
                  )
                : Icon(icon, size: 28, color: AppColors.primary),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
              letterSpacing: -0.2,
            ),
            textAlign: TextAlign.center,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 20),
            AppButton(
              label: actionLabel!,
              icon: const Icon(Icons.add_rounded),
              onPressed: onAction,
            ),
          ],
        ],
      ),
    );

    if (!useGlass) {
      return Center(child: content);
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: GlassCard(
          level: GlassLevel.l2,
          padding: EdgeInsets.zero,
          child: content,
        ),
      ),
    );
  }
}

/// 通用加载占位。居中转圈 + 可选文字。
class LoadingState extends StatelessWidget {
  final String? label;

  const LoadingState({super.key, this.label = '正在加载…'});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppColors.primary),
          const SizedBox(height: 12),
          Text(
            label!,
            style: TextStyle(
              fontSize: 13,
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
