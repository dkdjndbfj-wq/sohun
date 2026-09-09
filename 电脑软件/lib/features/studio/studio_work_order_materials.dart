import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/material_identity_service.dart';
import '../../data/database/database.dart';
import '../../data/database/models/studio_models.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_feedback.dart';
import 'farm_inventory_stock.dart';

class StudioWorkOrderMaterialSummary extends StatelessWidget {
  const StudioWorkOrderMaterialSummary({
    super.key,
    required this.materials,
    this.onManage,
  });

  final List<StudioWorkOrderMaterial> materials;
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    if (materials.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final allSettled = materials.every((item) => item.isSettled);
    final allAllocated = materials.every((item) => item.isAllocated);
    final total = materials.fold<double>(
      0,
      (sum, item) =>
          sum + (allSettled ? item.consumedGrams : item.estimatedGrams),
    );
    final failedLoss = materials.fold<double>(
      0,
      (sum, item) => sum + (allSettled ? 0 : item.consumedGrams),
    );
    final label = allSettled
        ? '耗材已结算 ${total.toStringAsFixed(1)} g'
        : allAllocated
            ? failedLoss > 0.01
                ? '失败损耗 ${failedLoss.toStringAsFixed(1)} g · 重打预留 ${total.toStringAsFixed(1)} g'
                : '已预留 ${total.toStringAsFixed(1)} g'
            : '待分配 ${materials.length} 个耗材通道';
    final color = allSettled
        ? colors.primary
        : allAllocated
            ? Colors.green
            : colors.error;
    return Padding(
      padding: const EdgeInsets.only(top: 5, left: 8, right: 8),
      child: Row(
        key: const Key('studio-work-order-material-summary'),
        children: [
          Icon(
            allSettled ? Icons.inventory_2_rounded : Icons.inventory_2_outlined,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          if (onManage != null)
            IconButton(
              key: const Key('studio-manage-work-order-materials'),
              tooltip: allSettled ? '查看耗材结算' : '分配耗材卷',
              onPressed: onManage,
              visualDensity: VisualDensity.compact,
              iconSize: 17,
              icon: Icon(allSettled ? Icons.receipt_long : Icons.tune_rounded),
            ),
        ],
      ),
    );
  }
}

Future<bool> showStudioMaterialAllocationDialog(
  BuildContext context,
  WidgetRef ref, {
  required StudioWorkOrder workOrder,
  required List<StudioWorkOrderMaterial> materials,
}) async {
  if (materials.isEmpty) {
    showSnack(context, '该工单还没有切片耗材需求', error: true);
    return false;
  }
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _MaterialAllocationDialog(
      workOrder: workOrder,
      initialMaterials: materials,
    ),
  );
  return result ?? false;
}

Future<void> updateStudioWorkOrderProgressWithMaterials(
  BuildContext context,
  WidgetRef ref, {
  required StudioSnapshot studio,
  required StudioWorkOrder workOrder,
  required int completedQuantity,
  required StudioWorkOrderStatus status,
}) async {
  try {
    var materials = studio.workOrderMaterials
        .where((item) => item.workOrderId == workOrder.id)
        .toList();
    if (status == StudioWorkOrderStatus.completed &&
        materials.isNotEmpty &&
        !materials.every((item) => item.isSettled)) {
      if (materials.any((item) => !item.isAllocated)) {
        final allocated = await showStudioMaterialAllocationDialog(
          context,
          ref,
          workOrder: workOrder,
          materials: materials,
        );
        if (!allocated || !context.mounted) return;
        final refreshed =
            await ref.read(studioDaoProvider).getDefaultSnapshot();
        materials = refreshed.workOrderMaterials
            .where((item) => item.workOrderId == workOrder.id)
            .toList();
      }
      if (!context.mounted) return;
      final actual = await showDialog<Map<int, double>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _MaterialSettlementDialog(materials: materials),
      );
      if (actual == null) return;
      await ref.read(studioDaoProvider).updateWorkOrderProgress(
            id: workOrder.id,
            completedQuantity: completedQuantity,
            status: status,
            actualGramsByTool: actual,
          );
      if (context.mounted) showSnack(context, '工单已完成，实际耗材已结算');
      return;
    }
    await ref.read(studioDaoProvider).updateWorkOrderProgress(
          id: workOrder.id,
          completedQuantity: completedQuantity,
          status: status,
        );
  } catch (error) {
    if (context.mounted) showSnack(context, '$error', error: true);
  }
}

/// Completes a farm work order from the manual pickup gate. Returning false
/// keeps the queue in waiting_removal, so the next print cannot start.
Future<bool> settleStudioWorkOrderForQueue(
  BuildContext context,
  WidgetRef ref,
  String workOrderId,
) async {
  try {
    final snapshot = await ref.read(studioDaoProvider).getDefaultSnapshot();
    if (!context.mounted) return false;
    final workOrder =
        snapshot.workOrders.where((item) => item.id == workOrderId).firstOrNull;
    if (workOrder == null) {
      showSnack(context, '关联的农场工单不存在', error: true);
      return false;
    }
    if (workOrder.status == StudioWorkOrderStatus.completed) return true;
    var materials = snapshot.workOrderMaterials
        .where((item) => item.workOrderId == workOrderId)
        .toList();
    if (materials.any((item) => !item.isAllocated)) {
      final allocated = await showStudioMaterialAllocationDialog(
        context,
        ref,
        workOrder: workOrder,
        materials: materials,
      );
      if (!allocated || !context.mounted) return false;
      final refreshed = await ref.read(studioDaoProvider).getDefaultSnapshot();
      materials = refreshed.workOrderMaterials
          .where((item) => item.workOrderId == workOrderId)
          .toList();
    }
    if (!context.mounted) return false;
    Map<int, double>? actual;
    if (materials.isNotEmpty && !materials.every((item) => item.isSettled)) {
      actual = await showDialog<Map<int, double>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _MaterialSettlementDialog(materials: materials),
      );
      if (actual == null) return false;
    }
    await ref.read(studioDaoProvider).updateWorkOrderProgress(
          id: workOrder.id,
          completedQuantity: workOrder.quantity,
          status: StudioWorkOrderStatus.completed,
          actualGramsByTool: actual,
        );
    if (context.mounted) showSnack(context, '工单已结算，可以开始下一个任务');
    return true;
  } catch (error) {
    if (context.mounted) showSnack(context, '$error', error: true);
    return false;
  }
}

class _MaterialAllocationDialog extends ConsumerStatefulWidget {
  const _MaterialAllocationDialog({
    required this.workOrder,
    required this.initialMaterials,
  });

  final StudioWorkOrder workOrder;
  final List<StudioWorkOrderMaterial> initialMaterials;

  @override
  ConsumerState<_MaterialAllocationDialog> createState() =>
      _MaterialAllocationDialogState();
}

class _MaterialAllocationDialogState
    extends ConsumerState<_MaterialAllocationDialog> {
  final Map<int, int?> _selectedByTool = {};
  final Map<int, StudioConsumableAvailability> _availability = {};
  List<Consumable> _inventory = const [];
  bool _loading = true;
  bool _saving = false;

  List<Consumable> get _consumables => _inventory;

  @override
  void initState() {
    super.initState();
    for (final material in widget.initialMaterials) {
      _selectedByTool[material.toolIndex] = material.consumableId;
    }
    _loadAvailability();
  }

  Future<void> _loadAvailability() async {
    try {
      final inventory = await ref.read(farmConsumablesProvider.future);
      final dao = ref.read(studioDaoProvider);
      final values = <int, StudioConsumableAvailability>{};
      for (final consumable in inventory) {
        values[consumable.id] = await dao.getConsumableAvailability(
          consumable.id,
          workspaceId: widget.workOrder.workspaceId,
          excludingWorkOrderId: widget.workOrder.id,
        );
      }
      if (!mounted) return;
      setState(() {
        _inventory = inventory;
        _availability
          ..clear()
          ..addAll(values);
        for (final material in widget.initialMaterials) {
          if (_selectedByTool[material.toolIndex] != null) continue;
          final candidates = _candidates(material)
              .where(
                (item) =>
                    item.backingAvailableGrams + 0.0001 >=
                    material.estimatedGrams,
              )
              .toList();
          if (candidates.length == 1) {
            _selectedByTool[material.toolIndex] =
                candidates.single.backingItem.id;
          }
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showSnack(context, '读取库存失败：$error', error: true);
    }
  }

  List<_MaterialAllocationOption> _candidates(
    StudioWorkOrderMaterial material,
  ) {
    final type = material.materialType?.trim();
    final color = _normalizedColor(material.colorHex);
    final matching = _consumables.where((item) {
      final typeMatches = type == null ||
          type.isEmpty ||
          MaterialIdentityService.sameFamily(item.materialType, type);
      final colorMatches =
          color == null || _normalizedColor(item.colorHex) == color;
      return typeMatches &&
          colorMatches &&
          (item.remainingGrams > 0 || item.id == material.consumableId);
    });
    return [
      for (final group in groupFarmWarehouseMaterials(matching))
        if (group.bestReservationCandidate(
          (item) =>
              _availability[item.id]?.availableGrams ?? item.remainingGrams,
          selectedId: _selectedByTool[material.toolIndex],
        )
            case final backing?)
          _MaterialAllocationOption(
            group: group,
            backingItem: backing,
            availableByConsumable: _availability,
          ),
    ];
  }

  Future<void> _save() async {
    final mapping = <int, int>{};
    for (final material in widget.initialMaterials) {
      final selected = _selectedByTool[material.toolIndex];
      if (selected == null) {
        showSnack(context, '请为通道 ${material.toolIndex + 1} 选择耗材卷', error: true);
        return;
      }
      mapping[material.toolIndex] = selected;
    }
    setState(() => _saving = true);
    try {
      await ref.read(studioDaoProvider).reserveWorkOrderMaterials(
            workOrderId: widget.workOrder.id,
            consumableByTool: mapping,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, '$error', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settled = widget.initialMaterials.every((item) => item.isSettled);
    return AlertDialog(
      title: Text(settled ? '耗材结算明细' : '分配工单耗材'),
      content: SizedBox(
        width: 680,
        child: _loading
            ? const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${widget.workOrder.title} · ${widget.workOrder.quantity} 次运行',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 12),
                    for (final material in widget.initialMaterials)
                      _MaterialAllocationRow(
                        material: material,
                        candidates: _candidates(material),
                        selectedId: _selectedByTool[material.toolIndex],
                        enabled: !settled && !_saving,
                        onChanged: (value) => setState(
                          () => _selectedByTool[material.toolIndex] = value,
                        ),
                      ),
                    if (!settled) ...[
                      const SizedBox(height: 8),
                      Text(
                        '仅列出与切片材质、颜色一致的仓库耗材；同品牌、型号、材质和颜色只显示一行。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(settled ? '关闭' : '取消'),
        ),
        if (!settled && widget.initialMaterials.any((item) => item.isAllocated))
          OutlinedButton.icon(
            onPressed: _saving
                ? null
                : () async {
                    setState(() => _saving = true);
                    await ref
                        .read(studioDaoProvider)
                        .releaseWorkOrderMaterials(widget.workOrder.id);
                    if (context.mounted) Navigator.of(context).pop(true);
                  },
            icon: const Icon(Icons.lock_open_rounded, size: 17),
            label: const Text('释放预留'),
          ),
        if (!settled)
          FilledButton.icon(
            onPressed: _loading || _saving ? null : _save,
            icon: const Icon(Icons.inventory_2_rounded, size: 17),
            label: Text(_saving ? '正在校验' : '确认预留'),
          ),
      ],
    );
  }
}

class _MaterialAllocationOption {
  const _MaterialAllocationOption({
    required this.group,
    required this.backingItem,
    required this.availableByConsumable,
  });

  final FarmWarehouseMaterialGroup group;
  final Consumable backingItem;
  final Map<int, StudioConsumableAvailability> availableByConsumable;

  double get backingAvailableGrams =>
      availableByConsumable[backingItem.id]?.availableGrams ??
      backingItem.remainingGrams;

  double get groupAvailableGrams => group.items.fold<double>(
        0,
        (sum, item) =>
            sum +
            (availableByConsumable[item.id]?.availableGrams ??
                item.remainingGrams),
      );

  String get label {
    final item = group.representative;
    return '${item.manufacturer} · ${item.model} · '
        '${item.colorName ?? item.colorHex} · '
        '同款可用 ${groupAvailableGrams.toStringAsFixed(1)} g';
  }
}

class _MaterialAllocationRow extends StatelessWidget {
  const _MaterialAllocationRow({
    required this.material,
    required this.candidates,
    required this.selectedId,
    required this.enabled,
    required this.onChanged,
  });

  final StudioWorkOrderMaterial material;
  final List<_MaterialAllocationOption> candidates;
  final int? selectedId;
  final bool enabled;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = candidates
        .where((item) => item.backingItem.id == selectedId)
        .firstOrNull;
    return Container(
      key: ValueKey('studio-material-tool-${material.toolIndex}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          _ColorSwatch(colorHex: material.colorHex),
          const SizedBox(width: 8),
          SizedBox(
            width: 190,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '通道 ${material.toolIndex + 1} · '
                  '${material.materialType?.trim().isNotEmpty == true ? material.materialType : '材质未标注'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  material.isSettled
                      ? '实际 ${material.consumedGrams.toStringAsFixed(2)} g'
                      : '需要 ${material.estimatedGrams.toStringAsFixed(2)} g',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: material.isSettled
                ? Text(
                    selected == null ? '原耗材已不在本机库存' : selected.label,
                  )
                : DropdownButtonFormField<int>(
                    key: ValueKey(
                      'studio-material-select-${material.toolIndex}',
                    ),
                    initialValue: candidates.any(
                      (item) => item.backingItem.id == selectedId,
                    )
                        ? selectedId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '仓库耗材',
                      isDense: true,
                    ),
                    items: [
                      for (final item in candidates)
                        DropdownMenuItem(
                          value: item.backingItem.id,
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: enabled ? onChanged : null,
                  ),
          ),
        ],
      ),
    );
  }
}

class _MaterialSettlementDialog extends StatefulWidget {
  const _MaterialSettlementDialog({required this.materials});

  final List<StudioWorkOrderMaterial> materials;

  @override
  State<_MaterialSettlementDialog> createState() =>
      _MaterialSettlementDialogState();
}

class _MaterialSettlementDialogState extends State<_MaterialSettlementDialog> {
  late final Map<int, TextEditingController> _controllers = {
    for (final item in widget.materials)
      item.toolIndex: TextEditingController(
        text: item.estimatedGrams.toStringAsFixed(2),
      ),
  };

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final values = <int, double>{};
    for (final item in widget.materials) {
      final parsed = double.tryParse(
        _controllers[item.toolIndex]!.text.trim().replaceAll(',', '.'),
      );
      if (parsed == null || !parsed.isFinite || parsed < 0) {
        showSnack(context, '通道 ${item.toolIndex + 1} 的实际克数无效', error: true);
        return;
      }
      values[item.toolIndex] = parsed;
    }
    Navigator.of(context).pop(values);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('确认实际耗材'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('按整个工单填写每个工具通道的实际用量，确认后将扣减对应库存卷。'),
              const SizedBox(height: 12),
              for (final item in widget.materials)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    key: ValueKey('studio-material-actual-${item.toolIndex}'),
                    controller: _controllers[item.toolIndex],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText:
                          '通道 ${item.toolIndex + 1} · ${item.materialType ?? '耗材'}',
                      suffixText: 'g',
                      helperText:
                          '切片估算 ${item.estimatedGrams.toStringAsFixed(2)} g',
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            key: const Key('studio-confirm-material-settlement'),
            onPressed: _submit,
            icon: const Icon(Icons.check_rounded),
            label: const Text('完成并扣减库存'),
          ),
        ],
      );
}

String? _normalizedColor(String? value) {
  final raw = value?.trim().toUpperCase();
  if (raw == null || raw.isEmpty) return null;
  final normalized = raw.startsWith('#') ? raw : '#$raw';
  return normalized.length == 9
      ? '#${normalized.substring(normalized.length - 6)}'
      : normalized;
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.colorHex});

  final String? colorHex;

  @override
  Widget build(BuildContext context) {
    final raw = colorHex?.replaceFirst('#', '') ?? '';
    final value = int.tryParse(raw.length == 6 ? 'FF$raw' : raw, radix: 16);
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: value == null
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : Color(value),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}
