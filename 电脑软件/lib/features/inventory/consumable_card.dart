import 'dart:ui' as ui;

import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/personal_desktop_theme.dart';
import '../../core/utils/brand_logo_utils.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/gram_utils.dart';
import '../../data/database/database.dart';
import '../../data/database/daos/consumable_dao.dart';
import '../../providers/database_provider.dart';
import '../../providers/consumable_provider.dart';
import '../../providers/personal_inventory_action_guard.dart';
import '../../providers/filament_cost_provider.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/experience_ui.dart';
import '../../widgets/filament_model_badge.dart';
import '../../widgets/filament_spool_icon.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/icon_action_button.dart';
import '../../widgets/stock_bar.dart';
import 'rfid_spool_replacement_dialog.dart';

Future<void> _changeInventoryRoll(
  BuildContext context,
  WidgetRef ref,
  Consumable item, {
  required bool add,
}) async {
  final account = PersonalInventoryActionGuard.fromRef(ref);
  final dao = account.dao;
  try {
    await account.checkAccess(item.id);
    if (add) {
      final binding = await dao.getRfidSpoolBindingById(item.id);
      account.assertCurrent();
      if (!context.mounted) return;
      if (binding?.tagUid.isNotEmpty == true) {
        await showRfidSpoolReplacementDialog(context, dao, item);
        return;
      }
    }
    final changed = await account.run(
      item.id,
      () => add ? dao.addOneRoll(item.id) : dao.deductOneRoll(item.id),
    );
    if (!context.mounted) return;
    if (changed <= 0) {
      showSnack(context, '已无库存可减少', error: true);
      return;
    }
    RollSnackCounter.instance.add(
      add ? 1 : -1,
      '${item.manufacturer} ${item.colorName ?? ''}'.trim(),
    );
  } catch (error) {
    if (context.mounted) showSnack(context, '$error', error: true);
  }
}

/// 耗材卡片。商标图作为低透明度背景 + 耗材颜色名称/类型/入库时间 + 卷数加减。
///
/// **具体卷**（CUID/FUID 绑定卷或由资料卡入库的独立卷）：始终按克数管理，
/// 不显示聚合库存的整卷加减按钮。实际余量小于初始容量时显示「未用完」。
class ConsumableCard extends ConsumerWidget {
  final Consumable item;
  final VoidCallback? onEdit;

  const ConsumableCard({super.key, required this.item, this.onEdit});

  /// 实际余量小于这条库存的初始容量时才是余料。
  bool get _isPartial =>
      GramUtils.isPartiallyUsed(item.remainingGrams, item.totalGrams);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final individual = ref
        .watch(personalIndividualSpoolIdsProvider)
        .contains(item.id);
    final rolls = inventoryRollCount(
      item.remainingGrams,
      individualSpool: individual,
    );
    final color = ColorUtils.fromHex(item.colorHex);
    final logoAsset = BrandLogoUtils.resolveAsset(item.manufacturer);
    final colorName = item.colorName?.isNotEmpty == true
        ? item.colorName!
        : item.colorHex;
    final isPartial = individual
        ? GramUtils.isPartiallyUsed(item.remainingGrams, item.totalGrams)
        : _isPartial;
    final usesGramControls = individual || isPartial;

    return GlassCard(
      level: GlassLevel.l2,
      padding: EdgeInsets.zero,
      onTap: onEdit,
      child: Stack(
        children: [
          // 商标背景图（低透明度）。找不到商标则不渲染背景图，用纯色渐变兜底。
          Positioned.fill(
            child: logoAsset != null
                ? Opacity(
                    opacity: 0.10,
                    child: Image.asset(
                      logoAsset,
                      cacheWidth: 320,
                      fit: BoxFit.contain,
                      alignment: Alignment.center,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  )
                : DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          color.withValues(alpha: 0.08),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
          ),
          // 前景内容
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部行：厂商名（无商标时显文字标识）+ 右上角菜单
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 商标小图标（有则显示，无则显示厂商首字）
                    if (logoAsset != null)
                      Image.asset(
                        logoAsset,
                        width: 20,
                        height: 20,
                        cacheWidth: 48,
                        cacheHeight: 48,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      )
                    else
                      Container(
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          item.manufacturer.isNotEmpty
                              ? item.manufacturer.substring(0, 1)
                              : '?',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        item.manufacturer,
                        style: TextStyle(
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _RfidBindingBadge(consumableId: item.id),
                    _PopupMenu(item: item, rolls: rolls),
                  ],
                ),
                const SizedBox(height: 10),
                // 耗材颜色名称（大字）+ 色块 + 未用完提示
                Row(
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isDark
                              ? AppColors.outlineDark
                              : AppColors.outline,
                          width: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        colorName,
                        style: TextStyle(
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // 未用完红色提示标签
                    if (isPartial)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.danger.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: AppColors.danger.withValues(alpha: 0.3),
                            width: 0.5,
                          ),
                        ),
                        child: const Text(
                          '未用完',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: AppColors.danger,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                // 耗材类型 + 单价提示
                Row(
                  children: [
                    BambuIcon(
                      name: 'filament',
                      size: 12,
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary,
                      applyColorFilter: true,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FilamentModelBadge(
                          manufacturer: item.manufacturer,
                          model: item.model,
                          materialType: item.materialType,
                          compact: true,
                        ),
                      ),
                    ),
                    // 单价提示（异步查成本配置）
                    _PriceTag(item: item),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                // 入库时间
                Row(
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 11,
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      _formatDate(item.createdAt),
                      style: TextStyle(
                        color: isDark
                            ? AppColors.textTertiaryDark
                            : AppColors.textTertiary,
                        fontSize: 11,
                        fontFamily: AppTypography.monoFontFamily,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                // 剩余克数文本
                Text(
                  isPartial
                      ? '${GramUtils.formatGrams(item.remainingGrams)} / ${GramUtils.formatGrams(item.totalGrams)}'
                      : GramUtils.formatRatio(
                          item.remainingGrams,
                          item.totalGrams,
                        ),
                  style: TextStyle(
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    fontFamily: AppTypography.monoFontFamily,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                // 具体卷与旧余料记录只显示克数，不提供聚合库存的整卷加减按钮。
                if (usesGramControls)
                  Center(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          GramUtils.formatGrams(item.remainingGrams),
                          style: TextStyle(
                            color: item.remainingGrams > 0
                                ? (isDark
                                      ? AppColors.textPrimaryDark
                                      : AppColors.textPrimary)
                                : (isDark
                                      ? AppColors.textTertiaryDark
                                      : AppColors.textTertiary),
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                            fontFeatures: const [
                              ui.FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          'g',
                          style: TextStyle(
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  // 正常卷：显示加减号 + 卷数
                  Row(
                    children: [
                      _RollButton(
                        icon: Icons.remove_rounded,
                        onTap: rolls <= 0 ? null : () => _deduct(context, ref),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '$rolls',
                              style: TextStyle(
                                color: rolls > 0
                                    ? (isDark
                                          ? AppColors.textPrimaryDark
                                          : AppColors.textPrimary)
                                    : (isDark
                                          ? AppColors.textTertiaryDark
                                          : AppColors.textTertiary),
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                fontFeatures: const [
                                  ui.FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Text(
                              '卷',
                              style: TextStyle(
                                color: isDark
                                    ? AppColors.textSecondaryDark
                                    : AppColors.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      _RollButton(
                        icon: Icons.add_rounded,
                        onTap: () => _add(context, ref),
                      ),
                    ],
                  ),
                const SizedBox(height: AppSpacing.sm),
                // 剩余克数进度紧跟卷数操作区，避免与上方信息割裂。
                StockBar(
                  remaining: item.remainingGrams,
                  total: item.totalGrams,
                  height: 6,
                  enableGradient: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deduct(BuildContext context, WidgetRef ref) async {
    await _changeInventoryRoll(context, ref, item, add: false);
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    await _changeInventoryRoll(context, ref, item, add: true);
  }

  String _formatDate(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

/// Shows the reusable CUID/FUID cycle without treating it as the spool's
/// unique inventory id. It is intentionally lazy so the existing card grid
/// remains fast for untagged desktop inventory.
class _RfidBindingBadge extends ConsumerWidget {
  const _RfidBindingBadge({required this.consumableId});

  final int consumableId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final binding = ref
        .watch(personalRfidSpoolBindingsProvider)
        .valueOrNull?[consumableId];
    if (binding == null || binding.tagUid.isEmpty) {
      return const SizedBox.shrink();
    }
    final status = binding.status == 'active' ? '使用中' : '历史卷';
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Tooltip(
        message: 'CUID/FUID · 第 ${binding.cycle} 卷 · $status',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.nfc_rounded, size: 14, color: AppColors.primary),
            const SizedBox(width: 2),
            Text(
              'C${binding.cycle}',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单价提示标签。监听成本配置变更流，匹配到显示单价，未匹配显示红色「单价未知」。
/// 改为 ConsumerWidget + ref.watch，单价保存后立即刷新。
class _PriceTag extends ConsumerWidget {
  final Consumable item;

  const _PriceTag({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configsAsync = ref.watch(filamentCostConfigsProvider);
    return configsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (configs) {
        // 从流中匹配单价（与 matchCost 同逻辑：精确→退化→兜底）
        final vendor = item.manufacturer;
        final material = item.materialType;
        final color = item.colorHex;
        double? costPerKg;
        // 1. 精确匹配 vendor+material+color
        for (final c in configs) {
          if (c.vendor == vendor &&
              c.materialType == material &&
              c.colorHex == color) {
            costPerKg = c.costPerKg;
            break;
          }
        }
        // 2. 退化匹配 vendor+material（color 为空串的配置）
        costPerKg ??= configs
            .where(
              (c) =>
                  c.vendor == vendor &&
                  c.materialType == material &&
                  c.colorHex.isEmpty,
            )
            .firstOrNull
            ?.costPerKg;
        // 3. 兜底：仅 materialType
        costPerKg ??= configs
            .where(
              (c) =>
                  c.vendor.isEmpty &&
                  c.materialType == material &&
                  c.colorHex.isEmpty,
            )
            .firstOrNull
            ?.costPerKg;

        if (costPerKg != null && costPerKg > 0) {
          return Text(
            '¥${costPerKg.toStringAsFixed(0)}/kg',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppColors.success,
              fontFeatures: [ui.FontFeature.tabularFigures()],
            ),
          );
        }
        // 未配置单价：红色提示
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: AppColors.danger.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(3),
          ),
          child: const Text(
            '单价未知',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: AppColors.danger,
            ),
          ),
        );
      },
    );
  }
}

/// 加减号圆形按钮。
class _RollButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _RollButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = onTap != null;
    if (GlassButtonsTheme.enabledOf(context)) {
      return SizedBox.square(
        dimension: 30,
        child: AppGlassButton(
          tooltip: icon == Icons.add_rounded || icon == Icons.add
              ? '增加卷数'
              : '减少卷数',
          onPressed: onTap,
          variant: AppGlassButtonVariant.secondary,
          compact: true,
          minimumSize: const Size.square(30),
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(20),
          child: Icon(icon, size: 18),
        ),
      );
    }
    return Material(
      color: enabled
          ? AppColors.primaryContainer
          : (isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? AppColors.primary
                : (isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary),
          ),
        ),
      ),
    );
  }
}

/// 右上角删除按钮：浅红底圆形 + 红色删除图标。
class _PopupMenu extends ConsumerWidget {
  final Consumable item;
  final int rolls;

  const _PopupMenu({required this.item, required this.rolls});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DeleteActionButton(onTap: () => _confirmDelete(context, ref));
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final dao = ref.read(consumableDaoProvider);
    final account = PersonalInventoryActionGuard.fromRef(ref);
    final binding = await dao.getRfidSpoolBindingById(item.id);
    if (!context.mounted) return;
    final tagged = binding?.tagUid.isNotEmpty == true;
    final ok = await AppDialog.confirm(
      context,
      tagged ? '归档耗材卷' : '删除耗材',
      tagged
          ? '这卷耗材带有可复用 RFID 标签。归档会保留周期、前驱卷和消耗历史，之后仍可在标签轨迹中查询。'
          : '确认删除「${item.manufacturer} ${item.colorName ?? ''}」？此操作不可撤销。',
      confirmText: tagged ? '归档' : '删除',
      destructive: true,
    );
    if (ok) {
      try {
        await account.run(item.id, () async {
          if (tagged) {
            await dao.retirePersonalRfidSpool(item.id);
          } else {
            await dao.deleteConsumable(item.id);
          }
        });
      } catch (error) {
        if (context.mounted) {
          showSnack(context, '$error', error: true);
        }
        return;
      }
      if (context.mounted) {
        showSnack(
          context,
          tagged
              ? '已归档「${item.manufacturer} ${item.colorName ?? ''}」，生命周期历史已保留'
              : '已删除「${item.manufacturer} ${item.colorName ?? ''}」',
        );
      }
    }
  }
}

/// Spool-first inventory object used by the material-wall presentation.
///
/// The original [ConsumableCard] remains available for compact legacy surfaces;
/// this variant gives the real material color and remaining quantity visual
/// priority while preserving edit and delete operations. Aggregate inventory
/// keeps +/- controls, while every concrete spool is managed in grams.
class MaterialShelfCard extends ConsumerWidget {
  const MaterialShelfCard({
    super.key,
    required this.item,
    this.onEdit,
    this.onDetails,
    this.selectionMode = false,
    this.selected = false,
    this.selectionRequiredGrams,
    this.selectionDisplayGrams,
    this.recommended = false,
    this.showFineDetail = false,
  });

  final Consumable item;
  final VoidCallback? onEdit;
  final VoidCallback? onDetails;
  final bool selectionMode;
  final bool selected;
  final double? selectionRequiredGrams;
  final double? selectionDisplayGrams;
  final bool recommended;
  final bool showFineDetail;

  /// 实际余量小于这条库存的初始容量时才是余料。
  bool get _isPartial =>
      GramUtils.isPartiallyUsed(item.remainingGrams, item.totalGrams);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final personal = PersonalDesktopTheme.of(context);
    final color = ColorUtils.fromHex(item.colorHex);
    final colorName = item.colorName?.trim().isNotEmpty == true
        ? item.colorName!.trim()
        : item.colorHex;
    final logo = BrandLogoUtils.resolveAsset(item.manufacturer);
    final individual = ref
        .watch(personalIndividualSpoolIdsProvider)
        .contains(item.id);
    final rolls = inventoryRollCount(
      item.remainingGrams,
      individualSpool: individual,
    );
    final isPartial = individual
        ? GramUtils.isPartiallyUsed(item.remainingGrams, item.totalGrams)
        : _isPartial;
    final usesGramControls = individual || isPartial;
    final displayGrams = selectionMode && selectionDisplayGrams != null
        ? selectionDisplayGrams!
              .clamp(0.0, individual ? item.remainingGrams : gramsPerRoll)
              .toDouble()
        : item.remainingGrams;

    return Semantics(
      button: onEdit != null,
      selected: selectionMode ? selected : null,
      label:
          '${item.manufacturer} $colorName ${item.materialType} '
          '${GramUtils.formatGrams(displayGrams)}',
      child: TactileLift(
        onTap: onEdit,
        maxTilt: 0.014,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 54,
              bottom: 0,
              child: DecoratedBox(
                key: ValueKey('material-shelf-surface-${item.id}'),
                decoration: BoxDecoration(
                  color: personal != null
                      ? personalDesktopGlassFill(
                          Theme.of(context),
                          opacity: personal.cardOpacity,
                        )
                      : dark
                      ? scheme.surface.withValues(alpha: 0.92)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(
                    ExperienceTokens.objectRadius,
                  ),
                  border: Border.all(
                    color: selected
                        ? AppColors.primary
                        : personal != null
                        ? personalDesktopGlassRim(Theme.of(context))
                        : color.withValues(alpha: dark ? 0.28 : 0.18),
                    width: selected ? 2 : 1,
                  ),
                  boxShadow: personal != null && !selected
                      ? (dark ? AppColors.shadow1Dark : AppColors.shadowCard)
                      : [
                          BoxShadow(
                            color: (selected ? AppColors.primary : color)
                                .withValues(
                                  alpha: selected ? 0.16 : (dark ? 0.1 : 0.07),
                                ),
                            blurRadius: selected ? 26 : 22,
                            offset: const Offset(0, 12),
                          ),
                        ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    ExperienceTokens.objectRadius,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (logo != null)
                        Positioned.fill(
                          key: ValueKey(
                            'material-shelf-brand-watermark-${item.id}',
                          ),
                          child: Opacity(
                            opacity: personal != null
                                ? (dark ? 0.07 : 0.045)
                                : (dark ? 0.14 : 0.11),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Image.asset(
                                logo,
                                cacheWidth: 240,
                                fit: BoxFit.contain,
                                alignment: Alignment.center,
                                errorBuilder: (_, __, ___) =>
                                    const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        )
                      else
                        DecoratedBox(
                          key: ValueKey(
                            'material-shelf-brand-fallback-${item.id}',
                          ),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                color.withValues(alpha: dark ? 0.08 : 0.05),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 1,
              top: 0,
              width: 98,
              height: 112,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      color.withValues(alpha: dark ? 0.14 : 0.10),
                      color.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 14,
              top: 2,
              child: Hero(
                key: ValueKey('material-shelf-spool-${item.id}'),
                tag: 'material-spool-${item.id}',
                child: FilamentSpoolIcon(color: color, size: 68),
              ),
            ),
            Positioned(
              left: 96,
              right: 46,
              top: 62,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    colorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 2),
                  FilamentModelBadge(
                    manufacturer: item.manufacturer,
                    model: item.model,
                    materialType: item.materialType,
                    compact: true,
                  ),
                ],
              ),
            ),
            Positioned(
              right: 10,
              top: 59,
              child: selectionMode
                  ? _ShelfSelectionBadge(
                      selected: selected,
                      recommended: recommended,
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _RfidBindingBadge(consumableId: item.id),
                        if (onDetails != null)
                          IconButton(
                            tooltip: '生命周期',
                            visualDensity: VisualDensity.compact,
                            iconSize: 18,
                            onPressed: onDetails,
                            icon: const Icon(Icons.timeline_rounded),
                          ),
                        _PopupMenu(item: item, rolls: rolls),
                      ],
                    ),
            ),
            if (isPartial)
              const Positioned(
                left: 14,
                top: 98,
                child: Text(
                  '余卷',
                  style: TextStyle(
                    color: AppColors.warning,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 112, 14, 13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.manufacturer,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      _PriceTag(item: item),
                    ],
                  ),
                  if (showFineDetail &&
                      ((item.batchNo?.trim().isNotEmpty ?? false) ||
                          (item.note?.trim().isNotEmpty ?? false))) ...[
                    const SizedBox(height: 5),
                    Text(
                      [
                        if (item.batchNo?.trim().isNotEmpty == true)
                          '批次 ${item.batchNo!.trim()}',
                        if (item.note?.trim().isNotEmpty == true)
                          item.note!.trim(),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 9,
                      ),
                    ),
                  ],
                  const Spacer(),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          GramUtils.formatGrams(displayGrams),
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 17,
                            fontWeight: personal != null
                                ? FontWeight.w600
                                : FontWeight.w800,
                            fontFeatures: const [
                              ui.FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                      Text(
                        _formatShelfDate(item.createdAt),
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 9,
                          fontFamily: AppTypography.monoFontFamily,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  if (selectionMode)
                    _ShelfSelectionStatus(
                      selected: selected,
                      requiredGrams: selectionRequiredGrams,
                      remainingGrams: displayGrams,
                    )
                  else if (!usesGramControls)
                    Row(
                      children: [
                        _RollButton(
                          icon: Icons.remove_rounded,
                          onTap: rolls <= 0
                              ? null
                              : () => _deductShelf(context, ref),
                        ),
                        Expanded(
                          child: Text(
                            '$rolls 卷',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                ui.FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        _RollButton(
                          icon: Icons.add_rounded,
                          onTap: () => _addShelf(context, ref),
                        ),
                      ],
                    )
                  else
                    SizedBox(
                      height: 30,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          isPartial ? '按克数管理此余卷' : '按克数管理此具体卷',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 7),
                  StockBar(
                    remaining: displayGrams,
                    total: selectionMode && selectionDisplayGrams != null
                        ? individual
                              ? item.totalGrams
                              : gramsPerRoll
                        : item.totalGrams,
                    height: 5,
                    enableGradient: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deductShelf(BuildContext context, WidgetRef ref) async {
    await _changeInventoryRoll(context, ref, item, add: false);
  }

  Future<void> _addShelf(BuildContext context, WidgetRef ref) async {
    await _changeInventoryRoll(context, ref, item, add: true);
  }

  String _formatShelfDate(DateTime value) {
    return '${value.month.toString().padLeft(2, '0')}/'
        '${value.day.toString().padLeft(2, '0')}';
  }
}

class _ShelfSelectionBadge extends StatelessWidget {
  const _ShelfSelectionBadge({
    required this.selected,
    required this.recommended,
  });

  final bool selected;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    if (!selected && !recommended) {
      return Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.chevron_right_rounded, size: 18),
      );
    }
    final color = selected ? AppColors.primary : AppColors.success;
    return Container(
      height: 28,
      padding: EdgeInsets.symmetric(horizontal: selected ? 7 : 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            selected ? Icons.check_rounded : Icons.auto_awesome_rounded,
            size: 14,
            color: color,
          ),
          if (!selected) ...[
            const SizedBox(width: 4),
            Text(
              '推荐',
              style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ShelfSelectionStatus extends StatelessWidget {
  const _ShelfSelectionStatus({
    required this.selected,
    required this.requiredGrams,
    required this.remainingGrams,
  });

  final bool selected;
  final double? requiredGrams;
  final double remainingGrams;

  @override
  Widget build(BuildContext context) {
    final required = requiredGrams;
    if (required == null) {
      final color = selected ? AppColors.primary : AppColors.success;
      return Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: color.withValues(alpha: 0.24)),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.check_circle_outline_rounded
                  : Icons.link_rounded,
              size: 15,
              color: color,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                selected ? '已选 · 将绑定此卷' : '可绑定到当前料位',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final shortage = required - remainingGrams;
    final insufficient = shortage > 0.01;
    final color = insufficient
        ? AppColors.warning
        : selected
        ? AppColors.primary
        : AppColors.success;
    final label = insufficient
        ? '还差 ${GramUtils.formatGrams(shortage)}'
        : selected
        ? '已选 · 方案需 ${GramUtils.formatGrams(required)}'
        : '可用 · 方案需 ${GramUtils.formatGrams(required)}';
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(
            insufficient
                ? Icons.warning_amber_rounded
                : selected
                ? Icons.check_circle_outline_rounded
                : Icons.inventory_2_outlined,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
