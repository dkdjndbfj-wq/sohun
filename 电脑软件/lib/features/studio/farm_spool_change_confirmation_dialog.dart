import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/spool_change_detector.dart';
import '../../core/utils/color_utils.dart';
import '../../data/database/database.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../providers/database_provider.dart';
import '../../providers/spool_change_provider.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_theme.dart';
import 'farm_ui/farm_feedback.dart';
import 'farm_inventory_stock.dart';

/// Farm-only confirmation for third-party or unidentified physical spools.
///
/// This dialog deliberately does not import the personal inventory provider,
/// personal spool picker, or personal remaining-weight editor. Official RFID
/// loads are handled automatically; manual confirmation deducts exactly one
/// unopened roll from the selected farm SKU.
class FarmSpoolChangeConfirmationDialog extends ConsumerStatefulWidget {
  const FarmSpoolChangeConfirmationDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const FarmSpoolChangeConfirmationDialog(),
    );
  }

  @override
  ConsumerState<FarmSpoolChangeConfirmationDialog> createState() =>
      _FarmSpoolChangeConfirmationDialogState();
}

class _FarmSpoolChangeConfirmationDialogState
    extends ConsumerState<FarmSpoolChangeConfirmationDialog> {
  final Map<String, int> _selectedIds = {};
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final events = ref.watch(
      spoolChangeQueueProvider.select(
        (events) =>
            events.where((event) => event.farmMode).toList(growable: false),
      ),
    );
    final inventory = ref.watch(farmConsumablesProvider);
    final canConfirm =
        ref.watch(currentFarmPermissionProvider('inventory.adjust'));
    ref.listen<List<SpoolChangeObservation>>(spoolChangeQueueProvider,
        (_, next) {
      if (!next.any((event) => event.farmMode) && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        });
      }
    });

    if (events.isEmpty) return const SizedBox.shrink();
    final event = events.first;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.warehouse_outlined),
          const SizedBox(width: 9),
          const Expanded(child: Text('农场第三方耗材确认')),
          if (events.length > 1)
            Chip(
              label: Text('还有 ${events.length - 1} 个槽位'),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: inventory.when(
          loading: () => const SizedBox(
            height: 220,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => SizedBox(
            height: 220,
            child: Center(child: Text('农场库存读取失败：$error')),
          ),
          data: (items) => _FarmSpoolChangeContent(
            event: event,
            items: items,
            selectedId: _selectedIds[event.eventId],
            enabled: !_busy && canConfirm,
            onSelected: (id) {
              setState(() => _selectedIds[event.eventId] = id);
            },
          ),
        ),
      ),
      actions: [
        if (!canConfirm)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Text(
              '需要当前农场成员确认',
              style: TextStyle(color: FarmVisual.warning),
            ),
          ),
        TextButton.icon(
          onPressed: _busy
              ? null
              : () => ref.read(spoolChangeQueueProvider.notifier).snooze(event),
          icon: const Icon(Icons.schedule_outlined, size: 17),
          label: const Text('稍后处理'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => ref
                  .read(spoolChangeQueueProvider.notifier)
                  .resolve(event.eventId),
          child: const Text('还是原来的卷'),
        ),
        FilledButton.icon(
          onPressed: !canConfirm || _busy || _selectedIds[event.eventId] == null
              ? null
              : () => _confirmFarmLoad(
                    event,
                    _selectedIds[event.eventId]!,
                  ),
          icon: _busy
              ? const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.inventory_2_outlined, size: 17),
          label: const Text('确认并扣仓库 1 卷'),
        ),
      ],
    );
  }

  Future<void> _confirmFarmLoad(
    SpoolChangeObservation event,
    int consumableId,
  ) async {
    if (_busy || !event.farmMode) return;
    setState(() => _busy = true);
    try {
      final dao = ref.read(printerDaoProvider);
      final printerId = event.printerId ??
          await dao.getPrinterIdBySerial(event.printerSerial);
      if (printerId == null) throw StateError('找不到农场打印机记录');
      await dao.bindSpoolReplacement(
        printerId: printerId,
        channelIndex: event.channelIndex,
        consumableId: consumableId,
        uniquePhysicalSpool: event.current?.isBambuOfficialRfid == true,
        farmOwnerConfirmed: event.current?.isBambuOfficialRfid != true,
      );
      ref.read(spoolChangeQueueProvider.notifier).resolve(event.eventId);
      if (mounted) {
        showSnack(context, '农场仓库已扣 1 卷，槽位从 1000g 开始计算');
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, '农场装料确认失败：$error', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _FarmSpoolChangeContent extends StatelessWidget {
  const _FarmSpoolChangeContent({
    required this.event,
    required this.items,
    required this.selectedId,
    required this.enabled,
    required this.onSelected,
  });

  final SpoolChangeObservation event;
  final List<Consumable> items;
  final int? selectedId;
  final bool enabled;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final available = groupFarmWarehouseMaterials(items)
        .where((group) => group.availableRolls > 0)
        .toList(growable: false);
    final tray = event.current;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(FarmPalette.radius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${event.printerLabel} · ${event.slotLabel}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 5),
              Text(
                tray?.isBambuOfficialRfid == true
                    ? '已检测到拓竹官方 RFID；正常情况下系统会自动完成扣库。'
                    : '未检测到可用 RFID，必须由当前成员确认实际装入的耗材。',
              ),
              if (tray?.trayType.trim().isNotEmpty == true)
                Text(
                  '设备上报：${tray!.trayType} · ${_farmTrayHex(tray)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '选择农场仓库耗材',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 7),
        if (available.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(child: Text('农场仓库没有可用整卷，请先到“批量库存”入库')),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: available.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final group = available[index];
                final item = group.representative;
                final backingItem = group.nextWholeRoll!;
                final selected = group.containsConsumable(selectedId);
                return ListTile(
                  enabled: enabled,
                  selected: selected,
                  leading: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: ColorUtils.fromHex(item.colorHex),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                  title: Text('${item.manufacturer} · ${item.materialType}'),
                  subtitle: Text(
                    '${item.model} · ${item.colorName ?? item.colorHex} · '
                    '仓库 ${group.availableRolls} 卷'
                    '${group.batchCount > 1 ? ' · ${group.batchCount} 个批次' : ''}',
                  ),
                  trailing:
                      selected ? const Icon(Icons.check_circle_rounded) : null,
                  onTap: enabled ? () => onSelected(backingItem.id) : null,
                );
              },
            ),
          ),
      ],
    );
  }
}

String _farmTrayHex(AmsTray tray) {
  final raw = tray.trayColor.trim();
  if (raw.length < 6) return '#FFFFFF';
  return '#${raw.substring(0, 6).toUpperCase()}';
}
