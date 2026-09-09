import 'package:flutter/material.dart';
import '../../core/theme/glass_button_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/spool_change_detector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_curves.dart';
import '../../core/theme/interaction_effects.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/gram_utils.dart';
import '../../data/database/database.dart';
import '../../data/database/daos/consumable_dao.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../providers/consumable_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/personal_inventory_action_guard.dart';
import '../../providers/spool_change_provider.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/filament_spool_icon.dart';
import 'external_consumable_picker_dialog.dart';

final _spoolChangeBoundCountsProvider =
    FutureProvider.autoDispose<Map<int, int>>((ref) {
      return ref.watch(printerDaoProvider).getBoundConsumableCounts();
    });

typedef _SpoolChangeLocation = ({
  String eventId,
  int? printerId,
  String printerSerial,
  int channelIndex,
  String personalOwnerAccount,
});

typedef _CurrentPersonalSpool = ({
  int consumableId,
  double remainingGrams,
  bool paused,
});

final _spoolChangeCurrentSpoolProvider = FutureProvider.autoDispose
    .family<_CurrentPersonalSpool?, _SpoolChangeLocation>((
      ref,
      location,
    ) async {
      final dao = ref.watch(printerDaoProvider);
      final consumableDao = ref.watch(consumableDaoProvider);
      final printerId =
          location.printerId ??
          await dao.getPrinterIdBySerial(location.printerSerial);
      if (printerId == null) return null;
      final printer = await dao.getByIdWithChannels(printerId);
      final channel = printer?.channels
          .where((item) => item.channel.channelIndex == location.channelIndex)
          .firstOrNull;
      final consumable = channel?.consumable;
      if (channel == null || consumable == null) return null;
      if (!await consumableDao.ensurePersonalConsumableAccess(
        consumable.id,
        ownerAccount: location.personalOwnerAccount,
      )) {
        return null;
      }
      return (
        consumableId: consumable.id,
        remainingGrams: consumable.remainingGrams,
        paused: channel.farmRollPaused,
      );
    });

/// Confirms one pending spool replacement at a time.
///
/// The app presents this widget as a modal route. Once its event is resolved,
/// that route closes so the next printer or spool change can open separately.
class SpoolChangeConfirmationDialog extends ConsumerStatefulWidget {
  const SpoolChangeConfirmationDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '耗材更换确认',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: AppCurves.durationModal,
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        if (!AppMotion.enabled(context)) return child;
        final curved = CurvedAnimation(
          parent: animation,
          curve: AppCurves.curveModal,
        );
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: curved, child: child),
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) =>
          const SpoolChangeConfirmationDialog(),
    );
  }

  @override
  ConsumerState<SpoolChangeConfirmationDialog> createState() =>
      _SpoolChangeConfirmationDialogState();
}

class _SpoolChangeConfirmationDialogState
    extends ConsumerState<SpoolChangeConfirmationDialog> {
  final Map<String, int> _selectedIds = {};
  String _selectionKey(SpoolChangeObservation event) =>
      '${event.eventId}:${SpoolChangeObservation.trayIdentity(event.current)}:${event.requiresRfidConfirmation}';
  bool _busy = false;
  bool _closing = false;

  void _assertEventCurrent(SpoolChangeObservation event) {
    final scope = ref.read(personalInventoryAccountScopeProvider);
    if (scope.enforce &&
        event.personalOwnerAccount.trim().toLowerCase() !=
            scope.ownerAccount.trim().toLowerCase()) {
      throw StateError('账号已经切换，请按当前账号的最新提示重新选择');
    }
    final current = ref
        .read(spoolChangeQueueProvider)
        .where((item) => item.locationKey == event.locationKey)
        .firstOrNull;
    if (current?.eventId != event.eventId || current?.isRemoval == true) {
      throw StateError('料位检测结果已经变化，请按最新提示重新选择');
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = ref.watch(
      spoolChangeQueueProvider.select(
        (events) =>
            events.where((event) => !event.farmMode).toList(growable: false),
      ),
    );
    final currentEventId = events.isEmpty ? null : events.first.eventId;
    final separatePopup = Navigator.of(context).canPop();
    ref.listen<List<SpoolChangeObservation>>(spoolChangeQueueProvider, (
      _,
      next,
    ) {
      if (currentEventId == null ||
          next.any(
            (event) => !event.farmMode && event.eventId == currentEventId,
          )) {
        return;
      }
      _closeCurrentPopup();
    });

    if (events.isEmpty) return const SizedBox.shrink();
    final event = events.first;
    final accountScope = ref.watch(personalInventoryAccountScopeProvider);
    final eventOwnerMatches =
        !accountScope.enforce ||
        event.personalOwnerAccount.trim().toLowerCase() ==
            accountScope.ownerAccount.trim().toLowerCase();
    final inventory = eventOwnerMatches
        ? switch (ref.watch(consumablesProvider)) {
            AsyncData(:final value) => value,
            _ => const <Consumable>[],
          }
        : const <Consumable>[];
    final individualSpoolIds = ref.watch(personalIndividualSpoolIdsProvider);
    final boundCounts = switch (ref.watch(_spoolChangeBoundCountsProvider)) {
      AsyncData(:final value) => value,
      _ => null,
    };
    final currentSpool = ref
        .watch(
          _spoolChangeCurrentSpoolProvider((
            eventId: event.eventId,
            printerId: event.printerId,
            printerSerial: event.printerSerial,
            channelIndex: event.channelIndex,
            personalOwnerAccount: event.personalOwnerAccount,
          )),
        )
        .whenOrNull(data: (value) => value);
    final currentSpoolVisible =
        currentSpool != null &&
        currentSpool.remainingGrams > 0 &&
        inventory.any((item) => item.id == currentSpool.consumableId);
    final canContinueCurrent =
        currentSpoolVisible &&
        (!event.requiresRfidConfirmation ||
            event.rfidCandidateIds.contains(currentSpool.consumableId));
    final selectedId =
        _selectedIds[_selectionKey(event)] ??
        (boundCounts == null
            ? null
            : _suggestedConsumableId(
                event,
                inventory,
                boundCounts,
                individualSpoolIds,
              ));
    final selected = selectedId == null
        ? null
        : inventory.where((item) => item.id == selectedId).firstOrNull;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 650),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Material(
            color: Theme.of(context).brightness == Brightness.dark
                ? AppColors.surfaceDark
                : AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _DialogHeader(
                    event: event,
                    count: separatePopup ? 1 : events.length,
                  ),
                  if (!separatePopup && events.length > 1) ...[
                    const SizedBox(height: 12),
                    _EventStepper(events: events),
                  ],
                  const SizedBox(height: 14),
                  _DetectedSpoolCard(event: event),
                  if (event.requiresRfidConfirmation) ...[
                    const SizedBox(height: 10),
                    if (selected != null)
                      Text(
                        event.rfidStockCandidates.containsKey(selected.id)
                            ? '已选库存卷：${event.rfidCandidateInventoryUids[selected.id] ?? "请重新选择"}'
                            : '手机登记 UID：${event.rfidCandidateUids[selected.id] ?? "请重新选择"}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    Text(
                      event.rfidStockCandidates.isNotEmpty
                          ? 'AMS 上报 ${event.current?.normalizedTagUid ?? ""}。这张资料卡可对应多卷库存，请选择实际装入的库存卷；确认只切换当前卷，不会增加库存。'
                          : 'AMS 上报 ${event.current?.normalizedTagUid ?? ""}。请核对它与手机登记的标签是否为同一张；确认后仅在本机记住对应关系。',
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (event.rfidCandidateIds.isEmpty)
                      const Text('没有可确认的当前卷，或完整标识已有冲突，请先核对标签生命周期。'),
                  ],
                  const SizedBox(height: 14),
                  Text(
                    selected == null ? '选择本次装入的耗材卷' : '已选择本次装入的库存卷',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 7),
                  _SelectedInventoryEntry(
                    selected: selected,
                    loading: boundCounts == null,
                    displayGrams: selected == null
                        ? null
                        : event.rfidStockCandidates.containsKey(selected.id) ||
                              individualSpoolIds.contains(selected.id)
                        ? selected.remainingGrams
                        : singleRollAvailableGrams(selected.remainingGrams),
                    onTap: boundCounts == null || _busy
                        ? null
                        : () => _chooseConsumable(
                            event,
                            selectedId,
                            boundCounts,
                            individualSpoolIds,
                            currentConsumableId: currentSpool?.consumableId,
                          ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: _busy ? null : () => _snoozeAndClose(event),
                        icon: const Icon(
                          Icons.notifications_paused_outlined,
                          size: 16,
                        ),
                        label: const Text('稍后提醒'),
                      ),
                      if (canContinueCurrent)
                        TextButton.icon(
                          key: const ValueKey(
                            'spool-change-continue-current-remnant',
                          ),
                          onPressed: _busy
                              ? null
                              : event.requiresRfidConfirmation
                              ? () => _bind(event, currentSpool.consumableId)
                              : () => _keepOriginal(event),
                          icon: const Icon(Icons.replay_rounded, size: 16),
                          label: Text(
                            '继续当前余料卷（${GramUtils.formatGrams(currentSpool.remainingGrams)}）',
                          ),
                        ),
                      FilledButton.icon(
                        onPressed: selectedId == null || _busy
                            ? null
                            : () => _bind(event, selectedId),
                        icon: _busy
                            ? Builder(
                                builder: (context) => SizedBox.square(
                                  dimension: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: GlassButtonsTheme.enabledOf(context)
                                        ? IconTheme.of(context).color
                                        : Colors.white,
                                  ),
                                ),
                              )
                            : const Icon(Icons.link_rounded, size: 16),
                        label: Text(
                          event.rfidStockCandidates.isNotEmpty
                              ? selected == null
                                    ? '请选择具体卷'
                                    : selected.id == currentSpool?.consumableId
                                    ? '继续选中的原余料卷'
                                    : GramUtils.isPartiallyUsed(
                                        selected.remainingGrams,
                                        selected.totalGrams,
                                      )
                                    ? '确认已有余料卷并绑定'
                                    : '确认同款新卷并绑定'
                              : event.requiresRfidConfirmation
                              ? '确认同一标签并绑定'
                              : '确认绑定',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _keepOriginal(SpoolChangeObservation event) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final dao = ref.read(printerDaoProvider);
      final guard = PersonalInventoryActionGuard.fromRef(ref);
      final accountScope = guard.scope;
      final printerId =
          event.printerId ??
          await dao.getPrinterIdBySerial(event.printerSerial);
      if (printerId == null) throw StateError('找不到打印机记录');
      final printer = await dao.getByIdWithChannels(printerId);
      final channel = printer?.channels
          .where((item) => item.channel.channelIndex == event.channelIndex)
          .firstOrNull;
      if (channel?.consumable == null ||
          channel!.consumable!.remainingGrams <= 0) {
        throw StateError('当前料位没有可继续使用的余料卷，请从库存重新选择');
      }
      await guard.run(channel.consumable!.id, () async {
        _assertEventCurrent(event);
        if (channel.farmRollPaused) {
          await dao.resumeChannelRollAfterMaintenance(
            channel.channel.id,
            enforcePersonalOwner: accountScope.enforce,
            personalOwnerAccount: accountScope.ownerAccount,
          );
        }
      });
      if (mounted) {
        showSnack(context, '原卷已重新装回，将从保留的克数继续计算');
      }
      ref.read(spoolChangeQueueProvider.notifier).resolve(event.eventId);
      _closeCurrentPopup();
    } catch (error) {
      if (mounted) {
        showSnack(context, '恢复原卷失败：$error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int? _suggestedConsumableId(
    SpoolChangeObservation event,
    List<Consumable> items,
    Map<int, int> boundCounts,
    Set<int> individualSpoolIds,
  ) {
    final current = event.current;
    if (current == null) return null;
    if (event.requiresRfidConfirmation) {
      // Selection is explicit; material-template colour is not identity proof.
      return null;
    }
    for (final item in items) {
      if (current.trayUuid.isNotEmpty && item.trayUuid == current.trayUuid) {
        return item.id;
      }
    }
    final hex = _trayHex(current);
    for (final item in items) {
      if (_hasAvailableRoll(
            item,
            boundCounts,
            individualSpool: individualSpoolIds.contains(item.id),
          ) &&
          item.materialType.toLowerCase() == current.trayType.toLowerCase() &&
          item.colorHex.toLowerCase() == hex.toLowerCase() &&
          (current.trayInfoIdx.isEmpty || item.model == current.trayInfoIdx)) {
        return item.id;
      }
    }
    return null;
  }

  Future<void> _chooseConsumable(
    SpoolChangeObservation event,
    int? selectedId,
    Map<int, int> boundCounts,
    Set<int> individualSpoolIds, {
    int? currentConsumableId,
  }) async {
    if (event.requiresRfidConfirmation) {
      final items =
          (ref.read(consumablesProvider).valueOrNull ?? const <Consumable>[])
              .where((c) => event.rfidCandidateIds.contains(c.id))
              .toList();
      final chosen = await showDialog<Consumable>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            event.rfidStockCandidates.isNotEmpty
                ? '选择这张资料卡对应的具体卷'
                : '核对手机登记的标签',
          ),
          content: SizedBox(
            width: 380,
            height: 260,
            child: items.isEmpty
                ? const Text('没有可确认的当前卷，请先在库存核对标签周期。')
                : ListView(
                    children: [
                      for (final item in items)
                        ListTile(
                          title: Text(
                            '${item.id == currentConsumableId
                                ? "当前暂存余料卷"
                                : GramUtils.isPartiallyUsed(item.remainingGrams, item.totalGrams)
                                ? "已有余料卷"
                                : "同款新卷"} · '
                            '${item.manufacturer} · ${item.model} · ${item.colorName ?? item.colorHex}',
                          ),
                          subtitle: Text(
                            event.rfidStockCandidates.containsKey(item.id)
                                ? '资料卡 ${event.rfidCandidateUids[item.id]} · 库存卷 ${event.rfidCandidateInventoryUids[item.id]} · 余量 ${item.remainingGrams.toStringAsFixed(1)}g'
                                : '手机 UID ${event.rfidCandidateUids[item.id]} · 库存卷 ${event.rfidCandidateInventoryUids[item.id]} · 余量 ${item.remainingGrams.toStringAsFixed(1)}g',
                          ),
                          onTap: () => Navigator.pop(ctx, item),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (chosen != null && mounted) {
        setState(() => _selectedIds[_selectionKey(event)] = chosen.id);
      }
      return;
    }
    final tray = event.current;
    final color = tray == null
        ? AppColors.primary
        : ColorUtils.fromHex(_trayHex(tray), fallback: AppColors.primary);
    final selected = await ConsumableShelfPickerDialog.show(
      context,
      spec: ConsumableShelfPickerSpec(
        title: '选择本次装入的耗材卷',
        subtitle: '${event.printerLabel} · ${event.slotLabel}',
        accentColor: color,
        keyPrefix: 'spool-change',
        selectedId: selectedId,
        initialManufacturer: tray?.traySubBrands.isNotEmpty == true
            ? tray!.traySubBrands
            : null,
        initialMaterial: tray?.trayType.isNotEmpty == true
            ? tray!.trayType
            : null,
        initialColorHex: tray == null ? null : _trayHex(tray),
        includeItem: (item) => event.requiresRfidConfirmation
            ? event.rfidCandidateIds.contains(item.id)
            : item.id == selectedId ||
                  _hasAvailableRoll(
                    item,
                    boundCounts,
                    individualSpool: individualSpoolIds.contains(item.id),
                  ),
        matchScore: (item) => _spoolMatchScore(item, tray),
        isRecommended: (item) => _spoolMatchScore(item, tray) >= 5,
        displayGramsFor: (item) => individualSpoolIds.contains(item.id)
            ? item.remainingGrams
            : singleRollAvailableGrams(
                item.remainingGrams,
                alreadyBoundRolls: boundCounts[item.id] ?? 0,
              ),
        emptyLabel: '库存中没有可继续使用或可绑定的耗材卷',
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _selectedIds[_selectionKey(event)] = selected.id);
  }

  Future<void> _bind(SpoolChangeObservation event, int consumableId) async {
    if (_busy || event.farmMode) return;
    setState(() => _busy = true);
    try {
      final dao = ref.read(printerDaoProvider);
      final guard = PersonalInventoryActionGuard.fromRef(ref);
      final accountScope = guard.scope;
      final printerId =
          event.printerId ??
          await dao.getPrinterIdBySerial(event.printerSerial);
      if (printerId == null) throw StateError('找不到打印机记录');
      double? manualRemainingGrams;
      final oldConsumableId = await dao.getConsumableIdByChannel(
        printerId,
        event.channelIndex,
      );
      if (oldConsumableId == consumableId) {
        final printer = await dao.getByIdWithChannels(printerId);
        final currentChannel = printer?.channels
            .where((item) => item.channel.channelIndex == event.channelIndex)
            .firstOrNull;
        final binding = await ref
            .read(consumableDaoProvider)
            .getRfidSpoolBindingById(consumableId);
        if (currentChannel?.awaitingSpoolSelection == true &&
            binding?.isActive == true) {
          await guard.run(consumableId, () async {
            _assertEventCurrent(event);
            await dao.resumePreparedPersonalSpoolReplacement(
              currentChannel!.channel.id,
              expectedConsumableId: consumableId,
              enforcePersonalOwner: accountScope.enforce,
              personalOwnerAccount: accountScope.ownerAccount,
            );
          });
          if (mounted) {
            showSnack(context, '已重新装回原余料卷，将从保留的克数继续计算');
          }
          ref.read(spoolChangeQueueProvider.notifier).resolve(event.eventId);
          _closeCurrentPopup();
          ref.invalidate(_spoolChangeBoundCountsProvider);
          return;
        }
      }
      if (oldConsumableId != null &&
          oldConsumableId != consumableId &&
          event.previous?.isBambuOfficialRfid != true) {
        final oldConsumable = await ref
            .read(consumableDaoProvider)
            .getById(oldConsumableId);
        if (oldConsumable != null) {
          final oldHasReliableRfid =
              oldConsumable.trayUuid?.trim().isNotEmpty == true &&
              oldConsumable.rfidSyncedAt != null;
          if (oldHasReliableRfid) {
            // 手动入口可能没有 previous tray，但数据库已经有可信 RFID
            // 残量，不需要把自动同步值再问一遍。
          } else {
            if (!mounted) return;
            manualRemainingGrams = await _askRemainingGrams(
              event,
              oldConsumable,
            );
            if (manualRemainingGrams == null) return;
            guard.assertCurrent();
            _assertEventCurrent(event);
          }
        }
      }
      final tray = event.current;
      final binding = await ref
          .read(consumableDaoProvider)
          .getRfidSpoolBindingById(consumableId);
      final stockCandidate = event.rfidStockCandidates[consumableId];
      final reusable =
          stockCandidate != null ||
          (binding?.tagUid.isNotEmpty == true && binding?.tagType != 'ams');
      if (event.requiresRfidConfirmation &&
          !event.rfidCandidateIds.contains(consumableId)) {
        throw StateError('请选择已经登记的候选标签卷；不能按模板颜色推断身份');
      }
      await guard.run(consumableId, () async {
        _assertEventCurrent(event);
        await dao.bindSpoolReplacement(
          printerId: printerId,
          channelIndex: event.channelIndex,
          consumableId: consumableId,
          manualRemainingGrams: manualRemainingGrams,
          uniquePhysicalSpool: tray?.isBambuOfficialRfid == true,
          confirmedAmsUid: event.requiresRfidConfirmation
              ? tray?.normalizedTagUid
              : null,
          sourceTagUid: stockCandidate?.tagUid,
          sourceTagType: stockCandidate?.tagType,
          sourceOwnerAccount: stockCandidate?.ownerAccount,
          enforcePersonalOwner: accountScope.enforce,
          personalOwnerAccount: accountScope.ownerAccount,
        );
      });
      if (tray case final officialTray?
          when officialTray.isBambuOfficialRfid && !reusable) {
        final consumableDao = ref.read(consumableDaoProvider);
        await consumableDao.updateTrayUuid(consumableId, officialTray.trayUuid);
        if (officialTray.hasValidRemain && officialTray.trayWeight > 0) {
          await consumableDao.updateRfidSync(
            consumableId: consumableId,
            remainingGrams: officialTray.remainingGrams,
          );
        }
      }
      ref.read(spoolChangeQueueProvider.notifier).resolve(event.eventId);
      _closeCurrentPopup();
      ref.invalidate(_spoolChangeBoundCountsProvider);
    } catch (error) {
      if (mounted) {
        showSnack(context, '绑定失败：$error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snoozeAndClose(SpoolChangeObservation event) {
    if (_busy) return;
    ref.read(spoolChangeQueueProvider.notifier).snooze(event);
    _closeCurrentPopup();
  }

  void _closeCurrentPopup() {
    if (_closing || !mounted) return;
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && navigator.canPop()) navigator.pop();
    });
  }

  Future<double?> _askRemainingGrams(
    SpoolChangeObservation event,
    Consumable old,
  ) async {
    final binding = await ref
        .read(consumableDaoProvider)
        .getRfidSpoolBindingById(old.id);
    if (!mounted) return null;
    final tagged = binding?.tagUid.isNotEmpty == true;
    final maxGrams = tagged ? old.totalGrams : gramsPerRoll;
    final controller = TextEditingController(
      text:
          (tagged
                  ? old.remainingGrams
                  : singleRollAvailableGrams(old.remainingGrams))
              .toString(),
    );
    try {
      return await AppDialog.show<double>(
        context: context,
        title: '旧卷还有多少料？',
        barrierDismissible: false,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${event.printerLabel} · ${event.slotLabel}',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${old.manufacturer} · ${old.materialType} · '
              '${old.colorName ?? old.colorHex}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '大约剩余',
                suffixText: 'g',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop<double>(),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              final value = double.tryParse(controller.text.trim());
              if (value == null ||
                  !value.isFinite ||
                  value < 0 ||
                  value > maxGrams) {
                showSnack(
                  context,
                  '请输入 0 到 ${maxGrams.toStringAsFixed(0)}g 的净余量',
                  error: true,
                );
                return;
              }
              if (value <= GramUtils.comparisonToleranceGrams) {
                final confirmed = await AppDialog.confirm(
                  context,
                  '确认旧卷已经用完？',
                  '你填写了 0g。只有旧卷确实没有余料时才继续；确认后旧卷会按耗尽保存。',
                  confirmText: '确认旧卷用完',
                  destructive: true,
                );
                if (!confirmed || !mounted) return;
              }
              if (!mounted) return;
              navigator.pop<double>(value);
            },
            child: const Text('回库并继续'),
          ),
        ],
      );
    } finally {
      controller.dispose();
    }
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.event, required this.count});

  final SpoolChangeObservation event;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.swap_vert_rounded,
            color: AppColors.primary,
            size: 22,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                count > 1 ? '发现多卷耗材变化' : '检测到耗材装入',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${event.printerLabel} · ${event.slotLabel}',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EventStepper extends StatelessWidget {
  const _EventStepper({required this.events});

  final List<SpoolChangeObservation> events;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < events.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: i == 0
                  ? AppColors.primary.withValues(alpha: 0.13)
                  : AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: i == 0
                    ? AppColors.primary.withValues(alpha: 0.45)
                    : AppColors.outline,
              ),
            ),
            child: Text(
              '${events[i].printerLabel} · ${events[i].slotLabel}',
              style: TextStyle(
                fontSize: 10,
                color: i == 0 ? AppColors.primary : AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }
}

class _DetectedSpoolCard extends StatelessWidget {
  const _DetectedSpoolCard({required this.event});

  final SpoolChangeObservation event;

  @override
  Widget build(BuildContext context) {
    final tray = event.current;
    final color = tray == null
        ? AppColors.primary
        : ColorUtils.fromHex(_trayHex(tray), fallback: AppColors.primary);
    final title = event.isExternal
        ? '外挂料位已完成进料'
        : event.isManual
        ? '没有 RFID，请告诉我换上的耗材'
        : tray?.isBambuOfficialRfid == true
        ? 'AMS 已识别 · ${tray!.trayType} ${tray.trayInfoIdx}'
        : '未识别标签 · 请手动选择';
    final detail = tray == null
        ? '请选择本次装入的是已有余料卷还是其他库存卷'
        : '${tray.traySubBrands.isEmpty ? '第三方或未知厂商' : tray.traySubBrands} · ${tray.trayColor.isEmpty ? '颜色未知' : _trayHex(tray)}';

    return AnimatedContainer(
      duration: AppMotion.duration(context, const Duration(milliseconds: 260)),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.9, end: 1),
            duration: AppMotion.duration(
              context,
              const Duration(milliseconds: 420),
            ),
            curve: Curves.easeOutBack,
            builder: (_, value, child) =>
                Transform.scale(scale: value, child: child),
            child: FilamentSpoolIcon(color: color, size: 42),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary,
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

class _SelectedInventoryEntry extends StatelessWidget {
  const _SelectedInventoryEntry({
    required this.selected,
    required this.loading,
    this.displayGrams,
    required this.onTap,
  });

  final Consumable? selected;
  final bool loading;
  final double? displayGrams;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final item = selected;
    final color = item == null
        ? AppColors.primary
        : ColorUtils.fromHex(item.colorHex, fallback: AppColors.primary);
    return Material(
      key: const ValueKey('choose-spool-change-consumable'),
      color: item == null
          ? AppColors.surfaceVariant
          : color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          constraints: const BoxConstraints(minHeight: 66),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: item == null
                  ? AppColors.outline
                  : color.withValues(alpha: 0.32),
            ),
          ),
          child: Row(
            children: [
              if (loading)
                const SizedBox.square(
                  dimension: 38,
                  child: Padding(
                    padding: EdgeInsets.all(9),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (item == null)
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.11),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.inventory_2_outlined,
                    color: AppColors.primary,
                    size: 20,
                  ),
                )
              else
                FilamentSpoolIcon(color: color, size: 40, dimensional: true),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loading
                          ? '正在读取库存'
                          : item == null
                          ? '打开耗材库选择'
                          : '${item.manufacturer} · ${item.model}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item == null
                          ? '按品牌浏览，也可以在选择窗口中新建耗材'
                          : '${item.materialType} · '
                                '${item.colorName ?? item.colorHex} · '
                                '本卷 ${GramUtils.formatGrams(displayGrams ?? singleRollAvailableGrams(item.remainingGrams))}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                item == null ? Icons.chevron_right_rounded : Icons.edit_rounded,
                size: 19,
                color: onTap == null
                    ? AppColors.textTertiary
                    : AppColors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _trayHex(AmsTray tray) {
  final raw = tray.trayColor.trim();
  if (raw.length >= 6) return '#${raw.substring(0, 6)}';
  return '#FFFFFF';
}

bool _hasAvailableRoll(
  Consumable item,
  Map<int, int> boundCounts, {
  required bool individualSpool,
}) {
  if (item.remainingGrams <= 0) return false;
  final physicalRolls = inventoryRollCount(
    item.remainingGrams,
    individualSpool: individualSpool,
  );
  return (boundCounts[item.id] ?? 0) < physicalRolls;
}

int _spoolMatchScore(Consumable item, AmsTray? tray) {
  if (tray == null) return 0;
  var score = 0;
  if (tray.trayUuid.isNotEmpty && item.trayUuid == tray.trayUuid) score += 10;
  if (tray.trayInfoIdx.isNotEmpty && item.model == tray.trayInfoIdx) score += 3;
  if (tray.trayType.isNotEmpty &&
      item.materialType.trim().toLowerCase() ==
          tray.trayType.trim().toLowerCase()) {
    score += 2;
  }
  if (tray.trayColor.length >= 6 &&
      item.colorHex.trim().toLowerCase() == _trayHex(tray).toLowerCase()) {
    score += 3;
  }
  if (tray.traySubBrands.isNotEmpty &&
      item.manufacturer.trim().toLowerCase() ==
          tray.traySubBrands.trim().toLowerCase()) {
    score += 1;
  }
  return score;
}
