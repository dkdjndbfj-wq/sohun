import 'package:flutter/material.dart';
import '../../core/theme/glass_button_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_curves.dart';
import '../../core/theme/interaction_effects.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/gram_utils.dart';
import '../../data/database/database.dart';
import '../../data/database/daos/consumable_dao.dart' show gramsPerRoll;
import '../../data/external/slicer/filament_change_point.dart';
import '../../data/external/slicer/slice_result.dart';
import '../../providers/consumable_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/external_multicolor_plan_provider.dart';
import '../../providers/print_task_provider.dart';
import '../../widgets/filament_spool_icon.dart';
import 'external_consumable_picker_dialog.dart';

class ExternalMulticolorPlanDialog extends ConsumerStatefulWidget {
  const ExternalMulticolorPlanDialog({super.key, required this.request});

  final ExternalMulticolorPlanRequest request;

  static Future<void> show(
    BuildContext context,
    ExternalMulticolorPlanRequest request,
  ) {
    if (request.farmMode) return Future<void>.value();
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '外挂多色耗材方案',
      barrierColor: Colors.black.withValues(alpha: 0.38),
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
      pageBuilder: (_, __, ___) =>
          ExternalMulticolorPlanDialog(request: request),
    );
  }

  @override
  ConsumerState<ExternalMulticolorPlanDialog> createState() =>
      _ExternalMulticolorPlanDialogState();
}

class _ExternalMulticolorPlanDialogState
    extends ConsumerState<ExternalMulticolorPlanDialog> {
  final Map<int, int> _selected = {};
  bool _saving = false;
  int? _restockingConsumableId;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(consumablesProvider).valueOrNull ?? const [];
    final inventoryById = {for (final item in inventory) item.id: item};
    final capacityGroups = _buildCapacityGroups(
      filaments: widget.request.filaments,
      selected: _selected,
      inventory: inventory,
    );
    final visibleCapacityGroups = capacityGroups
        .where((group) => group.toolIndices.length > 1 || group.isShort)
        .toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
              child: Material(
                color: isDark ? AppColors.surfaceDark : AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Header(request: widget.request),
                      const SizedBox(height: 14),
                      _ChangeSequence(
                        points: widget.request.changePoints,
                        filaments: widget.request.filaments,
                      ),
                      const SizedBox(height: 14),
                      Flexible(
                        fit: FlexFit.loose,
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: widget.request.filaments.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 9),
                          itemBuilder: (context, index) {
                            final filament = widget.request.filaments[index];
                            final selectedId = _selected[filament.toolIndex];
                            final selectedItem = inventoryById[selectedId];
                            return _FilamentMappingRow(
                              key: ValueKey(
                                'external-tool-${filament.toolIndex}',
                              ),
                              filament: filament,
                              selectedItem: selectedItem,
                              sharedToolIndices: selectedItem == null
                                  ? const []
                                  : _sharedToolsFor(filament.toolIndex),
                              onChoose: () => _chooseConsumable(filament),
                            );
                          },
                        ),
                      ),
                      if (visibleCapacityGroups.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        _CapacitySummary(
                          groups: visibleCapacityGroups,
                          restockingConsumableId: _restockingConsumableId,
                          onRestock: _restockSameConsumable,
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _error!,
                          key: const ValueKey('external-plan-error'),
                          style: const TextStyle(
                            color: AppColors.danger,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(
                            Icons.inventory_2_outlined,
                            size: 16,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 7),
                          const Expanded(
                            child: Text(
                              '确认后，实时消耗和完工修正会分别写入这些库存卷材。',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            key: const ValueKey('confirm-external-plan'),
                            onPressed: _saving ? null : _confirm,
                            icon: _saving
                                ? Builder(
                                    builder: (context) => SizedBox.square(
                                      dimension: 15,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color:
                                            GlassButtonsTheme.enabledOf(context)
                                            ? IconTheme.of(context).color
                                            : Colors.white,
                                      ),
                                    ),
                                  )
                                : const Icon(Icons.check_rounded, size: 18),
                            label: const Text('确认耗材方案'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _chooseConsumable(FilamentUsage filament) async {
    final selected = await ExternalConsumablePickerDialog.show(
      context,
      filament: filament,
      selectedId: _selected[filament.toolIndex],
      assignedGramsByConsumable: _assignedGramsExcluding(filament.toolIndex),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _selected[filament.toolIndex] = selected.id;
      _error = null;
    });
  }

  Future<void> _confirm() async {
    final requiredTools = widget.request.filaments
        .map((item) => item.toolIndex)
        .toSet();
    if (!_selected.keys.toSet().containsAll(requiredTools)) {
      setState(() => _error = '请为每一种外置颜色选择库存耗材，或先新建一卷。');
      return;
    }
    final inventory = ref.read(consumablesProvider).valueOrNull ?? const [];
    final inventoryIds = inventory.map((item) => item.id).toSet();
    if (!_selected.values.every(inventoryIds.contains)) {
      setState(() => _error = '已选耗材的库存记录发生变化，请重新选择。');
      return;
    }
    final shortages = _buildCapacityGroups(
      filaments: widget.request.filaments,
      selected: _selected,
      inventory: inventory,
    ).where((group) => group.isShort);
    if (shortages.isNotEmpty) {
      final shortage = shortages.first;
      setState(() {
        _error =
            '${shortage.consumable.manufacturer} ${shortage.consumable.model} '
            '还差 ${GramUtils.formatGrams(shortage.shortageGrams)}，'
            '请先补入同款卷或重新分配。';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(printTaskOrchestratorProvider.notifier)
          .applyExternalMulticolorPlan(
            taskId: widget.request.taskId,
            toolConsumableIds: Map<int, int>.from(_selected),
          );
      ref
          .read(externalMulticolorPlanQueueProvider.notifier)
          .resolve(widget.request.requestId);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _restockSameConsumable(_CapacityGroup group) async {
    if (_restockingConsumableId != null) return;
    final rolls = (group.shortageGrams / gramsPerRoll).ceil().clamp(1, 999);
    setState(() {
      _restockingConsumableId = group.consumable.id;
      _error = null;
    });
    try {
      await ref
          .read(consumableDaoProvider)
          .addRolls(group.consumable.id, rolls);
    } catch (error) {
      if (mounted) setState(() => _error = '补入同款卷失败：$error');
    } finally {
      if (mounted) setState(() => _restockingConsumableId = null);
    }
  }

  List<int> _sharedToolsFor(int toolIndex) {
    final consumableId = _selected[toolIndex];
    if (consumableId == null) return const [];
    return _selected.entries
        .where((entry) => entry.value == consumableId)
        .map((entry) => entry.key)
        .toList()
      ..sort();
  }

  Map<int, double> _assignedGramsExcluding(int excludedToolIndex) {
    final result = <int, double>{};
    for (final filament in widget.request.filaments) {
      if (filament.toolIndex == excludedToolIndex) continue;
      final consumableId = _selected[filament.toolIndex];
      if (consumableId == null) continue;
      result.update(
        consumableId,
        (grams) => grams + filament.grams,
        ifAbsent: () => filament.grams,
      );
    }
    return result;
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.request});

  final ExternalMulticolorPlanRequest request;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.swap_calls_rounded, color: AppColors.primary),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '确认外挂多色耗材',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              Text(
                '${request.printerLabel} · ${request.taskName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '${request.filaments.length} 种外置颜色',
            style: const TextStyle(
              color: AppColors.warning,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _ChangeSequence extends StatelessWidget {
  const _ChangeSequence({required this.points, required this.filaments});

  final List<FilamentChangePoint> points;
  final List<FilamentUsage> filaments;

  @override
  Widget build(BuildContext context) {
    final hasUnknownTargets = points.any((point) => point.toolIndex < 0);
    final sequence = <int>[];
    if (!hasUnknownTargets &&
        points.isNotEmpty &&
        points.first.previousToolIndex != null) {
      sequence.add(points.first.previousToolIndex!);
    }
    if (!hasUnknownTargets) {
      for (final point in points) {
        if (point.toolIndex >= 0) sequence.add(point.toolIndex);
        if (sequence.length >= 8) break;
      }
    }
    if (sequence.isEmpty) {
      sequence.addAll(filaments.map((item) => item.toolIndex));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Text(
            hasUnknownTargets ? '切片颜色' : '换色顺序',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var index = 0; index < sequence.length; index++) ...[
                    if (index > 0)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 5),
                        child: Icon(Icons.chevron_right_rounded, size: 15),
                      ),
                    _ToolDot(
                      toolIndex: sequence[index],
                      colorHex: _colorForTool(
                        sequence[index],
                        points,
                        filaments,
                      ),
                    ),
                  ],
                  if (points.length + 1 > sequence.length)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        '共 ${points.length} 次',
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolDot extends StatelessWidget {
  const _ToolDot({required this.toolIndex, required this.colorHex});

  final int toolIndex;
  final String? colorHex;

  @override
  Widget build(BuildContext context) {
    final color = ColorUtils.fromHex(colorHex ?? '#8A8A8A');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black26),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          'T$toolIndex',
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _FilamentMappingRow extends StatelessWidget {
  const _FilamentMappingRow({
    super.key,
    required this.filament,
    required this.selectedItem,
    required this.sharedToolIndices,
    required this.onChoose,
  });

  final FilamentUsage filament;
  final Consumable? selectedItem;
  final List<int> sharedToolIndices;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final color = ColorUtils.fromHex(filament.colorHex ?? '#8A8A8A');
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final identity = Row(
            children: [
              FilamentSpoolIcon(color: color, size: 40),
              const SizedBox(width: 11),
              Expanded(child: _FilamentIdentity(filament: filament)),
            ],
          );
          final selector = _SelectedConsumableButton(
            filament: filament,
            selectedItem: selectedItem,
            sharedToolIndices: sharedToolIndices,
            onPressed: onChoose,
          );
          if (constraints.maxWidth < 520) {
            return Column(
              children: [identity, const SizedBox(height: 9), selector],
            );
          }
          return Row(
            children: [
              SizedBox(width: 205, child: identity),
              const SizedBox(width: 10),
              Expanded(child: selector),
            ],
          );
        },
      ),
    );
  }
}

class _FilamentIdentity extends StatelessWidget {
  const _FilamentIdentity({required this.filament});

  final FilamentUsage filament;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'T${filament.toolIndex} · ${filament.colorHex ?? '颜色未知'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 3),
        Text(
          '${filament.materialType ?? '材质未知'} · 预计 ${GramUtils.formatGrams(filament.grams)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _SelectedConsumableButton extends StatelessWidget {
  const _SelectedConsumableButton({
    required this.filament,
    required this.selectedItem,
    required this.sharedToolIndices,
    required this.onPressed,
  });

  final FilamentUsage filament;
  final Consumable? selectedItem;
  final List<int> sharedToolIndices;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final item = selectedItem;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = item == null
        ? AppColors.primary
        : ColorUtils.fromHex(item.colorHex);
    final sharedLabel = sharedToolIndices.length > 1
        ? '${sharedToolIndices.map((tool) => 'T$tool').join('、')} 共用'
        : null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('choose-consumable-tool-${filament.toolIndex}'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(9),
        child: Ink(
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: color.withValues(alpha: item == null ? 0.055 : 0.075),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: color.withValues(alpha: item == null ? 0.24 : 0.34),
            ),
          ),
          child: Row(
            children: [
              if (item == null)
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.inventory_2_outlined,
                    size: 18,
                    color: AppColors.primary,
                  ),
                )
              else
                FilamentSpoolIcon(color: color, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: item == null
                    ? const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '选择库存耗材',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            '按品牌浏览耗材库',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 9.5,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${item.manufacturer} · ${item.colorName ?? item.colorHex}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${item.materialType} · ${GramUtils.formatGrams(item.remainingGrams)}'
                            '${sharedLabel == null ? '' : ' · $sharedLabel'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: sharedLabel == null
                                  ? (isDark
                                        ? AppColors.textSecondaryDark
                                        : AppColors.textSecondary)
                                  : AppColors.primary,
                              fontSize: 9.5,
                              fontWeight: sharedLabel == null
                                  ? FontWeight.w500
                                  : FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 7),
              Icon(
                Icons.chevron_right_rounded,
                size: 19,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CapacityGroup {
  const _CapacityGroup({
    required this.consumable,
    required this.toolIndices,
    required this.estimatedGrams,
  });

  final Consumable consumable;
  final List<int> toolIndices;
  final double estimatedGrams;

  double get shortageGrams => estimatedGrams - consumable.remainingGrams;
  bool get isShort => shortageGrams > 0.01;
}

List<_CapacityGroup> _buildCapacityGroups({
  required List<FilamentUsage> filaments,
  required Map<int, int> selected,
  required List<Consumable> inventory,
}) {
  final itemsById = {for (final item in inventory) item.id: item};
  final toolsById = <int, List<int>>{};
  final gramsById = <int, double>{};
  for (final filament in filaments) {
    final consumableId = selected[filament.toolIndex];
    if (consumableId == null || !itemsById.containsKey(consumableId)) continue;
    toolsById.putIfAbsent(consumableId, () => []).add(filament.toolIndex);
    gramsById.update(
      consumableId,
      (grams) => grams + filament.grams,
      ifAbsent: () => filament.grams,
    );
  }
  return [
    for (final entry in toolsById.entries)
      _CapacityGroup(
        consumable: itemsById[entry.key]!,
        toolIndices: entry.value..sort(),
        estimatedGrams: gramsById[entry.key]!,
      ),
  ];
}

class _CapacitySummary extends StatelessWidget {
  const _CapacitySummary({
    required this.groups,
    required this.restockingConsumableId,
    required this.onRestock,
  });

  final List<_CapacityGroup> groups;
  final int? restockingConsumableId;
  final ValueChanged<_CapacityGroup> onRestock;

  @override
  Widget build(BuildContext context) {
    final hasShortage = groups.any((group) => group.isShort);
    final accent = hasShortage ? AppColors.warning : AppColors.primary;
    return Container(
      key: const ValueKey('external-capacity-summary'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.075),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          for (var index = 0; index < groups.length; index++) ...[
            if (index > 0) const SizedBox(height: 7),
            _CapacityLine(
              group: groups[index],
              adding: restockingConsumableId == groups[index].consumable.id,
              onRestock: () => onRestock(groups[index]),
            ),
          ],
        ],
      ),
    );
  }
}

class _CapacityLine extends StatelessWidget {
  const _CapacityLine({
    required this.group,
    required this.adding,
    required this.onRestock,
  });

  final _CapacityGroup group;
  final bool adding;
  final VoidCallback onRestock;

  @override
  Widget build(BuildContext context) {
    final tools = group.toolIndices.map((tool) => 'T$tool').join(' + ');
    final rolls = (group.shortageGrams / gramsPerRoll).ceil().clamp(1, 999);
    return Row(
      children: [
        Icon(
          group.isShort ? Icons.warning_amber_rounded : Icons.link_rounded,
          size: 17,
          color: group.isShort ? AppColors.warning : AppColors.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            group.isShort
                ? '$tools 共用 · 预计 ${GramUtils.formatGrams(group.estimatedGrams)} / '
                      '库存 ${GramUtils.formatGrams(group.consumable.remainingGrams)} · '
                      '还差 ${GramUtils.formatGrams(group.shortageGrams)}'
                : '$tools 共用 · 预计 ${GramUtils.formatGrams(group.estimatedGrams)} / '
                      '库存 ${GramUtils.formatGrams(group.consumable.remainingGrams)}',
            style: TextStyle(
              color: group.isShort ? AppColors.warning : AppColors.primary,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (group.isShort) ...[
          const SizedBox(width: 8),
          TextButton.icon(
            key: ValueKey('restock-${group.consumable.id}'),
            onPressed: adding ? null : onRestock,
            icon: adding
                ? const SizedBox.square(
                    dimension: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded, size: 16),
            label: Text('补入 $rolls 卷同款'),
          ),
        ],
      ],
    );
  }
}

String? _colorForTool(
  int tool,
  List<FilamentChangePoint> points,
  List<FilamentUsage> filaments,
) {
  for (final filament in filaments) {
    if (filament.toolIndex == tool) return filament.colorHex;
  }
  for (final point in points) {
    if (point.toolIndex == tool) return point.colorHex;
  }
  return null;
}
