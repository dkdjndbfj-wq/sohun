import 'dart:ui' as ui;

import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/friendly_error.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/database/models/print_queue_item.dart';
import '../../data/external/slicer/autoclear_detector.dart';
import '../../data/prefs/autoclear_cache_prefs.dart';
import '../../providers/autoclear_provider.dart';
import '../../providers/print_queue_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';

/// 打印队列面板。
///
/// 显示当前活跃打印机的队列，支持：
/// - 添加 G-code / 3MF 到队列（自动发送队首到打印机）
/// - 取消 / 删除队列项
/// - 取件确认：等待取件的项高亮 + 大按钮「已取件，开始下一个」
///
/// 注意：仅 LAN 模式打印机可自动发送任务；云端打印机仅记录排队。
class PrintQueuePanel extends ConsumerWidget {
  const PrintQueuePanel({super.key, this.printerSerial});

  final String? printerSerial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serial = printerSerial ?? ref.watch(activePrinterSerialProvider);

    // 无活跃打印机
    if (serial == null || serial.isEmpty) {
      return const EmptyState(
        bambuIconName: 'printer',
        useGlass: true,
        title: '未选择活跃打印机',
        subtitle: '请在「设备列表」中点击一台打印机设为当前设备，\n才能查看和管理它的打印队列。',
      );
    }

    final items = ref.watch(printQueueProvider(serial));

    return Padding(
      padding: const EdgeInsets.all(ExperienceTokens.pageGutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExperiencePageHeader(
            title: '生产轨道',
            description: '把切片文件排成真实的发车顺序。拖动轨道节点即可改序，队首会在设备空闲且通过安全检查后自动出发。',
            actions: [
              AppButton(
                label: '添加到轨道',
                icon: const Icon(Icons.add_rounded, size: 16),
                onPressed: () => _pickAndEnqueue(context, ref, serial),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: OpenStage(
              padding: EdgeInsets.zero,
              child: items.isEmpty
                  ? const EmptyState(
                      bambuIconName: 'monitor_item_print',
                      useGlass: false,
                      title: '轨道正在等第一件作品',
                      subtitle: '添加 .gcode 或 .3mf 文件后，它会出现在这里并自动进入安全检查。',
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _QueueOverview(serial: serial, items: items),
                        Divider(
                          height: 1,
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        Expanded(
                          child: ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.lg,
                              AppSpacing.md,
                              AppSpacing.lg,
                              AppSpacing.xl,
                            ),
                            itemCount: items.length,
                            proxyDecorator: (child, _, animation) {
                              return AnimatedBuilder(
                                animation: animation,
                                builder: (context, _) => Material(
                                  color: Colors.transparent,
                                  elevation: 8 * animation.value,
                                  borderRadius: BorderRadius.circular(
                                    ExperienceTokens.objectRadius,
                                  ),
                                  child: child,
                                ),
                              );
                            },
                            onReorderItem: (oldIndex, newIndex) {
                              if (oldIndex == newIndex) return;
                              final reordered = [...items];
                              final moved = reordered.removeAt(oldIndex);
                              reordered.insert(newIndex, moved);
                              final orderedIds = reordered
                                  .map((item) => item.id)
                                  .whereType<int>()
                                  .toList(growable: false);
                              if (orderedIds.isNotEmpty) {
                                ref
                                    .read(printQueueProvider(serial).notifier)
                                    .reorder(orderedIds);
                              }
                            },
                            itemBuilder: (context, index) {
                              final item = items[index];
                              return _ProductionTrackItem(
                                key: ValueKey(
                                  'queue-${item.id ?? item.gcodePath}',
                                ),
                                index: index,
                                isFirst: index == 0,
                                isLast: index == items.length - 1,
                                status: item.status,
                                child: _QueueItemCard(
                                  item: item,
                                  index: index + 1,
                                  onCancel: item.id == null
                                      ? null
                                      : () => ref
                                            .read(
                                              printQueueProvider(
                                                serial,
                                              ).notifier,
                                            )
                                            .cancel(item.id!),
                                  onDelete: item.id == null
                                      ? null
                                      : () => _confirmDelete(
                                          context,
                                          ref,
                                          serial,
                                          item,
                                        ),
                                  onRetry:
                                      item.id == null ||
                                          item.status !=
                                              PrintQueueStatus.failed ||
                                          item.studioWorkOrderId == null
                                      ? null
                                      : () => _retryFailed(
                                          context,
                                          ref,
                                          serial,
                                          item,
                                        ),
                                  onConfirmRemoval:
                                      item.status !=
                                          PrintQueueStatus.waitingRemoval
                                      ? null
                                      : () => _confirmRemoval(
                                          context,
                                          ref,
                                          serial,
                                          item,
                                        ),
                                ),
                              );
                            },
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

  Future<void> _confirmRemoval(
    BuildContext context,
    WidgetRef ref,
    String serial,
    PrintQueueItem item,
  ) async {
    await ref.read(printQueueProvider(serial).notifier).confirmRemoval();
  }

  Future<void> _retryFailed(
    BuildContext context,
    WidgetRef ref,
    String serial,
    PrintQueueItem item,
  ) async {
    try {
      await ref.read(printQueueProvider(serial).notifier).retryFailed(item.id!);
      if (context.mounted) showSnack(context, '失败任务已重新加入队列，历史损耗不会重复扣除');
    } catch (error) {
      if (context.mounted) {
        showSnack(context, '无法重试：${friendlyError(error)}', error: true);
      }
    }
  }

  /// 选择 G-code / 3MF 文件并加入当前打印机队列。
  Future<void> _pickAndEnqueue(
    BuildContext context,
    WidgetRef ref,
    String serial,
  ) async {
    const typeGroup = XTypeGroup(
      label: 'G-code / 3MF',
      extensions: <String>['gcode', '3mf'],
    );
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null) return;
    final path = file.path;
    final name = path.split(RegExp(r'[/\\]')).last;
    try {
      await ref
          .read(printQueueProvider(serial).notifier)
          .enqueue(gcodePath: path, filename: name);
      if (context.mounted) {
        showSnack(context, '已添加到队列：$name');
      }
    } catch (e) {
      if (context.mounted) {
        showSnack(context, '添加失败：${friendlyError(e)}', error: true);
      }
    }
  }

  /// 删除队列项前确认（仅 queued / cancelled 可删除）。
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String serial,
    PrintQueueItem item,
  ) async {
    final ok = await AppDialog.confirm(
      context,
      '删除队列项',
      '确定从队列中删除「${item.filename}」？\n注意：删除不会停止已在打印的任务，'
          '仅从队列移除排队 / 已取消的项。',
      confirmText: '删除',
      destructive: true,
    );
    if (!ok) return;
    if (item.id == null) return;
    await ref.read(printQueueProvider(serial).notifier).delete(item.id!);
    if (context.mounted) showSnack(context, '已删除队列项');
  }
}

class _QueueOverview extends StatelessWidget {
  const _QueueOverview({required this.serial, required this.items});

  final String serial;
  final List<PrintQueueItem> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = items.cast<PrintQueueItem?>().firstWhere(
      (item) =>
          item?.status == PrintQueueStatus.printing ||
          item?.status == PrintQueueStatus.waitingRemoval,
      orElse: () => null,
    );
    final queued = items
        .where((item) => item.status == PrintQueueStatus.queued)
        .length;
    final statusText = active?.status == PrintQueueStatus.printing
        ? '轨道运行中'
        : active?.status == PrintQueueStatus.waitingRemoval
        ? '等待取件后继续'
        : queued > 0
        ? '准备发车'
        : '本轮已完成';

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: ExperienceTokens.hoverDuration,
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: active?.status == PrintQueueStatus.waitingRemoval
                  ? AppColors.warning
                  : scheme.primary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color:
                      (active?.status == PrintQueueStatus.waitingRemoval
                              ? AppColors.warning
                              : scheme.primary)
                          .withValues(alpha: 0.25),
                  blurRadius: 0,
                  spreadRadius: 5,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusText,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'SN $serial',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontFamily: AppTypography.monoFontFamily,
                    fontSize: 11,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          Text(
            '$queued 件待打印 · 共 ${items.length} 件',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductionTrackItem extends StatelessWidget {
  const _ProductionTrackItem({
    super.key,
    required this.index,
    required this.isFirst,
    required this.isLast,
    required this.status,
    required this.child,
  });

  final int index;
  final bool isFirst;
  final bool isLast;
  final PrintQueueStatus status;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active =
        status == PrintQueueStatus.printing ||
        status == PrintQueueStatus.waitingRemoval;
    final color = status == PrintQueueStatus.waitingRemoval
        ? AppColors.warning
        : active
        ? scheme.primary
        : scheme.outline;

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
                  if (!isFirst)
                    Positioned(
                      top: 0,
                      bottom: 28,
                      child: Container(width: 2, color: scheme.outlineVariant),
                    ),
                  if (!isLast)
                    Positioned(
                      top: 28,
                      bottom: 0,
                      child: Container(width: 2, color: scheme.outlineVariant),
                    ),
                  Positioned(
                    top: 14,
                    child: AnimatedContainer(
                      duration: ExperienceTokens.hoverDuration,
                      width: active ? 17 : 13,
                      height: active ? 17 : 13,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: child),
            const SizedBox(width: AppSpacing.sm),
            ReorderableDragStartListener(
              index: index,
              child: Tooltip(
                message: '拖动调整顺序',
                child: SizedBox(
                  width: 38,
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    color: scheme.onSurfaceVariant,
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

/// 单个队列项卡片。
///
/// 等待取件状态下整张卡变 warning 容器色 + 顶部大号「已取件」按钮。
/// 自动清件徽章三态：识别中（灰）/ 已识别（绿）/ 未检测到（橙）。
class _QueueItemCard extends ConsumerWidget {
  final PrintQueueItem item;
  final int index;
  final VoidCallback? onCancel;
  final VoidCallback? onDelete;
  final VoidCallback? onRetry;
  final VoidCallback? onConfirmRemoval;

  const _QueueItemCard({
    required this.item,
    required this.index,
    required this.onCancel,
    required this.onDelete,
    required this.onRetry,
    required this.onConfirmRemoval,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isWaitingRemoval = item.status == PrintQueueStatus.waitingRemoval;
    final isPrinting = item.status == PrintQueueStatus.printing;
    final isCompleted = item.status == PrintQueueStatus.completed;
    final isCancelled = item.status == PrintQueueStatus.cancelled;
    final isFailed = item.status == PrintQueueStatus.failed;
    final isQueued = item.status == PrintQueueStatus.queued;

    // 自动清件检测结果（按文件名匹配）
    final autoclearMap = ref.watch(autoclearStateProvider);
    final autoclearEntry = autoclearMap[item.filename];

    // 状态徽章变体映射
    final AppChipVariant chipVariant;
    final Color? dotColor;
    switch (item.status) {
      case PrintQueueStatus.queued:
        chipVariant = AppChipVariant.default_;
        dotColor = isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;
        break;
      case PrintQueueStatus.printing:
        chipVariant = AppChipVariant.info;
        dotColor = null;
        break;
      case PrintQueueStatus.waitingRemoval:
        chipVariant = AppChipVariant.warn;
        dotColor = null;
        break;
      case PrintQueueStatus.completed:
        chipVariant = AppChipVariant.dot;
        dotColor = AppColors.success;
        break;
      case PrintQueueStatus.cancelled:
        chipVariant = AppChipVariant.dot;
        dotColor = isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;
        break;
      case PrintQueueStatus.failed:
        chipVariant = AppChipVariant.danger;
        dotColor = AppColors.danger;
        break;
    }

    // 等待取件：整卡高亮 warning 容器背景 + warning 描边
    final borderColor = isWaitingRemoval
        ? AppColors.warning.withValues(alpha: 0.5)
        : (isPrinting
              ? AppColors.primary.withValues(alpha: 0.4)
              : Colors.transparent);

    final surfaceColor = isWaitingRemoval
        ? AppColors.warningContainer
        : isPrinting
        ? AppColors.primaryContainer.withValues(alpha: isDark ? 0.18 : 0.42)
        : Theme.of(context).colorScheme.surface;

    return AnimatedContainer(
      duration: ExperienceTokens.contentDuration,
      curve: ExperienceTokens.motionCurve,
      padding: const EdgeInsets.all(AppSpacing.md + 2),
      decoration: BoxDecoration(
        color: surfaceColor,
        border: Border.all(
          color: borderColor == Colors.transparent
              ? Theme.of(context).colorScheme.outlineVariant
              : borderColor,
          width: 1.2,
        ),
        borderRadius: BorderRadius.circular(ExperienceTokens.objectRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部：序号 + 文件名 + 状态徽章
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: isWaitingRemoval
                      ? AppColors.warning.withValues(alpha: 0.18)
                      : AppColors.primaryContainer,
                  borderRadius: BorderRadius.circular(AppColors.radiusSm),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$index',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isWaitingRemoval
                        ? AppColors.warning
                        : AppColors.primary,
                    fontFamily: AppTypography.monoFontFamily,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.filename,
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
                    const SizedBox(height: 2),
                    Text(
                      '排队于 ${_formatDateTime(item.queuedAt)}'
                      '${item.startedAt != null ? '  ·  开始于 ${_formatDateTime(item.startedAt!)}' : ''}'
                      '${item.completedAt != null ? '  ·  完成于 ${_formatDateTime(item.completedAt!)}' : ''}',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark
                            ? AppColors.textTertiaryDark
                            : AppColors.textTertiary,
                        fontFamily: AppTypography.monoFontFamily,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppChip(
                    label: item.status.label,
                    variant: chipVariant,
                    dotColor: dotColor,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  _AutoclearBadge(
                    entry: autoclearEntry,
                    onTap: () => _showAutoclearDialog(
                      context,
                      ref,
                      item.gcodePath,
                      item.filename,
                    ),
                  ),
                ],
              ),
            ],
          ),
          // 等待取件：大号「已取件，开始下一个」按钮
          if (isWaitingRemoval && onConfirmRemoval != null) ...[
            const SizedBox(height: AppSpacing.md + 2),
            AppButton(
              label: '已取件，开始下一个',
              variant: AppButtonVariant.primary,
              icon: Builder(
                builder: (context) => BambuIcon(
                  name: 'completed',
                  size: 18,
                  color: GlassButtonsTheme.enabledOf(context)
                      ? IconTheme.of(context).color
                      : AppColors.onPrimary,
                  applyColorFilter: true,
                ),
              ),
              onPressed: onConfirmRemoval,
            ),
          ],
          // 打印中：不可操作（提示）
          if (isPrinting) ...[
            const SizedBox(height: AppSpacing.md),
            _HintBar(
              text: '正在打印中，请等待打印完成后取件',
              color: AppColors.primary,
              bambuIconName: 'printer',
            ),
          ],
          // 操作按钮行：重试 / 取消 / 删除
          if (isQueued || isCancelled || isFailed) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isFailed && onRetry != null)
                  AppButton(
                    label: '检查耗材并重试',
                    variant: AppButtonVariant.primary,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    onPressed: onRetry,
                  ),
                if (isFailed && onRetry != null && onDelete != null)
                  const SizedBox(width: AppSpacing.sm),
                if (isQueued && onCancel != null)
                  AppButton(
                    label: '取消',
                    variant: AppButtonVariant.secondary,
                    icon: BambuIcon(
                      name: 'cross',
                      size: 14,
                      color: AppColors.primary,
                      applyColorFilter: true,
                    ),
                    onPressed: onCancel,
                  ),
                if (isQueued && onCancel != null && onDelete != null)
                  const SizedBox(width: AppSpacing.sm),
                if (onDelete != null)
                  AppButton(
                    label: '删除',
                    variant: AppButtonVariant.danger,
                    icon: Builder(
                      builder: (context) => BambuIcon(
                        name: 'delete_filament',
                        size: 14,
                        color: GlassButtonsTheme.enabledOf(context)
                            ? IconTheme.of(context).color
                            : AppColors.onPrimary,
                        applyColorFilter: true,
                      ),
                    ),
                    onPressed: onDelete,
                  ),
              ],
            ),
          ],
          // 已完成：可删除（清理）
          if (isCompleted && onDelete != null) ...[
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerRight,
              child: AppButton(
                label: '从列表删除',
                variant: AppButtonVariant.ghost,
                icon: const BambuIcon(
                  name: 'delete_filament',
                  size: 14,
                  color: AppColors.danger,
                  applyColorFilter: true,
                ),
                onPressed: onDelete,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 格式化日期时间：yyyy-MM-dd HH:mm
  static String _formatDateTime(DateTime dt) {
    return '${dt.year}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// 提示条。
class _HintBar extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final String? bambuIconName;

  const _HintBar({
    required this.text,
    required this.color,
    this.icon,
    this.bambuIconName,
  }) : assert(
         icon != null || bambuIconName != null,
         '必须提供 icon 或 bambuIconName 之一',
       );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
      ),
      child: Row(
        children: [
          if (bambuIconName != null)
            BambuIcon(
              name: bambuIconName!,
              size: 14,
              color: color,
              applyColorFilter: true,
            )
          else
            Icon(icon, size: 14, color: color),
          const SizedBox(width: AppSpacing.xs + 2),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 自动清件徽章（三态）。
///
/// - 无缓存 / 评分=0：灰色「识别中…」（可点击触发手动标记）
/// - 缓存.hasAutoClear=true 且无覆盖：绿色「自动清件」
/// - 缓存.hasAutoClear=false 且无覆盖：橙色「未检测到」
/// - 手动覆盖为含：绿色「已标记·含」+ 锁图标
/// - 手动覆盖为不含：橙色「已标记·无」+ 锁图标
class _AutoclearBadge extends StatelessWidget {
  final AutoclearCacheEntry? entry;
  final VoidCallback? onTap;

  const _AutoclearBadge({this.entry, this.onTap});

  @override
  Widget build(BuildContext context) {
    // 无缓存或评分=0（含检测失败）→ 识别中
    if (entry == null || entry!.score == 0 && entry!.manualOverride == null) {
      return _badge(
        context,
        label: '识别中…',
        bgColor: Colors.transparent,
        fgColor: AppColors.textTertiary,
        bambuIconName: 'refresh_normal',
      );
    }

    // 手动覆盖优先
    if (entry!.manualOverride != null) {
      if (entry!.manualOverride!) {
        return _badge(
          context,
          label: '已标记·含',
          bgColor: AppColors.successContainer,
          fgColor: AppColors.success,
          bambuIconName: 'confirm',
        );
      }
      return _badge(
        context,
        label: '已标记·无',
        bgColor: AppColors.warningContainer,
        fgColor: AppColors.warning,
        bambuIconName: 'confirm',
      );
    }

    // 自动检测结果
    if (entry!.hasAutoClear) {
      return _badge(
        context,
        label: '自动清件',
        bgColor: AppColors.successContainer,
        fgColor: AppColors.success,
        bambuIconName: 'completed',
      );
    }
    return _badge(
      context,
      label: '未检测到',
      bgColor: AppColors.warningContainer,
      fgColor: AppColors.warning,
      bambuIconName: 'warning',
    );
  }

  Widget _badge(
    BuildContext context, {
    required String label,
    required Color bgColor,
    required Color fgColor,
    required String bambuIconName,
  }) {
    if (GlassButtonsTheme.enabledOf(context)) {
      return AppGlassButton(
        label: label,
        onPressed: onTap,
        variant: AppGlassButtonVariant.quiet,
        tint: fgColor,
        compact: true,
        minimumSize: const Size(0, 24),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 3,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Builder(
              builder: (context) => BambuIcon(
                name: bambuIconName,
                size: 10,
                color: IconTheme.of(context).color,
                applyColorFilter: true,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(100),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 3,
        ),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(100),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            BambuIcon(
              name: bambuIconName,
              size: 10,
              color: fgColor,
              applyColorFilter: true,
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: fgColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自动清件覆盖对话框。
///
/// 展示自动检测评分明细，提供三个操作：
/// - 标记为含自动清件（手动覆盖为 true）
/// - 标记为不含自动清件（手动覆盖为 false）
/// - 清除手动覆盖（回退到自动检测结果）
/// - 重新自动扫描
Future<void> _showAutoclearDialog(
  BuildContext context,
  WidgetRef ref,
  String gcodePath,
  String filename,
) async {
  final entry = ref.read(autoclearStateProvider)[filename];

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('自动清件标记'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '文件：$filename',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (entry == null) ...[
              const Text('尚未检测，点击「重新自动扫描」开始识别。'),
            ] else ...[
              Text('启发式评分：${entry.score} / ${AutoClearDetector.threshold}'),
              const SizedBox(height: 8),
              if (entry.matchedFeatures.isEmpty) ...[
                const Text('无命中特征'),
              ] else ...[
                const Text(
                  '命中特征：',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                for (final f in entry.matchedFeatures)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 2),
                    child: Text(
                      '• $f',
                      style: const TextStyle(fontSize: 12, height: 1.4),
                    ),
                  ),
              ],
              const SizedBox(height: 8),
              if (entry.hasManualOverride) ...[
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.infoContainer,
                    borderRadius: BorderRadius.circular(AppColors.radiusSm),
                  ),
                  child: Text(
                    entry.manualOverride!
                        ? '当前：手动标记为「含自动清件」'
                        : '当前：手动标记为「不含自动清件」',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ] else ...[
                Text(
                  entry.hasAutoClear ? '当前：自动识别为含自动清件脚本' : '当前：自动识别为不含自动清件脚本',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
        TextButton(
          onPressed: () async {
            await ref
                .read(autoclearServiceProvider)
                .setManualOverride(gcodePath, false);
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text(
            '标记为不含',
            style: TextStyle(color: AppColors.warning),
          ),
        ),
        TextButton(
          onPressed: () async {
            await ref
                .read(autoclearServiceProvider)
                .setManualOverride(gcodePath, true);
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('标记为含', style: TextStyle(color: AppColors.success)),
        ),
        TextButton(
          onPressed: () async {
            await ref
                .read(autoclearServiceProvider)
                .setManualOverride(gcodePath, null);
            // 清除覆盖后触发重新扫描
            await ref.read(autoclearServiceProvider).detectAndCache(gcodePath);
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('重新自动扫描'),
        ),
      ],
    ),
  );
}
