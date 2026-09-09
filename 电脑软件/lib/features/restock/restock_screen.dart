import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/gram_utils.dart';
import '../../core/utils/friendly_error.dart';
import '../../providers/stock_alert_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';

/// 采购清单页（功能 6：耗材低库存预警 + 采购清单生成）。
///
/// 布局参考 [FilamentCostScreen]：
/// - 顶部 3 格统计卡片（critical / low / 预计采购总成本）
/// - 库存预警列表（按 critical → low → healthy 排序）
/// - 采购清单（带复选框）
/// - 底部操作栏：导出采购清单到剪贴板
///
/// 空状态：库存充足，暂无预警。
class RestockScreen extends ConsumerStatefulWidget {
  const RestockScreen({super.key});

  @override
  ConsumerState<RestockScreen> createState() => _RestockScreenState();
}

class _RestockScreenState extends ConsumerState<RestockScreen> {
  /// 用户勾选的采购建议 key 集合。
  final Set<String> _selectedKeys = {};

  /// 是否已对默认勾选做过初始化（避免覆盖用户「清空」操作）。
  bool _selectionInitialized = false;

  @override
  Widget build(BuildContext context) {
    final alertsAsync = ref.watch(stockAlertsProvider);
    final purchaseAsync = ref.watch(purchaseListProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: alertsAsync.when(
        loading: () => const LoadingState(),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '加载失败：${friendlyError(err)}',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (alerts) {
          // 空状态：无任何耗材或全部 healthy 且无采购建议
          final hasAlerts = alerts.any(
            (a) => a.level == StockLevel.critical || a.level == StockLevel.low,
          );

          if (alerts.isEmpty) {
            return const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: '还没有耗材',
              subtitle: '添加耗材后会自动计算库存预警',
            );
          }

          if (!hasAlerts) {
            return const EmptyState(
              icon: Icons.check_circle_outline,
              title: '库存充足，暂无预警',
              subtitle: '所有规格库存均在安全水位以上',
            );
          }

          final criticalCount =
              alerts.where((a) => a.level == StockLevel.critical).length;
          final lowCount =
              alerts.where((a) => a.level == StockLevel.low).length;

          return purchaseAsync.when(
            loading: () => const LoadingState(),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '采购清单加载失败：${friendlyError(e)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            data: (suggestions) {
              // 首次进入页面时默认勾选全部采购项；
              // 后续不再自动恢复，避免覆盖用户「清空」操作。
              if (!_selectionInitialized) {
                _selectedKeys
                  ..clear()
                  ..addAll(suggestions.map((s) => s.key));
                _selectionInitialized = true;
              } else {
                // 仅剔除已不存在的 key，保留用户已勾选项
                final validKeys = suggestions.map((s) => s.key).toSet();
                _selectedKeys.removeWhere((k) => !validKeys.contains(k));
              }

              final selectedItems = suggestions
                  .where((s) => _selectedKeys.contains(s.key))
                  .toList();
              final totalCost = selectedItems.fold<double>(
                0,
                (sum, s) => sum + (s.estimatedCost ?? 0),
              );

              return Padding(
                padding: const EdgeInsets.all(ExperienceTokens.pageGutter),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ExperiencePageHeader(
                      title: '耗材补给站',
                      description: '左边是正在下降的库存水位，右边是由真实消耗速度生成的采购篮。勾选变化会立即重算预算。',
                    ),
                    const SizedBox(height: 18),
                    _SummaryCard(
                      criticalCount: criticalCount,
                      lowCount: lowCount,
                      totalPurchaseCost: totalCost,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Expanded(
                      child: _RestockWorkspace(
                        alerts: alerts,
                        suggestions: suggestions,
                        selectedKeys: _selectedKeys,
                        selectedItems: selectedItems,
                        totalCost: totalCost,
                        onToggle: (key) {
                          setState(() {
                            if (_selectedKeys.contains(key)) {
                              _selectedKeys.remove(key);
                            } else {
                              _selectedKeys.add(key);
                            }
                          });
                        },
                        onSelectAll: () {
                          setState(() {
                            _selectedKeys
                              ..clear()
                              ..addAll(suggestions.map((s) => s.key));
                          });
                        },
                        onClearAll: () => setState(_selectedKeys.clear),
                        onExport: () => _exportToClipboard(selectedItems),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// 把选中的采购项导出为文本到剪贴板。
  Future<void> _exportToClipboard(
    List<PurchaseSuggestion> items,
  ) async {
    if (items.isEmpty) {
      _showSnack('请先勾选要采购的项目');
      return;
    }

    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final buf = StringBuffer()
      ..writeln('耗材采购清单 - $y-$m-$d')
      ..writeln(
        '共 ${items.length} 项，预计总成本 ¥${items.fold<double>(0, (s, e) => s + (e.estimatedCost ?? 0)).toStringAsFixed(2)}',
      )
      ..writeln('---');

    for (var i = 0; i < items.length; i++) {
      final s = items[i];
      final color =
          (s.colorName?.isNotEmpty ?? false) ? s.colorName : (s.colorHex ?? '');
      buf
        ..writeln('${i + 1}. ${s.manufacturer} / ${s.materialType} / $color')
        ..writeln(
          '   当前剩余 ${GramUtils.formatGrams(s.currentRemainingGrams)}，建议采购 ${GramUtils.formatGrams(s.suggestedPurchaseGrams)}（${s.suggestedRolls} 卷）',
        )
        ..writeln(
          '   预计成本：${s.estimatedCost != null ? '¥${s.estimatedCost!.toStringAsFixed(2)}' : '未配置单价'}',
        );
    }

    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    _showSnack('采购清单已复制到剪贴板');
  }

  void _showSnack(String msg) {
    showSnack(context, msg, duration: const Duration(seconds: 2));
  }
}

class _RestockWorkspace extends StatelessWidget {
  const _RestockWorkspace({
    required this.alerts,
    required this.suggestions,
    required this.selectedKeys,
    required this.selectedItems,
    required this.totalCost,
    required this.onToggle,
    required this.onSelectAll,
    required this.onClearAll,
    required this.onExport,
  });

  final List<StockAlertItem> alerts;
  final List<PurchaseSuggestion> suggestions;
  final Set<String> selectedKeys;
  final List<PurchaseSuggestion> selectedItems;
  final double totalCost;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAll;
  final VoidCallback onClearAll;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final purchasableKeys = suggestions.map((item) => item.key).toSet();
        final alertsStage = _AlertListCard(
          alerts: alerts,
          selectedKeys: selectedKeys,
          purchasableKeys: purchasableKeys,
          onToggle: onToggle,
        );
        final basketStage = _PurchaseListCard(
          suggestions: suggestions,
          selectedKeys: selectedKeys,
          selectedCount: selectedItems.length,
          totalCost: totalCost,
          onToggle: onToggle,
          onSelectAll: onSelectAll,
          onClearAll: onClearAll,
          onExport: onExport,
        );

        if (constraints.maxWidth < 900) {
          return ListView(
            children: [
              SizedBox(
                height: constraints.maxHeight.clamp(380.0, 520.0),
                child: alertsStage,
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(height: 500, child: basketStage),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 11, child: alertsStage),
            const SizedBox(width: AppSpacing.md),
            Expanded(flex: 9, child: basketStage),
          ],
        );
      },
    );
  }
}

/// 顶部 3 格统计卡片。
class _SummaryCard extends StatelessWidget {
  final int criticalCount;
  final int lowCount;
  final double totalPurchaseCost;

  const _SummaryCard({
    required this.criticalCount,
    required this.lowCount,
    required this.totalPurchaseCost,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      decoration: BoxDecoration(
        border: Border.symmetric(
          horizontal: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.notifications_active_rounded,
                size: 16,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                '库存预警概览',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _StatBox(
                  label: '严重不足',
                  value: criticalCount.toString(),
                  unit: '项',
                  icon: Icons.error_outline_rounded,
                  color: AppColors.danger,
                  highlight: criticalCount > 0,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatBox(
                  label: '低库存',
                  value: lowCount.toString(),
                  unit: '项',
                  icon: Icons.warning_amber_rounded,
                  color: AppColors.warning,
                  highlight: lowCount > 0,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatBox(
                  label: '预计采购成本',
                  value: totalPurchaseCost.toStringAsFixed(2),
                  unit: '元',
                  icon: Icons.shopping_cart_outlined,
                  color: AppColors.primary,
                  highlight: totalPurchaseCost > 0,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 单个统计块。
class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final IconData icon;
  final Color color;
  final bool highlight;

  const _StatBox({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 15, color: color),
          ),
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
                    Flexible(
                      child: Text(
                        value,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
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
      ),
    );
  }
}

/// 库存预警列表卡片。
class _AlertListCard extends StatelessWidget {
  final List<StockAlertItem> alerts;
  final Set<String> selectedKeys;
  final Set<String> purchasableKeys;
  final ValueChanged<String> onToggle;

  const _AlertListCard({
    required this.alerts,
    required this.selectedKeys,
    required this.purchasableKeys,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    return OpenStage(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                const Expanded(
                  child: ExperienceSectionHeading(
                    title: '库存水位',
                    color: AppColors.warning,
                  ),
                ),
                Text(
                  '共 ${alerts.length} 个规格',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.md),
              itemCount: alerts.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, index) {
                final item = alerts[index];
                final purchasable = purchasableKeys.contains(item.key);
                return _AlertItem(
                  item: item,
                  selected: selectedKeys.contains(item.key),
                  onToggle: purchasable ? () => onToggle(item.key) : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个预警项。
class _AlertItem extends StatelessWidget {
  final StockAlertItem item;
  final bool selected;
  final VoidCallback? onToggle;

  const _AlertItem({
    required this.item,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (levelColor, levelLabel, levelBg) = _levelStyle(item.level);

    // 进度条：剩余克数占月均消耗的比例（直观显示库存压力）
    // 比例 = remaining / max(monthly, 1)，上限 1.0
    final ratio = item.monthlyConsumptionGrams > 0
        ? (item.totalRemainingGrams / item.monthlyConsumptionGrams)
            .clamp(0.0, 1.0)
        : 1.0;

    // 主标题：厂商 + 材质 + 颜色名
    final colorLabel = (item.colorName?.isNotEmpty ?? false)
        ? item.colorName!
        : (item.colorHex ?? '无色');

    final content = AnimatedContainer(
      duration: ExperienceTokens.hoverDuration,
      curve: ExperienceTokens.motionCurve,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.primary.withValues(alpha: isDark ? 0.10 : 0.06)
            : isDark
                ? AppColors.surfaceVariantDark.withValues(alpha: 0.4)
                : AppColors.surfaceVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        border: Border.all(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.50)
              : levelColor.withValues(
                  alpha: item.level == StockLevel.healthy ? 0.1 : 0.3,
                ),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧色块
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: item.colorHex != null
                  ? ColorUtils.fromHex(item.colorHex!)
                  : AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isDark ? AppColors.dividerDark : AppColors.divider,
                width: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 中间信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${item.manufacturer} · ${item.materialType} · $colorLabel',
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
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: levelBg,
                        borderRadius:
                            BorderRadius.circular(AppColors.radiusFull),
                      ),
                      child: Text(
                        levelLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: levelColor,
                        ),
                      ),
                    ),
                    if (onToggle != null) ...[
                      const SizedBox(width: 6),
                      Icon(
                        selected
                            ? Icons.shopping_basket_rounded
                            : Icons.add_shopping_cart_rounded,
                        size: 16,
                        color: selected
                            ? AppColors.primary
                            : AppColors.textTertiary,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                // 副信息
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    _MetaChip(
                      label:
                          '剩余 ${GramUtils.formatGrams(item.totalRemainingGrams)} · ${item.rollCount}卷',
                      isDark: isDark,
                    ),
                    _MetaChip(
                      label:
                          '月均消耗 ${GramUtils.formatGrams(item.monthlyConsumptionGrams)}',
                      isDark: isDark,
                    ),
                    _MetaChip(
                      label: item.estimatedDaysLeft < 0
                          ? '预计剩余：无消耗记录'
                          : '预计剩余 ${item.estimatedDaysLeft} 天',
                      isDark: isDark,
                    ),
                    if (item.lowRollCount > 0)
                      _MetaChip(
                        label: '${item.lowRollCount}卷低库存',
                        isDark: isDark,
                        color: AppColors.warning,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                // 进度条
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppColors.radiusFull),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 6,
                    backgroundColor: isDark
                        ? AppColors.surfaceContainerHighDark
                        : AppColors.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(levelColor),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (onToggle == null) return content;
    return Tooltip(
      message: selected ? '从采购篮移出' : '加入采购篮',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: ValueKey('restock-alert-basket-${item.key}'),
          behavior: HitTestBehavior.opaque,
          onTap: onToggle,
          child: content,
        ),
      ),
    );
  }

  /// 等级配色（颜色 / 标签 / 背景色）。
  (Color, String, Color) _levelStyle(StockLevel level) {
    switch (level) {
      case StockLevel.critical:
        return (
          AppColors.danger,
          '严重不足',
          AppColors.dangerContainer.withValues(alpha: 0.7),
        );
      case StockLevel.low:
        return (
          AppColors.warning,
          '低库存',
          AppColors.warningContainer.withValues(alpha: 0.7),
        );
      case StockLevel.healthy:
        return (
          AppColors.success,
          '充足',
          AppColors.successContainer.withValues(alpha: 0.7),
        );
    }
  }
}

/// 副信息小标签。
class _MetaChip extends StatelessWidget {
  final String label;
  final bool isDark;
  final Color? color;

  const _MetaChip({required this.label, required this.isDark, this.color});

  @override
  Widget build(BuildContext context) {
    final fg =
        color ?? (isDark ? AppColors.textTertiaryDark : AppColors.textTertiary);
    return Text(
      label,
      style: TextStyle(fontSize: 11, color: fg, height: 1.3),
    );
  }
}

/// 采购清单卡片。
class _PurchaseListCard extends StatelessWidget {
  final List<PurchaseSuggestion> suggestions;
  final Set<String> selectedKeys;
  final int selectedCount;
  final double totalCost;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAll;
  final VoidCallback onClearAll;
  final VoidCallback onExport;

  const _PurchaseListCard({
    required this.suggestions,
    required this.selectedKeys,
    required this.selectedCount,
    required this.totalCost,
    required this.onToggle,
    required this.onSelectAll,
    required this.onClearAll,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OpenStage(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              8,
              AppSpacing.sm,
              8,
            ),
            child: Row(
              children: [
                const Expanded(
                  child: ExperienceSectionHeading(title: '采购篮'),
                ),
                TextButton(
                  onPressed: onSelectAll,
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: onClearAll,
                  child: const Text('清空'),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: suggestions.isEmpty
                ? const EmptyState(
                    icon: Icons.shopping_basket_outlined,
                    title: '暂时不用补给',
                    subtitle: '库存建议会自动出现在这里。',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: suggestions.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      final suggestion = suggestions[index];
                      return _PurchaseItem(
                        suggestion: suggestion,
                        selected: selectedKeys.contains(suggestion.key),
                        onToggle: () => onToggle(suggestion.key),
                      );
                    },
                  ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          _ActionBar(
            selectedCount: selectedCount,
            totalCost: totalCost,
            onExport: onExport,
          ),
        ],
      ),
    );
  }
}

/// 单个采购建议项。
class _PurchaseItem extends StatelessWidget {
  final PurchaseSuggestion suggestion;
  final bool selected;
  final VoidCallback onToggle;

  const _PurchaseItem({
    required this.suggestion,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final levelColor = _levelColor(suggestion.level);

    final colorLabel = (suggestion.colorName?.isNotEmpty ?? false)
        ? suggestion.colorName!
        : (suggestion.colorHex ?? '无色');

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onToggle,
        child: AnimatedContainer(
          duration: ExperienceTokens.hoverDuration,
          curve: ExperienceTokens.motionCurve,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary.withValues(alpha: isDark ? 0.10 : 0.06)
                : (isDark
                    ? AppColors.surfaceVariantDark.withValues(alpha: 0.4)
                    : AppColors.surfaceVariant.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            border: Border.all(
              color: selected
                  ? AppColors.primary.withValues(alpha: 0.5)
                  : (isDark ? AppColors.dividerDark : AppColors.divider),
              width: 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 复选框
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected
                      ? AppColors.primary
                      : (isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary),
                ),
              ),
              const SizedBox(width: 10),
              // 左侧色块
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: suggestion.colorHex != null
                      ? ColorUtils.fromHex(suggestion.colorHex!)
                      : AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: isDark ? AppColors.dividerDark : AppColors.divider,
                    width: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // 中间信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${suggestion.manufacturer} · ${suggestion.materialType} · $colorLabel',
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
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: levelColor.withValues(alpha: 0.15),
                            borderRadius:
                                BorderRadius.circular(AppColors.radiusFull),
                          ),
                          child: Text(
                            suggestion.level == StockLevel.critical
                                ? '严重'
                                : '低库存',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: levelColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // 采购量信息
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        _MetaChip(
                          label:
                              '当前 ${GramUtils.formatGrams(suggestion.currentRemainingGrams)}',
                          isDark: isDark,
                        ),
                        _MetaChip(
                          label:
                              '→ 采购 ${GramUtils.formatGrams(suggestion.suggestedPurchaseGrams)}（${suggestion.suggestedRolls} 卷）',
                          isDark: isDark,
                          color: AppColors.primary,
                        ),
                        _MetaChip(
                          label: suggestion.estimatedDaysLeft < 0
                              ? '暂无消耗历史'
                              : '预计 ${suggestion.estimatedDaysLeft} 天耗尽',
                          isDark: isDark,
                          color: suggestion.estimatedDaysLeft >= 0 &&
                                  suggestion.estimatedDaysLeft <= 3
                              ? AppColors.danger
                              : null,
                        ),
                        if (suggestion.monthlyConsumptionGrams > 0)
                          _MetaChip(
                            label:
                                '日均 ${(suggestion.monthlyConsumptionGrams / 30).toStringAsFixed(1)} g',
                            isDark: isDark,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              // 右侧成本
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    suggestion.estimatedCost != null
                        ? '¥${suggestion.estimatedCost!.toStringAsFixed(2)}'
                        : '未配置',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: suggestion.estimatedCost != null
                          ? AppColors.primary
                          : (isDark
                              ? AppColors.textTertiaryDark
                              : AppColors.textTertiary),
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                  if (suggestion.estimatedCost != null)
                    Text(
                      '估算成本',
                      style: TextStyle(
                        fontSize: 9,
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
      ),
    );
  }

  Color _levelColor(StockLevel level) {
    switch (level) {
      case StockLevel.critical:
        return AppColors.danger;
      case StockLevel.low:
        return AppColors.warning;
      case StockLevel.healthy:
        return AppColors.success;
    }
  }
}

/// 底部操作栏。
class _ActionBar extends StatelessWidget {
  final int selectedCount;
  final double totalCost;
  final VoidCallback onExport;

  const _ActionBar({
    required this.selectedCount,
    required this.totalCost,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            Icons.shopping_basket_outlined,
            size: 18,
            color: AppColors.primary,
          ),
          const SizedBox(width: 8),
          Text(
            '已选 $selectedCount 项',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
            ),
          ),
          const SizedBox(width: 16),
          Text(
            '预计 ',
            style: TextStyle(
              fontSize: 12,
              color:
                  isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
            ),
          ),
          Text(
            '¥${totalCost.toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
          const Spacer(),
          AppButton(
            label: '导出采购清单',
            icon: const Icon(Icons.copy_rounded, size: 16),
            onPressed: selectedCount > 0 ? onExport : null,
          ),
        ],
      ),
    );
  }
}
