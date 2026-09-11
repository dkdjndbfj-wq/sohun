import 'package:flutter/material.dart';
import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/personal_spool_policy.dart';
import '../../core/utils/friendly_error.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/color_utils.dart';
import '../../data/database/database.dart';
import '../../data/database/daos/consumable_dao.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/models/printer_feed_models.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../providers/consumable_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/personal_inventory_action_guard.dart';
import '../../providers/printer_connection_provider.dart';
import '../../providers/spool_change_provider.dart';
import '../../core/services/spool_change_detector.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/consumable_picker_layout.dart';
import '../../widgets/filament_model_badge.dart';
import '../../widgets/filament_spool_icon.dart';
import '../../widgets/stock_bar.dart';
import 'personal_spool_removal_dialog.dart';

/// 单个通道槽位。展示通道标签、绑定的耗材，并提供选择/更换/解绑操作。
class ChannelSlot extends ConsumerWidget {
  final ChannelWithConsumable data;
  final int printerId;
  final String? printerBrand;
  final String? printerSerial;
  final int? externalFeedCount;
  final int? totalFeedSlots;

  /// Uses a larger left-to-right tile for the printer card's material strip.
  /// The default remains the compact row used by legacy surfaces.
  final bool horizontal;

  const ChannelSlot({
    super.key,
    required this.data,
    required this.printerId,
    this.printerBrand,
    this.printerSerial,
    this.externalFeedCount,
    this.totalFeedSlots,
    this.horizontal = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final channel = data.channel;
    final rawConsumable = data.consumable;
    final accountScope = ref.watch(personalInventoryAccountScopeProvider);
    final inventory = ref.watch(consumablesProvider);
    final visibleIds = inventory is AsyncData<List<Consumable>>
        ? inventory.value.map((item) => item.id).toSet()
        : const <int>{};
    final accountProtected =
        accountScope.enforce &&
        rawConsumable != null &&
        !visibleIds.contains(rawConsumable.id);
    final consumable = accountProtected ? null : rawConsumable;
    final active = data.isActive;

    // 从活跃打印机实时状态获取 AMS 槽位信息
    final activePrinter = ref.watch(activePrinterConnectionProvider);
    final activeConfig = ref.watch(activePrinterConfigProvider);
    final matchesActivePrinter =
        printerSerial?.trim().isNotEmpty != true ||
        activeConfig?.serial == printerSerial;
    final status = matchesActivePrinter ? activePrinter.status : null;
    final amsTrays = status?.amsTrays;
    // P1-5 修复：用 firstWhere 匹配 globalSlot，避免 amsTrays 顺序非升序时取错
    // 旧实现 amsTrays[channel.channelIndex] 假设列表顺序即 globalSlot 顺序，
    // 多 AMS 场景下若解析顺序非升序会取到错误 tray
    final amsTray = (amsTrays != null && channel.channelIndex >= 0)
        ? amsTrays.cast<AmsTray?>().firstWhere(
            (t) => t?.globalSlot == channel.channelIndex,
            orElse: () => null,
          )
        : null;
    final externalSlot = channel.channelIndex == externalFeedLeftChannel
        ? 1
        : channel.channelIndex == externalFeedRightChannel
        ? 0
        : null;
    final externalTray = externalSlot == null
        ? null
        : status?.externalTrays?.cast<AmsTray?>().firstWhere(
            (tray) => tray?.slot == externalSlot,
            orElse: () => null,
          );
    final observedTray = amsTray ?? externalTray;
    final displayLabel = _feedDisplayLabel(
      channel,
      printerBrand: printerBrand,
      externalFeedCount: externalFeedCount,
      totalFeedSlots: totalFeedSlots,
    );

    if (accountProtected) {
      return _AccountProtectedChannel(
        channelLabel: displayLabel,
        horizontal: horizontal,
      );
    }

    if (horizontal) {
      return _AmsChannelTile(
        channelLabel: displayLabel,
        active: active,
        external: isExternalFeedChannel(channel.channelIndex),
        consumable: consumable,
        maintenancePaused: data.farmRollPaused,
        amsTray: observedTray,
        amsHumidity: status?.amsHumidity,
        amsTemp: status?.amsTemp,
        amsDrying: status?.amsDrying,
        onConfigure: () => _openPicker(context, ref),
        onManualChange: () => _requestManualChange(context, ref),
        onTakeOff: () => _takeOff(context, ref),
        onResume: () => _resumeAfterMaintenance(context, ref),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ChannelBadge(
                label: displayLabel,
                active: active,
                external: isExternalFeedChannel(channel.channelIndex),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: consumable == null
                    ? _EmptySlot(amsTray: observedTray)
                    : _BoundSlot(
                        consumable: consumable,
                        maintenancePaused: data.farmRollPaused,
                      ),
              ),
              const SizedBox(width: 4),
              // 操作按钮
              if (consumable == null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SlotButton(
                      label: '刚换了料',
                      color: AppColors.primary,
                      onTap: () => _requestManualChange(context, ref),
                    ),
                    _SlotButton(
                      label: '选择耗材',
                      color: (observedTray != null && observedTray.hasFilament)
                          ? AppColors.warning
                          : AppColors.primary,
                      onTap: () => _openPicker(context, ref),
                    ),
                  ],
                )
              else if (data.farmRollPaused)
                _SlotButton(
                  label: canReusePersonalSpool(consumable.remainingGrams)
                      ? '继续使用'
                      : '选择其他卷',
                  color: AppColors.primary,
                  onTap: () => canReusePersonalSpool(consumable.remainingGrams)
                      ? _resumeAfterMaintenance(context, ref)
                      : _requestManualChange(context, ref),
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SlotButton(
                      label: '更换',
                      color: AppColors.primary,
                      onTap: () => _requestManualChange(context, ref),
                    ),
                    _SlotButton(
                      label: '取下',
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondary,
                      onTap: () => _takeOff(context, ref),
                    ),
                  ],
                ),
            ],
          ),
          // AMS 槽位实时状态：颜色/材质/SKU/剩余克数/第三方标记 + AMS2 环境数据
          if (observedTray != null)
            Padding(
              padding: const EdgeInsets.only(left: 140, top: 4),
              child: _AmsStatusChip(
                amsTray: observedTray,
                amsHumidity: status?.amsHumidity,
                amsTemp: status?.amsTemp,
                amsDrying: status?.amsDrying,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _requestManualChange(BuildContext context, WidgetRef ref) async {
    final guard = PersonalInventoryActionGuard.fromRef(ref);
    final stored = await ref
        .read(printerDaoProvider)
        .getByIdWithChannels(printerId);
    final storedChannel = stored?.channels
        .where((item) => item.channel.id == data.channel.id)
        .firstOrNull;
    final currentConsumable = storedChannel?.consumable;
    if (!guard.isCurrent) {
      if (context.mounted) _showProtectedAccountMessage(context);
      return;
    }
    if (currentConsumable != null &&
        !await _canAccessCurrentPersonalInventory(ref, currentConsumable.id)) {
      if (context.mounted) _showProtectedAccountMessage(context);
      return;
    }
    final activeConfig = ref.read(activePrinterConfigProvider);
    final storedSerial = stored?.serial?.trim();
    final serial = storedSerial?.isNotEmpty == true
        ? storedSerial!
        : activeConfig?.serial ?? 'local-printer-$printerId';
    final storedName = stored?.printer.name?.trim();
    final label = storedName?.isNotEmpty == true
        ? storedName!
        : activeConfig?.displayLabel ?? '打印机 #$printerId';
    final isExternal = isExternalFeedChannel(data.channel.channelIndex);
    final externalCount =
        stored?.channels
            .where((item) => isExternalFeedChannel(item.channel.channelIndex))
            .length ??
        1;
    final accountScope = ref.read(personalInventoryAccountScopeProvider);
    if (!guard.isCurrent) {
      if (context.mounted) _showProtectedAccountMessage(context);
      return;
    }
    ref
        .read(spoolChangeQueueProvider.notifier)
        .enqueue(
          SpoolChangeObservation.manualEvent(
            printerSerial: serial,
            printerLabel: label,
            printerId: printerId,
            channelIndex: data.channel.channelIndex,
            isExternal: isExternal,
            externalInputCount: externalCount,
            externalInputIndex:
                data.channel.channelIndex == externalFeedLeftChannel ? 1 : 0,
          ),
          personalOwnerAccount: accountScope.enforce
              ? accountScope.ownerAccount
              : null,
        );
  }

  // 弹出居中的耗材选择对话框，选中后绑定到当前通道。
  Future<void> _openPicker(BuildContext context, WidgetRef ref) async {
    final guard = PersonalInventoryActionGuard.fromRef(ref);
    // 查询打印机品牌，判断是否为拓竹（拓竹有实时扣减，换卷无需询问剩余量）
    final printer = await ref
        .read(printerDaoProvider)
        .getByIdWithChannels(printerId);
    final currentChannel = printer?.channels
        .where((item) => item.channel.id == data.channel.id)
        .firstOrNull;
    final oldConsumable = currentChannel?.consumable;
    if (oldConsumable != null &&
        !await _canAccessCurrentPersonalInventory(ref, oldConsumable.id)) {
      if (context.mounted) _showProtectedAccountMessage(context);
      return;
    }
    final isBambu = printer?.printer.brand.contains('拓竹') ?? false;
    if (!context.mounted) return;
    if (!guard.isCurrent) {
      _showProtectedAccountMessage(context);
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _ConsumablePickerDialog(
        channelId: data.channel.id,
        isBambu: isBambu,
        oldConsumable: oldConsumable,
      ),
    );
  }

  // 个人模式取下前确认是否属于堵头/维修场景。
  Future<void> _takeOff(BuildContext context, WidgetRef ref) async {
    final guard = PersonalInventoryActionGuard.fromRef(ref);
    final stored = await ref
        .read(printerDaoProvider)
        .getByIdWithChannels(printerId);
    final currentChannel = stored?.channels
        .where((item) => item.channel.id == data.channel.id)
        .firstOrNull;
    final consumable = currentChannel?.consumable;
    if (consumable == null) return;
    if (!await _canAccessCurrentPersonalInventory(ref, consumable.id)) {
      if (context.mounted) _showProtectedAccountMessage(context);
      return;
    }
    if (!guard.isCurrent) {
      if (context.mounted) _showProtectedAccountMessage(context);
      return;
    }
    final isFarm = await ref
        .read(consumableDaoProvider)
        .isFarmConsumable(consumable.id);
    if (!context.mounted) return;
    if (!guard.isCurrent) {
      _showProtectedAccountMessage(context);
      return;
    }
    if (isFarm) {
      showSnack(context, '农场耗材请在农场耗材管理中操作', error: true);
      return;
    }
    final decision = await PersonalSpoolRemovalDialog.show(
      context: context,
      channelLabel: _feedDisplayLabel(
        data.channel,
        printerBrand: printerBrand,
        externalFeedCount: externalFeedCount,
        totalFeedSlots: totalFeedSlots,
      ),
      spoolLabel:
          '${consumable.manufacturer} · ${consumable.colorName ?? consumable.colorHex} · ${consumable.materialType}',
      remainingGrams: consumable.remainingGrams,
      normalDecision: PersonalSpoolRemovalDecision.takeOff,
    );
    if (decision == null || !context.mounted) return;
    if (!guard.isCurrent) {
      _showProtectedAccountMessage(context);
      return;
    }
    final accountScope = guard.scope;
    if (decision == PersonalSpoolRemovalDecision.maintenance) {
      await guard.run(
        consumable.id,
        () => ref
            .read(printerDaoProvider)
            .pauseChannelRollForMaintenance(
              data.channel.id,
              enforcePersonalOwner: accountScope.enforce,
              personalOwnerAccount: accountScope.ownerAccount,
            ),
      );
      if (context.mounted) {
        showSnack(
          context,
          canReusePersonalSpool(consumable.remainingGrams)
              ? '已保留当前克数；维修完成后点击“继续使用”'
              : '已保留当前克数；余量需大于 30g 才能继续使用',
        );
      }
      return;
    }
    await guard.run(
      consumable.id,
      () => ref
          .read(printerDaoProvider)
          .unbindChannel(
            data.channel.id,
            expectedConsumableId: consumable.id,
            enforcePersonalOwner: accountScope.enforce,
            personalOwnerAccount: accountScope.ownerAccount,
          ),
    );
    if (context.mounted) {
      showSnack(context, '已正常取下，库存克数保持不变');
    }
  }

  Future<void> _resumeAfterMaintenance(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final guard = PersonalInventoryActionGuard.fromRef(ref);
    final stored = await ref
        .read(printerDaoProvider)
        .getByIdWithChannels(printerId);
    final currentChannel = stored?.channels
        .where((item) => item.channel.id == data.channel.id)
        .firstOrNull;
    final consumable = currentChannel?.consumable;
    if (consumable == null) return;
    if (!guard.isCurrent) {
      if (context.mounted) _showProtectedAccountMessage(context);
      return;
    }
    if (!await _canAccessCurrentPersonalInventory(ref, consumable.id)) {
      if (context.mounted) _showProtectedAccountMessage(context);
      return;
    }
    if (!guard.isCurrent) {
      if (context.mounted) _showProtectedAccountMessage(context);
      return;
    }
    if (!canReusePersonalSpool(consumable.remainingGrams)) {
      if (context.mounted) {
        showSnack(context, '余量需大于 30g 且不超过 1000g 才能继续，当前克数已保留', error: true);
      }
      return;
    }
    if (currentChannel!.awaitingSpoolSelection) {
      if (context.mounted) await _requestManualChange(context, ref);
      return;
    }
    final accountScope = guard.scope;
    await guard.run(
      consumable.id,
      () => ref
          .read(printerDaoProvider)
          .resumeChannelRollAfterMaintenance(
            data.channel.id,
            enforcePersonalOwner: accountScope.enforce,
            personalOwnerAccount: accountScope.ownerAccount,
          ),
    );
    if (context.mounted) {
      showSnack(
        context,
        '已重新装回，从 ${singleRollAvailableGrams(consumable.remainingGrams).toStringAsFixed(0)}g 继续计算',
      );
    }
  }
}

Future<bool> _canAccessCurrentPersonalInventory(
  WidgetRef ref,
  int consumableId,
) {
  final scope = ref.read(personalInventoryAccountScopeProvider);
  if (!scope.enforce) return Future.value(true);
  return ref
      .read(consumableDaoProvider)
      .ensurePersonalConsumableAccess(
        consumableId,
        ownerAccount: scope.ownerAccount,
      );
}

void _showProtectedAccountMessage(BuildContext context) {
  showSnack(context, '该料位属于其他 Sohun 账号，请切回原账号后操作', error: true);
}

class _AccountProtectedChannel extends StatelessWidget {
  const _AccountProtectedChannel({
    required this.channelLabel,
    required this.horizontal,
  });

  final String channelLabel;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = Container(
      key: const ValueKey('personal-channel-account-protected'),
      constraints: BoxConstraints(minHeight: horizontal ? 220 : 64),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline_rounded, color: scheme.onSurfaceVariant),
          const SizedBox(height: 6),
          Text(
            '其他 Sohun 账号的耗材',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          Text(
            '切回原账号后可查看和操作',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
    if (horizontal) return message;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          _ChannelBadge(label: channelLabel, active: false, external: false),
          const SizedBox(width: 12),
          Expanded(child: message),
        ],
      ),
    );
  }
}

/// 紧凑 TextButton，用于通道行内操作。
class _SlotButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _SlotButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: glassButtonStyle(
        context,
        TextButton.styleFrom(
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 12),
        ),
        variant: AppGlassButtonVariant.quiet,
      ),
      child: Text(label),
    );
  }
}

/// 通道标签圆形徽章。激活态用 Google 蓝，空通道用灰。
class _ChannelBadge extends StatelessWidget {
  final String label;
  final bool active;
  final bool external;

  const _ChannelBadge({
    required this.label,
    required this.active,
    required this.external,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 128,
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: active
            ? AppColors.channelActive.withValues(alpha: 0.13)
            : AppColors.channelEmpty,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active
              ? AppColors.channelActive.withValues(alpha: 0.38)
              : AppColors.outline,
        ),
      ),
      child: Row(
        children: [
          Icon(
            external ? Icons.input_rounded : Icons.hub_outlined,
            size: 15,
            color: active
                ? AppColors.channelActive
                : (isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active
                    ? AppColors.channelActive
                    : (isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondary),
                fontWeight: FontWeight.w700,
                fontSize: 9.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Large left-to-right presentation used inside the printer card.
///
/// The spool is deliberately the primary affordance: clicking it opens the
/// material picker for this exact channel. Keeping the channel label, spool,
/// stock and actions in one tile makes the relationship much easier to scan
/// than a long vertical list.
// ignore: unused_element
class _LegacyHorizontalChannelTile extends StatelessWidget {
  final String channelLabel;
  final bool active;
  final bool external;
  final Consumable? consumable;
  final bool maintenancePaused;
  final AmsTray? amsTray;
  final int? amsHumidity;
  final double? amsTemp;
  final bool? amsDrying;
  final VoidCallback onConfigure;
  final VoidCallback onManualChange;
  final VoidCallback onTakeOff;
  final VoidCallback onResume;

  const _LegacyHorizontalChannelTile({
    required this.channelLabel,
    required this.active,
    required this.external,
    required this.consumable,
    required this.maintenancePaused,
    required this.amsTray,
    required this.amsHumidity,
    required this.amsTemp,
    required this.amsDrying,
    required this.onConfigure,
    required this.onManualChange,
    required this.onTakeOff,
    required this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bound = consumable != null;
    final filamentColor = bound
        ? ColorUtils.fromHex(consumable!.colorHex)
        : (active ? AppColors.primary : scheme.outline);
    final remaining = bound
        ? singleRollAvailableGrams(consumable!.remainingGrams)
        : 0.0;
    final ratio = bound ? (remaining / gramsPerRoll).clamp(0.0, 1.0) : 0.0;
    final progressColor = maintenancePaused
        ? AppColors.warning
        : ratio < 0.2
        ? AppColors.danger
        : ratio < 0.5
        ? AppColors.warning
        : AppColors.primary;

    return Container(
      constraints: const BoxConstraints(minHeight: 292),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: bound
            ? filamentColor.withValues(alpha: dark ? 0.10 : 0.045)
            : scheme.surfaceContainerHighest.withValues(
                alpha: dark ? 0.52 : 0.72,
              ),
        gradient: bound
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  filamentColor.withValues(alpha: dark ? 0.20 : 0.12),
                  filamentColor.withValues(alpha: dark ? 0.035 : 0.015),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: bound
              ? filamentColor.withValues(alpha: 0.30)
              : scheme.outlineVariant.withValues(alpha: 0.75),
        ),
        boxShadow: [
          BoxShadow(
            color: (bound ? filamentColor : scheme.shadow).withValues(
              alpha: dark ? 0.12 : 0.07,
            ),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _ChannelBadge(
                label: channelLabel,
                active: active,
                external: external,
              ),
              const Spacer(),
              Text(
                maintenancePaused
                    ? '已暂停'
                    : bound
                    ? '已绑定'
                    : '待配置',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: maintenancePaused
                      ? AppColors.warning
                      : bound
                      ? progressColor
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _SpoolConfigureButton(
                  color: bound ? filamentColor : scheme.onSurfaceVariant,
                  onTap: onConfigure,
                ),
                const SizedBox(height: 5),
                Text(
                  bound
                      ? (maintenancePaused
                            ? '已暂停 · ${consumable!.colorName ?? '未命名'}'
                            : (consumable!.colorName ?? '未命名'))
                      : '点击耗材卷进行配置',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: maintenancePaused
                        ? AppColors.warning
                        : scheme.onSurface,
                  ),
                ),
                if (bound) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FilamentModelBadge(
                        manufacturer: consumable!.manufacturer,
                        model: consumable!.model,
                        materialType: consumable!.materialType,
                        compact: true,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '${consumable!.materialType} · ${consumable!.manufacturer}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (bound) ...[
            Row(
              children: [
                Expanded(
                  child: StockBar(
                    remaining: remaining,
                    total: gramsPerRoll,
                    height: 6,
                    enableGradient: true,
                  ),
                ),
                const SizedBox(width: 8),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: remaining),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, child) => Text(
                    '${value.toStringAsFixed(0)}g',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: progressColor,
                    ),
                  ),
                ),
              ],
            ),
          ] else
            const StockBar(
              remaining: 0,
              total: gramsPerRoll,
              height: 6,
              enableGradient: false,
            ),
          const SizedBox(height: 5),
          if (amsTray != null)
            SizedBox(
              height: 18,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: _AmsStatusChip(
                  amsTray: amsTray!,
                  amsHumidity: amsHumidity,
                  amsTemp: amsTemp,
                  amsDrying: amsDrying,
                ),
              ),
            )
          else
            const SizedBox(height: 18),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (!bound) ...[
                _SlotButton(
                  label: '刚换了料',
                  color: AppColors.primary,
                  onTap: onManualChange,
                ),
                _SlotButton(
                  label: '绑定耗材',
                  color: active ? AppColors.warning : AppColors.primary,
                  onTap: onConfigure,
                ),
              ] else if (maintenancePaused)
                _SlotButton(
                  label: canReusePersonalSpool(consumable!.remainingGrams)
                      ? '继续使用'
                      : '选择其他卷',
                  color: AppColors.primary,
                  onTap: canReusePersonalSpool(consumable!.remainingGrams)
                      ? onResume
                      : onManualChange,
                )
              else ...[
                _SlotButton(
                  label: '更换',
                  color: AppColors.primary,
                  onTap: onManualChange,
                ),
                _SlotButton(
                  label: '取下',
                  color: dark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                  onTap: onTakeOff,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SpoolConfigureButton extends StatelessWidget {
  final Color color;
  final VoidCallback onTap;

  const _SpoolConfigureButton({required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (GlassButtonsTheme.enabledOf(context)) {
      return SizedBox.square(
        dimension: 72,
        child: AppGlassButton(
          tooltip: '配置耗材',
          onPressed: onTap,
          variant: AppGlassButtonVariant.secondary,
          compact: true,
          minimumSize: const Size.square(72),
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(36),
          child: FilamentSpoolIcon(color: color, size: 52, dimensional: true),
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(36),
        child: Ink(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(color: color.withValues(alpha: 0.24)),
          ),
          child: Center(
            child: FilamentSpoolIcon(color: color, size: 52, dimensional: true),
          ),
        ),
      ),
    );
  }
}

/// Compact white AMS slot. Four of these are shown together in one AMS row.
/// The spool is the same plain inventory icon; its filament changes to the
/// bound material color while the card itself remains neutral white.
class _AmsChannelTile extends StatelessWidget {
  final String channelLabel;
  final bool active;
  final bool external;
  final Consumable? consumable;
  final bool maintenancePaused;
  final AmsTray? amsTray;
  final int? amsHumidity;
  final double? amsTemp;
  final bool? amsDrying;
  final VoidCallback onConfigure;
  final VoidCallback onManualChange;
  final VoidCallback onTakeOff;
  final VoidCallback onResume;

  const _AmsChannelTile({
    required this.channelLabel,
    required this.active,
    required this.external,
    required this.consumable,
    required this.maintenancePaused,
    required this.amsTray,
    required this.amsHumidity,
    required this.amsTemp,
    required this.amsDrying,
    required this.onConfigure,
    required this.onManualChange,
    required this.onTakeOff,
    required this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bound = consumable != null;
    final color = bound
        ? ColorUtils.fromHex(consumable!.colorHex)
        : scheme.onSurfaceVariant.withValues(alpha: 0.48);
    final slotNumber = external
        ? (channelLabel.contains('L') ? 'L' : 'R')
        : (RegExp(r'(\d+)\s*通道').firstMatch(channelLabel)?.group(1) ??
              channelLabel.split(' ').last);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 150;
        if (compact) {
          return _NarrowAmsTile(
            slotNumber: slotNumber,
            color: color,
            bound: bound,
            active: active,
            remaining: bound
                ? singleRollAvailableGrams(consumable!.remainingGrams)
                : 0,
            maintenancePaused: maintenancePaused,
            canResume:
                bound && canReusePersonalSpool(consumable!.remainingGrams),
            onConfigure: onConfigure,
            onManualChange: onManualChange,
            onTakeOff: onTakeOff,
            onResume: onResume,
          );
        }
        return _AmsVerticalTile(
          slotNumber: slotNumber,
          channelLabel: channelLabel,
          color: color,
          bound: bound,
          active: active,
          maintenancePaused: maintenancePaused,
          consumable: consumable,
          amsTray: amsTray,
          amsHumidity: amsHumidity,
          amsTemp: amsTemp,
          amsDrying: amsDrying,
          onConfigure: onConfigure,
          onManualChange: onManualChange,
          onTakeOff: onTakeOff,
          onResume: onResume,
        );
      },
    );
  }
}

/// Full-size AMS channel card used when the row has enough horizontal room.
/// Four cards form one AMS row; the spool remains the primary click target.
class _AmsVerticalTile extends StatelessWidget {
  final String slotNumber;
  final String channelLabel;
  final Color color;
  final bool bound;
  final bool active;
  final bool maintenancePaused;
  final Consumable? consumable;
  final AmsTray? amsTray;
  final int? amsHumidity;
  final double? amsTemp;
  final bool? amsDrying;
  final VoidCallback onConfigure;
  final VoidCallback onManualChange;
  final VoidCallback onTakeOff;
  final VoidCallback onResume;

  const _AmsVerticalTile({
    required this.slotNumber,
    required this.channelLabel,
    required this.color,
    required this.bound,
    required this.active,
    required this.maintenancePaused,
    required this.consumable,
    required this.amsTray,
    required this.amsHumidity,
    required this.amsTemp,
    required this.amsDrying,
    required this.onConfigure,
    required this.onManualChange,
    required this.onTakeOff,
    required this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final remaining = bound
        ? singleRollAvailableGrams(consumable!.remainingGrams)
        : 0.0;
    final ratio = bound ? (remaining / gramsPerRoll).clamp(0.0, 1.0) : 0.0;
    final stockColor = maintenancePaused
        ? AppColors.warning
        : ratio < .2
        ? AppColors.danger
        : ratio < .5
        ? AppColors.warning
        : AppColors.primary;
    final title = bound
        ? (consumable!.colorName?.trim().isNotEmpty == true
              ? consumable!.colorName!.trim()
              : consumable!.colorHex)
        : (active ? '检测到耗材' : '未绑定');
    final subtitle = bound
        ? '${consumable!.materialType} · ${consumable!.manufacturer}'
        : '点击耗材卷进行配置';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onConfigure,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          height: 220,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 7),
          decoration: BoxDecoration(
            color: dark ? scheme.surface : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: bound
                  ? color.withValues(alpha: .42)
                  : scheme.outlineVariant.withValues(alpha: .85),
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: dark ? .12 : .045),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    constraints: const BoxConstraints(minWidth: 24),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: bound
                          ? color.withValues(alpha: .12)
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      slotNumber,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: bound ? color : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      maintenancePaused ? '已暂停' : (bound ? '已绑定' : '待配置'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: maintenancePaused
                            ? AppColors.warning
                            : bound
                            ? stockColor
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Center(
                  child: FilamentSpoolIcon(
                    // Keep the inventory icon plain: no dimensional winding
                    // texture is used in the printer channel view.
                    color: color,
                    size: 64,
                  ),
                ),
              ),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: maintenancePaused
                      ? AppColors.warning
                      : scheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Expanded(
                    child: StockBar(
                      remaining: remaining,
                      total: gramsPerRoll,
                      height: 5,
                      enableGradient: bound,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    bound ? '${remaining.toStringAsFixed(0)}g' : '--',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: bound ? stockColor : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (amsTray != null) ...[
                const SizedBox(height: 4),
                SizedBox(
                  height: 16,
                  child: ClipRect(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: _AmsStatusChip(
                        amsTray: amsTray!,
                        amsHumidity: amsHumidity,
                        amsTemp: amsTemp,
                        amsDrying: amsDrying,
                      ),
                    ),
                  ),
                ),
              ] else
                const SizedBox(height: 16),
              SizedBox(
                height: 22,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: bound
                      ? (maintenancePaused
                            ? _SlotButton(
                                label:
                                    canReusePersonalSpool(
                                      consumable!.remainingGrams,
                                    )
                                    ? '继续'
                                    : '选择其他卷',
                                color: AppColors.primary,
                                onTap:
                                    canReusePersonalSpool(
                                      consumable!.remainingGrams,
                                    )
                                    ? onResume
                                    : onManualChange,
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _SlotButton(
                                    label: '更换',
                                    color: AppColors.primary,
                                    onTap: onManualChange,
                                  ),
                                  _SlotButton(
                                    label: '取下',
                                    color: dark
                                        ? AppColors.textSecondaryDark
                                        : AppColors.textSecondary,
                                    onTap: onTakeOff,
                                  ),
                                ],
                              ))
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _SlotButton(
                              label: '刚换了料',
                              color: AppColors.primary,
                              onTap: onManualChange,
                            ),
                            _SlotButton(
                              label: '绑定',
                              color: active
                                  ? AppColors.warning
                                  : AppColors.primary,
                              onTap: onConfigure,
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NarrowAmsTile extends StatelessWidget {
  final String slotNumber;
  final Color color;
  final bool bound;
  final bool active;
  final double remaining;
  final bool maintenancePaused;
  final bool canResume;
  final VoidCallback onConfigure;
  final VoidCallback onManualChange;
  final VoidCallback onTakeOff;
  final VoidCallback onResume;

  const _NarrowAmsTile({
    required this.slotNumber,
    required this.color,
    required this.bound,
    required this.active,
    required this.remaining,
    required this.maintenancePaused,
    required this.canResume,
    required this.onConfigure,
    required this.onManualChange,
    required this.onTakeOff,
    required this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onConfigure,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? scheme.surface
                : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: bound
                  ? color.withValues(alpha: .38)
                  : scheme.outlineVariant,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: Text(
                  slotNumber,
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    color: bound ? color : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Spacer(),
              FilamentSpoolIcon(color: color, size: 38),
              const SizedBox(height: 3),
              Text(
                bound ? '已绑定' : (active ? '检测到耗材' : '待配置'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  color: bound ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              StockBar(
                remaining: remaining,
                total: gramsPerRoll,
                height: 4,
                enableGradient: bound,
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      bound ? '${remaining.toStringAsFixed(0)}g' : '配置',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: bound ? FontWeight.w700 : FontWeight.w500,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 20,
                        height: 20,
                      ),
                      iconSize: 14,
                      onSelected: (value) {
                        switch (value) {
                          case 'manual':
                            onManualChange();
                            break;
                          case 'remove':
                            onTakeOff();
                            break;
                          case 'resume':
                            onResume();
                            break;
                          case 'configure':
                            onConfigure();
                            break;
                        }
                      },
                      itemBuilder: (context) => [
                        if (!bound)
                          const PopupMenuItem(
                            value: 'manual',
                            child: Text('刚换了料'),
                          ),
                        if (!bound)
                          const PopupMenuItem(
                            value: 'configure',
                            child: Text('绑定耗材'),
                          ),
                        if (bound && maintenancePaused)
                          PopupMenuItem(
                            value: canResume ? 'resume' : 'manual',
                            child: Text(canResume ? '继续使用' : '选择其他卷'),
                          ),
                        if (bound && !maintenancePaused)
                          const PopupMenuItem(
                            value: 'manual',
                            child: Text('更换'),
                          ),
                        if (bound && !maintenancePaused)
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('取下'),
                          ),
                      ],
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
}

String _feedDisplayLabel(
  PrinterChannel channel, {
  String? printerBrand,
  int? externalFeedCount,
  int? totalFeedSlots,
}) {
  if (channel.channelIndex == externalFeedLeftChannel) return '外挂料位 L';
  if (channel.channelIndex == externalFeedRightChannel) {
    return externalFeedCount == 1 ? '外挂料位' : '外挂料位 R';
  }
  final label = channel.label.trim();
  if (label.length > 1 || !RegExp(r'^[A-Z]$').hasMatch(label)) return label;
  if (externalFeedCount == 0 &&
      totalFeedSlots == 1 &&
      channel.channelIndex == 0) {
    return '外挂料位';
  }
  final source = printerBrand?.contains('拓竹') == true ? 'AMS' : '多色系统';
  final unit = channel.channelIndex ~/ 4 + 1;
  final slot = channel.channelIndex % 4 + 1;
  return '$source $unit · 第 $slot 通道';
}

/// 已绑定耗材的中间区域：颜色块 + 颜色名/材质/厂商 + 实时克数 + 进度条。
///
/// 克数和进度条用 [TweenAnimationBuilder] 做 400ms 平滑过渡动画，
/// 打印扣减时 [_maybeDeductConsumables] 写库 → Stream 推送 → consumable 重建
/// → Tween 从旧值过渡到新值，实现"实时消耗"视觉效果。
class _BoundSlot extends StatelessWidget {
  final Consumable consumable;
  final bool maintenancePaused;

  const _BoundSlot({required this.consumable, required this.maintenancePaused});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = ColorUtils.fromHex(consumable.colorHex);
    final colorName = consumable.colorName ?? '未命名';
    final remaining = singleRollAvailableGrams(consumable.remainingGrams);
    const total = gramsPerRoll;
    final percent = (remaining / total).clamp(0.0, 1.0);

    // 进度条颜色：<20% 红（告警），<50% 橙（注意），≥50% 极光绿（正常）
    final progressColor = maintenancePaused
        ? AppColors.warning
        : percent < 0.2
        ? AppColors.danger
        : percent < 0.5
        ? AppColors.warning
        : AppColors.primary;

    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.12 : 0.055),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            color.withValues(alpha: isDark ? 0.16 : 0.10),
            color.withValues(alpha: isDark ? 0.035 : 0.018),
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: isDark ? 0.18 : 0.11),
              borderRadius: BorderRadius.circular(10),
            ),
            child: FilamentSpoolIcon(color: color, size: 28, dimensional: true),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        maintenancePaused ? '已暂停 · $colorName' : colorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: maintenancePaused
                              ? AppColors.warning
                              : (isDark
                                    ? AppColors.textPrimaryDark
                                    : AppColors.textPrimary),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: remaining),
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, child) => Text(
                        '${value.toStringAsFixed(0)}g',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: progressColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    FilamentModelBadge(
                      manufacturer: consumable.manufacturer,
                      model: consumable.model,
                      materialType: consumable.materialType,
                      compact: true,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        consumable.manufacturer,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                const SizedBox(height: 7),
                StockBar(
                  remaining: remaining,
                  total: total,
                  height: 5,
                  enableGradient: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// AMS 槽位实时状态：展示拓竹 RFID 读出的完整信息。
///
/// 显示内容（按数据可用性逐步展示）：
/// - 状态点 + 有料/空槽（基础状态）
/// - 颜色块 + 颜色 HEX（trayColor 非空时）
/// - 材质（trayType 非空时，如 PLA/PETG）
/// - SKU（trayInfoIdx 非空时，如 GFL99）
/// - 厂商（traySubBrands 非空时，如 Bambu/Generic）
/// - 剩余克数（remain >= 0 时，按 trayWeight × remain / 100 计算）
/// - 第三方标记（trayTag == "thirdparty" 时显示橙色"第三方"徽章）
class _AmsStatusChip extends StatelessWidget {
  final AmsTray amsTray;
  // v12：AMS 2 Pro / AMS HT 推送的环境数据，老 AMS 为 null 不展示
  final int? amsHumidity;
  final double? amsTemp;
  final bool? amsDrying;

  const _AmsStatusChip({
    required this.amsTray,
    this.amsHumidity,
    this.amsTemp,
    this.amsDrying,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasFilament = amsTray.hasFilament;

    // 空槽：仅显示"空槽"灰 chip（与旧版兼容）
    if (!hasFilament) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: isDark
              ? AppColors.surfaceVariantDark
              : AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '空槽',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            ),
          ],
        ),
      );
    }

    // 有料：组装完整信息行
    final parts = <Widget>[];

    // 1. 状态点 + "AMS" 标签
    parts.add(
      Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: AppColors.success,
          shape: BoxShape.circle,
        ),
      ),
    );
    parts.add(const SizedBox(width: 4));
    parts.add(
      const Text(
        'AMS',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: AppColors.success,
        ),
      ),
    );

    // v12：AMS 2 Pro / AMS HT 环境数据（湿度/温度/烘干状态）
    // 老 AMS / AMS Lite 不推送，amsHumidity/amsTemp 为 null 时不展示
    if (amsHumidity != null || amsTemp != null) {
      parts.add(const SizedBox(width: 6));
      // 湿度颜色：>60% 红色警告（耗材吸湿风险），40-60% 橙色，<40% 绿色
      final humidityColor = (amsHumidity ?? 0) > 60
          ? AppColors.danger
          : (amsHumidity ?? 0) > 40
          ? AppColors.warning
          : AppColors.success;
      if (amsHumidity != null) {
        parts.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.water_drop, size: 10, color: humidityColor),
              const SizedBox(width: 2),
              Text(
                '$amsHumidity%',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: humidityColor,
                ),
              ),
            ],
          ),
        );
      }
      if (amsTemp != null) {
        parts.add(const SizedBox(width: 6));
        parts.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.thermostat,
                size: 10,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 2),
              Text(
                '${amsTemp!.toStringAsFixed(0)}℃',
                style: TextStyle(
                  fontSize: 10,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        );
      }
      // 烘干中标记
      if (amsDrying == true) {
        parts.add(const SizedBox(width: 6));
        parts.add(
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: const Text(
              '烘干中',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: AppColors.warning,
              ),
            ),
          ),
        );
      }
    }

    // 2. 颜色块（trayColor 非空时）
    if (amsTray.trayColor.isNotEmpty) {
      final color = _parseColor(amsTray.trayColor);
      if (color != null) {
        parts.add(const SizedBox(width: 6));
        parts.add(
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: isDark ? AppColors.outlineDark : AppColors.outline,
                width: 0.5,
              ),
            ),
          ),
        );
        parts.add(const SizedBox(width: 3));
        parts.add(
          Text(
            '#${amsTray.trayColor.toUpperCase()}',
            style: TextStyle(
              fontSize: 10,
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
            ),
          ),
        );
      }
    }

    // 3. 材质（trayType 非空时）
    if (amsTray.trayType.isNotEmpty) {
      parts.add(const SizedBox(width: 6));
      parts.add(
        Text(
          amsTray.trayType,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
          ),
        ),
      );
    }

    // 4. 厂商（traySubBrands 非空时）
    if (amsTray.traySubBrands.isNotEmpty) {
      parts.add(const SizedBox(width: 6));
      parts.add(
        Text(
          amsTray.traySubBrands,
          style: TextStyle(
            fontSize: 10,
            color: isDark
                ? AppColors.textSecondaryDark
                : AppColors.textSecondary,
          ),
        ),
      );
    }

    // 5. SKU（trayInfoIdx 非空且非第三方时）
    if (amsTray.trayInfoIdx.isNotEmpty && !amsTray.isThirdParty) {
      parts.add(const SizedBox(width: 6));
      parts.add(
        Text(
          amsTray.trayInfoIdx,
          style: TextStyle(
            fontSize: 10,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
        ),
      );
    }

    // 6. 剩余克数（remain >= 0 时）
    if (amsTray.remain >= 0) {
      parts.add(const SizedBox(width: 6));
      parts.add(
        Text(
          '${singleRollAvailableGrams(amsTray.remainingGrams).toStringAsFixed(0)}g'
          ' (${amsTray.remain}%)',
          style: TextStyle(
            fontSize: 10,
            color: amsTray.remain < 20
                ? AppColors
                      .danger // 低于 20% 红色提醒
                : (isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary),
            fontWeight: amsTray.remain < 20 ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      );
    }

    // 7. 第三方标记（trayTag == "thirdparty"）
    if (amsTray.isThirdParty) {
      parts.add(const SizedBox(width: 6));
      parts.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(3),
          ),
          child: const Text(
            '第三方',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: AppColors.warning,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.successContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: parts),
    );
  }

  /// 解析拓竹颜色 hex（"RRGGBBAA" 或 "RRGGBB"）为 Flutter Color。
  Color? _parseColor(String hex) {
    if (hex.isEmpty) return null;
    try {
      // 拓竹格式：RRGGBBAA（末 2 位 alpha），Flutter 需要 AARRGGBB
      String normalized = hex;
      if (normalized.length == 8) {
        // RRGGBBAA → FFRRGGBB（强制不透明，避免透明色看不清）
        normalized = 'FF${normalized.substring(0, 6)}';
      } else if (normalized.length == 6) {
        normalized = 'FF$normalized';
      } else {
        return null;
      }
      return Color(int.parse(normalized, radix: 16));
    } catch (_) {
      return null;
    }
  }
}

/// 弹出单通道耗材选择面板。供外部（如 Dashboard）直接调用。
/// 选中后自动绑定到该通道。
///
/// [isBambu] 是否为拓竹打印机。非拓竹换卷时会弹窗询问旧卷剩余克数。
/// [oldConsumable] 当前通道绑定的旧卷（用于换卷时回库）。
Future<void> showConsumablePickerForChannel(
  BuildContext context,
  int channelId, {
  bool isBambu = true,
  Consumable? oldConsumable,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _ConsumablePickerDialog(
      channelId: channelId,
      isBambu: isBambu,
      oldConsumable: oldConsumable,
    ),
  );
}

/// 空通道占位：显示「未绑定」灰色文字。
class _EmptySlot extends StatelessWidget {
  /// AMS 槽位实时数据。有料时显示"AMS 检测到耗材，待绑定"高亮提示。
  final AmsTray? amsTray;

  const _EmptySlot({this.amsTray});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // AMS 检测到有料但通道未绑定 → 橙色提示用户操作
    if (amsTray != null && amsTray!.hasFilament) {
      return Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: isDark ? 0.14 : 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.30)),
        ),
        child: const Row(
          children: [
            FilamentSpoolIcon(color: AppColors.warning, size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '检测到耗材，绑定后即可开始跟踪库存',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.warning,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    // 正常空槽
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.surfaceVariantDark.withValues(alpha: 0.56)
            : AppColors.surfaceVariant.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? AppColors.outlineDark : AppColors.outline,
        ),
      ),
      child: Row(
        children: [
          FilamentSpoolIcon(
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
            size: 28,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '未绑定耗材',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
            ),
          ),
          Icon(
            Icons.add_circle_outline_rounded,
            size: 17,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
        ],
      ),
    );
  }
}

/// 耗材选择对话框。列出所有可用耗材（剩余量>0 且未被其他通道绑定）。
/// H2 bug 修复：通过 getBoundConsumableIds() 排除已被绑定的耗材。
class _ConsumablePickerDialog extends ConsumerStatefulWidget {
  final int channelId;

  /// 是否为拓竹打印机。拓竹有实时扣减，换卷走自动回库逻辑；
  /// 非拓竹换卷时需弹窗询问旧卷剩余克数。
  final bool isBambu;

  /// 当前通道绑定的旧卷（换卷时用于显示旧卷信息）。首次绑定（无旧卷）时为 null。
  final Consumable? oldConsumable;

  const _ConsumablePickerDialog({
    required this.channelId,
    required this.isBambu,
    required this.oldConsumable,
  });

  @override
  ConsumerState<_ConsumablePickerDialog> createState() =>
      _ConsumablePickerDialogState();
}

class _ConsumablePickerDialogState
    extends ConsumerState<_ConsumablePickerDialog> {
  final _searchController = TextEditingController();
  String _query = '';
  // 缓存每个耗材已绑定的通道数，用于判断是否还可继续绑定
  late final Future<Map<int, int>> _boundCountsFuture;
  Map<int, RfidSpoolBinding> _spoolBindings = {};
  Set<int> _individualSpoolIds = {};
  late final PersonalInventoryActionGuard _guard;

  Future<Map<int, int>> _loadAvailability() async {
    final dao = ref.read(consumableDaoProvider);
    final items = await ref.read(consumablesProvider.future);
    _spoolBindings = await dao.getRfidSpoolBindingsMap(items.map((c) => c.id));
    final stock = await dao.getPersonalRfidStockSourcesMap(
      items.map((c) => c.id),
    );
    _individualSpoolIds = {..._spoolBindings.keys, ...stock.keys};
    return ref.read(printerDaoProvider).getBoundConsumableCounts();
  }

  @override
  void initState() {
    super.initState();
    _guard = PersonalInventoryActionGuard.fromRef(ref);
    _boundCountsFuture = _loadAvailability();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final async = ref.watch(consumablesProvider);
    final panelSize = ConsumablePickerLayout.size(context);

    return Dialog(
      insetPadding: ConsumablePickerLayout.insetPadding,
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: SizedBox(
        width: panelSize.width,
        height: panelSize.height,
        child: Material(
          color: isDark ? AppColors.surfaceDark : Colors.white,
          elevation: 16,
          shadowColor: Colors.black.withValues(alpha: isDark ? 0.35 : 0.16),
          borderRadius: BorderRadius.circular(AppColors.radiusXxl),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(
                          alpha: isDark ? 0.16 : 0.10,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: FilamentSpoolIcon(
                        color: AppColors.primary,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '选择耗材',
                            style: TextStyle(
                              fontSize: 20,
                              height: 1.15,
                              fontWeight: FontWeight.w800,
                              color: isDark
                                  ? AppColors.textPrimaryDark
                                  : AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '每个供料位只绑定一卷 · 单卷最多 1000g',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? AppColors.textSecondaryDark
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, size: 21),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v.trim()),
                  decoration: InputDecoration(
                    labelText: '搜索',
                    hintText: '厂商或型号',
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.close_rounded, size: 18),
                          ),
                    filled: true,
                    fillColor: isDark
                        ? AppColors.surfaceVariantDark
                        : AppColors.surfaceContainerHigh,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 13,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: isDark
                            ? AppColors.outlineDark
                            : AppColors.outlineVariant,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: AppColors.primary,
                        width: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
              Divider(
                color: isDark ? AppColors.dividerDark : AppColors.divider,
                height: 1,
              ),
              Expanded(
                child: async.when(
                  loading: () => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                  error: (e, _) => _PickerMessage(
                    icon: Icons.cloud_off_rounded,
                    message: '加载失败：${friendlyError(e)}',
                  ),
                  data: (items) {
                    return FutureBuilder<Map<int, int>>(
                      future: _boundCountsFuture,
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          );
                        }
                        final counts = snapshot.data!;
                        // 聚合库存可有多卷，但一个物理供料位只能占用其中一卷。
                        var list = items.where((c) {
                          final binding = _spoolBindings[c.id];
                          if (binding != null &&
                              !binding.isActive &&
                              binding.status != 'replaced')
                            return false;
                          final individual = _individualSpoolIds.contains(c.id);
                          final rolls = !individual
                              ? inventoryRollCount(c.remainingGrams)
                              : 1;
                          final bound = counts[c.id] ?? 0;
                          final available = individual
                              ? c.remainingGrams
                              : singleRollAvailableGrams(
                                  c.remainingGrams,
                                  alreadyBoundRolls: bound,
                                );
                          return canReusePersonalSpool(available) &&
                              bound < rolls;
                        }).toList();
                        // 搜索过滤：厂商 / 型号 / 材质 / 颜色名 / HEX
                        if (_query.isNotEmpty) {
                          final q = _query.toLowerCase();
                          list = list.where((c) {
                            final haystack =
                                '${c.manufacturer} ${c.model} ${c.materialType} ${c.colorName ?? ''} ${c.colorHex}'
                                    .toLowerCase();
                            return haystack.contains(q);
                          }).toList();
                        }
                        if (list.isEmpty) {
                          return const _PickerMessage(
                            icon: Icons.inventory_2_outlined,
                            message: '没有可用耗材',
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
                              child: Text(
                                '${list.length} 种耗材可供选择',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: isDark
                                      ? AppColors.textSecondaryDark
                                      : AppColors.textSecondary,
                                ),
                              ),
                            ),
                            Expanded(
                              child: ListView.separated(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  8,
                                  16,
                                  20,
                                ),
                                itemCount: list.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, i) {
                                  final c = list[i];
                                  final individual = _spoolBindings.containsKey(
                                    c.id,
                                  );
                                  final rolls = individual
                                      ? 1
                                      : inventoryRollCount(c.remainingGrams);
                                  final bound = counts[c.id] ?? 0;
                                  return _ConsumableTile(
                                    consumable: c,
                                    individual: individual,
                                    bindable: rolls - bound,
                                    rollGrams: individual
                                        ? c.remainingGrams
                                        : singleRollAvailableGrams(
                                            c.remainingGrams,
                                            alreadyBoundRolls: bound,
                                          ),
                                    onTap: () => _select(c),
                                  );
                                },
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _select(Consumable c) async {
    try {
      _guard.assertCurrent();
      if (widget.oldConsumable != null &&
          !await _canAccessCurrentPersonalInventory(
            ref,
            widget.oldConsumable!.id,
          )) {
        throw StateError('该料位属于其他 Sohun 账号，请切回原账号后操作');
      }
      double? manualRemaining;
      // 非拓竹打印机换卷且存在旧卷：弹窗询问旧卷剩余克数（用于回库标记）
      if (!widget.isBambu && widget.oldConsumable != null) {
        manualRemaining = await _askRemainingGrams(widget.oldConsumable!);
        if (manualRemaining == null) return; // 用户取消
      }
      final accountScope = _guard.scope;
      await _guard.run(
        c.id,
        () => ref
            .read(printerDaoProvider)
            .changeRoll(
              channelId: widget.channelId,
              newConsumableId: c.id,
              manualRemainingGrams: manualRemaining,
              enforcePersonalOwner: accountScope.enforce,
              personalOwnerAccount: accountScope.ownerAccount,
            ),
      );
      if (mounted) {
        Navigator.of(context).pop();
        showSnack(context, '已绑定「${c.manufacturer} ${c.model}」');
      }
    } catch (error) {
      if (mounted) showSnack(context, '换卷未完成：$error', error: true);
    }
  }

  /// 弹窗询问旧卷剩余克数（非拓竹换卷专用）。
  /// 返回用户输入的克数；用户取消返回 null。
  Future<double?> _askRemainingGrams(Consumable old) async {
    final binding = await ref
        .read(consumableDaoProvider)
        .getRfidSpoolBindingById(old.id);
    if (!mounted) return null;
    final tagged = binding?.tagUid.isNotEmpty == true;
    const maxGrams = personalSpoolCapacityGrams;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final controller = TextEditingController(
      text:
          (tagged
                  ? old.remainingGrams
                  : singleRollAvailableGrams(old.remainingGrams))
              .toString(),
    );
    return showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('换卷 · 旧卷剩余克数'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '旧卷：${old.manufacturer} ${old.colorName ?? old.colorHex}',
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '当前绑定的一卷：初始净重 ${maxGrams.toStringAsFixed(0)}g',
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '请输入旧卷净余量。有未结算任务时保留账面余量，称重差额在结算后核对。',
              style: TextStyle(
                fontSize: 11,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '大约还剩多少克',
                suffixText: 'g',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(controller.text.trim());
              // N6 修复：输入校验
              if (v == null || !v.isFinite) {
                showSnack(ctx, '请输入有效数字', error: true);
                return;
              }
              if (v < 0) {
                showSnack(ctx, '剩余克数不能为负数', error: true);
                return;
              }
              if (v > maxGrams) {
                showSnack(
                  ctx,
                  '余量不能超过初始净重 ${maxGrams.toStringAsFixed(0)}g',
                  error: true,
                );
                return;
              }
              Navigator.pop(ctx, v);
            },
            child: const Text('确认'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}

/// 耗材列表项：色块 + 厂商/材质 + 剩余/可绑卷数。
class _ConsumableTile extends StatelessWidget {
  final Consumable consumable;
  final int bindable;
  final double rollGrams;
  final bool individual;
  final VoidCallback onTap;

  const _ConsumableTile({
    required this.consumable,
    required this.bindable,
    required this.rollGrams,
    this.individual = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final color = ColorUtils.fromHex(consumable.colorHex);
    final colorName = consumable.colorName ?? '未命名';
    final rolls = individual
        ? 1
        : inventoryRollCount(consumable.remainingGrams);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
          decoration: BoxDecoration(
            color: isDark
                ? AppColors.surfaceVariantDark.withValues(alpha: 0.52)
                : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: color.withValues(alpha: isDark ? 0.34 : 0.24),
            ),
            boxShadow: isDark ? null : AppColors.shadow1,
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: isDark ? 0.16 : 0.09),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: FilamentSpoolIcon(color: color, size: 38),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${consumable.manufacturer} · $colorName · ${consumable.materialType}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${consumable.model} · ${consumable.colorHex}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '本卷 ${rollGrams.toStringAsFixed(0)}g · 库存 $rolls 卷 · 可绑 $bindable 卷',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? AppColors.textSecondaryDark
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 52,
                          child: StockBar(
                            remaining: rollGrams,
                            total: individual
                                ? consumable.totalGrams
                                : gramsPerRoll,
                            height: 5,
                            enableGradient: true,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerMessage extends StatelessWidget {
  final IconData icon;
  final String message;

  const _PickerMessage({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 30, color: scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
