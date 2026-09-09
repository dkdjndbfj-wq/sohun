import 'package:file_selector/file_selector.dart';
import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/friendly_error.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/services/printer_model_normalizer.dart';
import '../../data/database/daos/printer_dao.dart';
import '../../data/database/models/scheduler_models.dart';
import '../../providers/database_provider.dart' show printerDaoProvider;
import '../../providers/printer_provider.dart';
import '../../providers/scheduler_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/app_input.dart';
import '../../widgets/app_select.dart';
import '../../widgets/app_switch.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/confirm_dialog.dart' show showSnack;
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';
import '../../widgets/icon_action_button.dart';

/// 跨打印机智能调度页。
///
/// 顶部：自动调度开关 + "添加任务"按钮 + "立即调度"按钮。
/// 任务列表：每项显示文件名、机型组徽章、材质、状态、操作（删除/手动分配/取消）。
///
/// 调度器只把任务分配到同机型组打印机（拓竹不同机型 gcode 不兼容是硬约束）。
class SchedulerScreen extends ConsumerWidget {
  const SchedulerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(schedulerTasksProvider);
    final printersAsync = ref.watch(printersWithChannelsProvider);
    final autoEnabled = ref.watch(autoScheduleEnabledProvider);

    Future<void> autoSchedule() async {
      try {
        await ref.read(schedulerNotifierProvider.notifier).autoSchedule();
        if (context.mounted) showSnack(context, '已尝试自动分配待调度任务');
      } catch (e) {
        if (context.mounted) {
          showSnack(context, '调度失败: ${friendlyError(e)}', error: true);
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.all(ExperienceTokens.pageGutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExperiencePageHeader(
            title: '任务调度场',
            description: '任务在左侧等待，打印机在右侧接单。拖动任务到精确匹配的设备，或让系统依据机型、喷嘴与耗材状态自动安排。',
            actions: [
              _AutoScheduleToggle(
                value: autoEnabled,
                onChanged: (value) => ref
                    .read(autoScheduleEnabledProvider.notifier)
                    .setEnabled(value),
              ),
              AppButton(
                label: '立即调度',
                variant: AppButtonVariant.secondary,
                icon: const Icon(Icons.auto_mode_rounded, size: 16),
                onPressed: autoSchedule,
              ),
              AppButton(
                label: '添加任务',
                icon: const Icon(Icons.add_rounded, size: 16),
                onPressed: () => _showAddTaskDialog(context, ref),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: tasksAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Text(
                  '加载失败: ${friendlyError(e)}',
                  style: const TextStyle(color: AppColors.danger),
                ),
              ),
              data: (tasks) => _SchedulerWorkspace(
                tasks: tasks,
                printers: printersAsync.valueOrNull ?? const [],
                printersLoading: printersAsync.isLoading,
                onAddTask: () => _showAddTaskDialog(context, ref),
                onReorder: (oldIndex, newIndex) {
                  if (oldIndex == newIndex) return;
                  final reordered = [...tasks];
                  final moved = reordered.removeAt(oldIndex);
                  reordered.insert(newIndex, moved);
                  final ids = reordered
                      .map((task) => task.id)
                      .whereType<int>()
                      .toList(growable: false);
                  if (ids.isNotEmpty) {
                    ref
                        .read(schedulerNotifierProvider.notifier)
                        .updateSortOrder(ids);
                  }
                },
                onAssign: (task, printerId) async {
                  try {
                    await ref
                        .read(schedulerNotifierProvider.notifier)
                        .manualAssign(task.id!, printerId);
                    if (context.mounted) {
                      showSnack(context, '任务已放入打印机轨道');
                    }
                  } catch (error) {
                    if (context.mounted) {
                      showSnack(
                        context,
                        '无法分配: ${friendlyError(error)}',
                        error: true,
                      );
                    }
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddTaskDialog(BuildContext context, WidgetRef ref) {
    AppDialog.show(
      context: context,
      title: '添加调度任务',
      content: _AddTaskForm(
        onSubmit:
            ({
              required gcodePath,
              required gcodeFilename,
              required modelGroup,
              required targetModel,
              required nozzleDiameter,
              required material,
              required grams,
            }) async {
              try {
                await ref
                    .read(schedulerNotifierProvider.notifier)
                    .addTask(
                      gcodePath: gcodePath,
                      gcodeFilename: gcodeFilename,
                      modelGroup: modelGroup,
                      targetModel: targetModel,
                      targetNozzleDiameter: nozzleDiameter,
                      requiredMaterial: material,
                      estimatedGrams: grams,
                    );
                if (context.mounted) {
                  Navigator.of(context).pop();
                  showSnack(context, '已添加调度任务：$gcodeFilename');
                }
              } catch (e) {
                if (context.mounted) {
                  showSnack(context, '添加失败: ${friendlyError(e)}', error: true);
                }
              }
            },
      ),
      actions: const [],
    );
  }
}

class _AutoScheduleToggle extends StatelessWidget {
  const _AutoScheduleToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              '自动调度',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: AppSwitch(value: value, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}

class _SchedulerWorkspace extends StatelessWidget {
  const _SchedulerWorkspace({
    required this.tasks,
    required this.printers,
    required this.printersLoading,
    required this.onAddTask,
    required this.onReorder,
    required this.onAssign,
  });

  final List<SchedulerTask> tasks;
  final List<PrinterWithChannels> printers;
  final bool printersLoading;
  final VoidCallback onAddTask;
  final void Function(int oldIndex, int newIndex) onReorder;
  final Future<void> Function(SchedulerTask task, int printerId) onAssign;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 940;
        final taskStage = _TaskStage(
          tasks: tasks,
          onAddTask: onAddTask,
          onReorder: onReorder,
        );
        final printerStage = _PrinterLandingPanel(
          printers: printers,
          tasks: tasks,
          loading: printersLoading,
          onAssign: onAssign,
        );

        if (compact) {
          return ListView(
            children: [
              SizedBox(
                height: constraints.maxHeight.clamp(360.0, 560.0),
                child: taskStage,
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(height: 300, child: printerStage),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 7, child: taskStage),
            const SizedBox(width: AppSpacing.md),
            Expanded(flex: 3, child: printerStage),
          ],
        );
      },
    );
  }
}

class _TaskStage extends StatelessWidget {
  const _TaskStage({
    required this.tasks,
    required this.onAddTask,
    required this.onReorder,
  });

  final List<SchedulerTask> tasks;
  final VoidCallback onAddTask;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    final pendingCount = tasks
        .where((task) => task.status == SchedulerTaskStatus.pending)
        .length;
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
            child: ExperienceSectionHeading(
              title: '任务轨道',
              trailing: Text(
                '$pendingCount 件等待分配',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Divider(
            height: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(
            child: tasks.isEmpty
                ? EmptyState(
                    bambuIconName: 'scheduler',
                    useGlass: false,
                    title: '轨道还没有任务',
                    subtitle: '添加切片文件后，可直接把它拖到右侧匹配的打印机。',
                    actionLabel: '添加任务',
                    onAction: onAddTask,
                  )
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      AppSpacing.md,
                      AppSpacing.md,
                      AppSpacing.lg,
                    ),
                    itemCount: tasks.length,
                    onReorderItem: onReorder,
                    proxyDecorator: (child, _, animation) => AnimatedBuilder(
                      animation: animation,
                      builder: (context, _) => Material(
                        color: Colors.transparent,
                        elevation: animation.value * 7,
                        borderRadius: BorderRadius.circular(
                          ExperienceTokens.objectRadius,
                        ),
                        child: child,
                      ),
                    ),
                    itemBuilder: (context, index) {
                      final task = tasks[index];
                      return _TaskTrackRow(
                        key: ValueKey('scheduler-task-${task.id ?? index}'),
                        task: task,
                        index: index,
                        isLast: index == tasks.length - 1,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _TaskTrackRow extends StatelessWidget {
  const _TaskTrackRow({
    super.key,
    required this.task,
    required this.index,
    required this.isLast,
  });

  final SchedulerTask task;
  final int index;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canAssign =
        task.status == SchedulerTaskStatus.pending && task.id != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 42,
              child: Stack(
                alignment: Alignment.topCenter,
                children: [
                  if (!isLast)
                    Positioned(
                      top: 30,
                      bottom: -AppSpacing.sm,
                      child: Container(width: 2, color: scheme.outlineVariant),
                    ),
                  Positioned(
                    top: 10,
                    child: ReorderableDragStartListener(
                      index: index,
                      child: Tooltip(
                        message: '拖动调整任务顺序',
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: _modelGroupColor(task.modelGroup),
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.surface, width: 3),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _TaskCard(task: task)),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(
              width: 42,
              child: canAssign
                  ? Draggable<SchedulerTask>(
                      data: task,
                      rootOverlay: true,
                      feedback: _TaskDragPreview(task: task),
                      childWhenDragging: Icon(
                        Icons.pan_tool_alt_rounded,
                        color: scheme.primary.withValues(alpha: 0.28),
                      ),
                      child: Tooltip(
                        message: '拖到打印机进行分配',
                        child: Icon(
                          Icons.pan_tool_alt_rounded,
                          color: scheme.primary,
                        ),
                      ),
                    )
                  : Icon(
                      Icons.check_rounded,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskDragPreview extends StatelessWidget {
  const _TaskDragPreview({required this.task});

  final SchedulerTask task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 340,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(ExperienceTokens.objectRadius),
          border: Border.all(color: scheme.primary, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(Icons.description_outlined, color: scheme.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.gcodeFilename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '${task.targetModel ?? task.modelGroup.label} · ${task.requiredMaterial}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrinterLandingPanel extends StatelessWidget {
  const _PrinterLandingPanel({
    required this.printers,
    required this.tasks,
    required this.loading,
    required this.onAssign,
  });

  final List<PrinterWithChannels> printers;
  final List<SchedulerTask> tasks;
  final bool loading;
  final Future<void> Function(SchedulerTask task, int printerId) onAssign;

  @override
  Widget build(BuildContext context) {
    return OpenStage(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            child: ExperienceSectionHeading(title: '打印机接单区'),
          ),
          Divider(
            height: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : printers.isEmpty
                ? const EmptyState(
                    bambuIconName: 'printer',
                    useGlass: false,
                    title: '还没有打印机',
                    subtitle: '先在打印机页面添加设备，再回来分配任务。',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: printers.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) => _PrinterDropZone(
                      printer: printers[index],
                      tasks: tasks,
                      onAssign: onAssign,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PrinterDropZone extends StatelessWidget {
  const _PrinterDropZone({
    required this.printer,
    required this.tasks,
    required this.onAssign,
  });

  final PrinterWithChannels printer;
  final List<SchedulerTask> tasks;
  final Future<void> Function(SchedulerTask task, int printerId) onAssign;

  bool _accepts(SchedulerTask task) {
    if (task.status != SchedulerTaskStatus.pending || task.id == null) {
      return false;
    }
    final target = task.targetSpec;
    if (target != null) {
      return PrinterModelNormalizer.sameModel(
        target.canonicalModel,
        printer.printer.model,
      );
    }
    return PrinterModelGroup.fromModel(printer.printer.model) ==
        task.modelGroup;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeTasks = tasks
        .where(
          (task) =>
              task.assignedPrinterId == printer.printer.id &&
              !task.status.isTerminal,
        )
        .toList(growable: false);

    return DragTarget<SchedulerTask>(
      onWillAcceptWithDetails: (details) => _accepts(details.data),
      onAcceptWithDetails: (details) {
        onAssign(details.data, printer.printer.id);
      },
      builder: (context, candidates, rejected) {
        final hovering = candidates.isNotEmpty;
        final incompatible = rejected.isNotEmpty;
        final borderColor = hovering
            ? scheme.primary
            : incompatible
            ? AppColors.warning
            : scheme.outlineVariant;
        return AnimatedContainer(
          duration: ExperienceTokens.hoverDuration,
          curve: ExperienceTokens.motionCurve,
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: hovering
                ? scheme.primaryContainer.withValues(alpha: 0.55)
                : scheme.surface,
            borderRadius: BorderRadius.circular(ExperienceTokens.objectRadius),
            border: Border.all(
              color: borderColor,
              width: hovering || incompatible ? 1.7 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AnimatedScale(
                    scale: hovering ? 1.12 : 1,
                    duration: ExperienceTokens.hoverDuration,
                    child: BambuIcon(
                      name: 'printer',
                      size: 26,
                      color: hovering
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                      applyColorFilter: true,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          printer.printer.name ?? printer.printer.model,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${printer.printer.model} · ${printer.channels.length} 个耗材槽',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                hovering
                    ? '松手，把任务交给这台设备'
                    : incompatible
                    ? '机型不匹配，不能接收这份 G-code'
                    : activeTasks.isEmpty
                    ? '拖入匹配任务'
                    : '${activeTasks.length} 个任务正在此设备轨道中',
                style: TextStyle(
                  color: hovering
                      ? scheme.primary
                      : incompatible
                      ? AppColors.warning
                      : scheme.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 单条任务卡片。
class _TaskCard extends ConsumerWidget {
  final SchedulerTask task;
  const _TaskCard({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final tertiaryColor = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;

    return AnimatedContainer(
      duration: ExperienceTokens.contentDuration,
      curve: ExperienceTokens.motionCurve,
      padding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(ExperienceTokens.objectRadius),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          // 左侧：机型组色条
          Container(
            width: 4,
            height: 38,
            decoration: BoxDecoration(
              color: _modelGroupColor(task.modelGroup),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // 中间：文件名 + 元信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.description_outlined,
                      size: 14,
                      color: tertiaryColor,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        task.gcodeFilename,
                        style: AppTypography.body.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: titleColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _ModelGroupBadge(group: task.modelGroup),
                    AppChip(
                      label: task.requiredMaterial,
                      variant: AppChipVariant.default_,
                    ),
                    if (task.estimatedGrams > 0)
                      AppChip(
                        label: '${task.estimatedGrams.toStringAsFixed(0)}g',
                        variant: AppChipVariant.dot,
                        dotColor: AppColors.warning,
                      ),
                    _StatusBadge(status: task.status),
                    // 已分配打印机徽章：assigned 状态显示打印机名称
                    // （assignedPrinterName 由 SchedulerDao LEFT JOIN printers 带出）
                    if (task.status == SchedulerTaskStatus.assigned &&
                        task.assignedPrinterName != null)
                      AppChip(
                        label: task.assignedPrinterName!,
                        variant: AppChipVariant.dot,
                        dotColor: AppColors.info,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // 右侧：操作
          _TaskActions(task: task),
        ],
      ),
    );
  }
}

/// 任务操作按钮组。
class _TaskActions extends ConsumerWidget {
  final SchedulerTask task;
  const _TaskActions({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (task.status == SchedulerTaskStatus.pending)
          IconActionButton(
            icon: Icons.send_rounded,
            onTap: () => _showManualAssignDialog(context, ref, task),
            color: AppColors.primary,
            size: 32,
            tooltip: '手动分配',
          ),
        if (task.status == SchedulerTaskStatus.assigned ||
            task.status == SchedulerTaskStatus.printing)
          IconActionButton(
            icon: Icons.undo_rounded,
            onTap: () async {
              await ref
                  .read(schedulerNotifierProvider.notifier)
                  .resetToPending(task.id!);
              if (context.mounted) showSnack(context, '已重置为待分配');
            },
            color: iconColor,
            size: 32,
            tooltip: '重置为待分配',
          ),
        IconActionButton(
          icon: Icons.delete_outline_rounded,
          onTap: () async {
            final ok = await AppDialog.confirm(
              context,
              '删除调度任务',
              '确定删除「${task.gcodeFilename}」？',
              destructive: true,
            );
            if (ok) {
              await ref
                  .read(schedulerNotifierProvider.notifier)
                  .deleteTask(task.id!);
            }
          },
          color: AppColors.danger,
          size: 32,
          tooltip: '删除',
        ),
      ],
    );
  }

  void _showManualAssignDialog(
    BuildContext context,
    WidgetRef ref,
    SchedulerTask task,
  ) async {
    final printerDao = ref.read(printerDaoProvider);
    final allPrinters = await printerDao.getAllPrintersWithChannels();
    // 这里只做精确机型预筛，最终仍由 Provider 使用舰队事实和喷嘴硬校验。
    final candidates = allPrinters.where((p) {
      final target = task.targetSpec;
      return target != null &&
          PrinterModelNormalizer.sameModel(
            target.canonicalModel,
            p.printer.model,
          );
    }).toList();

    if (!context.mounted) return;
    if (candidates.isEmpty) {
      showSnack(context, '没有精确匹配任务机型的打印机可用', error: true);
      return;
    }

    AppDialog.show(
      context: context,
      title: '手动分配到打印机',
      content: _ManualAssignList(
        printers: candidates,
        onPick: (printerId) async {
          await ref
              .read(schedulerNotifierProvider.notifier)
              .manualAssign(task.id!, printerId);
          if (context.mounted) {
            Navigator.of(context).pop();
            showSnack(context, '已手动分配');
          }
        },
      ),
      actions: [
        _DialogTextButton(
          label: '取消',
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// 机型组徽章。
class _ModelGroupBadge extends StatelessWidget {
  final PrinterModelGroup group;
  const _ModelGroupBadge({required this.group});

  @override
  Widget build(BuildContext context) {
    final color = _modelGroupColor(group);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppColors.radiusFull),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Text(
        group.label,
        style: AppTypography.label.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// 状态徽章。颜色：pending 灰、assigned 蓝、printing 绿、completed 浅绿、cancelled 红。
class _StatusBadge extends StatelessWidget {
  final SchedulerTaskStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final Color bg;
    switch (status) {
      case SchedulerTaskStatus.pending:
        color = AppColors.textSecondary;
        bg = AppColors.surfaceVariant;
      case SchedulerTaskStatus.assigned:
        color = AppColors.info;
        bg = AppColors.infoContainer;
      case SchedulerTaskStatus.printing:
        color = AppColors.success;
        bg = AppColors.successContainer;
      case SchedulerTaskStatus.completed:
        color = AppColors.primary700;
        bg = AppColors.primaryContainer;
      case SchedulerTaskStatus.cancelled:
        color = AppColors.danger;
        bg = AppColors.dangerContainer;
      case SchedulerTaskStatus.failed:
        color = AppColors.danger;
        bg = AppColors.dangerContainer;
      case SchedulerTaskStatus.blocked:
        color = AppColors.warning;
        bg = AppColors.warningContainer;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppColors.radiusFull),
      ),
      child: Text(
        status.label,
        style: AppTypography.label.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// 添加任务表单。
class _AddTaskForm extends StatefulWidget {
  final Future<void> Function({
    required String gcodePath,
    required String gcodeFilename,
    required PrinterModelGroup modelGroup,
    required String targetModel,
    required double nozzleDiameter,
    required String material,
    required double grams,
  })
  onSubmit;

  const _AddTaskForm({required this.onSubmit});

  @override
  State<_AddTaskForm> createState() => _AddTaskFormState();
}

class _AddTaskFormState extends State<_AddTaskForm> {
  String? _gcodePath;
  PrinterModelGroup _group = PrinterModelGroup.a1;
  String _targetModel = 'A1';
  double _nozzleDiameter = 0.4;
  final _materialController = TextEditingController(text: 'PLA');
  final _gramsController = TextEditingController(text: '20');
  bool _submitting = false;

  @override
  void dispose() {
    _materialController.dispose();
    _gramsController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    const typeGroup = XTypeGroup(
      label: 'G-code',
      extensions: <String>['gcode', '3mf'],
    );
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return;
    setState(() => _gcodePath = file.path);
  }

  Future<void> _submit() async {
    if (_gcodePath == null) {
      showSnack(context, '请先选择 G-code 文件', error: true);
      return;
    }
    final material = _materialController.text.trim();
    if (material.isEmpty) {
      showSnack(context, '请输入所需材质', error: true);
      return;
    }
    final grams = double.tryParse(_gramsController.text.trim()) ?? 0;

    setState(() => _submitting = true);
    try {
      final filename = _gcodePath!.split(RegExp(r'[/\\]')).last;
      await widget.onSubmit(
        gcodePath: _gcodePath!,
        gcodeFilename: filename,
        modelGroup: _group,
        targetModel: _targetModel,
        nozzleDiameter: _nozzleDiameter,
        material: material,
        grams: grams,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 文件选择
        Text(
          'G-code 文件',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: subColor,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppColors.surfaceContainerHighDark
                      : AppColors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppColors.radiusMd),
                  border: Border.all(
                    color: isDark ? AppColors.outlineDark : AppColors.outline,
                    width: 1,
                  ),
                ),
                child: Text(
                  _gcodePath == null
                      ? '未选择文件'
                      : _gcodePath!.split(RegExp(r'[/\\]')).last,
                  style: TextStyle(
                    fontSize: 13,
                    color: _gcodePath == null
                        ? (isDark
                              ? AppColors.textTertiaryDark
                              : AppColors.textTertiary)
                        : (isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimary),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            AppButton(
              label: '选择',
              variant: AppButtonVariant.secondary,
              onPressed: _pickFile,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: AppSelect<String>(
                value: _targetModel,
                label: '精确机型',
                items: PrinterModelNormalizer.knownBambuModels
                    .map(
                      (model) =>
                          DropdownMenuItem(value: model, child: Text(model)),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _targetModel = value;
                    _group = PrinterModelGroup.fromModel(value) ?? _group;
                  });
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AppSelect<double>(
                value: _nozzleDiameter,
                label: '切片喷嘴',
                items: const [0.2, 0.4, 0.6, 0.8]
                    .map(
                      (diameter) => DropdownMenuItem(
                        value: diameter,
                        child: Text('${diameter.toStringAsFixed(1)} mm'),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _nozzleDiameter = value);
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // 材质 + 预估克数
        Row(
          children: [
            Expanded(
              child: AppInput(
                label: '所需材质',
                hint: 'PLA / PETG / ABS...',
                controller: _materialController,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AppInput(
                label: '预估克数',
                hint: '20',
                controller: _gramsController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // 提交按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _DialogTextButton(
              label: '取消',
              onTap: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: AppSpacing.sm),
            AppButton(
              label: _submitting ? '添加中...' : '添加任务',
              icon: const Icon(Icons.add_rounded, size: 16),
              onPressed: _submitting ? null : _submit,
            ),
          ],
        ),
      ],
    );
  }
}

/// 手动分配打印机列表。
class _ManualAssignList extends StatelessWidget {
  final List<PrinterWithChannels> printers;
  final Future<void> Function(int printerId) onPick;

  const _ManualAssignList({required this.printers, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final subColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in printers)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppColors.radiusMd),
                onTap: () => onPick(p.printer.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? AppColors.surfaceVariantDark.withValues(alpha: 0.4)
                        : AppColors.surfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(AppColors.radiusMd),
                    border: Border.all(
                      color: isDark ? AppColors.outlineDark : AppColors.outline,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      BambuIcon(
                        name: 'printer',
                        size: 16,
                        color: AppColors.primary,
                        applyColorFilter: true,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.printer.name ?? p.serial ?? '未命名打印机',
                              style: AppTypography.body.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: titleColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${p.printer.brand} ${p.printer.model} · ${p.channels.where((c) => c.isActive).length} 个可用通道',
                              style: AppTypography.caption.copyWith(
                                fontSize: 11,
                                color: subColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: subColor,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 对话框文字按钮（取消等次级操作）。
class _DialogTextButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _DialogTextButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (GlassButtonsTheme.enabledOf(context)) {
      return AppGlassButton(
        label: label,
        onPressed: onTap,
        variant: AppGlassButtonVariant.quiet,
        compact: true,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 机型组对应主题色。
///
/// A1 蓝色 / P1 绿色 / X1 紫色 / H2D 橙色，便于视觉区分。
Color _modelGroupColor(PrinterModelGroup g) {
  switch (g) {
    case PrinterModelGroup.a1:
      return AppColors.info;
    case PrinterModelGroup.p1:
      return AppColors.primary;
    case PrinterModelGroup.x1:
      return const Color(0xFF8B5CF6); // 紫色
    case PrinterModelGroup.h2d:
      return AppColors.warning;
  }
}
