import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/friendly_error.dart';
import '../../data/database/models/print_queue_item.dart';
import '../../providers/print_queue_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/studio_provider.dart';
import 'farm_ui/farm_theme.dart';
import 'farm_ui/farm_feedback.dart';

/// 农场人工取件的阻塞式确认弹窗。
///
/// 打印机上报完成后，工单与耗材账目已经结算；这个确认只表示工作人员
/// 已经清空打印平台，随后才允许队列状态机尝试发送下一项。
class FarmPrintRemovalConfirmationDialog extends ConsumerStatefulWidget {
  const FarmPrintRemovalConfirmationDialog({
    super.key,
    required this.item,
    required this.pendingCount,
  });

  final PrintQueueItem item;
  final int pendingCount;

  static Future<void> show(
    BuildContext context, {
    required PrintQueueItem item,
    required int pendingCount,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FarmPrintRemovalConfirmationDialog(
        item: item,
        pendingCount: pendingCount,
      ),
    );
  }

  @override
  ConsumerState<FarmPrintRemovalConfirmationDialog> createState() =>
      _FarmPrintRemovalConfirmationDialogState();
}

class _FarmPrintRemovalConfirmationDialogState
    extends ConsumerState<FarmPrintRemovalConfirmationDialog> {
  bool _busy = false;
  bool _closeScheduled = false;

  @override
  Widget build(BuildContext context) {
    final itemId = widget.item.id;
    final pending = ref.watch(pendingPrintRemovalsProvider).valueOrNull;
    final stillWaiting = pending == null ||
        pending.any(
          (item) =>
              item.id == itemId &&
              item.printerSerial == widget.item.printerSerial,
        );
    if (!stillWaiting && !_busy && !_closeScheduled) {
      _closeScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    }

    final queue = ref.watch(printQueueProvider(widget.item.printerSerial));
    final nextItems = queue
        .where((item) => item.status == PrintQueueStatus.queued)
        .toList(growable: false)
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final next = nextItems.firstOrNull;
    final printers =
        ref.watch(printersWithChannelsProvider).valueOrNull ?? const [];
    var printerLabel = widget.item.printerSerial;
    for (final printer in printers) {
      if (printer.serial == widget.item.printerSerial) {
        printerLabel = printer.printer.name ?? printer.printer.model;
        break;
      }
    }
    final pendingCount = pending?.length ?? widget.pendingCount;
    final batchLabel =
        widget.item.batchIndex != null && widget.item.batchTotal != null
            ? '批次 ${widget.item.batchIndex}/${widget.item.batchTotal}'
            : null;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.pan_tool_alt_outlined, color: FarmVisual.warning),
          const SizedBox(width: 10),
          const Expanded(child: Text('打印完成，请先取件')),
          if (pendingCount > 1)
            Chip(
              label: Text('还有 ${pendingCount - 1} 台待处理'),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: FarmVisual.warning.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(FarmPalette.radius),
                border: Border.all(
                  color: FarmVisual.warning.withValues(alpha: .35),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    printerLabel,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.item.filename,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (batchLabel != null) ...[
                    const SizedBox(height: 6),
                    Chip(
                      label: Text(batchLabel),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              '请确认成品已经从打印平台完全取下，平台上没有残留模型、裙边或工具。',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(FarmPalette.radius),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    next == null
                        ? Icons.check_circle_outline_rounded
                        : Icons.skip_next_rounded,
                    size: 20,
                    color: FarmVisual.primary,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      next == null
                          ? '当前没有后续任务；确认后打印机恢复可用。'
                          : '下一项已预排：${next.filename}\n确认取件后，系统将进行安全检查并尝试发送。',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton.icon(
          onPressed: _busy || !stillWaiting ? null : _confirmRemoval,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.task_alt_rounded, size: 18),
          label: Text(next == null ? '确认已取件' : '已取件，开始下一项'),
        ),
      ],
    );
  }

  Future<void> _confirmRemoval() async {
    if (_busy || widget.item.id == null) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(printQueueProvider(widget.item.printerSerial).notifier)
          .confirmRemoval(expectedQueueItemId: widget.item.id);
    } catch (error) {
      if (mounted) {
        showSnack(
          context,
          friendlyError(error, context: '确认取件'),
          error: true,
        );
        setState(() => _busy = false);
      }
      return;
    }

    try {
      await recordCurrentFarmActivity(
        ref,
        actionCode: 'print.removal_confirmed',
        entityType: 'print_queue',
        entityId: '${widget.item.id}',
        summary: '确认 ${widget.item.printerSerial} 已取件：${widget.item.filename}',
      );
    } catch (error) {
      debugPrint('[FarmRemoval] 取件确认审计写入失败: $error');
    }
    if (mounted) Navigator.of(context).pop();
  }
}
