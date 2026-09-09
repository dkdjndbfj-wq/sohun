import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_typography.dart';
import 'bambu_icon.dart';
import 'glass_card.dart';

/// 通用统计卡片（v5 重构：走 GlassCard L2 体系 + 等宽字体 + 可选点击跳转）。
///
/// 用于展示单个统计指标：图标 + 标签 + 数值 + 单位。
/// 支持 highlight 高亮态、loading/error 命名构造、BambuIcon 图标。
///
/// v5 变更：
/// - 新增 [bambuIconName]：使用拓竹 SVG 图标替代 IconData
/// - 新增 [onTap]：点击跳转，hover 上浮 + 阴影加深
/// - 新增 [useGlass]：是否走 GlassCard L2 体系（默认 true）
/// - 数值默认使用 [AppTypography.dataLarge] 等宽字体
///
/// 保留 [icon] 参数向后兼容：未提供 [bambuIconName] 时回退到 [icon]。
class AppStatBox extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final IconData? icon;
  final String? bambuIconName;
  final Color color;
  final bool highlight;

  /// 点击回调。设置后启用 hover 上浮 + 阴影加深动效。
  final VoidCallback? onTap;

  /// 是否走 GlassCard L2 体系。默认 true。
  ///
  /// false 时回退到 v1 的简单 Container 样式（向后兼容）。
  final bool useGlass;

  /// 是否使用等宽字体显示数值。默认 true。
  final bool useMonoFont;

  const AppStatBox({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    this.icon,
    this.bambuIconName,
    required this.color,
    this.highlight = false,
    this.onTap,
    this.useGlass = true,
    this.useMonoFont = true,
  }) : assert(
          icon != null || bambuIconName != null,
          '必须提供 icon 或 bambuIconName 之一',
        );

  const AppStatBox.loading({super.key})
      : label = '加载中',
        value = '—',
        unit = '',
        icon = Icons.hourglass_top_rounded,
        bambuIconName = null,
        color = AppColors.textTertiary,
        highlight = false,
        onTap = null,
        useGlass = true,
        useMonoFont = true;

  const AppStatBox.error({super.key})
      : label = '出错',
        value = '—',
        unit = '',
        icon = Icons.error_outline_rounded,
        bambuIconName = null,
        color = AppColors.danger,
        highlight = false,
        onTap = null,
        useGlass = true,
        useMonoFont = true;

  @override
  Widget build(BuildContext context) {
    if (!useGlass) {
      return _buildLegacy(context);
    }
    return GlassCard(
      level: GlassLevel.l2,
      padding: const EdgeInsets.all(12),
      onTap: onTap,
      child: _buildContent(context),
    );
  }

  /// v1 简单 Container 样式（向后兼容）。
  Widget _buildLegacy(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: highlight
            ? color.withValues(alpha: 0.08)
            : (isDark
                ? AppColors.surfaceVariantDark.withValues(alpha: 0.4)
                : AppColors.surfaceVariant.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        border:
            highlight ? Border.all(color: color.withValues(alpha: 0.2)) : null,
      ),
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        // 图标
        _buildIcon(isDark),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    value,
                    style: useMonoFont
                        ? AppTypography.dataLarge.copyWith(
                            fontSize: 20,
                            color: highlight
                                ? color
                                : (isDark
                                    ? AppColors.textPrimaryDark
                                    : AppColors.textPrimary),
                          )
                        : TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: highlight
                                ? color
                                : (isDark
                                    ? AppColors.textPrimaryDark
                                    : AppColors.textPrimary),
                            fontFeatures: const [
                              ui.FontFeature.tabularFigures(),
                            ],
                          ),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    unit,
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIcon(bool isDark) {
    // 优先使用拓竹 SVG 图标
    if (bambuIconName != null) {
      return Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: BambuIcon(
            name: bambuIconName!,
            size: 15,
            color: color,
            applyColorFilter: true,
          ),
        ),
      );
    }
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(icon, size: 15, color: color),
    );
  }
}
