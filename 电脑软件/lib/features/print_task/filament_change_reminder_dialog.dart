import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_curves.dart';
import '../../core/theme/interaction_effects.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/gram_utils.dart';
import '../../data/external/slicer/filament_change_point.dart';
import '../../widgets/filament_spool_icon.dart';

enum FilamentFeedPhase { waiting, unloading, loading, completed }

class ReminderSpool {
  const ReminderSpool({
    required this.manufacturer,
    required this.materialType,
    required this.colorHex,
    required this.colorName,
    required this.remainingGrams,
  });

  final String manufacturer;
  final String materialType;
  final String colorHex;
  final String? colorName;
  final double remainingGrams;
}

class FilamentChangeReminderData {
  const FilamentChangeReminderData({
    required this.point,
    required this.printerLabel,
    required this.taskName,
    required this.changeIndex,
    required this.changeCount,
    required this.upcoming,
    this.currentColorHex,
    this.currentSpool,
    this.targetSpool,
  });

  final FilamentChangePoint point;
  final String printerLabel;
  final String taskName;
  final int changeIndex;
  final int changeCount;
  final List<FilamentChangePoint> upcoming;
  final String? currentColorHex;
  final ReminderSpool? currentSpool;
  final ReminderSpool? targetSpool;
}

/// Blocking, machine-driven external filament change prompt.
///
/// There is intentionally no close or confirmation button. The dialog closes
/// only after the printer reports a completed load cycle or resumes printing.
class FilamentChangeReminderDialog extends StatefulWidget {
  const FilamentChangeReminderDialog({
    super.key,
    required this.data,
    required this.phase,
  });

  final FilamentChangeReminderData data;
  final ValueNotifier<FilamentFeedPhase> phase;

  static Future<bool?> show(
    BuildContext context, {
    required FilamentChangeReminderData data,
    required ValueNotifier<FilamentFeedPhase> phase,
  }) {
    return showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '外挂耗材换色提醒',
      barrierColor: Colors.black.withValues(alpha: 0.48),
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
      pageBuilder: (_, __, ___) => FilamentChangeReminderDialog(
        data: data,
        phase: phase,
      ),
    );
  }

  @override
  State<FilamentChangeReminderDialog> createState() =>
      _FilamentChangeReminderDialogState();
}

class _FilamentChangeReminderDialogState
    extends State<FilamentChangeReminderDialog> {
  bool _allowPop = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.phase.addListener(_onPhaseChanged);
    if (widget.phase.value == FilamentFeedPhase.completed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _closeCompleted());
    }
  }

  @override
  void dispose() {
    widget.phase.removeListener(_onPhaseChanged);
    super.dispose();
  }

  void _onPhaseChanged() {
    if (!mounted) return;
    setState(() {});
    if (widget.phase.value == FilamentFeedPhase.completed) {
      _closeCompleted();
    }
  }

  Future<void> _closeCompleted() async {
    if (_closing || !mounted) return;
    _closing = true;
    setState(() => _allowPop = true);
    await Future<void>.delayed(
      AppMotion.duration(context, const Duration(milliseconds: 420)),
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final phase = widget.phase.value;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final targetHex = data.targetSpool?.colorHex ?? data.point.colorHex;
    final targetColor = ColorUtils.fromHex(
      targetHex ?? '#8A8A8A',
      fallback: AppColors.primary,
    );

    return PopScope(
      canPop: _allowPop,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 690),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
              child: Material(
                color: isDark ? AppColors.surfaceDark : AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Header(data: data),
                      const SizedBox(height: 18),
                      _TargetSpool(
                        data: data,
                        color: targetColor,
                        colorHex: targetHex,
                      ),
                      const SizedBox(height: 14),
                      _ColorTransition(data: data, targetColor: targetColor),
                      if (data.upcoming.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _UpcomingChanges(points: data.upcoming),
                      ],
                      const SizedBox(height: 16),
                      _MachineStatus(phase: phase, color: targetColor),
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
}

class _Header extends StatelessWidget {
  const _Header({required this.data});

  final FilamentChangeReminderData data;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.swap_vert_circle_rounded,
            color: AppColors.warning,
            size: 25,
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '请装入下一卷耗材',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              Text(
                '${data.printerLabel} · ${data.taskName}',
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
            color: AppColors.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '${data.changeIndex}/${data.changeCount} · 第 ${data.point.layerNum} 层',
            style: TextStyle(
              color: AppColors.primary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _TargetSpool extends StatelessWidget {
  const _TargetSpool({
    required this.data,
    required this.color,
    required this.colorHex,
  });

  final FilamentChangeReminderData data;
  final Color color;
  final String? colorHex;

  @override
  Widget build(BuildContext context) {
    final spool = data.targetSpool;
    final material = spool?.materialType ?? data.point.materialType ?? '耗材';
    final title = spool == null
        ? '$material · ${colorHex ?? '颜色未知'}'
        : '${spool.manufacturer} · ${spool.colorName ?? spool.colorHex}';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.075),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.86, end: 1),
            duration: AppMotion.duration(
              context,
              const Duration(milliseconds: 480),
            ),
            curve: Curves.easeOutBack,
            builder: (_, value, child) =>
                Transform.scale(scale: value, child: child),
            child: FilamentSpoolIcon(color: color, size: 76),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '现在装入',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 7,
                  runSpacing: 5,
                  children: [
                    _Tag(
                      text: data.point.toolIndex >= 0
                          ? 'T${data.point.toolIndex}'
                          : '手动换料',
                      color: color,
                    ),
                    _Tag(text: material, color: AppColors.primary),
                    if (colorHex != null) _Tag(text: colorHex!, color: color),
                    if (spool != null)
                      _Tag(
                        text:
                            '余 ${GramUtils.formatGrams(spool.remainingGrams)}',
                        color: AppColors.success,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorTransition extends StatelessWidget {
  const _ColorTransition({required this.data, required this.targetColor});

  final FilamentChangeReminderData data;
  final Color targetColor;

  @override
  Widget build(BuildContext context) {
    final currentHex = data.currentSpool?.colorHex ?? data.currentColorHex;
    final currentColor = ColorUtils.fromHex(
      currentHex ?? '#8A8A8A',
      fallback: AppColors.textTertiary,
    );
    return Row(
      children: [
        Expanded(
          child: _ColorStep(
            label: '当前退出',
            value: data.currentSpool?.colorName ?? currentHex ?? '上一卷',
            color: currentColor,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Icon(Icons.arrow_forward_rounded, size: 20),
        ),
        Expanded(
          child: _ColorStep(
            label: '下一卷',
            value: data.targetSpool?.colorName ??
                data.targetSpool?.colorHex ??
                data.point.colorHex ??
                '目标耗材',
            color: targetColor,
          ),
        ),
      ],
    );
  }
}

class _ColorStep extends StatelessWidget {
  const _ColorStep({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black26),
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 9,
                  color: AppColors.textSecondary,
                ),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UpcomingChanges extends StatelessWidget {
  const _UpcomingChanges({required this.points});

  final List<FilamentChangePoint> points;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          '接下来',
          style: TextStyle(fontSize: 10, color: AppColors.textSecondary),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 5,
            children: [
              for (final point in points.take(3))
                _Tag(
                  text: '第 ${point.layerNum} 层 · T${point.toolIndex}',
                  color: ColorUtils.fromHex(
                    point.colorHex ?? '#8A8A8A',
                    fallback: AppColors.primary,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MachineStatus extends StatelessWidget {
  const _MachineStatus({required this.phase, required this.color});

  final FilamentFeedPhase phase;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final (icon, title, detail) = switch (phase) {
      FilamentFeedPhase.waiting => (
          Icons.sensors_rounded,
          '等待打印机开始换料',
          '窗口会在检测到进料完成后自动关闭',
        ),
      FilamentFeedPhase.unloading => (
          Icons.upload_rounded,
          '正在退出上一卷耗材',
          '请按打印机提示完成退料',
        ),
      FilamentFeedPhase.loading => (
          Icons.download_rounded,
          '正在检测新耗材进料',
          '保持新耗材顺畅送入挤出机',
        ),
      FilamentFeedPhase.completed => (
          Icons.check_circle_rounded,
          '进料完成',
          '即将返回工作台',
        ),
    };
    final statusColor =
        phase == FilamentFeedPhase.completed ? AppColors.success : color;
    return AnimatedContainer(
      duration: AppMotion.duration(
        context,
        const Duration(milliseconds: 260),
      ),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: statusColor, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (phase != FilamentFeedPhase.completed)
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: statusColor,
              ),
            ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
