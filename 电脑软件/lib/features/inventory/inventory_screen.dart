import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../core/theme/glass_button_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/gram_utils.dart';
import '../../core/utils/friendly_error.dart';
import '../../data/database/database.dart';
import '../../data/database/personal_inventory_balance_sync.dart';
import '../../data/models/rfid_tag_identity.dart';
import '../../data/external/community/community_api_client.dart';
import '../../data/database/daos/consumable_dao.dart' show inventoryRollCount;
import '../../providers/consumable_provider.dart';
import '../../providers/personal_inventory_action_guard.dart';
import '../../providers/stock_alert_provider.dart';
import '../../data/prefs/app_prefs.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_input.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';
import '../../widgets/glass_card.dart';
import '../restock/restock_screen.dart';
import 'add_consumable_sheet.dart';
import 'consumable_card.dart';
import 'rfid_spool_replacement_dialog.dart';
import '../../widgets/rfid_spool_history.dart';
import '../../providers/database_provider.dart';
import '../../providers/app_auth_provider.dart';
import '../../core/services/personal_inventory_sync_service.dart';
import '../../widgets/rfid_spool_rebind_dialog.dart';
import '../../data/database/models/consumable_twin_event.dart';
import '../rfid/desktop_rfid_workbench.dart';
import '../../widgets/app_glass_button.dart';

/// 库存页。Gemini 风格：浅色背景 + 按品牌分区 + 一行 3 列卡片网格。
///
/// 列表数据由 [consumablesProvider] 按当前 sohun 账号作用域提供。
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(consumablesProvider);
    return _InventoryBody(async: async);
  }
}

/// 持有搜索状态的内部 Stateful 组件。
class _InventoryBody extends ConsumerStatefulWidget {
  final AsyncValue<List<Consumable>> async;

  const _InventoryBody({required this.async});

  @override
  ConsumerState<_InventoryBody> createState() => _InventoryBodyState();
}

class _InventoryBodyState extends ConsumerState<_InventoryBody> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // 按搜索词过滤：厂商 / 型号 / 材质 / 颜色名 / HEX / 备注
  List<Consumable> _applySearch(List<Consumable> items) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return items;
    return items.where((c) {
      final haystack =
          '${c.manufacturer} ${c.model} ${c.materialType} ${c.colorName ?? ''} ${c.colorHex} ${c.note ?? ''}'
              .toLowerCase();
      return haystack.contains(q);
    }).toList();
  }

  // 按品牌分组，保持品牌字母排序
  Map<String, List<Consumable>> _groupByBrand(List<Consumable> items) {
    final groups = <String, List<Consumable>>{};
    for (final c in items) {
      groups.putIfAbsent(c.manufacturer, () => []).add(c);
    }
    // 品牌按字母排序
    final sortedKeys = groups.keys.toList()..sort();
    // 每组内排序：任意规格的满卷在前，实际使用过的余料卷在后。
    for (final k in sortedKeys) {
      groups[k]!.sort((a, b) {
        final aPartial = GramUtils.isPartiallyUsed(
          a.remainingGrams,
          a.totalGrams,
        );
        final bPartial = GramUtils.isPartiallyUsed(
          b.remainingGrams,
          b.totalGrams,
        );
        if (aPartial != bPartial) return aPartial ? 1 : -1;
        return (a.colorName ?? '').compareTo(b.colorName ?? '');
      });
    }
    return {for (final k in sortedKeys) k: groups[k]!};
  }

  Future<void> _openAddSheet({Consumable? edit}) async {
    await AddConsumableSheet.show(context, edit: edit);
  }

  Future<void> _openTwinDetails(Consumable item) async {
    final dao = ref.read(consumableDaoProvider);
    final account = PersonalInventoryActionGuard.fromRef(ref);
    Future<bool> canContinue() async {
      if (!mounted) return false;
      try {
        await account.checkAccess(item.id);
        return mounted;
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$error')));
        }
        return false;
      }
    }

    if (!await canContinue()) return;
    final owner = await dao.getOwnerAccount(item.id);
    final rfidBinding = await dao.getRfidSpoolBindingById(item.id);
    final source = (await dao.getPersonalRfidStockSourcesMap([
      item.id,
    ]))[item.id];
    final balanceConflicts = await dao.readInventoryBalanceConflicts(
      item.uid,
      ownerAccount: owner,
    );
    if (!await canContinue() || !mounted) return;
    if (balanceConflicts.isNotEmpty &&
        rfidBinding?.tagUid.trim().isNotEmpty != true &&
        source == null) {
      final grams = await showPersonalInventoryBalanceReconcileDialog(
        context,
        spool: item,
        conflict: balanceConflicts.first,
        aggregateInventory: true,
      );
      if (grams == null || !mounted) return;
      try {
        await account.run(
          item.id,
          () => dao.reconcilePersonalInventoryBalance(
            item.id,
            balanceConflicts.first,
            grams,
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已记录余量核对，请刷新库存完成同步')));
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('核对失败：$error')));
        }
      }
      return;
    }
    if (rfidBinding?.tagUid.trim().isNotEmpty == true) {
      final history = await dao.getPersonalRfidSpoolHistory(
        rfidBinding!.tagUid,
        ownerAccount: owner,
      );
      if (!await canContinue() || !mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (_) => _RfidLifecycleDialog(
          item: item,
          tagUid: rfidBinding.tagUid,
          history: history,
          binding: rfidBinding,
        ),
      );
      if (action == 'replace' && await canContinue() && mounted) {
        await showRfidSpoolReplacementDialog(context, dao, item);
      }
      if (action == 'rebind' && await canContinue() && mounted) {
        final session = ref.read(appAuthProvider).session;
        final saved = await showRfidSpoolRebindDialog(
          context,
          item: item,
          save: (uid, type) async {
            await account.checkAccess(item.id);
            final current = ref.read(appAuthProvider).session;
            if (current?.user.id != session?.user.id ||
                current?.serverBaseUrl != session?.serverBaseUrl) {
              throw StateError('账号已切换，请关闭对话框后重试');
            }
            if (current == null) {
              await dao.rebindPersonalRfidSpool(
                consumableId: item.id,
                expectedTagUid: rfidBinding.tagUid,
                newTagUid: uid,
                newTagType: type,
                ownerAccount: null,
              );
            } else {
              final ready = await ref
                  .read(appAuthProvider.notifier)
                  .ensureValidSession();
              if (ready.user.id != session!.user.id ||
                  ready.serverBaseUrl != session.serverBaseUrl) {
                throw StateError('账号已切换，请重试');
              }
              final api = ref.read(communityApiProvider);
              if (api is! PersonalInventoryApi)
                throw StateError('当前服务不支持个人库存同步');
              await PersonalInventorySyncService(
                dao: dao,
                api: api as PersonalInventoryApi,
              ).rebindAndSynchronize(
                session: ready,
                consumableId: item.id,
                expectedTagUid: rfidBinding.tagUid,
                newTagUid: uid,
                newTagType: type,
              );
            }
          },
        );
        if (saved && mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已换绑新标签，原有余量与消耗记录已保留')));
      }
      return;
    }
    if (source != null && rfidBinding != null) {
      // A received spool already has an immutable inventory identity even
      // before a card is selected as its physical AMS binding. Its balance
      // conflicts and receipt ledger must remain accessible in this state.
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('${item.manufacturer} ${item.model} · 本卷记录'),
          content: SizedBox(
            width: 520,
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: RfidSpoolHistoryList(
              history: [rfidBinding],
              currentUid: item.uid,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
    final all = widget.async.valueOrNull ?? const <Consumable>[];
    final family = all
        .where(
          (candidate) =>
              candidate.manufacturer == item.manufacturer &&
              candidate.model == item.model &&
              candidate.materialType == item.materialType &&
              candidate.colorHex.toLowerCase() == item.colorHex.toLowerCase(),
        )
        .toList();
    final tagged = family
        .where((c) => c.trayUuid?.trim().isNotEmpty == true)
        .toList();
    if (tagged.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该耗材尚未绑定 RFID，暂无生命周期轨迹')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _TwinTimelineDialog(item: item, rolls: tagged),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: widget.async.when(
        loading: () => const LoadingState(),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '加载失败：${friendlyError(err)}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (items) {
          if (items.isEmpty) {
            final empty = EmptyState(
              useGlass: true,
              bambuIconName: 'spool',
              title: '还没有耗材',
              subtitle: '点击下方按钮添加第一卷',
              actionLabel: '添加耗材',
              onAction: () => _openAddSheet(),
            );
            if (defaultTargetPlatform != TargetPlatform.windows) return empty;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: AppGlassButton(
                      label: 'CUID / FUID 读写',
                      compact: true,
                      icon: const Icon(Icons.nfc_rounded, size: 18),
                      onPressed: () => openDesktopRfidWorkbench(context),
                    ),
                  ),
                ),
                Expanded(child: empty),
              ],
            );
          }

          final filtered = _applySearch(items);
          final grouped = _groupByBrand(filtered);
          final showFineDetail = ref.watch(inventoryFineDetailProvider);

          return CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    ExperienceTokens.pageGutter,
                    AppSpacing.xl,
                    ExperienceTokens.pageGutter,
                    AppSpacing.md,
                  ),
                  child: ExperiencePageHeader(
                    title: '耗材陈列墙',
                    description: '每一卷都按真实颜色、材质和剩余量陈列。悬停查看，点击即可编辑或补充库存。',
                  ),
                ),
              ),
              // 库存预警横幅（仅当存在 critical 级别告警时显示）
              if (ref.watch(hasCriticalStockAlertProvider)) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.lg,
                      AppSpacing.lg,
                      0,
                    ),
                    child: _StockAlertBanner(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const RestockScreen(),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              SliverToBoxAdapter(
                child: _SearchBar(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                  onAdd: () => _openAddSheet(),
                ),
              ),
              if (filtered.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xxxl),
                      child: Text(
                        '没有符合条件的耗材',
                        style: AppTypography.caption.copyWith(
                          color: isDark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                )
              else
                for (final entry in grouped.entries) ...[
                  _BrandHeader(brand: entry.key, items: entry.value),
                  _BrandShelf(
                    items: entry.value,
                    onEdit: (item) => _openAddSheet(edit: item),
                    onDetails: (item) => _openTwinDetails(item),
                    showFineDetail: showFineDetail,
                  ),
                ],
              const SliverToBoxAdapter(child: SizedBox(height: 80)),
            ],
          );
        },
      ),
    );
  }
}

/// Desktop lifecycle view for a reusable CUID/FUID. Each row is one concrete
/// spool, so replacing a depleted roll never hides the previous inventory UID.
class _RfidLifecycleDialog extends StatelessWidget {
  const _RfidLifecycleDialog({
    required this.item,
    required this.tagUid,
    required this.history,
    required this.binding,
  });

  final Consumable item;
  final String tagUid;
  final List<RfidSpoolBinding> history;
  final RfidSpoolBinding binding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('${item.manufacturer} ${item.model} · 标签链路'),
      content: SizedBox(
        width: 520,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: history.isEmpty
            ? const Text('暂无耗材卷记录')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '标签：$tagUid · 共 ${history.length} 卷',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 10),
                  if (history.where((b) => b.isActive).length > 1)
                    const Text('同一标签存在多个当前卷，自动识别已暂停，请核对实际耗材。'),
                  if (binding.tagType != 'ams' &&
                      !isConsumableRfidTagType(binding.tagType))
                    const Text('历史标签仅供查看；请重新扫描并确认 CUID/FUID 后使用耗材标签功能。'),
                  Expanded(
                    child: RfidSpoolHistoryList(
                      history: history,
                      currentUid: item.uid,
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        if (history.isNotEmpty &&
            history.first.inventoryUid == item.uid &&
            isConsumableRfidTagType(history.first.tagType))
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop('replace'),
            icon: const Icon(Icons.autorenew),
            label: const Text('复用标签，换入新卷'),
          ),
        if (binding.status == 'replaced' &&
            isConsumableRfidTagType(binding.tagType) &&
            item.remainingGrams > 0)
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop('rebind'),
            icon: const Icon(Icons.link),
            label: const Text('旧余料换绑新标签'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 搜索框 + 新增耗材按钮。
///
/// v5 Cockpit Tools：用 GlassCard L1 包裹整行，搜索清除与新增按钮走拓竹 SVG。
class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onAdd;

  const _SearchBar({
    required this.controller,
    required this.onChanged,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hintColor = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: GlassCard(
        level: GlassLevel.l1,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            // 搜索框 → AppInput（search 变体：圆角胶囊 + 搜索图标前缀 + 聚焦光环）
            Expanded(
              child: AppInput(
                hint: '搜索品牌、型号、材质…',
                controller: controller,
                search: true,
                onChanged: onChanged,
                // 前缀图标：用拓竹 'search' SVG
                prefixIcon: BambuIcon(
                  name: 'search',
                  size: 18,
                  color: hintColor,
                  applyColorFilter: true,
                ),
                // 清除按钮：有文本时显示 X 图标，空文本时隐藏
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (ctx, value, _) {
                    if (value.text.isEmpty) return const SizedBox.shrink();
                    if (GlassButtonsTheme.enabledOf(ctx)) {
                      return IconButton(
                        tooltip: '清除搜索',
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                        icon: const Icon(Icons.close_rounded, size: 18),
                        style: glassButtonStyle(
                          ctx,
                          IconButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size.square(28),
                            maximumSize: const Size.square(28),
                          ),
                          variant: AppGlassButtonVariant.quiet,
                        ),
                      );
                    }
                    return GestureDetector(
                      onTap: () {
                        controller.clear();
                        onChanged('');
                      },
                      child: BambuIcon(
                        name: 'cross',
                        size: 18,
                        color: hintColor,
                        applyColorFilter: true,
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            if (defaultTargetPlatform == TargetPlatform.windows) ...[
              AppGlassButton(
                label: 'CUID / FUID 读写',
                compact: true,
                variant: AppGlassButtonVariant.secondary,
                icon: const Icon(Icons.nfc_rounded, size: 18),
                onPressed: () => openDesktopRfidWorkbench(context),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
            // 新增按钮 → AppButton（primary 变体）+ 拓竹 'add_filament' 图标
            AppButton(
              label: '新增耗材',
              icon: Builder(
                builder: (context) => BambuIcon(
                  name: 'add_filament',
                  size: 18,
                  color: GlassButtonsTheme.enabledOf(context)
                      ? IconTheme.of(context).color
                      : AppColors.onPrimary,
                  applyColorFilter: true,
                ),
              ),
              onPressed: onAdd,
            ),
          ],
        ),
      ),
    );
  }
}

/// 品牌分区标题行（SliverToBoxAdapter）。
///
/// v5 Cockpit Tools：标题走 PickerGroupHeader 风格（小字号灰色 + 字间距），
/// 右侧保留品牌汇总 Chip。
class _BrandHeader extends ConsumerWidget {
  final String brand;
  final List<Consumable> items;

  const _BrandHeader({required this.brand, required this.items});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final individualIds = ref.watch(personalIndividualSpoolIdsProvider);
    // 品牌总卷数
    final totalRolls = items.fold<int>(
      0,
      (sum, e) =>
          sum +
          inventoryRollCount(
            e.remainingGrams,
            individualSpool: individualIds.contains(e.id),
          ),
    );
    // 品牌总剩余克数
    final totalRemainingGrams = items.fold<double>(
      0.0,
      (sum, e) => sum + e.remainingGrams,
    );

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.xs,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: ExperienceSectionHeading(
                title: brand,
                trailing: Text(
                  '$totalRolls 卷  ·  ${GramUtils.formatGrams(totalRemainingGrams)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                    fontFamily: AppTypography.monoFontFamily,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A horizontally scrollable physical shelf for one material brand.
class _BrandShelf extends StatelessWidget {
  final List<Consumable> items;
  final ValueChanged<Consumable> onEdit;
  final ValueChanged<Consumable>? onDetails;
  final bool showFineDetail;

  const _BrandShelf({
    required this.items,
    required this.onEdit,
    this.onDetails,
    required this.showFineDetail,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 300,
        child: Stack(
          children: [
            Positioned(
              left: AppSpacing.lg,
              right: AppSpacing.lg,
              bottom: 20,
              child: Container(
                height: 10,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant.withValues(alpha: 0.42),
                  borderRadius: BorderRadius.circular(99),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 14,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
              ),
            ),
            ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                2,
                AppSpacing.lg,
                30,
              ),
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.md),
              itemBuilder: (context, index) => SizedBox(
                width: 236,
                child: MaterialShelfCard(
                  item: items[index],
                  onEdit: () => onEdit(items[index]),
                  onDetails: onDetails == null
                      ? null
                      : () => onDetails!(items[index]),
                  showFineDetail: showFineDetail,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 库存预警横幅。
///
/// 当存在 critical 级别告警时显示在库存页顶部，红色玻璃质感 + 警告图标 +
/// 点击跳转到采购清单页。critical 项数从 [stockAlertsProvider] 实时读取。
///
/// v5 Cockpit Tools：用 GlassCard L2 + danger 色调包裹，图标走拓竹 'warning' SVG。
class _StockAlertBanner extends ConsumerWidget {
  final VoidCallback onTap;

  const _StockAlertBanner({required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final alerts = ref.watch(stockAlertsProvider).valueOrNull ?? [];
    final criticalCount = alerts
        .where((a) => a.level == StockLevel.critical)
        .length;
    final lowCount = alerts.where((a) => a.level == StockLevel.low).length;

    final tint = AppColors.danger.withValues(alpha: isDark ? 0.18 : 0.10);

    return GlassCard(
      level: GlassLevel.l2,
      color: tint,
      showBorder: true,
      enableHover: false,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const BambuIcon(
              name: 'warning',
              size: 16,
              color: AppColors.danger,
              applyColorFilter: true,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '库存预警：$criticalCount 项耗材严重不足'
                  '${lowCount > 0 ? '，$lowCount 项低库存' : ''}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.danger,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '点击查看采购清单',
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
          const SizedBox(width: AppSpacing.xs),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
        ],
      ),
    );
  }
}

class _TwinTimelineDialog extends ConsumerWidget {
  const _TwinTimelineDialog({required this.item, required this.rolls});
  final Consumable item;
  final List<Consumable> rolls;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final healthKey = rolls.map((roll) => roll.trayUuid!.trim()).join('|');
    final health = ref.watch(materialHealthProfileProvider(healthKey));
    final timelines = Future.wait(
      rolls.map(
        (roll) => ref
            .read(consumableTwinDaoProvider)
            .getTimeline(roll.trayUuid!.trim()),
      ),
    );
    return AlertDialog(
      title: Text('${item.manufacturer} ${item.model} · 生命周期'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: FutureBuilder<List<List<ConsumableTwinEvent>>>(
          future: timelines,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final events =
                snapshot.data?.expand((e) => e).toList() ??
                const <ConsumableTwinEvent>[];
            events.sort((a, b) => b.observedAt.compareTo(a.observedAt));
            return events.isEmpty
                ? const Center(child: Text('该款耗材暂无生命周期事件'))
                : Column(
                    children: [
                      health.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (_, __) => const SizedBox.shrink(),
                        data: (profile) => ListTile(
                          leading: CircleAvatar(
                            child: Text('${profile.score}'),
                          ),
                          title: Text('耗材健康度：${profile.label}'),
                          subtitle: Text(
                            '追踪 ${profile.rollCount} 卷 · ${profile.eventCount} 条事件 · 异常 ${profile.anomalyCount} 次',
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView.separated(
                          itemCount: events.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final event = events[index];
                            final grams = event.afterGrams == null
                                ? ''
                                : ' · ${event.afterGrams!.toStringAsFixed(1)} g';
                            return ListTile(
                              dense: true,
                              leading: const Icon(
                                Icons.timeline_rounded,
                                size: 18,
                              ),
                              title: Text('${event.eventType.value}$grams'),
                              subtitle: Text(
                                '${event.observedAt.toLocal()} · ${event.source}',
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
